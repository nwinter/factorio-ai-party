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
check("the clock only where it matters, or in the last 15 minutes", "minutes_to_deadline" not in cam_far
      and cam_near.get("minutes_to_deadline") == 10, f"{cam_far} {cam_near}")
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
check("thinking is 'planning the next step', not standing still", g["status"] == "planning the next step"
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
    check("shift: the opener carries it and welcomes viewers back", so.get("shift") == sh
          and "later shift" in so.get("how_to_call_it", ""), str(so))
    far = caster.facts_for({"kind": "camera", "agents": [], "t": 0, "prio": 2}, {"agents": []}, None, time.time() + 2400, sh)
    near = caster.facts_for({"kind": "camera", "agents": [], "t": 0, "prio": 2}, {"agents": []}, None, time.time() + 300, sh)
    check("shift: on every beat (time left only with the clock)", far.get("shift") == sh and near.get("shift") == sh
          and "minutes_to_deadline" not in far and near.get("minutes_to_deadline"))
    check("shift numbers: this shift and the next pass, others and run names fail", caster.check_line(
        "Shift three keeps rolling. Shift four gets this world next.", far, [], []) is None and caster.check_line(
        "Shift five inherits it.", far, [], []) == "shift number not in facts: shift five" and caster.check_line(
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
check("a second style fault falls back to a template", len(w2.notes) == 2 and c2.stats["fallbacks"] == 1
      and c2.spoke and c2.spoke[0][1] != bad[1][1], str(c2.spoke))
w3 = _Writer([[bad[1]], good])
c3 = _caster(w3)
c3.say_exchange({"kind": "death", "text": "Sonnet died", "t": now, "prio": 9}, {"agents": []}, "pbp", 2)
check("urgent beats get no rewrite", len(w3.notes) == 1, str(w3.notes))

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
