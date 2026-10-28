#!/usr/bin/env python3
"""(d28 batch317 cp1) The disclosure inventory: every unit of the agents' kit and when it unlocks, per force.

    python3 tools/disclosure/build.py [DESCRIBE_JSON]     # writes tools/disclosure/manifest.json, prints the summary
    python3 tools/disclosure/build.py --check [DESCRIBE]  # exit 1 when the manifest is not what the rules make

Units: each action (describe.json), each argument (ARGS_OF, ARGS by name, else with its action), each entry of a
reference topic (a top-level item of agent/ref/TOPIC.md: with the actions it names, else its topic), each topic's
index line, each section of the brief (rules.BRIEF) and each alert or tip the harness gives (alerts.tsv). Conditions:
tools/disclosure/rules.py; the design: docs/DISCLOSURE.md.
"""
import glob, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import rules  # noqa: E402
import brief  # noqa: E402

MANIFEST = os.path.join(HERE, "manifest.json")
ALERTS = os.path.join(HERE, "alerts.json")

# Worlds and milestones the summary sizes the kit at. world n's settings: every world flag but humans.
WORLD_N = {"space_age", "quality", "enemies", "team", "stream"}
MILESTONES = [
    ("tick 0", set()),
    ("first hour: power, labs, a few drills and belts", {
        "built:steam-engine|solar-panel", "built:lab", "scale:drills:3", "scale:belts:40", "scale:machines:10",
        "habit:hand_belts:20", "habit:hand_poles:8", "habit:hand_feeds:20", "habit:chest_moves:5",
        "habit:refused:1", "habit:refused_builds:2", "habit:refused_builds:3", "habit:sleeps:20",
        "habit:repeat_calls:5", "scale:game_hours:1", "event:enemy_seen", "research:logistics",
        "research:radar", "research:fast-inserter"}),
    ("mid game: oil, robots, circuits, trains, defense", {
        "research:oil-processing", "built:pumpjack", "research:construction-robotics", "research:logistic-robotics",
        "built:roboport", "research:logistic-system", "research:circuit-network", "research:railway",
        "built:locomotive|straight-rail", "research:gun-turret", "built:gun-turret|laser-turret|flamethrower-turret",
        "scale:turrets:4", "scale:machines:20", "scale:machines:40", "scale:belts:100", "scale:inserters:10",
        "scale:inserters:20", "event:attacked", "event:loss", "event:starved", "event:low_power", "event:died",
        "event:spitters", "habit:walked:2000", "habit:sleeps:40", "habit:repeat_calls:10", "habit:board_items:20",
        "scale:game_hours:2", "scale:game_hours:4", "scale:shifts:2", "research:logistics-2", "research:modules",
        "research:automobilism", "built:car|tank|spidertron|locomotive", "research:modular-armor",
        "research:heavy-armor", "research:military-2", "built:boiler", "built:pipe-to-ground", "research:flamethrower",
        "research:personal-roboport-equipment"}),
    ("rocket and first platform", {
        "research:rocket-silo", "built:rocket-silo", "research:space-platform", "built:space-platform-hub",
        "event:second_surface", "event:freight", "event:asteroids", "event:hub_full", "research:cliff-explosives",
        "research:artillery", "research:nuclear-power", "research:elevated-rail", "research:quality-module",
        "research:spidertron"}),
    ("every planet", {
        "arrived:vulcanus", "arrived:fulgora", "arrived:gleba", "arrived:aquilo", "event:demolishers",
        "event:pentapods", "event:spoiled", "research:agriculture", "research:captive-biter-spawner",
        "research:heating-tower", "scale:platforms:2", "event:resource_depleted", "event:worms",
        "event:pollution_attack", "habit:lookups:1"}),
]


def describe_path(argv):
    if argv:
        return argv[0]
    found = sorted(glob.glob(os.path.join(ROOT, "runs", "*", "*", "describe.json")), key=os.path.getmtime)
    if not found:
        sys.exit("no describe.json: pass one (a runs/SHIFT/AGENT/describe.json)")
    return found[-1]


