#!/usr/bin/env python3
"""The hosts know the story (hoststory.py; viewer Joonazan, shift07 16:38: "why is Rook always out of the loop?"):
python3 tools/stream/test_hoststory.py

1. AttackGate: a hit with nothing lost is no beat (a quiet hit, a word in another line); a loss near it, a key battle
   on air (its own fight, or one held on an incoming group) or a threat score at the director's floor (an agent
   fighting a minute) make it one, at once or when it comes to matter.
2. StoryMemo: headlines (headlines, space firsts, deaths, big losses), goals, each agent's plan line and last spoken
   line, research and what is stuck; rebuilt every few minutes, kept in the run folder across restarts.
3. caster.py: the snapshot path (on_snapshot) gates attack events and keeps the memo; every beat's facts carry the
   memo, why an attack is a beat, and the quiet hits; the booth guide says to know the story, not to tell it.
4. (d23 batch130 CM1) ArrivalGate: an arrival speaks when it is the route's first this shift, brings science or eggs
   (a platform's first delivery of that kind on that route), belongs to a ship the goals name, or ends a leg of an
   hour; the rest are a traffic count in the facts. model.py's arrival alert carries the leg and the cargo, and a new
   shift knows where each platform has been. d23's replay: python3 tools/stream/hosts_replay.py
5. (CM2) An analyst point is a beat of its own at priority 5, one per four minutes, a topic once per half hour, shaped
   as one number and a reason, its lines held to the point's facts.
6. (CM3) The memo carries "the run so far" from a file the operator edits (read again at each rebuild), and the
   plan's goals and lines in plain English by one small model call at most every ten minutes; the hosts' snapshot
   never carries the agents' shorthand, and a plan change waits for its rewrite.
The shift07 16:20-16:38 replay: python3 tools/stream/hostguide_replay.py --story [--writer or:MODEL].
"""
import json, os, sys, tempfile, threading, time
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import caster, hoststory  # noqa: E402


def fight(key, first, last, agent=None, losses=(), x=0, y=0, text=None):
    return {"key": key, "kind": "attack", "first": first, "last": last, "agent": agent, "losses": list(losses),
            "position": {"x": x, "y": y, "surface": "nauvis"}, "text": text}


def attack(key, text, agent=None, x=0, y=0):
    return {"kind": "attack", "text": text, "agent": agent, "alert_key": key, "position": {"x": x, "y": y},
            "prio": caster.PRIORITY["attack"], "t": time.time()}


def gate_tests():
    now = 1_000_000.0
    g = hoststory.AttackGate(None)
    hit = attack("area:80,80", "Base under attack: gun turret", x=80, y=80)
    s = {"fights": [fight("area:80,80", now, now, x=80, y=80)]}
    assert g.admit(hit, s, now) == [], "a single hit with nothing lost: no beat"
    assert g.poll(s, now + 10) == []
    assert g.poll({"fights": []}, now + 30) == [] and g.quiet_note(now + 31).startswith("1 small hit"), "ended quietly"
    assert "never its own line" in g.quiet_note(now + 31) and g.quiet_note(now + 400) is None
    # a loss in a fight within 64 tiles, in the last 2 minutes: a beat
    lossy = {"fights": [fight("area:80,80", now, now, x=80, y=80),
                        fight("loss:nauvis:#70", now - 20, now, losses=[now - 5], x=100, y=90, text="3 lost: 3 gun turret")]}
    out = g.admit(hit, lossy, now)
    assert len(out) == 1 and out[0]["why_it_matters"] == "buildings lost in this fight (3 lost: 3 gun turret)", out
    far = {"fights": [fight("area:80,80", now, now, x=80, y=80),
                      fight("loss:nauvis:#71", now, now, losses=[now], x=400, y=400)]}
    assert g.admit(hit, far, now) == [], "a loss far away is another fight"
    # a key battle on air: its own fight, or a battle held on an incoming group (no fight of that key)
    assert g.admit(hit, dict(s, onair={"battle": "area:80,80"}), now)[0]["why_it_matters"] == "a key battle, on screen now"
    assert g.admit(hit, dict(s, onair={"battle": "group:57"}), now)[0]["why_it_matters"] == \
        "part of the key battle on screen now"
    # an agent attacked: first sign, no beat; still fighting a minute later (the director's floor 1.5): a beat
    g2 = hoststory.AttackGate(None)
    astra = attack("attack:astra", "Astra is under attack", agent="astra")
    assert g2.admit(astra, {"fights": [fight("attack:astra", now, now, agent="astra")]}, now) == []
    assert g2.poll({"fights": [fight("attack:astra", now, now + 30, agent="astra")]}, now + 30) == []
    late = g2.poll({"fights": [fight("attack:astra", now, now + 61, agent="astra")]}, now + 61)
    assert len(late) == 1 and late[0]["why_it_matters"].startswith("threat score 1.5"), late
    # the run's threat history is read (the director writes it): a demolisher's tier counts at once
    d = tempfile.mkdtemp()
    json.dump({"sizes": [5] * 30, "pieces": [1] * 30, "tiers": [1] * 30, "bearings": [], "tiers_seen": {"1": 30},
               "candidates": [], "taken": []}, open(os.path.join(d, "threat-history.json"), "w"))
    g3 = hoststory.AttackGate(os.path.join(d, "threat-history.json"))
    demo = attack("area:5,5", "Base under attack: gun turret (by small demolisher)", x=5, y=5)
    out = g3.admit(demo, {"fights": [fight("area:5,5", now, now, x=5, y=5, text=demo["text"])]}, now)
    assert out and "tier" in out[0]["why_it_matters"], out
    # not attacks: untouched
    assert g.admit({"kind": "loss", "text": "1 lost"}, s, now) == [{"kind": "loss", "text": "1 lost"}]


