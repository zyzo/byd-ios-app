"""Small HTTP backend for the BYD Companion iOS app.

Wraps pyBYD so the app never handles BYD credentials or BYD's encryption.
Every request except /health needs `Authorization: Bearer <APP_TOKEN>` (APP_TOKEN lives in .env).

Run:  .venv/bin/uvicorn server:app --host 127.0.0.1 --port 8765
Deploy: see README.md (Cloudflare Containers).

The process is meant to live for a long time: it logs in once, keeps pyBYD's MQTT
connection open and feeds a state cache from every push the car sends. `GET /status`
answers from that cache at once; `GET /status?refresh=true` asks the car for a new
report and waits for it. The BYD login happens at startup, and again lazily on the
first request if that failed.
"""

import asyncio
import contextvars
import json
import logging
import os
import secrets
import time
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel
from pybyd import BydApiError, BydClient, BydConfig
from pybyd._state_engine import ProjectionSpec
from pybyd.car import BydCar
from pybyd.models import ClimateStartParams, minutes_to_time_span
from pybyd.models._base import parse_byd_timestamp
from pybyd.models.hvac import HvacOverallStatus
from pybyd.models.realtime import DoorOpenState, LockState, TirePressureUnit, VehicleRealtimeData, WindowState

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("byd-server")

APP_TOKEN = os.environ["APP_TOKEN"]
SKIP_COMMAND_GATE = os.environ.get("BYD_SKIP_COMMAND_GATE", "").lower() in ("1", "true", "yes")
# Ask the car for a report when the cache gets older than this (pushes reset the clock).
POLL_MINUTES = float(os.environ.get("BYD_POLL_MINUTES", "15"))
# How long `?refresh=true` waits for a report newer than the trigger: MQTT first, then HTTP polls.
REFRESH_MQTT_SECONDS = 12.0
REFRESH_POLL_ATTEMPTS = 8
REFRESH_POLL_INTERVAL = 1.5
REFRESH_HARD_CAP = 40.0
# A refresh that lands within this many seconds of fresh data just returns the cache.
REFRESH_MIN_GAP = 5.0
# A command's expected state overlays the cache until the car confirms or contradicts it, at most this long.
PROJECTION_TTL = 120.0

if SKIP_COMMAND_GATE:
    # pyBYD refuses commands that BYD's feature list for the car doesn't advertise, for example
    # trunk and windows on some cars where BYD's data is incomplete. With BYD_SKIP_COMMAND_GATE
    # set, the command is sent anyway and the app reports what BYD answers.
    import pybyd.client as _pybyd_client

    _evaluate_command_gate = _pybyd_client.evaluate_command_gate

    def _permissive_gate(*args, **kwargs):
        verdict = _evaluate_command_gate(*args, **kwargs)
        if verdict.supported:
            return verdict
        return verdict.model_copy(update={"supported": True, "reason": f"bypassed ({verdict.reason})"})

    _pybyd_client.evaluate_command_gate = _permissive_gate


# ---------------------------------------------------------------------------
# Fresh-only realtime reads
# ---------------------------------------------------------------------------
#
# pyBYD's get_vehicle_realtime sends the trigger, then accepts the first payload that
# VehicleRealtimeData.is_ready_raw likes. The trigger's own response is BYD's cached
# snapshot with a non-zero `time`, so without help the MQTT wait and the result polls
# never run. During a refresh this patch makes is_ready_raw reject anything that isn't
# newer than what we already had, so pyBYD keeps waiting for the car's actual report.


class _Refresh:
    def __init__(self, baseline: datetime | None) -> None:
        self.baseline = baseline  # newest car timestamp known before the trigger
        self.seen_trigger = False
        self.rejected = 0


_refresh_ctx: contextvars.ContextVar[_Refresh | None] = contextvars.ContextVar("byd_refresh", default=None)
_is_ready_raw = VehicleRealtimeData.is_ready_raw


