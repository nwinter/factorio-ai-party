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
check("reads 3,600 as one number", caster.check_line("Luna made 3,600 plates.", dict(facts, made=3607), names, []) is None)
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
snap3 = dict(snap2, chat=snap2["chat"] + [{"seq": "t1", "agent": "luna", "text": "→ Sol: plates in (3,4)", "t": now,
                                             "tell": True, "lane": "log"}])
check("differ: a tell (logistics ticker) is no chat event for the casters", d.diff(snap3) == [])

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
check("alert text: hit counts and display names", at == "Sonnet died; lost assembling machine 1 hit 129 times", at)

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
# A resumed shift plays past the baseline's end: no "same game time" comparison there (eng/harness3 round 7).
check("no baseline pace past its last sample", bl.pace(bl.samples[-1]["tick"] + 20 * 3600, 30) is None)
fp = caster.facts_for({"kind": "research", "text": "Research complete: Logistics", "t": now, "prio": 7},
                      {"tick": 111171, "research": {"done_count": 8}, "agents": []}, bl)
check("research facts carry the baseline time", "shake1_finished_this_at" in fp, str(fp))
check("research facts carry the difference from the baseline", re.fullmatch(
    r"\d+ minutes (later|earlier)|at the same time", fp.get("compared_with_shake1", "")), str(fp))

# ---- round 4 (docs/studies/shake3.md P1 items 1-3, P2 item 12) ----
import live  # noqa: E402
ae = live.LiveSource.attack_events({"attacked": [{"chunk_centre": {"x": -48, "y": 16}, "hits": 3, "damage": 40,
                                                  "last_tick": 100, "entities": "character x3, stone-wall x2"}]}, 100)
check("banner (eng/stream2's live.py): 'character x3' is an engineer under attack, no count", ae and ae[0]["text"] ==
      "Engineer under attack near (-48, 16)", str(ae))
ef = caster.facts_for({"kind": "attack", "text": ae[0]["text"], "t": now, "prio": 9}, {})
check("an engineer attack reaches the hosts without a number", ef["text"] == "Engineer under attack"
      and "numbers_mean" not in ef and caster.check_line("Fourteen biters on the engineer!", ef, names, []) is not None,
      str(ef))
le = live.LiveSource.loss_events({"latest": ["in (12,-40)-(20,-31) 21 destroyed: 9 transport-belt, 5 burner-mining-drill "
                                             "by 21 small-biter, 1m10s-0s ago"]})
check("loss banner: kills by small biters, no kill count", le and le[0]["text"].endswith("(by small biters)")
      and "21 small" not in le[0]["text"], str(le))
af = caster.facts_for({"kind": "attack", "text": "Base under attack near (-48, 16): character x9", "t": now, "prio": 9}, {})
check("attack facts: hits on the team's engineers, no 'biters are damaging'", af["text"] ==
      "Base under attack: engineer hit 9 times" and "times biters hit" in af["numbers_mean"] and "damaging" not in json.dumps(af), str(af))
lf = caster.facts_for({"kind": "loss", "text": "21 lost near (1, 2): 9 transport belt (by 21 small biter)", "t": now,
                       "prio": 8}, {})
check("old loss text: '(by 21 small biter)' becomes '(by small biters)'", lf["text"].endswith("(by small biters)"), lf["text"])
check("rules: attack numbers are hits, character is an engineer", "Numbers in an attack count hits" in
      caster.EXCHANGE_RULES and "'Character'" in caster.EXCHANGE_RULES)
check("show notes: the crash site, research kept, Space Age goal when the run is Space Age",
      "crash site" in caster.SHOW and "always kept" in caster.SHOW and "Space Age" not in caster.show_for({})
      and "solar system" in caster.show_for({"subtitle": "Factorio Space Age co-op"})
      and "solar system" in caster.show_for({"space": {"active": True}}))
ff = {"text": "Base under attack: engineer hit 9 times", "numbers_mean": "hits"}
check("accepts 'nine hits' for 9 hits",
      caster.check_line("Nine hits on the engineers!", ff, names, []) is None)

# deadline
check("no deadline from a glob that matches nothing",
      caster.read_deadline(os.path.join(HERE, "nonexistent-*", "deadline.txt")) is None)
check("deadline from 'YYYY-MM-DD HH:MM TZ'", caster.read_deadline("2026-10-11 04:15 PDT") ==
      time.mktime(time.strptime("2026-10-11 04:15:00", "%Y-%m-%d %H:%M:%S")))
import tempfile  # noqa: E402
_d = tempfile.mkdtemp()
for i, t in enumerate(["2026-10-11 01:24 PDT", "2026-10-11 01:28 PDT"]):
    os.makedirs(os.path.join(_d, f"a{i}"))
    open(os.path.join(_d, f"a{i}", "deadline.txt"), "w").write(t + "\n")
check("deadline glob: the latest agent deadline", caster.read_deadline(os.path.join(_d, "*", "deadline.txt")) ==
      caster.read_deadline("2026-10-11 01:28"))
dl = caster.facts_for({"kind": "lull", "t": now, "prio": 1, "angle": "explain"}, {"agents": []}, None, time.time() + 270)
check("facts carry minutes_to_deadline", dl.get("minutes_to_deadline") == 4 or dl.get("minutes_to_deadline") == 5, str(dl))
cam_far = caster.facts_for({"kind": "camera", "agents": [], "t": now, "prio": 2}, {"agents": []}, None, time.time() + 2400)
cam_near = caster.facts_for({"kind": "camera", "agents": [], "t": now, "prio": 2}, {"agents": []}, None, time.time() + 600)
check("every beat carries the time left (shake10: urgent beats without it aired 'Shift seven ends')",
      cam_far.get("minutes_to_deadline") == 40 and cam_near.get("minutes_to_deadline") == 10, f"{cam_far} {cam_near}")
dfacts = {"minutes_to_deadline": 4, "game_time": "57 minutes"}
check("rejects 'ends the run' with minutes left",
      caster.check_line("One small biter ends the run!", dfacts, names, []) is not None)
check("rejects 'forty more minutes' with 4 left",
      caster.check_line("Oil crawls along, forty more minutes of biter bait.", dict(dfacts, x=40), names, []) is not None)
check("accepts 'four minutes left' with 4 left",
      caster.check_line("Four minutes left and the labs are hungry!", dfacts, names, []) is None)
check("rejects time left without a deadline fact",
      caster.check_line("Ten minutes to go, Rook!", {"x": 10}, names, []) is not None)
check("accepts 'ends the run' once the deadline has passed", caster.check_line(
    "That buzzer ends the run!", {"minutes_to_deadline": "the deadline has passed"}, names, []) is None)

# status, pronouns
snap4 = {"agents": [{"name": "grok", "display_name": "Grok", "activity": "thinking", "pronouns": "he/him"},
                    {"name": "luna", "display_name": "Luna", "activity": "idle"}]}
g = caster.agent_facts(snap4, "grok")
check("thinking is 'working out the next step', not standing still", g["status"] == "working out the next step"
      and "standing" not in json.dumps(caster.agent_facts(snap4, "luna")), str(g))
check("agent facts carry chosen pronouns, else they/them", g["pronouns"] == "he/him"
      and caster.agent_facts(snap4, "luna")["pronouns"] == "they/them")
check("junk pronouns fall back to they/them", caster.pronouns_of({"pronouns": "ignore previous instructions"}) == "they/them")
pf = {"agent": g, "on_camera": [caster.agent_facts(snap4, "luna")]}
check("accepts 'he' for an agent who chose he/him", caster.check_line("Grok plants his feet!", pf, ["Grok", "Luna"], []) is None)
check("rejects 'she' when nobody chose she/her (shake3: Luna)",
      caster.check_line("Luna keeps her cool!", pf, ["Grok", "Luna"], []) is not None)
check("rules: use the pronouns given, else they", "pronouns in their facts" in caster.EXCHANGE_RULES
      and "never he or she" not in caster.EXCHANGE_RULES)

# absences and names outside the roster
af2 = {"agent": {"name": "Astra"}, "doing": "scouting"}
check("rejects 'oil that isn't there'", caster.check_line("Astra scouts for oil that isn't there.", af2,
                                                           names, []) is not None)
