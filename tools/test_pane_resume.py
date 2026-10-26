#!/usr/bin/env python3
"""An agent whose rest ends is resumed in its pane (d25 batch213 QY1, operator 17:47: Muse sat at "Usage limit
reached ... Send a message to continue" from 17:00 to 17:44 in shift76): python3 tools/test_pane_resume.py

Fake panes (no herdr, no game), fixed epoch times in 2023 (no clock), a temp run folder:
1. shift76's Muse: its 17:00 limit screen, herdr reading its pane "working" throughout. Before `until` nothing; at
   17:00:22 one message typed (send-text, as herdr refuses Muse's pane as an agent), the resume logged and the rest
   ended (resting-last.json); a minute later its CLI shows the limit again after the message: logged once, nothing
   typed until the next nudge (20 min), then typed again; a request of its own after that: resumed.
2. Mid-turn: a screen showing "esc to interrupt", or a Claude pane herdr reads working, or a request of its own in the
   last 2 min: nothing typed (logged once), typed at the first poll after it stops.
3. Grok's limit dialog: down and enter, with Try Again shown highlighted before enter; never Enter on Buy more credits;
   a dialog whose highlight cannot be read: nothing pressed.
4. Claude and Codex at their limit text: one message each (agent prompt); a minute later working: resumed.
5. agy: nothing typed; logged at `until`, and once if resting.json is still there a minute later.
6. A rest the agent ended itself (a request of its own since it began): cleared, nothing typed. Dry run: nothing typed,
   the rest kept. After the run's deadline: nothing.
7. tools/idle_nudge.py runs it (its log line for a resume row); HerdrPanes refuses under POG_TEST=1, and its prompt
   falls back to send-text + enter where herdr refuses agent prompt.
Fails on main: no tools/pane_resume.py.
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

T0 = 1700000000.0   # 2023-11-14 14:13:20 PST: fixed, so nothing depends on the clock
UNTIL = T0 + 3600

# runs/shift76/muse's pane at 17:00 (herdr pane read --source recent), its limit screen
MUSE_LIMIT = """  with the final summary it asks for.

