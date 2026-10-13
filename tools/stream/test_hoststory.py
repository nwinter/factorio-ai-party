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


if __name__ == "__main__":
    gate_tests()
    memo_tests()
    caster_tests()