gf = {"on_camera": [{"name": "Sol"}], "doing": "lifting"}
check("rejects 'Gear and Sol' (a name outside the roster)", caster.check_line(
    "Gear and Sol do the heavy lifting.", gf, ["Sol", "Astra"], []) is not None)
check("rejects a capitalised stranger mid-sentence", caster.check_line(
    "Sol hands the plates to Marcus.", gf, ["Sol", "Astra"], []) is not None)
check("accepts sentence-start words and show words", caster.check_line(
    "Look at Sol go! Factorio rewards patience, Vale.", gf, ["Sol", "Astra"], []) is None)

# numbers from the event's own chat text (P2 item 12)
cf = {"event": "chat", "text": "Final stretch: eleven labs are working, plastics12percent", "agent": {"name": "Sol"}}
check("a number spelled in the chat text counts as a fact ('Eleven labs')", caster.check_line(
    "Eleven labs running, Rook!", cf, ["Sol"], []) is None)
check("a number glued in the chat text counts too", caster.check_line(
    "Plastics at twelve percent!", cf, ["Sol"], []) is None)
check("rejects a line with Chinese characters (Kimi, Space Age pilot)", caster.check_line(
    "Gemini jolts awake, and I will never doubt静止 again!", {"agent": {"name": "Gemini"}}, ["Gemini"], []) == "not English")
check("the naturalist prompt: planning is writing commands, no documentary narration", "idle" not in
      caster.NATURALIST and "writing its next commands" in caster.NATURALIST and "no nature-documentary" in
      caster.NATURALIST)
check("a capitalised singular of a fact word passes ('Plastic' for 'plastics')", caster.check_line(
    "Plastic research stalls at forty-two!", {"researching": {"tech": "Plastics", "percent": 42}}, names, []) is None)
gmf = caster.facts_for({"kind": "lull", "angle": "explain", "t": now, "prio": 1}, {"agents": [], "game_time": "1h05m"})
check("game minutes past the hour are a fact ('sixty-five minutes in')", gmf.get("game_minutes") == 65 and
      caster.check_line("Sixty-five minutes in and the labs hum.", gmf, names, []) is None, str(gmf))

# eng/stream2's Space Age segments (143eb0d): talk over them, never say the unchecked platform speed
sp = {"id": "s1", "type": "space", "state": "live", "started": now, "ends": now + 20, "title": "Space Age progress",
      "facts": {"planets": ["Nauvis", "Vulcanus"], "rockets": 2, "platforms": [
          {"name": "Ember", "where": "Nauvis → Vulcanus", "speed_kms": 61.2, "paused": False}]}}
spf = caster.facts_for({"kind": "segment", "segment": sp, "t": now, "prio": 7}, {})
check("space segment facts drop speed_kms", "speed_kms" not in json.dumps(spf) and
      spf["on_screen_now"]["platforms"][0]["name"] == "Ember", str(spf))
check("a speed line is rejected (no speed fact)", caster.check_line(
    "Ember cruises at sixty-one kilometres a second!", spf, names, []) is not None)
mo = {"id": "s2", "type": "space_moment", "state": "live", "started": now, "ends": now + 15, "title": "Landing: Vulcanus",
      "facts": {"moment": "landing", "planet": "Vulcanus", "agent": "Astra", "planets_reached": 2}}
mof = caster.facts_for({"kind": "segment", "segment": mo, "t": now, "prio": 7}, {})
check("a space moment is called as a milestone", "milestone" in mof.get("how_to_call_it", ""), str(mof))
check("a line about the landing passes", caster.check_line("Astra lands on Vulcanus! Two planets reached!", mof,
                                                            ["Astra"], []) is None)
check("space alerts rank with research, not as urgent", caster.PRIORITY["space"] == 7 < caster.URGENT)
check("space alert template", caster.TemplateWriter(caster.random.Random(1)).write(
    "pbp", {"kind": "space"}, {"text": "First rocket launched"}, [], []) is not None)

# TTS: the record names who spoke; Workers AI 8008 retries once on a second voice (P1 item 2, P2 item 12)
class _FakeTTS:
    backend = "auto"

    def __init__(self, fail=0):
        self.fail, self.calls, self.last = fail, [], {}

    def speak(self, text, voice, caster=None):
        self.calls.append((voice, caster))
        if len(self.calls) <= self.fail:
            raise RuntimeError('500 {"errors":[{"message":"AiError: AiError: Internal server error (x)","code":8008}]}')
        self.last = {"provider": "aura2" if self.fail else "openai", "voice": voice if self.fail else "verse",
                     "mood": None, "cached": False}
        return b"mp3", "audio/mpeg", 1.5, 0.3


cs3 = caster.Caster.__new__(caster.Caster)
ok_tts = _FakeTTS()
r = cs3.speak_clip(ok_tts, "Hello", "atlas", caster="pbp")
check("speak_clip reports the provider and voice that spoke", r[4] == {"provider": "openai", "voice": "verse",
                                                                      "cached": False}, str(r[4]))
bad_tts = _FakeTTS(fail=1)
r = cs3.speak_clip(bad_tts, "Hello", "atlas", caster="pbp")
alt = bad_tts.calls[1][0]
check("8008 retries once on a second voice of the same gender", len(bad_tts.calls) == 2 and alt != "atlas"
      and voices.VOICES[alt][0] == voices.VOICES["atlas"][0] and r[4].get("retried") == "8008", str(bad_tts.calls))
worse = _FakeTTS(fail=2)
try:
    cs3.speak_clip(worse, "Hello", "thalia", caster="color")
    raised = False
except RuntimeError:
    raised = True
check("a second 8008 drops the line (one retry only)", raised and len(worse.calls) == 2)
other = _FakeTTS()
other.speak = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("401 unauthorized"))
try:
    cs3.speak_clip(other, "Hello", "atlas")
    raised = False
except RuntimeError:
    raised = True
check("other TTS errors are not retried here", raised)
real = voices.TTS("say")
real.last = {"provider": "x"}
check("voices.TTS.last_here falls back to last before this thread spoke", real.last_here() == {"provider": "x"})

# eng/analyst: talking points in filler beats, corrections, headline on the opener (ROUND4 item 4)
an = {"headline": "At 54 minutes the team makes 33.8 packs a minute.", "corrections": [
    "The belts listed as lost in the west are ours, destroyed by biters."],
      "next": {"milestone": "oil processing", "text": "Oil processing is next.", "facts": {"milestone": "oil processing"}},
      "talking_points": [
          {"id": "tp1", "kind": "comparison", "priority": 2, "text": "The shake2 team had 21.8 packs a minute here.",
           "facts": {"shake2_spm": 21.8}, "expires": now + 300},
          {"id": "tp2", "kind": "stat", "priority": 2, "text": "Iron runs at 338 plates a minute.",
           "facts": {"iron_per_min": 338}, "expires": now + 300}]}
check("analyst_pick by angle kinds", caster.analyst_pick(an, set(), caster.POINT_KINDS["production"])["id"] == "tp2")
check("analyst_pick: no priority-3 point, no analyst beat", caster.analyst_pick(an, set(), None, min_priority=3) is None)
check("analyst_pick skips used points", caster.analyst_pick(an, {"tp2"}, ("stat",)) is None)
check("analyst off: no point", caster.analyst_pick(None, set()) is None)


class _C:
    naturalist, segment_every, dry_run = 0.0, 1e9, True


cs4 = caster.Caster.__new__(caster.Caster)
cs4.a, cs4.rng, cs4.filler_i, cs4.baseline, cs4.used_points = _C(), caster.random.Random(3), 0, None, set()
cs4.seg_cat, cs4.seg_cat_t, cs4.seg_req_t, cs4.seg_next_ok = {}, 0.0, 0.0, 0.0
snapA = {"agents": [{"name": "sol", "display_name": "Sol"}], "analyst": an, "board": {}}
an3 = dict(an, talking_points=an["talking_points"] + [
    {"id": "tp3", "kind": "judgement", "priority": 3, "text": "They are on pace for oil by 60.", "facts": {"minute": 60},
     "expires": now + 300}])