def memo_tests():
    d = tempfile.mkdtemp()
    path = os.path.join(d, "host-memo.json")
    m = hoststory.StoryMemo(path)
    t0 = time.mktime(time.strptime("2026-10-13 12:58", "%Y-%m-%d %H:%M"))
    m.note({"kind": "loss", "text": "59 lost: 59 gun turret (by small demolishers)"}, t0)
    m.note({"kind": "loss", "text": "1 lost: 1 pipe (by medium biters)"}, t0 + 60)  # small: not a headline
    m.note({"kind": "space", "text": "Sunward is back at Nauvis"}, t0 + 4560)
    m.note({"kind": "space", "text": "Sunward is back at Nauvis"}, t0 + 4600)  # once
    m.note({"kind": "death", "text": "Haiku died"}, t0 + 4700)
    s = {"board": {"plan": {"goals": "Deliver metallurgy to Nauvis; make Sunward renewable.",
                            "doing": [{"name": "astra", "text": "Return Sunward metallurgy to Nauvis."},
                                      {"name": "sol", "text": "Vulcanus: tungsten and foundries."}]}},
         "agents": [{"name": "astra", "display_name": "Astra", "seen": True,
                     "last_said": {"text": "Sunward made it home intact with the metallurgy load.", "t": t0 + 4700}},
                    {"name": "sol", "display_name": "Sol", "seen": True, "where": "Vulcanus"},
                    {"name": "luna", "display_name": "Luna", "seen": False}],
         "research": {"label": "Exoskeleton equipment", "progress": 0.71},
         "analyst": {"headline": "Nearly every lab waits on packs.",
                     "storylines": [{"status": "developing", "text": "Dry drills and thin copper leave the labs waiting."},
                                    {"status": "resolved", "text": "old news"}]}}
    memo = m.update(s, t0 + 4800)
    assert memo["headlines"] == ["12:58 59 lost: 59 gun turret (by small demolishers)", "14:14 Sunward is back at Nauvis",
                                 "14:16 Haiku died"], memo["headlines"]
    assert memo["goals"].startswith("Deliver metallurgy") and memo["research"] == "Exoskeleton equipment, 71% done"
    assert memo["agents"] == ['Astra: Return Sunward metallurgy to Nauvis. Said 1 min ago: "Sunward made it home intact '
                              'with the metallurgy load."', "Sol: Vulcanus: tungsten and foundries. On Vulcanus"], memo["agents"]
    assert memo["stuck_or_developing"] == ["Dry drills and thin copper leave the labs waiting."]
    assert memo["state_of_play"] == "Nearly every lab waits on packs."
    f = m.facts()
    assert "Never recite it" in f["note"] and f["agents"] == memo["agents"]
    # rebuilt every few minutes, not every snapshot
    s2 = dict(s, research={"label": "Battery equipment", "progress": 0.1})
    assert m.update(s2, t0 + 4900)["research"] == "Exoskeleton equipment, 71% done"
    assert m.update(s2, t0 + 4800 + hoststory.MEMO_EVERY)["research"] == "Battery equipment, 10% done"
    # kept in the run folder: a restart keeps the headlines and the memo
    again = hoststory.StoryMemo(path)
    assert [h["text"] for h in again.headlines][-1] == "Haiku died" and again.facts()["research"].startswith("Battery")
    assert hoststory.StoryMemo(None).facts() is None
    # moments from the agents' own minds (site/content/moments.json): the latest 3 marked for the memo, one line each,
    # only what viewers saw (operator, 2026-10-13): a quote of another kind (a thought, a tell) is skipped
    mp = os.path.join(d, "moments.json")
    rows = [{"n": 22, "agents": ["astra"], "shift": 7, "time": "16:06", "fits": ["memo"], "seen": ["voiced"],
             "title": "five thousand circuits out of reach",
             "quotes": [{"who": "astra", "kind": "voiced 16:06", "text": "A provider chest only helps if robots can reach it."}]},
            {"n": 18, "agents": ["sonnet"], "shift": 7, "time": "16:58", "fits": ["memo", "chat"], "seen": ["voiced"],
             "title": "fair point, I was stuck in ...",
             "quotes": [{"who": "sonnet", "kind": "voiced", "text": "fair point, I was stuck in a courier loop."},
                        {"who": "sonnet", "kind": "working text", "text": "never seen"}]},
            {"n": 3, "agents": ["gemini"], "shift": 7, "time": "17:47", "fits": ["memo"], "seen": ["voiced"],
             "quotes": [{"who": "gemini", "kind": "thought 17:47", "text": "private thought"}]},
            {"n": 6, "agents": ["haiku"], "shift": 7, "time": "15:52", "fits": ["chat"], "seen": ["chat"],
             "quotes": [{"who": "haiku", "kind": "chat", "text": "correction: I have 0 coal now."}]},
            {"n": 29, "agents": ["opus"], "shift": 5, "time": "10:16", "fits": ["memo"], "seen": ["chat"], "title": "the delivery van",
             "quotes": [{"who": "opus", "kind": "confession", "text": "Quiet shift for me: I mostly became the team's delivery van."}]},
            {"n": 28, "agents": ["astra"], "shift": 5, "time": "09:15", "fits": ["memo"], "seen": ["voiced"],
             "quotes": [{"who": "astra", "kind": "voiced", "text": "Every hand-carried stack feels productive."}]}]
    with open(mp, "w") as f:
        json.dump(rows, f)
    assert hoststory.memo_moments(mp) == [
        'Sonnet (shift 7, 16:58), fair point, I was stuck in ...: "fair point, I was stuck in a courier loop." (said on stream)',
        'Astra (shift 7, 16:06), five thousand circuits out of reach: "A provider chest only helps if robots can reach it." '
        '(said on stream)',
        'Opus (shift 5, 10:16), the delivery van: "Quiet shift for me: I mostly became the team\'s delivery van." (in chat)']
    assert "private" not in json.dumps(hoststory.memo_moments(mp)) and "never seen" not in json.dumps(hoststory.memo_moments(mp))
    m2 = hoststory.StoryMemo(None, moments_path=mp)
    assert m2.update(s, t0 + 4800)["moments"][0].startswith("Sonnet (shift 7")
    assert "moments" not in hoststory.StoryMemo(None, moments_path=os.path.join(d, "none.json")).update(s, t0 + 4800)
    # the site's file parses into moments the memo can use, all of them seen by viewers
    real = hoststory.memo_moments()
    assert real and all(line.count('"') >= 2 and line.endswith(("(said on stream)", "(in chat)", "(said on stream; in chat)"))
                        for line in real), real