def cond(atoms):
    atoms = list(atoms)
    return {"world": sorted(a[6:] for a in atoms if a.startswith("world:")),
            "any": [a for a in atoms if not a.startswith("world:")]}


def ref_entries():
    """[(topic, n, lead, names, bytes)]: each top-level item of agent/ref/TOPIC.md."""
    actions = set(rules.ACTIONS)
    out = []
    for topic in brief.topics():
        text = open(os.path.join(brief.REF, topic + ".md")).read()
        items = re.split(r"\n(?=- )", "\n" + text)
        n = 0
        for item in items:
            item = item.strip("\n")
            if not item.startswith("- "):
                continue
            n += 1
            first = " ".join(item.split("\n", 2)[:2])
            lead = first.split(": ", 1)[0] if ": " in first else first[:80]
            names = []
            head = re.match(r"- `(?:\./fh (?:call )?)?([a-z_]+)", item)
            if head and head.group(1) in actions:
                names.append(head.group(1))
            for tok in re.findall(r"`([^`]+)`", lead):
                tok = tok.replace("./fh call ", "").replace("./fh ", "")
                w = re.split(r"[ {(\[]", tok.strip(), maxsplit=1)[0].replace(" ", "_")
                if w in actions and w not in names:
                    names.append(w)
            out.append((topic, n, " ".join(lead.split())[:100], names, len(item.encode()) + 1))
    return out


def alerts():
    """[(id, channel, trigger, atoms, source)]: alerts.json's kinds with their conditions (rules.ALERTS, else "self"
    gated by rules.ALERT_GATES on the kind's game feature)."""
    out = []
    for a in json.load(open(ALERTS)) if os.path.exists(ALERTS) else []:
        gate = rules.ALERT_GATES.get(a.get("game_feature"), [])
        atoms = next((list(x) for pat, x in rules.ALERTS if re.search(pat, a["id"])), None)
        atoms = atoms if atoms is not None else ["self"]
        if not any(x.startswith("world:") for x in atoms):
            atoms = gate + atoms
        out.append((a["id"], a["channel"], a["trigger"], atoms, a["source"]))
    return out


def units(describe):
    A = describe["actions"]
    us = []
    for name in sorted(A):
        size = len(json.dumps(A[name], separators=(",", ":")).encode())
        us.append({"id": f"action:{name}", "kind": "action", "condition": cond(rules.ACTIONS.get(name, ["UNASSIGNED"])),
                   "bytes": size})
        own = rules.ARGS_OF.get(name, {})
        for arg, text in (A[name].get("args") or {}).items():
            if arg in rules.META_ARGS:
                continue
            atoms = own.get(arg) or rules.ARGS.get(arg)
            us.append({"id": f"arg:{name}.{arg}", "kind": "argument", "action": name,
                       "condition": cond(atoms) if atoms else cond([f"with:action:{name}"]),
                       "advanced": bool(atoms) and atoms != rules.T0,
                       "bytes": len(json.dumps({arg: text}, separators=(",", ":")).encode())})
    for topic, n, lead, names, size in ref_entries():
        atoms = next((list(a) for pat, a in rules.DOCS if re.search(pat, lead)), None)
        atoms = atoms or [f"with:action:{a}" for a in names] or rules.TOPICS[topic]
        us.append({"id": f"doc:{topic}#{n}", "kind": "doc", "topic": topic, "lead": lead,
                   "condition": cond(atoms), "bytes": size})
    for topic in brief.topics():
        us.append({"id": f"index:{topic}", "kind": "index", "condition": cond([f"with:topic:{topic}"]), "bytes": 0})
    for f, n, text in brief_items():
        atoms = next((list(a) for ff, pat, a in rules.BRIEF_ITEMS if ff == f and re.search(pat, text)), rules.BRIEF[f])
        us.append({"id": f"brief:{f}#{n}", "kind": "brief", "lead": " ".join(text.split())[:100],
                   "condition": cond(atoms), "bytes": len(text.encode()) + 1})
    for aid, channel, trig, atoms, source in alerts():
        us.append({"id": f"alert:{aid}", "kind": "alert", "channel": channel, "trigger": trig, "source": source,
                   "condition": cond(atoms or ["start"]), "bytes": 0})
    return us


