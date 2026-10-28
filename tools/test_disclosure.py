#!/usr/bin/env python3
"""The disclosure inventory (d28 batch317 cp1; tools/disclosure/): python3 tools/test_disclosure.py

1. Vocabulary: every condition in tools/disclosure/rules.py is made of known atoms (start, never, self, world:FLAG,
   research:TECH, built:ENTITY|..., arrived:PLANET, event:KIND, habit:KIND:N, scale:KIND:N, with:UNIT naming a unit
   that has a rule).
2. Coverage: every action of the newest runs/*/*/describe.json has a rule (a warning while the design is in review:
   a new action from another batch does not fail this test) and every rule names an action that exists there.
3. The manifest (tools/disclosure/manifest.json): unique ids, known atoms, every action of its describe in it.
4. The tick-0 set in world n's settings: walking, mining, crafting, building and looking are in; nothing that needs
   research, a building or an event is; the core then is smaller than today's.
5. The runtime's table (disclosure_units.lua) is what the manifest makes, and the runtime's evaluator (disclosure.lua,
   run by lua) opens the same tick-0 actions as build.py's.
6. The brief of a disclosure run (POG_DISCLOSURE_OPEN): the core without the shut items and index commands, topic files
   with the open entries only, and each topic's items with their ids for fh help (ref/.units/TOPIC.json).
"""
import glob, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "disclosure"))
sys.dont_write_bytecode = True
import rules  # noqa: E402
import build  # noqa: E402

PLANETS = {"nauvis", "vulcanus", "fulgora", "gleba", "aquilo"}


def atom_ok(a):
    if a in ("start", "never", "self"):
        return True
    kind, _, rest = a.partition(":")
    if kind == "world":
        return rest in rules.WORLD
    if kind == "event":
        return rest in rules.EVENTS
    if kind in ("habit", "scale"):
        name, _, n = rest.rpartition(":")
        return n.isdigit() and name in (rules.HABITS if kind == "habit" else rules.SCALES)
    if kind == "research":
        return re.fullmatch(r"[a-z0-9-]+", rest) is not None
    if kind == "built":
        return all(re.fullmatch(r"[a-z0-9-]+", e) for e in rest.split("|"))
    if kind == "arrived":
        return rest in PLANETS
    if kind == "with":
        ref = rest.split(":", 1)[1] if rest.startswith(("action:", "topic:")) else rest
        return ref in rules.ACTIONS or ref in rules.TOPICS or ref in ("lessons", "ground_rules")
    return False


def conditions():
    yield "ACTIONS", rules.ACTIONS.items()
    yield "ARGS", rules.ARGS.items()
    for action, args in rules.ARGS_OF.items():
        yield f"ARGS_OF[{action}]", args.items()
    yield "TOPICS", rules.TOPICS.items()
    yield "BRIEF", rules.BRIEF.items()
    yield "BRIEF_ITEMS", ((f"{f} {p}", a) for f, p, a in rules.BRIEF_ITEMS)
    yield "DOCS", rules.DOCS
    yield "ALERTS", rules.ALERTS
    yield "ALERT_GATES", rules.ALERT_GATES.items()


def vocabulary():
    bad = [(where, key, a) for where, items in conditions() for key, atoms in items for a in atoms if not atom_ok(a)]
    assert not bad, bad
    for action, args in rules.ARGS_OF.items():
        assert action in rules.ACTIONS, action
    print("vocabulary: ok")


def newest_describe():
    found = sorted(glob.glob(os.path.join(build.ROOT, "runs", "*", "*", "describe.json")), key=os.path.getmtime)
    return found[-1] if found else None


def coverage():
    path = newest_describe()
    if not path:
        print("coverage: skipped (no runs/*/*/describe.json)")
        return
    actions = set(json.load(open(path))["actions"])
    missing = sorted(actions - set(rules.ACTIONS))
    gone = sorted(set(rules.ACTIONS) - actions)
    if missing:
        print(f"warning: actions with no disclosure rule yet (tools/disclosure/rules.py ACTIONS): {missing}")
    if gone:
        print(f"warning: rules for actions {os.path.relpath(path, build.ROOT)} does not have: {gone}")
    print("coverage: ok")


def manifest():
    m = json.load(open(build.MANIFEST))
    ids = [u["id"] for u in m["units"]]
    assert len(ids) == len(set(ids)), [i for i in ids if ids.count(i) > 1][:5]
    bad = [(u["id"], a) for u in m["units"] for a in u["condition"]["any"] + ["world:" + w for w in u["condition"]["world"]]
           if not atom_ok(a)]
    assert not bad, bad[:10]
    kinds = {u["kind"] for u in m["units"]}
    assert kinds == {"action", "argument", "doc", "index", "brief", "alert"}, kinds
    assert all(k in m["vocabulary"] for k in ("world", "event", "habit", "scale"))
    print("manifest: ok", len(ids), "units")


