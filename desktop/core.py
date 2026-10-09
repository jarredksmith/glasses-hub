"""Glasses Hub engine: pairing with the phone, delivery (Web Push, or the relay as a fallback),
fitting text to the glasses, quiet hours, the local "send" address, and a small Claude helper.

Phone <-> PC messages go through a relay (ntfy.sh), encrypted with a key derived from the pairing
code. Notes themselves go by Web Push straight from this PC to Apple's push service, encrypted for
the phone, so they arrive even when the phone app is closed and the screen is locked.
"""
import base64
import hashlib
import http.server
import json
import logging
import os
import queue
import re
import secrets
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

import webpush

log = logging.getLogger("glasseshub")

APP_DIR = Path(__file__).resolve().parent
ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
DEFAULT_APP_URL = "https://jarredksmith.github.io/glasses-hub/"
DEFAULT_RELAY = "https://ntfy.sh"
USER_AGENT = "GlassesHub/1.0 (+https://github.com/jarredksmith/glasses-hub)"


def data_dir() -> Path:
    """Machine-local folder (not synced by OneDrive) for settings, keys and logs."""
    base = os.environ.get("LOCALAPPDATA") or str(Path.home() / ".local" / "share")
    d = Path(base) / "GlassesHub"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ------------------------------------------------------------------ pairing code and relay crypto
def new_code() -> str:
    raw = "".join(secrets.choice(ALPHABET) for _ in range(16))     # 80 bits
    return "-".join(raw[i:i + 4] for i in range(0, 16, 4))


def normalize(code: str) -> str:
    return "".join(ch for ch in (code or "").upper() if ch in ALPHABET)


def derive(code: str):
    """-> (PC-to-phone channel, phone-to-PC channel, 32-byte key). Must match the phone app."""
    c = normalize(code)
    h = hashlib.sha256(("glasseshub-channel:" + c).encode()).hexdigest()[:24]
    key = hashlib.sha256(("glasseshub-key:" + c).encode()).digest()
    return f"gh-{h}", f"gh-{h}-up", key


def encrypt(key: bytes, obj) -> str:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    iv = os.urandom(12)
    ct = AESGCM(key).encrypt(iv, json.dumps(obj, ensure_ascii=False).encode("utf-8"), None)
    return base64.b64encode(iv + ct).decode("ascii")


def decrypt(key: bytes, text: str):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    raw = base64.b64decode(text)
    return json.loads(AESGCM(key).decrypt(raw[:12], raw[12:], None).decode("utf-8"))


# ------------------------------------------------------------------ fitting text to the glasses
_SPACES = re.compile(r"\s+")


def clean(text) -> str:
    return _SPACES.sub(" ", str(text or "")).strip()


def take(text: str, width: int):
    """Longest start of `text` that fits `width`, broken at a space when possible -> (line, rest)."""
    text = text.strip()
    if len(text) <= width:
        return text, ""
    cut = text.rfind(" ", 0, width + 1)
    if cut < width * 0.5:            # one very long word: hard cut
        cut = width
    return text[:cut].rstrip(), text[cut:].strip()


def ellipsize(line: str, width: int) -> str:
    line = line.rstrip(" .,;:")
    if len(line) + 1 > width:
        line, _ = take(line, width - 1)
        line = line.rstrip(" .,;:")
    return line + "…"


def fit(title, body, tw: int = 70, bw: int = 70, max_parts: int = 2):
    """Split a note into at most `max_parts` notifications of (title line, body line).

    The glasses show one line of title and one line of body per notification. Text that doesn't fit
    flows on into the next notification; anything past the last one ends with an ellipsis.
    """
    title, body = clean(title), clean(body)
    if not title:
        title, body = take(body, tw)
    t1, title_rest = take(title, tw)
    stream = clean(f"{title_rest} {body}")
    b1, stream = take(stream, bw)
    parts = [[t1, b1]]
    while stream and len(parts) < max_parts:
        t, stream = take(stream, tw)
        b, stream = take(stream, bw)
        parts.append([t, b])
    if stream:
        last = parts[-1]
        if last[1]:
            last[1] = ellipsize(last[1], bw)
        else:
            last[0] = ellipsize(last[0], tw)
    return [tuple(p) for p in parts]


# ------------------------------------------------------------------ small helpers
def http_json(url: str, timeout: int = 20, headers: dict = None):
    req = urllib.request.Request(url, headers=dict({"User-Agent": USER_AGENT, "Accept": "application/json"},
                                                   **(headers or {})))
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def parse_hhmm(text: str, default: str):
    try:
        h, m = (text or default).strip().split(":")
        return int(h) % 24, int(m) % 60
    except Exception:
        h, m = default.split(":")
        return int(h), int(m)


