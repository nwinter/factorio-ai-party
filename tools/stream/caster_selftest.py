#!/usr/bin/env python3
"""Offline checks for caster.py / voices.py (no network, no TTS service): python3 tools/stream/caster_selftest.py"""
import json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

import caster, voices  # noqa: E402
from mock import BANTER, LINES  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    fails += not ok
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))


# fact check: names and numbers must come from the facts
facts = {"event": "attack", "text": "Luna is under attack", "agent": {"name": "Luna", "role": "Defense"},
         "technologies_done": 14, "researching": {"tech": "Oil gathering", "percent": 67}}
names = ["Luna", "Opus", "Astra"]
check("accepts a grounded line", caster.check_line("Luna is under fire at 67 percent research!", facts, names, []) is None)
check("rejects an invented agent", caster.check_line("Opus rushes to help Luna!", facts, names, []) is not None)
check("rejects an invented number", caster.check_line("Luna faces 40 biters!", facts, names, []) is not None)
check("accepts a spelled-out fact", caster.check_line("Sixty-seven percent and one big push!", facts, names, []) is None)
check("rejects a spelled-out invented number",
      caster.check_line("Eighty-three percent done!", facts, names, []) is not None)
check("accepts a rounded figure", caster.check_line("Over a hundred machines starve!",
                                                    dict(facts, starved=118), names, []) is None)
check("spelled numbers stop at punctuation", [n for _, n in caster.spelled_numbers("minute thirty, two specimens")]
      == [30, 2])
check("parses spelled numbers", [n for _, n in caster.spelled_numbers("one hundred and twenty belts, forty-two")]
      == [120, 42])
check("rejects the hosts joining the team", caster.check_line("We're one tech behind!", facts, names, []) is not None
      and caster.check_line("Luna needs our help", facts, names, []) is not None)
check("allows host phrasing", caster.check_line("And here we see Luna, stay with us!", facts, names, []) is None)
check("reads 3,600 as one number", caster.check_line("Luna made 3,600 plates", dict(facts, made=3607), names, []) is None)
check("rejects a previous-run comparison without pace facts",
      caster.check_line("Last run they were still punching trees!", facts, names, []) is not None
      and caster.check_line("Last run they were slower.", dict(facts, pace={"verdict": "x"}), names, []) is None)
check("rejects invented absences", all(caster.check_line(x, facts, names, []) for x in (
    "Still no walls, still no turrets!", "No steam power yet.", "Belts down, no turrets in sight.")))
check("rejects an invented zero", caster.check_line("Zero belts laid so far.", facts, names, []) is not None)
check("rejects a repeat", caster.check_line("Luna is under attack!", facts, names, ["Luna is under attack, wow"]) is not None)
check("strips speaker prefix and stage directions", caster.clean('Rook: "*leans in* Huge play!"') == "Huge play!")

# heuristic classifier on the mock's own labels (BANTER = worth voicing, LINES = mostly logistics)
voice_hits = [caster.heuristic_kind(t)[0] == "voice" for v in BANTER.values() for t in v]
log_hits = [caster.heuristic_kind(t)[0] == "logistics" for v in LINES.values() for t in v]
check("heuristic voices most banter", sum(voice_hits) / len(voice_hits) >= 0.7, f"{sum(voice_hits)}/{len(voice_hits)}")
check("heuristic skips most logistics", sum(log_hits) / len(log_hits) >= 0.7, f"{sum(log_hits)}/{len(log_hits)}")
print(f"     heuristic: banter voiced {sum(voice_hits)}/{len(voice_hits)}, logistics skipped {sum(log_hits)}/{len(log_hits)}")
check("clef answer shapes", caster.pick_choice({"choice": "banter"}) == "banter"
      and caster.pick_choice({"probabilities": {"banter": 0.2, "logistics": 0.7}}) == "logistics")