def _fresh_only_is_ready_raw(vehicle_info: dict[str, Any]) -> bool:
    ready = _is_ready_raw(vehicle_info)
    ctx = _refresh_ctx.get()
    if ctx is None:
        return ready
    stamp = parse_byd_timestamp(vehicle_info.get("time")) if vehicle_info else None
    if not ctx.seen_trigger:
        # First payload of a refresh is the trigger's response: the pre-trigger snapshot.
        ctx.seen_trigger = True
        if stamp is not None and (ctx.baseline is None or stamp > ctx.baseline):
            ctx.baseline = stamp
        return False
    if not ready:
        return False
    if stamp is None or ctx.baseline is None:
        return True  # nothing to compare against: trust a post-trigger payload
    if stamp > ctx.baseline:
        return True
    ctx.rejected += 1
    return False


VehicleRealtimeData.is_ready_raw = staticmethod(_fresh_only_is_ready_raw)


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------


class State:
    client: BydClient | None = None
    car: BydCar | None = None
    vin: str = ""
    vehicle: Any = None
    lock = asyncio.Lock()  # serialises login and commands
    command_access = False
    # When the server last received realtime data and how (push over MQTT, or a poll).
    received_at: datetime | None = None
    source = "poll"
    fresh_at = 0.0  # monotonic time of the last report newer than what we had
    refresh_task: asyncio.Task | None = None
    poller: asyncio.Task | None = None


state = State()


def utcnow() -> datetime:
    return datetime.now(UTC)


def cache_timestamp() -> datetime | None:
    """The car's own timestamp on the cached realtime data."""
    if state.car is None or state.car.state.realtime is None:
        return None
    return state.car.state.realtime.timestamp


def age_text(stamp: datetime | None) -> str:
    return "unknown age" if stamp is None else f"{(utcnow() - stamp).total_seconds():.0f}s old"


def _on_vehicle_info(vin: str, rt: VehicleRealtimeData) -> None:
    """pyBYD calls this for every MQTT vehicleInfo push, before routing it to the car's state engine."""
    if vin != state.vin:
        return
    current = cache_timestamp()
    if rt.timestamp is not None and current is not None and rt.timestamp < current:
        log.info("Push for %s ignored: older than cache (%s)", vin[-4:], age_text(rt.timestamp))
        return
    state.received_at = utcnow()
    state.source = "push"
    if os.environ.get("BYD_DEBUG_RAW"):
        log.info("Push raw: %s", {k: v for k, v in rt.raw.items() if k in ("time","onlineState","connectState","vehicleState","requestSerial","elecPercent","leftFrontDoorLock","chargeState","timeStamp","updateTime")})
    if rt.timestamp is not None and (current is None or rt.timestamp > current):
        state.fresh_at = time.monotonic()
    log.info(
        "Push: battery=%s locked=%s charging=%s time=%s (%s)",
        rt.elec_percent,
        rt.is_locked,
        rt.is_charging,
        rt.timestamp.isoformat(timespec="seconds") if rt.timestamp else None,
        age_text(rt.timestamp),
    )


def _on_mqtt_event(event: str, vin: str, data: dict[str, Any]) -> None:
    if event != "vehicleInfo":
        log.info("MQTT %s event for %s", event, vin[-4:])


async def ensure_client() -> BydClient:
    """Logs in to BYD on first use (the lifespan does it at startup; this is the fallback)."""
    if state.client is not None:
        return state.client
    async with state.lock:
        if state.client is not None:
            return state.client
        client = BydClient(BydConfig.from_env(), on_vehicle_info=_on_vehicle_info, on_mqtt_event=_on_mqtt_event)
        await client.async_start()
        try:
            vehicles = await client.get_vehicles()
            vehicle = vehicles[0]
            car = await client.get_car(vehicle.vin, vehicle=vehicle, projection_ttl=PROJECTION_TTL)
        except BaseException:
            await client.async_close()
            raise
        state.vehicle = vehicle
        state.vin = vehicle.vin
        state.car = car
        state.client = client
        log.info("Logged in; car %s (%s)", vehicle.model_name, vehicle.vin[-4:])
        return client