def tick0():
    us = json.load(open(build.MANIFEST))["units"]
    open_ = build.unlocked(us, set(), build.WORLD_N)
    acts = {i[7:] for i in open_ if i.startswith("action:")}
    for a in ("walk", "move_to", "mine", "craft", "build", "inspect", "observe", "research", "say", "status"):
        assert a in acts, a
    late = {u["id"][7:] for u in us if u["kind"] == "action"
            and any(x.split(":")[0] in ("research", "built", "event", "arrived") for x in u["condition"]["any"])}
    assert not (acts & late), sorted(acts & late)
    for a in ("platform_create", "train", "circuit_set", "place_ghosts", "queue_submit", "wait_until"):
        assert a not in acts, a
    # an argument is never open before its action
    for u in us:
        if u["kind"] == "argument" and u["id"] in open_:
            assert f"action:{u['action']}" in open_, u["id"]
    full, core = build.core_bytes(open_, us)
    assert core < full, (core, full)
    # world gates: a base-game, peaceful, one-agent world has no team, stream or Space Age unit at tick 0
    solo = build.unlocked(us, set(), set())
    for a in ("tell", "board_post", "profile", "shoot"):
        assert f"action:{a}" not in solo, a
    assert not any(i.startswith("brief:team.md") for i in solo)
    print(f"tick 0: ok, {len(acts)} actions, core {core} of today's {full} bytes")


def tick0_open():
    us = json.load(open(build.MANIFEST))["units"]
    o = build.unlocked(us, set(), build.WORLD_N)
    return us, o, {"mode": "filter", "actions": sorted(i[7:] for i in o if i.startswith("action:")),
                   "docs": sorted(i[4:] for i in o if i.startswith("doc:")),
                   "brief": sorted(i[6:] for i in o if i.startswith("brief:"))}


def runtime_table():
    us, _, want = tick0_open()
    assert open(build.LUA).read() == build.lua(us), "disclosure_units.lua is not what the manifest makes: run build.py"
    if not shutil.which("lua"):
        print("runtime table: ok (lua not found: the evaluators not compared)")
        return
    harness = os.path.join(build.ROOT, "vendor", "factorio-harness")
    script = """
defines={events={}} prototypes={entity={}} script={active_mods={['space-age']='x',quality='x'}}
local nauvis={peaceful_mode=false,no_enemies_mode=false}
local force={name='player',valid=true,platforms={},technologies={},get_entity_count=function() return 0 end}
game={tick=0,forces={player=force},surfaces={},get_surface=function() return nauvis end}
storage={h={}}
local D=dofile('mod/agent-harness_0.1.0/disclosure.lua'){state=function() return storage.h end,
  units=dofile('mod/agent-harness_0.1.0/disclosure_units.lua'),forces=function() return {force} end,
  is_team=function() return true end,team_size=function() return 2 end,characters=function() return {} end}
D.operator.disclosure_set({mode='filter',world={stream=true}})
local r=D.read(force)
print(table.concat(r.actions,' ')) print(table.concat(r.docs,' ')) print(table.concat(r.brief,' '))
"""
    out = subprocess.run(["lua", "-e", script], cwd=harness, capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    acts, docs, brf = out.stdout.split("\n")[:3]
    assert acts.split() == want["actions"], set(acts.split()) ^ set(want["actions"])
    assert docs.split() == want["docs"], set(docs.split()) ^ set(want["docs"])
    assert brf.split() == want["brief"], set(brf.split()) ^ set(want["brief"])
    print(f"runtime table: ok, the Lua evaluator opens the same {len(want['actions'])} actions at tick 0")


def brief_filtered():
    sys.path.insert(0, os.path.join(build.ROOT, "tools"))
    import brief
    _, _, want = tick0_open()
    old = {k: os.environ.get(k) for k in ("POG_DISCLOSURE_OPEN", "POG_SPACE_AGE")}
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "open.json")
        json.dump(want, open(path, "w"))
        os.environ["POG_DISCLOSURE_OPEN"], os.environ["POG_SPACE_AGE"] = path, "1"
        try:
            full = brief.core("astra", "TIME", "")
            open_ = brief.disclosure_open()
            small = brief.core("astra", "TIME", "", open_=open_)
            assert "- Plans: `./fh queue submit" in full and "- Plans: `./fh queue submit" not in small
            assert "`belt_route`" in full and "`belt_route`" not in small and "`transfer`" in small
            assert "## Compact instructions" in small and "{{" not in small and len(small) < len(full)
            assert "Your team's tools grow with it" in small and "Your team's tools grow" not in full
            ws = os.path.join(d, "ws")
            os.makedirs(ws)
            brief.write(ws, "astra", "TIME", "", "", "", "")
            building = open(os.path.join(ws, "ref", "building.md")).read()
            assert "`build {" in building and "`belt_route {" not in building, building[:300]
            units = json.load(open(os.path.join(ws, "ref", ".units", "building.json")))
            ids = {i["id"]: i["text"] for i in units["items"]}
            assert any(t.startswith("- `belt_route") for t in ids.values()) and units["head"].startswith("# building")
            sa = json.load(open(os.path.join(ws, "ref", ".units", "space-age.json")))
            assert any(i["id"].startswith("spaceage.md#") for i in sa["items"])
            os.environ.pop("POG_DISCLOSURE_OPEN")
            assert brief.disclosure_open() is None and brief.core("astra", "TIME", "") == full
        finally:
            for k, v in old.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    print(f"brief: ok, core {len(small)} of {len(full)} bytes at tick 0")


if __name__ == "__main__":
    vocabulary()
    coverage()
    manifest()
    tick0()
    runtime_table()
    brief_filtered()
    print("all passed")