# voices: own pick wins, defaults are distinct, deterministic, and never a caster's voice
agents = [{"name": n} for n in ["astra", "opus", "sonnet", "haiku", "sol", "luna", "grok", "gemini", "muse"]]
agents[1]["voice"] = "Orpheus"
v1, v2 = voices.assign_voices(agents), voices.assign_voices(list(reversed(agents)))
check("agent's own voice pick is used", v1["opus"] == "orpheus")
check("default voices distinct", len(set(v1.values())) == len(agents))
check("default voices deterministic", v1 == v2)
check("casters' voices reserved", not set(v1.values()) & set(voices.CASTERS.values()))
check("unknown pick falls back", voices.assign_voices([{"name": "x", "voice": "nope"}])["x"] in voices.VOICES)
said = voices.speakable("Power: 2 boilers + 4 steam engines online. Boiler 2 at 31.5,19, fuel chest 31.5,21.5. "
                        "Coal chest(-71.5,-12.5) ok, belt S along x-82.5 to 1,000 plates")
check("speakable strips map coordinates", not re.search(r"\d+\.\d|-\d|x-", said) and "1,000" in said
      and "2 boilers + 4 steam engines" in said, said)
said2 = voices.speakable("Astra taking copper mining at x -58..-29, y -23..1. Will supply plates.")
check("speakable strips coordinate ranges", said2 == "Astra taking copper mining. Will supply plates.", said2)
check("speakable strips emoji/markdown/urls", voices.speakable("@Grok **wow** 😅 see https://a.b now") == "Grok wow see now")

# differ: first snapshot only opens; later changes become events
now = time.time()
snap = {"agents": [{"name": "luna", "display_name": "Luna"}], "alerts": [], "chat": [],
        "research": {"current": "a", "label": "A"}, "cameras": {"main": {"agents": ["luna"]}}}
d = caster.Differ()
first = d.diff(snap)
snap2 = dict(snap, alerts=[{"id": "x", "kind": "attack", "text": "Luna is under attack", "agent": "luna"}],
             chat=[{"seq": 1, "agent": "luna", "text": "help!", "t": now, "aloud": True}],
             research={"current": "b", "label": "B"}, cameras={"main": {"agents": ["opus"]}},
             board={"available": True, "events": [{"seq": 3, "by": "luna", "agent": "luna", "verb": "done",
                                                   "title": "Wall west", "kind": "task", "t": now}]})
kinds = sorted(e["kind"] for e in d.diff(snap2))
check("differ: first snapshot is the opener", [e["kind"] for e in first] == ["open"])
check("differ: alerts, chat, research, camera, board", kinds == ["attack", "board", "camera", "chat", "research_start"],
      str(kinds))
check("differ: no repeats", d.diff(snap2) == [])

# templates never leave a placeholder and only use facts
tw = caster.TemplateWriter()
bad = []
for kind in caster.TemplateWriter.T:
    for who in ("pbp", "color"):
        e = {"kind": kind, "t": now, "prio": 5}
        f = {"event": kind, "game_time": "1 hour 3 minutes", "team_size": 9, "text": "Luna is under attack", "change": "done",
             "title": "Wall west", "tech": "Oil gathering", "agent": {"name": "Luna", "role": "Defense"},
             "on_camera": [{"name": "Opus", "doing": "building boiler", "where": "power plant", "role": "Power",
                            "model": "Claude Opus 5.5", "motto": "Power is a promise"}],
             "busy_agents": [{"name": "Luna", "doing": "building gun turret", "where": "50 m W", "role": "Defense"}],
             "researching": {"tech": "Oil gathering", "percent": 67}, "technologies_done": 14,
             "on_screen_now": {"segment": "production", "title": "Production: 9.1 science per minute"},
             "viewer_message": {"from": "factoryfan", "text": "How many labs?"},
             "analyst_answer": "They have 14 technologies and Oil gathering is at 67 percent."}
        for _ in range(4):
            line = tw.write(who, e, f, [], names + ["Opus"])
            if not line or "{" in line or caster.check_line(line, f, names + ["Opus"], []):
                bad.append((kind, who, line))
check("templates fill cleanly and pass the fact check", not bad, str(bad[:3]))

# exchanges: parse both hosts, tolerate markdown and quotes, ignore chatter
ex = caster.parse_exchange('Here you go:\n**Rook:** "Huge fight at the wall!"\n\nVale: They needed that.\nnote: x')
check("parse_exchange", ex == [("pbp", "Huge fight at the wall!"), ("color", "They needed that.")], str(ex))

