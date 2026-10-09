"""Standard Web Push, sent straight from this PC to Apple's (or Google's/Mozilla's) push service.

No server of our own is involved:
  - VAPID (RFC 8292) proves the pushes come from this PC's key, which the phone subscribed with.
  - The message is end-to-end encrypted for the phone (RFC 8291, aes128gcm), so the push service
    can't read it.
Only the `cryptography` package is needed.
"""
import base64
import hashlib
import hmac
import json
import os
import struct
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def unb64u(text: str) -> bytes:
    text = text.strip()
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _hmac(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def _raw_public(pub) -> bytes:
    return pub.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


# ------------------------------------------------------------------ VAPID keys
def new_vapid_key() -> str:
    """A new P-256 private key, as PEM text (kept only on this PC)."""
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption()).decode("ascii")


def load_vapid(pem: str):
    return serialization.load_pem_private_key(pem.encode("ascii"), password=None)


def vapid_public(pem: str) -> str:
    """The public half, base64url, as the phone needs it for pushManager.subscribe()."""
    return b64u(_raw_public(load_vapid(pem).public_key()))


def vapid_header(pem: str, endpoint: str, subject: str) -> str:
    key = load_vapid(pem)
    u = urllib.parse.urlsplit(endpoint)
    claims = {"aud": f"{u.scheme}://{u.netloc}", "exp": int(time.time()) + 3600, "sub": subject}
    head = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}, separators=(",", ":")).encode())
    body = b64u(json.dumps(claims, separators=(",", ":")).encode())
    signing_input = f"{head}.{body}".encode("ascii")
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")       # JWT wants raw r||s, not DER
    token = f"{head}.{body}.{b64u(sig)}"
    return f"vapid t={token}, k={b64u(_raw_public(key.public_key()))}"


# ------------------------------------------------------------------ RFC 8291 encryption
def encrypt(payload: bytes, p256dh: str, auth: str, salt: bytes = None, server_key=None) -> bytes:
    ua_public = unb64u(p256dh)
    auth_secret = unb64u(auth)
    server_key = server_key or ec.generate_private_key(ec.SECP256R1())
    as_public = _raw_public(server_key.public_key())
    ua_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_public)
    ecdh_secret = server_key.exchange(ec.ECDH(), ua_key)

    prk_key = _hmac(auth_secret, ecdh_secret)
    ikm = _hmac(prk_key, b"WebPush: info\x00" + ua_public + as_public + b"\x01")
    salt = salt or os.urandom(16)
    prk = _hmac(salt, ikm)
    cek = _hmac(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
    nonce = _hmac(prk, b"Content-Encoding: nonce\x00\x01")[:12]

    ciphertext = AESGCM(cek).encrypt(nonce, payload + b"\x02", None)   # 0x02 = last (only) record
    rs = 4096
    header = salt + struct.pack("!I", rs) + bytes([len(as_public)]) + as_public
    return header + ciphertext


def decrypt(body: bytes, ua_private, auth: str) -> bytes:
    """The phone's side of RFC 8291. Only used by the self-test."""
    salt, rs, idlen = body[:16], struct.unpack("!I", body[16:20])[0], body[20]
    as_public = body[21:21 + idlen]
    ciphertext = body[21 + idlen:]
    ua_public = _raw_public(ua_private.public_key())
    as_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_public)
    ecdh_secret = ua_private.exchange(ec.ECDH(), as_key)
    prk_key = _hmac(unb64u(auth), ecdh_secret)
    ikm = _hmac(prk_key, b"WebPush: info\x00" + ua_public + as_public + b"\x01")
    prk = _hmac(salt, ikm)
    cek = _hmac(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
    nonce = _hmac(prk, b"Content-Encoding: nonce\x00\x01")[:12]
    plain = AESGCM(cek).decrypt(nonce, ciphertext, None)
    return plain.rstrip(b"\x00")[:-1]          # drop padding and the 0x02 delimiter


# ------------------------------------------------------------------ sending
class PushGone(Exception):
    """The phone's subscription no longer exists (app deleted, notifications turned off)."""


def send(subscription: dict, data: dict, vapid_pem: str, subject: str,
         ttl: int = 3600, urgency: str = "high", topic: str = None, timeout: int = 20) -> int:
    endpoint = subscription["endpoint"]
    keys = subscription.get("keys") or {}
    body = encrypt(json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
                   keys["p256dh"], keys["auth"])
    headers = {
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        "TTL": str(int(ttl)),
        "Urgency": urgency,
        "Authorization": vapid_header(vapid_pem, endpoint, subject),
    }
    if topic:
        headers["Topic"] = topic[:32]
    req = urllib.request.Request(endpoint, data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        if e.code in (404, 410):
            raise PushGone(f"HTTP {e.code} {detail}".strip()) from None
        raise RuntimeError(f"push service said HTTP {e.code} {detail}".strip()) from None
