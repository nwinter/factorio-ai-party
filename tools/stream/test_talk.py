#!/usr/bin/env python3
"""Offline checks for the agents' own words on air (task-talk-hosts): which chat lines are voiced (caster.talk_pick,
caster.TalkPicker) and how the hosts yield to them (Caster.yield_to, yield_beat, chat_tick).
python3 tools/stream/test_talk.py"""
import os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

import caster  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    fails += not ok
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))


def pick(text, aloud=False, label=None, agent="opus"):
    return caster.talk_pick({"agent": agent, "text": text, "aloud": aloud}, label)


# good lines from shift01's chat that Clef called logistics and nobody heard
for text in ["@everyone Fuel is the bottleneck: boiler empty, half the furnaces unfueled. Once electric drills land I "
             "am building a coal belt from the coal patch west to the boilers.",
             "@everyone CRUDE OIL found far to the northwest, six wells! Radars next.",
             "@sonnet @luna could someone drop 10 copper plates for me? I need them for the offshore pump.",
             "Southern scouting found biters near (16,304), and they killed me at (25,299). Avoid that route until armed.",
             "Coal main line is complete: coal patch to boiler, 160 belts. Thanks @astra @muse @grok."]:
    ok, label, said = pick(text)
    check(f"voiced ({label}): {text[:50]}", ok and label in caster.TALK_KINDS and "(" not in said and "@" not in said,
          f"{ok} {label} {said}")
check("the opening handles and 'opus here:' are not read out",
      pick("@everyone opus here: I'll take copper mining and steam power.")[2] == "I'll take copper mining and steam power.")
check("an agent's own name as a prefix is not read out",
      pick("haiku: coal is claimed twice, so I'll leave it and take the labs.", agent="haiku")[2].startswith("coal is"))
check("shouted words are said in lower case", "coal chest" in pick("Built a public COAL chest, take what you need.")[2]
      and pick("CRUDE OIL found, six wells! Radars next.")[2].startswith("crude oil found")
      and "MW" in pick("Power is up to 4.5 MW now, thanks everyone!")[2])

# never coordinate soup, run-together words, lists of positions
for text, why in [("@astra coal delivered: 5 each into the furnaces at (22,-24), (18,-24), (26,-24) and (22,-18).",
                   "positions"),
                  ("Moving the frominserterasm tobelt line next, please wait.", "run-together"),
                  ("Iron courier is waiting for160plates, then runs mall70/gears50/circuits40. Please leave them.",
                   "run-together"),
                  ("Power check: 860/860 kW, 2 engines, 3 boilers, 1.8 MW and 4 pumps.", "numbers"),
                  ("@opus ok, on it.", "short"),
                  ("@sonnet I'm at (-5,-23), please hand me the 4 furnaces.", "fragment"),
                  ("Copper crew: fed your burners at (-6,-21) area with my coal. Next the boiler.", "fragment"),
                  ("Confirmed: opus takes coal and steam power.", "ack")]:
    ok, label, said = pick(text)
    check(f"not voiced ({why}): {text[:50]}", not ok and label == why, f"{ok} {label} {said}")
check("a plain status with nothing to hear stays text", not pick("@opus hauled 35 coal to your boiler. Feeding it now.")[0])
check("Clef's banter still lifts a line with no plan, ask or reaction",
      pick("The quarry looks lovely at sunset tonight.", label="banter")[:2] == (True, "banter"))
check("an aloud line is always voiced, coordinates gone",
      pick("Iron is growing at (18,-20): four drill pairs.", aloud=True)[:2] == (True, "aloud")
      and "(" not in pick("Iron is growing at (18,-20): four drill pairs.", aloud=True)[2])