def caster_tests():
    now = time.time()
    c = caster.Caster.__new__(caster.Caster)
    c.lock, c.differ, c.events, c.chat_q = threading.Lock(), caster.Differ(), deque(maxlen=50), deque(maxlen=50)
    c.gate, c.story = hoststory.AttackGate(None), hoststory.StoryMemo(None)
    base = {"agents": [{"name": "astra", "display_name": "Astra", "seen": True}], "chat": [], "board": {}}
    c.on_snapshot(dict(base, alerts=[]))  # the first snapshot primes the differ
    hit = {"id": "area:80,80:1", "key": "area:80,80", "kind": "attack", "text": "Base under attack: gun turret",
           "position": {"x": 80, "y": 80}, "t": now}
    c.on_snapshot(dict(base, alerts=[hit], fights=[fight("area:80,80", now, now, x=80, y=80)]))
    assert not [e for e in c.events if e["kind"] == "attack"], "a hit with nothing lost is no beat"
    lost = {"id": "loss:1", "key": "loss:nauvis:#70", "kind": "loss", "text": "12 lost: 12 gun turret (by big biters)",
            "t": now}
    c.on_snapshot(dict(base, alerts=[hit, lost], fights=[
        fight("area:80,80", now, now, x=80, y=80),
        fight("loss:nauvis:#70", now, now, losses=[now], x=90, y=80, text=lost["text"])]))
    beats = [e for e in c.events if e["kind"] != "open"]  # (the show's opener, from the first snapshot)
    assert [e["kind"] for e in beats] == ["loss", "attack"], beats  # the waiting attack came to matter with the loss
    assert beats[1]["why_it_matters"].startswith("buildings lost in this fight")
    assert c.story.headlines[-1]["text"] == lost["text"], "a big loss is a headline of the run"
    f = caster.story_facts({}, beats[1], c.story, c.gate, now)
    assert f["why_it_matters"] and "Never recite it" in f["story"]["note"]
    assert "Know the story, don't tell it" in caster.DIALOGUE and "Never read it out" in caster.DIALOGUE
    ev = caster.Differ()
    ev.diff({"alerts": []})
    e = ev.diff({"alerts": [hit]})[0]
    assert e["alert_key"] == "area:80,80" and e["position"] == {"x": 80, "y": 80}
    print("hoststory: ok (quiet hits, losses near, key battles, an agent fighting a minute, threat history, memo "
          "headlines/goals/agents/research/stuck, every few minutes, kept across restarts, caster wiring)")


