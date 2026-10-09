"""NFL scores for the teams you follow (Chiefs by default), from ESPN's public scoreboard feed.

Alerts: game reminder, kickoff, every score (with the play), halftime and final.
While a game is on it checks every 20 seconds; otherwise every half hour.
"""
import re
import time
from datetime import datetime, timezone

from core import Plugin, http_json, log

API = "https://site.api.espn.com/apis/site/v2/sports/football/nfl"

TEAMS = {
    "ARI": "Cardinals", "ATL": "Falcons", "BAL": "Ravens", "BUF": "Bills", "CAR": "Panthers", "CHI": "Bears",
    "CIN": "Bengals", "CLE": "Browns", "DAL": "Cowboys", "DEN": "Broncos", "DET": "Lions", "GB": "Packers",
    "HOU": "Texans", "IND": "Colts", "JAX": "Jaguars", "KC": "Chiefs", "LAC": "Chargers", "LAR": "Rams",
    "LV": "Raiders", "MIA": "Dolphins", "MIN": "Vikings", "NE": "Patriots", "NO": "Saints", "NYG": "Giants",
    "NYJ": "Jets", "PHI": "Eagles", "PIT": "Steelers", "SEA": "Seahawks", "SF": "49ers", "TB": "Buccaneers",
    "TEN": "Titans", "WSH": "Commanders",
}

# words that are part of the play description, not a player's name
_PLAY_WORDS = {"Yd", "Yds", "Pass", "Rush", "Run", "Field", "Goal", "Kick", "Two-Point", "Conversion", "Failed",
               "Safety", "Interception", "Return", "Fumble", "Punt", "Blocked", "Kickoff", "Recovery", "Missed",
               "PAT", "TD", "FG", "Defensive", "Lateral", "Recovered", "In", "End", "Zone", "Touchdown"}
_SUFFIX = {"Jr.", "Sr.", "II", "III", "IV", "V", "Jr", "Sr"}


def short_play(text: str) -> str:
    """'Tyquan Thornton 2 Yd pass from Patrick Mahomes (Harrison Butker Kick)'
       -> 'Thornton 2-yd pass from Mahomes (Butker kick)'"""
    words = text.split()
    out, run = [], []

    def flush():
        names = [w for w in run if w not in _SUFFIX]
        if len(names) >= 2:
            out.append(names[-1])
        else:
            out.extend(run)
        run.clear()

    for w in words:
        bare = w.strip("()")
        if bare[:1].isupper() and bare not in _PLAY_WORDS and not w.startswith("(") and not w.endswith(")"):
            run.append(w)
            continue
        if w.startswith("(") and bare[:1].isupper() and bare not in _PLAY_WORDS:
            flush()
            run.append(w)            # name inside parentheses, e.g. (Harrison Butker Kick)
            continue
        if run and run[0].startswith("("):
            names = [x.strip("(") for x in run if x.strip("(") not in _SUFFIX]
            out.append("(" + (names[-1] if len(names) >= 2 else " ".join(names)))
            run.clear()
        else:
            flush()
        out.append(w)
    if run:
        if run[0].startswith("("):
            names = [x.strip("(") for x in run if x.strip("(") not in _SUFFIX]
            out.append("(" + (names[-1] if len(names) >= 2 else " ".join(names)))
            run.clear()
        else:
            flush()
    s = " ".join(out)
    s = re.sub(r"(\d+) Yds? ", r"\1-yd ", s)
    s = s.replace("Field Goal", "FG").replace(" Kick)", " kick)").replace("Two-Point Pass Conversion Failed", "2-pt failed")
    s = s.replace("Two-Point Run Conversion Failed", "2-pt failed").replace("for Two-Point Conversion", "for 2-pt")
    for a, b in (("Interception Return", "pick-six"), ("Fumble Return", "fumble return"), ("Punt Return", "punt return"),
                 ("Kickoff Return", "kickoff return"), ("Fumble Recovery", "fumble recovery"),
                 ("Blocked Punt", "blocked punt")):
        s = s.replace(a, b)
    s = s.replace(" Pass to ", " pass to ").replace(" Rush", " run").replace(" Run ", " run ")
    return re.sub(r"\s+", " ", s).strip()


