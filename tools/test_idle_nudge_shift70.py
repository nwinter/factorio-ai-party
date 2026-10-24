#!/usr/bin/env python3
"""d24 batch168 QK1 (operator 14:35, viewer Aurora 14:29): the idle nudge's "does not answer" handoff, once per episode.
No game, no clock: python3 tools/test_idle_nudge_shift70.py [--module PATH]

shift70 13:52-14:32: Gemini rested about 5 and 10 minutes at a time to pace its quota (resting.json reason pace) and
played between; the idle nudge sent 22 "gemini does not answer" handoffs to its leads, one a minute in each rest, and
one for Grok (out of quota). Replayed here from tools/idle_nudge_shift70.json, built from runs/shift70: Gemini's own
requests and game actions (its journal), its rests (context.log, agy-pace), Grok's quota rest, the leads' requests,
and what each logged handoff named as waiting. Gemini's standing is reconstructed: 20 min at 13:57:06 (its logged
nudge), then since its last game action. --module PATH replays through another idle_nudge.py (main's: 23 notices).
"""
import argparse, datetime, importlib.util, json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stream"))
sys.dont_write_bytecode = True


def load(path):
    spec = importlib.util.spec_from_file_location("idle_nudge_replay", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def stamp(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def replay(N, fx):
    """Poll once a minute from the process start to its last poll (14:32:14) as the shift's idle nudge did; returns
    (sent, log rows)."""
    run = tempfile.mkdtemp()
    try:
        g = fx["gemini"]
        names = ["gemini", "grok"] + list(fx["leads"])
        for n in names:
            os.makedirs(os.path.join(run, n))
        json.dump(fx["grok"]["rest"], open(os.path.join(run, "grok", "resting.json"), "w"))
        written = {n: 0 for n in names}
        reqs = dict(fx["leads"], gemini=g["requests"], grok=[])

        def journals(now):  # each journal holds what was written by now
            for n, times in reqs.items():
                with open(os.path.join(run, n, "journal.jsonl"), "a") as f:
                    while written[n] < len(times) and times[written[n]] <= now:
                        f.write(json.dumps({"at": stamp(times[written[n]]), "event": "request",
                                            "request": {"action": "status", "bot": n, "args": {}}}) + "\n")
                        written[n] += 1

        def rests(now):  # resting.json: the latest rest begun; resting-last.json: the one before (agy-quota --woke)
            begun = [r for r in g["rests"] if r["since"] <= now]
            for f, r in (("resting.json", begun[-1] if begun else None), ("resting-last.json", begun[-2] if len(begun) > 1 else None)):
                path = os.path.join(run, "gemini", f)
                if r:
                    json.dump(r, open(path, "w"))
                elif os.path.exists(path):
                    os.remove(path)

        def opened(agent, now, default):
            seen = [w for w in fx["waiting"] if w["agent"] == agent and w["t"] <= now + 5]
            ahead = [w for w in fx["waiting"] if w["agent"] == agent]
            return seen[-1]["open"] if seen else (ahead[0]["open"] if agent == "gemini" else default)

        def row(name, standing_s, **kw):
            r = {"name": name, "standing_s": standing_s, "alive": True, "action": None, "queue": {"state": "paused", "steps": 0},
                 "unread_chat": 0, "unread_mentions": 0, "unread_tells": 0, "unread_board": 0,
                 "counted": {"text": "last 10 min: as the shift's harness counted"}}  # its standing is the only count
            r.update(kw)
            return r

        n = N.Nudger(names, start=fx["start"], run_dir=run)
        sent, logged = [], []
        send = lambda to, text: sent.append((to, text)) or {"seq": len(sent)}  # noqa: E731
        t = fx["start"]
        while t <= fx["end"]:
            journals(t)
            rests(t)
            work = [w[0] for w in g["work"] if w[0] <= t]
            since = max([fx["gemini_standing_since"]] + work)
            resting = any(r["since"] <= t < r["until"] for r in g["rests"])
            last = max([x for x in g["requests"] if x <= t], default=fx["start"])
            gem = row("gemini", int(t - since), unread_tells=1 if resting else 0, last_request_s=int(t - last),
                      open=opened("gemini", t, ""))
            # before 14:30 nothing waited on Grok (main's handoff went first then): idle machines near it stand in
            grok = row("grok", int(t - fx["grok"]["rest"]["since"]) + 3600, unread_tells=1,
                       open=opened("grok", t, "open for you: 12 machines idle or starved near you (you hold no fresh claim)"))
            leads = [row(x, 0, action="mine", last_request_s=0) for x in fx["leads"]]
            n.step({"agents": [gem, grok] + leads}, t, send, logged.append)
            t += 60.2  # the shift's polls: 13:47:05 to 14:32:14 is 45 of them
        return sent, logged
    finally:
        shutil.rmtree(run, ignore_errors=True)


def notices(logged):
    return [e for e in logged if e.get("handoff") and e.get("sent")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--module", default=os.path.join(HERE, "idle_nudge.py"))
    a = ap.parse_args()
    fx = json.load(open(os.path.join(HERE, "idle_nudge_shift70.json")))
    N = load(a.module)
    recorded = [e for e in fx["logged"] if e["handoff"]]
    assert len(recorded) == 23 and sum(e["agent"] == "gemini" for e in recorded) == 22, len(recorded)
    sent, logged = replay(N, fx)
    got = notices(logged)
    by = {x: sum(e["agent"] == x for e in got) for x in ("gemini", "grok")}
    print(f"shift70 13:47-14:32 replayed through {os.path.relpath(a.module, os.path.dirname(HERE))}: {len(got)} "
          f"'does not answer' notices (gemini {by['gemini']}, grok {by['grok']}); recorded in nudges.jsonl: 23 "
          f"(gemini 22, grok 1)")
    if a.module != os.path.join(HERE, "idle_nudge.py"):
        return
    # after: Gemini's pace rests are its loop pacing its quota, so it is not "not answering" and no handoff goes for it;
    # Grok, out of quota until 15:59, gets one, once (its episode lasts until it makes a request of its own)
    assert by == {"gemini": 0, "grok": 1}, [(e["t"], e["agent"], e["why"]) for e in got]
    grok = got[0]
    assert grok["t"][:16] in ("2026-10-24T14:30", "2026-10-24T14:31") and grok["why"] == "out of quota until 15:59", grok
    assert grok["text"].startswith("Operator (automatic, facts only): cover request. grok does not answer (out of quota "
                                   "until 15:59). Asked of you until grok makes a request of its own: cover what waits "
                                   "on it. Waiting on it: 1 request or tell to grok unanswered (tell from luna"), grok["text"]
    # Gemini's own idle nudge: once, at 13:57:06 as in the shift (20 min standing less its 5 min pace rest: 15 min)
    gem = [e for e in logged if e["agent"] == "gemini" and not e.get("handoff")]
    assert [(e["t"][11:16], e["standing_min"]) for e in gem] == [("13:57", 15)], [(e["t"], e["standing_min"]) for e in gem]
    print("idle nudge shift70: ok (pace rests answer, one handoff per episode, cover request text)")
    rules(N)


def rules(N):
    """The episode, the shared back-off and the cover text, apart from the replay."""
    T0 = 1_800_000_000.0
    run = tempfile.mkdtemp()
    try:
        for name in ("gemini", "luna"):
            os.makedirs(os.path.join(run, name))

        def request(name, at):
            with open(os.path.join(run, name, "journal.jsonl"), "a") as f:
                f.write(json.dumps({"at": stamp(at), "event": "request", "request": {"action": "status", "bot": name, "args": {}}}) + "\n")

        def rest(name, since, until, reason):
            json.dump({"since": since, "until": until, "reason": reason}, open(os.path.join(run, name, "resting.json"), "w"))
        opened = ("open for you: 1 board item of yours (#2035 Fulgora silo freight [doing]); 2 alert groups in your claims "
                  "(accumulator low (claim #523)); 2 requests or tells to you unanswered (tell from sol 50s ago: power 523 "
                  "at 26%)")
        gem = {"name": "gemini", "standing_s": 3600, "alive": True, "queue": {"state": "none"}, "open": opened,
               "counted": {"text": "last 10 min: 0 game actions"}}
        lead = {"name": "luna", "standing_s": 0, "alive": True, "action": "mine"}
        sent, logged = [], []
        send = lambda to, text: sent.append((to, text)) or {"seq": len(sent)}  # noqa: E731
        n = N.Nudger(["gemini", "luna"], start=T0 - 3600, run_dir=run)
        request("gemini", T0 - 7200)
        # a quota rest: one handoff for the episode, naming the owner, the items, the cover call for its claim
        rest("gemini", T0 - 60, T0 + 7200, "quota")
        for k in range(30):
            request("luna", T0 + 60 * k - 30)
            n.step({"agents": [gem, lead]}, T0 + 60 * k, send, logged.append)
        assert len(sent) == 1 and sent[0][0] == "luna", sent
        text = sent[0][1]
        assert text.startswith("Operator (automatic, facts only): cover request. gemini owns #2035, #523 and does not "
                               "answer (out of quota until "), text
        assert ("Asked of you until gemini makes a request of its own: cover #2035 and what waits on it; board_update "
                "{id: 523, cover: true} for its claim #523 (you hear its alerts with gemini). Waiting on it: 2 requests or "
                "tells to gemini unanswered (tell from sol 50s ago: power 523 at 26%); 1 board item of gemini's (#2035") in text, text
        assert len(text.encode()) <= N.TELL_MAX and logged[0]["handoff_n"] == 1, logged[0]
        # it makes a request of its own: the episode ends; it rests again: a new episode, its handoff 40 min after the
        # last (every_min doubled once), then 80
        request("gemini", T0 + 31 * 60)
        rest("gemini", T0 + 32 * 60, T0 + 7200, "quota")
        n.step({"agents": [gem, lead]}, T0 + 32 * 60, send, logged.append)
        assert len(sent) == 1, "the second episode's handoff waits for the back-off"
        request("luna", T0 + 40 * 60 - 30)
        n.step({"agents": [gem, lead]}, T0 + 40 * 60, send, logged.append)
        assert len(sent) == 2 and logged[-1]["handoff_n"] == 2, logged[-1]
        request("gemini", T0 + 41 * 60)
        rest("gemini", T0 + 42 * 60, T0 + 7200, "quota")
        request("luna", T0 + 119 * 60 - 30)
        n.step({"agents": [gem, lead]}, T0 + 119 * 60, send, logged.append)
        assert len(sent) == 2
        request("luna", T0 + 120 * 60 - 30)
        n.step({"agents": [gem, lead]}, T0 + 120 * 60, send, logged.append)
        assert len(sent) == 3, "80 min after the last"
        # the harness's line when nothing is open names no item
        none = dict(gem, name="grok", open="open for you: none (no board items of yours, no fresh claims, no unanswered "
                                           "requests or tells)")
        assert N.waiting_items(none["open"]) == [] and N.asks(none) == (set(), 0, 0)
        # a short pace rest: no handoff, no nudge, not standing; a long one (over 30 min) is an episode
        m = N.Nudger(["gemini", "luna"], start=T0 - 3600, run_dir=run)
        rest("gemini", T0 + 200 * 60, T0 + 210 * 60, "pace")
        sent.clear()
        request("luna", T0 + 205 * 60 - 30)
        assert m.step({"agents": [gem, lead]}, T0 + 205 * 60, send, logged.append) == [] and not sent
        assert m.due(gem, T0 + 205 * 60).startswith("resting until"), m.due(gem, T0 + 205 * 60)
        assert m.standing(dict(gem, standing_s=900), T0 + 211 * 60) == 300, "15 min less its 10 min rest"
        assert m.silence("gemini", T0 + 211 * 60) == (0, ""), "a pace rest is a sign of life"
        rest("gemini", T0 + 220 * 60, T0 + 260 * 60, "pace")
        request("luna", T0 + 225 * 60 - 30)
        out = m.step({"agents": [gem, lead]}, T0 + 225 * 60, send, logged.append)
        assert [e.get("handoff") for e in out] == [True] and "resting until" in out[0]["why"], out
        # a wait it set itself with a known end holds the nudge while it lasts, when it began soon after its last work;
        # back-to-back waits do not
        w = N.Nudger(["haiku"], start=T0 - 3600)
        nap = {"name": "haiku", "standing_s": 13 * 60, "alive": True, "action": "sleep", "sleeping_s": 8 * 60,
               "sleep_left_s": 4 * 60, "queue": {"state": "none"}}
        assert w.step({"agents": [nap]}, T0, send, logged.append) == []
        assert w.due(nap, T0) == "in its own sleep (4 min left)", w.due(nap, T0)
        assert w.due(dict(nap, standing_s=25 * 60), T0) is None, "it stood 17 min before this sleep"
        wt = {"name": "haiku", "standing_s": 12 * 60, "alive": True, "action": "wait_ticks", "action_until_s": 600,
              "queue": {"state": "none"}}
        x = N.Nudger(["haiku"], start=T0 - 3600)
        x.observe(dict(wt, standing_s=7 * 60, action_until_s=900), T0 - 300)
        x.observe(wt, T0)
        assert x.due(wt, T0) == "in its own wait_ticks (10 min left)", "it began 7 min after its last work"
        x.observe(dict(wt, standing_s=21 * 60, action_until_s=60), T0 + 540)
        x.observe(dict(wt, standing_s=22 * 60, action_until_s=600), T0 + 600)
        assert x.due(dict(wt, standing_s=22 * 60, action_until_s=600), T0 + 600) is None, "a new wait, back to back"
        # an overdue watch is something new for a repeat
        y = N.Nudger(["haiku"], start=T0 - 3600)
        idle = {"name": "haiku", "standing_s": 15 * 60, "alive": True, "queue": {"state": "none"},
                "counted": {"text": "last 10 min: 0 game actions"}}
        y.step({"agents": [idle]}, T0, send, logged.append)
        idle = dict(idle, standing_s=40 * 60)  # 25 min on
        assert y.due(idle, T0 + 25 * 60).startswith("nudged 25 min ago in this idle stretch")
        late = dict(idle, measures=[{"id": "uptime@1", "state": "late", "line": "uptime@1 late"}])
        assert y.due(late, T0 + 25 * 60) is None
        assert y.step({"agents": [late]}, T0 + 25 * 60, send, logged.append)[0]["repeat"] == {"n": 2, "why": "a watch overdue"}
        # it works: a new idle stretch, its first nudge at the usual 20 min
        y.observe(dict(idle, standing_s=60), T0 + 30 * 60)
        assert y.due(dict(idle, standing_s=12 * 60), T0 + 45 * 60) is None
    finally:
        shutil.rmtree(run, ignore_errors=True)
    print("idle nudge episodes: ok (one per episode, shared back-off, short pace rests, own waits, overdue watch)")


if __name__ == "__main__":
    main()
