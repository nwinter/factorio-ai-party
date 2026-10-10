"""Synthetic 7-agent session for developing the overlay without a game.

Agents wander between work sites doing role-flavoured actions, think between actions, chat, and occasionally get
attacked or die. Research and production replay the real co-op 1 score timeline
(runs/2026-10-10-coop1/scores.jsonl) at `speed` x, starting `start_min` game minutes in.
"""
import bisect, json, math, os, random, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCORES = os.path.join(ROOT, "runs", "2026-10-10-coop1", "scores.jsonl")

# What the agents "chose" with `profile`. Deliberately awkward picks (near-white, near-black, long name, emoji)
# so the page's contrast fallback and truncation get exercised.
PROFILES = {
    "astra": {"display_name": "Astra", "color": "#7c5cff", "glyph": "✦", "motto": "Ratios first."},
    "opus": {"display_name": "Opus", "color": "#e8743b", "glyph": "♪", "motto": "Power is a promise."},
    "sonnet": {"display_name": "Sonnet", "color": "#f4f4f0", "glyph": "S", "motto": "Fourteen belts, one rhyme."},
    "haiku": {"display_name": "Haiku", "color": "#2fbf71", "glyph": "🌸", "motto": "ore falls, plates rise"},
    "sol": {"display_name": "Sol", "color": "#ffd400", "glyph": "☀", "motto": "Keep the labs lit."},
    "luna": {"display_name": "Luna", "color": "#14141c", "glyph": "🌙", "motto": "Night shift."},
    "grok": {"display_name": "Grok the Unyielding Builder", "color": "#00c8e0", "glyph": "Gk", "motto": ""},
    "gemini": {"display_name": "Gemini", "color": "#5aa9ff", "glyph": "♊", "motto": "Two belts are better than one."},
    "muse": {"display_name": "Muse", "color": "#ff8fb1", "glyph": "Mu", "motto": "Every blueprint a sketch."},
    # extras for the 12-agent density test (tools/stream/runs/mock12.json)
    "nova": {"display_name": "Nova", "color": "#3ddc97", "glyph": "N", "motto": ""},
    "kite": {"display_name": "Kite", "color": "#ff6b3d", "glyph": "🪁", "motto": ""},
    "echo": {"display_name": "echo", "color": "#9aa0a6", "glyph": "e", "motto": ""},
}

SITES = {
    "iron smelting": (-62, -18), "copper smelting": (-60, 34), "power plant": (44, -64), "oil field": (176, -138),
    "science labs": (-12, -52), "mall": (22, 12), "defense line": (-150, 118), "iron ore": (-112, -44),
    "coal field": (64, -18), "stone": (30, 70), "spawn": (0, 0),
}

ROLES = {
    "astra": ["iron smelting", "copper smelting", "science labs", "iron ore"],
    "opus": ["power plant", "oil field", "coal field"],
    "sonnet": ["mall", "iron smelting", "copper smelting", "spawn"],
    "haiku": ["iron ore", "coal field", "stone", "copper smelting"],
    "sol": ["science labs", "mall", "iron smelting"],
    "luna": ["defense line", "oil field", "spawn"],
    "grok": ["mall", "power plant", "science labs", "stone"],
    "gemini": ["copper smelting", "iron smelting", "mall", "spawn"],
    "muse": ["science labs", "oil field", "mall"],
    "nova": ["coal field", "power plant"],
    "kite": ["defense line", "iron ore"],
    "echo": ["stone", "spawn", "mall"],
}

