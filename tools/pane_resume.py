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

(d25 batch220 QAE1, operator 23:58: Sol's Codex turn ended at ~23:25 on "Selected model is at capacity. Please try a
different model." under a "Set up security for Daybreak mode" dialog; tools/supervise.sh skipped every nudge as
"working" because a background loop of Sol's made a platform_defense request every 20 s, and the operator resumed it
at 23:55.) A CLI stopped on a provider error: an agent with no rest running (no resting.json; a rest is the rule above)
whose pane's last 40 lines show a provider stop (STOP, per CLI, after the last message typed here) and no turn running,
with herdr not reading it working (claude, codex, grok), for --idle-min (the nudge time) in a row. A usage-limit
screen (LIMIT) is never one. Then: a known promo or setup dialog on the screen (DIALOGS) gets one esc, and nothing
else is pressed in it; a dialog still up after the esc is logged and nothing is typed. Then one message, "Operator
(automatic): your last turn stopped on a provider error: <the line>; continue from your tells and notes.".
(d26 batch252 CA, viewer Aurora site:4965; Sol's d25-d26 night: five capacity stops, 23:28-23:54 and 00:46-01:02
resumed by hand, 01:16-01:53 by the deadline prompt only, 02:40-02:51 and 07:08-07:18 by this module) A resume is a
request of its own in its journal after the message whose action the journal did not hold while the CLI was stopped
(the background loop's, platform_defense for Sol), not a keypress or a turn shown: a turn shown with no such request,
the stop shown again, or neither, is logged once a try. The next message goes 5, 10, then 20 min after the last
(BACKOFF_S; never mid-turn), 4 at most (MAX_TRIES; then logged as spent). A stop not resumed 20 min (ALERT_S) after it
was first seen is told once to its cover (idle_nudge's cover_for: an active coverer of one of its claims, else the
handoff's lead), facts only: since when, the line, the tries and their times, no request of its own since; once it
resumes, the cover hears it is back, once. A purchase or credit screen (PURCHASE) on the pane: nothing pressed or
typed, in either rule (d23: Buy more credits is never chosen).

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
# (d25 batch220) Each CLI's provider-stop lines: the Codex 0.164, Claude Code 2.1.310, Grok 1.0.70 and Muse 1.4.13
# binaries' texts (Codex's "■ Selected model is at capacity. Please try a different model.", Sol 23:25 d25).
STOP = {
    "codex": re.compile(r"at capacity|[Rr]ate limit|stream error|stream disconnected|Reconnecting|high demand|"
                        r"[Ss]erver overloaded|[Ii]nternal server error|exceeded retry limit|unexpected status"),
    "claude": re.compile(r"API Error(?!: Request was aborted)|[Oo]verloaded|high load|temporarily limiting requests|"
                         r"Request timed out|Connection error"),
    "grok": re.compile(r"Rate limited|rate limit for your plan|The service is busy|Service unavailable|"
                       r"Something went wrong on our side|did not complete successfully|Connection failed|"
                       r"No response from the model|temporarily overloaded|stopped responding|"
                       r"temporarily unavailable|timed out or was interrupted|Reconnecting"),
    "muse": re.compile(r"model failed|provider error|turn failed|rate limited|[Ss]erver overloaded|server error|"
                       r"connection failed|stream error|stopped before reaching the model"),
}
# Lines that are not a stop although a pattern matches: Codex's switch-model reminder dialog
NOT_STOP = re.compile(r"rate limit reminders|Approaching rate limits")
# Promo or setup dialogs a stopped CLI can show on top (Codex: the Daybreak security setup notice, Sol 23:25 d25 with
# "1 Set up security" and esc dismiss; its model-upgrade and switch-model notices): one esc, never an option chosen
DIALOGS = re.compile(r"Set up security|[Ss]ecurity setup|Codex just got an upgrade|Approaching rate limits")
END = "continue from your tells and notes."
RETRY_S = 1200     # a dialog still up after esc: esc again 20 min later
STOP_TAIL = 40     # the screen's last lines searched for a stop (a dialog on top takes ~10)
# (d26 batch252 CA, viewer Aurora site:4965) a provider-stop episode gets at most MAX_TRIES messages, the next one
# BACKOFF_S after the last (5, 10, 20 min); a resume is a request of its own in the journal after the try whose action
# the journal did not already hold while the CLI was stopped (a background loop's), not a keypress or a turn shown; a
# stop still unresumed ALERT_S after it was first seen is told once to its cover, and its return once.
MAX_TRIES = 4
BACKOFF_S = (300, 600, 1200)
ALERT_S = 1200
# A purchase or credit screen (d23 rule: Buy more credits is never chosen): nothing pressed or typed while it shows
PURCHASE = re.compile(r"Buy more credits|Buy credits|Add credits|Purchase|Add funds|Upgrade (?:your )?plan|[Pp]ayment method")
ALERT_TAG = "Operator (automatic, facts only):"


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


def stop_message(line):
    return f"{TAG} last turn stopped on a provider error: {line}; {END}"


def alert_text(name, ep, now, running):
    """The cover's tell while `name` stays stopped: facts only, one line."""
    n = ep["tries"]
    tried = f"{n} resume{'' if n == 1 else 's'} tried" + (f" ({', '.join(when(t, now) for t in ep['at'])})" if n else "")
    if n >= MAX_TRIES:
        tried += "; no more will be typed"
    bg = sorted(a for a in ep.get("bg") or () if a)
    since = when(ep.get("last_own") or ep["seen"], now)
    text = (f"{ALERT_TAG} {name}'s pane has shown a provider error since {when(ep['seen'], now)} ({ep['line'][:140]}); "
            f"{tried}; no request of its own since {since}"
            + (f" (its journal since holds only {', '.join(bg[:3])} requests)" if bg else "")
            + ("; its pane shows a turn running now." if running else "."))
    return text[:480]


def back_text(name, ep, at, action, now):
    """Its return, told once to the cover that heard the alert."""
    n = ep["tries"]
    return (f"{ALERT_TAG} {name} is back: a request of its own ({action}) at {when(at, now)}, after a provider error on "
            f"its pane from {when(ep['seen'], now)} ({round((at - ep['seen']) / 60)} min; {n} resume{'' if n == 1 else 's'} tried).")


def after_typed(lines):
    """The lines after the last message typed here (its wrapped lines too), or all of them."""
    i = max((k for k, l in enumerate(lines) if TAG in l), default=None)
    if i is None:
        return lines
    acc, end = "", "".join(END.split())   # compared without spaces: a wrap can split a word
    for j in range(i, min(len(lines), i + 12)):
        acc += "".join(lines[j].split())
        if end in acc or "inbox(./fhtells)." in acc:
            return lines[j + 1:]
    return lines[i + 1:]


def provider_stop(kind, screen):
    """The last provider-stop line in the screen's last lines after the last message typed here, or None; None too
    while a turn runs or a usage-limit text shows (pane_resume's rest rule owns those)."""
    tail = after_typed((screen or "").splitlines())[-STOP_TAIL:]
    text = "\n".join(tail)
    if BUSY.search(text) or any(p.search(text) for p in LIMIT.values()) or DIALOG.search(text):
        return None
    pats = [STOP[kind]] if kind in STOP else list(STOP.values())
    for line in reversed(tail):
        if not NOT_STOP.search(line) and not DIALOGS.search(line) and any(p.search(line) for p in pats):
            return " ".join(line.strip(" \t■⚠✗✘•│┃●◆⎿").split())[:200]
    return None


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

    def __init__(self, run_dir, panes, every_s=1200, deadline=None, dry=False, end_rest=None, pause=time.sleep,
                 idle_s=600, cover=None, send=None):
        self.run_dir = run_dir
        self.cover = cover     # (d26 batch252) cover(name, now): who hears that an agent stays stopped, or None
        self.send = send       # send(to, text): an operator tell (idle_nudge's; a dry run sends nothing)
        self.idle_s = idle_s   # (d25 batch220) the nudge time: a provider stop this long gets a message
        self.stops = {}        # agent -> its provider-stop episode: {line, seen, t, tries, phase, logged}
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
                if not row and kind != "agy" and not (self.deadline and now >= self.deadline):
                    entries = self.stopped(name, pane, kind, now) or []
                    for entry in entries if isinstance(entries, list) else [entries]:
                        entry.update({"agent": name, "kind": kind, "resume": True, "provider_stop": True,
                                      "t": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now))})
                        if self.dry:
                            entry["dry_run"] = True
                        write(entry)
                        out.append(entry)
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
        if not (st["kind"] == "grok" and DIALOG.search(screen)) and PURCHASE.search("\n".join(screen.splitlines()[-STOP_TAIL:])):
            st["t"], st["phase"] = now, "limit"   # (d26 batch252) looked at again at the next nudge
            return self.once(st, "purchase", {"action": "purchase_screen", "try": n,
                                              "line": f"resume {name}: rest until {clock} passed; a purchase or credit "
                                                      "screen is on its pane; nothing pressed or typed"})
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

    def stopped(self, name, pane, kind, now):
        """(d25 batch220; d26 batch252 CA) One poll of the provider-stop rule for an agent with no rest: the rows to log."""
        ep = self.stops.get(name)
        d = os.path.join(self.run_dir, name)
        screen = self.panes.read(pane) or ""
        line = provider_stop(kind, screen)
        working = kind in HERDR_TRACKS and self.panes.status(pane) == "working"
        busy = BUSY.search("\n".join(screen.splitlines()[-TAIL:]))
        running = bool(busy or working)
        if ep and ep["tries"]:
            return self.after_try(name, d, pane, ep, now, screen, line, running)
        if running or not line:
            self.stops.pop(name, None)   # before any try: the CLI moved, or the stop is gone; the episode ends
            return None
        if not ep:
            ep = self.stops[name] = {"line": line, "seen": now, "t": None, "tries": 0, "at": [], "logged": set()}
        ep["line"] = line
        if now - ep["seen"] < self.idle_s:
            return None
        rows = [] if ep["t"] is not None and now - ep["t"] < RETRY_S else [self.try_stop(name, d, pane, ep, now, screen)]
        rows.append(self.alert(name, d, ep, now, running))
        return [r for r in rows if r]

    def own_new(self, d, ep):
        """The first request of its own after the last try whose action the journal did not hold while it was stopped,
        as (at, action), or None."""
        for at, action in pacing.requests_since(d, ep["t"]):
            if action not in ep["bg"]:
                return at, action
        return None

    def after_try(self, name, d, pane, ep, now, screen, line, running):
        """After a message: resumed once the journal shows a request of its own; else the try's outcome logged once,
        the next try after its back-off (never mid-turn), and the cover's alert."""
        new = self.own_new(d, ep)
        if new:
            self.stops.pop(name, None)
            at, action = new
            entry = {"action": "resumed", "tries": ep["tries"], "verified": action,
                     "line": f"resume {name}: resumed: a request of its own ({action}) {round((at - ep['t']) / 60)} min "
                             f"after try {ep['tries']}, {round((at - ep['seen']) / 60)} min after the stop was seen"}
            if ep.get("cover"):
                text = back_text(name, ep, at, action, now)
                entry["cover_back"] = {"to": ep["cover"], "text": text, "sent": self.tell(ep["cover"], text)}
                entry["line"] += f"; told {ep['cover']} it is back"
            return [entry]
        if now - ep["t"] < CHECK_S:
            return None
        rows, n, mins = [], ep["tries"], round((now - ep["t"]) / 60)
        if line and ("stop", n) not in ep["logged"]:
            ep["logged"].add(("stop", n))
            ep["line"] = line
            rows.append({"action": "still_stopped", "tries": n, "stop": line,
                         "line": f"resume {name}: its pane shows a provider stop again {mins} min after try {n} ({line})"})
        elif not line and running and ("turn", n) not in ep["logged"]:
            ep["logged"].add(("turn", n))
            rows.append({"action": "turn_running", "tries": n,
                         "line": f"resume {name}: a turn running {mins} min after try {n}; no request of its own in its "
                                 "journal yet (not counted as resumed)"})
        elif not line and not running and ("quiet", n) not in ep["logged"]:
            ep["logged"].add(("quiet", n))
            rows.append({"action": "no_request", "tries": n,
                         "line": f"resume {name}: no turn running, no provider stop and no request of its own {mins} min "
                                 f"after try {n}"})
        if n < MAX_TRIES and not running and now - ep["t"] >= BACKOFF_S[min(n, len(BACKOFF_S)) - 1]:
            rows.append(self.try_stop(name, d, pane, ep, now, screen))
        elif n >= MAX_TRIES and "gave_up" not in ep["logged"] and now - ep["t"] >= BACKOFF_S[-1]:
            ep["logged"].add("gave_up")
            rows.append({"action": "tries_spent", "tries": n,
                         "line": f"resume {name}: {n} tries made since {when(ep['seen'], now)} and no request of its own; "
                                 "nothing more typed this episode"})
        rows.append(self.alert(name, d, ep, now, running))
        return [r for r in rows if r]

    def tell(self, to, text):
        """An operator tell through idle_nudge's send; True when it went (a dry run: False, nothing sent)."""
        if self.dry or not self.send:
            return False
        try:
            self.send(to, text)
            return True
        except Exception:   # noqa: BLE001 (logged in the row as not sent)
            return False

    def alert(self, name, d, ep, now, running):
        """Once per episode, ALERT_S after the stop was first seen: the facts to its cover."""
        if "alert" in ep["logged"] or now - ep["seen"] < ALERT_S:
            return None
        ep["logged"].add("alert")
        if "bg" not in ep:
            ep["bg"] = {a for _, a in pacing.requests_since(d, ep["seen"])}
        older = [at for at, a in pacing.requests_since(d, ep["seen"] - 3 * 3600) if at <= ep["seen"] and a not in ep["bg"]]
        ep["last_own"] = older[-1] if older else None
        to = self.cover(name, now) if self.cover else None
        text = alert_text(name, ep, now, running)
        entry = {"action": "cover_alert", "to": to, "text": text, "tries": ep["tries"]}
        if not to:
            entry.update(sent=False, line=f"resume {name}: stopped {round((now - ep['seen']) / 60)} min; no active cover "
                                          "to tell (a claim's coverer, --lead, or a member with a request of its own in 10 min)")
            return entry
        entry["sent"] = self.tell(to, text)
        if entry["sent"] or self.dry:
            ep["cover"] = to
        entry["line"] = (f"resume {name}: stopped {round((now - ep['seen']) / 60)} min; "
                         + (f"told {to} (cover)" if entry["sent"] else f"dry run: would tell {to}" if self.dry
                            else f"tell to {to} failed"))
        return entry

    def try_stop(self, name, d, pane, ep, now, screen):
        """One message for the stop (a known dialog on top gets one esc first; a purchase screen: nothing)."""
        n = ep["tries"] + 1
        tail = "\n".join(screen.splitlines()[-STOP_TAIL:])
        if PURCHASE.search(tail):
            ep["t"] = now
            if "purchase" in ep["logged"]:
                return None
            ep["logged"].add("purchase")
            return {"action": "purchase_screen", "try": n, "stop": ep["line"],
                    "line": f"resume {name}: a purchase or credit screen is on its pane; nothing pressed or typed"}
        esc = ""
        if DIALOGS.search(tail):   # a dialog sits at the bottom
            if self.dry:
                esc = "esc (dry run) for the dialog on top; "
            else:
                self.panes.keys(pane, "esc")
                self.pause(0.5)
                screen = self.panes.read(pane) or ""
                if DIALOGS.search("\n".join(screen.splitlines()[-STOP_TAIL:])):
                    ep["t"] = now
                    if "dialog" in ep["logged"]:
                        return None
                    ep["logged"].add("dialog")
                    return {"action": "dialog_up", "try": n, "stop": ep["line"],
                            "line": f"resume {name}: a dialog is still on its pane after esc; nothing typed; next try "
                                    f"{RETRY_S // 60} min later"}
                esc = "esc for the dialog on top; "
        if n == 1:   # what the journal holds while it is stopped: a background loop's actions, not a resume
            ep["bg"] = {a for _, a in pacing.requests_since(d, ep["seen"])}
        text = stop_message(ep["line"])
        how, ok, said = ("dry run", True, "") if self.dry else self.panes.prompt(pane, text)
        entry = {"action": "typed" if ok else "not_typed", "try": n, "how": how, "text": text, "stop": ep["line"],
                 "stopped_min": round((now - ep["seen"]) / 60), "sent": ok and not self.dry}
        if said:
            entry["output"] = said
        if ok:
            ep["t"], ep["tries"] = now, n
            ep["at"].append(now)
        else:
            ep["t"] = now   # the next poll after RETRY_S tries again
        nxt = (f"; next try {BACKOFF_S[min(n, len(BACKOFF_S)) - 1] // 60} min later unless it resumes" if n < MAX_TRIES
               else "; the last try this episode")
        entry["line"] = (f"resume {name}: provider stop for {entry['stopped_min']} min ({ep['line']}); {esc}"
                         + (f"{'dry run: would type' if self.dry else 'typed'} ({how}), try {n} of {MAX_TRIES}{nxt}" if ok else
                            f"try {n} failed ({how}: {said}); next try {RETRY_S // 60} min later"))
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
