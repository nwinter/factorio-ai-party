#!/usr/bin/env python3
"""d24 batch158 addendum (viewer Aurora 11:50, 11:51): the idle nudge fits a tell's 500 bytes with the counts first, and
backs off for a session that does not answer, with one handoff to an active lead. No game, no clock:
python3 tools/test_idle_nudge_answer.py"""
import datetime, json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import idle_nudge as N  # noqa: E402

T0 = 1_800_000_000.0


def row(name, standing_min, **kw):
    r = {"name": name, "standing_s": standing_min * 60, "alive": True, "action": None, "queue": {"state": "none"},
         "unread_chat": 0, "unread_mentions": 0, "unread_tells": 0, "unread_board": 0, "last_request_s": 30}
    r.update(kw)
    return r


def journal(run, name, at, action="status"):
    os.makedirs(os.path.join(run, name), exist_ok=True)
    stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    with open(os.path.join(run, name, "journal.jsonl"), "a") as f:
        f.write(json.dumps({"at": stamp, "event": "request", "request": {"action": action, "bot": name, "args": {}}}) + "\n")


MUSE_OPEN = ("open for you: 8 more of yours unchanged for 2h+ left out; 30 machines idle or starved near you (you hold "
             "no fresh claim) (electric-furnace (-161.5,-540.5) output full, 2 tiles; big-mining-drill (-161.5,-536.5) "
             "output blocked, 4 tiles; ...); 1 request or tell to you unanswered (tell from haiku 29m14s ago: haiku "
             "correction on the route: the foundries at (79.5,224.5-234.5) ...)")


