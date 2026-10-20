"""Camera director: picks what the main and secondary director clients look at.

Rules (docs/BOTS-API.md): main camera on the most interesting agent with a minimum dwell (~20 s); secondary
cameras on the next two; when another agent is within ~40 tiles of a camera's subject, frame both (midpoint,
zoomed out). Zoom follows the subject's activity (close for fights and building, wide for walks that last), and
fights, base attacks and deaths cut the main camera straight away. Every decision is appended to a JSONL log so the weights can be tuned after a stream.
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
    "solo_zoom": 0.75,       # idle / thinking / unknown activity (Factorio zoom: 1 = normal play view, higher = closer)
    "side_zoom": 0.75,
    "zoom_fight": 1.05,      # zoom follows the subject's activity: close for fights and building, wide for walks
    "zoom_build": 0.95,
    "zoom_work": 0.85,       # mining, crafting, loading machines
    "zoom_walk": 0.5,
    "zoom_settle": 5.0,      # an activity must last this long before the zoom follows it (short walks stay close)
    "zoom_delta": 0.1,       # ignore smaller zoom changes
    "main_scale": 1.5,       # every zoom above is multiplied by this on the main camera when sent
    "side_scale": 2.6,       # and by this on the secondary cameras (small tiles need a closer view)
    "max_zoom": 3.0,         # cap on the zoom sent (cameras.lua MAX_ZOOM is 4)
    "side_pair_distance": 12.0,  # secondaries frame two agents only when this close (else follow one, close up)
    "airtime_bonus": 0.015,  # interest per second since an agent was last on any camera (capped)
    "airtime_cap": 2.5,
    "onair_penalty": 0.8,    # main camera discounts agents a secondary camera already shows (fewer forced cuts)
    "reframe_tiles": 6.0,    # re-send a pair midpoint when it moved this far
    "reframe_every": 2.0,
    "attack_cut": True,      # cut the main camera to a fresh attack (agent in combat, base area hit) right away
    "attack_hold": 20.0,     # seconds the main camera stays on an attack
    "attack_spacing": 45.0,  # at most one attack cut this often
    "attack_fresh": 8.0,     # an alert older than this is no longer news
    "attack_zoom": 1.05,     # following an agent in a fight
    "area_zoom": 0.8,        # a base area under attack whose size is unknown
    # A base attack or a loss is shown where it happens: a fixed view on its position and surface, zoomed so its
    # extent (a 32-tile chunk for an attack, the loss rectangle) fits, sent as is and without easing (the camera is
    # there at once, so the replay clip can start then). shake10: the camera followed an agent within 50 tiles
    # (attack_near) and the announced turret fight replayed as the factory.
    "fight_margin": 24.0,    # tiles around the fight's extent; ~60 tiles across at zoom 1
    "death_hold": 12.0,      # a death cuts to where the agent fell (ignores attack_spacing)
    "death_zoom": 1.1,
    # Work away from the body (model.work: remote platform builds, far ghosts/paste/deconstruction): the last
    # secondary camera cuts to where the work lands, labelled "Sol building on Solstice (from the ground)".
    "work_cut": True,
    "work_hold": 15.0,       # seconds on the work
    "work_spacing": 45.0,    # at most one work cut this often
    "work_fresh": 20.0,      # a work item older than this is no longer news
    "work_zoom": 0.9,        # a far ghost/paste/deconstruct position on the body's surface (scaled like other views)
}
HOLDS = ("@attack", "@segment", "@work", "@map", "@platform", "@look")  # fixed shots a camera keeps until their `until`
FIGHT = {"shoot", "attack", "kite"}
BUILD = {"build", "place", "construct", "blueprint", "build_blueprint", "build_path", "rotate", "repair", "deconstruct"}
WORK = {"mine", "craft", "insert", "take", "feed", "gather", "research", "fuel"}
WALK = {"walk", "path", "move_to", "follow"}


def dist(a, b):
    return math.hypot(a["x"] - b["x"], a["y"] - b["y"])


RIDING = ("ascending", "descending")  # a bot in a cargo pod (harness travel state)


def surface_of(agent):
    """The planet or platform surface an agent is on (profiles `surface`); the base game has only nauvis."""
    return agent.get("surface") or "nauvis"


CLIENT = (1920, 1080)  # a camera client's screen; Factorio draws 32 px a tile at zoom 1 (60 x 33.75 tiles)


def frame_of(target, frac=1.0):
    """What a client shows, from its shot: {"position" | "follow", "zoom" (as sent to the game), "frac", "surface"},
    or None before a shot was sent. frac: share of the client's width the program shows (the on-air crop)."""
    if not target or not target.get("game_zoom") or target.get("map"):
        return None  # (a map camera shows the chart, not the world: no footage of anything for replays.py)
    fr = {"zoom": target["game_zoom"], "frac": frac}
    if "position" in target:
        p = target["position"]
        fr.update(position={"x": p["x"], "y": p["y"]}, surface=target.get("surface") or p.get("surface") or "nauvis")
    elif target.get("follow"):
        fr["follow"] = target["follow"]
    else:
        return None
    return fr


