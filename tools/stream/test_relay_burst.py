#!/usr/bin/env python3
"""d27 batch263 VR (Nick 06:30: few viewers, long-time and in good faith): a viewer's message in parts reaches the agent
whole, in order, a few seconds apart. Caleb's 4 parts to Sol (06:09:38-06:10:13, site:5173-5176): part 4 came 8 s after
part 3 and the lane dropped it as "rate" (10 s a viewer); the parts that passed reached the game 45 s apart (the relay's
author gap). Through Feed + Relay with the default limits into a harness that keeps audience.lua's viewer_say limits
(relay_replay.Harness)."""
import os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import viewers as V  # noqa: E402
import relay_replay as R  # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        FAILS.append(name)


ROOT = os.path.dirname(os.path.dirname(HERE))
LUA = open(os.path.join(ROOT, R.AUDIENCE)).read()
AGENTS = ["astra", "sol", "luna", "opus"]


def run(lines, until=None):
    """lines: [(dt, author, text)]; the relay steps every 2 s (Feed.run_relay). -> (harness says, lane, relay)."""
    sw = os.path.join(tempfile.mkdtemp(), "relay.on")
    open(sw, "w").close()
    gap, per_min, part_s = R.viewer_limits(LUA)
    h = R.Harness(gap, per_min, part_s)
    relay = V.Relay(h, sw, roster=[(a, None) for a in AGENTS])
    feed = V.Feed({}, V.Filter(AGENTS), relay=relay)
    t0, k, i = 1_800_000_000.0, 0.0, 0
    end = until or (max(dt for dt, _, _ in lines) + 120)
    lines = sorted(lines)
    while k <= end:
        while i < len(lines) and lines[i][0] <= k:
            dt, author, text = lines[i]
            feed.ingest([{"id": f"site:{i}", "source": "site", "author": author, "name": author, "text": text, "t": t0 + dt}],
                        [], now=t0 + dt)
            i += 1
        h.now = t0 + k
        relay.step(t0 + k)
        k += 1.0 if k < 1 else 2.0
    for s in h.says:
        s["dt"] = s["at"] - t0
    return h.says, {m["id"]: m for m in feed.lane()[0]}, relay


check("viewer_say: 3 s a viewer, 20 a minute, 10 s for a part (audience.lua)", R.viewer_limits(LUA) == (3.0, 20, 10.0),
      R.viewer_limits(LUA))

# Caleb's four parts at their own times (s after part 1), each a few dozen words
CALEB = [(0.0, "sol: Speed-Hacking Inserters in Factorio Objective: Bypass stack inserter capacity delays (1/4)"),
         (13.6, "sol: Problem: Stack inserters pause until grabbing a full stack of identical items (2/4)"),
         (26.5, "sol: Implementation: Wire inserter to transport belt segment in front of it (3/4)"),
         (35.1, "sol:Dynamic filter updates force inserter to grab whatever is available immediately (4/4)")]
says, lane, relay = run([(dt, "caleb", t) for dt, t in CALEB])
mine = [s for s in says if s["name"] == "caleb"]
check("caleb: all four parts reach the game, in order", [s["text"][-5:] for s in mine] == ["(1/4)", "(2/4)", "(3/4)", "(4/4)"],
      [s["text"] for s in mine])
check("caleb: each part within 2 s of being written (main: 32 s and 65 s, part 4 dropped)",
      all(0 <= s["dt"] - dt <= 2 for s, (dt, _) in zip(mine, CALEB)), [(round(s["dt"], 1), dt) for s, (dt, _) in zip(mine, CALEB)])
check("caleb: each goes to Sol, @-mentioned", all(s["text"].startswith("sol") or s["text"].startswith("@sol") for s in mine), mine)

# A burst: one viewer's 8 lines 1 s apart all wait (none dropped) and go in order, about 3-4 s apart
BURST = [(float(k), "rapid", f"step {k + 1} of my plan: build the copper smelters on the east side") for k in range(8)]
says, lane, relay = run(BURST)
mine = [s for s in says if s["name"] == "rapid"]
gaps = [round(b["dt"] - a["dt"], 1) for a, b in zip(mine, mine[1:])]
check("burst: all 8 reach the game, in order", [int(s["text"].split("step ")[1].split(" ")[0]) for s in mine] == list(range(1, 9)),
      [s["text"] for s in mine])
check("burst: 3-4 s apart (the relay's 3 s per viewer, a step every 2 s)", all(3 <= g <= 4 for g in gaps), gaps)
check("burst: the last within 30 s of the first", mine[-1]["dt"] - mine[0]["dt"] <= 30, mine[-1]["dt"])
check("burst: nothing refused", not relay.dropped, dict(relay.dropped))

# A viewer's 13th line in a minute is dropped as rate; 12 pass the lane
says, lane, relay = run([(float(k * 4), "many", f"thought number {k} about the rail network layout") for k in range(13)])
check("lane: 12 a minute a viewer, the 13th dropped as rate",
      len([s for s in says if s["name"] == "many"]) == 12 and "site:12" not in lane, (len(says), sorted(lane)))

# Flood guard: 25 viewers in 25 s: 20 pass the lane, 5 are busy; at most 20 reach the game in a minute
says, lane, relay = run([(float(k), f"v{k}", f"viewer {k} says the north outpost needs walls") for k in range(25)], until=150)
check("flood: the lane passes 20 of them (the rest busy) and those 20 reach the game", len(says) == 20 and len(lane) == 20,
      (len(says), len(lane)))
check("flood: at most 20 reach the game in any minute", all(sum(1 for t in says if 0 <= t["dt"] - s["dt"] < 60) <= 20 for s in says))
check("flood: one line every 3 s at most", all(b["dt"] - a["dt"] >= 3 for a, b in zip(says, says[1:])),
      [round(s["dt"], 1) for s in says])

# A 500-character site line goes as one game line (main: two parts at 300)
long = ("the copper smelters need another row of furnaces and a second belt " * 10)[:500].strip()
says, lane, relay = run([(0.0, "longwriter", long)])
check("long: 500 characters in one game line, the address in front",
      len(says) == 1 and "part" not in says[0] and says[0]["text"].endswith(long[-40:]) and len(says[0]["text"]) <= V.RELAY_MAX,
      says)
check("long: the lane shows it whole", lane["site:0"]["text"] == long, lane["site:0"]["text"][-20:])

sys.exit(1 if FAILS else 0)