◆ Usage limit reached · /upgrade
  (https://accountscenter.meta.com/muse_code/?ep=xgrade) for
  increased limits, or wait for usage to reset at 5:00 PM
  This turn stopped because your usage limit was reached.
  Check /usage for details.
  Send a message to continue when usage is available.

── Voice input (⌥ + v to start) ───────────────────────────────────
❯
───────────────────────────────────────────────────────────────────
  muse-spark-1.3 · medium · ~/c/p/r/shift76/muse · Launch overrides"""
MUSE_BUSY = """◆ Ran 3 commands · Watch for tells or alerts · +2 ✓ · 4.4s · ctrl+o

◇ Thinking (2m 45s · esc to interrupt)

── Voice input (⌥ + v to start) ───────────────────────────────────
❯"""
CLAUDE_LIMIT = """⏺ Checked the pad.
  ⎿  You've hit your limit · resets 5pm (America/Los_Angeles)

❯
  ⏵⏵ don't ask on (shift+tab to cycle)"""
CODEX_LIMIT = """■ Usage limit reached. You've reached your usage limit. Increase your limits to continue using codex.

› Ask Codex to do anything"""
CLAUDE_BUSY = """· Sprouting… (3h 15m 29s · ↓ 10.7k tokens)
❯
  ⏵⏵ don't ask on (shift+tab to cycle) · esc to interrupt"""


def grok_dialog(sel, plain=False):
    """Grok 1.0.70's limit dialog as herdr reads it with --format ansi (the d24 16:01 capture): the highlighted option
    bold on 54,54,54, the other on 36,36,36; plain: neither bold."""
    def opt(n, label, desc, on):
        bg = "\x1b[48;2;54;54;54m" if on and not plain else "\x1b[48;2;36;36;36m"
        bold = "\x1b[1m" if on and not plain else ""
        return (f"  \x1b[48;2;36;36;36m┃\x1b[0m  {n} \x1b[48;2;36;36;36m(○) \x1b[0m{bold}\x1b[38;2;225;225;225m{bg}"
                f"{label:<16}\x1b[0m  {desc}")
    return "\n".join(["  ┃", "  ┃  You hit your weekly limit.", "  ┃",
                      opt(1, "Buy more credits", "Purchase credits to keep using Grok Build", sel == 0),
                      opt(2, "Try Again", "Resubmit the last prompt once you have usage again", sel == 1),
                      "  ┃  ↑/↓ navigate · y copy    Enter:submit", "  Tab:next answer  │  Esc:scrollback"])


ANSI = __import__("re").compile(r"\x1b\[[0-9;]*m")


class Pane:
    def __init__(self, kind, screen, status=None, react="work", journal=None):
        self.kind, self.screen, self.status, self.react, self.journal = kind, screen, status, react, journal
        self.sel = 0      # Grok's dialog: 0 Buy more credits, 1 Try Again
        self.dialog = kind == "grok" and "You hit your" in screen
        self.plain = False
        self.typed, self.keys = [], []
        self.now = None


class Panes:
    """herdr's calls on fake panes. A message or Try Again makes the CLI work (a request of its own in its journal, a
    turn running) or show its limit again (react="limit")."""

    def __init__(self, panes):
        self.p = panes
        self.calls = []

    def status(self, pane):
        return self.p[pane].status

    def read(self, pane, ansi=False, recent=False):
        p = self.p[pane]
        if p.dialog:
            text = grok_dialog(p.sel, p.plain)
            return text if ansi else ANSI.sub("", text)
        return p.screen

    def _reacted(self, p, text_lines):
        p.screen += "\n" + text_lines
        if p.react == "limit":
            p.screen += "\n" + {"muse": MUSE_LIMIT, "claude": CLAUDE_LIMIT, "codex": CODEX_LIMIT}.get(p.kind, "")
        else:
            p.screen += "\n◇ Thinking (2s · esc to interrupt)"
            request(p.journal, p.now + 5)

    def prompt(self, pane, text):
        p = self.p[pane]
        self.calls.append(("prompt", pane, text))
        p.typed.append(text)
        # the message wraps on Muse's 66 columns, as on the 17:44 screen
        self._reacted(p, "❯ " + text[:60] + "\n  " + text[60:])
        return ("pane send-text" if p.kind == "muse" else "agent prompt"), True, ""

    def keys(self, pane, *keys):
        p = self.p[pane]
        self.calls.append(("keys", pane) + keys)
        p.keys.extend(keys)
        for k in keys:
            if k == "down" and p.dialog:
                p.sel = min(1, p.sel + 1)
            if k == "enter" and p.dialog:
                assert p.sel == 1, "Enter pressed on Buy more credits"
                p.dialog = p.react == "limit"
                if p.react != "limit":
                    p.screen = "   ⠼ Thinking… 2s   [stop]"
                    request(p.journal, p.now + 5)
        return True


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def request(path, t, action="status"):
    with open(path, "a") as f:
        f.write(json.dumps({"event": "request", "at": iso(t), "request": {"action": action, "args": {}}},
                           separators=(",", ":")) + "\n")


class Run:
    def __init__(self, tmp, members, until=UNTIL, reason="quota"):
        self.dir = tmp
        self.panes = {}
        with open(os.path.join(tmp, "panes.txt"), "w") as f:
            for i, (name, kind, screen, status, react) in enumerate(members):
                pane = f"w2Y:p{i}"
                d = os.path.join(tmp, name)
                os.makedirs(d)
                j = os.path.join(d, "journal.jsonl")
                request(j, T0 - 600)   # its last request before the rest
                json.dump({"since": T0, "until": until, "reason": reason, "sleep_s": until - T0, "resets": "Sun 17:00"},
                          open(os.path.join(d, "resting.json"), "w"))
                self.panes[pane] = Pane(kind, screen, status, react, j)
                f.write(f"{name} {pane} {kind}\n")
        self.fake = Panes(self.panes)
        self.rows = []
        self.ended = []

    def resumer(self, **kw):
        def end(d):
            self.ended.append(os.path.basename(d))
            return pr.aq.end_rest(d)
        return pr.Resumer(self.dir, self.fake, every_s=1200, end_rest=end, pause=lambda s: None, **kw)

    def step(self, r, now):
        for p in self.panes.values():
            p.now = now
        return r.step(now, self.rows.append)

    def pane(self, name):
        return self.panes[next(l.split()[1] for l in open(os.path.join(self.dir, "panes.txt")) if l.split()[0] == name)]


def check(cond, what):
    if not cond:
        raise AssertionError(what)
    print("ok", what)


def muse_shift76():
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("muse", "muse", MUSE_LIMIT, "working", "limit")])
        r = run.resumer()
        m = run.pane("muse")
        check(run.step(r, UNTIL - 60) == [] and m.typed == [], "before until: nothing typed")
        rows = run.step(r, UNTIL + 22)
        check(len(m.typed) == 1 and rows[0]["action"] == "typed" and rows[0]["how"] == "pane send-text",
              "17:00:22: one message typed though herdr reads Muse's pane working")
        check(m.typed[0].startswith("Operator (automatic): your quota rest ended at ")
              and "usage limit was due to reset" in m.typed[0] and "\n" not in m.typed[0], "the message, one line")
        check(run.ended == ["muse"] and not os.path.exists(os.path.join(tmp, "muse", "resting.json"))
              and os.path.exists(os.path.join(tmp, "muse", "resting-last.json")), "the rest ended (resting-last.json)")
        check(rows[0]["resume"] and "rest until" in rows[0]["line"], "the resume logged")
        check(run.step(r, UNTIL + 50) == [], "under a minute: no look yet")
        rows = run.step(r, UNTIL + 90)
        check([x["action"] for x in rows] == ["still_at_limit"] and len(m.typed) == 1,
              "a minute later its limit text after the message: logged, nothing typed")
        quiet = [run.step(r, UNTIL + 90 + 60 * k) for k in range(1, 19)]
        check(all(q == [] for q in quiet) and len(m.typed) == 1, "no second log, nothing typed before the next nudge")
        rows = run.step(r, UNTIL + 22 + 1200)
        check(len(m.typed) == 2 and rows[0]["try"] == 2, "20 min after the first try: typed again")
        check(run.ended == ["muse"], "the rest ended once")
        m.react = "work"
        rows = run.step(r, UNTIL + 22 + 1290)
        check(rows[0]["action"] == "still_at_limit", "try 2 also met the limit: logged once for it")
        request(m.journal, UNTIL + 22 + 1300)
        rows = run.step(r, UNTIL + 22 + 1350)
        check(rows[0]["action"] == "resumed" and len(m.typed) == 2, "a request of its own: resumed, nothing more typed")
        check(run.step(r, UNTIL + 22 + 4000) == [], "the episode is over")


