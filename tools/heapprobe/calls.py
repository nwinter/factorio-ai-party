#!/usr/bin/env python3
"""calls.py WORLD N MODE: N rounds of dispatch calls as sol (signal_watch {}, status), one RCON command each.
MODE: normal | stop (collector stopped around each call) | collect (a full collect just before each call, untimed)."""
import sys, os, time, re, json
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pog
world, n, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
assert world != "n"
pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
r = pog.Rcon(pog.HOSTS.get(world, "127.0.0.1"), pog.PORTS[world], pw, timeout=60)
ACTIONS = [("signal_watch", {}), ("status", {})]
pre = {"normal": "", "stop": "collectgarbage('stop')", "collect": "collectgarbage('collect')"}[mode]
post = "collectgarbage('restart')" if mode == "stop" else ""
rows = []
for i in range(n):
    for a, args in ACTIONS:
        req = json.dumps({"id": f"b334-{mode}-{a}-{i}-{time.time():.3f}", "action": a, "bot": "sol", "args": args})
        lua = (f"{pre} local kb0=collectgarbage('count') local p=helpers.create_profiler() "
               f"local out=remote.call('agent_harness','dispatch',[==[{req}]==]) p.stop() local kb1=collectgarbage('count') {post} "
               f"rcon.print({{'', 'T ', p, ' kb0=', math.floor(kb0), ' kb1=', math.floor(kb1), ' bytes=', #out, ' tick=', game.tick}})")
        out = r.command("/silent-command __agent-harness__ " + lua)
        m = re.search(r"Duration: ([\d.]+)ms kb0=(\d+) kb1=(\d+) bytes=(\d+) tick=(\d+)", out)
        if not m:
            print("ERR", a, out[:200]); continue
        ms, kb0, kb1, by, tick = float(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5])
        rows.append({"action": a, "ms": ms, "kb0": kb0, "kb1": kb1, "bytes": by, "tick": tick, "mode": mode})
        time.sleep(0.25)
json.dump(rows, open(f"calls_{mode}_{int(time.time())}.json", "w"))  # in the current directory
for a, _ in ACTIONS:
    rs = [x for x in rows if x["action"] == a]
    ms = sorted(x["ms"] for x in rs)
    fell = [x for x in rs if x["kb1"] < x["kb0"]]
    grew = sorted(x["kb1"] - x["kb0"] for x in rs if x["kb1"] >= x["kb0"])
    def q(p): return ms[min(len(ms) - 1, int(p * len(ms)))]
    print(f"{mode} {a}: n={len(ms)} median {q(0.5):.1f} p90 {q(0.9):.1f} max {ms[-1]:.1f} over10 {sum(m > 10 for m in ms)}; "
          f"heap fell inside {len(fell)} (their ms {sorted(round(x['ms'],1) for x in fell)}, fell MB {[round((x['kb0']-x['kb1'])/1024,1) for x in fell]}); "
          f"alloc KB median {grew[len(grew)//2] if grew else None}")
    slow = sorted(rs, key=lambda x: -x["ms"])[:5]
    print("   slowest:", [(round(x["ms"], 1), round((x["kb1"] - x["kb0"]) / 1024, 1), round(x["kb0"] / 1024)) for x in slow])
