#!/usr/bin/env python3
"""(mt283, private) Stand-in agents for a load test of a private copy (never world n): each named bot does what agents
do most, in turn, at a set rate of calls: reads (status, observe, game_alerts, board, tells), a direct wait, a small
build and its mining back, and one repeating queue (a hand craft every 20 s). One RCON connection, calls one at a time.

  python3 tools/mt/standin_load.py --port 27476 --password-file ~/.config/pog/rcon-imac-mt.pw \\
      --bots astra,sol,luna,rb1,rb2,rb3 --minutes 30 --rate 0.9 --out runs/x/load.jsonl

--rate: calls a second per bot (world n's agents made about 0.9: 336 calls in 40 s for 9). Each call's round trip,
reply size and outcome go to --out, one JSON line each; the end prints the calls made, the rate reached and the round
trip's median, p99 and max per action. The bots need wooden chests and iron plates (--give puts 50 and 400 in each).
"""
import argparse, json, os, statistics, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import pog  # noqa: E402

CYCLE = ["status", "observe", "game_alerts", "build", "board", "mine", "wait_ticks", "tells"]


class Copy:
    def __init__(self, a):
        if a.port in (27025,):
            sys.exit("refusing world n's port")
        self.r = pog.Rcon(a.host, a.port, open(os.path.expanduser(a.password_file)).read().strip(), timeout=120)
        self.n = 0

    def lua(self, code):
        return self.r.command("/silent-command __agent-harness__ " + code)

    def call(self, bot, action, args):
        self.n += 1
        req = json.dumps({"id": f"standin-{bot}-{time.time_ns()}-{self.n}", "bot": bot, "action": action, "args": args})
        t0 = time.perf_counter()
        txt = self.r.command("/silent-command rcon.print(remote.call('agent_harness','dispatch',[==[" + req + "]==]))")
        ms = (time.perf_counter() - t0) * 1000
        try:
            env = json.loads(txt)
        except ValueError:
            env = {"ok": False, "error": {"message": txt[:200]}}
        return env, ms, len(txt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="imac.local")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--password-file", required=True)
    ap.add_argument("--bots", required=True)
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--rate", type=float, default=0.9)
    ap.add_argument("--give", action="store_true")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    bots = a.bots.split(",")
    c = Copy(a)
    if a.give:
        names = ",".join(f"'{b}'" for b in bots)
        print(c.lua("local out={} for _,n in ipairs({" + names + "}) do local b=storage.agent_harness.bots.by_name[n]; "
                    "local ch=b and b.character; if ch and ch.valid then ch.insert{name='wooden-chest',count=50}; "
                    "ch.insert{name='iron-plate',count=400}; out[#out+1]=n end end rcon.print('given: '..table.concat(out,' '))"))
    spots = {}
    for b in bots:
        env, _, _ = c.call(b, "status", {"peek": True})
        pos = ((env.get("result") or {}).get("position")) or {"x": 0, "y": 0}
        # a free tile for the chest within reach (find_non_colliding_position round 3 tiles east of the bot)
        got = c.lua("local c=storage.agent_harness.bots.by_name['" + b + "'].character; local p=c.surface.find_non_colliding_position("
                    "'wooden-chest',{c.position.x+3,c.position.y},6,1,true); rcon.print(p and (p.x..' '..p.y) or '')").split()
        spots[b] = {"x": float(got[0]), "y": float(got[1])} if len(got) == 2 else {"x": round(pos["x"]) + 3.5, "y": round(pos["y"]) + 0.5}
        env, _, _ = c.call(b, "queue_repeat", {"name": "standin", "interval_ticks": 1200,
                                                "steps": [{"action": "craft", "args": {"item": "iron-gear-wheel", "count": 2}}]})
        print(b, "queue:", "ok" if env.get("ok") else (env.get("error") or {}).get("message", "")[:120])
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    out = open(a.out, "w")
    step = {b: i for i, b in enumerate(bots)}
    every = 1.0 / (a.rate * len(bots))
    t_end = time.time() + a.minutes * 60
    nxt = time.time()
    k = 0
    while time.time() < t_end:
        b = bots[k % len(bots)]
        k += 1
        act = CYCLE[step[b] % len(CYCLE)]
        step[b] += 1
        args = {}
        if act == "observe":
            args = {"radius": 24}
        elif act == "build":
            args = {"item": "wooden-chest", "position": spots[b], "queue_resume_after": True}
        elif act == "mine":
            args = {"position": spots[b], "queue_resume_after": True}
        elif act == "wait_ticks":
            args = {"ticks": 240}
        env, ms, size = c.call(b, act, args)
        out.write(json.dumps({"t": round(time.time(), 3), "bot": b, "action": act, "ms": round(ms, 2), "bytes": size,
                              "ok": bool(env.get("ok")), "tick": env.get("tick"),
                              "error": None if env.get("ok") else (env.get("error") or {}).get("message", "")[:160]}) + "\n")
        nxt += every
        wait = nxt - time.time()
        if wait > 0:
            time.sleep(wait)
        else:
            nxt = time.time()
    out.close()
    rows = [json.loads(x) for x in open(a.out)]
    span = rows[-1]["t"] - rows[0]["t"] if len(rows) > 1 else 1
    print(f"{len(rows)} calls in {span:.0f} s: {len(rows) / span:.2f} a second (asked {a.rate * len(bots):.2f}); "
          f"{sum(1 for r in rows if not r['ok'])} failed")
    for act in CYCLE:
        ms = sorted(r["ms"] for r in rows if r["action"] == act)
        if ms:
            p99 = ms[min(len(ms) - 1, int(len(ms) * 0.99))]
            print(f"  {act}: {len(ms)} calls, round trip median {statistics.median(ms):.1f} ms, p99 {p99:.1f}, max {ms[-1]:.1f}")


if __name__ == "__main__":
    main()
