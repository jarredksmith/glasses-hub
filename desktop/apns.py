"""Apple push, sent straight from this PC to Apple, for the Glasses Hub iPhone app.

The iPhone app can only listen to the relay while it is running. With an Apple push key on this PC,
notes also reach it when it is closed: they arrive as ordinary notifications, which the glasses mirror.

Needs an "Apple Push Notifications service" key (.p8) from the Apple Developer account that built the
app. Apple only talks HTTP/2 here, which is what the `httpx` package is for.
"""
import base64
import json
import threading
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

HOST = "https://api.push.apple.com"            # TestFlight and App Store builds use Apple's production service


class PushGone(Exception):
    """Apple says this phone no longer accepts pushes for the app (deleted, or the token changed)."""


def _b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def check_key(pem: str):
    """Raise ValueError unless `pem` is the kind of key Apple issues (.p8: a P-256 private key)."""
    try:
        key = serialization.load_pem_private_key(pem.encode("ascii"), password=None)
    except Exception as e:
        raise ValueError("That file isn't a .p8 key from Apple.") from e
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise ValueError("That key isn't the type Apple push uses.")
    return key


_tokens = {}                # (key_id, team_id) -> (made_at, token); Apple wants these reused, not minted per push
_lock = threading.Lock()
_client = None


def provider_token(pem: str, key_id: str, team_id: str, now: float = None) -> str:
    """The signed token that tells Apple which developer account is sending (ES256 JWT, good for an hour)."""
    now = time.time() if now is None else now
    with _lock:
        made = _tokens.get((key_id, team_id))
        if made and now - made[0] < 45 * 60:
            return made[1]
        head = _b64u(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
        body = _b64u(json.dumps({"iss": team_id, "iat": int(now)}, separators=(",", ":")).encode())
        der = check_key(pem).sign(f"{head}.{body}".encode("ascii"), ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        token = f"{head}.{body}.{_b64u(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"
        _tokens[(key_id, team_id)] = (now, token)
        return token


def payload(title: str, body: str) -> dict:
    return {"aps": {"alert": {"title": title or " ", "body": body or ""}, "sound": "default"}}


def send(device_token: str, title: str, body: str, *, pem: str, key_id: str, team_id: str, topic: str,
         tag: str = None, ttl: int = 3600):
    """Send one notification. Raises PushGone if the phone should be forgotten, RuntimeError otherwise."""
    global _client
    try:
        import httpx
    except ImportError as e:
        raise RuntimeError("Apple push needs one more package. Run setup.bat again to install it.") from e
    headers = {
        "authorization": "bearer " + provider_token(pem, key_id, team_id),
        "apns-topic": topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": str(int(time.time()) + int(ttl)),
    }
    if tag:
        headers["apns-collapse-id"] = tag.encode("utf-8")[:64].decode("utf-8", "ignore")
    with _lock:
        if _client is None:
            _client = httpx.Client(http2=True, timeout=15)
        client = _client
    try:
        r = client.post(f"{HOST}/3/device/{device_token}", json=payload(title, body), headers=headers)
    except Exception as e:
        with _lock:
            _client = None                      # a stale connection; the next push opens a new one
        raise RuntimeError(f"Couldn't reach Apple: {e}") from e
    if r.status_code == 200:
        return
    try:
        reason = r.json().get("reason", "")
    except Exception:
        reason = ""
    if r.status_code == 410 or reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"):
        raise PushGone(reason or str(r.status_code))
    if reason in ("InvalidProviderToken", "ExpiredProviderToken"):
        with _lock:
            _tokens.clear()
        raise RuntimeError("Apple didn't accept the push key. Check the Key ID matches the .p8 file "
                           "and that the key has Apple Push Notifications turned on.")
    raise RuntimeError(f"Apple refused the push ({r.status_code} {reason}).")
