#!/usr/bin/env python3
"""A CLI stopped on a provider error is resumed in its pane (d25 batch220 QAE1, operator 23:58: Sol's Codex turn ended
at ~23:25 on "Selected model is at capacity. Please try a different model." under a "Set up security for Daybreak
mode" dialog, and sat until the operator's esc and prompt at 23:55): python3 tools/test_pane_resume_stop.py

Fake panes (no herdr, no game), fixed epoch times in 2023 (no clock), a temp run folder:
1. Sol: its stop line and the dialog, herdr reading the pane idle, a background loop's request in its journal every
   20 s. Nothing before --idle-min; then one esc (no option chosen, no other key) and one message naming the line;
   the CLI's turn makes a request of its own (a tells read, not the loop's platform_defense): resumed.
2. Keeps failing: the stop shown again after each message is logged once a try; (d26 batch252) typed again 5, 10 and
   20 min after the last try, 4 tries at most, then logged as spent; the cover told once at 20 min.
3. Not a stop: a turn running ("Reconnecting" mid-turn), herdr reading a Claude pane working, a usage-limit screen
   with no rest, Claude's "Request was aborted", a rest running, an agy pane, after the deadline, the old stop line
   above a message already typed: nothing pressed or typed.
4. Claude, Grok and Muse stops: one message each. A dialog still up after esc: logged once, nothing typed. Dry run:
   nothing pressed or typed. tools/idle_nudge.py passes its --idle-min.
Fails on main: no provider-stop rule in tools/pane_resume.py.
"""
import datetime
import json
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
os.environ["POG_TEST"] = "1"
os.environ["POG_REST_PUSH"] = "off"
import pane_resume as pr  # noqa: E402

T0 = 1700000000.0   # fixed, so nothing depends on the clock
IDLE = 600

SOL_STOP = """• Asterion: 153 foundation, 0 open ghosts; watching flight 205.

■ Selected model is at capacity. Please try a different model."""
DAYBREAK = """
  Set up security for Daybreak mode

› 1. Set up security

  Press enter to confirm or esc to dismiss"""
CODEX_PROMPT = """
› Ask Codex to do anything

  gpt-6.1-sol high · 41% context left"""
CODEX_RETRYING = """■ stream disconnected - retrying sampling request (2/5 in 412ms)…

• Reconnecting... 2/5 (12s • esc to interrupt)
› Ask Codex to do anything"""
CODEX_LIMIT = """■ Usage limit reached. You've reached your usage limit. Increase your limits to continue using codex.

› Ask Codex to do anything"""
CLAUDE_529 = """⏺ Reading the pad.
  ⎿  API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

❯
  ⏵⏵ don't ask on (shift+tab to cycle)"""
CLAUDE_ABORTED = """  ⎿  API Error: Request was aborted.

❯
  ⏵⏵ don't ask on (shift+tab to cycle)"""
GROK_STOP = """  Model is temporarily overloaded. Try again in a moment.

  > """
MUSE_STOP = """◆ Ran 2 commands · 1.2s
✗ turn failed: rate limited (HTTP 429)

── Voice input (⌥ + v to start) ───────────────────────────────────
❯"""


class Pane:
    def __init__(self, kind, screen, status="idle", react="work", dialog=False, sticky=False):
        self.kind, self.screen, self.status, self.react = kind, screen, status, react
        self.dir = None   # its agent folder: a turn's request goes into its journal
        self.dialog, self.sticky = dialog, sticky   # sticky: esc does not close it
        self.typed, self.keys = [], []