def brief_items():
    """[(file, n, text)]: each top-level bullet or paragraph of the brief's files (a heading goes with what follows)."""
    out = []
    for f in rules.BRIEF:
        path = os.path.join(brief.REF if f.startswith("ref/") else brief.AGENT, f.replace("ref/", ""))
        text = open(path).read()
        if f == "full-tools.md":
            text = text.split("<!-- harness -->")[0]
        parts = []
        for block in re.split(r"\n\s*\n", text):
            cut = r"\n" if f == "full-tools.md" and not block.lstrip().startswith(("- ", "#")) else r"\n(?=- |#)"
            for piece in re.split(cut, block):
                if piece.strip():
                    parts.append(piece.rstrip("\n") + "\n")
        out += [(f, n + 1, p) for n, p in enumerate(p for p in parts if p.strip())]
    return out


def atoms_ok(atoms, have, world):
    return any(a == "start" or a in have for a in atoms)


def unlocked(us, have, world):
    """The ids open with these atoms met in this world (with: resolved to a fixed point; an argument needs its action,
    a topic's index line any of its entries)."""
    by = {u["id"]: u for u in us}
    open_ = set()
    for _ in range(6):
        before = len(open_)
        for u in us:
            c = u["condition"]
            if u["id"] in open_ or not set(c["world"]) <= world or "never" in c["any"]:
                continue
            ok = not c["any"]
            for a in c["any"]:
                if a == "start" or a in have or (a == "self" and "self" in have):
                    ok = True
                elif a.startswith("habit:") or a.startswith("scale:"):
                    # a met threshold also meets any lower one of the same kind
                    k, _, n = a.rpartition(":")
                    ok = any(h.rpartition(":")[0] == k and int(h.rpartition(":")[2]) >= int(n) for h in have
                             if h.count(":") == 2 and h.rpartition(":")[2].isdigit())
                elif a.startswith("with:topic:"):
                    t = a[11:]
                    ok = any(i.startswith(f"doc:{t}#") for i in open_)
                elif a.startswith("with:"):
                    ref = a[5:]
                    ref = ref if ":" in ref else f"action:{ref}"
                    ok = ref in open_
                if ok:
                    break
            if ok and u["kind"] == "argument" and f"action:{u['action']}" not in open_:
                ok = False
            if ok:
                open_.add(u["id"])
        if len(open_) == before:
            break
    return open_


def core_bytes(open_, us):
    """(today's assembled core for claude, the core with only open items): brief.sample less the closed items of
    PLAYBOOK.md, team.md, compact.md, full-tools.md and harness-claude.md, and the index cut to open commands."""
    full = len(brief.sample("claude").encode())
    closed = sum(u["bytes"] for u in us if u["kind"] == "brief" and u["id"] not in open_
                 and not u["id"].startswith(("brief:spaceage.md", "brief:coop.md", "brief:ref/index.md")))
    keep = {i.split(":", 1)[1] for i in open_ if i.startswith("action:")}
    lines = []
    for topic, scope, cmds in brief.index():
        names = [c for c in cmds if c.replace("./", "").replace(" NAME", "").replace(" ", "_") in keep]
        if topic and names:
            lines.append(f"- `{topic}`, {scope}: " + ", ".join(f"`{c}`" for c in names) + ".")
    idx = brief.index_text()
    small = idx.split("\n- ", 1)[0].rstrip("\n") + "\n\n" + "\n".join(lines) + "\n"
    return full, full - closed - (len(idx.encode()) - len(small.encode()))

