"""Get a BYD Bluetooth key (dkey) for direct BLE control, using BYD's watch-key API.

Flow (ported from https://github.com/PoorGrammerA/BydBleAutoLock, MIT licence):
  1. create a watch QR code            -> you scan it with the official BYD app
  2. poll until the BYD app approves it
  3. exchange it for a watch session token
  4. fetch vehicle info, incl. the car's BLE MAC and the dkey
  5. fetch the Bluetooth key record (key number)

The result is written to ble_key.json (private, gitignored). It is a car key:
never share or commit it.

Usage:  .venv/bin/python provision_ble_key.py            full flow
        .venv/bin/python provision_ble_key.py --resume   reuse the saved watch token (no new scan)
        .venv/bin/python provision_ble_key.py --check    only test that the API answers
"""

import hashlib
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

import httpx
import qrcode
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad
from dotenv import load_dotenv

# Region settings come from the same .env as server.py (see .env.example).
load_dotenv()
BASE_URL = os.environ.get("BYD_BASE_URL", "https://dilinkappoversea-eu.byd.auto").rstrip("/")
# The watch API uses BYD's own country keys, which differ from ISO codes for a few countries.
_WATCH_ALIASES = {"VN": "VNM", "BN": "BRN", "UK": "GB"}
_country = os.environ.get("BYD_COUNTRY_CODE", "NL").strip().upper()
COUNTRY_CODE = os.environ.get("BYD_WATCH_COUNTRY_CODE") or _WATCH_ALIASES.get(_country, _country)
LANGUAGE = os.environ.get("BYD_WATCH_LANGUAGE") or os.environ.get("BYD_LANGUAGE", "en")
TIME_ZONE = os.environ.get("BYD_TIME_ZONE", "Europe/Amsterdam")

WATCH_MODEL = "SM-R925N"
WATCH_BRAND = "SAMSUNG"
WATCH_APP_VERSION = "341"

HERE = Path(__file__).parent
KEY_FILE = HERE / "ble_key.json"
DEVICE_FILE = HERE / ".watch_device_id"
TOKEN_FILE = HERE / ".watch_token.json"
QR_FILE = HERE / "watch_qr.png"


# ── crypto helpers (match the official watch app) ──────────────────────────

def md5_hex(value: str) -> str:
    return hashlib.md5(value.encode()).hexdigest().upper()


def sha1_mixed(value: str) -> str:
    """SHA-1 where each byte is unpadded hex, upper-case at even indexes, lower at odd."""
    digest = hashlib.sha1(value.encode()).digest()
    return "".join(format(b, "x").upper() if i % 2 == 0 else format(b, "x") for i, b in enumerate(digest))


def aes_encrypt_hex(plaintext: str, key_hex: str) -> str:
    cipher = AES.new(bytes.fromhex(key_hex), AES.MODE_CBC, iv=bytes(16))
    return cipher.encrypt(pad(plaintext.encode(), 16)).hex().upper()


def aes_decrypt(cipher_hex: str, key_hex: str) -> str:
    cipher = AES.new(bytes.fromhex(key_hex), AES.MODE_CBC, iv=bytes(16))
    return unpad(cipher.decrypt(bytes.fromhex(cipher_hex)), 16).decode()


def compact_json(fields: dict) -> str:
    return json.dumps(fields, separators=(",", ":"), ensure_ascii=False)


def sign(fields: dict, secret: str) -> str:
    parts = "".join(f"{k}={fields[k] or ''}&" for k in sorted(fields) if k)
    return sha1_mixed(parts + "password=" + md5_hex(secret))


def random_id() -> str:
    return uuid.uuid4().hex.upper()


def watch_imei() -> str:
    """A stable fake watch identifier for this Mac, kept between runs."""
    if DEVICE_FILE.exists():
        return DEVICE_FILE.read_text().strip()
    value = md5_hex(random_id())
    DEVICE_FILE.write_text(value)
    os.chmod(DEVICE_FILE, 0o600)
    return value


# ── requests ───────────────────────────────────────────────────────────────

class WatchApiError(Exception):
    pass