class Panes:
    """herdr's calls on fake panes. A message makes the CLI run a turn (react="work"), show a provider stop again
    (react="stop"), or end its turn with no error (react="quiet")."""

    def __init__(self, panes):
        self.p = panes
        self.now = T0

    def journal(self, p, action):
        with open(os.path.join(p.dir, "journal.jsonl"), "a") as j:
            j.write(json.dumps({"event": "request", "at": iso(self.now + 5), "request": {"action": action}}) + "\n")

    def status(self, pane):
        return self.p[pane].status

    def read(self, pane, ansi=False, recent=False):
        p = self.p[pane]
        return p.screen + (DAYBREAK if p.dialog else "") + (CODEX_PROMPT if p.kind == "codex" else "")

    def prompt(self, pane, text):
        p = self.p[pane]
        assert not p.dialog, "typed into a pane with a dialog on top"
        p.typed.append(text)
        p.screen += "\n\n› " + text[:70] + "\n  " + text[70:140] + "\n  " + text[140:]   # wrapped
        if p.react == "work":
            p.screen += "\n\n• Working (3s • esc to interrupt)"
            self.journal(p, "tells")
        elif p.react == "stop":
            p.screen += "\n\n■ Selected model is at capacity. Please try a different model."
        elif p.react == "quiet":
            p.screen += "\n\n• Read tells; nothing new."
            self.journal(p, "tells")
        else:   # "show": a turn shown, no request of its own
            p.screen += "\n\n• Working (3s • esc to interrupt)"
        return "agent prompt", True, ""

    def keys(self, pane, *keys):
        p = self.p[pane]
        p.keys.extend(keys)
        if "esc" in keys and p.dialog and not p.sticky:
            p.dialog = False
        return True


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class Run:
    def __init__(self, tmp, members, rest_until=None):
        self.dir = tmp
        self.panes = {}
        with open(os.path.join(tmp, "panes.txt"), "w") as f:
            for i, (name, pane) in enumerate(members):
                pid = f"w2Y:p{i}"
                d = os.path.join(tmp, name)
                os.makedirs(d)
                with open(os.path.join(d, "journal.jsonl"), "w") as j:   # a background loop's requests every 20 s
                    for k in range(200):
                        j.write(json.dumps({"event": "request", "at": iso(T0 + 20 * k), "request": {
                            "action": "platform_defense", "args": {"platform": "Asterion"}}}) + "\n")
                if rest_until:
                    json.dump({"since": T0, "until": rest_until, "reason": "quota"},
                              open(os.path.join(d, "resting.json"), "w"))
                self.panes[pid] = pane
                pane.dir = d
                f.write(f"{name} {pid} {pane.kind}\n")
        self.fake = Panes(self.panes)
        self.rows = []

    def resumer(self, **kw):
        return pr.Resumer(self.dir, self.fake, every_s=1200, end_rest=lambda d: None, pause=lambda s: None,
                          idle_s=IDLE, **kw)

    def poll(self, r, t0, t1, step=60):
        """Polls every `step` s from t0 to t1; the rows written."""
        out = []
        t = t0
        while t <= t1:
            self.fake.now = t
            out += r.step(t, self.rows.append)
            t += step
        return out


def check(cond, what):
    if not cond:
        raise AssertionError(what)
    print("ok", what)


def sol():
    with tempfile.TemporaryDirectory() as tmp:
        sol = Pane("codex", SOL_STOP, dialog=True)
        run = Run(tmp, [("sol", sol)])
        r = run.resumer()
        rows = run.poll(r, T0, T0 + IDLE - 60)
        check(rows == [] and sol.keys == [] and sol.typed == [],
              "Sol: nothing pressed or typed before the nudge time (10 min), its journal busy with a background loop")
        run.fake.now = T0 + IDLE
        rows = r.step(T0 + IDLE, run.rows.append)
        check(sol.keys == ["esc"], "Sol: one esc for the Daybreak dialog, no option chosen")
        check(len(sol.typed) == 1 and sol.typed[0] == "Operator (automatic): your last turn stopped on a provider error: "
              "Selected model is at capacity. Please try a different model.; continue from your tells and notes.",
              "Sol: one message naming the line")
        row = rows[0]
        check(row["action"] == "typed" and row["resume"] and row["provider_stop"] and row["stopped_min"] == 10
              and "esc for the dialog on top" in row["line"] and row["agent"] == "sol", "Sol: the try logged")
        rows = run.poll(r, T0 + IDLE + 30, T0 + IDLE + 60, 30)
        check([x["action"] for x in rows] == ["resumed"] and len(sol.typed) == 1 and rows[0]["verified"] == "tells",
              "Sol: its turn's request of its own (tells): resumed")
        run.poll(r, T0 + IDLE + 120, T0 + 3 * 3600, 300)
        check(len(sol.typed) == 1 and sol.keys == ["esc"], "Sol: nothing more while it works")


def keeps_failing():
    with tempfile.TemporaryDirectory() as tmp:
        sol = Pane("codex", SOL_STOP, react="stop")
        run = Run(tmp, [("sol", sol)])
        told = []
        r = run.resumer(cover=lambda name, now: "astra", send=lambda to, text: told.append((to, text)))
        run.poll(r, T0, T0 + IDLE + 120)
        check(len(sol.typed) == 1 and [x["action"] for x in run.rows] == ["typed", "still_stopped"]
              and "provider stop again 1 min after try 1" in run.rows[1]["line"],
              "keeps failing: the stop after the message logged once")
        run.poll(r, T0 + IDLE + 180, T0 + IDLE + 240)
        check(len(sol.typed) == 1, "keeps failing: no second try within 5 min")
        run.poll(r, T0 + IDLE + 300, T0 + IDLE + 360)
        check(len(sol.typed) == 2 and [x["action"] for x in run.rows][-2:] == ["typed", "still_stopped"],
              "keeps failing: tried again at 5 min, its failure logged")
        run.poll(r, T0 + IDLE + 420, T0 + IDLE + 840)
        check(len(sol.typed) == 2, "keeps failing: the third try waits 10 min")
        run.poll(r, T0 + IDLE + 900, T0 + IDLE + 2040)
        check(len(sol.typed) == 3 and [(x["action"], x.get("to")) for x in run.rows if x["action"] == "cover_alert"] == [("cover_alert", "astra")]
              and len(told) == 1, "keeps failing: third try at 10 min; the cover told once at 20 min")
        run.poll(r, T0 + IDLE + 2100, T0 + 6 * 3600)
        check(len(sol.typed) == 4 and sum(x["action"] == "tries_spent" for x in run.rows) == 1 and len(told) == 1,
              "keeps failing: the fourth try at 20 min, then nothing more typed (4 tries), spent logged once")


