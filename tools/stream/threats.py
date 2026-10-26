"""How notable an attack is, against the run's own recent history (Nick, 13:45: "Shouldn't the attack group
size/threshold be dynamic based on the stage of the game, how often attacks are happening, etc.?").

No fixed thresholds. Each incoming group (harness attack_groups_live) and each fight that could be a key battle gets a
score from parts, weighted by director settings (`threat_weights`):

- size: a group's size against the last `history` groups (its percentile, squared: the 75th scores 0.56 of the
  weight); a fight's pieces lost against the last battles' (the same); scales from early game to evolution 0.56+;
- tier: a unit tier above the usual mix (75th percentile tier of recent groups and fights): first big biters,
  behemoths, a demolisher; double the first `tier_first` times a tier is seen;
- target: aimed near an agent, at an outpost (outside the base map's core), or from a new direction (no recent group
  within 35 degrees of its bearing from the base centre);
- for a fight, also an agent in it and how long it has gone on.

Calibrated to how attacks go now (d23 batch124 CG1, Nick 10:00: "slightly less interesting these days now that the
defenses are holding and there's a lot more standard biter attacks happening with no issue"; shift62-63: 176 groups in
6.3 h, 12 followed, every one stopped or turned back short of our buildings, 3 losses on Nauvis): each group seen is
tracked to its end (gone from the read for OUTCOME_GRACE s) with whether it reached contact and the pieces of ours
lost near it (a real loss, segments-style: not a few walls or belts) while it lived and OUTCOME_GRACE s after;
- routine: minus `routine` x (1 - the share of the last `outcomes` groups that destroyed something), once
  `outcomes_min` have ended: routine waves the defenses hold score low (today about -1.2), a run of damaging attacks
  lifts it back to 0;
- cover: where it is aimed (its target, else our nearest building to it), inside the base map's box: no turret of the
  map whose range reaches it adds `no_cover` (an outpost with no cover still cuts in). The map draws a cluster of
  turrets as one (turretsweep.merge), so it says none or some, not how many; outside its box it says nothing.
A fight that destroys something is scored as a battle (score_fight, unchanged): an attack doing damage still cuts in.

Then a budget (`threat_budget` per hour, the followed groups and battle holds together) is filled with the highest
scores: the bar is the score a candidate must reach so that, at the rate candidates have come in the last hour, about
the budget would pass; when they are rare the bar falls to `threat_floor`, when constant it rises; with the budget
spent in the last hour nothing passes. Spacing stays the director's. History (sizes, tiers, bearings, candidates,
taken) is kept in runs/RUN/threat-history.json so a restart keeps the run's scale; every score and decision goes to
the director log.
"""
import json, math, os, re, time

TIERS = [(re.compile(r"demolisher|segment", re.I), 5), (re.compile(r"behemoth", re.I), 4), (re.compile(r"\bbig", re.I), 3),
         (re.compile(r"medium", re.I), 2), (re.compile(r"small", re.I), 1)]
WEIGHTS = {"size": 2.0, "tier": 1.5, "agent": 1.0, "outpost": 0.7, "new_dir": 0.7, "pieces": 2.0, "duration": 0.5,
           "routine": 1.2, "no_cover": 1.0}
SETTINGS = {"budget": 4.0, "floor": 1.0, "history": 30, "tier_first": 3, "window": 3600.0, "outcomes": 20, "outcomes_min": 8}
OUTCOME_GRACE = 60.0   # s after a group leaves the read: its end, and the time a loss near it still counts
NEAR_LOSS = 60.0       # tiles from the group (or its target) within which a loss counts as its doing
COVER_MARGIN = 8.0     # tiles past a turret's range that still count as covered (biters attack from a few tiles off)


def tier_of(text):
    """"2 big-biter, 1 medium-spitter" or "(by small demolishers)" -> the highest tier named (0: none)."""
    best = 0
    for rx, n in TIERS:
        if rx.search(text or ""):
            best = max(best, n)
    return best


def percentile(values, v):
    """Share of values below v (ties count half); 0.5 without history."""
    if not values:
        return 0.5
    below = sum(1 for x in values if x < v) + 0.5 * sum(1 for x in values if x == v)
    return below / len(values)


def cover(g, turrets, box=None):
    """The drawn turrets [[x, y, range], ...] whose range (plus COVER_MARGIN) reaches where group g is aimed: its target,
    else our nearest building to it; None without turrets read, a place to aim at, or that place inside box."""
    if turrets is None or not box:
        return None
    at = g.get("target") or g.get("nearest")
    if not at or not (box["x0"] <= at["x"] <= box["x1"] and box["y0"] <= at["y"] <= box["y1"]):
        return None
    return sum(1 for t in turrets if math.hypot(t[0] - at["x"], t[1] - at["y"]) <= (t[2] if len(t) > 2 else 24) + COVER_MARGIN)


