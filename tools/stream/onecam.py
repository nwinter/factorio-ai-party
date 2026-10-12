"""One story at a time: one camera on air, the other two clients standing by (operator task 2026-10-12, after a
viewer said three cameras at once made it hard to concentrate on any one thing).

- On air: one client fills the left column (layout.json `main`; cuts.py brings it to the front in OBS). It follows
  one agent, never a pair, for at least `onair_dwell` (90 s) and usually a few minutes (`onair_max`).
- Standby: the next subject is framed on a standby client first (a jump, off air), and the cut happens once it is
  there, so viewers never watch a long pan.
- Earlier cuts only for urgent events: an agent's death, a real base loss (not minor_loss: more than three cheap
  pieces, or a turret, a machine, an engineer; one such cut per `loss_recut`), and a segment that takes the camera
  (Space Age launches and landings, spotlight, overview). The replay scene (replays.py) is its own program scene.
  After an urgent shot the story it interrupted comes back (`resume_min`).
- Inset: a minor loss (or a real one inside loss_recut) outside the on-air frame shows as a small inset for its
  length (`inset_hold`) instead of a cut. An attack with nothing lost yet is only a toast (inside the on-air frame,
  the label says it). "Inside the frame" is the client's view at its zoom after the on-air crop (director.in_frame);
  shift01 counted 60 tiles from the subject as on air, so a fight 35 tiles north of Sol got neither a cut nor an
  inset and its replay showed Sol in the base.
- Trio (operator task 2026-10-12, after Nick liked the old one-big-two-small layout because each tile said who was
  doing what): sometimes the program shows all three clients, the one on air in a big tile and the two standbys in
  small tiles (layout-3cam.json's holes), each labelled with its agent and what it does. The director picks it when
  two other agents do notable things far apart from the story on air at once (`trio_ratio`, `trio_apart`), or as a
  periodic "around the base" check-in (`trio_every`); it lasts `trio_hold` (within trio_min..trio_max) and then
  it is one camera again, with the same client on air (no cut). No flicker: at least `trio_gap` of one camera before
  a trio; never while a replay is on air (hold_layout, set by serve.py) or an urgent or segment shot holds the
  camera; the small tiles are framed off air first (like a cut) and the layout switches once both are there. An
  urgent alert or a segment that takes the camera ends a trio at once (one story for it).
- Standing still (a viewer, shift01: "should move on air to next moving player if they stand still too much"): an
  agent's model thinks between actions and its character stands there. A subject on air at least `still_min` whose
  character has not moved or visibly acted for `still_cut` gives way to an agent moving or acting now, if one scores
  at least `still_worth` of it; an agent cut away from for that is not the pick again for `still_block` (urgent
  shots aside). "Thinking" with a still character scores like idle; walking, building, mining, fighting score up.
- Look-ahead (Nick: "we know when an agent is gonna do something interesting based on their dispatched actions"):
  each agent's `plan` (live.py: the action running now as the harness status reports it, with its size and bounds).
  A big visible action (a construct or a path of many pieces, a fight, a rocket or platform action) scores
  `plan_boost`; crafting, waits and reads score `dull`. The standby is framed to fit the action's bounds ahead of the
  cut, the camera on air holds while it runs (no rotation, up to `plan_hold`), zooms to fit its bounds, and once it
  ends the stand-still rule may cut away after `plan_after` instead of `still_cut`.
- public(): "main" is the camera on air and "inset" the inset while it is up (what viewers see), so the overlay,
  model.py, replays.py, the casters and push_live keep reading cameras.main; in a trio also "cam2" and "cam3", the
  small tiles. program() is what cuts.py applies: which client is on air and which, if any, is the inset; the layout
  ("onecam" or "trio") and, in a trio, which client is in which hole.
"""
import json, time

from director import Director, BUILD, FIGHT, HOLDS, WALK, dist, frame_of, in_frame
from segments import CHEAP, LOSS_RE

MINOR = CHEAP + ("wall", "chest", "gate")  # a loss of at most MINOR_MAX of these is an inset, not a cut
MINOR_MAX = 3


def minor_loss(text):
    """"2 lost near (10, -66): 2 transport belt (by medium spitters)" -> True: a few cheap pieces (shake12 had dozens
    an hour). A turret, a machine, an engineer, or more than MINOR_MAX pieces is a real loss."""
    m = LOSS_RE.match(text or "")
    if not m:
        return False
    names = [n.strip().split(" ", 1)[-1] for n in m.group(2).split(",")]
    return int(m.group(1)) <= MINOR_MAX and all(n.endswith(MINOR) for n in names)