def main():
    # Muse at 11:46 (runs/shift69 nudges.jsonl: 1054 bytes, cut at 500 in the unread field, "20"): the counts come
    # first, the unanswered tell comes first among what is open, and the whole is at most 500 bytes
    muse = row("muse", 1079, queue={"state": "paused", "steps": 0}, unread_chat=200, unread_chat_to_you=3,
               unread_mentions=118, unread_tells=110, unacked_tells=3, unacked_oldest_s=1029 * 60, unread_board=6,
               orders={"set": 1, "armed": "fish-heal"}, open=MUSE_OPEN,
               counted={"text": "last 10 min: 0 game actions, 0 reads, 0 messages; working 0%, asleep 0%, waiting 0%, "
                                "standing 100%, on watch 100% of it (standing orders armed: fish-heal)"})
    t = N.nudge_text(muse)
    assert len(t.encode()) <= N.TELL_MAX, len(t.encode())
    assert t.startswith("Operator (automatic, facts only): idle for 1079 min (no action, no queue step). Unread for you: "
                        "200 chat messages (3 naming you), 8 mentions, 110 tells, 3 tells shown, not acknowledged "
                        "(oldest 1029 min), 6 board lines. Queue: paused with 0 steps."), t
    assert "Open for you: 1 request or tell to you unanswered (tell from haiku 29m14s ago" in t, t
    assert t.endswith("..."), t
    # long durations, a long sleep reason, long watch lines and names (UTF-8 too): never over 500 bytes, counts kept
    long = row("Ålesund-Großmeister-" * 4, 10 ** 7, sleeping_s=10 ** 8, unread_chat=10 ** 9, unread_mentions=10 ** 9 + 7,
               unread_tells=7, unacked_tells=10 ** 6, unacked_oldest_s=10 ** 9, unread_board=10 ** 5,
               sleep_reason="wartet auf Ström für die Gießerei " * 30, orders={"set": 12, "armed": "ä" * 400},
               measures=[{"id": "uptime@1", "state": "late", "line": "uptime@1 " + "x" * 600}], open=MUSE_OPEN * 3)
    t = N.nudge_text(long)
    assert len(t.encode()) <= N.TELL_MAX, len(t.encode())
    assert "idle for 10000000 min" in t and "1000000000 chat messages" in t and "1000000 tells shown" in t, t
    t.encode().decode("utf-8")  # whole characters only
    # the parts after the counts: each whole if it fits, else cut at a word and nothing after it
    assert N.fit("abc.", [" one two three.", " four."], limit=30) == "abc. one two three. four."
    cut = N.fit("a" * 20, [" one two three four five six seven eight."], limit=48)
    assert cut == "a" * 20 + " one two three four five..." and len(cut) <= 48, cut
    assert N.top_items("a (b; c); d; e (f (g; h))") == ["a (b; c)", "d", "e (f (g; h))"]

    # a session that does not answer: its tells are not delivered and its journal holds no request of its own since
    # the last nudge: the interval doubles each time (20, 40, 80 min ... at most 4 h); a request of its own ends it
    run = tempfile.mkdtemp()
    for name in ("muse", "haiku", "luna"):
        journal(run, name, T0 - 7200)
    sent, logged = [], []
    send = lambda name, text: sent.append((name, text)) or {"seq": len(sent)}  # noqa: E731
    n = N.Nudger(["muse", "haiku", "luna"], start=T0 - 3600, run_dir=run)
    m = row("muse", 30, unread_tells=5)
    assert [e["agent"] for e in n.step({"agents": [m]}, T0, send, logged.append)] == ["muse"]
    ask = "open for you: 1 request or tell to you unanswered (tell from haiku 1m02s ago: {})"
    m["open"] = ask.format("the route")  # (d24 batch168) a repeat goes on something new asked of it
    assert n.step({"agents": [m]}, T0 + 20 * 60, send, logged.append)[0].get("unanswered") == 1
    why = n.due(m, T0 + 50 * 60)
    assert why == ("not answering (1 nudge not delivered and no request of its own since; no request of its own for "
                   "170 min): idle nudges every 40 min while it does not answer"), why
    m["open"] = ask.format("the foundries")
    assert n.due(m, T0 + 60 * 60) is None, "40 min after the last"
    n.step({"agents": [m]}, T0 + 60 * 60, send, logged.append)
    assert "every 80 min" in n.due(m, T0 + 130 * 60)
    for k in range(6):
        n.unanswered["muse"] = 10
    assert "every 240 min" in n.due(m, T0 + 61 * 60), "at most 4 h"
    journal(run, "muse", T0 + 62 * 60)  # it asks something of its own: answering again
    n.observe(m, T0 + 63 * 60)
    assert n.unanswered["muse"] == 0 and n.due(m, T0 + 80 * 60).startswith("nudged 20 min ago in this idle stretch")
    m["open"] = ask.format("the belts")
    assert n.due(m, T0 + 80 * 60) is None, "answering again: the usual 20 min, on something new"

    # a pane that reads idle or done with no request of its own for 30 min: a session that stopped, backed off at once
    p = N.Nudger(["haiku"], start=T0 - 3600, run_dir=run, pane_status=lambda name: "done")
    h = row("haiku", 40)
    assert p.due(h, T0) is None, "never nudged: the first goes"
    p.step({"agents": [h]}, T0, send, logged.append)
    assert p.due(h, T0 + 25 * 60).startswith("not answering (its pane reads done; no request of its own for 145 min)")
    p.pane_status = lambda name: "working"
    assert p.due(h, T0 + 25 * 60).startswith("nudged 25 min ago in this idle stretch"), "a working pane: the usual rules"

    # a rest (resting.json, as the operator marked Muse's until Sun 17:00) is no nudge; while it does not answer, one
    # handoff goes to the active lead, naming what waits on it; never twice
    os.makedirs(os.path.join(run, "muse"), exist_ok=True)
    json.dump({"since": T0 - 600, "until": T0 + 86400, "reason": "quota", "resets": "Sun 17:00"},
              open(os.path.join(run, "muse", "resting.json"), "w"))
    journal(run, "luna", T0 - 120)
    q = N.Nudger(["muse", "haiku", "luna"], start=T0 - 3600, run_dir=run, leads=["haiku", "luna"])
    sent.clear(); logged.clear()
    rm = row("muse", 300, unread_tells=9, open=MUSE_OPEN)
    rep = {"agents": [rm, row("luna", 0, action="mine"), row("haiku", 0, action="mine")]}
    out = q.step(rep, T0, send, logged.append)
    assert [e.get("handoff") for e in out] == [True] and out[0]["lead"] == "luna", out  # haiku: no request in 10 min
    to, text = sent[0]
    assert to == "luna" and text.startswith("Operator (automatic, facts only): cover request. muse does not answer (out "
                                            "of quota until"), text
    assert "Asked of you until muse makes a request of its own: cover what waits on it." in text, text
    assert "Waiting on it: 1 request or tell to muse unanswered (tell from haiku 29m14s ago" in text and len(text.encode()) <= 500, text
    assert "8 more of yours" not in text and "30 machines" not in text, "only what waits on it"
    assert q.step(rep, T0 + 600, send, logged.append) == [] and len(sent) == 1, "once"
    # nothing waiting on it: no handoff
    r2 = N.Nudger([], start=T0 - 3600, run_dir=run)
    assert r2.step({"agents": [row("muse", 300, open="open for you: 30 machines idle or starved near you")]}, T0,
                   send, logged.append) == []
    # no active lead: logged, not sent
    os.remove(os.path.join(run, "luna", "journal.jsonl"))
    r3 = N.Nudger(["muse", "luna"], start=T0 - 3600, run_dir=run)
    out = r3.step({"agents": [rm, row("luna", 0)]}, T0, send, logged.append)
    assert out[0]["sent"] is False and "no active lead" in out[0]["error"], out
    print("idle nudge answer: ok (500 bytes, counts first, back-off, stopped pane, rest, handoff to an active lead)")


if __name__ == "__main__":
    main()
