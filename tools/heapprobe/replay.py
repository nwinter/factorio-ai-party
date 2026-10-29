#!/usr/bin/env python3
"""replay.py WORLD REQUESTS.json RATE LABEL: the requests (journal request objects) through dispatch, in order, at RATE a
second, each with a fresh id; timed in the game (profiler) with the heap before and after. Writes replay_LABEL.json in the
current directory and prints per action (scope) the median, p90 and longest ms and the median KB allocated."""
import sys, os, time, re, json, collections
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pog
world, path, rate, label = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
assert world != "n", "a private copy only"
pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
r = pog.Rcon(pog.HOSTS.get(world, "127.0.0.1"), pog.PORTS[world], pw, timeout=60)
reqs = json.load(open(path))
rows, start = [], time.time()
for i, q in enumerate(reqs):
    q = dict(q, id=f"replay-{label}-{i}-{int(start)}")
    body = json.dumps(q)
    lua = (f"local kb0=collectgarbage('count') local p=helpers.create_profiler() "
           f"local out=remote.call('agent_harness','dispatch',[==[{body}]==]) p.stop() local kb1=collectgarbage('count') "
           f"rcon.print({{'', 'T ', p, ' kb0=', math.floor(kb0), ' kb1=', math.floor(kb1), ' bytes=', #out}})")
    out = r.command("/silent-command __agent-harness__ " + lua)
    m = re.search(r"Duration: ([\d.]+)ms kb0=(\d+) kb1=(\d+) bytes=(\d+)", out)
    key = q["action"] + ("/" + q["args"]["scope"] if isinstance(q.get("args"), dict) and q["args"].get("scope") else "")
    if m:
        rows.append({"key": key, "ms": float(m[1]), "kb0": int(m[2]), "kb1": int(m[3]), "bytes": int(m[4])})
    else:
        rows.append({"key": key, "error": out[:200]})
    wait = start + (i + 1) / rate - time.time()
    if wait > 0:
        time.sleep(wait)
json.dump(rows, open(f"replay_{label}.json", "w"))
by = collections.defaultdict(list)
for x in rows:
    if "ms" in x:
        by[x["key"]].append(x)
print(f"{label}: {len(rows)} requests in {time.time() - start:.0f} s, {sum('error' in x for x in rows)} errors")
for key, xs in sorted(by.items(), key=lambda kv: -len(kv[1])):
    ms = sorted(x["ms"] for x in xs)
    kb = sorted(x["kb1"] - x["kb0"] for x in xs if x["kb1"] >= x["kb0"])
    q = lambda p: ms[min(len(ms) - 1, int(p * len(ms)))]
    print(f"  {key:28} n={len(ms):4} median {q(0.5):6.2f} p90 {q(0.9):6.2f} max {ms[-1]:6.1f} ms; "
          f"alloc median {kb[len(kb) // 2] if kb else '-'} KB, sum {sum(kb) / 1024:.1f} MB; over 10 ms {sum(m > 10 for m in ms)}")