ACTIONS = {
    "iron smelting": ["build:stone-furnace", "insert:coal", "take:iron-plate", "build_blueprint:smelter-column"],
    "copper smelting": ["build:steel-furnace", "insert:copper-ore", "take:copper-plate"],
    "power plant": ["build:steam-engine", "build:boiler", "construct:offshore-pump", "insert:coal"],
    "oil field": ["build:pumpjack", "build_blueprint:refinery-block", "construct:pipe-to-ground"],
    "science labs": ["build:lab", "insert:automation-science-pack", "build:assembling-machine-2", "craft:lab"],
    "mall": ["craft:transport-belt", "craft:inserter", "build:assembling-machine-1", "take:electronic-circuit"],
    "defense line": ["build:gun-turret", "insert:firearm-magazine", "build:stone-wall", "craft:firearm-magazine"],
    "iron ore": ["mine:iron-ore", "build:electric-mining-drill", "build:burner-mining-drill"],
    "coal field": ["mine:coal", "build:electric-mining-drill", "take:coal"],
    "stone": ["mine:stone", "craft:stone-furnace"],
    "spawn": ["craft:iron-gear-wheel", "rotate:splitter"],
}

LINES = {
    "astra": ["Iron column 3 is online, 30 furnaces. Copper next.", "Blue science is starving for engines; Grok can you bump the engine row?",
              "Labs at 19. Queueing construction robotics.", "Red/green ratio is 5:6 now, holding steady."],
    "opus": ["Boilers 7 and 8 up. We have headroom for the refinery.", "Oil: 4 pumpjacks tapped, sulfur flowing.",
             "Coal belt to the boilers is at 80%, adding a second lane.", "Heads up: I'm pausing the refinery to reroute water."],
    "sonnet": ["Main bus extended 40 tiles east. Six lanes.", "Who took my splitters? 😅", "Belt mall ready: yellow and red belts on tap.",
               "Underground belts placed under the rail line."],
    "haiku": ["Copper patch south-west: 8 drills down.", "Coal ok. Stone low.", "New iron field charted, 400k.", "Feeding the burner drills."],
    "sol": ["Research queue: robotics → construction robotics.", "Labs idle 10% — need more green.", "Inserted 200 blue packs.",
            "Construction robotics at 70%."],
    "luna": ["Biters probing the west wall again.", "Turret line west is 12 strong, ammo stocked.", "Pollution cloud reached the nest at -180,120.",
             "Swapping to piercing ammo when we have steel to spare."],
    "grok": ["Mall makes assemblers, belts, inserters, poles now.", "Building a 2nd engine row by the labs.",
             "Who wants a blueprint for 12 green circuit assemblers?", "Moving power poles out of the walkway, sorry Sonnet."],
    "gemini": ["Copper line doubled: two belts into the circuit block.", "Splitting the bus at x=40 for the green circuits.",
               "Balancer down, both lanes even now.", "Need 200 more belts, Grok?"],
    "muse": ["New blueprint: 6-refinery block with cracking.", "Sketched a compact lab ring for blue + purple.",
             "Placed the oil block ghost; filling it by hand for now.", "Blueprint string in notes if anyone wants the smelter."],
}


def load_timeline():
    rows = []
    try:
        for line in open(SCORES):
            s = json.loads(line)["score"]
            if rows and s["tick"] <= rows[-1]["tick"]:
                continue
            s["research_done"] = list(s.get("research_done") or [])
            rows.append(s)
    except FileNotFoundError:
        pass
    return rows