# viewer lane: accepts the likely shapes, drops links, becomes a viewer event
vs = caster.viewer_messages({"viewers": [{"id": 1, "user": "ann", "text": "go opus!", "t": now}],
                             "events": [{"kind": "viewer", "seq": 2, "name": "bo", "message": "why so slow?", "t": now},
                                        {"kind": "viewer", "seq": 3, "name": "spam", "text": "see https://x.y"}]})
check("viewer_messages shapes", [(v["name"], v["text"]) for v in vs] == [("ann", "go opus!"), ("bo", "why so slow?")],
      str(vs))
d2 = caster.Differ()
d2.diff({"agents": []})
vk = [e for e in d2.diff({"agents": [], "viewers": [{"id": 9, "user": "cy", "text": "hi hosts", "t": now}]})]
check("differ: viewer event", [(e["kind"], e["viewer"]) for e in vk] == [("viewer", "cy")], str(vk))

# a siege: pending urgent events fold into one beat
class _A:
    stale, seed = 45, 1
cs = caster.Caster.__new__(caster.Caster)
cs.a, cs.events = _A(), caster.deque(maxlen=60)
for i, k in enumerate(["death", "attack", "loss", "board"]):
    cs.events.append({"kind": k, "text": f"{k} {i}", "t": now + i, "prio": caster.PRIORITY[k]})
pk = cs.pick_event(now + 5)
check("siege folds urgent events", pk["prio"] >= caster.URGENT and len(pk.get("also", [])) == 2
      and [e["kind"] for e in cs.events] == ["board"], str(pk))
at = caster.facts_for({"kind": "death", "text": "sonnet died; lost assembling-machine-1 x129", "t": now, "prio": 9},
                      {"agents": [{"name": "sonnet", "display_name": "Sonnet"}]})["text"]
check("alert text: counts and display names", at == "Sonnet died; lost assembling machine 1 (129 of them)", at)

# segments (eng/stream2): a new segment becomes one event; its on-screen facts are the facts
d3 = caster.Differ()
d3.diff({"agents": []})
seg = {"id": "seg-1", "type": "production", "state": "starting", "started": now, "ends": now + 30,
       "title": "Iron: 224 a minute", "facts": {"item": "iron plate", "rate_now": 224}}
se = d3.diff({"agents": [], "segment": seg})
check("differ: segment event once", [e["kind"] for e in se] == ["segment"]
      and d3.diff({"agents": [], "segment": dict(seg, state="live")}) == [], str(se))
sf = caster.facts_for(dict(se[0], prio=7), {"agents": []})
check("segment facts are the on-screen facts", sf["on_screen_now"]["rate_now"] == 224
      and caster.check_line("Iron at 224 a minute!", sf, [], []) is None, str(sf))
rf = caster.facts_for({"kind": "segment", "t": now, "prio": 7, "segment": {
    "id": "r1", "type": "attack_replay", "state": "live", "started": now, "ends": now + 15, "title": "Replay: Luna died",
    "facts": {"event": "Luna died", "kind": "death", "agent": "Luna", "seconds": 15, "ago_s": 21}}}, {"agents": []})
check("replay facts: event, agent and how to call it", rf["on_screen_now"]["agent"] == "Luna"
      and "how_to_call_it" in rf and caster.check_line("Run it back: Luna died at the wall.", rf, ["Luna"], []) is None,
      str(rf))
check("a rounded rate passes", caster.check_line("Plastic surges fifty-one a minute!", {"rate": 51.4}, [], []) is None
      and caster.check_line("Plastic surges fifty-three a minute!", {"rate": 51.4}, [], []) is not None)


class _Resp:
    def __init__(self, d):
        self.d = json.dumps(d).encode()

    def read(self, *a):
        return self.d

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


calls = []


def _fake(req, timeout=0):
    url = req if isinstance(req, str) else req.full_url
    calls.append((url, getattr(req, "data", None)))
    if url.endswith("/segments"):
        return _Resp({"types": [{"type": "production", "available": True}, {"type": "attack_replay",
                                                                            "available": False}], "busy": False})
    return _Resp({"id": "seg-2", "state": "queued"})