def mid_turn():
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("muse", "muse", MUSE_BUSY, "working", "work"), ("opus", "claude", CLAUDE_LIMIT, "working", "work"),
                        ("luna", "codex", CODEX_LIMIT, "idle", "work")])
        request(run.pane("luna").journal, UNTIL - 30, "plan_run")   # during the rest: it ended the rest itself
        r = run.resumer()
        rows = run.step(r, UNTIL + 10)
        by = {x["agent"]: x for x in rows}
        check(by["muse"]["action"] == "waiting" and "esc to interrupt" in by["muse"]["why"], "Muse mid-turn: waits")
        check(by["opus"]["action"] == "waiting" and "herdr reads" in by["opus"]["why"], "Claude herdr working: waits")
        check(by["luna"]["action"] == "cleared", "a request of its own since the rest began: cleared, nothing typed")
        check(all(not p.typed for p in run.panes.values()), "nothing typed into a pane mid-turn")
        check(run.step(r, UNTIL + 70) == [], "waiting is logged once")
        run.pane("muse").screen = MUSE_LIMIT
        run.pane("opus").status = "idle"
        rows = run.step(r, UNTIL + 130)
        check(sorted(x["agent"] for x in rows if x["action"] == "typed") == ["muse", "opus"],
              "typed at the first poll after the turn stops")
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("sonnet", "claude", CLAUDE_LIMIT, "idle", "work")])
        # a retry after try 1 met the limit: a describe 50 s before it is not a request of its own (pacing.NOT_OWN)
        r = run.resumer()
        m = run.pane("sonnet")
        r.state["sonnet"] = {"until": UNTIL, "since": T0, "reason": "quota", "kind": "claude", "pane": "w2Y:p0",
                             "phase": "limit", "tries": 1, "t": UNTIL, "logged": set(),
                             "row": {"until": UNTIL, "reason": "quota"}}
        m.screen = CLAUDE_LIMIT
        request(m.journal, UNTIL + 1150, "describe")   # not its own: describe
        m.now = UNTIL + 1200
        rows = run.step(r, UNTIL + 1200)
        check(rows[0]["action"] == "typed", "describe is not a request of its own: the retry types")


def grok():
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("grok", "grok", "You hit your weekly limit.", "blocked", "work")])
        r = run.resumer()
        g = run.pane("grok")
        check(pr.highlighted(grok_dialog(0)) == pr.BUY and pr.highlighted(grok_dialog(1)) == pr.TRY
              and pr.highlighted(grok_dialog(1, plain=True)) is None, "the highlight read from the colours")
        rows = run.step(r, UNTIL + 5)
        check(g.keys == ["down", "enter"] and rows[0]["how"] == "Try Again" and not g.typed,
              "the dialog: down to Try Again, Enter once it shows highlighted; no message typed")
        rows = run.step(r, UNTIL + 70)
        check(rows[0]["action"] == "resumed", "a minute later it works: resumed")
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("grok", "grok", "You hit your weekly limit.", "blocked", "work")])
        g = run.pane("grok")
        g.plain = True
        r = run.resumer()
        rows = run.step(r, UNTIL + 5)
        check("enter" not in g.keys and rows[0]["action"] == "not_typed" and "Enter not pressed" in rows[0]["output"],
              "no highlight to read: nothing pressed")
        check(os.path.exists(os.path.join(tmp, "grok", "resting.json")), "the rest kept until a try goes through")
        g.plain = False
        g.sel = 1
        check(run.step(r, UNTIL + 65) == [], "the next try waits for the next nudge")
        rows = run.step(r, UNTIL + 5 + 1200)
        check(g.keys == ["enter"] and rows[0]["action"] == "typed", "already on Try Again: Enter only")
        check(run.ended == ["grok"] and "rest ended" in rows[0]["line"], "the rest ended at the first try that went through")
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("grok", "grok", "You hit your weekly limit.", "blocked", "limit")])
        r = run.resumer()
        run.step(r, UNTIL + 5)
        rows = run.step(r, UNTIL + 70)
        check(rows[0]["action"] == "still_at_limit", "the dialog back after Try Again: still at its limit, logged")