def not_a_stop():
    cases = [
        ("a turn running (Reconnecting mid-turn)", Pane("codex", CODEX_RETRYING)),
        ("herdr reads a Claude pane working", Pane("claude", CLAUDE_529, status="working")),
        ("a usage-limit screen with no rest", Pane("codex", CODEX_LIMIT)),
        ("Claude's Request was aborted", Pane("claude", CLAUDE_ABORTED)),
        ("an agy pane", Pane("agy", "Connection error")),
        ("no error on the screen", Pane("codex", "• Watching Asterion.")),
    ]
    for what, pane in cases:
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, [("a", pane)])
            run.poll(run.resumer(), T0, T0 + 3600)
            check(pane.typed == [] and pane.keys == [] and run.rows == [], f"not a stop: {what}")
    with tempfile.TemporaryDirectory() as tmp:
        pane = Pane("codex", SOL_STOP)
        run = Run(tmp, [("a", pane)], rest_until=T0 + 7200)
        run.poll(run.resumer(), T0, T0 + 3600)
        check(pane.typed == [] and run.rows == [], "not a stop: a rest running (the rest rule owns it)")
    with tempfile.TemporaryDirectory() as tmp:
        pane = Pane("codex", SOL_STOP)
        run = Run(tmp, [("a", pane)])
        run.poll(run.resumer(deadline=T0 + 300), T0, T0 + 3600)
        check(pane.typed == [], "not a stop: after the run's deadline")
    with tempfile.TemporaryDirectory() as tmp:
        pane = Pane("codex", SOL_STOP, react="quiet")
        run = Run(tmp, [("a", pane)])
        run.poll(run.resumer(), T0, T0 + 4 * 3600)
        check(len(pane.typed) == 1 and [x["action"] for x in run.rows] == ["typed", "resumed"],
              "not a stop: the old line above the message typed (its turn read its tells and ended with no error)")
    check(pr.provider_stop("codex", "Hide future rate limit reminders about switching models\n› x") is None,
          "not a stop: Codex's switch-model reminder")


def other_clis():
    for kind, screen, line in [("claude", CLAUDE_529, 'API Error: 529 {"type":"error"'),
                               ("grok", GROK_STOP, "Model is temporarily overloaded. Try again in a moment."),
                               ("muse", MUSE_STOP, "turn failed: rate limited (HTTP 429)")]:
        with tempfile.TemporaryDirectory() as tmp:
            pane = Pane(kind, screen, status="working" if kind == "muse" else "idle")
            run = Run(tmp, [("a", pane)])
            run.poll(run.resumer(), T0, T0 + IDLE + 60)
            check(len(pane.typed) == 1 and line in pane.typed[0] and pane.keys == []
                  and [x["action"] for x in run.rows] == ["typed", "resumed"], f"{kind}: one message, resumed")
    with tempfile.TemporaryDirectory() as tmp:
        pane = Pane("codex", SOL_STOP, dialog=True, sticky=True)
        run = Run(tmp, [("sol", pane)])
        run.poll(run.resumer(), T0, T0 + IDLE + 1200 + 60)
        check(pane.typed == [] and pane.keys == ["esc", "esc"] and [x["action"] for x in run.rows] == ["dialog_up", "cover_alert"]
              and run.rows[1]["sent"] is False, "a dialog still up after esc: logged once, nothing typed, esc again 20 min "
              "later; at 20 min the alert finds no cover (none given)")
    with tempfile.TemporaryDirectory() as tmp:
        pane = Pane("codex", SOL_STOP, dialog=True)
        run = Run(tmp, [("sol", pane)])
        run.poll(run.resumer(dry=True), T0, T0 + IDLE)
        check(pane.typed == [] and pane.keys == [] and run.rows[0]["dry_run"]
              and "dry run: would type" in run.rows[0]["line"], "dry run: nothing pressed or typed")
    with tempfile.TemporaryDirectory() as tmp:
        pane = Pane("codex", "• Read the Security setup notes.\n" + "• line\n" * 50 + SOL_STOP)
        run = Run(tmp, [("sol", pane)])
        run.poll(run.resumer(), T0, T0 + IDLE)
        check(pane.keys == [] and len(pane.typed) == 1, "a dialog's words far up in the history: no esc, one message")
    src = open(os.path.join(ROOT, "tools", "idle_nudge.py")).read()
    check("idle_s=n.idle_s" in src, "idle_nudge passes its --idle-min")


if __name__ == "__main__":
    sol()
    keeps_failing()
    not_a_stop()
    other_clis()
    print("test_pane_resume_stop: all ok")