def arrival(name, came, planet, leg=None, carrying=None):
    return {"kind": "arrival", "text": f"{name} arrives at {planet}", "prio": caster.PRIORITY["arrival"],
            "facts": {"platform": name, "came_from": came, "planet": planet, "leg_minutes": leg, "carrying": carrying}}


def arrival_tests():
    now = 1_000_000.0
    d = tempfile.mkdtemp()
    path = os.path.join(d, "host-arrivals.json")
    g = hoststory.ArrivalGate(path)
    s = {"board": {"plan": {"goals": "Reach Shattered Planet. Asterion's full edge roundtrip, then 25 chunks."}}}
    # a platform's first visit (a space headline) passes and notes its route
    first = {"kind": "space", "text": "Swiftlet is back at Nauvis", "facts": {"platform": "Swiftlet", "came_from": "Gleba",
                                                                          "planet": "Nauvis", "headline": "platform_arrival"}}
    assert g.admit(first, s, now) == [first]
    out = g.admit(arrival("Cinder", "Nauvis", "Gleba", leg=9), s, now)
    assert out and out[0]["why_it_matters"] == "the first platform from Nauvis to Gleba this shift", out
    assert g.admit(arrival("Kestrel II", "Gleba", "Nauvis", leg=12), s, now + 30) == [], "the route Swiftlet flew"
    assert g.admit(arrival("Cinder", "Nauvis", "Gleba", leg=9), s, now + 60) == [], "a routine docking"
    # science or eggs: a platform's first delivery of that kind on that route, not every trip of a freighter
    out = g.admit(arrival("Meridian-V", "Gleba", "Nauvis", carrying="1200 agricultural science pack"), s, now + 90)
    assert out and out[0]["why_it_matters"] == "it brings 1200 agricultural science pack", out
    assert g.admit(arrival("Meridian-V", "Gleba", "Nauvis", carrying="1000 agricultural science pack"), s, now + 99) == []
    out = g.admit(arrival("Meridian-V", "Gleba", "Nauvis", carrying="900 agricultural science pack, 20 biter egg"), s, now + 120)
    assert out and "20 biter egg" in out[0]["why_it_matters"], "eggs: a new kind"
    # a ship the goals name, a long leg
    out = g.admit(arrival("Asterion", "Solar system edge", "Aquilo", leg=95), s, now + 150)
    assert out and out[0]["why_it_matters"] == ("the first platform from Solar system edge to Aquilo this shift; the "
                                                "team's goals name this ship; it ends a 95-minute leg"), out
    out = g.admit(arrival("Asterion", "Solar system edge", "Aquilo", leg=20), s, now + 160)
    assert out and out[0]["why_it_matters"] == "the team's goals name this ship"
    assert not hoststory.ArrivalGate.in_goals("Aster", s) and hoststory.ArrivalGate.in_goals("asterion", s)
    out = g.admit(arrival("Spindle", "Nauvis", "Gleba", leg=61), s, now + 170)
    assert out and out[0]["why_it_matters"] == "it ends a 61-minute leg"
    # the rest: a traffic count for a word in another beat
    note = g.traffic_note(now + 180)
    assert note.startswith("3 routine platform arrivals in the last 10 minutes (latest: Meridian-V arrives at Nauvis)") \
        and "never its own line" in note, note
    assert g.traffic_note(now + 2000) is None
    assert g.admit({"kind": "loss", "text": "1 lost"}, s, now) == [{"kind": "loss", "text": "1 lost"}]
    # kept in the run folder: a restart keeps the shift's routes and deliveries
    again = hoststory.ArrivalGate(path)
    assert again.admit(arrival("Chalk", "Nauvis", "Gleba"), s, now) == []
    assert again.admit(arrival("Meridian-V", "Gleba", "Nauvis", carrying="5 agricultural science pack"), s, now) == []

    # model.py: the arrival alert carries the leg (route memory) and the science or eggs in the hub
    from model import Model, story_cargo
    assert story_cargo("iron-plate*900 agricultural-science-pack*1200 biter-egg*20 agricultural-science-pack@rare*5 "
                       "+3 more") == "1205 agricultural science pack, 20 biter egg"
    assert story_cargo("iron-plate*900") == "" and story_cargo(None) == ""
    m = Model({"agents": {}, "space_age": True})

    def read(t, tick, at, hub=None):
        row = {"name": "Meridian-V", "at": at, "hub": True, "state": "on_the_path" if "->" in at else "waiting_at_station"}
        if hub:
            row["hub_items"] = hub
        m.ingest({"tick": tick, "agents": [], "space": {"rockets": 9, "planets": ["nauvis", "gleba"], "platforms": [row]}}, t)
    read(now, 1000, "nauvis")
    read(now + 10, 2000, "nauvis->gleba 5%")
    read(now + 20, 2000 + 3600 * 70, "gleba")  # its first at Gleba: the orbit moment
    read(now + 30, 2000 + 3600 * 71, "nauvis->gleba 95%")
    read(now + 40, 2000 + 3600 * 80, "nauvis", hub="agricultural-science-pack*1200 spoilage*40")
    a = [x for x in m.alerts if x["key"].startswith("arrive:Meridian-V:nauvis")]
    assert a and a[-1]["kind"] == "arrival", m.alerts
    assert a[-1]["facts"]["leg_minutes"] == 9 and a[-1]["facts"]["carrying"] == "1200 agricultural science pack", a[-1]["facts"]

    # caster.py: the snapshot path gates arrivals; every beat's facts carry the traffic count
    c = caster.Caster.__new__(caster.Caster)
    c.lock, c.differ, c.events, c.chat_q = threading.Lock(), caster.Differ(), deque(maxlen=50), deque(maxlen=50)
    c.gate, c.story, c.arrivals = hoststory.AttackGate(None), hoststory.StoryMemo(None), hoststory.ArrivalGate(None)
    base = {"agents": [], "chat": [], "board": {}}
    c.on_snapshot(dict(base, alerts=[]))
    al = [{"id": f"arrive:Cinder:gleba:{i}", "key": f"arrive:Cinder:gleba:{i}", "kind": "arrival",
           "text": "Cinder arrives at Gleba", "facts": {"platform": "Cinder", "planet": "Gleba", "came_from": "Nauvis"}}
          for i in (1, 2)]
    c.on_snapshot(dict(base, alerts=al[:1]))
    c.on_snapshot(dict(base, alerts=al))
    got = [e for e in c.events if e["kind"] == "arrival"]
    assert len(got) == 1 and got[0]["why_it_matters"].startswith("the first platform from Nauvis"), list(c.events)
    f = caster.story_facts({}, got[0], None, None, time.time(), c.arrivals)
    assert f["why_it_matters"] and f["traffic"].startswith("1 routine platform arrival in"), f
    assert "why_it_matters" in caster.facts_for(dict(got[0]), {})["how_to_call_it"]


