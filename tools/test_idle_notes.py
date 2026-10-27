#!/usr/bin/env python3
"""Idle nudges tell unread notes from work that asks or is due (d26 batch252 IN, viewer Aurora site:4852: "Could idle
checks separate unread notes from overdue work? Sonnet's no-action tower FYI and Haiku's completed-transfer thanks
appeared as unanswered"). The harness's open line (open.lua, tests/d26_batch252.lua) now has three parts for these:
"requests or tells to you unanswered" (they ask), "board items of yours overdue for review" (work due) and "unread notes
to you asking nothing". Here, tools/idle_nudge.py: the nudge lists what asks, then what is due, notes last; a new note
is no reason to nudge again, a board item newly overdue is; a handoff carries the overdue items, not the notes.
No game, no clock: python3 tools/test_idle_notes.py. Fails on main (no overdue_ids; notes not ordered last).
"""
import datetime, json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import idle_nudge as N  # noqa: E402

T0 = 1_800_000_000.0
NOTE = ("2 unread notes to you asking nothing (tell from sonnet 4m00s ago: Tower (11.5,6.5) is hot and idle by design. "
        "No action needed.; tell from haiku 9m00s ago: Thanks. Transfer #2283 is complete)")
ASK = "1 request or tell to you unanswered (tell from luna 3m10s ago: Please confirm if tower (77.5,48.5) is intentional.)"
DUE = "1 board item of yours overdue for review (board #1301 Build patch-2 uranium outpost: next check at tick 1, 10s ago)"


def row(name, **kw):
    r = {"name": name, "standing_s": 30 * 60, "alive": True, "action": None, "queue": {"state": "none"},
         "unread_chat": 0, "unread_mentions": 0, "unread_tells": 2, "unread_board": 0, "last_request_s": 30}
    r.update(kw)
    return r


def journal(run, name, at):
    os.makedirs(os.path.join(run, name), exist_ok=True)
    stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    with open(os.path.join(run, name, "journal.jsonl"), "a") as f:
        f.write(json.dumps({"at": stamp, "event": "request", "request": {"action": "status", "bot": name, "args": {}}}) + "\n")


def check(cond, what):
    if not cond:
        raise AssertionError(what)
    print("ok", what)


def main():
    t = N.open_text(f"open for you: {NOTE}; 1 board item of yours (#1301 Build patch-2 [doing]); {DUE}; {ASK}")
    check(t.index("unanswered") < t.index("overdue for review") < t.index("#1301 Build patch-2 [doing]") < t.index("asking nothing"),
          "the nudge's open part: what asks, then what is due, then the rest, notes last")
    text = N.nudge_text(row("muse", open=f"open for you: {NOTE}; {ASK}"))
    check("Open for you: " + ASK in text, "the nudge text: the ask first")

    run = tempfile.mkdtemp()
    for name in ("muse", "luna"):
        journal(run, name, T0 - 60)
    sent, logged = [], []
    send = lambda name, text: sent.append((name, text)) or {"seq": len(sent)}  # noqa: E731
    n = N.Nudger(["muse", "luna"], start=T0 - 3600, run_dir=run)
    m = row("muse", open=f"open for you: {ASK}")
    n.step({"agents": [m]}, T0, send, logged.append)
    check(n.base["muse"]["overdue"] == set(), "the nudge keeps what was overdue at it (none)")
    m["open"] = f"open for you: {ASK}; {NOTE}"
    check(n.change(m) == "", "a new note that asks nothing is no reason to nudge again")
    m["open"] = f"open for you: {ASK}; {DUE}; {NOTE}"
    check(n.change(m) == "a board item newly overdue for review", "a board item newly overdue is")
    check(N.overdue_ids(m) == {"1301"}, "overdue ids from the open line")

    # a handoff for one that does not answer: what waits on it is the ask and the overdue item, never a note
    h = n.handoff(m, "not answering", {"agents": [m, row("luna")]}, T0, send, logged.append)
    check(h and h["lead"] == "luna" and "board #1301" in h["text"] and "luna 3m10s ago" in h["text"]
          and "asking nothing" not in h["text"] and "Tower (11.5,6.5)" not in h["text"],
          "a handoff carries the ask and the overdue item, not the notes")
    print("test_idle_notes: all ok")


if __name__ == "__main__":
    main()
