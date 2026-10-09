"""Odd facts: a surprising fact every so often, on topics you pick, during the hours you pick.

Facts come from Claude (topics of your choice). Without a Claude key it uses Wikipedia's
"On this day" events instead.
"""
import random
import time
from datetime import datetime

from core import Plugin, get_api_key, http_json, in_window, log

FACT_RULES = """You write one-glance "huh, really?" facts for a tiny display on smart glasses.
Each fact is shown as two lines: "top" (at most {tw} characters) and "bottom" (at most {bw} characters).
The top line should hook; the bottom line finishes the thought. Plain text, no emoji, no quotes.

Rules:
- Exactly {n} facts, spread across these topics: {topics}.
- Surprising, specific and TRUE. Well established facts only: no myths, no "studies suggest", nothing
  that changes year to year. If you're not sure it's true, pick a different fact.
- Don't repeat or closely echo any of these recent facts:
{recent}

Reply with JSON only: [{{"topic": "...", "top": "...", "bottom": "..."}}]"""


class Facts(Plugin):
    id = "facts"
    name = "Odd facts"
    defaults = {"enabled": True,
                "topics": "space, history, animals, the human body, food origins, inventions, oceans, words",
                "every_minutes": 60, "start": "09:00", "end": "21:00", "weekdays_only": False,
                "source": "auto", "last_at": 0, "recent": []}
    actions = {"fact": "Fact now"}
    fields = [("topics", "Topics (comma separated)", "text", None),
              ("every_minutes", "Minutes between facts", "int", (5, 1440)),
              ("start", "From (HH:MM)", "time", None),
              ("end", "Until (HH:MM)", "time", None),
              ("weekdays_only", "Weekdays only", "bool", None),
              ("source", "Facts from", "choice", ["auto", "claude", "wikipedia"])]

    def __init__(self, hub):
        super().__init__(hub)
        self.fetch = http_json
        self.pool = []

    def source(self):
        s = self.cfg.get("source", "auto")
        if s == "auto":
            return "claude" if get_api_key() else "wikipedia"
        return s

    def widths(self):
        devs = [d for d in self.hub.cfg["devices"].values()]
        tw = min([int((d.get("widths") or (70, 70))[0]) for d in devs] or [70])
        bw = min([int((d.get("widths") or (70, 70))[1]) for d in devs] or [70])
        return tw, bw

    def refill(self):
        if self.source() == "claude":
            try:
                self.pool.extend(self._from_claude())
                return
            except Exception as e:
                self.hub.event("log", f"[Odd facts] Claude didn't answer ({e}); using Wikipedia instead.")
        self.pool.extend(self._from_wikipedia())

    def _from_claude(self):
        tw, bw = self.widths()
        rules = FACT_RULES.format(n=8, tw=tw, bw=bw, topics=self.cfg.get("topics") or "anything",
                                  recent="\n".join(f"- {r}" for r in self.cfg.get("recent", [])[-60:]) or "- (none yet)")
        data = self.hub.claude.ask_json(rules, "Write the facts now.", max_tokens=2500)
        out = [{"top": str(d.get("top", "")).strip(), "bottom": str(d.get("bottom", "")).strip()}
               for d in (data if isinstance(data, list) else []) if str(d.get("top", "")).strip()]
        if not out:
            raise RuntimeError("no facts in Claude's reply")
        random.shuffle(out)
        return out

    def _from_wikipedia(self):
        now = datetime.now()
        path = f"onthisday/selected/{now.month:02d}/{now.day:02d}"
        try:
            d = self.fetch(f"https://en.wikipedia.org/api/rest_v1/feed/{path}")
        except Exception:
            d = self.fetch(f"https://api.wikimedia.org/feed/v1/wikipedia/en/{path}")
        recent = set(self.cfg.get("recent", []))
        out = []
        for e in d.get("selected", []):
            text = (e.get("text") or "").strip()
            if text and len(text) <= 200:
                top = f"On this day in {e.get('year')}:"
                if f"{top} {text}"[:60] not in recent:
                    out.append({"top": "", "bottom": f"{top} {text}"})
        random.shuffle(out)
        if not out:
            raise RuntimeError("Wikipedia had nothing new for today")
        return out[:8]

    def send_fact(self, manual=False):
        if not self.pool:
            self.refill()
        f = self.pool.pop(0)
        ok = self.send(f["top"], f["bottom"], manual=manual)
        key = (f"{f['top']} {f['bottom']}".strip())[:60]
        self.cfg["recent"] = (self.cfg.get("recent", []) + [key])[-80:]
        self.cfg["last_at"] = time.time()
        self.hub.save()
        return ok

    def due_in(self) -> float:
        every = max(5.0, float(self.cfg.get("every_minutes") or 60)) * 60
        return float(self.cfg.get("last_at") or 0) + every - time.time()

    def active_now(self) -> bool:
        if self.cfg.get("weekdays_only") and datetime.now().weekday() >= 5:
            return False
        return in_window(self.cfg.get("start", "09:00"), self.cfg.get("end", "21:00"))

    def tick(self) -> float:
        if not self.active_now():
            self.state_text = f"Resting until {self.cfg.get('start', '09:00')}"
            return 120
        wait = self.due_in()
        if wait <= 0:
            if self.send_fact():
                wait = self.due_in()
            else:
                self.cfg["last_at"] = time.time()          # held back (quiet hours / no phone): try next slot
                wait = self.due_in()
        mins = max(1, int(wait // 60))
        self.state_text = f"Next fact in {mins} min"
        return max(30, min(wait, 600))

    def action(self, action_id, arg=None):
        if action_id == "fact":
            self.send_fact(manual=True)
        return None