async def merge_realtime(rt: VehicleRealtimeData, source: str) -> None:
    """Puts a polled report into the cache unless a push already delivered something as new."""
    assert state.car is not None
    current = cache_timestamp()
    if rt.timestamp is not None and current is not None and rt.timestamp <= current:
        log.info("Poll result not newer than cache (%s), keeping cache", age_text(rt.timestamp))
        return
    # The engine applies pyBYD's zero-drop filters and reconciles projections.
    await state.car._engine.update_realtime(rt)  # noqa: SLF001
    state.received_at = utcnow()
    state.source = source
    if rt.timestamp is not None and (current is None or rt.timestamp > current):
        state.fresh_at = time.monotonic()
    log.info("Poll: battery=%s locked=%s (%s)", rt.elec_percent, rt.is_locked, age_text(rt.timestamp))
    if os.environ.get("BYD_DEBUG_RAW"):
        log.info("Poll raw: %s", {k: v for k, v in rt.raw.items() if k in ("time","onlineState","connectState","vehicleState","requestSerial","elecPercent","leftFrontDoorLock","chargeState","timeStamp","updateTime")})


async def update_hvac() -> None:
    assert state.client is not None and state.car is not None
    try:
        hvac = await state.client.get_hvac_status(state.vin)
    except BydApiError as e:
        log.info("HVAC read failed: %s", e)
        return
    await state.car._engine.update_hvac(hvac)  # noqa: SLF001


async def fetch_cloud_snapshot() -> None:
    """Fills an empty cache with whatever BYD's cloud has, without waiting for the car."""
    client = await ensure_client()
    rt = await client.get_vehicle_realtime(state.vin)
    await merge_realtime(rt, "poll")
    await update_hvac()


async def _refresh(reason: str) -> bool:
    """Triggers a report from the car and waits for data newer than what the cache had.

    Returns True when the cache now holds a newer report than before the trigger.
    """
    client = await ensure_client()
    baseline = cache_timestamp()
    ctx = _Refresh(baseline)
    token = _refresh_ctx.set(ctx)
    started = time.monotonic()
    log.info("Refresh (%s): cache %s", reason, age_text(baseline))
    try:
        rt = await asyncio.wait_for(
            client.get_vehicle_realtime(
                state.vin,
                mqtt_timeout=REFRESH_MQTT_SECONDS,
                poll_attempts=REFRESH_POLL_ATTEMPTS,
                poll_interval=REFRESH_POLL_INTERVAL,
            ),
            REFRESH_HARD_CAP,
        )
    except TimeoutError:
        rt = None
        log.warning("Refresh (%s): no report within %.0fs", reason, REFRESH_HARD_CAP)
    finally:
        _refresh_ctx.reset(token)
    if rt is not None:
        await merge_realtime(rt, "poll")
    await update_hvac()
    now = cache_timestamp()
    fresh = now is not None and (ctx.baseline is None or now > ctx.baseline)
    log.info(
        "Refresh (%s) done in %.1fs: %s, rejected %d old payload(s), data %s",
        reason,
        time.monotonic() - started,
        "new report" if fresh else "nothing newer",
        ctx.rejected,
        age_text(now),
    )
    return fresh


async def refresh_status(reason: str) -> bool:
    """One refresh at a time: callers that arrive while one is running share its result."""
    task = state.refresh_task
    if task is not None and not task.done():
        return await asyncio.shield(task)
    state.refresh_task = asyncio.create_task(_refresh(reason))
    return await asyncio.shield(state.refresh_task)


async def poll_forever() -> None:
    """Keeps the cache from going stale: a refresh at startup, then whenever no data arrived for POLL_MINUTES."""
    while True:
        try:
            if state.received_at is None:
                await refresh_status("startup")
            elif (utcnow() - state.received_at).total_seconds() > POLL_MINUTES * 60:
                await refresh_status("periodic")
        except Exception as e:  # noqa: BLE001
            log.warning("Background refresh failed: %s", e)
        await asyncio.sleep(60)


@asynccontextmanager
async def lifespan(_: FastAPI):
    try:
        await ensure_client()
    except Exception as e:  # noqa: BLE001
        log.warning("Login at startup failed, will retry on the first request: %s", e)
    state.poller = asyncio.create_task(poll_forever())
    yield
    state.poller.cancel()
    if state.client is not None:
        await state.client.async_close()
        state.client = None