def local_time(iso: str) -> datetime:
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone()


def fmt_when(dt: datetime) -> str:
    now = datetime.now().astimezone()
    t = dt.strftime("%I:%M %p").lstrip("0")
    if dt.date() == now.date():
        return f"Today {t}"
    if (dt.date() - now.date()).days == 1:
        return f"Tomorrow {t}"
    return dt.strftime("%a %b ") + str(dt.day) + f", {t}"


def period_name(n) -> str:
    try:
        n = int(n)
    except (TypeError, ValueError):
        return ""
    return f"Q{n}" if n <= 4 else ("OT" if n == 5 else f"{n - 4}OT")


class NFL(Plugin):
    id = "nfl"
    name = "NFL scores"
    defaults = {"enabled": True, "teams": ["KC"], "reminder": True, "reminder_minutes": 30, "kickoff": True,
                "scores": True, "halftime": True, "final": True, "ignore_quiet": True}
    actions = {"score": "Score now"}
    fields = [("teams", "Teams (comma separated, e.g. KC, DAL)", "list", None),
              ("reminder", "Remind me before the game", "bool", None),
              ("reminder_minutes", "Minutes before kickoff", "int", (5, 240)),
              ("kickoff", "Kickoff", "bool", None),
              ("scores", "Every score, with the play", "bool", None),
              ("halftime", "Halftime score", "bool", None),
              ("final", "Final score", "bool", None),
              ("ignore_quiet", "Game alerts can come during quiet hours", "bool", None)]

    def __init__(self, hub):
        super().__init__(hub)
        self.fetch = http_json            # swappable for tests
        self.schedule = {}                # team -> list of games
        self.schedule_at = 0
        self.games = {}                   # event id -> tracking state

    # ---------------------------------------------------------- data
    def teams(self):
        return [t.strip().upper() for t in self.cfg.get("teams") or [] if t.strip()]

    def refresh_schedule(self, force=False):
        if not force and time.time() - self.schedule_at < 1800:
            return
        sched = {}
        for team in self.teams():
            games = []
            for extra in ("", "?seasontype=3"):
                try:
                    d = self.fetch(f"{API}/teams/{team.lower()}/schedule{extra}")
                except Exception as e:
                    if not extra:
                        raise
                    continue
                for e in d.get("events", []):
                    c = (e.get("competitions") or [{}])[0]
                    games.append({
                        "id": e["id"], "date": e.get("date"), "short": e.get("shortName", ""),
                        "state": ((c.get("status") or {}).get("type") or {}).get("state", "pre"),
                        "tv": ", ".join(b.get("media", {}).get("shortName", "") for b in c.get("broadcasts", [])
                                        if b.get("media", {}).get("shortName"))[:30],
                        "opp": next((x["team"]["abbreviation"] for x in c.get("competitors", [])
                                     if x["team"]["abbreviation"] != team), ""),
                        "home": next((x.get("homeAway") == "home" for x in c.get("competitors", [])
                                      if x["team"]["abbreviation"] == team), False),
                        "record": (d.get("team") or {}).get("recordSummary", ""),
                    })
            seen, uniq = set(), []
            for g in sorted(games, key=lambda g: g["date"] or ""):
                if g["id"] not in seen:
                    seen.add(g["id"])
                    uniq.append(g)
            sched[team] = uniq
        self.schedule = sched
        self.schedule_at = time.time()

    def summary(self, event_id):
        return self.fetch(f"{API}/summary?event={event_id}")

    # ---------------------------------------------------------- the loop
    def tick(self) -> float:
        self.refresh_schedule()
        now = datetime.now(timezone.utc)
        live_soon = []
        next_check = 1800
        for team, games in self.schedule.items():
            for g in games:
                if not g["date"]:
                    continue
                start = datetime.fromisoformat(g["date"].replace("Z", "+00:00"))
                mins = (start - now).total_seconds() / 60
                st = self.games.setdefault(g["id"], {"team": team})
                # reminder before the game
                if self.cfg.get("reminder") and g["state"] == "pre" and 0 < mins <= float(self.cfg.get("reminder_minutes") or 30) \
                        and not st.get("reminded"):
                    st["reminded"] = True
                    them = TEAMS.get(g["opp"], g["opp"])
                    vs = "vs" if g["home"] else "at"
                    self.send(f"{TEAMS.get(team, team)} {vs} {them} in {int(round(mins))} min",
                              f"{fmt_when(start.astimezone())}{' on ' + g['tv'] if g['tv'] else ''}",
                              manual=bool(self.cfg.get("ignore_quiet")), tag=f"nfl-{g['id']}-pre")
                # watch closely from 15 minutes before kickoff until it's final
                if (g["state"] == "in") or (-15 <= -mins <= 5 * 60 and not st.get("final_done")):
                    live_soon.append((team, g))
                elif g["state"] == "pre" and mins > 0:
                    remind_at = mins - float(self.cfg.get("reminder_minutes") or 30)
                    next_check = min(next_check, max(60, (remind_at if remind_at > 0 else mins - 15) * 60))
        for team, g in live_soon:
            self.watch(team, g)
        if live_soon:
            self.state_text = "Game on: " + ", ".join(g["short"] for _, g in live_soon)
            return 20
        nxt = self.next_game()
        self.state_text = f"Next: {nxt[1]['short']}, {fmt_when(local_time(nxt[1]['date']))}" if nxt else "No games scheduled"
        return next_check

    def next_game(self):
        now = datetime.now(timezone.utc).isoformat()
        best = None
        for team, games in self.schedule.items():
            for g in games:
                if g["state"] == "pre" and (g["date"] or "") > now[:16]:
                    if not best or g["date"] < best[1]["date"]:
                        best = (team, g)
                    break
        return best

    def watch(self, team, g):
        st = self.games.setdefault(g["id"], {"team": team})
        s = self.summary(g["id"])
        self.process(team, g["id"], s)

    @staticmethod
    def _teams(comp, team):
        us = them = None
        for c in comp.get("competitors", []):
            if c["team"]["abbreviation"] == team:
                us = c
            else:
                them = c
        return us, them

    @staticmethod
    def _score(c):
        v = c.get("score")
        if isinstance(v, dict):
            v = v.get("displayValue") or v.get("value")
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return 0

    def line(self, team, comp, us_score=None, them_score=None):
        us, them = self._teams(comp, team)
        a = us_score if us_score is not None else self._score(us)
        b = them_score if them_score is not None else self._score(them)
        return f"{team} {a}-{b} {them['team']['abbreviation']}"

    def process(self, team, event_id, s, quiet_start=None):
        """Compare a fresh game summary with what we've already announced, and announce what's new."""
        st = self.games.setdefault(event_id, {"team": team})
        comp = s["header"]["competitions"][0]
        status = (comp.get("status") or {}).get("type") or {}
        state, name = status.get("state", "pre"), status.get("name", "")
        us, them = self._teams(comp, team)
        if not us or not them:
            return
        manual = bool(self.cfg.get("ignore_quiet"))
        plays = s.get("scoringPlays") or []
        first_look = "seen" not in st
        if first_look:
            st["seen"] = set()
            st["state"] = state
            if state == "in" and plays:
                # we started mid-game: one catch-up note instead of every score so far
                st["seen"].update(p["id"] for p in plays)
                st["kicked"] = True
                self.send(f"{self.line(team, comp)}, {status.get('shortDetail', '')}".strip(", "),
                          "Following this game live.", manual=manual, tag=f"nfl-{event_id}-live")
                return
            if state == "post":
                st["seen"].update(p["id"] for p in plays)
                st["final_done"] = True
                return
        # kickoff
        if state == "in" and not st.get("kicked"):
            st["kicked"] = True
            if self.cfg.get("kickoff"):
                venue = ((s.get("gameInfo") or {}).get("venue") or {}).get("fullName", "")
                tv = ", ".join(b.get("media", {}).get("shortName", "") for b in comp.get("broadcasts", [])
                               if b.get("media", {}).get("shortName")) or \
                     ", ".join(n for b in (s.get("broadcasts") or []) for n in [((b.get("media") or {}).get("shortName"))] if n)
                ha = "vs" if us.get("homeAway") == "home" else "@"
                self.send(f"Kickoff: {team} {ha} {them['team']['abbreviation']}",
                          " · ".join(x for x in (tv, venue) if x) or "Game on!", manual=manual, tag=f"nfl-{event_id}-ko")
        # scores
        for p in plays:
            if p["id"] in st["seen"]:
                continue
            st["seen"].add(p["id"])
            if not self.cfg.get("scores"):
                continue
            who = (p.get("team") or {}).get("abbreviation", "")
            home = us.get("homeAway") == "home"
            a, b = (p.get("homeScore"), p.get("awayScore")) if home else (p.get("awayScore"), p.get("homeScore"))
            when = f"{period_name((p.get('period') or {}).get('number'))} {(p.get('clock') or {}).get('displayValue', '')}".strip()
            kind = (p.get("type") or {}).get("abbreviation") or "Score"
            cheer = "!" if who == team else ":"
            self.send(f"{self.line(team, comp, a, b)}, {when}",
                      f"{kind} {who}{cheer} {short_play(p.get('text', ''))}", manual=manual, tag=f"nfl-{event_id}-{p['id']}")
        # halftime
        if name == "STATUS_HALFTIME" and not st.get("half_done"):
            st["half_done"] = True
            if self.cfg.get("halftime"):
                self.send(f"Halftime: {self.line(team, comp)}", "", manual=manual, tag=f"nfl-{event_id}-half")
        # final
        if state == "post" and not st.get("final_done"):
            st["final_done"] = True
            self.schedule_at = 0          # pick up the new record and next game
            if self.cfg.get("final"):
                a, b = self._score(us), self._score(them)
                nick = TEAMS.get(team, team)
                verdict = f"{nick} win!" if a > b else (f"{nick} lose." if a < b else "Tie game.")
                rec = next((r.get("summary") for r in (us.get("record") or []) if r.get("type") in ("total", None)), "")
                ot = " (OT)" if "OT" in (status.get("shortDetail") or "") else ""
                self.send(f"Final{ot}: {self.line(team, comp)}", f"{verdict}{' Record ' + rec + '.' if rec else ''}",
                          manual=manual, tag=f"nfl-{event_id}-final")
        st["state"] = state

    # ---------------------------------------------------------- "Score now"
    def action(self, action_id, arg=None):
        if action_id != "score":
            return None
        self.refresh_schedule(force=True)
        notes = 0
        now = datetime.now(timezone.utc)
        for team, games in self.schedule.items():
            live = next((g for g in games if g["state"] == "in"), None)
            done = [g for g in games if g["state"] == "post"]
            recent = done[-1] if done else None
            if live:
                s = self.summary(live["id"])
                comp = s["header"]["competitions"][0]
                detail = ((comp.get("status") or {}).get("type") or {}).get("shortDetail", "")
                plays = s.get("scoringPlays") or []
                last = plays[-1] if plays else None
                body = ""
                if last:
                    who = (last.get("team") or {}).get("abbreviation", "")
                    body = f"Last: {(last.get('type') or {}).get('abbreviation', '')} {who}, {short_play(last.get('text', ''))}"
                self.send(f"{self.line(team, comp)}, {detail}", body, manual=True)
                notes += 1
                continue
            nxt = next((g for g in games if g["state"] == "pre"), None)
            title = body = ""
            if recent and (now - datetime.fromisoformat(recent["date"].replace("Z", "+00:00"))).days < 2:
                s = self.summary(recent["id"])
                comp = s["header"]["competitions"][0]
                title = f"Final: {self.line(team, comp)}"
            if nxt:
                them = TEAMS.get(nxt["opp"], nxt["opp"])
                vs = "vs" if nxt["home"] else "at"
                text = f"Next: {vs} {them}, {fmt_when(local_time(nxt['date']))}{' on ' + nxt['tv'] if nxt['tv'] else ''}"
                if title:
                    body = text
                else:
                    rec = nxt.get("record")
                    title = f"{TEAMS.get(team, team)}{' (' + rec + ')' if rec else ''}"
                    body = text
            if title:
                self.send(title, body, manual=True)
                notes += 1
        return None if notes else "No games found for your teams."