ONECAM = {
    "onair_dwell": 90.0,    # the subject on air holds at least this long (urgent events excepted)
    "onair_max": 240.0,     # after this, cut to the best other agent if it is at least rotate_ratio as interesting
    "ready_s": 1.5,         # a standby client this long on its new subject is framed (it jumps there) and may cut
    "inset_hold": 20.0,     # an inset stays up this long after its alert
    "onair_edge": 3.0,      # tiles: an alert inside the on-air frame (this far from its border) needs no cut or inset
    "loss_recut": 180.0,    # a loss within this long of the last loss cut is an inset, not a cut
    "resume_min": 30.0,     # back from an urgent shot, the story it interrupted holds at least this much longer
    "view_frac": 1.0,       # share of the client's width the on-air hole shows (serve.py: from layout.json's crop)
    "work_cut": False,      # work away from the body was a side camera's shot; no side cameras now
    "trio": True,           # sometimes one big tile and two small ones (module doc)
    "trio_hold": 90.0,      # a trio lasts this long ...
    "trio_min": 60.0,       # ... kept within these bounds (run config may set trio_hold)
    "trio_max": 120.0,
    # simulate.py --cams onecam (mock9, 2 h): ratio 0.6 and gap 300 s made a trio every ~6.5 min (a quarter of the
    # airtime); 0.9 and 480 s, one about every 10 min (~13%), with one camera the default
    "trio_gap": 480.0,      # at least this long on one camera before a trio (and after the start)
    "trio_every": 900.0,    # a check-in trio after this long without one, if two other agents are worth a tile
    "trio_ratio": 0.9,      # busy: two other agents each score at least this share of the subject on air ...
    "trio_apart": 40.0,     # ... and are this many tiles from it and from each other (distinct things)
    "trio_near": 20.0,      # a check-in needs its agents at least this far apart (else the tiles show one spot)
    "trio_zoom": 1.3,       # the small tiles are framed this much closer
    "trio_frac": 1.0,       # the big tile's share of a client's width (layout-3cam.json main is 16:9: no crop)
    "trio_force": False,    # mock screenshots: a trio whenever three agents can fill it, held
    "still_cut": 25.0,      # the character on air has not moved or visibly acted this long ...
    "still_min": 30.0,      # ... and has been on air this long: cut to an agent moving or acting now
    "still_moved": 0.5,     # tiles: less than this between polls is standing still
    "moving_s": 6.0,        # "moving now": moved or visibly acted within this long
    "still_worth": 0.5,     # the moving agent must score at least this share of the one on air
    "still_block": 60.0,    # an agent cut away from for standing still is not the pick again for this long
    "still_factor": 0.5,    # "thinking" with a character still for still_cut scores like idle
    "move_boost": 1.25,     # walking, building, mining, fighting now
    "plan_boost": 1.6,      # a big visible action dispatched or running (module doc)
    "dull": 0.75,           # crafting, waits, reads
    "plan_hold": 300.0,     # the camera on air holds a big action this long at most
    "plan_after": 8.0,      # once it ends, standing still this long is enough to cut away
}
VISIBLE = FIGHT | BUILD | WALK | {"mine", "gather", "craft", "construct", "kite", "repair", "pickup", "drive", "shoot"}
DULL = {"craft", "wait_until", "sleep", "inspect", "feed", "insert", "take", "transfer", "research", "fuel", "observe"}
BIG = {"construct": 4, "build_path": 8, "build_blueprint": 4, "blueprint": 4}  # kind -> pieces that make it big


def plan_kind(a):
    return str((a.get("plan") or {}).get("kind") or a.get("active") or "").split(":")[0]


def big_plan(a):
    """A visible action worth a camera: a construct or a path of BIG pieces, a fight, a rocket or platform action."""
    k = plan_kind(a)
    if a.get("combat") or k in FIGHT or k == "kite":
        return True
    if any(w in k for w in ("rocket", "platform", "launch", "cargo")):
        return True
    p = a.get("plan") or {}
    size = p.get("remaining") if p.get("remaining") is not None else p.get("total")
    return k in BIG and (size or 0) >= BIG[k]