def summary(us, describe):
    from collections import Counter
    kinds = Counter(u["kind"] for u in us)
    print("units:", dict(kinds), "total", len(us))
    atoms = Counter()
    for u in us:
        for a in u["condition"]["any"] + ["world:" + w for w in u["condition"]["world"]]:
            k = a.split(":")[0]
            atoms[k if k != "with" else "with"] += 1
    print("atoms by kind:", dict(atoms))
    missing = [u["id"] for u in us if "UNASSIGNED" in u["condition"]["any"]]
    print("unassigned:", missing)
    have = set()
    world = WORLD_N
    rows = []
    for label, add in MILESTONES:
        have |= add
        o = unlocked(us, have, world)
        acts = sorted(i[7:] for i in o if i.startswith("action:"))
        A = describe["actions"]
        dbytes = sum(u["bytes"] for u in us if u["id"] in o and u["kind"] in ("action",))
        abytes = sum(u["bytes"] for u in us if u["id"] in o and u["kind"] == "argument")
        args = sum(1 for u in us if u["id"] in o and u["kind"] == "argument")
        refb = sum(u["bytes"] for u in us if u["id"] in o and u["kind"] == "doc")
        docs = sum(1 for u in us if u["id"] in o and u["kind"] == "doc")
        full, core = core_bytes(o, us)
        desc = sum(u["bytes"] for u in us if u["id"] in o and u["kind"] == "argument") + 24 * len(acts)
        alerts_open = sum(1 for u in us if u["id"] in o and u["kind"] == "alert")
        rows.append((label, len(acts), args, docs, refb, core, full, desc, alerts_open))
        if label == "tick 0":
            print("tick 0 actions:", " ".join(acts))
    totals = (sum(1 for u in us if u["kind"] == "action" and "never" not in u["condition"]["any"]),
              sum(1 for u in us if u["kind"] == "argument"), sum(1 for u in us if u["kind"] == "doc"),
              sum(u["bytes"] for u in us if u["kind"] == "doc"))
    desc_all = sum(u["bytes"] for u in us if u["kind"] == "argument") + 24 * totals[0]
    print("milestone | actions | arguments | describe bytes | doc entries | doc bytes | core bytes (today's) | alerts "
          "open before their own trigger")
    for r in rows:
        print(f"{r[0]} | {r[1]} | {r[2]} | {r[7]} | {r[3]} | {r[4]} | {r[5]} ({r[6]}) | {r[8]}")
    print(f"all | {totals[0]} | {totals[1]} | {desc_all} | {totals[2]} | {totals[3]} | |")
    return rows


def manifest(us, src):
    return {"about": "d28 batch317 cp1: units of the agents' kit and their unlock conditions per force (design only; "
                     "docs/DISCLOSURE.md). condition: world flags all needed, then any one atom.",
            "describe": src[src.index("runs/"):] if "runs/" in src else os.path.basename(src),
            "vocabulary": {"world": rules.WORLD, "event": rules.EVENTS, "habit": rules.HABITS, "scale": rules.SCALES},
            "units": us}


def main(argv):
    check = argv[:1] == ["--check"]
    argv = argv[1:] if check else argv
    src = describe_path(argv)
    describe = json.load(open(src))
    us = units(describe)
    m = manifest(us, src)
    head = json.dumps({k: v for k, v in m.items() if k != "units"}, indent=1)[:-2]
    text = head + ',\n "units": [\n' + ",\n".join(json.dumps(u, separators=(",", ":")) for u in us) + "\n ]\n}\n"
    if check:
        old = json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else {}
        same = old.get("units") == json.loads(text)["units"]
        print("manifest current" if same else "manifest differs from the rules: run tools/disclosure/build.py")
        return 0 if same else 1
    open(MANIFEST, "w").write(text)
    summary(us, describe)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
