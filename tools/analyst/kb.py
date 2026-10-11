#!/usr/bin/env python3
"""Factorio knowledge lookups over the prototype dump (tools/analyst/kb/<version>/*.json). Stdlib only.

  python3 tools/analyst/kb.py search "green science"
  python3 tools/analyst/kb.py recipe electronic-circuit
  python3 tools/analyst/kb.py tech oil-processing
  python3 tools/analyst/kb.py path rocket-silo [--done automation,logistics,...]
  python3 tools/analyst/kb.py ratio logistic-science-pack 60 [--assembler assembling-machine-2 --furnace stone-furnace]
  python3 tools/analyst/kb.py entity electric-mining-drill
  python3 tools/analyst/kb.py compare '{"logistic-science-pack": 22}' logistic-science-pack 60
  python3 tools/analyst/kb.py research-time oil-processing --labs 10

Every answer comes from the game's own prototypes for the version dumped (default base-2.0.77), so numbers are exact
for that version. Ratio calculations assume no modules or beacons and machines at quality normal; productivity
research is ignored unless --mining-prod is given.
"""
import argparse, difflib, json, math, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_VERSION = os.environ.get("POG_KB", "base-2.0.77")

ALIASES = {
    "red science": "automation-science-pack", "red": "automation-science-pack",
    "green science": "logistic-science-pack", "green": "logistic-science-pack",
    "black science": "military-science-pack", "grey science": "military-science-pack",
    "gray science": "military-science-pack", "military science": "military-science-pack",
    "blue science": "chemical-science-pack", "blue": "chemical-science-pack",
    "purple science": "production-science-pack", "purple": "production-science-pack",
    "yellow science": "utility-science-pack", "yellow": "utility-science-pack",
    "white science": "space-science-pack", "space science": "space-science-pack",
    "green circuit": "electronic-circuit", "green circuits": "electronic-circuit", "circuit": "electronic-circuit",
    "red circuit": "advanced-circuit", "red circuits": "advanced-circuit",
    "blue circuit": "processing-unit", "blue circuits": "processing-unit",
    "gear": "iron-gear-wheel", "gears": "iron-gear-wheel", "plastic": "plastic-bar", "lds": "low-density-structure",
    "assembler": "assembling-machine-1", "drill": "electric-mining-drill", "miner": "electric-mining-drill",
    "furnace": "stone-furnace", "belt": "transport-belt", "yellow belt": "transport-belt", "red belt": "fast-transport-belt",
    "blue belt": "express-transport-belt", "oil": "oil-processing", "robots": "construction-robotics",
    "bots": "construction-robotics", "silo": "rocket-silo", "rocket": "rocket-silo", "steam engine": "steam-engine",
    "biter nest": "biter-spawner", "nest": "biter-spawner", "spawner": "biter-spawner", "turret": "gun-turret",
    "petroleum": "petroleum-gas", "pumpjack": "pumpjack", "refinery": "oil-refinery",
}
RAW = {"iron-ore", "copper-ore", "stone", "coal", "uranium-ore", "crude-oil", "water", "wood", "steam"}
# items with several recipes: the one a typical base uses
PREFERRED = {"petroleum-gas": "advanced-oil-processing", "heavy-oil": "advanced-oil-processing",
             "light-oil": "advanced-oil-processing", "solid-fuel": "solid-fuel-from-light-oil",
             "uranium-235": "uranium-processing", "uranium-238": "uranium-processing"}
DEFAULT_MACHINE = {"crafting": "assembling-machine-2", "advanced-crafting": "assembling-machine-2",
                   "crafting-with-fluid": "assembling-machine-2", "smelting": "stone-furnace",
                   "chemistry": "chemical-plant", "oil-processing": "oil-refinery", "centrifuging": "centrifuge",
                   "rocket-building": "rocket-silo"}


def pretty(n):
    return n.replace("-", " ") if isinstance(n, str) else n


def fmt(x, nd=2):
    if isinstance(x, float):
        if abs(x - round(x)) < 1e-9:
            return str(int(round(x)))
        return f"{x:.{nd}f}".rstrip("0").rstrip(".")
    return str(x)