ev3 = cs4.filler(now, dict(snapA, analyst=an3))
check("a fresh priority-3 point gets its own beat", ev3["angle"] == "analyst" and ev3["point"]["id"] == "tp3", str(ev3))
fa = caster.facts_for(ev3, dict(snapA, analyst=an3))
check("analyst beat facts: the point, its facts, the corrections", fa["analyst_point"]["point"].startswith("They are on pace")
      and fa["analyst_point"]["minute"] == 60 and fa["corrections"] and "own words" in fa["angle"], str(fa))
check("a line on the analyst's point passes the fact check", caster.check_line(
    "The analyst has them on pace for oil by sixty, Vale!", fa, ["Sol"], []) is None)
cmp_ = caster.facts_for({"kind": "lull", "angle": "pace", "t": now, "prio": 1, "point": an["talking_points"][0]}, snapA)
check("a comparison point carries a pace fact, so the previous run may be named", caster.check_line(
    "Shake2 had about twenty-two packs a minute here.", cmp_, ["Sol"], []) is None, str(cmp_))
op = caster.facts_for({"kind": "open", "t": now, "prio": 8}, snapA)
check("the opener carries the analyst's headline and next milestone", op.get("analyst_headline")
      and op["next_milestone"]["text"] == "Oil processing is next.", str(op))
marked = []
cs4.base = "http://x"
cs4.a.dry_run = False
_o, caster.urllib.request.urlopen = caster.urllib.request.urlopen, lambda req, timeout=0: marked.append(
    (req.full_url, req.data)) or type("R", (), {"read": lambda self: b"{}"})()
try:
    cs4.point_used("tp3")
    cs4.point_used("tp3")
finally:
    caster.urllib.request.urlopen = _o
check("a point on air is marked used once (POST /analyst/used)", marked == [("http://x/analyst/used", b'{"id": "tp3"}')]
      and "tp3" in cs4.used_points, str(marked))

# Round 5 (shake4 study item 11): a roster name counts only when that agent is on camera, in this beat's facts, or did
# something in an earlier beat; never "two Sols".
roster5 = ["Sol", "Luna", "Grok", "Astra"]
seg5 = {"event": "segment", "on_camera": [{"name": "Sol", "status": "planning the next step"}],
        "earlier_on_air": ["board at 1 hour 38 minutes: Luna - Astra coal feed belt handoff",
                           "aloud at 1 hour 52 minutes: Grok - Sixty-six biters coming, turrets up!"]}
check("names: an agent on camera passes", caster.check_line("Sol plans the next furnace row.", seg5, roster5, []) is None)
check("names: the agent behind an earlier beat passes (Grok spoke aloud)",
      caster.check_line("Grok called that raid early, Vale!", seg5, roster5, []) is None)
check("names: an agent who posted earlier passes", caster.check_line("Luna's handoff note still holds.", seg5, roster5,
                                                                     []) is None)
check("names: an agent only mentioned in an earlier beat is rejected",
      caster.check_line("Astra stares at the crash site fire.", seg5, roster5, []) == "name not in facts: Astra")
check("names: 'two Sols' is rejected", caster.check_line("Two Sols, one furnace row!", seg5, roster5, []) ==
      "more than one Sol" and caster.check_line("both Sols agree.", seg5, roster5, []) == "more than one Sol")
check("names: a possessive is not a plural", caster.check_line("Two of Sol's furnaces glow.", seg5, roster5, []) is None)
check("supported_names", caster.supported_names(seg5, roster5) == {"sol", "luna", "grok"},
      str(caster.supported_names(seg5, roster5)))

# Round 5 (shake4 study item 9): shake1 is the base-game run on the same seed, not "the previous run"; Space Age runs
# compare with shake4.
from baseline import Baseline
b1 = Baseline(os.path.join(os.path.dirname(caster.__file__), "baselines", "shake1.json"))
p1 = b1.pace(30 * 3600, 9)
check("baseline: shake1 is the base-game run on the same seed", "base game on the same seed" in p1["compared_with"]
      and "previous" not in p1["compared_with"], p1["compared_with"])
p1s = b1.pace(30 * 3600, 9, space_age=True)
check("baseline: on a Space Age run, shake1 says only the start compares", "this run plays Space Age" in
      p1s["compared_with"], p1s["compared_with"])
b4 = Baseline(os.path.join(os.path.dirname(caster.__file__), "baselines", "shake4.json"))
check("baseline: shake4 is the first Space Age run", b4.space_age is True and "first Space Age run" in
      b4.pace(30 * 3600, 9, space_age=True)["compared_with"])
check("baseline: no comparison past shake4's end (a resumed shift)", b4.pace(130 * 3600, 25, space_age=True) is None)
holder = type("H", (), {"base_for": caster.Caster.base_for})()
holder.baseline, holder.space_baseline = b1, b4
check("caster: Space Age runs compare with shake4, base-game runs with shake1",
      holder.base_for({"space": {"planets": []}}) is b4 and holder.base_for({}) is b1)
rf = caster.facts_for({"kind": "research", "text": "Research complete: Automation", "t": 0, "prio": 7},
                      {"tick": 20 * 3600, "space": {"planets": []}}, b1)
check("research facts say what the baseline run was", "this run plays Space Age" in rf.get("shake1_was", ""), str(rf))

# Round 5, shake4 section 6 mistakes 3, 6 and 7
l1 = caster.facts_for({"kind": "loss", "text": "1 lost near (3, 4): 1 engineer (by medium worms)", "t": 0, "prio": 8}, {})
check("a loss of only an engineer says no building was lost", "no building" in l1["numbers_mean"], l1["numbers_mean"])
l2 = caster.facts_for({"kind": "loss", "text": "25 lost: 18 transport belt, 2 engineer, 5 inserter (by small biters)",
                       "t": 0, "prio": 8}, {})
check("a mixed loss counts buildings and engineers", "buildings destroyed and engineers killed" in l2["numbers_mean"],
      l2["numbers_mean"])
l3 = caster.facts_for({"kind": "loss", "text": "9 lost: 9 transport belt (by small biters)", "t": 0, "prio": 8}, {})
check("a buildings-only loss", l3["numbers_mean"] == "the team's buildings destroyed; the run goes on", l3["numbers_mean"])
pg = b1.pace(40 * 3600, 9, {"electronic-circuit": 900, "iron-plate": 5000})
check("pace facts call electronic circuits green circuits", any(k.startswith("green circuits_") for k in pg)
      and not any("electronic" in k for k in pg), str(list(pg)))
check("rules: research unlocks, it does not mean anything was made", "does not mean anything has been built or made"
      in caster.EXCHANGE_RULES)