app = FastAPI(title="BYD Companion backend", lifespan=lifespan)


def require_token(authorization: str = Header(default="")) -> None:
    expected = f"Bearer {APP_TOKEN}"
    if not secrets.compare_digest(authorization.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="Bad or missing token")


def to_bar(value: float | None, unit: TirePressureUnit | None) -> float | None:
    if value is None:
        return None
    if unit == TirePressureUnit.KPA:
        return round(value / 100, 2)
    if unit == TirePressureUnit.PSI:
        return round(value * 0.0689476, 2)
    return round(value, 2)


def build_status(stale: bool = False) -> dict:
    assert state.car is not None
    snapshot = state.car.state
    rt = snapshot.realtime
    if rt is None:
        raise HTTPException(status_code=503, detail="No data from the car yet")
    hvac = snapshot.hvac
    projected = bool(state.car._engine.active_projections)  # noqa: SLF001

    unit = rt.tire_press_unit
    windows = [rt.left_front_window, rt.right_front_window, rt.left_rear_window, rt.right_rear_window]
    return {
        "model": state.vehicle.model_name,
        "plate": state.vehicle.auto_plate,
        "batteryPercent": rt.elec_percent,
        "rangeTotalKm": rt.endurance_mileage,
        "rangeElectricKm": rt.ev_endurance,
        "rangeFuelKm": rt.oil_endurance,
        "odometerKm": rt.total_mileage,
        "locked": rt.is_locked,
        "trunkOpen": rt.trunk_lid == DoorOpenState.OPEN if rt.trunk_lid is not None else None,
        "windowsOpen": any(w == WindowState.OPEN for w in windows if w is not None),
        "acOn": hvac.is_ac_on if hvac is not None else None,
        "charging": rt.is_charging,
        # For the app's auto-lock: it won't lock a car that is on, moving, or has a door open.
        "powerOn": rt.is_vehicle_on,
        "speedKmh": rt.speed,
        "anyDoorOpen": rt.is_any_door_open,
        "tyresBar": {
            "frontLeft": to_bar(rt.left_front_tire_pressure, unit),
            "frontRight": to_bar(rt.right_front_tire_pressure, unit),
            "rearLeft": to_bar(rt.left_rear_tire_pressure, unit),
            "rearRight": to_bar(rt.right_rear_tire_pressure, unit),
        },
        # When the car produced the data, when this server received it, and how.
        "updatedAt": rt.timestamp.isoformat() if rt.timestamp else None,
        "receivedAt": state.received_at.isoformat() if state.received_at else None,
        "source": "projection" if projected else state.source,
        # True when a refresh was asked for and the car didn't answer with anything newer.
        "stale": stale,
    }


@app.get("/health")
async def health() -> dict:
    """Unauthenticated liveness check (the Cloudflare cron uses it to keep the container awake)."""
    stamp = cache_timestamp()
    return {
        "ok": True,
        "loggedIn": state.client is not None,
        "dataAgeSeconds": round((utcnow() - stamp).total_seconds()) if stamp else None,
    }


@app.get("/status", dependencies=[Depends(require_token)])
async def status(refresh: bool = False) -> dict:
    try:
        if state.car is None or state.car.state.realtime is None:
            await fetch_cloud_snapshot()
            if refresh:
                return build_status(stale=not await refresh_status("request"))
            return build_status()
        if not refresh:
            return build_status()
        if time.monotonic() - state.fresh_at < REFRESH_MIN_GAP:
            return build_status()  # the car reported moments ago
        return build_status(stale=not await refresh_status("request"))
    except BydApiError as e:
        raise HTTPException(status_code=502, detail=f"BYD error {e.code}: {e}") from e


BLE_KEY_FILE = Path(__file__).parent / "ble_key.json"


