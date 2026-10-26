#!/usr/bin/env python3
"""Resume an agent in its pane when its rest ends (d25 batch213 QY1, operator 17:47; tools/idle_nudge.py runs it every
poll).

Muse rested on its weekly limit until Sun 17:00 (shift76, runs/shift76/muse/resting.json). At 17:00 its CLI sat on
"Usage limit reached ... Send a message to continue when usage is available."; the idle nudges at 17:00 and 17:40 went
as game tells ("tell not delivered"), which a CLI stopped at its prompt never reads, and tools/supervise.sh typed
nothing: herdr reads Muse's pane as "working" from its launch on (revision 1 from 14:31 to 17:46, through the limit
screen), so the supervisor never saw it idle. The operator resumed it at 17:44 by typing into the pane.

When a rest's `until` passes (resting.json, any reason), this acts once in the agent's pane (panes.txt: name, pane,
kind), the way each CLI needs it:
- muse, claude, codex: one message, "Operator (automatic): your quota rest ended at Sun 17:00 ...", through
  `herdr agent prompt`, else `herdr pane send-text` and `send-keys enter` (herdr does not take Muse's pane as an agent);
- grok: when its limit dialog is up ("You hit your weekly limit." with 1 Buy more credits, 2 Try Again), Try Again:
  `down` when Buy more credits is the highlighted option, then `enter` only once the screen's colours show Try Again
  highlighted (bold) and Buy more credits not (the operator's d24 16:01 check); otherwise nothing is pressed. Without
  the dialog, a message as above;
- agy: nothing typed. The loop (tools/launch-agent.sh .agy-loop.sh) sleeps until the reset and then ends the rest
  itself (tools/agy-quota.py --woke); a minute after `until`, a resting.json still there is logged once.
Then it logs the resume and ends the rest (resting.json -> resting-last.json, the runtime hears done, as
tools/quota_rest.py --done). A rest the agent already ended with a request of its own (tools/stream/pacing.py) is only
cleared.

Never into a pane mid-turn: nothing is typed while the pane's last lines show a turn running ("esc to interrupt",
Grok's "[stop]"), while herdr reads the pane working (claude, codex and grok; not muse, see above), or within 2 min of
a request of its own in its journal (as supervise.sh); it waits for the next poll.

A minute after it typed: a request of its own since, or a turn running, is a resume (logged). The CLI's limit text
shown again after the message (or Grok's dialog still up) is logged once, and it tries again at the next nudge (every
--every-min after the last try) until the CLI moves or the run's deadline. Each step is a row in runs/RUN/nudges.jsonl
({"resume": true, ...}) and a line in idle-nudge.log. --dry-run reads the panes and types nothing.

Under POG_TEST=1 (tools/testsafe.py) HerdrPanes refuses: tests drive Resumer with fake panes.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
import pacing  # noqa: E402  (resting.json, and a request of the agent's own since a moment)
import testsafe  # noqa: E402

_spec = importlib.util.spec_from_file_location("agy_quota", os.path.join(ROOT, "tools", "agy-quota.py"))
aq = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(aq)

TAG = "Operator (automatic): your"   # the start of the message, to find it on the screen (short enough not to wrap)
# Each CLI's limit text (shift76 Muse's screen; Claude Code's API error rows; the Codex 0.164 and Grok 1.0.70 binaries)
LIMIT = {
    "muse": re.compile(r"Usage limit reached|usage limit was reached|Send a message to continue when usage"),
    "claude": re.compile(r"You've hit your limit|[Uu]sage limit reached|\blimit reached [·∙] resets"),
    "codex": re.compile(r"[Uu]sage limit reached|You've reached your usage limit|hit your usage limit"),
    "grok": re.compile(r"You hit your [a-z ]*limit|Resubmit the last prompt once you have usage again"),
}
DIALOG = re.compile(r"Resubmit the last prompt once you have usage again")   # Grok's limit dialog is up
TRY, BUY = "Try Again", "Buy more credits"
BUSY = re.compile(r"esc to interrupt|\[stop\]", re.I)   # a turn running: Muse, Claude Code, Codex; Grok's spinner line
HERDR_TRACKS = ("claude", "codex", "grok")   # kinds whose herdr status follows the turn (Muse's stays "working")
TAIL = 25          # the screen's last lines that show a turn running
CHECK_S = 60       # the look after typing
RECENT_S = 120     # a request of its own this recent: working (supervise.sh)
SGR = re.compile(r"\x1b\[([0-9;]*)m")


def when(t, now=None):
    return pacing.clock(t, now)


def message(row, now=None):
    """The continue message: facts and the one ask, on one line."""
    end = when(row["until"], now)
    if row.get("reason") == "quota":
        what = f"your quota rest ended at {end}, when your usage limit was due to reset"
    else:
        what = f"your {row.get('reason') or 'quota'} rest ended at {end}"
    return f"{TAG}{what[len('your'):]}. Continue the shift from notes.md and your inbox (./fh tells)."


def bold_before(line, label):
    """Is `label` drawn bold in this ANSI line (the SGR state just before it)? None when the label is not there."""
    i = line.find(label)
    if i < 0:
        return None
    bold = False
    for m in SGR.finditer(line, 0, i):
        for code in (m.group(1) or "0").split(";"):
            if code in ("0", ""):
                bold = False
            elif code == "1":
                bold = True
            elif code == "22":
                bold = False
    return bold


def highlighted(ansi):
    """The option Grok's dialog highlights (bold, the d24 16:01 capture: Try Again on 54,54,54 in bold, Buy more
    credits plain on 36,36,36): TRY or BUY when exactly one of the two is bold, else None."""
    rows = {}
    for line in ansi.splitlines():
        for label in (TRY, BUY):
            if label in line and label not in rows:
                rows[label] = bold_before(line, label)
    if rows.get(TRY) and rows.get(BUY) is False:
        return TRY
    if rows.get(BUY) and rows.get(TRY) is False:
        return BUY
    return None


def team(run_dir):
    """[(name, pane, kind)] from panes.txt."""
    out = []
    try:
        for line in open(os.path.join(run_dir, "panes.txt")):
            parts = line.split()
            if len(parts) >= 3:
                out.append((parts[0], parts[1], parts[2]))
    except OSError:
        pass
    return out


def rest_row(agent_dir):
    """resting.json as written ({since, until, reason, ...}), whether or not it has ended; None."""
    try:
        with open(os.path.join(agent_dir, pacing.REST)) as f:
            row = json.load(f)
    except (OSError, ValueError):
        return None
    return row if isinstance(row, dict) and isinstance(row.get("until"), (int, float)) else None


class HerdrPanes:
    """herdr's pane calls (the CLI, 10 s each)."""

    def __init__(self):
        if testsafe.active():
            raise RuntimeError("POG_TEST=1: no herdr pane reads or typing in a test (use fake panes)")

    def _run(self, *args):
        p = subprocess.run(["herdr", *args], capture_output=True, text=True, timeout=10)
        return p.returncode, (p.stdout or "") + (p.stderr or "")

    def status(self, pane):
        rc, out = self._run("pane", "get", pane)
        try:
            return ((json.loads(out).get("result") or {}).get("pane") or {}).get("agent_status")
        except ValueError:
            return None

    def read(self, pane, ansi=False, recent=False):
        args = ["pane", "read", pane, "--source", "recent" if recent else "visible"]
        if recent:
            args += ["--lines", "150"]
        if ansi:
            args += ["--format", "ansi"]
        rc, out = self._run(*args)
        return out if rc == 0 else ""

    def prompt(self, pane, text):
        """(how, ok, output): herdr agent prompt, else the text typed and Enter."""
        rc, out = self._run("agent", "prompt", pane, text)
        if rc == 0:
            return "agent prompt", True, out[:160]
        rc, out2 = self._run("pane", "send-text", pane, text)
        if rc == 0:
            time.sleep(0.5)
            rc, out2 = self._run("pane", "send-keys", pane, "enter")
        return "pane send-text", rc == 0, (out[:80] + " | " + out2[:80]).strip(" |")

    def keys(self, pane, *keys):
        rc, out = self._run("pane", "send-keys", pane, *keys)
        return rc == 0