class WatchApi:
    def __init__(self) -> None:
        self.http = httpx.Client(timeout=20, headers={"User-Agent": "okhttp/4.12.0"})
        self.imei = watch_imei()
        self.time_offset_ms = 0

    def _now(self) -> str:
        return str(int(time.time() * 1000) + self.time_offset_ms)

    def _common_outer(self, ts: str) -> dict:
        return {
            "watchModel": WATCH_MODEL,
            "watchName": WATCH_BRAND + WATCH_MODEL,
            "watchBrand": WATCH_BRAND,
            "watchAppVersion": WATCH_APP_VERSION,
            "watchOs": "0",
            "reqTimestamp": ts,
            "language": LANGUAGE,
            "countryCode": COUNTRY_CODE,
        }

    def _post(self, endpoint: str, body: dict, decrypt_key: str):
        resp = self.http.post(f"{BASE_URL}/{endpoint}", content=compact_json(body),
                              headers={"Content-Type": "application/json; charset=UTF-8"})
        resp.raise_for_status()
        outer = resp.json()
        envelope = json.loads(outer.get("response") or outer.get("respondData") or "{}")
        if str(envelope.get("code")) != "0":
            raise WatchApiError(f"{endpoint}: code={envelope.get('code')} message={envelope.get('message')}")
        data = envelope.get("respondData") or envelope.get("response")
        return json.loads(aes_decrypt(data, md5_hex(decrypt_key))) if data else None

    def unlogin(self, endpoint: str, inner: dict):
        ts = inner["timeStamp"]
        encry = aes_encrypt_hex(compact_json(dict(sorted(inner.items()))), md5_hex(COUNTRY_CODE))
        signed = {**inner, **self._common_outer(ts), "identifier": COUNTRY_CODE, "watchImei": self.imei}
        body = {
            "countryCode": COUNTRY_CODE,
            "encryData": encry,
            "identifier": COUNTRY_CODE,
            "language": LANGUAGE,
            "reqTimestamp": ts,
            "sign": sign(signed, COUNTRY_CODE),
            "watchAppVersion": WATCH_APP_VERSION,
            "watchBrand": WATCH_BRAND,
            "watchImei": self.imei,
            "watchModel": WATCH_MODEL,
            "watchName": WATCH_BRAND + WATCH_MODEL,
            "watchOs": "0",
        }
        return self._post(endpoint, body, COUNTRY_CODE)

    def login(self, endpoint: str, token: dict, extra: dict):
        ts = self._now()
        inner = {"timeStamp": ts, "random": random_id(), "watchImei": self.imei,
                 "deviceType": "0", "networkType": "wifi", **extra}
        encry = aes_encrypt_hex(compact_json(dict(sorted(inner.items()))), md5_hex(token["encryToken"]))
        # Signed-in requests identify the account by its userId.
        identifier = token.get("identifier") or token.get("userId") or COUNTRY_CODE
        user_type = token.get("userType") or ""
        signed = {**inner, **self._common_outer(ts), "identifier": identifier, "userType": user_type}
        body = {
            "identifier": identifier,
            "watchImei": self.imei,
            **self._common_outer(ts),
            "userType": user_type,
            "encryData": encry,
            "sign": sign(signed, token["signToken"]),
        }
        return self._post(endpoint, body, token["encryToken"])

    def basic(self) -> dict:
        return {"timeStamp": self._now(), "random": random_id(), "networkType": "wifi", "version": WATCH_APP_VERSION}

    # Steps
    def sync_time(self) -> None:
        # Not offered on every regional server (Vietnam answers 1007); local time is fine then.
        try:
            data = self.unlogin("watch/login/getServerCurrentTime", self.basic())
        except WatchApiError:
            return
        server_ms = data.get("serverTime") if isinstance(data, dict) else data
        if server_ms:
            self.time_offset_ms = int(server_ms) - int(time.time() * 1000)

    def create_qr(self) -> str:
        return self.unlogin("watch/login/create/qrcode", self.basic())["uuid"]

    def qr_status(self, qr_uuid: str) -> tuple[str, dict]:
        data = self.unlogin("watch/login/check/qrcode", {**self.basic(), "uuid": qr_uuid})
        if not isinstance(data, dict):
            data = {"_raw": data}
        status = next((data[k] for k in ("codeStatus", "qrCodeStatus", "status", "qrStatus") if k in data), None)
        return str(status), data

    def gain_token(self, qr_uuid: str) -> dict:
        data = self.unlogin("watch/login/gain/token", {"timeStamp": self._now(), "uuid": qr_uuid, "timeZone": TIME_ZONE})
        token = data["watchTokenInfo"]
        return token

    def qr_content(self, qr_uuid: str) -> str:
        plain = f"watchImei={self.imei}&uuid={qr_uuid}&countryCode={COUNTRY_CODE}"
        return "watchQRCode://" + aes_encrypt_hex(plain, md5_hex("watch.bydautolink"))