def analyst_tests():
    now = time.time()
    pts = [{"id": "tp9", "kind": "stat", "topic": "spm-steady", "priority": 3, "expires": now + 300,
            "text": "The labs hold 112 science per minute.", "facts": {"spm": 112}},
           {"id": "tp8", "kind": "storyline", "topic": "ore-depletion", "priority": 2, "expires": now + 300,
            "text": "93 of 94 drills report no minable resources, so scrap feeds the factory.",
            "facts": {"drills_depleted": 93, "electric_drills": 94}},
           {"id": "tp7", "kind": "storyline", "topic": "agents-idle", "priority": 1, "expires": now + 300, "text": "x"}]
    s = {"analyst": {"talking_points": pts}, "agents": [], "chat": [], "board": {}}
    e = caster.analyst_event(s, set(), {}, now)
    assert e["kind"] == "analyst" and e["point"]["id"] == "tp9" and e["prio"] == caster.PRIORITY["analyst"] == 5
    assert caster.analyst_event(s, {"tp9"}, {}, now)["point"]["id"] == "tp8", "a used id: the next"
    aired = {}
    caster.analyst_aired(aired, {"topic": "steady-spm", "text": "Nothing alike."}, now - 600)
    assert caster.analyst_event(s, set(), aired, now)["point"]["id"] == "tp8", "a topic aired lately, its words in any order"
    aired = {}
    caster.analyst_aired(aired, {"topic": "steady-spm", "text": "Nothing alike."}, now - caster.ANALYST_TOPIC_GAP)
    assert caster.analyst_event(s, set(), aired, now)["point"]["id"] == "tp9", "half an hour later"
    aired = {}
    caster.analyst_aired(aired, {"topic": "lab-rate", "text": "The labs hold 112.6 science per minute."}, now - 60)
    assert caster.analyst_event(s, set(), aired, now)["point"]["id"] == "tp8", "much the same text under another topic"
    assert caster.analyst_event(s, {"tp9", "tp8"}, {}, now) is None, "priority 1 never"
    assert caster.analyst_event({"analyst": {"talking_points": [dict(pts[0], expires=now - 1)]}}, set(), {}, now) is None
    assert caster.PRIORITY["arrival"] > caster.PRIORITY["analyst"] > caster.PRIORITY["chat"]
    # the snapshot path: one analyst beat waiting at a time, none within ANALYST_EVERY of the last one
    c = caster.Caster.__new__(caster.Caster)
    c.lock, c.differ, c.events, c.chat_q = threading.Lock(), caster.Differ(), deque(maxlen=50), deque(maxlen=50)
    c.used_points = set()
    c.on_snapshot(s)
    c.on_snapshot(s)
    assert [x["kind"] for x in c.events].count("analyst") == 1, list(c.events)
    c.events.clear()
    c.analyst_t = time.time()
    c.on_snapshot(s)
    assert not [x for x in c.events if x["kind"] == "analyst"], "inside four minutes of the last"
    c.analyst_t = time.time() - caster.ANALYST_EVERY
    c.on_snapshot(s)
    assert [x for x in c.events if x["kind"] == "analyst"]
    # facts: the point and how to call it; the lines hold to the point's numbers, not the background's
    snap = dict(s, science={"spm": 112, "stage_label": "Rocket"}, research={"label": "Plastic bar productivity 8",
                                                                           "progress": 0.57, "done_count": 246})
    ev = caster.analyst_event(snap, {"tp9"}, {}, now)
    f = caster.facts_for(ev, snap)
    assert f["analyst_point"]["point"].startswith("93 of 94") and f["how_to_call_it"] == caster.ANALYST_CALL
    assert "cause" in caster.ANALYST_CALL and "one number at most" in caster.ANALYST_CALL
    assert "never what the team should do" in caster.ANALYST_CALL
    assert (f.get("background") or {}).get("technologies_done") == 246
    held = caster.checked_facts(ev, f)
    assert set(held) <= set(caster.ANALYST_CHECK) and "background" not in held
    assert caster.check_line("Ninety-three of the drills are dry, so scrap now feeds the factory.", held, [], []) is None
    assert caster.check_line("With 246 technologies done, the drills are dry.", held, [], []) == \
        "number not in facts: 246"
    assert caster.check_line("With 246 technologies done, the drills are dry.", f, [], []) is None, "other beats: all"
    assert caster.checked_facts({"kind": "arrival"}, f) is f
    print("hoststory: ok (arrivals: route firsts, new cargo, goal ships, long legs, traffic, kept; model leg and "
          "cargo; analyst beats: priority 5, one per four minutes, topics, held to the point)")