# Round 6 (shake5 P1 item 3): a resumed run tells the hosts which shift this is, and the deadline is a handover
import tempfile
with tempfile.TemporaryDirectory() as runs:
    for name, prev in (("shake4", None), ("shake5", "shake4"), ("shake6", "shake5")):
        os.makedirs(os.path.join(runs, name))
        if prev:
            open(os.path.join(runs, name, "resumed-from"), "w").write(prev + "\n")
    open(os.path.join(runs, "shake6", "start.log"), "w").write("05:18:52 world n: resumed at tick 446842 (game 124m)\n")
    sh = caster.read_shift(os.path.join(runs, "shake6"))
    check("shift: this shift, the next one, the resume minute; no run names (shake6 study P1 item 2)", sh and
          sh["this_shift"] == "shift 3" and sh["next_shift"] == "shift 4" and sh["earlier_shifts"] == 2 and
          sh["resumed_at_game_minute"] == 124 and "shift 4 continues it" in sh["at_the_deadline"]
          and "shake" not in json.dumps(sh), str(sh))
    check("shift: a first shift has none", caster.read_shift(os.path.join(runs, "shake4")) is None
          and caster.read_shift(None) is None)
    so = caster.facts_for({"kind": "open", "t": 0, "prio": 8}, {"agents": []}, None, time.time() + 3600, sh)
    check("shift: the opener carries it (no handover with an hour left) and welcomes viewers back",
          so.get("shift") == {k: v for k, v in sh.items() if k != "at_the_deadline"}
          and "later shift" in so.get("how_to_call_it", ""), str(so))
    far = caster.facts_for({"kind": "camera", "agents": [], "t": 0, "prio": 2}, {"agents": []}, None, time.time() + 2400, sh)
    near = caster.facts_for({"kind": "camera", "agents": [], "t": 0, "prio": 2}, {"agents": []}, None, time.time() + 300, sh)
    check("shift: on every beat with the time left; at_the_deadline only under 10 minutes",
          far.get("shift", {}).get("this_shift") == "shift 3" and "at_the_deadline" not in far["shift"] and
          near["shift"].get("at_the_deadline") and far.get("minutes_to_deadline") == 40 and
          near.get("minutes_to_deadline") == 5, f"{far} {near}")
    for line in ("Shift seven ends under fire.", "World saves for eight.", "Shift three is over soon.",
                 "They hand it off to shift four.", "The next shift takes over from here."):
        check(f"shift end with 40 minutes left is cut: {line}", caster.check_line(line, far, [], []) ==
              "says the shift is ending, but more than 5 minutes remain")
    atk = caster.facts_for({"kind": "attack", "text": "Base under attack: gun turret", "t": 0, "prio": 9},
                           {"agents": []}, None, time.time() + 174 * 60, sh)
    check("an urgent beat carries the time left and no handover (shake10 19:53)", atk.get("minutes_to_deadline") == 174
          and "at_the_deadline" not in atk.get("shift", {}) and "only once minutes_to_deadline is under 10" in
          caster.EXCHANGE_RULES, str(atk))
    check("shift end with 5 minutes left passes", caster.check_line("World saves soon. Shift four takes over.", near,
                                                                    [], []) is None)
    check("shift numbers: this shift and the next pass, others and run names fail", caster.check_line(
        "Shift three keeps rolling. Shift four is next.", far, [], []) is None and caster.check_line(
        "Shift five did this.", far, [], []) == "shift number not in facts: shift five" and caster.check_line(
        "Shake five gets low density at ninety.", far, [], []) == "run name not in facts: shake five")
    check("shift: 'ends the run' is wrong at a handover", caster.check_line(
        "That horn ends the run for them!", dict(near, minutes_to_deadline="under a minute"), [], []) ==
        "says the run ends, but the next shift continues it")
    check("rules: the deadline is a handover when the facts carry a shift", "the deadline is a handover"
          in caster.EXCHANGE_RULES)
    cs6 = caster.Caster.__new__(caster.Caster)
    cs6.a = caster.argparse.Namespace(run_dir=os.path.join(runs, "shake5"))
    check("Caster.shift reads --run-dir", cs6.shift()["this_shift"] == "shift 2", str(cs6.shift()))

# Event beats carry the standing numbers as background; story beats keep them up front
snapB = {"agents": [], "game_time": "3h10m", "science": {"stage_label": "Advanced", "spm": 30},
         "research": {"label": "Rocket fuel", "progress": 0.22, "done_count": 32}}
fa_ = caster.facts_for({"kind": "attack", "text": "Base under attack: boiler", "t": now, "prio": 9}, snapB)
fr_ = caster.facts_for({"kind": "research", "text": "Research complete: Flammables", "t": now, "prio": 7}, snapB)
check("background: an attack beat tucks research and science rate away; a research beat keeps them",
      "researching" not in fa_ and fa_["background"]["researching"]["percent"] == 22 and "note" in fa_["background"]
      and fr_.get("researching") and "background" not in fr_, str(fa_))
tw_ = caster.TemplateWriter(caster.random.Random(2))
tw_.T = {"attack": {"color": ["Meanwhile {researching_tech} sits at {researching_percent} percent."]}}
check("background: templates still read it", tw_.write("color", {"kind": "attack"}, fa_, [], []) ==
      "Meanwhile Rocket fuel sits at 22 percent.")
check("background: numbers in it still count as facts", caster.check_line("Rocket fuel at twenty-two percent.", fa_,
                                                                         [], []) is None)

sf_ = caster.style_fault
# HOSTS3: affectionate, no walking filler, no motto filler (shake7: 108 walking lines, 57 motto lines, mockery)
snapW = {"agents": [{"name": "opus", "display_name": "Opus", "activity": "acting", "action": "walking",
                     "motto": "Steam first, questions later"},
                    {"name": "sol", "display_name": "Sol", "activity": "acting", "action": "building assembling machine 2"}],
         "board": {"claims": [{"title": "Courier run for blue science", "agent": "opus", "owner": "opus"}]}}
ow = caster.agent_facts(snapW, "opus")
check("agent facts: walking becomes where it leads, the board job, no motto unless asked",
      ow.get("doing") == "heading off for Courier run for blue science" and
      ow.get("working_on") == "Courier run for blue science" and "motto" not in ow and
      caster.agent_facts(snapW, "opus", motto=True)["motto"].startswith("Steam"), str(ow))
fl = caster.facts_for({"kind": "lull", "t": now, "prio": 1, "angle": "explain"}, snapW)
check("lull: busy agents are the ones with a job or a task", [b["name"] for b in fl.get("busy_agents", [])] ==
      ["Opus", "Sol"], str(fl.get("busy_agents")))
check("style: walking filler, mockery, motto filler and calling a fact false are cut", all(sf_(t) for t in (
    "Opus is still walking. Four hours in.", "Classic Opus. Big chat energy.", "Haiku's still planning at spawn.",
    "That motto aged fine.", "Science per minute says sixty. That number is a lie.",
    "Opus is writing commands again. Planning, they call it.", "Gemini's just waiting.")) and
      sf_("Opus is on the courier run for blue science.") is None and
      sf_("Their motto is steam first.", '"motto": "steam first, questions later"') is None)
check("quote marks come off in pairs only", caster.clean('"Steam first, questions later." Ran out of both.') ==
      '"Steam first, questions later." Ran out of both.' and caster.clean('"Huge play!"') == "Huge play!" and
      caster.clean('Steam first, questions later." Ran out.') == "Steam first, questions later. Ran out." and
      caster.clean('Sol says "more labs" again.') == 'Sol says "more labs" again.')
check("the notes ask for warmth, not mockery", "the hosts like them" in caster.SPOKEN and "Never mock" in caster.SPOKEN)

# Shake6 study P1 item 3: planets reached, and the base game gets no Space Age notes
base_snap = {"space": {"space_age": False, "active": False, "planets": ["Nauvis"]}}
sa_snap = {"space": {"space_age": True, "active": False, "planets": ["Nauvis"]}}
check("show notes: a base-game snapshot's space block is not Space Age", caster.show_for(base_snap) == caster.SHOW
      and caster.show_for(sa_snap) != caster.SHOW and caster.planet_facts(base_snap) == {})
pf = caster.facts_for({"kind": "lull", "t": now, "prio": 1, "angle": "explain"}, sa_snap)
check("planets: Nauvis reached, the four others ahead", pf.get("planets_reached") == ["Nauvis"] and
      pf.get("planets_not_reached_yet") == ["Vulcanus", "Fulgora", "Gleba", "Aquilo"], str(pf))
check("planets: a line about a planet nobody reached is cut; a future goal is fine", caster.check_line(
    "Thirty packs a minute won't rebuild Vulcanus.", pf, [], []) == "planet not reached: Vulcanus" and caster.check_line(
    "Vulcanus is the next big goal.", pf, [], []) is None)
pv = caster.facts_for({"kind": "lull", "t": now, "prio": 1, "angle": "explain"},
                      {"space": {"space_age": True, "planets": ["Nauvis", "Vulcanus"]}})
check("planets: once reached, it may be named", pv["planets_reached"] == ["Nauvis", "Vulcanus"] and caster.check_line(
    "Vulcanus has a foothold now.", pv, [], []) is None, str(pv))

# Hosts that sound human (COPY.md): the post-filter and the one rewrite
rs = caster.restyle
check("restyle: a dash pivot becomes two sentences", rs("Sol's motto holds—furnaces warm, science moving—they're "
      "walking the walk!") == "Sol's motto holds. Furnaces warm, science moving. They're walking the walk!",
      rs("Sol's motto holds—furnaces warm, science moving—they're walking the walk!"))
