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
- public(): "main" is the camera on air and "inset" the inset while it is up (what viewers see), so the overlay,
  model.py, replays.py, the casters and push_live keep reading cameras.main. program() is what cuts.py applies:
  which client is on air and which, if any, is the inset.
"""
import json, time

from director import Director, HOLDS, frame_of, in_frame
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
}


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
        return {"onair": self.onair, "inset": self.inset and self.inset["slot"]}

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
        return bool(position) and in_frame(frame_of(cur, self.cfg["view_frac"]), position, by_name,
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
    def step(self, snapshot, now=None, segment=None):
        now = now or time.time()
        agents = snapshot["agents"]
        by_name = {a["name"]: a for a in agents}
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
        self.direct(by_name, scores, ranked, now)
        for t in (self.state.get(self.onair), self.state.get(self.inset and self.inset["slot"])):
            for n in (t or {}).get("agents") or []:
                self.last_on_air[n] = now
        return self.public(now)

    def direct(self, by_name, scores, ranked, now):
        """The story on air: keep it (zoom follows the activity), or pick the next subject on a standby and cut."""
        cur = self.state.get(self.onair)
        if self.pending:
            return  # an urgent shot is being framed; the cut comes within ready_s
        if cur and cur.get("subject") in HOLDS and now < cur.get("until", 0):
            return
        if cur and now < cur.get("hold_until", 0) and cur.get("subject") in scores:
            self.keep(cur, by_name, now)
            return
        subj = cur.get("subject") if cur else None
        need = subj not in scores  # nothing on air, a hold that ended, or the subject died or left
        inset_agents = set((self.state.get(self.inset["slot"]) or {}).get("agents") or []) if self.inset else set()
        others = [n for n in ranked if n != subj and n not in inset_agents]
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
            if cand and held >= self.cfg["onair_dwell"] and now - self.last_program_cut >= self.cfg["cut_spacing"]:
                if scores[cand] > scores[subj] * self.cfg["switch_margin"] + self.cfg["switch_bias"]:
                    want = cand
                    reason = f"{cand} {scores[cand]} beats {subj} {scores[subj]}"
                elif held >= self.cfg["onair_max"] and scores[cand] >= scores[subj] * self.cfg["rotate_ratio"]:
                    want = cand
                    reason = f"rotate after {int(held)} s"
            self.keep(cur, by_name, now)
        nxt = self.next_slot()
        lead = want or cand
        if nxt and lead:
            t = self.state.get(nxt["slot"])
            z = self.zoom_for(by_name[lead], self.cfg["solo_zoom"]) or self.cfg["solo_zoom"]
            if not t or t.get("subject") != lead or abs(t["zoom"] - z) >= self.cfg["zoom_delta"]:
                keep_framed = t and t.get("subject") == lead
                self.apply(nxt, {"agents": [lead], "follow": lead, "zoom": z, "solo_zoom": z, "subject": lead,
                                 "jump": True, "since": now, "framed": t["framed"] if keep_framed else now},
                           f"standby: {lead}", scores, now, quiet=True)
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
        """Zoom follows the on-air subject's activity once it has lasted zoom_settle (no pairs on air)."""
        subj = cur["subject"]
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
        for key, slot in (("main", self.onair), ("inset", self.inset and self.inset["slot"])):
            t = self.state.get(slot) if slot else None
            if not t:
                continue
            s = self.slot(slot)
            row = {"agents": t["agents"], "zoom": t["zoom"], "since": self.onair_since if key == "main" else t["since"],
                   "player": s["player"], "pair": False, "client": slot}
            fr = frame_of(t, self.cfg["view_frac"] if key == "main" else 1.0)  # the inset hole is 16:9: no crop
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