def in_frame(fr, point, by_name, edge=2.0):
    """Is this map point (x, y, surface) inside the frame, at least `edge` tiles from its border? A followed agent's
    position comes from by_name (name -> agent). shift01: the replay judged 'shown' a loss 20 tiles from the agent on
    air, and the on-air view was 28 x 24 tiles; the clip was Sol in the base."""
    if not fr or not point:
        return False
    if "position" in fr:
        c, surf = fr["position"], fr.get("surface") or "nauvis"
    else:
        a = by_name.get(fr.get("follow")) or {}
        c, surf = a.get("position"), surface_of(a)
    if not c or surf != (point.get("surface") or "nauvis"):
        return False
    tile = 32.0 * fr["zoom"]
    hw = CLIENT[0] / tile / 2 * (fr.get("frac") or 1.0) - edge
    hh = CLIENT[1] / tile / 2 - edge
    return abs(point["x"] - c["x"]) <= hw and abs(point["y"] - c["y"]) <= hh


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
        self.last_attack_alert = None
        self.last_attack_framed = None
        self.attacks_seen = set()
        self.want = {}  # slot -> (zoom the subject's activity asks for, since)
        self.work_seen = set()
        self.last_work_cut = -1e9

    # -- scoring ----------------------------------------------------------------------------------------------
    def scores(self, agents, now):
        out = {}
        for a in agents:
            if not a["alive"] or not a.get("position") or not a.get("seen", True):
                continue
            if a.get("activity") == "resting":  # between turns, pacing its quota (pacing.py): its character stands
                continue
            off_air = now - self.last_on_air.get(a["name"], self.started)
            bonus = min(self.cfg["airtime_cap"], off_air * self.cfg["airtime_bonus"])
            idle_penalty = 0.5 if a["activity"] == "idle" else 1.0
            out[a["name"]] = round((a["interest"] + bonus) * idle_penalty + (0.01 if a["activity"] == "acting" else 0), 3)
        return out

    def zoom_for(self, a, base=None):
        """Zoom for what an agent is doing now: fights and building close, walks wide."""
        kind = str(a.get("active") or "").split(":")[0]
        if a.get("combat") or kind in FIGHT:
            return self.cfg["zoom_fight"]
        if kind in BUILD:
            return self.cfg["zoom_build"]
        if kind in WORK:
            return self.cfg["zoom_work"]
        if kind in WALK:
            return self.cfg["zoom_walk"]
        if a.get("activity") == "thinking" and not kind:
            return None  # between actions: keep whatever the last action asked for
        return base or self.cfg["solo_zoom"]

    def frame(self, subject, agents_by_name, taken, zoom, partner=None, pair_distance=None):
        """Single follow, or a pair framing when someone free is close to the subject. A current partner is kept
        until 1.25x the pair distance so framing does not flicker at the threshold."""
        s = agents_by_name[subject]
        best = None
        for name, a in agents_by_name.items():
            if name == subject or name in taken or not a["alive"] or not a.get("position"):
                continue
            if surface_of(a) != surface_of(s) or a.get("travel") in RIDING or s.get("travel") in RIDING:
                continue  # Space Age: only agents standing on the same planet or platform share a frame
            d = dist(s["position"], a["position"])
            limit = (pair_distance or self.cfg["pair_distance"]) * (1.25 if name == partner else 1.0)
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
        return {"agents": [subject, other], "position": mid, "surface": surface_of(s), "zoom": round(pz, 2),
                "distance": round(d, 1)}

    # -- attacks ----------------------------------------------------------------------------------------------
    def attack_target(self, snapshot, by_name, scores, now):
        """A fresh attack alert -> (subject agent or None, position or None, alert), or None. Each alert is
        considered once; cuts are spaced by attack_spacing."""
        if not self.cfg["attack_cut"]:
            return None
        spaced = now - self.last_attack_cut >= self.cfg["attack_spacing"]
        for al in sorted(snapshot.get("alerts") or [], key=lambda a: -a["t"]):
            if al["kind"] not in ("attack", "loss", "death") or al["id"] in self.attacks_seen:
                continue
            if al["kind"] != "death" and not spaced:
                continue  # may still be news once the spacing has passed
            self.attacks_seen.add(al["id"])
            if now - al["t"] > self.cfg["attack_fresh"]:
                continue
            if al["kind"] == "death":  # the agent is down: show where it fell, close
                fell = by_name.get(al.get("agent")) or {}
                p = fell.get("position") or al.get("position")
                if p:
                    surf = surface_of(fell) if fell else (p.get("surface") or "nauvis")  # (no agent row: the alert's)
                    return None, {"x": round(p["x"], 1), "y": round(p["y"], 1), "surface": surf}, al
                continue
            if al.get("agent") in scores:
                return al["agent"], None, al  # the agent itself is in the fight: following it frames the fight
            p = al.get("position")
            if not p:
                continue
            return None, {"x": round(p["x"], 1), "y": round(p["y"], 1), "surface": p.get("surface") or "nauvis",
                          "extent": p.get("extent")}, al
        return None

    def fight_zoom(self, extent):
        """The zoom that fits a fight of this extent (tiles) on a director client (~60 tiles across at zoom 1)."""
        if not extent:
            return round(self.cfg["area_zoom"] * self.cfg["main_scale"], 2)
        return round(max(0.4, min(2.0, 60.0 / (extent + self.cfg["fight_margin"]))), 2)

    # -- work away from the body -------------------------------------------------------------------------------
    def work_target(self, snapshot, now):
        """The newest fresh work item (snapshot `work`, model.py) not shown yet -> a fixed shot for the last secondary
        camera, or None. A platform: the whole platform (model.platform_shot); else the far position, closer in."""
        if not self.cfg["work_cut"] or now - self.last_work_cut < self.cfg["work_spacing"]:
            return None
        cur = self.state.get(self.slots[-1]["slot"])
        if cur and cur["subject"] in HOLDS and now < cur["until"]:
            return None  # that camera holds an attack or a segment shot
        from model import platform_shot
        for w in sorted(snapshot.get("work") or [], key=lambda w: -w["t"]):
            if w["id"] in self.work_seen:
                continue
            self.work_seen.add(w["id"])
            if now - w["t"] > self.cfg["work_fresh"]:
                continue
            shot = platform_shot(w["view"]) if w.get("view") else \
                {"position": w["position"], "surface": w.get("surface") or "nauvis", "zoom": self.cfg["work_zoom"]}
            # `work`, not `label`: public() reads a label as an attack banner
            return dict(shot, agents=[w["agent"]], subject="@work", until=now + self.cfg["work_hold"], work=w["label"])
        return None

    # -- main loop --------------------------------------------------------------------------------------------
    def step(self, snapshot, now=None, segment=None):
        """segment: Segments.camera() ({follow | position, zoom, until, label, id}) while a segment holds the main
        camera; an attack still cuts in (and the segment ends itself when it sees the alert)."""
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
            self.last_attack_alert = al  # replays.py reads it when last_attack_cut == now
            # replays.py: did this cut put the fight in frame, and from when (an agent in the fight, followed; or a
            # fixed view on the fight's position). A death is checked against the main camera's recent subjects there.
            self.last_attack_framed = {"t": now, "how": "follow" if subject else "position"} \
                if (subject or al["kind"] != "death") else None
            cur = self.state.get(main)
            if subject and cur and cur["subject"] == subject:
                cur["since"] = now - self.cfg["main_dwell"] + self.cfg["attack_hold"]  # already there: just stay
                cur.update(label=al["text"], kind=al["kind"], attack_t=now, fight=al.get("key"))
                self.last_attack_cut = now
            elif subject:
                target = self.frame(subject, by_name, {subject}, self.cfg["attack_zoom"])
                if cur:
                    released.append(cur["subject"])
                self.want[main] = (self.cfg["attack_zoom"], now)
                self.apply(self.slots[0], dict(target, subject=subject, label=al["text"], kind=al["kind"], attack_t=now,
                                               fight=al.get("key"),
                                               solo_zoom=self.cfg["attack_zoom"],
                                               since=now - self.cfg["main_dwell"] + self.cfg["attack_hold"]),
                           f"attack: {al['text']}", scores, now)
                self.last_attack_cut = now
            else:
                if cur and cur["subject"] in by_name:
                    released.append(cur["subject"])
                death = al["kind"] == "death"
                shot = {"agents": [], "subject": "@attack", "position": position, "surface": position.get("surface"),
                        "label": al["text"], "kind": al["kind"], "since": now, "attack_t": now, "fight": al.get("key"),
                        "until": now + self.cfg["death_hold" if death else "attack_hold"]}
                if death:
                    shot["zoom"] = self.cfg["death_zoom"]
                else:  # the whole fight in frame, there at once
                    shot.update(zoom=self.fight_zoom(position.get("extent")), exact_zoom=True, jump=True)
                self.apply(self.slots[0], shot, f"attack: {al['text']}", scores, now)
                self.last_attack_cut = now
        cur = self.state.get(main) if main else None
        if segment and not attack and not (cur and cur["subject"] == "@attack" and now < cur["until"]):
            if not cur or cur.get("seg") != segment["id"]:
                follow = segment.get("follow")
                if follow and follow not in by_name:
                    follow = None
                target = {"agents": [follow] if follow else [], "subject": "@segment", "zoom": segment["zoom"],
                          "seg": segment["id"], "until": segment["until"], "since": now, "segment": segment["label"]}
                if follow:
                    target["follow"] = follow
                elif segment.get("position"):
                    # a platform shot names its surface and a zoom that fits the platform (model.platform_shot)
                    target.update(position=segment["position"], surface=segment.get("surface"),
                                  exact_zoom=bool(segment.get("exact_zoom")))
                if follow or "position" in target:
                    if cur and cur["subject"] in by_name:
                        released.append(cur["subject"])
                    self.apply(self.slots[0], target, f"segment: {segment['label']}", scores, now)
        elif cur and cur["subject"] == "@segment" and (not segment or cur.get("seg") != segment["id"]):
            cur["until"] = 0  # the segment ended or was cut: back to normal directing below
        work = self.work_target(snapshot, now) if len(self.slots) > 1 else None
        if work:
            slot = self.slots[-1]
            cur = self.state.get(slot["slot"])
            if cur and cur["subject"] in by_name:
                released.append(cur["subject"])
            self.apply(slot, dict(work, since=now), f"work: {work['work']}", scores, now)
            self.last_work_cut = now
        for t in self.state.values():  # an agent whose work is on air is not also followed (its body) elsewhere
            if t and t["subject"] == "@work" and now < t["until"]:
                taken.update(t["agents"])
        for i, slot in enumerate(self.slots):
            name = slot["slot"]
            cur = self.state.get(name)
            if cur and cur["subject"] in HOLDS:
                if now < cur["until"]:
                    taken.update(cur["agents"])
                    for n in cur["agents"]:
                        self.last_on_air[n] = now
                    continue  # holding on a base attack nobody is near, or a segment's shot
                cur = None
            elif attack and i == 0 and attack[0]:
                taken.update(cur["agents"])  # just cut to the attacked agent; secondaries take the rest
                for n in cur["agents"]:
                    self.last_on_air[n] = now
                continue
            dwell = self.cfg["main_dwell"] if i == 0 else self.cfg["side_dwell"]
            base = slot.get("zoom") or (self.cfg["solo_zoom"] if i == 0 else self.cfg["side_zoom"])
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
            # zoom follows the subject's activity once it has lasted zoom_settle (a two-second walk stays close)
            want = self.zoom_for(by_name[subject], base)
            same = cur is not None and cur["subject"] == subject
            if want is None:
                want = cur.get("solo_zoom", cur["zoom"]) if same else base
            if same:
                w = self.want.get(name)
                if not w or abs(w[0] - want) > 1e-6:
                    self.want[name] = w = (want, now)
                zoom = want if now - w[1] >= self.cfg["zoom_settle"] else cur.get("solo_zoom", cur["zoom"])
            else:
                self.want[name] = (want, now)
                zoom = want
            target = self.frame(subject, by_name, taken | held | {subject}, zoom, partner,
                                None if i == 0 else self.cfg["side_pair_distance"])
            target["solo_zoom"] = zoom
            if cur is not None and cur["subject"] == subject:
                target.update({k: cur[k] for k in ("label", "kind", "attack_t") if k in cur})
            taken.update(target["agents"])
            if cur is None or cur["subject"] != subject:
                if cur is not None:
                    released.append(cur["subject"])
                self.apply(slot, dict(target, subject=subject, since=now), reason, scores, now)
            elif cur["agents"] != target["agents"]:
                self.apply(slot, dict(target, subject=subject, since=cur["since"]),
                           "pair" if len(target["agents"]) > 1 else "unpair", scores, now)
            elif "position" in target and dist(cur["position"], target["position"]) >= self.cfg["reframe_tiles"] \
                    and now - cur.get("sent", 0) >= self.cfg["reframe_every"]:
                self.apply(slot, dict(target, subject=subject, since=cur["since"]), "reframe", scores, now,
                           quiet=True)
            elif abs(target["zoom"] - cur["zoom"]) >= self.cfg["zoom_delta"] - 1e-9 \
                    and now - cur.get("sent", 0) >= self.cfg["zoom_settle"]:
                act = str(by_name[subject].get("active") or "").split(":")[0]
                self.apply(slot, dict(target, subject=subject, since=cur["since"]),
                           f"zoom {target['zoom']} ({act or by_name[subject].get('activity') or 'idle'})", scores, now)
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
            pos = target["position"]
            body = {"player": slot["player"], "position": {"x": pos["x"], "y": pos["y"]}, "zoom": target["zoom"], "smooth": True,
                    # Space Age: a fixed view names its surface (else the director's own, maybe a platform)
                    "surface": target.get("surface") or pos.get("surface") or "nauvis"}
        else:
            body = {"player": slot["player"], "follow": target["follow"], "zoom": target["zoom"], "smooth": True}
        if target is not None and target.get("map"):
            body["map"] = True  # cameras.lua: Factorio's map (the remote controller's chart), not the world
        if target is not None and target.get("jump"):
            body["smooth"] = False  # cameras.lua teleports at once (and sets the zoom) instead of easing over
        elif target is not None and target.get("glide") and "position" in target:
            body["speed"] = target["glide"]  # (d20 batch50 A2) a detail pan: cameras.lua moves at most this many tiles/s
        if target is not None and target.get("exact_zoom"):
            # a zoom that fits (a fight, a platform): sent as computed
            body["zoom"] = round(min(self.cfg["max_zoom"], target["zoom"]), 2)
        elif target is not None:
            scale = self.cfg["main_scale"] if slot is self.slots[0] else self.cfg["side_scale"]
            z = target["zoom"] * scale
            if "distance" in target:  # a pair: ~60 tiles across at zoom 1, keep both in frame
                z = min(z, 60.0 / (target["distance"] + 24.0) * (2.0 if slot is not self.slots[0] else 1.0))
            body["zoom"] = round(min(self.cfg["max_zoom"], z), 2)
        try:
            result = self.sender(body)
        except Exception as e:  # keep directing even if the harness call fails; the log shows it
            result = {"ok": False, "error": str(e)}
        if target is not None:
            target["sent"] = now
            target["game_zoom"] = body.get("zoom")  # frame_of: what the client shows
        if reason not in ("reframe", "pair", "unpair") and not reason.startswith("zoom "):
            self.last_cut = now
        self.state[name] = target
        top = sorted(scores.items(), key=lambda kv: -kv[1])[:5]
        entry = {"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)), "slot": name,
                 "reason": reason, "target": target and {k: target[k] for k in ("agents", "zoom") if k in target},
                 "cmd": body, "result": result, "scores": dict(top)}
        if getattr(self, "surface_log", None):  # onecam's surface balance: shares, targets and the factors applied
            entry["surface"] = dict(self.surface_log, terms={n: f for n, f in self.surface_terms.items() if f != 1.0})
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
                if frame_of(t):
                    out[slot["slot"]]["frame"] = frame_of(t)  # replays.py: what this camera shows
                if t.get("label") and now - t.get("attack_t", now) < self.cfg["attack_hold"]:
                    out[slot["slot"]]["attack"] = t["label"]
                    out[slot["slot"]]["alert"] = t.get("kind") or "attack"
                    if t.get("fight"):
                        out[slot["slot"]]["fight"] = t["fight"]  # replays.py: this camera shows that fight live
                if t.get("segment") and now < t.get("until", 0):
                    out[slot["slot"]]["segment"] = t["segment"]
                if t.get("work") and now < t.get("until", 0):
                    out[slot["slot"]]["work"] = t["work"]  # the page labels the camera with it
                if t.get("surface") and t["surface"] != "nauvis":
                    out[slot["slot"]]["surface"] = t["surface"]
        return out
