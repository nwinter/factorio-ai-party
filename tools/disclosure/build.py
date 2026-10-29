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
LUA = os.path.join(ROOT, "vendor", "factorio-harness", "mod", "agent-harness_0.1.0", "disclosure_units.lua")
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
        "scale:inserters:20", "event:attacked", "event:loss", "event:low_power", "event:died",
        "event:spitters", "habit:walked:2000", "habit:sleeps:40", "habit:repeat_calls:10", "habit:board_items:20",
        "scale:game_hours:2", "scale:game_hours:4", "research:logistics-2", "research:modules",
        "research:automobilism", "built:car|tank|spidertron|locomotive", "research:modular-armor",
        "research:heavy-armor", "research:military-2", "built:boiler", "built:pipe-to-ground", "research:flamethrower",
        "research:personal-roboport-equipment"}),
    ("rocket and first platform", {
        "research:rocket-silo", "built:rocket-silo", "research:space-platform", "built:space-platform-hub",
        "event:second_surface", "event:freight", "event:asteroids", "research:cliff-explosives",
        "research:artillery", "research:nuclear-power", "research:elevated-rail", "research:quality-module",
        "research:spidertron"}),
    ("every planet", {
        "arrived:vulcanus", "arrived:fulgora", "arrived:gleba", "arrived:aquilo", "event:demolishers",
        "event:pentapods", "event:spoiled", "research:agriculture", "research:captive-biter-spawner",
        "research:heating-tower", "scale:platforms:2", "event:resource_depleted", "event:worms",
        "event:pollution_attack"}),
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


def item_key(text, seen):
    """An item's id within its file, from its own lead so an edit elsewhere keeps it: a split part's action and feature
    (build-fast-replace), the command it starts with (belt_route), else its first four words (game-rule-ghosts); a
    second item of the same lead gets -2, -3, ..."""
    flat = " ".join(text.split())
    # (cp4) a part split from a large entry, "- `ACTION`, FEATURE: ...": ACTION-FEATURE (build-fast-replace)
    part = re.match(r"- `([a-z][a-z_]*)`, ([a-z][a-z0-9 -]*?):", flat)
    m = re.match(r"(?:- )?`(?:\./fh (?:call )?)?([a-z][a-z_]*)", flat)
    base = (part.group(1) + "-" + "-".join(part.group(2).split())) if part else \
        m.group(1) if m else "-".join(re.findall(r"[a-z0-9]+", flat.lower())[:4]) or "item"
    key, k = base, 2
    while key in seen:
        key, k = f"{base}-{k}", k + 1
    seen.add(key)
    return key


def topic_items(topic):
    """[(key, text)]: each top-level item of agent/ref/TOPIC.md (ids topic#key, item_key)."""
    text = open(os.path.join(brief.REF, topic + ".md")).read()
    out, seen = [], set()
    for item in re.split(r"\n(?=- )", "\n" + text):
        item = item.strip("\n")
        if item.startswith("- "):
            out.append((item_key(item, seen), item + "\n"))
    return out


def ref_entries():
    """[(topic, n, lead, names, bytes)]: each top-level item of agent/ref/TOPIC.md."""
    actions = set(rules.ACTIONS)
    out = []
    for topic in brief.topics():
        for n, item in topic_items(topic):
            item = item.rstrip("\n")
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
    """[(file, key, text)]: each top-level bullet, paragraph or heading of the brief's files (ids file#key, item_key)."""
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
        seen = set()
        out += [(f, item_key(p, seen), p) for p in parts if p.strip()]
    return out


def expand(us):
    """{id: (gate, atoms)}: each unit's condition with its with: atoms replaced by what they refer to (the runtime's
    table, disclosure_units.lua, holds these; an argument also needs its action, checked apart)."""
    by = {u["id"]: u for u in us}
    docs_of = {}
    for u in us:
        if u["kind"] == "doc":
            docs_of.setdefault(u["topic"], []).append(u["id"])
    memo = {}

    def ref_ids(a):
        ref = a[5:]
        if ref.startswith("topic:"):
            return docs_of.get(ref[6:], [])
        return [ref if ":" in ref else f"action:{ref}"]

    def go(uid, depth=0):
        if uid in memo:
            return memo[uid]
        c = by[uid]["condition"]
        gate, atoms = set(c["world"]), []
        refs = [a for a in c["any"] if a.startswith("with:")]
        own = [a for a in c["any"] if not a.startswith("with:")]
        atoms += own
        gates = []
        for a in refs:
            for rid in ref_ids(a):
                if rid in by and depth < 8:
                    g, at = go(rid, depth + 1)
                    gates.append(g)
                    atoms += at if at else ["start"]
        if gates and not own:
            gate |= set.intersection(*gates)
        out = (gate, list(dict.fromkeys(atoms)))
        memo[uid] = out
        return out
    return {u["id"]: go(u["id"]) for u in us}