class FakeWriter:
    def __init__(self, reply):
        self.reply, self.prompts, self.spent = reply, [], 0.0

    def complete(self, system, user, max_tokens=80):
        self.prompts.append((system, user))
        return self.reply(user) if callable(self.reply) else self.reply


def plain_tests():
    now = 1_000_000.0
    d = tempfile.mkdtemp()
    # the run block: a file beside the shift folders, started from the repo's seed, read again at each rebuild
    run_dir = os.path.join(d, "shift66")
    os.makedirs(run_dir)
    path = hoststory.run_block_path(run_dir)
    assert path == os.path.join(d, "host-run-so-far.md") and os.path.exists(path)
    seed = open(hoststory.RUN_BLOCK_SEED).read()
    assert open(path).read() == seed and 250 <= len(seed.split()) <= 400, len(seed.split())
    assert "Asterion" in seed and "Shattered Planet" in seed and "should" not in seed.lower()
    m = hoststory.StoryMemo(None, moments_path=os.path.join(d, "none.json"), run_block=path)
    memo = m.update({"board": {}}, now)
    assert memo["run_so_far"].startswith("Nine AI models began") and "\n" not in memo["run_so_far"]
    with open(path, "w") as f:
        f.write("# heading\n\nThe operator's own words.\n\nA second paragraph.\n")
    assert m.update({"board": {}}, now + 10)["run_so_far"].startswith("Nine AI"), "until the next rebuild"
    assert m.update({"board": {}}, now + hoststory.MEMO_EVERY)["run_so_far"] == "The operator's own words. A second paragraph."
    assert hoststory.run_block_path(run_dir) == path and open(path).read().startswith("# heading"), "an edit is kept"
    assert hoststory.read_run_block(os.path.join(d, "missing.md")) is None

    # plain_checked: numbers from the note only, no ticks, whole sentences up to the cap
    raw = "Asterion probe launched53840310: legendary pair; all23 healthy"
    assert hoststory.plain_checked("Asterion is out on a probe. It left at tick 53840310. All 23 guns are fed. "
                                   "It has 40 rockets.", raw) == "Asterion is out on a probe. All 23 guns are fed."
    assert hoststory.plain_checked("One two three four. Five six seven eight.", "x", words=5) == "One two three four."
    assert hoststory.plain_checked(None, raw) == ""

    # the rewrite: one call for the texts not yet rewritten, at most every PLAIN_EVERY seconds
    goals = "Reach Shattered Planet. Asterion full clean edge roundtrip home53825571."
    lines = {"astra": "Asterion probe launched53840310: legendary pair; all23 healthy", "sol": "Weaver9933actualAG/10coho"}
    s = {"board": {"plan": {"goals": goals, "doing": [{"name": n, "text": t} for n, t in lines.items()]}},
         "agents": [{"name": "astra", "display_name": "Astra"}, {"name": "sol", "display_name": "Sol"}],
         "space": {"platforms": [{"name": "Asterion"}, {"name": "Weaver"}]}}
    w = FakeWriter(lambda user: json.dumps({"goals": "The team aims for the Shattered Planet after Asterion's clean "
                                                     "round trip to the edge.",
                                            "line:astra": "Astra has Asterion out on a probe. All 23 guns are fed."}))
    pp = hoststory.PlainPlan(w, os.path.join(d, "host-plain.json"))
    view = pp.view(s)["board"]["plan"]
    assert view["goals"] is None and view["doing"] == [], "no shorthand before its rewrite"
    sync = lambda f: f()  # noqa: E731
    assert pp.tick(s, now, run=sync) and len(w.prompts) == 1
    system, user = w.prompts[0]
    assert "add nothing, judge nothing, advise nothing" in system and "Space platforms (ships): Asterion, Weaver" in user
    assert "line:astra" in user and "goals" in user
    view = pp.view(s)["board"]["plan"]
    assert view["goals"].startswith("The team aims") and view["doing"] == [
        {"name": "astra", "text": "Astra has Asterion out on a probe. All 23 guns are fed."}], view
    assert pp.english[lines["sol"]] == "", "a line the rewrite left out is left out"
    s2 = {"board": {"plan": dict(s["board"]["plan"], goals="Reach Shattered Planet; new probe140.")}}
    assert not pp.tick(s2, now + 60, run=sync), "inside ten minutes"
    assert pp.tick(s2, now + hoststory.PLAIN_EVERY, run=sync) and len(w.prompts) == 2
    assert json.loads(w.prompts[1][1].split("\n")[-1]) == {"goals": "Reach Shattered Planet; new probe140."}
    assert not pp.tick(s2, now + 3 * hoststory.PLAIN_EVERY, run=sync), "nothing new: no call"
    # kept in the run folder
    again = hoststory.PlainPlan(w, os.path.join(d, "host-plain.json"))
    assert again.view(s)["board"]["plan"]["goals"].startswith("The team aims")
    # no writer (the template writer): the plan as it is, plan changes as they are
    assert hoststory.PlainPlan(None).view(s) is s
    assert hoststory.PlainPlan(None).admit({"kind": "plan", "changes": ["x"]}, now) == [{"kind": "plan", "changes": ["x"]}]
    # a failed call leaves the shorthand out
    bad = hoststory.PlainPlan(FakeWriter("not json"))
    bad.tick(s, now, run=sync)
    assert bad.view(s)["board"]["plan"]["goals"] is None and not bad.busy

    # a plan change waits for its rewrite, then airs in plain English; one never rewritten is dropped
    w3 = FakeWriter(json.dumps({"line:sol": "Sol runs the Weaver freighter to Gleba."}))
    p3 = hoststory.PlainPlan(w3)
    ev = {"kind": "plan", "changes": ["sol is now on: Weaver9933actualAG"], "raw": [("sol", "Weaver9933actualAG")],
          "agent": None, "t": now, "prio": 5}
    assert p3.admit(ev, now) == [] and p3.poll(now + 5) == []
    p3.tick({"board": {"plan": {"doing": [{"name": "sol", "text": "Weaver9933actualAG"}]}}}, now + 10, run=sync)
    out = p3.poll(now + 20)
    assert len(out) == 1 and out[0]["changes"] == ["sol is now on: Sol runs the Weaver freighter to Gleba."] \
        and out[0]["t"] == now + 20 and "raw" not in out[0] and "held" not in out[0], out
    assert p3.poll(now + 30) == []
    p4 = hoststory.PlainPlan(FakeWriter("{}"))
    assert p4.admit(dict(ev, raw=[("sol", "unread")]), now) == []
    assert p4.poll(now + hoststory.PLAIN_HOLD) == [] and p4.held == [], "dropped after PLAIN_HOLD"

    # caster.py: the Differ keeps the raw texts; the hosts' snapshot and memo hold the rewrite only
    dif = caster.Differ()
    dif.diff({"board": {"plan": {"goals": "a", "doing": []}}})
    e = [x for x in dif.diff({"board": {"plan": {"goals": "b1234", "doing": [{"name": "sol", "text": "x9"}]}}})
         if x["kind"] == "plan"][0]
    assert e["raw"] == [("goals", "b1234"), ("sol", "x9")] and e["changes"][0] == "new goals: b1234"
    c = caster.Caster.__new__(caster.Caster)
    c.lock, c.differ, c.events, c.chat_q = threading.Lock(), caster.Differ(), deque(maxlen=50), deque(maxlen=50)
    c.story, c.plain = hoststory.StoryMemo(None, moments_path=os.path.join(d, "none.json")), pp
    c.on_snapshot(s)
    assert c.snap["board"]["plan"]["goals"].startswith("The team aims"), c.snap["board"]["plan"]
    assert "53825571" not in json.dumps(c.story.memo) and c.story.memo["goals"].startswith("The team aims")
    assert c.story.memo["agents"][0].startswith("Astra: Astra has Asterion out on a probe")
    f = caster.facts_for({"kind": "lull", "angle": "explain", "t": now, "prio": 1}, c.snap)
    assert "53840310" not in json.dumps(f) and "Weaver9933" not in json.dumps(f), f.get("team_plan")
    a = caster.parser().parse_args(["--writer", "or", "--model", "anthropic/claude-opus-5.5", "--low-model",
                                    "anthropic/claude-haiku-5.5"])
    c.a = a
    pw = c.plain_writer()
    assert pw.model == "anthropic/claude-haiku-5.5" and pw.reasoning == {"enabled": False}
    c.a = caster.parser().parse_args(["--writer", "template"])
    assert c.plain_writer() is None
    print("hoststory: ok (run block from an editable file; plain plan: one call per ten minutes, no shorthand, no "
          "ticks, plan changes wait, kept; caster wiring)")


if __name__ == "__main__":
    gate_tests()
    memo_tests()
    caster_tests()
    arrival_tests()
    analyst_tests()
    plain_tests()