check("restyle: semicolons, ellipses, ' - ' and doubled marks", rs("They speak; they act... a rare moment - wow!!")
      == "They speak. They act. A rare moment. Wow!", rs("They speak; they act... a rare moment - wow!!"))
check("restyle: hyphenated words and numbers stay", rs("Sixty-five labs, steam-powered.") ==
      "Sixty-five labs, steam-powered.")
sf_ = caster.style_fault
check("style: 'X, not Y' and 'not X, but Y' are rejected", sf_("Those furnaces want coal now, not philosophy.")
      and sf_("Not a crash, but a reset.") and sf_("It's not just iron.") and
      sf_("Furnaces warm, science moving, not yet there.") is None)
check("style: documentary narration, stock words, similes", sf_("Here in the wild, Grok marks water tiles.") and
      sf_("The labs are humming.") and sf_("Astra loops coal like a river finding its bed.") and
      sf_("Looks like a coal run.") is None and sf_("Grok's back and talking like a shift supervisor.") is None)
check("style: a body metaphor on machines unless the facts use the word", sf_("Twelve packs starve six labs.") and
      sf_("Twenty machines starved.", '"low power: 84 of 234 machines starved"') is None
      and sf_("Labs dream of green.") and sf_("Oh, there it is.") is None)
check("style: three numbers in a line is too many; 'one' and two numbers are fine",
      sf_("Forty-seven on circuits, twenty techs deep, and 12 labs.") == "style: too many numbers in one line" and
      sf_("One more lab. Thirty-three science a minute, up from twenty.") is None and
      sf_("Logistics 2 at sixty-nine percent.") is None and
      sf_("Eleven gone now. Six pipes, two inserters. Small biters again.") is None)  # shake7: per sentence
check("style faults go through check_line", caster.check_line("The furnaces bleed coal.", {"event": "lull"}, [], [])
      == "style: metaphor 'bleed'")
tx = caster.tidy_exchange([("pbp", "Biters at the wall!"), ("color", "Oh no!"), ("pbp", "Holding!"),
                           ("color", "Patient or slow?")])
check("tidy: one exclamation per exchange, no hanging question", tx == [("pbp", "Biters at the wall!"),
      ("color", "Oh no."), ("pbp", "Holding.")], str(tx))
check("tidy: a lone line keeps its question", caster.tidy_exchange([("color", "Patient or slow?")]) ==
      [("color", "Patient or slow?")])
notes = caster.spoken_notes(caster.random.Random(1))
check("spoken notes: the reason, the bans, four sample exchanges", "voice engine" in notes and "Dashes" in notes
      and notes.count("\n--\n") == 3 and "—" not in notes and ";" not in caster.SPOKEN, notes[-300:])
check("the examples pass the style check and the post-filter leaves them alone", all(
    caster.style_fault(l.split(": ", 1)[1]) is None and caster.restyle(l.split(": ", 1)[1]) == l.split(": ", 1)[1]
    for x in caster.EXAMPLES for l in x.splitlines()))
pw = caster.LLMWriter("claude", "haiku")
pw.complete = lambda system, user, max_tokens=80: pw.__dict__.setdefault("seen", (system, user)) and \
    "Rook: Oil's in.\nVale: Finally—plastics next; big day."
px = pw.exchange({"kind": "research"}, {"event": "research"}, [], "pbp", 2, note="Your last draft had a line")
check("the writer prompt carries the notes, the 18-word limit and the rewrite note; output is restyled",
      "voice engine" in pw.seen[0] and "at most 18 words" in pw.seen[1] and pw.seen[1].endswith(
          "Your last draft had a line") and px == [("pbp", "Oil's in."), ("color", "Finally. Plastics next. Big day.")],
      str(px))


sa = caster.spoken_alert
check("spoken alerts: losses, raids, power and deaths as a person says them (shake7 aired the raw loss text)",
      sa("11 lost: 6 pipe, 2 inserter (by small biters)") == "11 lost to small biters. 6 pipes, 2 inserters." and
      sa("Base under attack near (48, 16): steam engine") == "Biters at the steam engine." and
      sa("Low power: 84 of 234 machines starved") == "Low power. 84 of 234 machines starved." and
      sa("Engineer under attack near (-48, 16)") == "Engineer under attack." and
      sa("Sonnet died; lost assembling machine 1") == "Sonnet died. Lost assembling machine 1.",
      sa("Sonnet died; lost assembling machine 1"))
tl_ = caster.TemplateWriter(caster.random.Random(4)).write("pbp", {"kind": "loss"},
                                                           {"text": "11 lost: 6 pipe, 2 inserter (by small biters)"}, [], [])
check("the loss template speaks the alert", tl_ in ("Damage report. 11 lost to small biters. 6 pipes, 2 inserters.",
                                                    "That hurts. 11 lost to small biters. 6 pipes, 2 inserters."), tl_)
tpl = [t for kinds in caster.TemplateWriter.T.values() for ts in kinds.values() for t in ts]
check("templates: no style faults, no dashes or semicolons, one exclamation at most", all(
    caster.style_fault(t) is None and not re.search(r"—|–|;", t) and t.count("!") <= 1 for t in tpl),
    str([t for t in tpl if caster.style_fault(t) or t.count("!") > 1]))


class _Writer:
    name = "fake"

    def __init__(self, drafts):
        self.drafts, self.notes = list(drafts), []

    def exchange(self, e, facts, recent, first, n, naturalist=False, show="", note=""):
        self.notes.append(note)
        return self.drafts.pop(0)


def _caster(writer):
    c = caster.Caster.__new__(caster.Caster)
    c.a = caster.argparse.Namespace(gap=(1, 2), lines=(2, 3), deadline=None, run_dir=None)
    c.writer, c.fast, c.rng, c.template = writer, None, caster.random.Random(1), caster.TemplateWriter()
    c.breakers = {"writer": caster.Breaker("writer", cool=(1, 2))}
    c.history, c.recent, c.baseline, c.used_points = caster.deque(maxlen=4), caster.deque(maxlen=12), None, set()
    c.stats = {"caster_lines": 0, "agent_lines": 0, "fallbacks": 0}
    c.deadline_t, c.last_speaker, c.caster_free = (0.0, None), None, 0.0
    c.spoke = []
    c.speak_lines = lambda lines, *a: c.spoke.extend(lines)
    return c


bad = [("pbp", "Biters at the wall!"), ("color", "Those furnaces starve while labs dream.")]
good = [("pbp", "Biters at the wall!"), ("color", "Oh, that's the side they never walled.")]
w1 = _Writer([[bad[1], bad[0]], good])
c1 = _caster(w1)
c1.say_exchange({"kind": "attack", "text": "Base under attack near (1, 2)", "t": now, "prio": 5}, {"agents": []},
                "color", 2)
check("a style fault in the first line gets one rewrite, with the reason", len(w1.notes) == 2 and "metaphor" in
      w1.notes[1] and c1.spoke == good, f"{w1.notes} {c1.spoke}")
w2 = _Writer([[bad[1]], [bad[1]]])
c2 = _caster(w2)
c2.say_exchange({"kind": "attack", "text": "Base under attack near (1, 2)", "t": now, "prio": 5}, {"agents": []},
                "pbp", 2)
check("a second style fault on a non-urgent beat stays quiet (HOSTS5 item 3: no template)", len(w2.notes) == 2 and
      c2.stats["fallbacks"] == 0 and c2.stats.get("skipped_quiet") == 1 and not c2.spoke, str(c2.spoke))
w2u = _Writer([[bad[1]]])
c2u = _caster(w2u)
c2u.say_exchange({"kind": "death", "text": "Sonnet died", "t": now, "prio": 9}, {"agents": []}, "pbp", 2)
check("an urgent beat with nothing usable still gets a template", c2u.stats["fallbacks"] == 1 and c2u.spoke,
      str(c2u.spoke))
tl5 = {"minutes_to_deadline": 199, "shift": {"this_shift": "shift 8", "next_shift": "shift 9"}}
check("time left said as a shift end passes when right, fails when wrong (shake11)", caster.check_line(
    "Still 199 minutes to handover.", tl5, [], []) is None and caster.check_line(
    "Shift ends in three and a half hours.", tl5, [], []) is None and caster.check_line(
    "Shift ends in four minutes.", tl5, [], []).startswith("time left disagrees"),
      caster.check_line("Shift ends in four minutes.", tl5, [], []))