# pacing: team-wide gap, per-agent cooldown, staleness, best first, no near-repeats
t0 = 1000.0
p = caster.TalkPicker(gap=12, cooldown=50, stale=30)
m1 = {"agent": "opus", "text": "Power is at its limit, please hold off big consumers until I add engines.", "t": t0}
m2 = {"agent": "sol", "text": "Steel is running. I am scouting south for oil next.", "t": t0}
m3 = {"agent": "astra", "text": "Biters attacking the stone area: chests destroyed! Who can defend?", "t": t0}
d = p.add(t0, [m1, m2, m3])
check("pacing: three good lines wait", [x["voiced"] for x in d] == [True, True, True] and len(p.waiting) == 3, d)
first = p.next(t0)
check("pacing: a reaction goes before a plan or a request", first and first[0] is m3, first)
p.aired_now(t0, first[0], first[2])
check("pacing: nothing inside the team-wide gap", p.next(t0 + 5) is None)
nxt = p.next(t0 + 12)
check("pacing: after the gap the next waiting line", nxt and nxt[0]["agent"] in ("opus", "sol"), nxt)
p.aired_now(t0 + 12, nxt[0], nxt[2])
check("pacing: a line older than --chat-stale is dropped", p.next(t0 + 40) is None and not p.waiting, p.waiting)
m4 = {"agent": "astra", "text": "The furnaces are starving again, can someone bring coal?", "t": t0 + 40}
p.add(t0 + 40, [m4])
check("pacing: one agent waits out its cooldown", p.next(t0 + 41) is None and p.waiting)
check("pacing: then speaks", (p.next(t0 + 51) or [None])[0] is m4)
p2 = caster.TalkPicker()
p2.add(t0, [m1])
p2.aired_now(t0, m1, caster.talk_text(m1["text"]))
d = p2.add(t0 + 60, [dict(m1, agent="luna", text="Power is at its limit, please hold off big consumers until I add "
                                                   "more engines.", t=t0 + 60)])
check("no two near-identical lines", d[0]["voiced"] is False and d[0]["label"] == "repeat", d)
check("talkative counts the last 5 minutes", p.talkative(t0 + 60) == 2 and p.talkative(t0 + 400) == 0)

# the hosts yield: react once or stay quiet, never over an attack
a = caster.parser().parse_args(["--writer", "template", "--dry-run", "--classifier", "heuristic", "--tts", "say",
                                "--log-dir", tempfile.mkdtemp(), "--seed", "3"])
c = caster.Caster(a)
c.agent_free = 100.0
c.a.react = 1.0
c.yield_to({"agent": "sol"}, "Steel is running. I am scouting south for oil next.", "plan")
check("yield: quiet while the agent clip plays", c.yield_beat(99.0, 4) == "quiet")
e = c.yield_beat(101.0, 4)
check("yield: then the reaction beat, once", e and e["react"] and e["agent"] == "sol" and e["kind"] == "chat", e)
check("yield: then quiet for the rest of the window", c.yield_beat(110.0, 4) == "quiet")
check("yield: an attack or a card on screen still speaks", c.yield_beat(110.0, 9) is None)
check("yield: over after --yield seconds", c.yield_beat(100.0 + a.yield_s + 1, 4) is None)
c.a.react = 0.0
c.yield_to({"agent": "sol"}, "Steel is running.", "plan")
check("yield: without a reaction the hosts stay quiet", c.yield_beat(c.agent_free + 1, 4) == "quiet")
facts = caster.facts_for(dict(e, prio=4), {"agents": [{"name": "sol"}]})
check("yield: the reaction beat tells the hosts they answer what viewers just heard",
      "own voice" in facts.get("how_to_call_it", "") and facts.get("text"), facts)

# chat_tick end to end (dry run): a typed line is judged, voiced, and the hosts yield to it
c2 = caster.Caster(a)
rec = []
c2.record = lambda **kw: rec.append(kw)
now = time.time()
c2.snap = {"agents": [{"name": "opus", "display_name": "Opus"}], "chat": []}
c2.chat_q.extend([{"kind": "chat", "agent": "opus", "seq": 1, "aloud": False, "t": now,
                   "text": "@everyone Fuel is the bottleneck: boiler empty, half the furnaces unfueled!"},
                  {"kind": "chat", "agent": "opus", "seq": 2, "aloud": False, "t": now,
                   "text": "@haiku coal at (22,-24), (18,-24), (26,-24)."}])
c2.chat_tick(now, {})
dec = [r for r in rec if r.get("type") == "chat_decision"]
agent = [r for r in rec if r.get("type") == "agent"]
check("chat_tick: the good line is voiced, the soup is not", [r["voiced"] for r in dec] == [True, False] and
      len(agent) == 1 and agent[0]["line"].startswith("Fuel is the bottleneck"), rec)
check("chat_tick: the hosts yield to it", c2.yielding and c2.yielding["until"] > c2.agent_free)
check("chat_tick: typed chat no longer reaches the hosts' events before it airs",
      'self.events.append(dict(e, prio=2 if not e["aloud"] else 4))' not in open(caster.__file__).read())

# d19 batch42 A1: a long say's parts ("@Foobator (2/3) ...", host/saysplit.ts) are voiced without the part number
check("talk_text: a part number is not read out",
      caster.talk_text("@Foobator (2/3) After that, modules go in.") == "After that, modules go in.",
      caster.talk_text("@Foobator (2/3) After that, modules go in."))

print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