def plan_extent(a):
    """Tiles a view must span to show the agent and its action's bounds, or None without bounds."""
    b = (a.get("plan") or {}).get("bounds")
    if not b or not a.get("position"):
        return None
    cx, cy = (b["left"] + b["right"]) / 2, (b["top"] + b["bottom"]) / 2
    return max(b["right"] - b["left"], b["bottom"] - b["top"]) + 2 * dist(a["position"], {"x": cx, "y": cy})


def onair_doing(snap, name):
    """What the agent on air is doing, for the label "Following Luna · fixing the north wall": its line in the
    team plan, else the board item it claimed, else its current action."""
    board = snap.get("board") or {}
    for d in (board.get("plan") or {}).get("doing") or []:
        if name in (d.get("agent"), d.get("name")) and d.get("text"):
            return d["text"]
    for c in board.get("claims") or []:
        if c.get("agent") == name and c.get("title"):
            return c["title"]
    a = next((a for a in snap.get("agents") or [] if a["name"] == name), {})
    if a.get("activity") == "acting" and a.get("action"):
        return a["action"].replace("_", " ")
    return ""


def onair_info(snap, cams):
    """snapshot["onair"]: who viewers are watching, for the hosts (caster.py prefers that agent) and the page."""
    main = (cams or {}).get("main") or {}
    agents = main.get("agents") or []
    name = agents[0] if len(agents) == 1 and not main.get("attack") else None
    a = next((a for a in snap.get("agents") or [] if a["name"] == name), {}) if name else {}
    return {"agent": name, "display_name": a.get("display_name") or name, "doing": onair_doing(snap, name) if name else "",
            "since": main.get("since"), "client": main.get("client"), "attack": main.get("attack"),
            "inset": ((cams or {}).get("inset") or {}).get("attack")}


