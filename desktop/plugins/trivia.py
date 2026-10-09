"""Trivia host: you read the question off your glasses, everyone else guesses, the answer shows up
on your glasses a little later (or when you tap Reveal).

Questions come from Claude (any topic you like) or the free Open Trivia Database (no key needed).
"""
import html
import threading
import json
import random
import time
import urllib.parse

from core import Plugin, get_api_key, http_json, log

OPENTDB = "https://opentdb.com"

TRIVIA_RULES = """You write questions for a trivia game. The host reads each question from a tiny display
on smart glasses and says it out loud, so keep everything short.

Rules:
- Exactly {n} questions about: {topic}. Difficulty: {difficulty}.
- "q": the question, at most 110 characters. No "Which of the following".
- "choices": 4 short options (each at most 22 characters), one of them the answer. {choice_rule}
- "answer": the correct answer, exactly as it appears in choices, at most 40 characters.
- "note": one fun follow-up fact, at most 65 characters.
- Facts must be accurate and not time-sensitive (nothing that changes year to year).
- Don't repeat or closely echo any of these recent questions:
{recent}

Reply with JSON only: [{{"q": "...", "choices": ["...","...","...","..."], "answer": "...", "note": "..."}}]"""


class Trivia(Plugin):
    id = "trivia"
    name = "Trivia host"
    defaults = {"enabled": True, "source": "auto", "topic": "General knowledge", "difficulty": "mixed",
                "choices": True, "answer_delay": 30, "round_size": 10, "next_delay": 20, "category": 0}
    actions = {"next": "Next question", "reveal": "Reveal answer", "round": "Start a round", "stop": "Stop round"}
    fields = [("source", "Questions from", "choice", ["auto", "claude", "opentdb"]),
              ("topic", "Topic (Claude only)", "text", None),
              ("difficulty", "Difficulty", "choice", ["mixed", "easy", "medium", "hard"]),
              ("choices", "Show multiple-choice options", "bool", None),
              ("answer_delay", "Seconds until the answer shows (0 = only when I tap Reveal)", "int", (0, 600)),
              ("round_size", "Questions per round", "int", (1, 50)),
              ("next_delay", "Seconds after an answer before the next question (0 = tap Next)", "int", (0, 600))]

    def __init__(self, hub):
        super().__init__(hub)
        self.fetch = http_json
        self.pool = []
        self.cur = None            # {"q","choices","answer","note","n","asked","revealed","revealed_at"}
        self.number = 0
        self.round_left = 0
        self.token = None
        self.recent = []
        self.state_text = "Ready"
        self.lock = threading.RLock()

    # ---------------------------------------------------------- question sources
    def source(self) -> str:
        s = self.cfg.get("source", "auto")
        if s == "auto":
            return "claude" if get_api_key() else "opentdb"
        return s

    def refill(self):
        src = self.source()
        try:
            qs = self._from_claude() if src == "claude" else self._from_opentdb()
        except Exception as e:
            if src == "claude":
                log.warning("Claude trivia failed (%s); using Open Trivia DB", e)
                self.hub.event("log", f"[Trivia] Claude didn't answer ({e}); using Open Trivia DB instead.")
                qs = self._from_opentdb()
            else:
                raise
        random.shuffle(qs)
        self.pool.extend(qs)

    def _from_claude(self):
        n = 10
        diff = self.cfg.get("difficulty", "mixed")
        rules = TRIVIA_RULES.format(
            n=n, topic=self.cfg.get("topic") or "General knowledge",
            difficulty="a mix of easy, medium and hard" if diff == "mixed" else diff,
            choice_rule="Put the answer in a random position.",
            recent="\n".join(f"- {q}" for q in self.recent[-40:]) or "- (none yet)")
        data = self.hub.claude.ask_json(rules, f"Write {n} questions now.", max_tokens=3000)
        out = []
        for d in data if isinstance(data, list) else []:
            q, a = str(d.get("q", "")).strip(), str(d.get("answer", "")).strip()
            ch = [str(c).strip() for c in d.get("choices") or [] if str(c).strip()]
            if q and a:
                if a not in ch:
                    ch = []
                out.append({"q": q, "choices": ch[:4], "answer": a, "note": str(d.get("note", "")).strip()})
        if not out:
            raise RuntimeError("no questions in Claude's reply")
        return out

    def _from_opentdb(self):
        if not self.token:
            try:
                self.token = self.fetch(f"{OPENTDB}/api_token.php?command=request").get("token")
            except Exception:
                self.token = None
        params = {"amount": 20, "type": "multiple", "encode": "url3986"}
        diff = self.cfg.get("difficulty", "mixed")
        if diff in ("easy", "medium", "hard"):
            params["difficulty"] = diff
        if int(self.cfg.get("category") or 0):
            params["category"] = int(self.cfg["category"])
        if self.token:
            params["token"] = self.token
        d = self.fetch(f"{OPENTDB}/api.php?{urllib.parse.urlencode(params)}")
        if d.get("response_code") in (3, 4) and self.token:        # token expired / used up: reset it
            self.token = None
            params.pop("token", None)
            d = self.fetch(f"{OPENTDB}/api.php?{urllib.parse.urlencode(params)}")
        if d.get("response_code") == 5:
            time.sleep(6)                                           # rate limited: one call per 5 s
            d = self.fetch(f"{OPENTDB}/api.php?{urllib.parse.urlencode(params)}")
        un = lambda s: html.unescape(urllib.parse.unquote(s or "")).strip()
        out = []
        for r in d.get("results", []):
            q, a = un(r.get("question")), un(r.get("correct_answer"))
            ch = [a] + [un(x) for x in r.get("incorrect_answers", [])]
            random.shuffle(ch)
            if len(q) <= 130 and all(len(c) <= 30 for c in ch):
                out.append({"q": q, "choices": ch, "answer": a, "note": un(r.get("category"))})
        if not out:
            raise RuntimeError(f"Open Trivia DB returned nothing (code {d.get('response_code')})")
        return out

    # ---------------------------------------------------------- game flow
    def ask_next(self, manual=True):
        if not self.pool:
            self.refill()
        q = self.pool.pop(0)
        self.number += 1
        self.recent.append(q["q"])
        self.recent = self.recent[-80:]
        self.cur = dict(q, n=self.number, asked=time.time(), revealed=False)
        body = ""
        if self.cfg.get("choices") and q.get("choices"):
            body = "  ".join(f"{'ABCD'[i]}) {c}" for i, c in enumerate(q["choices"]))
        self.send(f"Q{self.number}: {q['q']}", body, manual=manual, tag=f"trivia-q{self.number}")
        self.state_text = f"Question {self.number} asked" + (f", {self.round_left} left in round" if self.round_left else "")
        self.wake.set()

    def reveal(self, manual=True):
        if not self.cur or self.cur["revealed"]:
            return False
        q = self.cur
        letter = ""
        if self.cfg.get("choices") and q.get("choices") and q["answer"] in q["choices"]:
            letter = "ABCD"[q["choices"].index(q["answer"])] + ") "
        self.send(f"A{q['n']}: {letter}{q['answer']}", q.get("note", ""), manual=manual, tag=f"trivia-a{q['n']}")
        q["revealed"], q["revealed_at"] = True, time.time()
        if self.round_left:
            self.round_left -= 1
            if not self.round_left:
                self.state_text = "Round over"
                self.send("That's the round!", f"{q['n']} questions. Tap Start a round to play again.",
                          manual=True, tag="trivia-end")
        else:
            self.state_text = f"Answer {q['n']} shown"
        self.wake.set()
        return True

    def tick(self) -> float:
        with self.lock:
            return self._tick()

    def _tick(self) -> float:
        now = time.time()
        q = self.cur
        delay = float(self.cfg.get("answer_delay") or 0)
        if q and not q["revealed"] and delay > 0 and now - q["asked"] >= delay:
            self.reveal()
        q = self.cur
        nxt = float(self.cfg.get("next_delay") or 0)
        if self.round_left and q and q["revealed"] and nxt > 0 and now - q["revealed_at"] >= nxt:
            self.ask_next()
        busy = (q and not q["revealed"]) or self.round_left
        if not busy and len(self.pool) < 3:
            try:
                self.refill()          # keep a few questions ready so "Next" is instant
            except Exception as e:
                log.info("trivia prefetch failed: %s", e)
                return 300
        return 1 if busy else 300

    def action(self, action_id, arg=None):
        with self.lock:
            return self._action(action_id, arg)

    def _action(self, action_id, arg=None):
        if action_id == "next":
            if self.cur and not self.cur["revealed"]:
                self.reveal()
                time.sleep(float(self.hub.cfg.get("gap_seconds") or 5))
            self.ask_next()
        elif action_id == "reveal":
            if not self.reveal():
                return "No question waiting for an answer."
        elif action_id == "round":
            self.round_left = max(1, int(self.cfg.get("round_size") or 10))
            self.number = 0
            self.send("Trivia time!", f"{self.round_left} questions. First one coming up.", manual=True, tag="trivia-start")
            time.sleep(float(self.hub.cfg.get("gap_seconds") or 5))
            self.ask_next()
        elif action_id == "stop":
            self.round_left = 0
            self.state_text = "Round stopped"
            return "Round stopped."
        return None
