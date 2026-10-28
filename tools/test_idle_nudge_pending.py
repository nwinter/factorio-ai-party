#!/usr/bin/env python3
"""d28 batch299 CV (viewer Aurora site 00:46: "could batch168 keep failed cover attempts pending? idle_nudge closes the
episode even with no lead. Test later availability and tell failures, without duplicate delivery."): a handoff that
does not go (no active lead, or the tell refused) keeps its episode pending; each poll tries again, one log line for each
kind of failure, one delivery when it goes. No game, no clock: python3 tools/test_idle_nudge_pending.py"""
import datetime, json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import idle_nudge as N  # noqa: E402

T0 = 1_800_000_000.0
OPEN = ("open for you: 1 request or tell to you unanswered (tell from sol 3m10s ago: the Fulgora pad needs a cover); "
        "1 board item of yours (#2101 Gleba spoilage line [doing])")


def row(name, standing_min, **kw):
    r = {"name": name, "standing_s": standing_min * 60, "alive": True, "action": None, "queue": {"state": "none"},
         "unread_chat": 0, "unread_mentions": 0, "unread_tells": 0, "unread_board": 0, "last_request_s": 30}
    r.update(kw)
    return r


def journal(run, name, at):
    os.makedirs(os.path.join(run, name), exist_ok=True)
    stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    with open(os.path.join(run, name, "journal.jsonl"), "a") as f:
        f.write(json.dumps({"at": stamp, "event": "request", "request": {"action": "status", "bot": name, "args": {}}}) + "\n")


def setup():
    run = tempfile.mkdtemp()
    for name in ("muse", "luna"):
        journal(run, name, T0 - 7200)  # luna's last request of its own 2 h ago: not an active lead
    json.dump({"since": T0 - 600, "until": T0 + 86400, "reason": "quota"},
              open(os.path.join(run, "muse", "resting.json"), "w"))
    n = N.Nudger(["muse", "luna"], start=T0 - 3600, run_dir=run, leads=["luna"])
    rep = {"agents": [row("muse", 300, unread_tells=2, open=OPEN), row("luna", 0, action="mine")]}
    return run, n, rep


def main():
    # no active lead, then a lead appears: logged once while none, delivered once when one is active
    run, n, rep = setup()
    sent, logged = [], []
    send = lambda to, text: sent.append((to, text)) or {"seq": len(sent)}  # noqa: E731
    out = n.step(rep, T0, send, logged.append)
    assert [(e["sent"], e["lead"]) for e in out] == [(False, None)] and "no active lead" in out[0]["error"], out
    for k in range(1, 30):  # 29 more polls a minute apart, still no lead: nothing sent, nothing logged again
        assert n.step(rep, T0 + 60 * k, send, logged.append) == [], k
    assert sent == [] and len(logged) == 1, logged
    journal(run, "luna", T0 + 30 * 60 - 20)  # luna makes a request of its own: an active lead
    out = n.step(rep, T0 + 30 * 60, send, logged.append)
    assert [(e["sent"], e["lead"], e["after_failed"], e["handoff_n"]) for e in out] == [(True, "luna", 30, 1)], out
    assert len(sent) == 1 and sent[0][0] == "luna" and "cover request. muse" in sent[0][1], sent
    assert logged[0]["pending"] is True, logged[0]
    for k in range(31, 60):  # delivered: never again in this episode
        journal(run, "luna", T0 + 60 * k - 20)
        assert n.step(rep, T0 + 60 * k, send, logged.append) == [], k
    assert len(sent) == 1 and len(logged) == 2, (sent, logged)

    # the tell refused (the RCON call failed): logged once, tried again each poll, delivered once when it goes
    run, n, rep = setup()
    journal(run, "luna", T0 - 20)
    sent, logged, fail = [], [], [3]

    def flaky(to, text):
        if fail[0]:
            fail[0] -= 1
            raise RuntimeError(f"tell: rcon timed out ({fail[0]})")
        sent.append((to, text))
        return {"seq": 7}
    for k in range(5):
        journal(run, "luna", T0 + 60 * k - 20)
        n.step(rep, T0 + 60 * k, flaky, logged.append)
    assert [(e["sent"], e.get("pending")) for e in logged] == [(False, True), (True, None)], logged
    assert logged[0]["error"].startswith("RuntimeError: tell: rcon timed out") and logged[1]["after_failed"] == 3, logged
    assert len(sent) == 1, sent

    # each kind once: no lead, then the tell refused, then delivered
    run, n, rep = setup()
    sent, logged, fail = [], [], [2]
    n.step(rep, T0, flaky, logged.append)
    n.step(rep, T0 + 60, flaky, logged.append)
    for k in range(2, 6):
        journal(run, "luna", T0 + 60 * k - 20)
        n.step(rep, T0 + 60 * k, flaky, logged.append)
    assert [("no active lead" in (e.get("error") or ""), e["sent"]) for e in logged] == [(True, False), (False, False),
                                                                                       (False, True)], logged
    assert len(sent) == 1 and logged[2]["after_failed"] == 4, logged

    # a pending episode that ends (it makes a request of its own) sent nothing: no back-off counted; still resting, a
    # new episode begins (its own log line), and its handoff goes as soon as a lead is active
    run, n, rep = setup()
    sent, logged = [], []
    n.step(rep, T0, send, logged.append)
    journal(run, "muse", T0 + 120)
    n.step(rep, T0 + 180, send, logged.append)
    assert n.episode["muse"]["since"] == T0 + 180 and n.handoffs.get("muse", 0) == 0, (n.episode, n.handoffs)
    assert [e["episode_since"] for e in logged] == [N.datetime.datetime.fromtimestamp(t).astimezone().isoformat(
        timespec="seconds") for t in (T0, T0 + 180)], logged
    journal(run, "luna", T0 + 280)
    out = n.step(rep, T0 + 300, send, logged.append)
    assert [e["sent"] for e in out] == [True] and out[0]["after_failed"] == 1 and len(sent) == 1, out
    print("idle nudge pending: ok (no lead then a lead: one delivery; no repeat log lines; tell failures retried; "
          "each kind logged once)")


if __name__ == "__main__":
    main()