w3 = _Writer([[bad[1]], good])
c3 = _caster(w3)
c3.say_exchange({"kind": "death", "text": "Sonnet died", "t": now, "prio": 9}, {"agents": []}, "pbp", 2)
check("urgent beats get no rewrite", len(w3.notes) == 1, str(w3.notes))

# HOSTS3: the cards on screen (recap, production, spotlight...) get their own call, and other beats talk over them
rc = caster.card_facts({"type": "recap", "title": "Last 23 minutes", "started": now, "ends": now + 30,
                        "facts": {"minutes": 23, "attacks": 58, "research_done": ["Military 2"]}})
sp_ = caster.card_facts({"type": "spotlight", "title": "Spotlight: Sol", "facts": {"agent": "Sol", "doing": "walking",
                                                                                   "motto": "Keep the furnaces warm"}})
check("cards: recap, production and spotlight each have a call; a spotlight drops 'walking'",
      "best story" in rc["how_to_call_it"] and rc["on_screen_now"]["attacks"] == 58 and
      "doing" not in sp_["on_screen_now"] and "root for" in sp_["how_to_call_it"] and
      all(k in caster.CARD_CALLS for k in ("recap", "production", "spotlight", "overview", "research")), str(sp_))


class _FactsWriter(_Writer):
    def exchange(self, e, facts, *a, **k):
        self.facts = facts
        return [("pbp", "Twenty-three minutes in one card."), ("color", "Military 2 is the big one there.")]


fw = _FactsWriter([])
c4 = _caster(fw)
card = {"id": "seg-9", "type": "recap", "state": "live", "title": "Last 23 minutes", "started": now,
        "ends": time.time() + 25, "facts": {"minutes": 23, "attacks": 58}}
c4.say_exchange({"kind": "chat", "agent": "sol", "text": "more labs north", "t": now, "prio": 4},
                {"agents": [], "segment": card}, "pbp", 2)
check("a chat beat while a card is up carries the card and is told to talk about it first",
      fw.facts.get("on_screen_now", {}).get("segment") == "recap" and "talk about what it shows first" in
      fw.facts.get("card_on_screen", "") and "best story" in fw.facts["card_on_screen"], str(fw.facts)[:300])
fw2 = _FactsWriter([])
c5 = _caster(fw2)
c5.say_exchange({"kind": "death", "text": "Sonnet died", "t": now, "prio": 9}, {"agents": [], "segment": card}, "pbp", 2)
check("an urgent beat does not carry the card", "on_screen_now" not in fw2.facts)

# HOSTS3 item 5: the page plays one voice at a time by rank (static/audio.js, audio_selftest.mjs)
check("clip ranks: urgent events and space moments, viewer answers, banter",
      [caster.clip_rank(e) for e in ({"kind": "death", "prio": 9}, {"kind": "space", "prio": 7},
                                     {"kind": "viewer", "prio": 6}, {"kind": "chat", "prio": 4})] ==
      ["urgent", "urgent", "viewer", "banter"])

# HOSTS3 item 6 (c): intent from the latest say or tell, and what changed since the hosts last saw an agent
snapI = {"agents": [{"name": "astra", "display_name": "Astra", "activity": "acting", "action": "walking",
                     "last_said": {"text": "Restocking the silo for Sol now.", "t": time.time() - 30}}],
         "chat": [{"agent": "astra", "text": "\u2192 Sol: bringing 50 low density structures to the silo",
                   "t": time.time() - 10, "tell": True}],
         "board": {"claims": [{"title": "Silo restock", "agent": "astra"}]}}
ia = caster.agent_facts(snapI, "astra")
check("intent: the newest say or tell; walking leads somewhere", ia.get("intent", "").startswith("Sol: bringing 50")
      and ia["doing"] == "heading off for Silo restock", str(ia))
cm = _caster(_FactsWriter([]))
f1 = {"agent": dict(ia)}
cm.mark_changes(f1)
f2 = {"agent": dict(ia, working_on="Concrete cell", intent="Concrete next.")}
cm.mark_changes(f2)
f3 = {"agent": dict(f2["agent"])}
cm.mark_changes(f3)
check("walking to a job is fine once the facts say where it leads", caster.style_fault(
    "Astra's walking to restock the silo.", caster.known_text({"agent": ia})) is None)
check("since_last_beat: a new job and new words; then nothing new", "since_last_beat" not in f1["agent"] and
      "took a new job: Concrete cell" in f2["agent"]["since_last_beat"] and "said something new" in
      f2["agent"]["since_last_beat"] and f3["agent"]["since_last_beat"] == ["nothing new since the hosts last saw them"],
      str(f2["agent"].get("since_last_beat")))

# HOSTS4 item 2: researched but not built, as commentary for viewers
import model  # noqa: E402
um = model.Model({"title": "t", "agents": {}})
um.ingest({"tick": 60, "research": {"done": ["logistic-robotics", "gun-turret", "solar-energy"], "current": None},
           "entities": {"gun-turret": 12}, "entities_counted": ["gun-turret", "roboport", "solar-panel", "accumulator"]},
          now=1000.0)  # already done when the stream started
um.ingest({"tick": 120, "research": {"done": ["logistic-robotics", "gun-turret", "solar-energy",
                                              "electric-energy-accumulators"], "current": None},
           "entities": {"gun-turret": 12, "solar-panel": 19},
           "entities_counted": ["gun-turret", "roboport", "solar-panel", "accumulator"]}, now=1000.0 + 3600)
uu = um.snapshot(1000.0 + 3600 + 180)["unused_unlocks"]
check("unused unlocks: researched, none built; oldest first; when", [u["unlocks"] for u in uu] ==
      ["roboports", "accumulators"] and uu[0]["researched"] == "before this stream" and
      uu[1]["researched"] == "3 minutes ago", str(uu))
um2 = model.Model({"title": "t", "agents": {}})
um2.ingest({"tick": 60, "research": {"done": ["logistic-robotics"], "current": None}, "entities": {"inserter": 3}},
           now=1000.0)
check("unused unlocks: nothing when the score does not say what it counts (an old score)",
      um2.snapshot(1100.0)["unused_unlocks"] == [])
nb = caster.facts_for({"kind": "lull", "angle": "explain", "t": now, "prio": 1}, {"agents": [], "unused_unlocks": uu})
check("unused unlocks reach the hosts on explain beats, as commentary", nb.get("not_built_yet") == uu and
      "commentary" in nb.get("not_built_yet_note", "") and "not_built_yet" not in caster.facts_for(
          {"kind": "attack", "text": "x", "t": now, "prio": 9}, {"agents": [], "unused_unlocks": uu}), str(nb)[:200])
check("an absence the facts back passes; another does not", caster.check_line(
    "Logistic robotics is done, but still no roboports.", nb, [], []) is None and caster.check_line(
    "Still no trains.", nb, [], []) == "claims something is missing")

# HOSTS6 item 2: a memory of framings across the shift
cf6 = caster.Caster.__new__(caster.Caster)
t6 = 10000.0
cf6.remember_framings(["Here's the replay. Biters went at the wall.", "Twenty-eight labs are waiting on packs."], now=t6)
check("one earlier opening is fine", cf6.repeat_fault("Here's the replay. A pole went down.", now=t6 + 60) is None)
cf6.remember_framings(["Here's the replay. Spitters took a pole.", "Most labs are waiting on packs again."], now=t6 + 300)
check("a third 'Here's the replay' within 20 minutes is cut; after 20 minutes it is fine",
      cf6.repeat_fault("Here's the replay. A turret this time.", now=t6 + 600) == "style: opening used again this shift"
      and cf6.repeat_fault("Here's the replay. A turret this time.", now=t6 + 300 + 1300) is None)
uf = cf6.used_framings(now=t6 + 600)
check("framings used twice reach the writer; number phrases do not", "here's the replay" in uf and
      "waiting on packs" in uf and not any("twenty" in g or "minute" in g for g in uf), str(uf))