class _B:
    dry_run, segment_every = False, 180


cs2 = caster.Caster.__new__(caster.Caster)
cs2.a, cs2.base, cs2.rng = _B(), "http://x", caster.random.Random(1)
cs2.seg_cat, cs2.seg_cat_t, cs2.seg_req_t, cs2.seg_next_ok = {}, 0.0, 0.0, 0.0
cs2.record = lambda **kw: None
_orig, caster.urllib.request.urlopen = caster.urllib.request.urlopen, _fake
try:
    r1 = cs2.request_segment([("attack_replay", {}), ("production", {})], "lull")
    r2 = cs2.request_segment([("production", {})], "lull")  # inside --segment-every: no request
finally:
    caster.urllib.request.urlopen = _orig
posted = [json.loads(d) for u, d in calls if u.endswith("/segment")]
check("segment request skips unavailable types and rate-limits", r1 == {"id": "seg-2", "state": "queued"}
      and r2 is None and [p["type"] for p in posted] == ["production"], str(posted))

# viewer questions: the analyst answers them (analyst.py posts analyst.answers); the hosts voice the answer by name
d4 = caster.Differ()
an = {"viewer_questions": {"on": True}, "age_s": 30, "answers": []}
d4.diff({"agents": [], "viewers": [], "analyst": an})
lane = [{"id": "q1", "name": "factoryfan", "text": "how many labs do they have?", "t": time.time()},
        {"id": "c1", "name": "beltlover", "text": "this base is so tidy lol", "t": time.time()}]
ve = d4.diff({"agents": [], "viewers": lane, "analyst": an})
check("questions wait for the analyst, comments do not", [e.get("viewer") for e in ve] == ["beltlover"], str(ve))
ans = {"id": "va1", "viewer": "factoryfan", "question": "How many labs do they have?", "t": time.time(),
       "answer": "They have 6 labs, and 10 labs finish automation 2 in about a minute.",
       "facts": {"viewer_question": "How many labs do they have?", "analyst_answer": "They have 6 labs ..."}}
ae = d4.diff({"agents": [], "viewers": lane, "analyst": dict(an, answers=[ans])})
check("an analyst answer becomes a viewer beat above plain chat", len(ae) == 1 and ae[0].get("answer")
      and ae[0]["prio"] > caster.PRIORITY["viewer"], str(ae))
af = caster.facts_for(ae[0], {"agents": []})
check("answer facts carry the viewer, the question and the answer",
      af["viewer_message"]["from"] == "factoryfan" and af.get("analyst_answer") == ans["answer"], str(af))
check("a host line from the answer passes the fact check",
      caster.check_line("Factoryfan asks about labs: they have 6, and 10 labs would do it in about a minute.",
                        af, names, []) is None)
tl = caster.TemplateWriter().write("pbp", ae[0], af, [], names)
check("the template fallback voices an answer by name", tl and tl.startswith("factoryfan asks:") and "6 labs" in tl, str(tl))
check("no template line for a plain viewer comment",
      caster.TemplateWriter().write("pbp", ve[0], caster.facts_for(ve[0], {"agents": []}), [], names) is None)
off = caster.Differ()
off.diff({"agents": [], "viewers": []})
check("without the analyst the hosts still take questions",
      len(off.diff({"agents": [], "viewers": lane[:1]})) == 1)

# pace against the shake1 baseline
from baseline import Baseline  # noqa: E402
bl = Baseline(os.path.join(HERE, "baselines", "shake1.json"))
p = bl.pace(111171, 8, {"iron-plate": 3607}, ["logistics"])
check("baseline pace facts", p and p["technologies_now"] == 8 and "verdict" in p and "shake1_next_research" in p, str(p))
fp = caster.facts_for({"kind": "research", "text": "Research complete: Logistics", "t": now, "prio": 7},
                      {"tick": 111171, "research": {"done_count": 8}, "agents": []}, bl)
check("research facts carry the baseline time", "shake1_finished_this_at" in fp, str(fp))

print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