class KB:
    def __init__(self, version=DEFAULT_VERSION):
        self.version = version
        d = os.path.join(HERE, "kb", version)

        def load(n):
            p = os.path.join(d, n + ".json")
            return json.load(open(p)) if os.path.exists(p) else []
        self.recipes = {r["name"]: r for r in load("recipes")}
        self.techs = {t["name"]: t for t in load("technologies")}
        self.items = {i["name"]: i for i in load("items")}
        self.entities = {e["name"]: e for e in load("entities")}
        self.fluids = {f["name"]: f for f in load("fluids")}
        s = os.path.join(d, "settings.json")
        self.settings = json.load(open(s)) if os.path.exists(s) else {}
        self.unlocked_by, self.leads_to, self.made_by = {}, {}, {}
        for t in self.techs.values():
            for e in t.get("effects") or []:
                if e.get("type") == "unlock-recipe":
                    self.unlocked_by.setdefault(e["recipe"], []).append(t["name"])
            for p in t.get("prerequisites") or []:
                self.leads_to.setdefault(p, []).append(t["name"])
        for r in self.recipes.values():
            if r.get("hidden"):
                continue
            for p in r.get("products") or []:
                self.made_by.setdefault(p["name"], []).append(r["name"])

    # ---- names ---------------------------------------------------------------------------------------------------
    def all_names(self):
        return set(self.recipes) | set(self.techs) | set(self.items) | set(self.entities) | set(self.fluids)

    def resolve(self, q):
        """Name or alias or close match -> prototype name (or None)."""
        if not q:
            return None
        k = q.strip().lower()
        if k in ALIASES:
            return ALIASES[k]
        n = k.replace(" ", "-")
        if n in self.all_names():
            return n
        m = difflib.get_close_matches(n, self.all_names(), n=1, cutoff=0.75)
        return m[0] if m else None

    def search(self, q, limit=15):
        k = q.strip().lower()
        out = []
        if k in ALIASES:
            out.append((ALIASES[k], "alias"))
        words = re.findall(r"[a-z0-9]+", k)
        for n in sorted(self.all_names()):
            if all(w in n for w in words):
                kinds = [c for c, src in (("recipe", self.recipes), ("tech", self.techs), ("item", self.items),
                                          ("entity", self.entities), ("fluid", self.fluids)) if n in src]
                out.append((n, "/".join(kinds)))
        if len(out) < 3:
            for n in difflib.get_close_matches(k.replace(" ", "-"), self.all_names(), n=5, cutoff=0.6):
                if n not in [o[0] for o in out]:
                    out.append((n, "close"))
        return out[:limit]

    # ---- recipes ---------------------------------------------------------------------------------------------------
    def recipe_for(self, item, prefer=None):
        if prefer and prefer in self.recipes:
            return self.recipes[prefer]
        if item in PREFERRED and PREFERRED[item] in self.recipes:
            return self.recipes[PREFERRED[item]]
        if item in self.recipes and not self.recipes[item].get("hidden"):
            return self.recipes[item]
        opts = [self.recipes[r] for r in self.made_by.get(item, []) if "recycling" not in r and not r.endswith("-barrel")
                and not r.startswith("empty-")]
        return min(opts, key=lambda r: len(r["products"])) if opts else None

    def recipe_text(self, name):
        r = self.recipes.get(name) or self.recipe_for(name)
        if not r:
            return f"no recipe named {name}"
        ing = ", ".join(f"{fmt(i['amount'])} {pretty(i['name'])}" for i in r["ingredients"]) or "nothing"
        prod = ", ".join(f"{fmt(p.get('amount') or ((p.get('amount_min', 0) + p.get('amount_max', 0)) / 2))} "
                         f"{pretty(p['name'])}" + (f" ({fmt(p['probability'] * 100)}%)" if p.get("probability") else "")
                         for p in r["products"])
        machines = self.machines_for(r["category"])
        unlock = self.unlocked_by.get(r["name"])
        lines = [f"recipe {r['name']}: {ing} -> {prod} in {fmt(r['energy'])} s (at crafting speed 1); category "
                 f"{r['category']}, made in {', '.join(machines) or 'hand only'}"
                 + ("; hand-craftable" if r["category"] == "crafting" else ""),
                 "available from the start" if r.get("enabled") else
                 f"unlocked by technology {', '.join(unlock)}" if unlock else "not unlocked by any technology"]
        others = [x for x in self.made_by.get(r["main_product"] or (r["products"][0]["name"] if r["products"] else ""), [])
                  if x != r["name"] and "recycling" not in x]
        if others:
            lines.append("other recipes making it: " + ", ".join(others))
        used = sorted({x["name"] for x in self.recipes.values() if not x.get("hidden") and "recycling" not in x["name"]
                       and any(i["name"] == (r["main_product"] or r["name"]) for i in x["ingredients"])})
        if used:
            lines.append(f"used in {len(used)} recipes: " + ", ".join(used[:14]) + (" ..." if len(used) > 14 else ""))
        return "\n".join(lines)

    def machines_for(self, category):
        return [e["name"] for e in self.entities.values() if category in (e.get("crafting_categories") or {})
                and e["type"] in ("assembling-machine", "furnace", "rocket-silo") and not e.get("hidden")]

    # ---- technologies ----------------------------------------------------------------------------------------------
    def tech_cost(self, t):
        """{pack: total}, total seconds at one lab of speed 1, trigger text (2.0 trigger techs cost no packs)."""
        if t.get("trigger"):
            return {}, 0, self.trigger_text(t["trigger"])
        n = t.get("unit_count") or 0
        packs = {i["name"]: i["amount"] * n for i in t.get("unit_ingredients") or []}
        return packs, n * (t.get("unit_time") or 0), None

    def trigger_text(self, tr):
        tr = {key: (v.get("name") if isinstance(v, dict) and "name" in v else v) for key, v in tr.items()}
        k = tr.get("type")
        if k == "craft-item":
            return f"craft {tr.get('count', 1)} {pretty(tr.get('item'))}"
        if k == "mine-entity":
            return f"mine {pretty(tr.get('entity'))}"
        if k == "build-entity":
            return f"build a {pretty(tr.get('entity'))}"
        if k == "craft-fluid":
            return f"produce {pretty(tr.get('fluid'))}"
        if k == "send-item-to-orbit":
            return f"launch {pretty(tr.get('item'))} into orbit"
        if k == "capture-spawner":
            return "capture a biter spawner"
        if k == "create-space-platform":
            return "create a space platform"
        return json.dumps(tr)

    def packs_text(self, packs):
        return ", ".join(f"{fmt(v)} {pretty(k).replace(' science pack', '')}" for k, v in packs.items()) or "none"

    def tech_text(self, name):
        t = self.techs.get(name)
        if not t:
            return f"no technology named {name}"
        packs, secs, trig = self.tech_cost(t)
        unlocks = [e["recipe"] for e in t.get("effects") or [] if e.get("type") == "unlock-recipe"]
        other = [e for e in t.get("effects") or [] if e.get("type") != "unlock-recipe"]
        cost = (f"research trigger: {trig} (no science packs)" if trig else
                f"cost {fmt(t.get('unit_count') or 0)} units x ({self.packs_text({i['name']: i['amount'] for i in t['unit_ingredients']})}) "
                f"= {self.packs_text(packs)}; {fmt(t.get('unit_time'))} s per unit, {fmt(secs / 60, 1)} lab-minutes at speed 1"
                + (f"; formula {t['unit_count_formula']}" if t.get("unit_count_formula") else ""))
        lines = [f"technology {name}: {cost}",
                 "prerequisites: " + (", ".join(t.get("prerequisites") or []) or "none"),
                 "unlocks recipes: " + (", ".join(unlocks) or "none")]
        if other:
            lines.append("other effects: " + "; ".join(
                f"{e['type']} {e.get('recipe') or e.get('ammo_category') or e.get('turret_id') or e.get('item') or ''} "
                f"{fmt(e['modifier']) if e.get('modifier') is not None else ''}".strip() for e in other[:8]))
        nxt = self.leads_to.get(name)
        if nxt:
            lines.append(f"leads to {len(nxt)}: " + ", ".join(sorted(nxt)[:16]) + (" ..." if len(nxt) > 16 else ""))
        if (t.get("max_level") or 1) > 1:
            lines.append(f"levels up to {t['max_level']}")
        lines.append("note: research progress is kept if the lab switches to something else; nothing is lost")
        return "\n".join(lines)

    def path(self, goal, done=()):
        """Technologies still needed for goal (prerequisites first) and their total cost."""
        done = set(done)
        order, seen = [], set()

        def visit(n):
            if n in seen or n in done or n not in self.techs:
                return
            seen.add(n)
            for p in self.techs[n].get("prerequisites") or []:
                visit(p)
            order.append(n)
        visit(goal)
        total, secs, triggers = {}, 0.0, []
        for n in order:
            packs, s, trig = self.tech_cost(self.techs[n])
            for k, v in packs.items():
                total[k] = total.get(k, 0) + v
            secs += s
            if trig:
                triggers.append((n, trig))
        return order, total, secs, triggers

    def path_text(self, goal, done=()):
        if goal not in self.techs:
            r = self.resolve(goal)
            if r in self.unlocked_by:
                goal = self.unlocked_by[r][0]
            elif r in self.techs:
                goal = r
            else:
                return f"no technology for {goal}"
        order, total, secs, triggers = self.path(goal, done)
        if not order:
            return f"{goal} is already researched"
        lines = [f"to research {goal}: {len(order)} technologies still needed" + (" (given what is done)" if done else " from a new game"),
                 "order: " + " > ".join(order),
                 f"total science packs: {self.packs_text(total)}",
                 f"lab time: {fmt(secs / 60, 1)} lab-minutes at speed 1 (e.g. {fmt(secs / 600, 1)} min with 10 labs, {fmt(secs / 1200, 1)} with 20)"]
        if triggers:
            lines.append("trigger technologies (done by an action, no packs): " + "; ".join(f"{n}: {t}" for n, t in triggers))
        return "\n".join(lines)

    def research_time_text(self, name, labs, lab_speed=1.0):
        t = self.techs.get(name)
        if not t:
            return f"no technology named {name}"
        packs, secs, trig = self.tech_cost(t)
        if trig:
            return f"{name} is a trigger technology: {trig}; it completes on that action, no lab time"
        wall = secs / (labs * lab_speed)
        per_min = {k: v / (wall / 60) for k, v in packs.items()} if wall else {}
        return (f"{name}: {fmt(secs)} lab-seconds; with {labs} labs at speed {fmt(lab_speed)}: {fmt(wall / 60, 1)} minutes, "
                f"if packs arrive at {self.packs_text({k: round(v, 1) for k, v in per_min.items()})} per minute")

    # ---- entities --------------------------------------------------------------------------------------------------
    def entity_text(self, name):
        e = self.entities.get(name)
        if not e:
            it = self.items.get(name)
            if it:
                return (f"item {name}: stack {it.get('stack_size')}" + (f", fuel {fmt(it['fuel_value'] / 1e6)} MJ" if it.get("fuel_value") else "")
                        + (f", places {it['place_result']}" if it.get("place_result") else "")
                        + (f", spoils in {fmt(it['spoil_ticks'] / 3600, 1)} min" if it.get("spoil_ticks") else ""))
            f = self.fluids.get(name)
            if f:
                return f"fluid {name}: " + json.dumps(f)
            return f"no entity named {name}"
        skip = {"name", "type", "hidden", "electric", "crafting_categories", "resource_categories"}
        parts = [f"{k}={json.dumps(v) if isinstance(v, (dict, list)) else fmt(v)}" for k, v in sorted(e.items()) if k not in skip]
        cats = list((e.get("crafting_categories") or {}).keys())
        if cats:
            parts.append("crafts=" + ",".join(cats))
        txt = f"{e['type']} {name}: " + "; ".join(parts)
        if e["type"] == "mining-drill" and e.get("mining_speed"):
            txt += f"\n= {fmt(e['mining_speed'] * 60)} ore per minute on iron/copper/coal/stone (mining time 1), before mining productivity"
        if e["type"] == "resource" and e.get("mining_time"):
            txt += f"\n= an electric mining drill (0.5/s) mines {fmt(30 / e['mining_time'])} per minute from it"
        it = self.items.get(name)
        if it:
            txt += f"\nitem stack size {it.get('stack_size')}"
        unlock = self.unlocked_by.get(name)
        if unlock:
            txt += f"\nrecipe unlocked by {', '.join(unlock)}"
        return txt

    # ---- ratios ----------------------------------------------------------------------------------------------------
    def machine_speed(self, name):
        e = self.entities.get(name) or {}
        return e.get("crafting_speed") or 1.0

    def ratio(self, item, per_min, assembler=None, furnace=None, chem=None, drill="electric-mining-drill",
              mining_prod=0.0, stop=()):
        """Build tree for per_min of item. Returns {item: {rate, recipe, machine, machines}} and raw {item: rate}."""
        need, raw = {}, {}
        stop = set(stop)

        def machine_for(cat):
            if cat == "smelting":
                return furnace or DEFAULT_MACHINE[cat]
            if cat in ("crafting", "advanced-crafting", "crafting-with-fluid"):
                m = assembler or DEFAULT_MACHINE[cat]
                if cat == "crafting-with-fluid" and m == "assembling-machine-1":
                    m = "assembling-machine-2"
                return m
            if cat == "chemistry" and chem:
                return chem
            return DEFAULT_MACHINE.get(cat) or (self.machines_for(cat) or ["?"])[0]

        def add(it, rate, depth=0):
            if depth > 30:
                return
            if it in RAW or it in stop:
                raw[it] = raw.get(it, 0) + rate
                return
            r = self.recipe_for(it)
            if not r:
                raw[it] = raw.get(it, 0) + rate
                return
            out_amt = sum((p.get("amount") or (p.get("amount_min", 0) + p.get("amount_max", 0)) / 2) * (p.get("probability") or 1)
                          for p in r["products"] if p["name"] == it)
            if not out_amt:
                raw[it] = raw.get(it, 0) + rate
                return
            crafts = rate / out_amt
            m = machine_for(r["category"])
            speed = self.machine_speed(m)
            n = need.setdefault(it, {"rate": 0.0, "recipe": r["name"], "machine": m, "machines": 0.0, "time": r["energy"],
                                     "per_craft": out_amt})
            n["rate"] += rate
            n["machines"] += crafts * r["energy"] / (speed * 60)
            for i in r["ingredients"]:
                add(i["name"], crafts * i["amount"], depth + 1)
        add(item, per_min)
        d = self.entities.get(drill) or {}
        drills = {}
        for ore, rate in raw.items():
            res = self.entities.get(ore)
            if res and res.get("type") == "resource" and not res.get("required_fluid") and d.get("mining_speed"):
                per = d["mining_speed"] / res["mining_time"] * 60 * (1 + mining_prod)
                drills[ore] = rate / per
        return need, raw, drills

    def ratio_text(self, item, per_min, **kw):
        it = self.resolve(item) or item
        need, raw, drills = self.ratio(it, per_min, **kw)
        if not need:
            return f"no recipe chain found for {item}"
        lines = [f"{fmt(per_min)} {pretty(it)} per minute needs (no modules or beacons):"]
        for name, n in sorted(need.items(), key=lambda kv: -kv[1]["machines"]):
            lines.append(f"- {pretty(name)}: {fmt(n['rate'], 1)}/min from {fmt(n['machines'], 2)} x {n['machine']} "
                         f"(recipe {n['recipe']}, {fmt(n['time'])} s per {fmt(n['per_craft'])}) -> build {math.ceil(n['machines'] - 1e-9)}")
        lines.append("raw: " + ", ".join(f"{fmt(v, 1)}/min {pretty(k)}" + (f" ({fmt(drills[k], 1)} {kw.get('drill', 'electric-mining-drill')}s)" if k in drills else "")
                                         for k, v in sorted(raw.items(), key=lambda kv: -kv[1])))
        belt = self.entities.get("transport-belt", {}).get("belt_speed_items_per_s")
        if belt:
            lines.append(f"(a yellow belt carries {fmt(belt * 60)} items/min, both lanes)")
        return "\n".join(lines)

    def compare_text(self, actual, item, target):
        it = self.resolve(item) or item
        have = actual.get(it, 0)
        need, raw, _ = self.ratio(it, target)
        need_now, _, _ = self.ratio(it, max(have, 0.001))
        lines = [f"{pretty(it)}: making {fmt(have, 1)}/min vs target {fmt(target)}/min ({fmt(100 * have / target if target else 0, 0)}%)"]
        short = []
        for name, n in need.items():
            got = actual.get(name)
            if got is None or name == it:
                continue
            if got < n["rate"] * 0.95:
                short.append((n["rate"] - got, f"{pretty(name)} {fmt(got, 1)}/min of {fmt(n['rate'], 1)} needed"))
        if short:
            lines.append("short of: " + "; ".join(s for _, s in sorted(short, reverse=True)[:6]))
        builds = [f"{math.ceil(n['machines'] - 1e-9)} {n['machine']} for {pretty(k)}" for k, n in list(need.items())[:6]]
        lines.append("the target needs " + ", ".join(builds))
        if have:
            lines.append(f"current output corresponds to about {fmt(need_now[it]['machines'], 1)} {need_now[it]['machine']} "
                         f"running full time on {pretty(it)}")
        return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", default=DEFAULT_VERSION)
    ap.add_argument("cmd", choices=["search", "recipe", "tech", "path", "ratio", "entity", "item", "compare",
                                    "research-time", "settings", "made-by"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--done", default="", help="comma-separated researched technologies (for path)")
    ap.add_argument("--assembler")
    ap.add_argument("--furnace")
    ap.add_argument("--drill", default="electric-mining-drill")
    ap.add_argument("--mining-prod", type=float, default=0.0)
    ap.add_argument("--labs", type=int, default=10)
    ap.add_argument("--lab-speed", type=float, default=1.0)
    a = ap.parse_args()
    kb = KB(a.version)
    q = " ".join(a.args)
    if a.cmd == "search":
        print("\n".join(f"{n} ({k})" for n, k in kb.search(q)) or "nothing found")
    elif a.cmd == "recipe":
        print(kb.recipe_text(kb.resolve(q) or q))
    elif a.cmd == "made-by":
        n = kb.resolve(q) or q
        print(f"{n} is made by: " + (", ".join(kb.made_by.get(n, [])) or "no recipe (raw or mined)"))
    elif a.cmd == "tech":
        n = kb.resolve(q) or q
        if n not in kb.techs and n in kb.unlocked_by:
            print(f"({n} is a recipe; it is unlocked by {', '.join(kb.unlocked_by[n])})")
            n = kb.unlocked_by[n][0]
        print(kb.tech_text(n))
    elif a.cmd == "path":
        print(kb.path_text(kb.resolve(q) or q, [d for d in a.done.split(",") if d]))
    elif a.cmd == "ratio":
        item, rate = " ".join(a.args[:-1]), float(a.args[-1])
        print(kb.ratio_text(item, rate, assembler=a.assembler, furnace=a.furnace, drill=a.drill, mining_prod=a.mining_prod))
    elif a.cmd in ("entity", "item"):
        print(kb.entity_text(kb.resolve(q) or q))
    elif a.cmd == "compare":
        actual = json.loads(a.args[0])
        print(kb.compare_text(actual, a.args[1], float(a.args[2])))
    elif a.cmd == "research-time":
        print(kb.research_time_text(kb.resolve(q) or q, a.labs, a.lab_speed))
    elif a.cmd == "settings":
        print(json.dumps(kb.settings, indent=1))


if __name__ == "__main__":
    main()