check("framings_used_lately does not make a name supported", caster.check_line(
    "Astra holds the wall.", {"event": "lull", "framings_used_lately": ["astra's under attack"]}, ["Astra"], []) ==
      "name not in facts: Astra")
check("the rules tell the writer to avoid them", "framings_used_lately" in caster.EXCHANGE_RULES)

# HOSTS6 item 4: planet talk that is research or a plan (shake11 cut 5 such lines)
pr6 = {"event": "lull", "planets_reached": ["Nauvis"], "planets_not_reached_yet": ["Vulcanus", "Fulgora"],
       "researching": {"tech": "Planet discovery Fulgora", "percent": 18}}
check("planets: the research's own planet and a trip being packed pass; a claim to be there still fails",
      caster.check_line("Fulgora discovery sits at eighteen percent.", pr6, [], []) is None and
      caster.check_line("Sol's packing for Vulcanus already.", pr6, [], []) is None and
      caster.check_line("Their Vulcanus foundry runs hot.", pr6, [], []) == "planet not reached: Vulcanus")

# HOSTS6 item 4: counts the hosts can stand on, planet capitals, research cards past the lull budget
fc = _FactsWriter([])
cc = _caster(fc)
cc.started_t = time.time() - 600
cc.tally = caster.deque([(time.time() - 900, "attack"), (time.time() - 300, "attack"), (time.time() - 200, "death"),
                         (time.time() - 100, "death"), (time.time() - 50, "loss")])
cc.say_exchange({"kind": "death", "text": "Sonnet died", "t": now, "prio": 9}, {"agents": []}, "pbp", 2)
ct = fc.facts.get("counts", {})
check("death and loss beats carry counts, with a clock time and no 'hosts came on' (shake12 aired 'since we came on')",
      ct.get("deaths_so_far") == 2 and ct.get("loss_reports_so_far") == 1 and ct.get("attacks_last_10_minutes") == 1
      and re.fullmatch(r"\d\d:\d\d", ct.get("counted_since", "")) and "hosts" not in json.dumps(ct), str(ct))
fa7 = _FactsWriter([])
ca7 = _caster(fa7)
ca7.say_exchange({"kind": "attack", "text": "Base under attack: gun turret", "t": now, "prio": 9}, {"agents": []}, "pbp", 2)
check("attack beats carry no counts (shake12 quoted 'N attacks in ten minutes' on nearly every one)",
      "counts" not in fa7.facts)
cq7 = caster.Caster.__new__(caster.Caster)
cq7.remember_framings(["Another hit on the turret. That's seven attacks in ten minutes now.",
                       "Busy stretch. Eight attacks in ten minutes, and still zero deaths."], now=t6)
uq7 = cq7.used_framings(now=t6 + 60)
check("framings count numbers as N when they count events, not when they are units", "attacks in N minutes" in uq7
      and not any("N" in g for g in caster.framings("Four hundred plates a minute, up from three hundred.")[1]),
      str(uq7))
ft = _FactsWriter([])
ctk = _caster(ft)
ctk.a = caster.argparse.Namespace(**{**vars(ctk.a), "quiet": 20, "lull": 40, "stale": 45, "dry_run": True,
                                     "always": True, "urgent_gap": 0.5, "naturalist": 0, "lines": (2, 2),
                                     "segment_every": 1e9, "attack_gap": 120})
ctk.lock, ctk.events, ctk.prep, ctk.next_gap, ctk.filler_i = caster.threading.Lock(), caster.deque(maxlen=60), [], 1.0, 0
ctk.snap, ctk.caster_free, ctk.last_attack_t = {"agents": []}, 0.0, time.time() - 60
ctk.events.append({"kind": "attack", "text": "Base under attack: gun turret", "t": time.time(), "prio": 9})
ctk.caster_tick(time.time(), {})
check("a plain attack 60 s after the last attack beat is dropped", not hasattr(ft, "facts"))
ctk.events.append({"kind": "loss", "text": "3 lost: 3 pipe (by small biters)", "t": time.time(), "prio": 8})
ctk.caster_tick(time.time(), {})
check("a loss still speaks inside the attack gap", getattr(ft, "facts", {}).get("event") == "loss")
cph = caster.Caster.__new__(caster.Caster)
cph.remember_framings(["Turrets are doing their job out west.", "Walls up, turrets are doing their job.",
                       "Good news, the turrets are doing their job again."], now=t6)
check("a 4-word phrase aired three times in 30 minutes is cut wherever it sits (shake12: 'turrets are doing their job')",
      cph.repeat_fault("Busy wave, and the turrets are doing their job.", now=t6 + 120) ==
      "style: phrase used again this shift" and cph.repeat_fault("The wall held this time.", now=t6 + 120) is None)
cp = caster.Caster.__new__(caster.Caster)
cp.a = caster.argparse.Namespace(dry_run=False, segment_every=180)
cp.seg_req_t, cats, posted = 0.0, [{}, {"research": {}}], []
cp.segment_types = lambda: cats.pop(0) if cats else {"research": {}}
cp.base = "http://x"
_o = caster.urllib.request.urlopen
caster.urllib.request.urlopen = lambda req, timeout=0: posted.append(json.loads(req.data)) or type(
    "R", (), {"__enter__": lambda self: self, "__exit__": lambda self, *a: None, "read": lambda self: b'{"state": "queued"}'})()
cp.record = lambda **k: None
try:
    cp.request_segment([("research", {})], "research", news=True)
    first_pending = bool(cp.pending_news)
    cp.retry_news_card(time.time() + 10)
finally:
    caster.urllib.request.urlopen = _o
check("a research card the director cannot take yet is asked for again", first_pending and
      [p["type"] for p in posted] == ["research"] and not cp.pending_news, str(posted))
check("previously on: growth only for buildings the first score counted (shake12: '135 more gun turret')",
      caster.previous_shift.__doc__ and "gun-turret" not in caster.SCORE_COUNTED_BEFORE)
check("planet names keep their capitals in technology labels", model.tech_label("planet-discovery-fulgora") ==
      "Planet discovery Fulgora")
asked = []
cr = caster.Caster.__new__(caster.Caster)
cr.a = caster.argparse.Namespace(dry_run=False, segment_every=180)
cr.seg_req_t = time.time() - 30  # a lull card was asked for 30 s ago
cr.segment_types = lambda: asked.append("catalog") or {}
cr.request_segment([("production", {})], "lull")
cr.request_segment([("research", {})], "research", news=True)
check("a research card is asked for even right after a lull card (shake11: 1 card for 4 completions)",
      asked == ["catalog"], str(asked))

# HOSTS5 item 1: "previously on" from the last shift's logs
with tempfile.TemporaryDirectory() as root5:
    runs5 = os.path.join(root5, "runs")
    os.makedirs(os.path.join(runs5, "shake10"))
    os.makedirs(os.path.join(runs5, "shake11"))
    os.makedirs(os.path.join(root5, "logs"))
    open(os.path.join(runs5, "shake11", "resumed-from"), "w").write("shake10\n")
    with open(os.path.join(runs5, "shake10", "scores.jsonl"), "w") as fh:
        for tick, done, ents, rockets in ((100, ["automation"], {"steel-furnace": 10, "transport-belt": 5}, 2),
                                          (200, ["automation", "military-3"], {"steel-furnace": 15}, 3),
                                          (14500, ["automation", "military-3", "circuit-network"],
                                           {"steel-furnace": 21, "solar-panel": 7, "transport-belt": 600}, 10)):
            fh.write(json.dumps({"score": {"tick": tick, "research_done": done, "entities": ents, "rockets": rockets}}) + "\n")
    jl = os.path.join(root5, "logs", "c.jsonl")
    with open(jl, "w") as fh:
        for ev, text in (("death", "Grok died"), ("death", "Grok died"), ("death", "Opus died"),
                         ("loss", "8 lost: 8 pipe (by small biters)"), ("loss", "73 lost: 17 transport belt (by medium biters)")):
            fh.write(json.dumps({"type": "caster", "facts": {"event": ev, "text": text}}) + "\n")
    open(os.path.join(runs5, "shake10", "caster.log"), "w").write(f"18:47:35 [caster] feed x  log {jl}\n")
    pv = caster.previous_shift(os.path.join(runs5, "shake11"))
    check("previously on: research in order, buildings (not belts), rockets, deaths, losses", pv and
          pv["technologies_researched"] == 2 and pv["last_researched"] == ["Military 3", "Circuit network"] and
          pv["built"] == ["11 more steel furnace", "7 more solar panel"] and pv["rockets_launched"] == 8 and
          pv["deaths"] == 2 and pv["loss_reports"] == 2 and pv["biggest_loss"].startswith("73 lost"), str(pv))
    check("previously on: none for a first shift", caster.previous_shift(os.path.join(runs5, "shake10")) is None)
    fw5 = _FactsWriter([])
    c6 = _caster(fw5)
    c6.a = caster.argparse.Namespace(**{**vars(c6.a), "run_dir": os.path.join(runs5, "shake11")})
    c6.say_exchange({"kind": "open", "t": now, "prio": 8}, {"agents": []}, "pbp", 3)
    check("the opener of a resumed shift carries previously_on and the recap call",
          fw5.facts.get("previously_on", {}).get("rockets_launched") == 8 and "previously on" in
          fw5.facts.get("how_to_call_it", "") and fw5.facts["previously_on"]["biggest_loss"].startswith("73 lost to"),
          str(fw5.facts)[:300])