def in_window(start: str, end: str, now: datetime = None) -> bool:
    """True when `now` is between start and end ("HH:MM"), handling windows that cross midnight."""
    now = now or datetime.now()
    s = parse_hhmm(start, "00:00")
    e = parse_hhmm(end, "00:00")
    cur = (now.hour, now.minute)
    if s == e:
        return True
    if s < e:
        return s <= cur < e
    return cur >= s or cur < e


def get_api_key() -> str:
    """Claude key: env var, this app's own key file, or CallPilot's (same PC), in that order."""
    k = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if k:
        return k
    for f in (data_dir() / "api_key.txt", data_dir().parent / "CallPilot" / "api_key.txt"):
        try:
            if f.exists():
                k = f.read_text(encoding="utf-8").strip()
                if k:
                    return k
        except Exception:
            pass
    return ""


def save_api_key(key: str):
    (data_dir() / "api_key.txt").write_text(key.strip(), encoding="utf-8")


class Claude:
    """Minimal Claude client over HTTPS (no extra packages)."""
    URL = "https://api.anthropic.com/v1/messages"

    def __init__(self, hub):
        self.hub = hub

    @staticmethod
    def _extra(model: str) -> dict:
        m = model.lower()
        if "sonnet-5-5" in m:
            return {"thinking": {"type": "between_tools"}}
        if any(k in m for k in ("opus-5-5", "fable", "mythos")):
            return {"output_config": {"effort": "low"}}
        return {"thinking": {"type": "disabled"}}

    def _post(self, body: dict, key: str, timeout=90):
        req = urllib.request.Request(self.URL, data=json.dumps(body).encode("utf-8"), method="POST", headers={
            "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))

    def _models(self, key: str):
        req = urllib.request.Request("https://api.anthropic.com/v1/models?limit=50",
                                     headers={"x-api-key": key, "anthropic-version": "2023-06-01"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return [m["id"] for m in json.loads(r.read().decode("utf-8")).get("data", [])]

    def ask(self, system: str, prompt: str, max_tokens: int = 2000) -> str:
        key = get_api_key()
        if not key:
            raise RuntimeError("No Claude API key yet (Settings → Claude key).")
        model = self.hub.cfg.get("claude_model") or "claude-sonnet-5-5"
        body = dict({"model": model, "max_tokens": max_tokens, "system": system,
                     "messages": [{"role": "user", "content": prompt}]}, **self._extra(model))
        try:
            resp = self._post(body, key)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:400]
            if e.code == 404:                               # model retired: pick another one
                ids = self._models(key)
                pick = next((i for fam in ("sonnet", "opus", "haiku") for i in ids if fam in i), ids[0] if ids else model)
                log.warning("model %s not found; using %s", model, pick)
                self.hub.cfg["claude_model"] = pick
                self.hub.save()
                body.update({"model": pick})
                body.pop("thinking", None)
                body.pop("output_config", None)
                body.update(self._extra(pick))
                resp = self._post(body, key)
            elif e.code == 400 and any(w in detail for w in ("thinking", "effort", "output_config")):
                body.pop("thinking", None)
                body.pop("output_config", None)
                body["max_tokens"] = max(max_tokens, 8000)
                resp = self._post(body, key)
            else:
                raise RuntimeError(f"Claude said HTTP {e.code}: {detail}") from None
        text = "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text").strip()
        if not text:
            raise RuntimeError(f"Claude returned no text (stop reason: {resp.get('stop_reason')})")
        return text

    def ask_json(self, system: str, prompt: str, max_tokens: int = 2000):
        text = self.ask(system, prompt, max_tokens)
        m = re.search(r"[\[{].*[\]}]", text, re.S)
        if not m:
            raise RuntimeError("Claude's reply wasn't JSON")
        return json.loads(m.group(0))


# ------------------------------------------------------------------ the hub
DEFAULTS = {
    "code": "",
    "vapid_pem": "",
    "app_url": DEFAULT_APP_URL,
    "relay": DEFAULT_RELAY,
    "devices": {},
    "quiet_on": True,
    "quiet_start": "22:00",
    "quiet_end": "07:00",
    "gap_seconds": 5,
    "max_per_hour": 40,
    "claude_model": "claude-sonnet-5-5",
    "send_port": 8770,
    "send_key": "",
    "plugins": {},
}


class Hub:
    def __init__(self, on_event=None):
        self.path = data_dir() / "config.json"
        self.lock = threading.RLock()
        self.cfg = self._load()
        self.on_event = on_event or (lambda kind, text: None)     # UI callback: ("log"|"devices"|"status"|"sent", text)
        self.q = queue.Queue()
        self.running = False
        self.plugins = {}
        self.history = []                 # recent deliveries, newest last
        self._sent_times = []
        self._last_push_at = 0.0
        self._seen = set()
        self.relay_ok = False
        self.http = None
        self.claude = Claude(self)
        changed = False
        if not self.cfg.get("code"):
            self.cfg["code"] = new_code()
            changed = True
        if not self.cfg.get("vapid_pem"):
            self.cfg["vapid_pem"] = webpush.new_vapid_key()
            changed = True
        if not self.cfg.get("send_key"):
            self.cfg["send_key"] = secrets.token_hex(8)
            changed = True
        if changed:
            self.save()
        self._derive()

    # ---------------------------------------------------------- settings
    def _load(self) -> dict:
        cfg = json.loads(json.dumps(DEFAULTS))
        try:
            if self.path.exists():
                cfg.update(json.loads(self.path.read_text(encoding="utf-8")))
        except Exception as e:
            log.error("couldn't read settings: %s", e)
        return cfg

    def save(self):
        with self.lock:
            for _ in range(3):
                try:
                    text = json.dumps(self.cfg, indent=2)
                    break
                except RuntimeError:          # another thread changed a setting mid-save; try again
                    time.sleep(0.05)
            else:
                return
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(text, encoding="utf-8")
            os.replace(tmp, self.path)

    def _derive(self):
        self.down, self.up, self.key = derive(self.cfg["code"])

    @property
    def vapid_public(self) -> str:
        return webpush.vapid_public(self.cfg["vapid_pem"])

    def new_pairing(self):
        """New code and new push key: every phone has to pair again."""
        self.cfg["code"] = new_code()
        self.cfg["vapid_pem"] = webpush.new_vapid_key()
        self.cfg["devices"] = {}
        self.save()
        self._derive()
        self._restart_listener()
        self.event("devices", "")
        self.event("log", "New pairing code made. Pair your phone again with the new code.")

    def plugin_cfg(self, pid: str, defaults: dict) -> dict:
        p = self.cfg["plugins"].setdefault(pid, {})
        for k, v in defaults.items():
            p.setdefault(k, json.loads(json.dumps(v)))
        return p

    def event(self, kind: str, text: str):
        if kind == "log":
            log.info(text)
        try:
            self.on_event(kind, text)
        except Exception:
            pass

    # ---------------------------------------------------------- lifecycle
    def add_plugin(self, plugin):
        self.plugins[plugin.id] = plugin

    def start(self):
        self.running = True
        threading.Thread(target=self._send_loop, name="send", daemon=True).start()
        self._restart_listener()
        for p in self.plugins.values():
            p.start()
        self._start_http()

    def stop(self):
        self.running = False
        for p in self.plugins.values():
            p.stop()
        if self.http:
            try:
                self.http.shutdown()
            except Exception:
                pass

    # ---------------------------------------------------------- delivery
    def quiet_now(self) -> bool:
        return bool(self.cfg.get("quiet_on")) and in_window(self.cfg.get("quiet_start"), self.cfg.get("quiet_end"))

    def deliver(self, title: str, body: str = "", source: str = "hub", manual: bool = False,
                tag: str = None, ttl: int = 3600, to: str = None, max_parts: int = 2) -> bool:
        """Queue a note for the phone(s). Automatic notes respect quiet hours and the hourly cap."""
        title, body = clean(title), clean(body)
        if not (title or body):
            return False
        if not manual:
            if self.quiet_now():
                self.event("log", f"[{source}] held back (quiet hours): {title}")
                return False
            now = time.time()
            self._sent_times = [t for t in self._sent_times if now - t < 3600]
            if len(self._sent_times) >= int(self.cfg.get("max_per_hour") or 40):
                self.event("log", f"[{source}] skipped (hourly limit reached): {title}")
                return False
            self._sent_times.append(now)
        if not self.cfg["devices"]:
            self.event("log", f"[{source}] no phone paired yet: {title}")
            return False
        self.q.put({"title": title, "body": body, "source": source, "tag": tag or f"{source}-{int(time.time()*1000)}",
                    "ttl": ttl, "to": to, "max_parts": max_parts, "t": time.time()})
        return True

    def _send_loop(self):
        while self.running:
            try:
                item = self.q.get(timeout=1)
            except queue.Empty:
                continue
            try:
                self._send_item(item)
            except Exception as e:
                log.exception("delivery failed")
                self.event("log", f"Couldn't deliver: {e}")

    def _wait_gap(self):
        gap = float(self.cfg.get("gap_seconds") or 5)
        wait = self._last_push_at + gap - time.time()
        if wait > 0:
            time.sleep(wait)

    def _send_item(self, item):
        devices = dict(self.cfg["devices"])
        if item.get("to"):
            devices = {k: v for k, v in devices.items() if k == item["to"]}
        push_devs = {k: v for k, v in devices.items() if v.get("sub")}
        relay_devs = {k: v for k, v in devices.items() if not v.get("sub")}
        # one layout per width setting (usually just one)
        widths = {}
        for did, d in push_devs.items():
            w = tuple(d.get("widths") or (70, 70))
            widths.setdefault(w, []).append(did)
        shown = None
        for (tw, bw), ids in widths.items():
            parts = fit(item["title"], item["body"], tw, bw, item["max_parts"])
            shown = shown or parts
            for i, (t, b) in enumerate(parts):
                self._wait_gap()
                for did in ids:
                    self._push(did, t, b, item, i, len(parts))
                self._last_push_at = time.time()
        if relay_devs:
            tw = min(int((d.get("widths") or (70, 70))[0]) for d in relay_devs.values())
            bw = min(int((d.get("widths") or (70, 70))[1]) for d in relay_devs.values())
            parts = fit(item["title"], item["body"], tw, bw, item["max_parts"])
            shown = shown or parts
            for i, (t, b) in enumerate(parts):
                self._wait_gap()
                self.relay_post({"type": "note", "title": t, "body": b, "source": item["source"],
                                 "tag": f'{item["tag"]}-{i}', "t": time.time(), "to": item.get("to")})
                self._last_push_at = time.time()
        if shown:
            entry = {"t": item["t"], "source": item["source"], "parts": shown}
            self.history.append(entry)
            self.history = self.history[-200:]
            self.event("sent", json.dumps(entry))

    def _push(self, did, title, body, item, i, n):
        dev = self.cfg["devices"].get(did)
        if not dev or not dev.get("sub"):
            return
        nav = self.cfg.get("app_url") or DEFAULT_APP_URL
        data = {
            "web_push": 8030,                       # Declarative Web Push (iOS 18.4+); older systems use the service worker
            "notification": {"title": title or " ", "body": body, "navigate": nav, "silent": False,
                             "tag": f'{item["tag"]}-{i}'},
            "mutable": True,                        # let the app's service worker log it in its history first
            "gh": {"source": item["source"], "part": i + 1, "of": n, "t": time.time()},
        }
        try:
            webpush.send(dev["sub"], data, self.cfg["vapid_pem"], subject=nav, ttl=item["ttl"])
            dev["last_ok"] = time.time()
            dev.pop("last_error", None)
        except webpush.PushGone as e:
            self.event("log", f'{dev.get("name","Phone")} stopped accepting notifications ({e}). '
                              "Open Glasses Hub on the phone to reconnect.")
            dev["sub"] = None
            dev["last_error"] = "Subscription expired"
            self.save()
            self.event("devices", "")
        except Exception as e:
            dev["last_error"] = str(e)[:200]
            self.event("log", f'Push to {dev.get("name","Phone")} failed: {e}')

    # ---------------------------------------------------------- relay (pairing and taps from the phone)
    def relay_post(self, obj, channel=None):
        url = f'{self.cfg.get("relay", DEFAULT_RELAY).rstrip("/")}/{channel or self.down}'
        data = encrypt(self.key, obj).encode("ascii")
        for attempt in range(4):
            try:
                req = urllib.request.Request(url, data=data, method="POST",
                                             headers={"Content-Type": "text/plain", "User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=15) as r:
                    return r.status
            except Exception as e:
                if attempt == 3:
                    self.event("log", f"Couldn't reach the relay: {e}")
                    return None
                time.sleep((6 if "429" in str(e) else 1.5) * (attempt + 1))

    def _restart_listener(self):
        self._listen_gen = getattr(self, "_listen_gen", 0) + 1
        gen = self._listen_gen
        threading.Thread(target=self._listen_loop, args=(gen,), name="relay-listen", daemon=True).start()

    def _listen_loop(self, gen):
        since = str(int(time.time()))          # only messages from now on
        backoff = 2
        while self.running and gen == self._listen_gen:
            try:
                url = f'{self.cfg.get("relay", DEFAULT_RELAY).rstrip("/")}/{self.up}/json?since={since}'
                req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=90) as r:
                    backoff = 2
                    if not self.relay_ok:
                        self.relay_ok = True
                        self.event("status", "")
                    for raw in r:
                        if not self.running or gen != self._listen_gen:
                            return
                        line = raw.strip()
                        if not line:
                            continue
                        ev = json.loads(line)
                        if ev.get("event") != "message":
                            continue
                        since = ev.get("id") or since
                        if ev.get("id") in self._seen:
                            continue
                        self._seen.add(ev.get("id"))
                        try:
                            msg = decrypt(self.key, ev.get("message", ""))
                        except Exception:
                            continue
                        if time.time() - float(msg.get("t", 0)) > 120:
                            continue                     # stale, ignore
                        threading.Thread(target=self._handle, args=(msg,), daemon=True).start()
            except Exception as e:
                if self.running and gen == self._listen_gen:
                    if self.relay_ok:
                        self.relay_ok = False
                        self.event("status", "")
                    log.info("relay listener reconnecting: %s", e)
                    time.sleep(backoff)
                    backoff = min(30, backoff * 2)

    def status_payload(self, to=None) -> dict:
        dev = self.cfg["devices"].get(to or "", {})
        return {"type": "status", "to": to, "t": time.time(), "pc": socket.gethostname(),
                "push": bool(dev.get("sub")), "app_url": self.cfg.get("app_url"),
                "vapid": self.vapid_public, "quiet": self.quiet_now(),
                "plugins": [p.describe() for p in self.plugins.values()]}

    def _handle(self, msg: dict):
        cmd = msg.get("cmd")
        did = str(msg.get("id") or "")[:40]
        devs = self.cfg["devices"]
        try:
            if did and cmd in ("hello", "subscribe"):
                dev = devs.setdefault(did, {"added": time.time()})
                dev["name"] = clean(msg.get("name") or dev.get("name") or "Phone")[:40]
                w = msg.get("widths") or {}
                try:
                    dev["widths"] = [max(20, int(w.get("title", 70))), max(20, int(w.get("body", 70)))]
                except (TypeError, ValueError):
                    dev.setdefault("widths", [70, 70])
                dev["last_seen"] = time.time()
            if cmd == "hello":
                self.save()
                self.event("devices", "")
                self.relay_post(dict(self.status_payload(did), type="welcome"))
            elif cmd == "subscribe":
                sub = msg.get("sub") or {}
                if not (sub.get("endpoint", "").startswith("https://") and (sub.get("keys") or {}).get("p256dh")):
                    raise ValueError("bad subscription")
                devs[did]["sub"] = {"endpoint": sub["endpoint"], "keys": {"p256dh": sub["keys"]["p256dh"],
                                                                          "auth": sub["keys"]["auth"]}}
                devs[did].pop("last_error", None)
                self.save()
                self.event("devices", "")
                self.event("log", f'{devs[did]["name"]} paired. Notifications now arrive even with the app closed.')
                self.deliver("Glasses Hub is connected", "Notes now arrive even with the app closed.",
                             source="hub", manual=True, to=did)
                self.relay_post({"type": "subscribed", "to": did, "t": time.time()})
            elif cmd == "relay_only":
                if did in devs:
                    devs[did]["sub"] = None
                    self.save()
                    self.event("devices", "")
            elif cmd == "forget":
                if devs.pop(did, None) is not None:
                    self.save()
                    self.event("devices", "")
                    self.event("log", "A phone disconnected itself.")
            elif cmd == "status":
                self.relay_post(self.status_payload(did))
            elif cmd == "test":
                self.deliver("Test from Glasses Hub", f"Sent {datetime.now().strftime('%I:%M:%S %p').lstrip('0')}"
                             " from your PC.", source="hub", manual=True, to=did or None)
            elif cmd == "toggle":
                p = self.plugins.get(msg.get("plugin"))
                if p:
                    p.set_enabled(bool(msg.get("on")))
                    self.event("status", "")
                self.relay_post(self.status_payload(did))
            elif cmd == "action":
                p = self.plugins.get(msg.get("plugin"))
                if p:
                    reply = p.action(msg.get("action"), msg.get("arg"))
                    if reply:
                        self.relay_post({"type": "toast", "to": did, "text": reply, "t": time.time()})
                    self.relay_post(self.status_payload(did))
        except Exception as e:
            log.exception("command %s failed", cmd)
            self.relay_post({"type": "toast", "to": did, "text": f"PC error: {e}", "t": time.time()})

    # ---------------------------------------------------------- local "send" address for scripts
    def send_url(self) -> str:
        return f'http://127.0.0.1:{self.cfg["send_port"]}/send?key={self.cfg["send_key"]}'

    def _start_http(self):
        hub = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _reply(self, code, obj):
                data = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _go(self, params):
                if params.get("key") != hub.cfg["send_key"] and self.headers.get("X-Key") != hub.cfg["send_key"]:
                    return self._reply(403, {"ok": False, "error": "wrong or missing key"})
                title = params.get("title") or params.get("t") or ""
                body = params.get("body") or params.get("text") or params.get("b") or ""
                ok = hub.deliver(title, body, source=clean(params.get("source") or "send")[:20], manual=True)
                self._reply(200 if ok else 409, {"ok": ok})

            def do_GET(self):
                u = urllib.parse.urlsplit(self.path)
                if u.path.rstrip("/") == "/send":
                    return self._go({k: v[-1] for k, v in urllib.parse.parse_qs(u.query).items()})
                self._reply(200, {"app": "Glasses Hub", "send": "GET or POST /send?key=...&title=...&body=..."})

            def do_POST(self):
                u = urllib.parse.urlsplit(self.path)
                params = {k: v[-1] for k, v in urllib.parse.parse_qs(u.query).items()}
                n = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(min(n, 20000)) if n else b""
                try:
                    if raw.strip().startswith(b"{"):
                        params.update({k: str(v) for k, v in json.loads(raw).items()})
                    elif raw:
                        params.update({k: v[-1] for k, v in urllib.parse.parse_qs(raw.decode()).items()} or
                                      {"body": raw.decode("utf-8", "replace")})
                except Exception:
                    params.setdefault("body", raw.decode("utf-8", "replace"))
                if u.path.rstrip("/") == "/send":
                    return self._go(params)
                self._reply(404, {"ok": False})

        try:
            self.http = http.server.ThreadingHTTPServer(("127.0.0.1", int(self.cfg["send_port"])), H)
            threading.Thread(target=self.http.serve_forever, name="send-http", daemon=True).start()
        except OSError as e:
            self.http = None
            self.event("log", f"The local send address couldn't start (port {self.cfg['send_port']} busy?): {e}")


class Plugin:
    """Base for the things that send notes. Each runs its own small background loop."""
    id = "plugin"
    name = "Plug-in"
    defaults = {"enabled": True}
    actions = {}            # action id -> button label (shown on the phone and the PC)
    fields = []             # (key, label, kind, extra) for the settings dialog; kind: text|list|int|bool|choice|time

    def __init__(self, hub: Hub):
        self.hub = hub
        self.cfg = hub.plugin_cfg(self.id, self.defaults)
        self.running = False
        self.wake = threading.Event()
        self.state_text = ""

    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("enabled"))

    def set_enabled(self, on: bool):
        self.cfg["enabled"] = on
        self.hub.save()
        self.hub.event("log", f"{self.name} turned {'on' if on else 'off'}.")
        self.wake.set()

    def describe(self) -> dict:
        return {"id": self.id, "name": self.name, "on": self.enabled, "state": self.state_text,
                "actions": [{"id": k, "label": v} for k, v in self.actions.items()]}

    def start(self):
        self.running = True
        threading.Thread(target=self._loop, name=self.id, daemon=True).start()

    def stop(self):
        self.running = False
        self.wake.set()

    def sleep(self, seconds: float):
        self.wake.wait(max(0.5, seconds))
        self.wake.clear()

    def _loop(self):
        while self.running:
            delay = 60
            try:
                if self.enabled:
                    delay = self.tick()
                else:
                    delay = 30
            except Exception as e:
                log.exception("%s failed", self.id)
                self.state_text = f"Problem: {e}"[:120]
                self.hub.event("log", f"[{self.name}] {e}")
                delay = 120
            self.sleep(delay or 60)

    def tick(self) -> float:
        return 60

    def action(self, action_id, arg=None):
        return None

    def send(self, title, body="", manual=False, **kw):
        return self.hub.deliver(title, body, source=self.id, manual=manual, **kw)