class OneCam(Director):
    def __init__(self, slots, sender, log_path, **tuning):
        tuning = dict(ONECAM, **{k: v for k, v in tuning.items() if v is not None})
        super().__init__(slots, sender, log_path, **tuning)
        self.cfg["side_scale"] = self.cfg["main_scale"]  # every client may go on air: framed the same
        self.onair = slots[0]["slot"] if slots else None
        self.onair_since = time.time()
        self.inset = None    # {"slot", "until"}
        self.pending = None  # {"slot", "reason"}: a standby framing an urgent shot, cut to once ready
        self.last_alert = -1e9
        self.last_program_cut = -1e9  # (Director.last_cut counts every camera command; here only cuts on air)
        self.resume = None     # {"subject", "since"}: the story an urgent shot interrupted, taken up again after it
        self.last_loss = None  # {"t", "position"} of the last loss that cut
        self.cuts = []       # (t, slot, reason)
        self.mode = "onecam"   # or "trio"
        self.mode_since = None  # None: since the start (self.started)
        self.trio = None       # {"tiles": {"cam2": client slot, "cam3": ...}, "agents", "why", "until"} while on
        self.trio_pending = None  # the same while its small tiles are being framed
        self.last_trio = -1e9  # when the last trio ended
        self.hold_layout = False  # serve.py: a replay is on air; no layout change now
        self.layouts = []      # (t, mode, why)
        self.motion = {}       # name -> {"pos", "still_since", "moved"}: when each character last moved or acted
        self.still_block = {}  # name -> until when it is not the pick (cut away from for standing still)
        self.plan_end = {}     # name -> when its last big action ended
        self.was_big = set()

    # -- clients ----------------------------------------------------------------------------------------------
    def slot(self, name):
        return next(s for s in self.slots if s["slot"] == name)

    def standbys(self):
        busy = {self.onair, self.inset and self.inset["slot"]}
        return [s for s in self.slots if s["slot"] not in busy]

    def next_slot(self):
        """The standby that frames the next subject (the first one; the other takes insets)."""
        sb = self.standbys()
        if self.pending:
            return self.slot(self.pending["slot"])
        return sb[0] if sb else None

    def program(self):
        out = {"onair": self.onair, "inset": self.inset and self.inset["slot"], "layout": self.mode}
        if self.trio:
            out["tiles"] = dict(self.trio["tiles"], main=self.onair)
        return out

    def onair_frac(self):
        return self.cfg["trio_frac"] if self.mode == "trio" else self.cfg["view_frac"]

    def cut(self, slot, reason, now):
        if slot == self.onair:
            return
        self.onair = slot
        self.onair_since = now
        self.last_program_cut = now
        self.pending = None
        cur = self.state.get(slot)
        if cur:
            cur["since"] = now
        self.cuts.append((now, slot, reason))
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"cut to {slot}: {reason}",
                                    "target": cur and {k: cur[k] for k in ("agents", "zoom") if k in cur}}) + "\n")
        who = "+".join(cur["agents"]) if cur and cur.get("agents") else (cur or {}).get("subject", "-")
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} ON AIR {slot}: {who}  <- {reason}", flush=True)

    def frame_on(self, slot, target, reason, scores, now):
        """Send a shot to a standby client: off air, so it jumps there (no easing) and the cut can follow at once."""
        self.apply(slot, dict(target, jump=True, since=now, framed=now), reason, scores, now)

    def urgent(self, target, reason, scores, now):
        """Frame on a standby, cut once it is there (step); with one client, take the on-air one. The story on air is
        remembered and taken up again when the urgent shot is over (direct)."""
        self.leave_trio(reason, now)
        self.trio_pending = None
        cur = self.state.get(self.onair)
        if cur and cur.get("subject") in scores and not self.pending:
            self.resume = {"subject": cur["subject"], "since": self.onair_since}
        nxt = self.next_slot()
        if not nxt:
            self.apply(self.slot(self.onair), dict(target, jump=True, since=now, framed=now), reason, scores, now)
            return
        self.frame_on(nxt, target, reason, scores, now)
        self.pending = {"slot": nxt["slot"], "reason": reason}

    def ready(self, slot, now):
        t = self.state.get(slot)
        return bool(t) and now - t.get("framed", t.get("since", now)) >= self.cfg["ready_s"]

    # -- alerts -----------------------------------------------------------------------------------------------
    def attack_target(self, snapshot, by_name, scores, now):
        """Director.attack_target, spaced on any alert handled (a cut or an inset), not on cuts alone."""
        saved = self.last_attack_cut
        self.last_attack_cut = self.last_alert
        try:
            return super().attack_target(snapshot, by_name, scores, now)
        finally:
            self.last_attack_cut = saved

    def fight_zoom(self, extent):
        return round(max(0.4, super().fight_zoom(extent) * self.cfg["view_frac"]), 2)

    def near_onair(self, subject, position, by_name):
        """Do viewers see this now: the agent on air is in it, or its position is inside the on-air frame."""
        cur = self.state.get(self.onair)
        if not cur:
            return False
        if subject and subject in (cur.get("agents") or []):
            return True
        return bool(position) and in_frame(frame_of(cur, self.onair_frac()), position, by_name,
                                           self.cfg["onair_edge"])

    def on_alert(self, attack, by_name, scores, now):
        subject, position, al = attack
        if al["kind"] == "attack" and not self.near_onair(subject, position, by_name):
            return  # an attack with nothing lost yet, away from the story: its toast says it (losses inset or cut)
        self.last_alert = now
        self.last_attack_alert = al
        if subject:
            target = {"agents": [subject], "follow": subject, "zoom": self.cfg["attack_zoom"], "subject": subject,
                      "solo_zoom": self.cfg["attack_zoom"]}
        else:
            death = al["kind"] == "death"
            target = {"agents": [], "subject": "@attack", "position": position, "surface": position.get("surface"),
                      "until": now + self.cfg["death_hold" if death else "attack_hold"]}
            if death:
                target["zoom"] = self.cfg["death_zoom"]
            else:
                target.update(zoom=self.fight_zoom(position.get("extent")), exact_zoom=True)
        target.update(label=al["text"], kind=al["kind"], attack_t=now, fight=al.get("key"))
        big = al["kind"] == "death" or (al["kind"] == "loss" and not minor_loss(al["text"]))
        if big and al["kind"] == "loss" and self.last_loss and now - self.last_loss["t"] < self.cfg["loss_recut"]:
            big = False  # viewers saw a loss a moment ago: an inset keeps the story on air
        if self.mode == "trio" and not big and not self.near_onair(subject, position, by_name):
            return  # no inset over the tiles: its toast says it (a big one ends the trio in urgent())
        cur = self.state.get(self.onair)
        if self.near_onair(subject, position, by_name) and not (al["kind"] == "death" and not subject):
            # the camera on air already shows it: label it and stay through the fight
            cur.update(label=al["text"], kind=al["kind"], attack_t=now, fight=al.get("key"))
            self.onair_since = max(self.onair_since, now - self.cfg["onair_dwell"] + self.cfg["attack_hold"])
            self.last_attack_cut = now
            self.last_attack_framed = {"t": now, "how": "follow" if subject else "position"}
            return
        if big:
            if subject:  # the agent in the fight holds the camera for the fight, then normal directing resumes
                target["hold_until"] = now + self.cfg["attack_hold"]
            self.urgent(target, f"{al['kind']}: {al['text']}", scores, now)
            if al["kind"] == "loss" and position:
                self.last_loss = {"t": now, "position": position}
            self.last_attack_cut = now  # serve.py: a segment gives way, replays.py looks at the alert
            self.last_attack_framed = {"t": now, "how": "follow" if subject else "position"} \
                if (subject or al["kind"] != "death") else None
            return
        # an attack (or one cheap building lost) far from the story on air: a small inset for its length
        sb = [s for s in self.standbys() if not (self.pending and s["slot"] == self.pending["slot"])]
        if self.inset:
            slot = self.slot(self.inset["slot"])
        elif len(sb) >= 2 or (sb and not self.pending and len(self.slots) == 2):
            slot = sb[-1]
        else:
            return  # no client free for it
        self.frame_on(slot, dict(target, until=now + self.cfg["inset_hold"]), f"inset: {al['text']}", scores, now)
        self.inset = {"slot": slot["slot"], "until": now + self.cfg["inset_hold"]}

    # -- main loop --------------------------------------------------------------------------------------------
    # -- standing still and the look-ahead -----------------------------------------------------------------------
    def track(self, agents, now):
        for a in agents:
            m = self.motion.get(a["name"])
            p = a.get("position")
            acting = a.get("combat") or plan_kind(a) in VISIBLE
            if m is None:
                self.motion[a["name"]] = m = {"pos": p, "still_since": now, "moved": now}
            if p and m["pos"] and dist(p, m["pos"]) >= self.cfg["still_moved"]:
                m["pos"], m["moved"] = p, now
            elif p and not m["pos"]:
                m["pos"] = p
            if acting:
                m["moved"] = now
            big = big_plan(a)
            if a["name"] in self.was_big and not big:
                self.plan_end[a["name"]] = now
            (self.was_big.add if big else self.was_big.discard)(a["name"])

    def still_s(self, name, now):
        m = self.motion.get(name)
        return now - m["moved"] if m else 0.0

    def scores(self, agents, now):
        out = super().scores(agents, now)
        cfg = self.cfg
        for a in agents:
            n = a["name"]
            if n not in out:
                continue
            k = plan_kind(a)
            if big_plan(a):
                f = cfg["plan_boost"]
            elif k in DULL:
                f = cfg["dull"]
            elif a.get("combat") or k in VISIBLE:
                f = cfg["move_boost"]
            elif a.get("activity") == "thinking" and self.still_s(n, now) >= cfg["still_cut"]:
                f = cfg["still_factor"]  # thinking, character standing there: like idle
            else:
                f = 1.0
            out[n] = round(out[n] * f, 3)
        return out

    def plan_zoom(self, a):
        """The zoom that fits the agent and its action's bounds, or None."""
        ext = plan_extent(a) if big_plan(a) else None
        return self.fight_zoom(ext) if ext else None

    def step(self, snapshot, now=None, segment=None):
        now = now or time.time()
        agents = snapshot["agents"]
        by_name = {a["name"]: a for a in agents}
        self.track(agents, now)
        scores = self.scores(agents, now)
        ranked = sorted(scores, key=lambda n: -scores[n])
        if not self.slots:
            return {}
        if self.pending and self.ready(self.pending["slot"], now):
            self.cut(self.pending["slot"], self.pending["reason"], now)
        if self.inset and now >= self.inset["until"]:
            self.inset = None
        attack = self.attack_target(snapshot, by_name, scores, now)
        if attack:
            self.on_alert(attack, by_name, scores, now)
        cur = self.state.get(self.onair)
        urgent_hold = cur and cur.get("subject") == "@attack" and now < cur.get("until", 0)
        if segment and not attack and not urgent_hold:
            pend = self.state.get(self.pending["slot"]) if self.pending else None
            if (not cur or cur.get("seg") != segment["id"]) and not (pend and pend.get("seg") == segment["id"]):
                follow = segment.get("follow")
                if follow and follow not in by_name:
                    follow = None
                target = {"agents": [follow] if follow else [], "subject": "@segment", "zoom": segment["zoom"],
                          "seg": segment["id"], "until": segment["until"], "segment": segment["label"]}
                if follow:
                    target["follow"] = follow
                elif segment.get("position"):
                    target.update(position=segment["position"], surface=segment.get("surface"),
                                  exact_zoom=bool(segment.get("exact_zoom")))
                if follow or "position" in target:
                    self.urgent(target, f"segment: {segment['label']}", scores, now)
        elif cur and cur.get("subject") == "@segment" and (not segment or cur.get("seg") != segment["id"]):
            cur["until"] = 0  # the segment ended or was cut: back to normal directing
        if self.mode == "trio":
            self.tiles(by_name, scores, now)
        else:
            self.direct(by_name, scores, ranked, now)
            self.maybe_trio(by_name, scores, ranked, now)
        shown = [self.onair, self.inset and self.inset["slot"]] + list((self.trio or {}).get("tiles", {}).values())
        for t in (self.state.get(s) for s in shown if s):
            for n in (t or {}).get("agents") or []:
                self.last_on_air[n] = now
        return self.public(now)

    # -- trio: one big tile and two small ones ------------------------------------------------------------------
    def trio_pick(self, subj, by_name, scores, ranked, now):
        """-> (two agents for the small tiles, why) or None: busy (two others score near the story on air and are far
        from it and each other) or a check-in (trio_every since the last trio)."""
        def apart(a, b, d):
            pa, pb = by_name[a].get("position"), by_name[b].get("position")
            return (by_name[a].get("surface") or "nauvis") != (by_name[b].get("surface") or "nauvis") or \
                not (pa and pb) or dist(pa, pb) >= d
        cfg = self.cfg
        for d, need, why in ((cfg["trio_apart"], max(1e-6, scores.get(subj, 0) * cfg["trio_ratio"]), "busy"),
                             (cfg["trio_near"], 0, "check-in")):
            if why == "check-in" and not cfg["trio_force"] and now - max(self.last_trio, self.started) < cfg["trio_every"]:
                continue
            pick = []
            for n in ranked:
                if n == subj or scores[n] < need or not apart(n, subj, d) or any(not apart(n, p, d) for p in pick):
                    continue
                pick.append(n)
                if len(pick) == 2:
                    return pick, why
        return None

    def maybe_trio(self, by_name, scores, ranked, now):
        """One camera long enough, nothing urgent: frame two standbys for a trio, switch once both are there."""
        cfg = self.cfg
        if not cfg["trio"] or len(self.slots) < 3:
            return
        cur = self.state.get(self.onair)
        subj = cur.get("subject") if cur else None
        blocked = (self.hold_layout or self.pending or self.inset or subj not in scores or
                   (not cfg["trio_force"] and now - self.since_mode() < cfg["trio_gap"]))
        p = self.trio_pending
        if blocked:
            self.trio_pending = None
            return
        if p:
            if any(a not in scores for a in p["agents"]):
                self.trio_pending = None
            elif all(self.ready(s, now) for s in p["tiles"].values()):
                hold = min(cfg["trio_max"], max(cfg["trio_min"], cfg["trio_hold"]))
                self.trio = dict(p, until=1e18 if cfg["trio_force"] else now + hold)
                self.trio_pending = None
                self.set_mode("trio", f"{p['why']}: {', '.join(p['agents'])}", now)
            return
        found = self.trio_pick(subj, by_name, scores, ranked, now)
        sb = self.standbys()
        if not found or len(sb) < 2:
            return
        pick, why = found
        tiles = {}
        for hole, slot, name in zip(("cam2", "cam3"), sb, pick):
            z = round((self.zoom_for(by_name[name], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]) * cfg["trio_zoom"], 2)
            t = self.state.get(slot["slot"])
            if not (t and t.get("subject") == name):
                self.frame_on(slot, {"agents": [name], "follow": name, "zoom": z, "solo_zoom": z, "subject": name},
                              f"trio tile: {name}", scores, now)
            tiles[hole] = slot["slot"]
        self.trio_pending = {"tiles": tiles, "agents": pick, "why": why}

    def tiles(self, by_name, scores, now):
        """In a trio: the big tile keeps its story (zoom follows), the small tiles their agents; over at `until`, or at
        once when an agent in it is gone."""
        cur = self.state.get(self.onair)
        gone = (not cur or cur.get("subject") not in scores) or any(a not in scores for a in self.trio["agents"])
        if gone or now >= self.trio["until"]:
            self.leave_trio("an agent left" if gone else f"after {int(now - self.since_mode())} s", now)
            return
        self.keep(cur, by_name, now)

    def since_mode(self):
        return self.started if self.mode_since is None else self.mode_since

    def leave_trio(self, why, now):
        if self.mode != "trio":
            return
        self.trio = None
        self.last_trio = now
        self.set_mode("onecam", why, now)

    def set_mode(self, mode, why, now):
        self.mode, self.mode_since = mode, now
        self.layouts.append((now, mode, why))
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"t": round(now, 1), "time": time.strftime("%H:%M:%S", time.localtime(now)),
                                    "slot": "program", "reason": f"layout {mode}: {why}", "target": None,
                                    "tiles": (self.trio or {}).get("tiles")}) + "\n")
        print(f"[director] {time.strftime('%H:%M:%S', time.localtime(now))} LAYOUT {mode}  <- {why}", flush=True)

    def layout_info(self):
        """snapshot["onair"]["layout"]: what the program shows, for the hosts and the page."""
        out = {"mode": self.mode, "since": round(self.since_mode(), 1)}
        if self.trio:
            out.update(why=self.trio["why"], agents=list(self.trio["agents"]), until=round(self.trio["until"], 1))
        return out

    def direct(self, by_name, scores, ranked, now):
        """The story on air: keep it (zoom follows the activity), or pick the next subject on a standby and cut."""
        cur = self.state.get(self.onair)
        if self.pending:
            return  # an urgent shot is being framed; the cut comes within ready_s
        if self.trio_pending:  # the standbys are being framed for a trio: hold the story
            if cur and cur.get("subject") in scores:
                self.keep(cur, by_name, now)
            return
        if cur and cur.get("subject") in HOLDS and now < cur.get("until", 0):
            return
        if cur and now < cur.get("hold_until", 0) and cur.get("subject") in scores:
            self.keep(cur, by_name, now)
            return
        subj = cur.get("subject") if cur else None
        need = subj not in scores  # nothing on air, a hold that ended, or the subject died or left
        inset_agents = set((self.state.get(self.inset["slot"]) or {}).get("agents") or []) if self.inset else set()
        blocked = {n for n, t in self.still_block.items() if now < t}
        others = [n for n in ranked if n != subj and n not in inset_agents and n not in blocked]
        cand = others[0] if others else None
        want = None
        resumed = None
        if need:
            r, self.resume = self.resume, None
            if r and r["subject"] in scores and r["subject"] not in inset_agents and subj in (None, "@attack", "@segment"):
                want, resumed = r["subject"], r  # back to the story the urgent shot interrupted
                self.resume = r  # kept until the cut back happens
            else:
                want = ranked[0] if ranked else None
            if want is None:
                return
        else:
            held = now - self.onair_since
            cfg = self.cfg
            holding = big_plan(by_name[subj]) and held < cfg["plan_hold"]  # its big action runs: stay
            if cand and not holding and held >= cfg["onair_dwell"] and now - self.last_program_cut >= cfg["cut_spacing"]:
                if scores[cand] > scores[subj] * cfg["switch_margin"] + cfg["switch_bias"]:
                    want = cand
                    reason = f"{cand} {scores[cand]} beats {subj} {scores[subj]}" + \
                        (f" ({plan_kind(by_name[cand])} ahead)" if big_plan(by_name[cand]) else "")
                elif held >= cfg["onair_max"] and scores[cand] >= scores[subj] * cfg["rotate_ratio"]:
                    want = cand
                    reason = f"rotate after {int(held)} s"
            still = self.still_s(subj, now)
            ended = now - self.plan_end.get(subj, -1e9) < cfg["onair_dwell"]
            if not want and not holding and held >= cfg["still_min"] and \
                    still >= (cfg["plan_after"] if ended else cfg["still_cut"]):
                moving = [n for n in others if self.still_s(n, now) < cfg["moving_s"]
                          and scores[n] >= scores[subj] * cfg["still_worth"]]
                if moving:
                    want = cand = moving[0]
                    why = f"{plan_kind(by_name[want])} ahead" if big_plan(by_name[want]) else "moving"
                    reason = f"{subj} still {int(still)} s; {want} {why}"
                    self.still_block[subj] = now + cfg["still_block"]
            self.keep(cur, by_name, now)
        nxt = self.next_slot()
        lead = want or cand
        if nxt and lead:
            t = self.state.get(nxt["slot"])
            fit = self.plan_zoom(by_name[lead])  # framed on its action's bounds ahead of the cut
            z = fit or self.zoom_for(by_name[lead], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            if not t or t.get("subject") != lead or abs(t["zoom"] - z) >= self.cfg["zoom_delta"]:
                keep_framed = t and t.get("subject") == lead
                shot = {"agents": [lead], "follow": lead, "zoom": z, "solo_zoom": z, "subject": lead,
                        "jump": True, "since": now, "framed": t["framed"] if keep_framed else now}
                if fit:
                    shot.update(exact_zoom=True, plan_fit=fit)
                self.apply(nxt, shot, f"standby: {lead}" + (f" ({plan_kind(by_name[lead])} bounds)" if fit else ""),
                           scores, now, quiet=True)
        if want and nxt and self.state[nxt["slot"]].get("subject") == want and self.ready(nxt["slot"], now):
            self.cut(nxt["slot"], reason if not need else f"back to {want}" if resumed else
                     (f"{subj} unavailable" if subj else "initial"), now)
            self.want[nxt["slot"]] = (self.state[nxt["slot"]]["zoom"], now)
            if resumed:
                self.resume = None
                self.onair_since = max(resumed["since"], now - self.cfg["onair_dwell"] + self.cfg["resume_min"])
        elif want and not nxt and need:  # one client only: retarget it on air
            z = self.zoom_for(by_name[want], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            self.apply(self.slot(self.onair), {"agents": [want], "follow": want, "zoom": z, "solo_zoom": z,
                                               "subject": want, "since": now}, "initial", scores, now)
            self.onair_since = now

    def keep(self, cur, by_name, now):
        """Zoom follows the on-air subject's activity once it has lasted zoom_settle (no pairs on air); while a big
        action with bounds runs, the zoom fits them."""
        subj = cur["subject"]
        fit = self.plan_zoom(by_name[subj])
        if fit or cur.get("plan_fit"):
            if fit and cur.get("plan_fit") and abs(fit - cur["plan_fit"]) < self.cfg["zoom_delta"]:
                return  # fitted already
            target = {k: v for k, v in cur.items() if k not in ("jump", "exact_zoom", "plan_fit")}
            if fit:
                target.update(zoom=fit, exact_zoom=True, plan_fit=fit)
                reason = f"zoom {fit} (fits {plan_kind(by_name[subj])})"
            else:  # the action ended: back to the activity's zoom
                target.update(zoom=self.cfg["solo_zoom"], solo_zoom=self.cfg["solo_zoom"])
                reason = "zoom (action over)"
            self.apply(self.slot(self.onair), target, reason, {}, now)
            return
        want = self.zoom_for(by_name[subj], self.cfg["solo_zoom"])
        if want is None:
            want = cur.get("solo_zoom", cur["zoom"])
        w = self.want.get(self.onair)
        if not w or abs(w[0] - want) > 1e-6:
            self.want[self.onair] = w = (want, now)
        zoom = want if now - w[1] >= self.cfg["zoom_settle"] else cur.get("solo_zoom", cur["zoom"])
        if abs(zoom - cur["zoom"]) >= self.cfg["zoom_delta"] - 1e-9 and now - cur.get("sent", 0) >= self.cfg["zoom_settle"]:
            act = str(by_name[subj].get("active") or "").split(":")[0]
            target = {k: v for k, v in cur.items() if k != "jump"}
            target.update(zoom=zoom, solo_zoom=zoom)
            self.apply(self.slot(self.onair), target, f"zoom {zoom} ({act or by_name[subj].get('activity') or 'idle'})",
                       {}, now)

    def public(self, now=None):
        now = now or time.time()
        out = {}
        rows = [("main", self.onair), ("inset", self.inset and self.inset["slot"])]
        if self.trio:
            rows += sorted(self.trio["tiles"].items())
        for key, slot in rows:
            t = self.state.get(slot) if slot else None
            if not t:
                continue
            s = self.slot(slot)
            row = {"agents": t["agents"], "zoom": t["zoom"], "since": self.onair_since if key == "main" else t["since"],
                   "player": s["player"], "pair": False, "client": slot}
            fr = frame_of(t, self.onair_frac() if key == "main" else 1.0)  # inset and small tiles are 16:9: no crop
            if fr:
                row["frame"] = fr  # replays.py: what the program shows
            if t.get("label") and now - t.get("attack_t", now) < self.cfg["attack_hold"]:
                row.update(attack=t["label"], alert=t.get("kind") or "attack")
                if t.get("fight"):
                    row["fight"] = t["fight"]
            if t.get("segment") and now < t.get("until", 0):
                row["segment"] = t["segment"]
            if t.get("surface") and t["surface"] != "nauvis":
                row["surface"] = t["surface"]
            out[key] = row
        return out
