#!/usr/bin/env python3
"""What changed this hour (hourly.py, d25 batch197). Offline: python3 tools/stream/test_hourly.py

1. NP1 gather: one hour of a run folder (scores, chronicle with a first arrival and a repeat, digest, efficiency,
   the analyst's points with much the same text again, aloud lines, plan lines, a loss the hosts called) becomes
   rows with their sources; targets are our ships and chart spots inside a building box.
2. NP2 check: a piece whose numbers and names are all in its facts passes; each fault is named (words, a dash, an
   unknown target, a number or name the facts lack, a fact whose number or name is not in its row, he or she for an
   agent who did not choose it, "we", advice, a long caption).
3. write: a refused draft is written once more with the reason; refused twice, no piece.
4. NP3 airing (tour.py's fake service and clock): blocked() names what comes first (a fresh attack, loss or death, a
   battle, an enemy group, someone's look, follow, platform hold, host view, a tour overlay, a replay); a piece waits
   and airs when the way is clear, rendered only then, with the hosts hushed for it alone; one blocked for 10 minutes
   expires unrendered; with one camera a fresh attack ends it on air, with three it goes on; someone else's look ends
   it; a tour already running makes it wait; a render that fails drops it.
"""
import json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hourly  # noqa: E402
import tour  # noqa: E402
import test_tour  # noqa: E402

T1 = 1792926000.0  # the hour's end (a fixed epoch: no clock)
T0 = T1 - 3600


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(t))