# ── main flow ──────────────────────────────────────────────────────────────

def main() -> None:
    api = WatchApi()
    api.sync_time()
    qr_uuid = api.create_qr()
    print(f"✓ BYD watch-key API answered at {BASE_URL} (country {COUNTRY_CODE}, QR created).")
    if "--check" in sys.argv:
        return

    if "--resume" in sys.argv and TOKEN_FILE.exists():
        fetch_key(api, json.loads(TOKEN_FILE.read_text()))
        return

    qrcode.make(api.qr_content(qr_uuid)).save(QR_FILE)
    subprocess.run(["open", str(QR_FILE)], check=False)
    print("\nScan the QR code that just opened with the official BYD app on your phone")
    print("(look for a scan icon, often top-right on the home screen), then approve it.")
    print("Waiting up to 5 minutes…")

    deadline = time.time() + 300
    last = None
    while True:
        status, raw = api.qr_status(qr_uuid)
        shown = {k: (v if len(str(v)) <= 24 else str(v)[:6] + "…") for k, v in raw.items()}
        if (status, str(shown)) != last:
            print(f"  QR status: {status}   raw: {shown}", flush=True)
            last = (status, str(shown))
        if status == "2":
            break
        if status in ("3", "4"):
            sys.exit(f"QR was rejected or expired (status {status}). Run the script again.")
        if time.time() > deadline:
            sys.exit("Timed out waiting for approval. Run the script again.")
        time.sleep(3)
    QR_FILE.unlink(missing_ok=True)
    print("✓ Approved in the BYD app.")

    token = api.gain_token(qr_uuid)
    TOKEN_FILE.write_text(json.dumps(token))
    os.chmod(TOKEN_FILE, 0o600)
    fetch_key(api, token)


def fetch_key(api: WatchApi, token: dict) -> None:
    vin = token["vin"]
    vehicle = api.login("watch/login/gain/vehicle", token, {"appVersion": "2", "vin": vin})
    bt_dto = ((vehicle or {}).get("cfVechicle") or {}).get("watchBluetoothDto") or {}
    bt_info = bt_dto.get("watchBluetoothInfo") or {}
    try:
        bt_key = api.login("watch/login/gain/bluetooth", token, {"appVersion": "2", "vin": vin}) or {}
    except WatchApiError as e:
        print(f"  (gain/bluetooth failed, using vehicle info only: {e})")
        bt_key = {}

    dkey = bt_key.get("dk") or bt_info.get("dkey")
    key_number = bt_key.get("empowerBluetoothKeyNo", bt_info.get("keyNumber", 0))
    if not dkey:
        print("\n✗ BYD returned no Bluetooth key (dkey) for this car/account.")
        print("  Bluetooth Key is probably not enabled for your car or region in the BYD app.")
        print("  Fields returned for watchBluetoothDto:", sorted(bt_dto.keys()))
        sys.exit(1)

    record = {
        "vin": vin,
        "macAddress": bt_dto.get("macAddress") or bt_key.get("bluetoothMacAddress"),
        "dkey": dkey,
        "keyNumber": int(key_number or 0),
        "keyValidTo": bt_info.get("keyValidTo"),
        "functionCodes": bt_dto.get("functionCode"),
        "createdAt": int(time.time()),
    }
    KEY_FILE.write_text(json.dumps(record, indent=2))
    os.chmod(KEY_FILE, 0o600)
    print(f"\n✓ Bluetooth key saved to {KEY_FILE.name} (private). Key number {record['keyNumber']}, "
          f"car BLE address {'present' if record['macAddress'] else 'missing'}.")


if __name__ == "__main__":
    try:
        main()
    except WatchApiError as e:
        sys.exit(f"BYD watch API error: {e}")