def met(atom, have):
    if atom == "start" or atom in have:
        return True
    if atom.startswith(("habit:", "scale:")):
        k, _, n = atom.rpartition(":")
        return any(h.rpartition(":")[0] == k and h.rpartition(":")[2].isdigit() and int(h.rpartition(":")[2]) >= int(n)
                   for h in have)
    return False


def unlocked(us, have, world):
    """The ids open with these atoms met in this world (the runtime's rule: world gate, then any atom; never stays
    shut; an argument needs its action)."""
    ex = expand(us)
    open_ = set()
    for u in us:
        gate, atoms = ex[u["id"]]
        if not gate <= world or "never" in atoms:
            continue
        if atoms and not any(met(a, have) for a in atoms):
            continue
        open_.add(u["id"])
    return {i for i in open_ if not (by_kind(i) == "arg" and "action:" + i[4:].split(".", 1)[0] not in open_)}


def by_kind(uid):
    return uid.split(":", 1)[0]


def what_of():
    """{action: what it does}: the first clause of the topic entry that starts with the action (for the unlock line)."""
    out = {}
    for topic in brief.topics():
        text = open(os.path.join(brief.REF, topic + ".md")).read()
        for item in re.split(r"\n(?=- )", "\n" + text):
            flat = " ".join(item.split())
            m = re.match(r"- `(?:\./fh (?:call )?)?([a-z_]+)[^`]*`(?: \([^)]*\))?(?: and `[^`]*`)?: (.+)", flat)
            if not m or m.group(1) in out:
                continue
            clause = re.split(r"(?<=[a-z0-9)`])\. |; | \(", m.group(2), maxsplit=1)[0].rstrip(".:")
            if len(clause) > 150:
                clause = clause[:150].rsplit(" ", 1)[0]
            if "`" in clause and clause.count("`") % 2:
                clause = clause.rsplit("`", 1)[0].rstrip(" ,(")
            if clause.startswith("`") or len(clause) < 12:
                continue
            out[m.group(1)] = clause
    return out


def lua_str(v):
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def lua_cond(gate, atoms):
    g = "{" + ",".join(lua_str(x) for x in sorted(gate)) + "}"
    a = "{" + ",".join(lua_str(x) for x in atoms) + "}"
    return f"g={g},a={a}"


def lua(us):
    """disclosure_units.lua: the runtime's table of conditions (expanded), with each action's topic and what it does."""
    ex = expand(us)
    topic_of = brief.commands()
    what = what_of()
    lines = ["-- Generated by tools/disclosure/build.py from tools/disclosure/rules.py (d28 batch317): do not edit.",
             "-- Each unit: g, the world flags it needs (all); a, the atoms that open it (any; none: open with its gate).",
             "return {", " actions={"]
    for u in us:
        if u["kind"] == "action":
            n = u["id"][7:]
            extra = (f",t={lua_str(topic_of[n])}" if topic_of.get(n, "core") != "core" else "") + \
                    (f",w={lua_str(what[n])}" if n in what else "")
            lines.append(f"  [{lua_str(n)}]={{{lua_cond(*ex[u['id']])}{extra}}},")
    lines.append(" },")
    lines.append(" args={")
    by_action = {}
    for u in us:
        if u["kind"] == "argument" and u["advanced"]:
            by_action.setdefault(u["action"], []).append(u)
    for a in sorted(by_action):
        inner = ",".join(f"[{lua_str(u['id'].split('.', 1)[1])}]={{{lua_cond(*ex[u['id']])}}}" for u in by_action[a])
        lines.append(f"  [{lua_str(a)}]={{{inner}}},")
    lines.append(" },")
    for kind, key in (("doc", "docs"), ("brief", "brief")):
        lines.append(f" {key}={{")
        for u in us:
            if u["kind"] == kind:
                lines.append(f"  [{lua_str(u['id'].split(':', 1)[1])}]={{{lua_cond(*ex[u['id']])}}},")
        lines.append(" },")
    lines.append("}")
    return "\n".join(lines) + "\n"


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
        same = old.get("units") == json.loads(text)["units"] and os.path.exists(LUA) and open(LUA).read() == lua(us)
        print("manifest current" if same else "manifest differs from the rules: run tools/disclosure/build.py")
        return 0 if same else 1
    open(MANIFEST, "w").write(text)
    open(LUA, "w").write(lua(us))
    summary(us, describe)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