def put(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def score(t, tick, rockets, done, inf, consumed, produced, plats):
    return {"t": iso(t), "score": {"tick": tick, "rockets": rockets, "research_done": done, "current_research": "plastic-bar-productivity",
                                   "current_packs": ["automation-science-pack", "chemical-science-pack"], "infinite": inf,
                                   "consumed": consumed, "produced": produced, "entities": {"lab": 20, "laser-turret": 800},
                                   "planets": ["nauvis", "gleba"], "platforms": plats}}


def fixture():
    run = tempfile.mkdtemp(prefix="hourly-run-")
    logs = tempfile.mkdtemp(prefix="hourly-logs-")
    plats = [{"name": "Weaver", "at": "gleba"}, {"name": "Asterion", "at": "in transit", "to": "aquilo"}]
    put(os.path.join(run, "scores.jsonl"), [
        score(T0 - 3600, 100000, 1000, ["a"], {"mining-productivity-3": 27}, {"automation-science-pack": 0, "chemical-science-pack": 0},
              {"automation-science-pack": 0, "chemical-science-pack": 0}, plats),
        score(T0, 316000, 1300, ["a"], {"mining-productivity-3": 27}, {"automation-science-pack": 6000, "chemical-science-pack": 6000},
              {"automation-science-pack": 6000, "chemical-science-pack": 5000}, plats),
        score(T1, 532000, 1500, ["a", "rocket-silo"], {"mining-productivity-3": 28},
              {"automation-science-pack": 9000, "chemical-science-pack": 9000},
              {"automation-science-pack": 9600, "chemical-science-pack": 8000},
              plats + [{"name": "Lark", "at": "nauvis"}])])
    put(os.path.join(run, "chronicle.jsonl"), [
        {"type": "event", "kind": "platform_arrived", "platform": "Weaver", "at": "gleba", "t": T0 - 100, "id": 1},
        {"type": "event", "kind": "platform_arrived", "platform": "Weaver", "at": "gleba", "t": T0 + 100, "id": 2, "game_time": "1h00m"},
        {"type": "event", "kind": "platform_arrived", "platform": "Weaver", "at": "nauvis", "t": T0 + 200, "id": 3, "game_time": "1h01m"},
        {"type": "event", "kind": "death", "agent": "sol", "planet": "gleba", "surface": "gleba", "by": "small-stomper-pentapod",
         "position": {"x": -62, "y": 101}, "t": T0 + 300, "id": 4, "game_time": "1h02m"},
        {"type": "event", "kind": "platform_created", "platform": "Lark", "at": "nauvis", "by": "astra", "t": T0 + 400, "id": 5,
         "game_time": "1h03m"},
        {"type": "event", "kind": "rocket", "surface": "nauvis", "cargo": "firearm-magazine*200", "t": T0 + 500, "id": 6},
        {"type": "event", "kind": "rocket", "surface": "nauvis", "cargo": "firearm-magazine*200", "t": T0 + 600, "id": 7},
        {"type": "event", "kind": "research", "name": "rocket-silo", "queued_by": "luna", "t": T0 + 700, "id": 8, "game_time": "1h05m"},
        {"type": "event", "kind": "death", "agent": "luna", "planet": "nauvis", "t": T1 + 10, "id": 9}])
    put(os.path.join(run, "factory-digest.jsonl"), [
        {"t": T0 + 900, "to": "sol", "seq": 7, "text": "Factory digest, changed since the last one (tick 1, 2 game min ago): "
                                                      "blockers: cleared: vulcanus: input shortage 46 assembling-machine."}])
    put(os.path.join(run, "efficiency.jsonl"), [
        {"t": T0 - 10, "team": {"machines": 100, "running": 40}, "agents": [{"name": "astra", "built_logged": 10, "items": 1000}]},
        {"t": T0 + 5, "team": {"machines": 100, "running": 50}, "agents": [{"name": "astra", "built_logged": 10, "items": 2000}]},
        {"t": T1 - 5, "team": {"machines": 110, "running": 60},
         "agents": [{"name": "astra", "built_logged": 13, "items": 9000, "machines": 33, "top_items": [{"item": "iron-plate"}]}]}])
    put(os.path.join(run, "chat.jsonl"), [
        {"seq": 1, "from": "grok", "aloud": True, "logged_at": iso(T0 + 60), "text": "First line."},
        {"seq": 2, "from": "grok", "aloud": True, "logged_at": iso(T0 + 120), "text": "Weaver took a fresh thousand."},
        {"seq": 3, "from": "grok", "aloud": True, "logged_at": iso(T0 + 180), "text": "Third line."},
        {"seq": 4, "from": "luna", "logged_at": iso(T0 + 200), "text": "Not aloud."}])
    json.dump({"lines": [{"agent": "sol", "text": "Refit installed.", "tick": 400000}, {"agent": "luna", "text": "Old.", "tick": 1}],
               "goals": "Reach the Shattered Planet.", "goals_tick": 450000}, open(os.path.join(run, "plan.json"), "w"))
    json.dump({"english": {"Refit installed.": "Sol has installed the refit."}}, open(os.path.join(run, "host-plain.json"), "w"))
    put(os.path.join(logs, "analyst-20261025-020740.jsonl"), [
        {"reply": {"t": T0 + 100, "headline": "Steady.", "talking_points": [
            {"topic": "spm-steady", "priority": 3, "text": "Science holds at 120 a minute across all colours."}]}},
        {"reply": {"t": T0 + 200, "talking_points": [
            {"topic": "spm-flat", "priority": 3, "text": "Science holds at 120 a minute across all the colours."},
            {"topic": "chem-gap", "priority": 2, "text": "Fourteen of 21 chemical assemblers are short of ingredients."}]}}])
    start = time.strftime("%Y%m%d-%H%M%S", time.localtime(T0 - 600))
    put(os.path.join(logs, f"caster-{start}.jsonl"), [
        {"type": "caster", "event": "loss", "exchange": T0 + 1000, "facts": {"text": "8 lost: 4 stone wall", "planet": "Nauvis"}},
        {"type": "caster", "event": "loss", "exchange": T0 + 1000, "line": "the second line of the same beat"},
        {"type": "caster", "event": "attack", "exchange": T0 - 50, "facts": {"text": "before the hour", "planet": "Nauvis"}}])
    out = os.path.join(run, "chart", "out")
    os.makedirs(os.path.join(out, "gleba"))
    json.dump({"surfaces": {"gleba": {"cells": {"0,0": [1, 2, 3, 4, 0, 0, 100, 100]}},
                            "nauvis": {"cells": {"0,0": [1, 2, 3, 4, 0, 0, 10, 10]}}}}, open(os.path.join(out, "index.json"), "w"))
    json.dump({"recipes": [[40, 30, "agricultural-science-pack"], [50, 40, "agricultural-science-pack"]]},
              open(os.path.join(out, "gleba", "0_0.labels.json"), "w"))
    os.makedirs(os.path.join(out, "nauvis"))
    json.dump({"recipes": [[400, 300, "automation-science-pack"]]}, open(os.path.join(out, "nauvis", "1_1.labels.json"), "w"))
    return run, logs


AGENTS = {"sol": {"display": "Sol", "pronouns": "they"}, "luna": {"display": "Luna", "pronouns": "she/her"},
          "grok": {"display": "Grok", "pronouns": "he/him"}, "astra": {"display": "Astra", "pronouns": "they"},
          "opus": {"display": "Opus", "pronouns": "he/him"}}


def gather_tests():
    run, logs = fixture()
    m = hourly.gather(run, T0, T1, logs, AGENTS)
    by = {}
    for r in m.rows:
        by.setdefault(r["kind"], []).append(r)
    txt = lambda k: [r["text"] for r in by.get(k, [])]
    assert txt("rockets") == ["200 rockets launched in these 60 minutes (300 in the hour before); 1,500 launched in the whole run"], txt("rockets")
    assert by["rockets"][0]["source"].endswith("scores.jsonl rows " + iso(T0)[11:19] + " and " + iso(T1)[11:19] + ", score.rockets")
    assert "research finished: rocket silo" in txt("research") and \
        "mining productivity 3 reached level 28 (was 27)" in txt("research"), txt("research")
    assert txt("science") == ["the labs used about 50 sets of science a minute this hour (about 100 the hour before), "
                              "researching plastic bar productivity; the tightest colour, chemical science pack: 50 made and 50 used a minute"], txt("science")
    assert txt("platform_new") == ["a new platform in the fleet: Lark"]
    assert txt("first_arrival") == ["Weaver reached nauvis for the first time in the run, at 1h01m"], "an arrival seen before the hour is no first"
    assert txt("death") == ["sol died on gleba at 1h02m, killed by small stomper pentapod"], "a death after the hour is not this hour's"
    assert txt("platform_created") == ["platform Lark was made at nauvis at 1h03m by astra"]
    assert txt("research")[0].startswith("research finished at 1h05m: rocket silo (queued by luna)") or \
        "research finished at 1h05m: rocket silo (queued by luna)" in txt("research")
    assert txt("rockets_by") == ["rockets this hour by planet: nauvis 2; the most sent cargo: firearm magazine (2 rockets)"]
    assert txt("traffic") == ["2 platform arrivals this hour; the busiest routes: "]
    assert txt("digest") == ["factory digest at " + hourly.hhmm(T0 + 900) + " (to sol): blockers: cleared: vulcanus: input "
                                                                         "shortage 46 assembling-machine."], txt("digest")
    assert txt("built") == ["astra built 3 machines this hour (33 theirs now)"], txt("built")
    assert txt("machines") == ["60 of 110 machines working at " + hourly.hhmm(T1 - 5)], "no comparison with a shift's first row"
    an = txt("analyst")
    assert len(an) == 2 and "spm-flat" in an[1] or "spm-flat" in an[0], "much the same point again: the latest only"
    assert not any("spm-steady" in a for a in an), an
    assert txt("analyst_headline") == ["the analyst's headline at " + hourly.hhmm(T0 + 100) + ": Steady."]
    assert txt("aloud") == ["grok said aloud at " + hourly.hhmm(T0 + 120) + ": Weaver took a fresh thousand.",
                            "grok said aloud at " + hourly.hhmm(T0 + 180) + ": Third line."], "the last two per agent, aloud only"
    assert txt("plan") == ["sol's plan line, set at 1h51m: Sol has installed the refit."], "in the hour's ticks, in plain English"
    assert by["plan"][0]["source"].endswith("plan.json lines, sol in plain English (" + run.lstrip("/") + "/host-plain.json)") or \
        "in plain English" in by["plan"][0]["source"], by["plan"][0]["source"]
    assert txt("goals") == ["the team's goals, set this hour: Reach the Shattered Planet."], "no rewrite: as written"
    assert txt("loss") == ["a loss at " + hourly.hhmm(T0 + 1000) + " on Nauvis: 8 lost: 4 stone wall"], "one per beat, in the hour"
    assert "attacks" not in by, "an attack before the hour"
    tg = {t["id"]: t for t in m.targets}
    assert [t["target"] for t in m.targets if "platform" in t["target"]] == [{"platform": n} for n in ("Weaver", "Asterion", "Lark")]
    spots = [t for t in m.targets if "surface" in t["target"]]
    assert {"surface": "gleba", "x": -62, "y": 101, "zoom": 0.6} in [t["target"] for t in spots], "the death's spot"
    assert {"surface": "gleba", "x": 45, "y": 35, "zoom": 0.5} in [t["target"] for t in spots], "a science spot in a box"
    assert not any(t["target"]["surface"] == "nauvis" for t in spots), "a spot outside every building box"
    asterion = next(t for t in m.targets if t["target"] == {"platform": "Asterion"})
    assert asterion["text"] == f"ship Asterion (in transit to aquilo at {hourly.hhmm(T1)})" and m.row(asterion["id"]) is asterion
    assert len({r["id"] for r in m.rows}) == len(m.rows) and all(r["source"] for r in m.rows)
    assert m.game_time == "2h27m"
    return m, tg


def piece(m, narration, facts, target=None, caption="Lark joins the fleet"):
    tid = target or next(t["id"] for t in m.targets if t["target"] == {"platform": "Lark"})
    return {"changes": [], "stops": [{"target": tid, "caption": caption, "narration": narration}], "facts": facts}


GOOD = ("Lark is the newest ship in the fleet, made at Nauvis by Astra this hour. It arrives as the silos keep their "
        "pace, about two hundred rockets in the hour, fewer than the three hundred before. Sol died on Gleba to a "
        "stomper, and Luna saw her own research finish: the rocket silo. Grok, for his part, watched Weaver take a "
        "fresh thousand, and the factory went on around them.")


def check_tests(m):
    rid = {r["kind"]: r["id"] for r in m.rows}
    lark = next(t for t in m.targets if t["target"] == {"platform": "Lark"})
    facts = [{"claim": "platform Lark was made at nauvis by astra", "source": rid["platform_created"]},
             {"claim": "200 rockets launched this hour, 300 in the hour before", "source": rid["rockets"]},
             {"claim": "sol died on gleba, killed by a small stomper pentapod", "source": rid["death"]},
             {"claim": "rocket silo research finished, queued by luna", "source": next(r["id"] for r in m.rows if "queued by luna" in r["text"])},
             {"claim": "grok: Weaver took a fresh thousand", "source": next(r["id"] for r in m.rows if "fresh thousand" in r["text"])},
             {"claim": "Lark is at nauvis", "source": lark["id"]}]
    m.agents = AGENTS
    assert len(GOOD.split()) in range(60, 111), len(GOOD.split())
    assert hourly.check(piece(m, GOOD, facts), m) is None, hourly.check(piece(m, GOOD, facts), m)
    bad = lambda text=GOOD, f=facts, **kw: hourly.check(piece(m, text, f, **kw), m)
    assert bad(" ".join(GOOD.split()[:50])) == "50 words (the piece is 60-110)"
    assert bad(GOOD.replace("this hour.", "this hour — quietly.")) == "a dash"
    assert bad(target="T99") == "target 'T99' is not in the camera targets"
    assert bad(caption="x" * 61) == "caption over 60 characters"
    assert bad(GOOD.replace("about two hundred", "about two hundred and fifty")) == "number not in the facts: about two hundred and fifty"
    assert bad(GOOD.replace("about two hundred", "about 230")) == "number not in the facts: about 230"
    assert bad(GOOD.replace("about two hundred", "over a hundred and fifty")) is None, "over 150 for 200 is honest"
    assert bad(GOOD.replace("about two hundred", "nearly two hundred and fifty")) == \
        "number not in the facts: nearly two hundred and fifty", "nearly 250 for 200 is not"
    assert bad(GOOD.replace("Sol died on Gleba", "Sol died on Vulcanus")) == "name not in the facts: Vulcanus"
    assert bad(GOOD.replace("Grok, for his part", "Opus, for his part")) == "name not in the facts: Opus"
    assert bad(GOOD.replace("Luna saw her own", "Sol saw her own").replace("Sol died on Gleba to a stomper, and", "and")) \
        == "pronoun 'her': no agent named here chose it"
    assert bad(GOOD.replace("Grok, for his part,", "Grok, for her part,")) is None, "she: Luna is named here"
    assert bad(GOOD.replace("the factory went on", "our factory went on")) == "speaks as part of the team ('we')"
    assert bad(GOOD.replace("the factory went on around them.", "the team should build more silos.")) == \
        "advice ('should'): the narrator observes"
    f2 = [dict(facts[1], claim="250 rockets launched this hour")] + facts
    assert bad(f=f2) == "fact 1: 250 is not in " + rid["rockets"]
    f3 = [dict(facts[0], claim="platform Lark was made at vulcanus by astra")] + facts[1:]
    assert bad(f=f3) == "fact 1: vulcanus is not in " + rid["platform_created"]
    assert bad(f=[dict(facts[0], source="Z9")]) == "fact 1 names no row ('Z9')"
    assert bad(f=[]) == "no facts list"
    assert hourly.check(None, m) == "the reply is not JSON"
    assert hourly.check({"stops": [], "facts": facts}, m) == "one or two stops"
    two = piece(m, GOOD, facts)
    two["stops"].append({"target": lark["id"], "caption": "c", "narration": "and more words here"})
    assert hourly.check(two, m) is None, "two stops count as one narration"
    return facts


class FakeWriter:
    def __init__(self, replies):
        self.replies, self.prompts, self.spent = list(replies), [], 0.0

    def complete(self, system, user, max_tokens=80):
        self.prompts.append(user)
        self.spent += 0.03
        return self.replies.pop(0)


def write_tests(m, facts):
    good = json.dumps(piece(m, GOOD, facts))
    bad = json.dumps(piece(m, GOOD.replace("Gleba", "Vulcanus"), facts))
    w = FakeWriter(["Here you go:\n```json\n" + bad + "\n```", "```" + good + "```"])
    p, attempts = hourly.write(m, w)
    assert p and [a["why"] for a in attempts] == ["name not in the facts: Vulcanus", None], attempts
    assert "Your last draft was refused: name not in the facts: Vulcanus." in w.prompts[1] and "refused" not in w.prompts[0]
    assert "- Sol (they)" in w.prompts[0] and "- Luna (she/her)" in w.prompts[0]
    assert attempts[0]["cost_usd"] == 0.03 and attempts[0]["draft"]["stops"]
    w = FakeWriter([bad, "not json at all"])
    p, attempts = hourly.write(m, w)
    assert p is None and [a["why"] for a in attempts] == ["name not in the facts: Vulcanus", "the reply is not JSON"]
    out = hourly.finish(json.loads(good), m, "shift73", T1 + 30, "model-x", [{"cost_usd": 0.03}])
    assert out["id"] == "hourly-shift73-" + time.strftime("%Y%m%d-%H%M", time.localtime(T1)) and out["words"] == len(GOOD.split())
    assert out["stops"][0]["target"] == {"platform": "Lark"} and out["stops"][0]["id"] == out["id"] + "-1"
    assert out["facts"][0]["row"] == "platform Lark was made at nauvis at 1h03m by astra" and out["facts"][0]["where"]
    assert out["cost_usd"] == 0.03
    w = FakeWriter([good])
    hourly.write(m, w, earlier=[out])
    assert "Earlier pieces (do not repeat them):\n- " + hourly.hhmm(T1) + ": Lark is the newest" in w.prompts[0]
    assert hourly.roster(state={"agents": [{"name": "muse", "display_name": "Muse Spark"}, {"name": "haiku", "display_name": "haiku",
                                                                                            "pronouns": "they"}]}) == \
        {"muse": {"display": "Muse Spark", "pronouns": "they/them"}, "haiku": {"display": "Haiku", "pronouns": "they"}}
    md = hourly.piece_md(dict(out, tts_usd=0.04))
    assert "> Lark is the newest" in md and "[" + out["facts"][0]["source"] + ": \"platform Lark" in md


class Svc(test_tour.FakeService):
    """tour.py's fake service with more of the snapshot: extra(now) -> fields (alerts, onair, look, ...)."""

    def __init__(self, clock, extra=None):
        super().__init__(clock, platforms=("Lark", "Weaver"))
        self.extra = extra or (lambda now: {})

    def state(self):
        st = super().state()
        st.update(self.extra(self.clock()))
        return st


def fake_render(calls, ok=True):
    def render(script, d):
        calls.append(time_of[0]())
        if not ok:
            return None
        clips = {}
        for s in json.load(open(script))["stops"]:
            text = " ".join(s["narration"].split())
            open(os.path.join(d, s["id"] + ".mp3"), "wb").write(b"ID3")
            clips[s["id"]] = {"file": s["id"] + ".mp3", "hash": tour.clip_hash("el-brian", text), "duration": 20.0,
                              "chars": len(text), "provider": "eleven"}
        return {"voice": "el-brian", "clips": clips}
    return render


time_of = [None]


def airing_tests(m, facts):
    now = 5000.0
    assert hourly.blocked({}, now) is None and hourly.blocked(None, now) is None
    fresh = {"kind": "attack", "t": now - 30, "text": "Base under attack: laser turret"}
    assert hourly.blocked({"alerts": [fresh]}, now) == "a fresh attack (Base under attack: laser turret)"
    assert hourly.blocked({"alerts": [dict(fresh, t=now - hourly.URGENT_S - 1)]}, now) is None, "an old attack"
    assert hourly.blocked({"alerts": [dict(fresh, kind="research")]}, now) is None
    assert hourly.blocked({"alerts": [dict(fresh, kind="death", text="sol died")]}, now) == "a fresh death (sol died)"
    assert hourly.blocked({"battle": {"key": "b"}}, now) == "a battle on air"
    assert hourly.blocked({"onair": {"attack": {"x": 1}}}, now) == "an attack on air"
    assert hourly.blocked({"onair": {"incoming": {"x": 1}}}, now) == "an enemy group followed on air"
    assert hourly.blocked({"look": {"by": "operator"}}, now) == "a look on air (by operator)"
    assert hourly.blocked({"follow": {"agent": "sol"}}, now) == "a follow on air"
    assert hourly.blocked({"platform_hold": {"name": "Lark", "by": "operator"}}, now) == "a platform hold on air (by operator)"
    assert hourly.blocked({"hostview": {"label": "Nick"}}, now) == "the host view on air"
    assert hourly.blocked({"tour": [{"id": "x"}]}, now) == "a tour overlay on air"
    assert hourly.blocked({"replay": {"playing": "c1"}}, now) == "a replay on air"
    assert hourly.blocked({"replay": {"playing": None, "enabled": True}, "look": None, "onair": {"agent": "sol"}}, now) is None

    good = json.loads(json.dumps(piece(m, GOOD, facts)))

    def setup(extra=None, cams=None, ok=True, run_file=None):
        d = tempfile.mkdtemp(prefix="hourly-air-")
        clock = test_tour.Clock()
        time_of[0] = clock
        svc = Svc(clock, extra)
        calls = []
        a = hourly.Airing(svc, d, cams, clock=clock, sleep=clock.sleep, renderer=fake_render(calls, ok),
                          hush_file=os.path.join(d, "hush.json"), stop_file=os.path.join(d, "stop"),
                          run_file=run_file or os.path.join(d, "tour-run.json"), log_dir=d)
        p = hourly.finish(good, m, "shift73", clock(), "model-x", [{"cost_usd": 0.03}])
        return a, svc, clock, calls, p, d

    hushes = []
    a, svc, clock, calls, p, d = setup(lambda now: hushes.append(os.path.exists(os.path.join(a.hush_file))) or {})
    res = a.air(p)
    assert res["event"] == "aired" and res["aired"] == 1 and res["skipped"] == 0 and res["ended_early"] is None, res
    assert calls == [1000.0] and res["waited_s"] == 0, "rendered once, at once"
    looks = [c for c in svc.calls if c[1:3] == ("POST", "/look")]
    assert len(looks) == 1 and looks[0][3]["platform"] == "Lark" and looks[0][3]["by"] == "tour"
    clips = [c for c in svc.clips]
    assert len(clips) == 1 and clips[0]["channel"] == "narrator" and clips[0]["tour"] == p["stops"][0]["id"]
    assert any(hushes) and not os.path.exists(a.hush_file), "hushed while it airs, unhushed after"
    assert not os.path.exists(a.run_file), "the run file only while it airs"
    assert res["tts_usd"] == round(len(" ".join(GOOD.split())) * 0.08 / 1000, 4) and res["seconds"] == 20.0
    rows = [json.loads(l) for l in open(os.path.join(d, f"tour-{p['id']}.jsonl"))]
    assert [r["event"] for r in rows] == ["start", "aired", "end"], rows

    # blocked for the first 100 s (a fresh loss), then clear: it waits, renders after, airs
    a, svc, clock, calls, p, d = setup(lambda now: {"alerts": [{"kind": "loss", "t": 1000.0, "text": "8 lost"}]}
                                       if now < 1100 else {})
    res = a.air(p)
    assert res["event"] == "aired" and res["waited_s"] == 105 and calls == [1105.0], (res, calls)

    # blocked for 10 minutes: expired, never rendered, nothing sent
    a, svc, clock, calls, p, d = setup(lambda now: {"look": {"by": "operator", "id": "op"}})
    res = a.air(p)
    assert res == {"event": "expired", "id": p["id"], "waited_s": 600, "why": "a look on air (by operator)",
                   "age_s": 600}, res
    assert calls == [] and not [c for c in svc.calls if c[2] in ("/look", "/audio")]

    # one camera: an attack a few seconds into the piece ends it
    def attack_at(t):
        return lambda now: {"alerts": [{"kind": "attack", "t": t, "text": "Base under attack"}]} if now >= t else {}
    a, svc, clock, calls, p, d = setup(attack_at(1010.0), cams=1)
    res = a.air(p)
    assert res["event"] == "aired" and res["ended_early"] == "a attack with one camera (Base under attack)", res
    assert svc.cancelled and svc.look_hold is None and not os.path.exists(a.hush_file), "narration back, look and hush cleared"
    end = [json.loads(l) for l in open(os.path.join(d, f"tour-{p['id']}.jsonl"))][-1]
    assert end["event"] == "end" and end["stopped"] and end["why"].startswith("a attack with one camera")
    # (d28 batch319 SU) the stop it cut short airs again once the attack is no longer fresh (URGENT_S), as the same
    # segment: the narration's clips say {id, part, parts}, and each run releases the page's hold at its end
    assert res["resumed"]["stops"] == 1 and res["resumed"]["aired"] == 1 and res["resumed"]["ended_early"] is None, res
    rs = [json.loads(l) for l in open(os.path.join(d, f"tour-{p['id']}-resume1.jsonl"))]
    assert rs[0]["event"] == "start" and rs[0]["t"] >= 1010.0 + 120, rs[0]
    segs = [c.get("segment") for c in svc.clips]
    assert len(segs) == 2 and all(sg == {"id": p["id"], "part": 1, "parts": 1} for sg in segs), segs
    releases = [c for c in svc.calls if c[1:3] == ("POST", "/audio/release")]
    assert len(releases) == 2 and releases[0][3] == {"segment": p["id"]}, releases
    # three cameras: the attack goes to the inset, the piece goes on
    a, svc, clock, calls, p, d = setup(attack_at(1010.0), cams=3)
    res = a.air(p)
    assert res["event"] == "aired" and res["ended_early"] is None and clock() > 1000 + 20, (res, clock())
    # the snapshot's cameras count when --cams is not given
    a, svc, clock, calls, p, d = setup(lambda now: dict(attack_at(1010.0)(now), cameras={"main": {}, "left": {}, "right": {}}))
    assert a.air(p)["ended_early"] is None
    # someone else's look ends it, whatever the cameras
    a, svc, clock, calls, p, d = setup(lambda now: {"look": {"by": "operator", "id": "op", "until": now + 30}} if now >= 1012 else {},
                                       cams=3)
    res = a.air(p)
    assert res["ended_early"] == "a look by operator took the camera", res
    # a tour already running (its run file, a live pid): the piece waits for it
    rf = os.path.join(tempfile.mkdtemp(), "tour-run.json")
    json.dump({"pid": os.getpid(), "script": "x.json"}, open(rf, "w"))
    a, svc, clock, calls, p, d = setup(run_file=rf)
    res = a.air(p)
    assert res["event"] == "expired" and res["why"] == f"a tour is running (pid {os.getpid()})" and calls == []
    # no voice rendered it
    a, svc, clock, calls, p, d = setup(ok=False)
    assert a.air(p) == {"event": "dropped", "id": p["id"], "why": "no narrator voice rendered it"}
    script = json.load(open(os.path.join(d, p["id"], "script.json")))
    assert [s["id"] for s in script["stops"]] == [p["stops"][0]["id"]] and script["facts"] == p["facts"]


def main():
    m, _ = gather_tests()
    facts = check_tests(m)
    write_tests(m, facts)
    airing_tests(m, facts)
    print("test_hourly: ok")


if __name__ == "__main__":
    main()
