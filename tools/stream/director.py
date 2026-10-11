"""Camera director: picks what the main and secondary director clients look at.

Rules (docs/BOTS-API.md): main camera on the most interesting agent with a minimum dwell (~20 s); secondary
cameras on the next two; when another agent is within ~40 tiles of a camera's subject, frame both (midpoint,
zoomed out). Every decision is appended to a JSONL log so the weights can be tuned after a stream.
"""
import json, math, time

DEFAULTS = {
    "main_dwell": 20.0,      # seconds before the main camera may cut
    "side_dwell": 12.0,
    "max_dwell": 60.0,       # after this, cut to the best other agent if it is at least `rotate_ratio` as interesting
    "rotate_ratio": 0.5,
    "switch_margin": 1.6,    # a challenger must beat the current subject by this factor (+ switch_bias) to cut early
    "switch_bias": 2.0,
    "cut_spacing": 4.0,      # seconds between voluntary cuts on any camera, so cameras do not all cut at once
    "pair_distance": 40.0,   # tiles
    "solo_zoom": 0.7,
    "side_zoom": 0.6,
    "airtime_bonus": 0.015,  # interest per second since an agent was last on any camera (capped)
    "airtime_cap": 2.5,
    "onair_penalty": 0.8,    # main camera discounts agents a secondary camera already shows (fewer forced cuts)
    "reframe_tiles": 6.0,    # re-send a pair midpoint when it moved this far
    "reframe_every": 2.0,
    "attack_cut": True,      # cut the main camera to a fresh attack (agent in combat, base area hit) right away
    "attack_hold": 20.0,     # seconds the main camera stays on an attack
    "attack_spacing": 45.0,  # at most one attack cut this often
    "attack_fresh": 8.0,     # an alert older than this is no longer news
    "attack_zoom": 0.5,
    "attack_near": 50.0,     # follow an agent within this many tiles of a base attack instead of a fixed position
}


def dist(a, b):
    return math.hypot(a["x"] - b["x"], a["y"] - b["y"])