def bearing(frm, to):
    return math.degrees(math.atan2(to["y"] - frm["y"], to["x"] - frm["x"])) % 360


class Threats:
    def __init__(self, path=None, weights=None, log=None, **settings):
        self.path = path
        self.w = dict(WEIGHTS, **(weights or {}))
        self.cfg = dict(SETTINGS, **{k: v for k, v in settings.items() if v is not None})
        self.log = log or (lambda entry: None)
        self.h = {"sizes": [], "pieces": [], "tiers": [], "bearings": [], "tiers_seen": {}, "candidates": [], "taken": [],
                  "live": {}, "outcomes": []}
        if path:
            try:
                with open(path) as f:
                    self.h.update(json.load(f))
            except (OSError, ValueError):
                pass

    def save(self):
        if not self.path:
            return
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(self.h, f)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def usual_tier(self):
        t = sorted(self.h["tiers"][-self.cfg["history"]:])
        return t[int(0.75 * (len(t) - 1))] if t else 1

    def tier_part(self, tier):
        usual = self.usual_tier()
        if tier <= usual:
            return 0.0
        first = self.h["tiers_seen"].get(str(tier), 0) < self.cfg["tier_first"]
        return self.w["tier"] * (tier - usual) * (2.0 if first else 1.0)

    def target_parts(self, target, centre, agents, core):
        """Parts for where it is aimed: an agent within 40 tiles, an outpost (outside the core box), a new direction."""
        parts = {}
        if not target:
            return parts
        if any(a.get("position") and math.hypot(a["position"]["x"] - target["x"], a["position"]["y"] - target["y"]) <= 40
               for a in agents or []):
            parts["agent"] = self.w["agent"]
        if core and not (core["x0"] <= target["x"] <= core["x1"] and core["y0"] <= target["y"] <= core["y1"]):
            parts["outpost"] = self.w["outpost"]
        if centre:
            b = bearing(centre, target)
            recent = self.h["bearings"][-self.cfg["history"]:]
            if len(recent) >= 3 and all(min(abs(b - x), 360 - abs(b - x)) > 35 for x in recent):
                parts["new_dir"] = self.w["new_dir"]
        return parts

    def score_group(self, g, centre=None, agents=(), core=None, turrets=None, box=None):
        """An incoming group (attack_groups_live row) -> (score, parts). turrets: the base map's [[x, y, range], ...] on
        the group's surface, box its {x0, y0, x1, y1}; None when not known (no cover part)."""
        parts = {"size": round(self.w["size"] * percentile(self.h["sizes"][-self.cfg["history"]:], g.get("size") or 0) ** 2, 3)}
        tp = self.tier_part(tier_of(g.get("kinds")))
        if tp:
            parts["tier"] = tp
        parts.update(self.target_parts(g.get("target"), centre, agents, core))
        share = self.harm_share()
        if share is not None and share < 1:
            parts["routine"] = -round(self.w["routine"] * (1 - share), 3)
        if cover(g, turrets, box) == 0:
            parts["no_cover"] = self.w["no_cover"]
        return round(sum(parts.values()), 3), parts

    # -- how attacks go now (CG1) --------------------------------------------------------------------------------
    def observe(self, groups, losses, now):
        """groups: this read's rows [{id, surface, position, target?, contact}]; losses: [{key, surface, x, y, pieces, t}]
        (each real loss once by key). Tracks each group to its end; an ended one joins outcomes [t, contact, pieces]."""
        live = self.h.setdefault("live", {})
        for g in groups:
            k = str(g["id"])
            e = live.get(k) or {"first": now, "contact": False, "pieces": 0, "seen": []}
            e.update(last=now, surface=g.get("surface") or "nauvis", pos=[g["position"]["x"], g["position"]["y"]],
                     target=[g["target"]["x"], g["target"]["y"]] if g.get("target") else e.get("target"))
            e["contact"] = e["contact"] or bool(g.get("contact"))
            live[k] = e
        for l in losses:
            for e in live.values():
                if l["key"] in e["seen"] or (l.get("surface") or "nauvis") != e["surface"]:
                    continue
                if not (e["first"] <= l["t"] <= e["last"] + OUTCOME_GRACE):
                    continue
                spots = [e["pos"]] + ([e["target"]] if e.get("target") else [])
                if any(math.hypot(l["x"] - p[0], l["y"] - p[1]) <= NEAR_LOSS for p in spots):
                    e["pieces"] += l["pieces"]
                    e["seen"] = (e["seen"] + [l["key"]])[-20:]
        changed = False
        for k in [k for k, e in live.items() if now - e["last"] > OUTCOME_GRACE]:
            e = live.pop(k)
            self.h["outcomes"] = (self.h.get("outcomes", []) + [[round(e["last"], 1), int(e["contact"]), e["pieces"]]])[-200:]
            changed = True
        if changed:
            self.save()

    def harm_share(self):
        """The share of the last `outcomes` ended groups that destroyed something of ours; None under outcomes_min."""
        last = self.h.get("outcomes", [])[-self.cfg["outcomes"]:]
        if len(last) < self.cfg["outcomes_min"]:
            return None
        return sum(1 for o in last if o[2] > 0) / len(last)

    def score_fight(self, pieces, text, agent_in_it, duration_s, target=None, centre=None, agents=(), core=None):
        """A fight that could be a key battle -> (score, parts)."""
        parts = {}
        if pieces:
            parts["pieces"] = round(self.w["pieces"] * percentile(self.h["pieces"][-self.cfg["history"]:], pieces) ** 2, 3)
        tp = self.tier_part(tier_of(text))
        if tp:
            parts["tier"] = tp
        if agent_in_it:
            parts["agent"] = self.w["agent"]
        if duration_s > 0:
            parts["duration"] = round(self.w["duration"] * min(1.0, duration_s / 60.0), 3)
        tparts = self.target_parts(target, centre, (), core)
        tparts.pop("agent", None)
        parts.update(tparts)
        return round(sum(parts.values()), 3), parts

    def learn_group(self, g, centre=None):
        """A group seen (once): its size, tier and bearing join the history."""
        self.h["sizes"] = (self.h["sizes"] + [g.get("size") or 0])[-200:]
        t = tier_of(g.get("kinds"))
        if t:
            self.h["tiers"] = (self.h["tiers"] + [t])[-200:]
            self.h["tiers_seen"][str(t)] = self.h["tiers_seen"].get(str(t), 0) + 1
        if centre and g.get("target"):
            self.h["bearings"] = (self.h["bearings"] + [round(bearing(centre, g["target"]), 1)])[-200:]
        self.save()

    def learn_fight(self, pieces, text):
        """A fight over: its pieces lost and tier join the history."""
        if pieces:
            self.h["pieces"] = (self.h["pieces"] + [pieces])[-200:]
        t = tier_of(text)
        if t:
            self.h["tiers"] = (self.h["tiers"] + [t])[-200:]
            self.h["tiers_seen"][str(t)] = self.h["tiers_seen"].get(str(t), 0) + 1
        self.save()

    def bar(self, now):
        """The score a candidate needs now (module doc), and the numbers behind it."""
        win = self.cfg["window"]
        cands = [c for c in self.h["candidates"] if now - c[0] <= win]
        taken = [t for t in self.h["taken"] if now - t <= win]
        budget = self.cfg["budget"]
        if len(taken) >= budget:
            return float("inf"), {"candidates_h": len(cands), "taken_h": len(taken), "budget": budget}
        left = budget - len(taken)
        scores = sorted((c[1] for c in cands), reverse=True)
        bar = scores[int(left)] if len(scores) > left else 0.0  # the (left+1)-th best of the last hour
        return max(self.cfg["floor"], bar), {"candidates_h": len(cands), "taken_h": len(taken), "budget": budget}

    def decide(self, kind, key, score, parts, now, blocked=None, force=None, where=None):
        """A candidate's decision (logged): -> True to follow / hold it. blocked: the director's reason it cannot now
        (an urgent shot, spacing), still counted as a candidate. force: the director's reason to take it whatever the
        bar (batch245: every battle), logged with its score; it spends none of the budget. where: the candidate's place
        for the log (batch245: a group's position, target and size)."""
        bar, ctx = self.bar(now)
        take = blocked is None and (force is not None or score >= bar)
        why = blocked or (f"{force} (score {score}, bar {round(bar, 2)})" if force is not None else
                          f"score {score} >= bar {round(bar, 2)}" if take else f"score {score} < bar {round(bar, 2)}")
        self.h["candidates"] = [c for c in self.h["candidates"] if now - c[0] <= self.cfg["window"] * 2] + [[now, score]]
        if take and force is None:
            self.h["taken"] = [t for t in self.h["taken"] if now - t <= self.cfg["window"] * 2] + [now]
        self.save()
        self.log({"t": round(now, 1), "threat": kind, "key": key, "score": score, "parts": parts, "bar": None if bar == float("inf") else round(bar, 3),
                  **ctx, "decision": "take" if take else "skip", "why": why, **({"where": where} if where else {})})
        return take
