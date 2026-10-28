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
"""
import glob, json, os, re, sys

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


if __name__ == "__main__":
    vocabulary()
    coverage()
    manifest()
    tick0()
    print("all passed")