@app.get("/ble-key", dependencies=[Depends(require_token)])
async def ble_key() -> dict:
    """Hands the Bluetooth key (made by provision_ble_key.py) to the app once, for its Keychain.

    Reads ble_key.json next to this file, or the BLE_KEY_JSON environment variable when hosted.
    """
    if BLE_KEY_FILE.exists():
        record = json.loads(BLE_KEY_FILE.read_text())
    elif os.environ.get("BLE_KEY_JSON"):
        record = json.loads(os.environ["BLE_KEY_JSON"])
    else:
        raise HTTPException(status_code=404, detail="No Bluetooth key yet. Run provision_ble_key.py on the Mac.")
    return {k: record.get(k) for k in ("vin", "macAddress", "dkey", "keyNumber", "keyValidTo")}


class ClimateRequest(BaseModel):
    temperature: float = 21.0
    minutes: int = 20


class NotConfirmed(Exception):
    """BYD accepted the command but never reported it done."""


def _locks(value: LockState) -> list[ProjectionSpec]:
    return [
        ProjectionSpec("realtime", f"{side}_door_lock", value)
        for side in ("left_front", "right_front", "left_rear", "right_rear")
    ]


def _windows(value: WindowState) -> list[ProjectionSpec]:
    return [
        ProjectionSpec("realtime", f"{side}_window", value)
        for side in ("left_front", "right_front", "left_rear", "right_rear")
    ]


# Each command: how to send it, and the state the car should be in once it has taken effect.
COMMANDS: dict[str, tuple[Any, list[ProjectionSpec]]] = {
    "lock": (lambda c, v, _: c.lock(v), _locks(LockState.LOCKED)),
    "unlock": (lambda c, v, _: c.unlock(v), _locks(LockState.UNLOCKED)),
    "trunk_open": (lambda c, v, _: c.open_trunk(v), [ProjectionSpec("realtime", "trunk_lid", DoorOpenState.OPEN)]),
    "trunk_close": (lambda c, v, _: c.close_trunk(v), [ProjectionSpec("realtime", "trunk_lid", DoorOpenState.CLOSED)]),
    "windows_open": (lambda c, v, _: c.open_windows(v), _windows(WindowState.OPEN)),
    "windows_close": (lambda c, v, _: c.close_windows(v), _windows(WindowState.CLOSED)),
    "ac_start": (
        lambda c, v, body: c.start_climate(
            v,
            params=ClimateStartParams(temperature=body.temperature, time_span=minutes_to_time_span(body.minutes)),
        ),
        [ProjectionSpec("hvac", "status", HvacOverallStatus.ON)],
    ),
    "ac_stop": (lambda c, v, _: c.stop_climate(v), [ProjectionSpec("hvac", "status", HvacOverallStatus.OFF)]),
    "honk": (lambda c, v, _: c.find_car(v), []),
}


async def refresh_after_command() -> None:
    await asyncio.sleep(3)  # give the car a moment to act before asking it to report
    try:
        await refresh_status("after command")
    except Exception as e:  # noqa: BLE001
        log.warning("Refresh after command failed: %s", e)


@app.post("/command/{name}", dependencies=[Depends(require_token)])
async def command(name: str, body: ClimateRequest | None = None) -> dict:
    if name not in COMMANDS:
        raise HTTPException(status_code=404, detail=f"Unknown command {name}")
    send, projections = COMMANDS[name]
    client = await ensure_client()
    car = state.car
    assert car is not None
    async with state.lock:
        try:
            if not state.command_access:
                await client.verify_command_access(state.vin)
                state.command_access = True

            async def run() -> None:
                result = await send(client, state.vin, body or ClimateRequest())
                if not result.success:
                    raise NotConfirmed

            # The car's state engine overlays the expected state on the cache while the command
            # runs, drops it if the command fails, and lets the car's next report replace it.
            await car._execute_command(run, projections)  # noqa: SLF001
            success = True
        except NotConfirmed:
            success = False
        except (BydApiError, ValueError) as e:
            # BYD sometimes answers "Service error (1008)" although the car did act: ask it to report.
            asyncio.create_task(refresh_after_command())
            raise HTTPException(status_code=502, detail=str(e)) from e
    log.info("Command %s: %s", name, "confirmed" if success else "not confirmed")
    if name != "honk":
        asyncio.create_task(refresh_after_command())
    return {"command": name, "success": success}