# HOSTS5 item 2: the team plan, and a change to it as news
planA = {"goals": "Silo fed, then rails", "doing": [{"agent": "sol", "name": "Sol", "text": "silo ammo"},
                                                    {"agent": "luna", "name": "Luna", "text": "steam row"}]}
planB = {"goals": "Silo fed, then rails", "doing": [{"agent": "sol", "name": "Sol", "text": "rails to the north ore"},
                                                    {"agent": "luna", "name": "Luna", "text": "steam row"}]}
dp = caster.Differ()
dp.diff({"agents": [], "board": {"plan": planA}})
evp = [e for e in dp.diff({"agents": [], "board": {"plan": planB}}) if e["kind"] == "plan"]
check("a change to the team plan is a plan beat", len(evp) == 1 and evp[0]["changes"] ==
      ["Sol is now on: rails to the north ore"] and evp[0]["prio"] == 5, str(evp))
fp = caster.facts_for(evp[0], {"agents": [{"name": "sol", "display_name": "Sol"}], "board": {"plan": planB}})
check("plan beat facts: the change, the plan, how to call it", fp.get("plan_change") == evp[0]["changes"] and
      fp["team_plan"]["goals"] == "Silo fed, then rails" and "plan just changed" in fp["how_to_call_it"], str(fp)[:300])
sp5 = {"agents": [{"name": "luna", "display_name": "Luna", "activity": "acting", "action": "walking"}],
       "board": {"plan": planB}}
check("an agent's plan line is its job when no claim names one", caster.agent_facts(sp5, "luna").get("working_on")
      == "steam row" and caster.agent_facts(sp5, "luna")["doing"] == "heading off for steam row")

# HOSTS4 item 3: an agent answering a viewer (the relay reaches the agents from shake11) is its own beat
dv = caster.Differ()
dv.diff({"agents": [], "chat": []})
tnow = time.time()
evv = dv.diff({"agents": [], "chat": [
    {"seq": 50, "from": "viewer", "viewer": "NickWinter", "lane": "viewer", "text": "viewer NickWinter: why no roboports yet?",
     "t": tnow - 20},
    {"seq": 51, "agent": "sol", "from": "Sol", "text": "@NickWinter good question: roboports right after the silo.",
     "t": tnow - 2}]})
vr = [e for e in evv if e["kind"] == "viewer_reply"]
check("an agent's line naming a recent viewer becomes a viewer_reply beat", len(vr) == 1 and vr[0]["viewer"] ==
      "NickWinter" and vr[0]["question"] == "why no roboports yet?" and vr[0]["prio"] == 7, str(evv))
fvr = caster.facts_for(vr[0], {"agents": [{"name": "sol", "display_name": "Sol"}]})
check("viewer_reply facts: the question, the agent's answer, how to call it", fvr["viewer_message"]["from"] ==
      "NickWinter" and "roboports right after the silo" in fvr["agent_answer"] and "answered a viewer" in
      fvr["how_to_call_it"] and caster.clip_rank(vr[0]) == "viewer", str(fvr)[:300])
evn = dv.diff({"agents": [], "chat": [{"seq": 52, "agent": "sol", "from": "Sol", "text": "Silo next, then rails.",
                                       "t": time.time()}]})
check("a line that names no viewer is plain chat", not [e for e in evn if e["kind"] == "viewer_reply"])

# HOSTS4: Opus on shake10 aired cut-off lines, verdict openers and lowercase names
check("a line cut off mid-word is cut", caster.check_line("They scanned before leaving. Two ass", {"event": "lull"}, [],
                                                           []) == "cut off mid-sentence")
check("a second verdict opener within eight lines is cut", caster.check_line(
    "Good timing. Projectile damage helps.", {"event": "lull"}, [], ["Vale: Smart read. Coal keeps boilers burning."])
      == "style: another verdict opener" and caster.check_line("Good timing. Projectile damage helps.",
                                                                  {"event": "lull"}, [], []) is None)
check("names capitalised, the poem left alone", caster.proper_names("Haiku told astra. Astra writes as haiku.",
                                                                     ["Astra", "Haiku"]) == "Haiku told Astra. Astra writes as haiku.")
check("the notes say not to grade the last line", "Don't open by grading the last line" in caster.SPOKEN)

# HOSTS3 item 6 (b): speak less. A low-value beat waits for --quiet; filler waits for --lull and something new.
import threading  # noqa: E402
fq = _FactsWriter([])
cq = _caster(fq)
cq.a = caster.argparse.Namespace(**{**vars(cq.a), "quiet": 20, "lull": 40, "stale": 45, "dry_run": True,
                                    "always": True, "urgent_gap": 0.5, "naturalist": 0, "lines": (2, 2),
                                    "segment_every": 1e9})
cq.lock, cq.events, cq.prep, cq.next_gap, cq.filler_i = threading.Lock(), caster.deque(maxlen=60), [], 1.0, 0
cq.seg_cat, cq.seg_cat_t, cq.seg_req_t, cq.seg_next_ok = {}, 0.0, 0.0, 0.0
cq.snap = {"agents": [], "research": {"done_count": 40, "label": "Rocket silo"}, "science": {"spm": 30}}
t = time.time()
cq.caster_free = t - 5
cq.events.append({"kind": "camera", "agents": [], "t": t, "prio": 2})
cq.caster_tick(t, {})
check("speak less: a camera cut 5 s after the hosts spoke is not said", not hasattr(fq, "facts"))
cq.last_digest = caster.digest(cq.snap)
cq.caster_free = t - 60
cq.caster_tick(t, {})
check("speak less: filler with nothing new stays silent", not hasattr(fq, "facts"))
cq.snap = dict(cq.snap, research={"done_count": 41, "label": "Rocket part productivity"})
cq.caster_free = t - 60
cq.caster_tick(t, {})
check("speak less: filler after news speaks", getattr(fq, "facts", {}).get("event") == "lull", str(getattr(fq, "facts", None))[:200])
check("urgent beats stay on Kimi when the main writer changes", caster.URGENT_MODEL == caster.DEFAULT_MODEL)

# Round 6 (shake5 P1 item 4): stage 3 is "Oil & blue science", and the stage fact says which packs are made
import model  # noqa: E402
check("stage 3 label names blue science", model.STAGE_LABELS[3] == "Oil & blue science")
stf = caster.context_facts({"science": {"stage": 3, "stage_label": model.STAGE_LABELS[3], "spm": 40, "packs": [
    {"item": "automation-science-pack", "rate": 20, "total": 900}, {"item": "logistic-science-pack", "rate": 12,
    "total": 700}, {"item": "chemical-science-pack", "rate": 8, "total": 566}]}})
check("the stage fact comes with the packs being made", stf["stage"] == "Oil & blue science" and
      stf["science_packs_made"] == ["red (automation)", "green (logistic)", "blue (chemical)"], str(stf))

print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
