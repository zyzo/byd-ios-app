"""Small HTTP backend for the BYD Companion iOS app.

Wraps pyBYD so the app never handles BYD credentials or BYD's encryption.
Every request needs `Authorization: Bearer <APP_TOKEN>` (APP_TOKEN lives in .env).

Run:  .venv/bin/uvicorn server:app --host 127.0.0.1 --port 8765
"""

import asyncio
import json
import os
import secrets
import time
from contextlib import asynccontextmanager
from pathlib import Path

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel
from pybyd import BydApiError, BydClient, BydConfig
from pybyd.models import ClimateStartParams, minutes_to_time_span
from pybyd.models.realtime import DoorOpenState, TirePressureUnit, WindowState

load_dotenv()
APP_TOKEN = os.environ["APP_TOKEN"]
STATUS_TTL_SECONDS = 30


class State:
    client: BydClient
    vin: str
    vehicle: object
    lock = asyncio.Lock()
    command_access = False
    status_cache: dict | None = None
    status_at = 0.0


state = State()


@asynccontextmanager
async def lifespan(_: FastAPI):
    async with BydClient(BydConfig.from_env()) as client:
        state.client = client
        vehicles = await client.get_vehicles()
        state.vehicle = vehicles[0]
        state.vin = vehicles[0].vin
        yield


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


async def fetch_status() -> dict:
    client, vin = state.client, state.vin
    rt = await client.get_vehicle_realtime(vin)
    try:
        ac_on = (await client.get_hvac_status(vin)).is_ac_on
    except BydApiError:
        ac_on = None

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
        "acOn": ac_on,
        "charging": rt.is_charging,
        "tyresBar": {
            "frontLeft": to_bar(rt.left_front_tire_pressure, unit),
            "frontRight": to_bar(rt.right_front_tire_pressure, unit),
            "rearLeft": to_bar(rt.left_rear_tire_pressure, unit),
            "rearRight": to_bar(rt.right_rear_tire_pressure, unit),
        },
        "updatedAt": rt.timestamp.isoformat() if rt.timestamp else None,
    }


@app.get("/status", dependencies=[Depends(require_token)])
async def status(refresh: bool = False) -> dict:
    async with state.lock:
        fresh = time.monotonic() - state.status_at < STATUS_TTL_SECONDS
        if state.status_cache is None or refresh or not fresh:
            try:
                state.status_cache = await fetch_status()
            except BydApiError as e:
                raise HTTPException(status_code=502, detail=f"BYD error {e.code}: {e}") from e
            state.status_at = time.monotonic()
        return state.status_cache


BLE_KEY_FILE = Path(__file__).parent / "ble_key.json"


@app.get("/ble-key", dependencies=[Depends(require_token)])
async def ble_key() -> dict:
    """Hands the Bluetooth key (made by provision_ble_key.py) to the app once, for its Keychain."""
    if not BLE_KEY_FILE.exists():
        raise HTTPException(status_code=404, detail="No Bluetooth key yet. Run provision_ble_key.py on the Mac.")
    record = json.loads(BLE_KEY_FILE.read_text())
    return {k: record.get(k) for k in ("vin", "macAddress", "dkey", "keyNumber", "keyValidTo")}


class ClimateRequest(BaseModel):
    temperature: float = 21.0
    minutes: int = 20


COMMANDS = {
    "lock": lambda c, v, _: c.lock(v),
    "unlock": lambda c, v, _: c.unlock(v),
    "trunk_open": lambda c, v, _: c.open_trunk(v),
    "trunk_close": lambda c, v, _: c.close_trunk(v),
    "windows_open": lambda c, v, _: c.open_windows(v),
    "windows_close": lambda c, v, _: c.close_windows(v),
    "ac_start": lambda c, v, body: c.start_climate(
        v,
        params=ClimateStartParams(temperature=body.temperature, time_span=minutes_to_time_span(body.minutes)),
    ),
    "ac_stop": lambda c, v, _: c.stop_climate(v),
    "honk": lambda c, v, _: c.find_car(v),
}


@app.post("/command/{name}", dependencies=[Depends(require_token)])
async def command(name: str, body: ClimateRequest | None = None) -> dict:
    if name not in COMMANDS:
        raise HTTPException(status_code=404, detail=f"Unknown command {name}")
    async with state.lock:
        try:
            if not state.command_access:
                await state.client.verify_command_access(state.vin)
                state.command_access = True
            result = await COMMANDS[name](state.client, state.vin, body or ClimateRequest())
        except (BydApiError, ValueError) as e:
            raise HTTPException(status_code=502, detail=str(e)) from e
        state.status_at = 0.0  # next /status call fetches fresh data
        return {"command": name, "success": bool(result.success)}