class Resumer:
    """The rule, apart from herdr (tests give fake panes)."""

    def __init__(self, run_dir, panes, every_s=1200, deadline=None, dry=False, end_rest=None, pause=time.sleep):
        self.run_dir = run_dir
        self.panes = panes
        self.every_s = every_s
        self.deadline = deadline
        self.dry = dry
        self.end_rest = end_rest or aq.end_rest
        self.pause = pause
        self.state = {}   # agent -> its episode: {until, reason, kind, pane, phase, tries, t, logged}

    def step(self, now, write):
        """One poll for every team member; the rows written."""
        out = []
        for name, pane, kind in team(self.run_dir):
            d = os.path.join(self.run_dir, name)
            row = rest_row(d)
            st = self.state.get(name)
            if row and row["until"] <= now and (not st or st["until"] != row["until"]):
                if self.deadline and now >= self.deadline:
                    continue
                st = self.state[name] = {"until": row["until"], "since": row.get("since"), "reason": row.get("reason"),
                                         "kind": kind, "pane": pane, "phase": "due", "tries": 0, "t": None,
                                         "logged": set(), "row": row}
            if not st or st["phase"] == "over":
                continue
            entry = self.advance(name, d, st, now)
            if entry:
                entry.setdefault("agent", name)
                entry.setdefault("kind", kind)
                entry["resume"] = True
                entry["t"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now))
                entry["rest_until"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(st["until"]))
                if self.dry:
                    entry["dry_run"] = True
                write(entry)
                out.append(entry)
        return out

    def once(self, st, key, entry):
        """entry the first time `key` comes up in this episode, else None."""
        if key in st["logged"]:
            return None
        st["logged"].add(key)
        return entry

    def own_since(self, d, t):
        return t is not None and pacing.requested_since(d, t)

    def mid_turn(self, name, d, st, now):
        """Why the pane is mid-turn now, or None."""
        screen = self.panes.read(st["pane"]) or ""
        tail = "\n".join(screen.splitlines()[-TAIL:])
        m = BUSY.search(tail)
        if m:
            return f"its screen shows a turn running ({m.group(0)})"
        if st["kind"] in HERDR_TRACKS and self.panes.status(st["pane"]) == "working":
            return "herdr reads its pane working"
        if self.own_since(d, now - RECENT_S):
            return f"a request of its own in the last {RECENT_S // 60} min"
        return None

    def at_limit(self, d, st):
        """Does the CLI show its limit screen after the message typed (or Grok's dialog)?"""
        if st["kind"] == "grok" and DIALOG.search(self.panes.read(st["pane"]) or ""):
            return True
        text = self.panes.read(st["pane"], recent=True) or ""
        i = text.rfind(TAG)
        after = text[i:] if i >= 0 else text
        pat = LIMIT.get(st["kind"])
        return bool(pat and pat.search(after))

    def advance(self, name, d, st, now):
        clock = when(st["until"], now)
        if st["kind"] == "agy":
            return self.agy(name, d, st, now, clock)
        if st["phase"] == "due":
            if self.own_since(d, st["since"]):
                st["phase"] = "over"
                if not self.dry:
                    self.end_rest(d)
                return {"action": "cleared", "line": f"resume {name}: its rest until {clock} passed and it has made a "
                        "request of its own since the rest began; nothing typed" + ("" if self.dry else
                                                                                       "; rest ended (resting-last.json)")}
            return self.attempt(name, d, st, now, clock)
        if st["phase"] == "typed":
            if now - st["t"] < CHECK_S:
                return None
            if self.own_since(d, st["t"]) or BUSY.search("\n".join((self.panes.read(st["pane"]) or "").splitlines()[-TAIL:])):
                st["phase"] = "over"
                return {"action": "resumed", "tries": st["tries"],
                        "line": f"resume {name}: resumed ({'a request of its own' if self.own_since(d, st['t']) else 'a turn running'} "
                                f"{round((now - st['t']) / 60)} min after try {st['tries']})"}
            if self.at_limit(d, st):
                st["phase"] = "limit"
                return {"action": "still_at_limit", "tries": st["tries"],
                        "line": f"resume {name}: its CLI still shows its limit screen {round((now - st['t']) / 60)} min "
                                f"after try {st['tries']}; next try at the next nudge ({round(self.every_s / 60)} min after it)"}
            st["phase"] = "over"
            return {"action": "no_limit_screen", "tries": st["tries"],
                    "line": f"resume {name}: no limit screen {round((now - st['t']) / 60)} min after try {st['tries']}, "
                            "and no request of its own or turn running yet"}
        if st["phase"] == "limit":
            if self.own_since(d, st["t"]):
                st["phase"] = "over"
                return {"action": "resumed", "tries": st["tries"],
                        "line": f"resume {name}: resumed (a request of its own after try {st['tries']})"}
            if now - st["t"] < self.every_s or (self.deadline and now >= self.deadline):
                return None
            return self.attempt(name, d, st, now, clock)
        return None

    def attempt(self, name, d, st, now, clock):
        """Type into the pane (not mid-turn), end the rest at the first try that goes through, look again in a minute."""
        busy = self.mid_turn(name, d, st, now)
        if busy:
            return self.once(st, "busy", {"action": "waiting", "why": busy,
                                          "line": f"resume {name}: rest until {clock} passed; not typed while mid-turn "
                                                  f"({busy}); again each poll"})
        n = st["tries"] + 1
        screen = self.panes.read(st["pane"]) or ""
        if st["kind"] == "grok" and DIALOG.search(screen):
            how, ok, said = self.try_again(st["pane"])
            text = None
        else:
            text = message(st["row"], now)
            how, ok, said = ("dry run", True, "") if self.dry else self.panes.prompt(st["pane"], text)
        entry = {"action": "typed" if ok else "not_typed", "try": n, "how": how, "text": text, "sent": ok and not self.dry}
        if said:
            entry["output"] = said
        if not ok:
            st["t"], st["phase"], st["tries"] = now, "limit", n   # the next nudge tries again
            entry["line"] = f"resume {name}: try {n} failed ({how}: {said}); next try at the next nudge"
            return entry
        st["t"], st["phase"], st["tries"] = now, "typed", n
        cleared = ""
        if not self.dry and not st.get("ended"):   # the first try that went through ends the rest
            self.end_rest(d)
            st["ended"] = True
            cleared = "; rest ended (resting-last.json)"
        entry["line"] = (f"resume {name}: rest until {clock} passed; {'dry run: would type' if self.dry else 'typed'} "
                         f"({how}){cleared}")
        return entry

    def try_again(self, pane):
        """(how, ok, output): Grok's dialog answered Try Again, only when the screen shows it highlighted."""
        if self.dry:
            return "Try Again (dry run)", True, ""
        sel = highlighted(self.panes.read(pane, ansi=True) or "")
        if sel == BUY:
            self.panes.keys(pane, "down")
            self.pause(0.5)
            sel = highlighted(self.panes.read(pane, ansi=True) or "")
        if sel != TRY:
            return "Try Again", False, "Try Again not shown highlighted; Enter not pressed"
        ok = self.panes.keys(pane, "enter")
        return "Try Again", ok, "" if ok else "send-keys enter failed"

    def agy(self, name, d, st, now, clock):
        """The agy loop resumes itself: logged at `until`, and once if its rest is still there a minute later."""
        if st["phase"] == "due":
            st["phase"], st["t"] = "watch", now
            return {"action": "loop", "line": f"resume {name}: rest until {clock} passed; its agy loop ends the rest "
                                              "itself (nothing typed)"}
        if now - st["t"] < CHECK_S:
            return None
        st["phase"] = "over"
        row = rest_row(d)
        if row and row["until"] == st["until"] and not self.own_since(d, st["since"]):
            return {"action": "loop_not_resumed", "line": f"resume {name}: its rest until {clock} is still in "
                    f"resting.json {round((now - st['until']) / 60)} min after it, no request of its own since it began"}
        return None