class Director:
    def __init__(self, slots, sender, log_path, **tuning):
        """slots: [{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}, ...] (first one is main)."""
        self.slots = slots
        self.sender = sender
        self.cfg = dict(DEFAULTS, **{k: v for k, v in tuning.items() if v is not None})
        self.log_path = log_path
        self.state = {s["slot"]: None for s in slots}  # slot -> current assignment dict
        self.last_on_air = {}
        self.started = time.time()
        self.last_cut = 0.0
        self.last_attack_cut = -1e9
        self.attacks_seen = set()

    # -- scoring ----------------------------------------------------------------------------------------------
    def scores(self, agents, now):
        out = {}
        for a in agents:
            if not a["alive"] or not a.get("position") or not a.get("seen", True):
                continue
            off_air = now - self.last_on_air.get(a["name"], self.started)
            bonus = min(self.cfg["airtime_cap"], off_air * self.cfg["airtime_bonus"])
            idle_penalty = 0.5 if a["activity"] == "idle" else 1.0
            out[a["name"]] = round((a["interest"] + bonus) * idle_penalty + (0.01 if a["activity"] == "acting" else 0), 3)
        return out

    def frame(self, subject, agents_by_name, taken, zoom, partner=None):
        """Single follow, or a pair framing when someone free is close to the subject. A current partner is kept
        until 1.25x the pair distance so framing does not flicker at the threshold."""
        s = agents_by_name[subject]
        best = None
        for name, a in agents_by_name.items():
            if name == subject or name in taken or not a["alive"] or not a.get("position"):
                continue
            d = dist(s["position"], a["position"])
            limit = self.cfg["pair_distance"] * (1.25 if name == partner else 1.0)
            if d <= limit and (best is None or (name == partner, -d) > (best[1] == partner, -best[0])):
                best = (d, name)
        if not best:
            return {"agents": [subject], "follow": subject, "zoom": zoom}
        d, other = best
        o = agents_by_name[other]
        mid = {"x": round((s["position"]["x"] + o["position"]["x"]) / 2, 1),
               "y": round((s["position"]["y"] + o["position"]["y"]) / 2, 1)}
        # ~60 tiles across at zoom 1 on a 1080p client: leave ~24 tiles of margin around the pair
        pz = max(0.3, min(zoom, 60.0 / (d + 24.0)))
        return {"agents": [subject, other], "position": mid, "zoom": round(pz, 2), "distance": round(d, 1)}

    # -- attacks ----------------------------------------------------------------------------------------------
    def attack_target(self, snapshot, by_name, scores, now):
        """A fresh attack alert -> (subject agent or None, position or None, alert), or None. Each alert is
        considered once; cuts are spaced by attack_spacing."""
        if not self.cfg["attack_cut"] or now - self.last_attack_cut < self.cfg["attack_spacing"]:
            return None
        for al in sorted(snapshot.get("alerts") or [], key=lambda a: -a["t"]):
            if al["kind"] not in ("attack", "loss") or al["id"] in self.attacks_seen:
                continue
            self.attacks_seen.add(al["id"])
            if now - al["t"] > self.cfg["attack_fresh"]:
                continue
            if al.get("agent") in scores:
                return al["agent"], None, al
            p = al.get("position")
            if not p:
                continue
            near = [(dist(a["position"], p), n) for n, a in by_name.items()
                    if n in scores and a.get("position") and dist(a["position"], p) <= self.cfg["attack_near"]]
            if near:
                return min(near)[1], None, al
            return None, {"x": round(p["x"], 1), "y": round(p["y"], 1)}, al
        return None

    # -- main loop --------------------------------------------------------------------------------------------
    def step(self, snapshot, now=None):
        now = now or time.time()
        agents = snapshot["agents"]
        by_name = {a["name"]: a for a in agents}
        scores = self.scores(agents, now)
        ranked = sorted(scores, key=lambda n: -scores[n])
        taken = set()
        released = []  # subjects a higher camera just cut away from: a lower camera that lost its subject takes one
        attack = self.attack_target(snapshot, by_name, scores, now) if self.slots else None
        main = self.slots[0]["slot"] if self.slots else None
        if attack:
            subject, position, al = attack
            cur = self.state.get(main)
            if subject and cur and cur["subject"] == subject:
                cur["since"] = now - self.cfg["main_dwell"] + self.cfg["attack_hold"]  # already there: just stay
                self.last_attack_cut = now
            elif subject:
                target = self.frame(subject, by_name, {subject}, self.cfg["attack_zoom"])
                if cur:
                    released.append(cur["subject"])
                self.apply(self.slots[0], dict(target, subject=subject, label=al["text"],
                                               since=now - self.cfg["main_dwell"] + self.cfg["attack_hold"]),
                           f"attack: {al['text']}", scores, now)
                self.last_attack_cut = now
            else:
                if cur and cur["subject"] in by_name:
                    released.append(cur["subject"])
                self.apply(self.slots[0], {"agents": [], "subject": "@attack", "position": position,
                                           "zoom": self.cfg["attack_zoom"], "label": al["text"], "since": now,
                                           "until": now + self.cfg["attack_hold"]},
                           f"attack: {al['text']}", scores, now)
                self.last_attack_cut = now
        for i, slot in enumerate(self.slots):
            name = slot["slot"]
            cur = self.state.get(name)
            if cur and cur["subject"] == "@attack":
                if now < cur["until"]:
                    continue  # holding on a base attack nobody is near
                cur = None
            elif attack and i == 0 and attack[0]:
                taken.update(cur["agents"])  # just cut to the attacked agent; secondaries take the rest
                for n in cur["agents"]:
                    self.last_on_air[n] = now
                continue
            dwell = self.cfg["main_dwell"] if i == 0 else self.cfg["side_dwell"]
            zoom = slot.get("zoom") or (self.cfg["solo_zoom"] if i == 0 else self.cfg["side_zoom"])
            slot_scores = scores
            if i == 0:
                shown = {t["subject"] for s2, t in self.state.items() if t and s2 != name}
                slot_scores = {n: v * (self.cfg["onair_penalty"] if n in shown else 1.0) for n, v in scores.items()}
            free = sorted((n for n in ranked if n not in taken), key=lambda n: -slot_scores[n])
            on_air = {t["subject"] for s2, t in self.state.items() if t and s2 != name}
            subject, reason = self.choose(cur, free, slot_scores, now, dwell, on_air, released)
            if subject is None:
                if cur is not None:
                    self.apply(slot, None, "no candidates", scores, now)
                continue
            # secondary cameras do not pair-frame agents that the main camera already shows
            partner = cur["agents"][1] if cur and cur["subject"] == subject and len(cur["agents"]) > 1 else None
            # do not pull another camera's subject into a pair while that camera is still within its dwell
            held = set()
            for j, other in enumerate(self.slots):
                t = self.state.get(other["slot"])
                if j != i and t and now - t["since"] < (self.cfg["main_dwell"] if j == 0 else self.cfg["side_dwell"]):
                    held.add(t["subject"])
            target = self.frame(subject, by_name, taken | held | {subject}, zoom, partner)
            taken.update(target["agents"])
            if cur is None or cur["subject"] != subject:
                if cur is not None:
                    released.append(cur["subject"])
                self.apply(slot, dict(target, subject=subject, since=now), reason, scores, now)
            elif cur["agents"] != target["agents"]:
                self.apply(slot, dict(target, subject=subject, since=cur["since"]),
                           "pair" if len(target["agents"]) > 1 else "unpair", scores, now)
            elif "position" in target:
                moved = dist(cur["position"], target["position"])
                if moved >= self.cfg["reframe_tiles"] and now - cur.get("sent", 0) >= self.cfg["reframe_every"]:
                    self.apply(slot, dict(target, subject=subject, since=cur["since"]), "reframe", scores, now,
                               quiet=True)
            for n in self.state[name]["agents"] if self.state.get(name) else []:
                self.last_on_air[n] = now
        return self.public(now)

    def choose(self, cur, free, scores, now, dwell, on_air=(), released=()):
        if not free:
            return None, None
        best = free[0]
        if cur is None:
            return best, "initial"
        subj = cur["subject"]
        if subj not in scores:
            return best, f"{subj} unavailable"
        if subj not in free:
            swap = [n for n in released if n in free]
            if swap:
                return swap[0], f"{subj} moved up; swap to {swap[0]}"
            return best, f"{subj} taken by a higher camera"
        held = now - cur["since"]
        if held < dwell or best == subj or now - self.last_cut < self.cfg["cut_spacing"]:
            return subj, None
        others = [n for n in free if n != subj]
        if not others:
            return subj, None
        challenger = others[0]
        if scores[challenger] > scores[subj] * self.cfg["switch_margin"] + self.cfg["switch_bias"]:
            return challenger, f"{challenger} {scores[challenger]} beats {subj} {scores[subj]}"
        fresh = [n for n in others if n not in on_air]  # a rotation shows someone no camera is showing
        if held > self.cfg["max_dwell"] and fresh and scores[fresh[0]] >= scores[subj] * self.cfg["rotate_ratio"]:
            return fresh[0], f"rotate after {int(held)} s"
        return subj, None

    def apply(self, slot, target, reason, scores, now, quiet=False):
        name = slot["slot"]
        if target is None:
            body = {"player": slot["player"], "release": True}
        elif "position" in target:
            body = {"player": slot["player"], "position": target["position"], "zoom": target["zoom"], "smooth": True}
        else:
            body = {"player": slot["player"], "follow": target["follow"], "zoom": target["zoom"], "smooth": True}
        try:
            result = self.sender(body)
        except Exception as e:  # keep directing even if the harness call fails; the log shows it
            result = {"ok": False, "error": str(e)}
        if target is not None:
            target["sent"] = now
        if reason not in ("reframe", "pair", "unpair"):
            self.last_cut = now
        self.state[name] = target
        top = sorted(scores.items(), key=lambda kv: -kv[1])[:5]
        entry = {"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)), "slot": name,
                 "reason": reason, "target": target and {k: target[k] for k in ("agents", "zoom") if k in target},
                 "cmd": body, "result": result, "scores": dict(top)}
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(entry) + "\n")
        if not quiet:
            who = "+".join(target["agents"]) if target else "-"
            stub = " (stub)" if isinstance(result, dict) and result.get("stub") else ""
            print(f"[director] {entry['time']} {name}: {who} zoom {target and target['zoom']}  <- {reason}{stub}",
                  flush=True)

    def public(self, now=None):
        now = now or time.time()
        out = {}
        for slot in self.slots:
            t = self.state.get(slot["slot"])
            if t:
                out[slot["slot"]] = {"agents": t["agents"], "zoom": t["zoom"], "since": t["since"],
                                     "player": slot["player"], "pair": len(t["agents"]) > 1}
                if t.get("label") and now - t.get("sent", now) < self.cfg["attack_hold"]:
                    out[slot["slot"]]["attack"] = t["label"]
        return out