class MockSource:
    name = "mock"

    def __init__(self, run, speed=4.0, start_min=40.0, seed=7):
        self.rng = random.Random(seed)
        self.speed = speed
        self.rows = load_timeline()
        self.ticks = [r["tick"] for r in self.rows]
        self.order = []  # technologies in the order they finished
        for r in self.rows:
            self.order += [t for t in r["research_done"] if t not in self.order]
        self.next_flow = 0
        self.t0 = time.time()
        self.game0 = start_min * 60
        self.agents = {}
        names = list((run.get("agents") or {}).keys()) or list(PROFILES)
        for i, name in enumerate(names):
            home = ROLES.get(name, ["spawn"])[0]
            x, y = SITES[home]
            self.agents[name] = {
                "name": name, "kind": "bot", **PROFILES.get(name, {"display_name": name.capitalize(), "color": "#888888", "glyph": name[:1].upper()}),
                "pos": [x + self.rng.uniform(-8, 8), y + self.rng.uniform(-8, 8)], "site": home, "target": None,
                "active": False, "until": time.time() + self.rng.uniform(1, 6), "phase": "think",
                "alive": True, "dead_until": None, "combat_until": 0, "last": None, "last_said": None,
            }
        self.chat = []
        self.seq = 0
        self.next_chat = time.time() + 2
        self.next_attack = time.time() + 20
        self.next_power = time.time() + 50
        self.power_until = 0
        self.events = []
        self.profile_change_at = time.time() + 120

    # ---- timeline --------------------------------------------------------------------------------------------
    def game_seconds(self, now):
        return self.game0 + (now - self.t0) * self.speed

    def score_at(self, gsec):
        if not self.rows:
            return None, None
        tick = gsec * 60
        i = max(0, min(len(self.rows) - 1, bisect.bisect_right(self.ticks, tick) - 1))
        a = self.rows[i]
        b = self.rows[min(i + 1, len(self.rows) - 1)]
        f = 0 if b["tick"] == a["tick"] else max(0.0, min(1.0, (tick - a["tick"]) / (b["tick"] - a["tick"])))
        produced = {k: int(a["produced"].get(k, 0) + (b["produced"].get(k, 0) - a["produced"].get(k, 0)) * f)
                    for k in set(a["produced"]) | set(b["produced"])}
        cur = a.get("current_research")
        progress = None
        if cur:
            start = next((r["tick"] for r in self.rows if r.get("current_research") == cur), a["tick"])
            end = next((r["tick"] for r in self.rows if cur in r["research_done"]), None)
            if end and end > start:
                progress = max(0.0, min(0.99, (tick - start) / (end - start)))
            else:
                progress = 0.89
        research = {"current": cur, "progress": progress, "done": a["research_done"],
                    "top_done": [t for t in self.order if t in a["research_done"]][-4:][::-1]}
        return {"tick": int(tick), "produced": produced}, research

    # ---- agents ----------------------------------------------------------------------------------------------
    def step_agent(self, a, now, gsec):
        r = self.rng
        if not a["alive"]:
            if now >= a["dead_until"]:
                a["alive"], a["pos"], a["phase"], a["until"] = True, [r.uniform(-3, 3), r.uniform(-3, 3)], "think", now + 4
                a["site"] = "spawn"
            return
        if a["phase"] == "walk":
            tx, ty = SITES[a["target"]]
            dx, dy = tx - a["pos"][0], ty - a["pos"][1]
            d = math.hypot(dx, dy)
            step = 2.2 * self.speed * 0.5  # tiles per poll-ish second, slowed so the camera can keep up
            if d <= step:
                a["pos"] = [tx + r.uniform(-6, 6), ty + r.uniform(-6, 6)]
                a["site"] = a["target"]
                a["phase"], a["active"], a["until"] = "think", False, now + r.uniform(3, 12)
                a["last"] = {"kind": "walk", "outcome": "arrived", "tick": int(gsec * 60)}
            else:
                a["pos"] = [a["pos"][0] + dx / d * step, a["pos"][1] + dy / d * step]
            return
        if now < a["until"]:
            if a["phase"] == "act" and a["active"].startswith(("mine", "build", "construct")):
                a["pos"] = [a["pos"][0] + r.uniform(-0.6, 0.6), a["pos"][1] + r.uniform(-0.6, 0.6)]
            return
        if a["phase"] == "act":
            a["last"] = {"kind": a["active"].split(":")[0], "outcome": r.choice(["done", "done", "done", "partial"]),
                         "tick": int(gsec * 60)}
            a["phase"], a["active"], a["until"] = "think", False, now + r.uniform(4, 20)
            return
        # thinking finished: walk somewhere or act here
        sites = ROLES.get(a["name"], ["spawn"])
        if r.random() < 0.3:
            a["target"] = r.choice([s for s in sites if s != a["site"]] or sites)
            a["phase"], a["active"] = "walk", "walk"
        else:
            a["phase"], a["active"], a["until"] = "act", r.choice(ACTIONS[a["site"]]), now + r.uniform(6, 35)

    def say(self, a, text, gsec):
        self.seq += 1
        a["last_said"] = {"text": text, "tick": int(gsec * 60)}
        self.chat.append({"seq": self.seq, "tick": int(gsec * 60), "from": a["display_name"], "text": text})
        self.chat = self.chat[-50:]

    def observe(self):
        now = time.time()
        gsec = self.game_seconds(now)
        r = self.rng
        events = []
        for a in self.agents.values():
            self.step_agent(a, now, gsec)
        if now >= self.next_chat:
            a = r.choice([a for a in self.agents.values() if a["alive"]])
            self.say(a, r.choice(LINES.get(a["name"], ["Working on it."])), gsec)
            if r.random() < 0.35:  # a reply
                b = r.choice([b for b in self.agents.values() if b is not a and b["alive"]])
                self.next_chat = now + r.uniform(2, 4)
                self._reply = (b, f"@{a['display_name']} on it.")
            else:
                self.next_chat = now + r.uniform(5, 14)
        if getattr(self, "_reply", None) and now >= self.next_chat - 1:
            b, text = self._reply
            self._reply = None
            self.say(b, text, gsec)
        if now >= self.next_attack:
            victim = self.agents.get("luna") if r.random() < 0.6 and "luna" in self.agents else r.choice(list(self.agents.values()))
            if victim["alive"]:
                victim["combat_until"] = now + 12
                victim["active"], victim["phase"], victim["until"] = "shoot:small-biter", "act", now + 12
                if r.random() < 0.25:
                    victim["dead_pending"] = now + 8
            self.next_attack = now + r.uniform(60, 150)
        for a in self.agents.values():
            if a.get("dead_pending") and now >= a["dead_pending"]:
                a["dead_pending"] = None
                a["alive"], a["active"], a["phase"] = False, False, "dead"
                a["dead_until"] = now + 10
                a["combat_until"] = 0
        if now >= self.next_power:
            self.power_until = now + 25
            self.next_power = now + r.uniform(180, 300)
        if now >= self.profile_change_at:
            # an agent re-picks its colour mid-stream; the page should follow
            g = self.agents.get("grok")
            if g:
                g["color"] = "#ff3d7f" if g["color"] != "#ff3d7f" else "#00c8e0"
            self.profile_change_at = now + 240
        score, research = self.score_at(gsec)
        obs = {
            "tick": int(gsec * 60), "paused": False, "game_seconds": gsec,
            "agents": [{
                "name": a["name"], "kind": "bot", "display_name": a["display_name"], "color": a["color"],
                "glyph": a["glyph"], "motto": a.get("motto", ""), "position": {"x": round(a["pos"][0], 1), "y": round(a["pos"][1], 1)},
                "alive": a["alive"], "dead_until_tick": int((gsec + (a["dead_until"] - now) * self.speed) * 60) if not a["alive"] else None,
                "active": a["active"], "last": a["last"], "combat": now < a["combat_until"], "last_said": a["last_said"],
            } for a in self.agents.values()],
            "chat": self.chat[-20:],
            "power": {"machines": 330, "starved": 140 if now < self.power_until else 3},
            "events": events,
        }
        if score:
            obs["produced"] = score["produced"]
            obs["research"] = research
            if now >= self.next_flow:  # like the live source: last hour in 2-minute buckets
                self.next_flow = now + 20
                totals = [self.score_at(max(0, gsec - k * 120))[0]["produced"] for k in range(30, -1, -1)]
                obs["flows"] = {n: [max(0, totals[i + 1].get(n, 0) - totals[i].get(n, 0)) for i in range(30)]
                                for n in score["produced"]}
        return obs