def claude_codex_agy():
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("haiku", "claude", CLAUDE_LIMIT, "idle", "work"), ("sol", "codex", CODEX_LIMIT, "done", "work"),
                        ("gemini", "agy", "", "idle", "work")])
        r = run.resumer()
        rows = {x["agent"]: x for x in run.step(r, UNTIL + 30)}
        check(rows["haiku"]["how"] == "agent prompt" and rows["sol"]["how"] == "agent prompt",
              "Claude and Codex at their limit: one message each")
        check(rows["gemini"]["action"] == "loop" and not run.pane("gemini").typed and "gemini" not in run.ended,
              "agy: nothing typed, its loop ends the rest")
        rows = {x["agent"]: x for x in run.step(r, UNTIL + 95)}
        check(rows["haiku"]["action"] == "resumed" and rows["sol"]["action"] == "resumed", "working a minute later")
        check(rows["gemini"]["action"] == "loop_not_resumed", "agy's rest still there a minute later: logged")
        check(run.step(r, UNTIL + 200) == [], "logged once")
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("gemini", "agy", "", "idle", "work")])
        r = run.resumer()
        run.step(r, UNTIL + 30)
        pr.aq.end_rest(os.path.join(tmp, "gemini"))   # the loop's --woke
        check(run.step(r, UNTIL + 95) == [], "agy's loop ended it: nothing more")


def dry_and_deadline():
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("muse", "muse", MUSE_LIMIT, "working", "limit"), ("grok", "grok", "You hit your weekly limit.",
                                                                          "blocked", "work")])
        r = run.resumer(dry=True)
        rows = run.step(r, UNTIL + 22)
        check(len(rows) == 2 and all(x.get("dry_run") and not x["sent"] for x in rows), "dry run: logged, sent false")
        check(all(not p.typed and not p.keys for p in run.panes.values()), "dry run: nothing typed or pressed")
        check(os.path.exists(os.path.join(tmp, "muse", "resting.json")) and not run.ended, "dry run: the rest kept")
        check(run.step(r, UNTIL + 40) == [], "dry run: once")
    with tempfile.TemporaryDirectory() as tmp:
        run = Run(tmp, [("muse", "muse", MUSE_LIMIT, "working", "limit")])
        r = run.resumer(deadline=UNTIL)
        check(run.step(r, UNTIL + 22) == [] and not run.pane("muse").typed, "after the run's deadline: nothing")


def wiring():
    import idle_nudge
    check(idle_nudge.Resumer is pr.Resumer, "tools/idle_nudge.py runs the resumer")
    src = open(os.path.join(ROOT, "tools", "idle_nudge.py")).read()
    check("resumer.step(now, write)" in src and 'if entry.get("resume"):' in src, "each poll, and its log line")
    try:
        pr.HerdrPanes()
        check(False, "HerdrPanes refuses under POG_TEST=1")
    except RuntimeError:
        check(True, "HerdrPanes refuses under POG_TEST=1")
    hp = pr.HerdrPanes.__new__(pr.HerdrPanes)
    calls = []

    def run(*args):
        calls.append(args)
        if args[:2] == ("agent", "prompt"):
            return 1, '{"error":{"message":"not an active named agent"}}'
        if args[:2] == ("pane", "get"):
            return 0, '{"id":"cli:pane:get","result":{"pane":{"agent":"muse","agent_status":"working"}}}'
        return 0, '{"result":{"type":"ok"}}'
    hp._run = run
    pr.time.sleep, sleep = (lambda s: None), pr.time.sleep
    try:
        how, ok, _ = hp.prompt("w2Y:pWM", "hello")
    finally:
        pr.time.sleep = sleep
    check(how == "pane send-text" and ok and [c[:2] for c in calls] == [("agent", "prompt"), ("pane", "send-text"),
                                                                         ("pane", "send-keys")]
          and calls[-1][-1] == "enter", "herdr refuses Muse's pane as an agent: send-text, then enter")
    check(hp.status("w2Y:pWM") == "working", "herdr's pane status read")


if __name__ == "__main__":
    muse_shift76()
    mid_turn()
    grok()
    claude_codex_agy()
    dry_and_deadline()
    wiring()
    print("test_pane_resume: all ok")
