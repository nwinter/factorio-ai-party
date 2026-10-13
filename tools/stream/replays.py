"""Instant replays from the OBS replay buffer (operator go-ahead in REPLAYS.md; docs/STREAM-NOTES.md "Replays").

Factorio cannot rewind in multiplayer, so the replay is OBS's: the replay buffer keeps the last ~45 s of the program
output (all three cameras). A replay shows what a camera recorded and what the main camera's viewers did not just
watch (shake10: the main camera showed a fight live, then the replay aired that same stretch while the battle went on):

  - never during the fight: a clip about a fight waits until that fight (model.py `fights`) has been quiet 20 s
    (`quiet_s`); a death clip waits while any fight within 40 tiles goes on;
  - a fight the main camera showed live gets no replay of it (main covered most of the window, `main_frac`);
  - a loss (something destroyed): a clip of the stretch in which the program showed that spot, around the moment of
    loss (from `loss_before` before it to `loss_watch` after, at most `loss_len`, at least `loss_min_s`), aired after
    the fight ends, even if the main camera watched it live. "Showed" is geometry: the spot inside the frame of the
    camera on air (cams["main"]["frame"], director.in_frame: the client's view at its zoom, after the on-air crop;
    in a trio the big tile; never the inset or a small tile, since the replay is the whole program), sampled every tick; never while a replay is on air (the program is the replay then). shift01: a loss 20
    tiles from Sol counted as shown; the program had Sol in the base and the fight was 35 tiles north, off frame.
    Several losses of one fight within one clip's stretch get one clip;
  - a fight only a side camera showed: that camera's stretch of it (at least `side_min_s`, at most `fight_show`) is
    saved while it is in the buffer and aired after the fight ends. No camera on it: no replay;
  - death: if the main camera showed that agent in the 10 s before, save 5 s after and replay 11 s before to 4 s after.

The clip plays as an `attack_replay` segment (segments.py), so the casters see it and talk over it: on "live" the
program scene switches to the "replay" scene (the clip, muted, under a REPLAY banner page; the stream overlay rides
along off-canvas so the casters' voices keep playing), and when the segment ends or is cut the program goes back to
"stream". A watchdog returns to "stream" whenever "replay" is on air without a replay playing.
"""
import itertools, json, threading, time, traceback
from collections import deque

from director import in_frame
from obsws import OBS, OBSError
from segments import STARTING_S

DEFAULTS = {
    "scene": "replay",             # created on first connect if missing
    "stream_scene": "stream",      # always returned to
    "media": "replay clip",        # ffmpeg_source in the replay scene
    "banner": "replay banner",     # browser source with /replay (REPLAY banner)
    "overlay_input": "stream overlay",  # the live overlay's browser source (voices), added off-canvas
    "fight_show": 15.0,            # at most this much of a fight a side camera recorded
    "side_min_s": 6.0,             # a side camera must have shown the fight this long for a clip
    "main_frac": 0.5,              # the main camera showed more than this share of a window live: no replay of it
    "main_near": 20.0,             # tiles (plus half the fight's extent): an agent the main camera follows shows it
    "side_near": 12.0,             # the same for a side camera (closer view)
    "quiet_s": 20.0,               # a fight is over once it has not been reported for this long
    "fight_near": 40.0,            # a death clip waits while a fight this close goes on
    "loss_before": 6.0,            # a loss clip: the program's footage of the spot from 6 s before the loss
    "loss_after": 4.0,             # (to 4 s after when it was on air all along: loss_len in all)
    "loss_watch": 15.0,            # ... or later, up to this long after it (a cut to the fight: its footage starts then)
    "loss_len": 10.0,              # at most this long
    "loss_min_s": 4.0,             # less footage of the spot than this: no clip
    "loss_merge": 30.0,            # tiles: a loss this close to one already clipped, inside its stretch, adds no clip
    "frame_edge": 2.0,             # tiles: a spot this close to a frame's border does not count as shown
    "loss_lag": 2.0,               # a loss alert arrives about this long after the loss (status poll)
    "fight_max_age": 300.0,        # a clip waiting for its fight to end is dropped after this long
    "death_before": 11.0,          # replay window around a death
    "death_after": 4.0,
    "death_save_after": 5.0,
    "seen_window": 10.0,           # a death replays only if main showed that agent this recently
    "spacing": 120.0,              # at most one replay this often
    "max_age": 120.0,              # a clip not played within this long is dropped
    "stats_every": 30.0,
    "play_timeout": 8.0,           # a replay segment live this long with the clip not on air is ended
    # key battles (onecam.py watch_battle; Nick on the 12:58 Demolisher replay: "a few seconds on Nauvis, several
    # seconds of an empty field ... replay wasn't long enough and had irrelevant camera shots"): module doc
    "buffer_s": 45.0,              # the OBS replay buffer's length (the pog profile's setting, not changed here)
    "battle_margin": 4.0,          # a window is saved while it is this far inside the buffer
    "battle_min": 15.0,            # a battle clip is this long ...
    "battle_per_piece": 0.5,       # ... plus this per piece lost (59 turrets: 40 s) ...
    "battle_cap": 40.0,            # ... at most this (and buffer_s - battle_margin)
    "battle_footage": 8.0,         # a start window shorter than this (the battle was over at once): no clip
    "cut_settle": 2.0,             # on-air footage counts from this long after a cut (OBS switches a tick later)
    "battle_lead": 3.0,           # the clip starts this long before the battle's first sign, not earlier
    "battle_first_s": 4.0,         # on-air footage must begin by this long after the first sign (else: aftermath)
    "battle_cover": 0.7,           # ... and cover this share of the start window
    "battle_live_frac": 0.9,       # the program showed this share of the battle live: no replay of it
    "battle_gap": 2.5,             # seconds: footage samples further apart than this are separate runs
}


class Replays:
    def __init__(self, segments, overlay_url="http://127.0.0.1:8787/replay", obs=None, log=print, start=True, **cfg):
        self.cfg = dict(DEFAULTS, **{k: v for k, v in cfg.items() if v is not None})
        self.segments = segments
        segments.replays = self
        self.overlay_url = overlay_url
        self.obs = obs or OBS()
        self.log = log
        self.lock = threading.Lock()
        self.ids = itertools.count(1)
        self.pending = None      # {kind, label, agent, save_at, show_from, show_to}
        self.clip = None         # saved, not yet played: {id, path, saved_t, show_from, show_to, label, kind, agent}
        # Deaths close together each get a clip, played in order. In shake4 Haiku's clip was queued, Opus died 43 s
        # later, that cut emptied the segment queue and Opus's clip replaced Haiku's: Haiku's death never aired.
        self.more_pending = deque(maxlen=4)  # later deaths, losses and side clips waiting behind self.pending
        self.more_clips = deque(maxlen=4)    # saved clips waiting behind self.clip
        self.fights = {}  # key -> {last, position, ...} from the latest snapshot (model.py fights)
        self.cover = {}   # key -> {"main": deque[t], "side": deque[t], "run": start of the side camera's run, ...}
        self.playing = None      # clip id on air
        self.last_replay = -1e9
        self.main_seen = deque(maxlen=60)  # (t, [agents on main])
        self.frames = deque(maxlen=90)     # (t, {slot: camera row}, {name: agent}): what the program showed, per tick
        self.loss_wait = []                # losses judged once their window is over (judge_losses)
        self.loss_clips = deque(maxlen=8)  # (show_from, show_to, position) of the loss clips queued
        self.status = {"enabled": True, "connected": False, "buffer_active": None, "error": None, "stats": None,
                       "replays": 0, "last": None, "program": None}
        self.prev_stats = None
        self.next_stats = 0
        self.next_buffer_try = 0
        self.scene_ready = False
        self.next_watch = 0
        self.refreshed = None  # segment id whose banner page was reloaded
        self.battle = None     # the key battle being covered: {key, info, shown: [t], parts: {part: score}, ...}
        self.battle_keep = {}  # battle key -> the part to air ("start" / "end"), or "none", once it is over
        self.battle_areas = deque(maxlen=8)  # (until, position+surface, extent): losses there are the battle's
        if start:  # selftest drives work() by hand
            threading.Thread(target=self.run, daemon=True).start()

    # ---- availability for segments.py --------------------------------------------------------------------------
    def why(self, now=None):
        now = now or time.time()
        if not self.status["connected"]:
            return "OBS not connected" + (f" ({self.status['error']})" if self.status["error"] else "")
        if not self.status["buffer_active"]:
            return "OBS replay buffer not running"
        if not self.clip or now - self.clip["show_to"] > self.max_age(self.clip):
            return "no fresh clip (one is saved after a death on the main camera, a loss, or a fight a side camera showed)"
        if self.waiting(self.clip, now):
            return "the fight is still going on (a replay airs once it has been quiet 20 s)"
        return None

    def max_age(self, c):
        if c.get("battle"):
            return 1200.0  # saved at its start, aired after a battle that may last minutes
        return self.cfg["fight_max_age"] if c.get("fight") or c.get("position") else self.cfg["max_age"]

    def waiting(self, c, now):
        """True while the fight a clip is about (or, for a death, a fight within fight_near) is still going on."""
        q = self.cfg["quiet_s"]
        if c.get("battle"):  # until the director says the battle is over (quiet battle_after) and a part is chosen
            return c["battle"] not in self.battle_keep
        if c.get("fight"):
            f = self.fights.get(c["fight"])
            return bool(f and now - f["last"] < q)
        p = c.get("position")
        if p:  # a loss alert is re-reported ~2 minutes after the fact: only attacks count as a fight going on
            return any(now - f["last"] < q and f.get("kind") != "loss" and f.get("position") and
                       ((f["position"]["x"] - p["x"]) ** 2 + (f["position"]["y"] - p["y"]) ** 2) ** 0.5 <= self.cfg["fight_near"]
                       for f in self.fights.values())
        return False

    def facts(self, now):
        c = self.clip
        return {"event": c["label"], "kind": c["kind"], "agent": c.get("agent_name"),
                "seconds": round(c["show_to"] - c["show_from"]), "ago_s": round(now - c["show_to"])}, c["id"]

    # ---- hooks from serve.py's ticker ---------------------------------------------------------------------------
    def tick(self, snap, cams, now):
        main = (cams or {}).get("main") or {}
        self.main_seen.append((now, list(main.get("agents") or [])))
        self.fights = {f["key"]: f for f in snap.get("fights") or []}
        if not self.playing:  # while a replay is on air the program is the replay, not the cameras
            by_name = {a["name"]: {k: a.get(k) for k in ("position", "surface")} for a in snap.get("agents") or []}
            self.frames.append((now, {s: dict(c) for s, c in (cams or {}).items()}, by_name))
        self.watch_fights(snap, cams or {}, now)
        self.watch_battle(snap.get("battle"), snap, cams or {}, now)
        self.judge_losses(now)

    def shows(self, slot, cam, fight, by_name):
        """Does this camera show the fight now: its position inside the camera's frame; without a frame (older
        directors), the director's cut to it (main), or an agent it follows near it."""
        if cam.get("frame"):
            return in_frame(cam["frame"], fight.get("position"), by_name, self.cfg["frame_edge"])
        if cam.get("fight") == fight["key"]:
            return True
        p = fight.get("position") or {}
        other = self.fights.get(cam.get("fight")) if cam.get("fight") else None
        if other and p and other.get("position"):  # the camera's fight covers this spot (a loss inside an attack)
            q = other["position"]
            reach = ((q.get("extent") or 0) + (p.get("extent") or 0)) / 2 + 8
            if (q.get("surface") or "nauvis") == (p.get("surface") or "nauvis") and \
                    ((q["x"] - p["x"]) ** 2 + (q["y"] - p["y"]) ** 2) ** 0.5 <= reach:
                return True
        near = self.cfg["main_near" if slot == "main" else "side_near"] + (p.get("extent") or 0) / 2
        for n in cam.get("agents") or []:
            a = by_name.get(n) or {}
            q = a.get("position")
            if q and p and (a.get("surface") or "nauvis") == (p.get("surface") or "nauvis") and \
                    ((q["x"] - p["x"]) ** 2 + (q["y"] - p["y"]) ** 2) ** 0.5 <= near:
                return True
        return False

    def watch_fights(self, snap, cams, now):
        """Per fight, which cameras showed it when; from that the loss clips and the side-camera clips (module doc)."""
        by_name = {a["name"]: a for a in snap.get("agents") or []}
        for key, f in self.fights.items():
            c = self.cover.setdefault(key, {"main": deque(maxlen=120), "side": deque(maxlen=120), "run": None,
                                            "side_done": False, "losses_done": set()})
            main_on = self.shows("main", cams.get("main") or {}, f, by_name)
            # side-camera clips only for the three-camera director (rows without a frame); with one camera the other
            # rows are the inset and the trio's small tiles, which a replay of the program would not show big
            side_on = any(self.shows(s, cam, f, by_name) for s, cam in cams.items()
                          if s != "main" and not cam.get("frame"))
            if self.playing:  # the program is a replay: the cameras are off air
                main_on = side_on = False
            if main_on:
                c["main"].append(now)
            if side_on:
                c["side"].append(now)
            # a loss: judged once its window is over, on what the program showed of the spot (judge_losses)
            for lt in f.get("losses") or []:
                if lt in c["losses_done"]:
                    continue
                c["losses_done"].add(lt)
                self.loss_wait.append({"key": key, "t_loss": lt - self.cfg["loss_lag"], "text": f.get("text"),
                                       "position": f.get("position"), "fight": key if f.get("kind") != "loss" else None})
            # a side camera's run on the fight: a clip of it when the run ends (or reaches fight_show)
            if c["side_done"] or f.get("kind") == "loss":
                continue  # a loss is not a fight to replay at length: its moment has its own clip above
            if side_on and c["run"] is None:
                c["run"] = now
            run_len = now - c["run"] if c["run"] is not None else 0
            if c["run"] is not None and (not side_on or run_len >= self.cfg["fight_show"]):
                start, end = max(c["run"], now - self.cfg["fight_show"]), now
                c["run"] = None
                if end - start < self.cfg["side_min_s"]:
                    continue
                main_share = sum(1 for t in c["main"] if start <= t <= end) / max(1, sum(1 for t in c["side"] if start <= t <= end))
                c["side_done"] = True
                if main_share > self.cfg["main_frac"]:
                    self.log(f"[replays] skipped {key}: the main camera showed it live ({f.get('text')})")
                    continue
                self.queue_pending({"kind": "fight", "label": f.get("text") or "Fight", "fight": key, "agent": None,
                                    "agent_name": None, "position": f.get("position"),
                                    "save_at": now, "show_from": start, "show_to": end})
        for key in [k for k in self.cover if k not in self.fights]:
            del self.cover[key]

    # ---- key battles -------------------------------------------------------------------------------------------
    def shows_battle(self, main, info, by_name):
        """The camera on air shows the battle: the agent fighting in it followed, or the battle's spot on the frame's
        surface inside the frame (its area may reach in from just outside). Another surface, another place: no."""
        fr = main.get("frame")
        if not fr:
            return False
        if fr.get("follow") and fr["follow"] == info.get("agent"):
            a = by_name.get(fr["follow"]) or {}
            return (a.get("surface") or "nauvis") == info["position"].get("surface", "nauvis")
        return in_frame(fr, info["position"], by_name, -min((info.get("extent") or 0) / 2, 15.0))

    def battle_len(self, info):
        c = self.cfg
        return max(c["battle_min"], min(c["battle_cap"], c["buffer_s"] - c["battle_margin"],
                                        c["battle_min"] + c["battle_per_piece"] * (info.get("lost") or 0)))

    def runs(self, ts, lo, hi):
        out = []
        for t in ts:
            if not lo <= t <= hi:
                continue
            if out and t - out[-1][1] <= self.cfg["battle_gap"]:
                out[-1][1] = t
            else:
                out.append([t, t])
        return out

    def watch_battle(self, info, snap, cams, now):
        """A key battle (snapshot battle, onecam.py): what the program showed of it, sampled every tick. Its clip is
        one window from battle_lead before its first sign (the first hit or loss the director heard of), battle_len
        long, saved once the window is over (well inside the buffer). It airs once the battle is over, and only if the
        program's footage covers that first moment (Nick, 13:40: the replays were "just the after-battle carnage, with
        a few seconds of unrelated base capture beforehand"): footage that starts later is aftermath, no replay; and
        not if the program showed nearly all of it live."""
        cfg = self.cfg
        b = self.battle
        if b and (not info or info["key"] != b["key"]):
            self.finish_battle(now)
            b = None
        if not info:
            return
        if not b:
            b = self.battle = {"key": info["key"], "info": info, "shown": [], "saved": None, "why": None}
        b["info"] = info
        by_name = {a["name"]: {k: a.get(k) for k in ("position", "surface")} for a in snap.get("agents") or []}
        main = (cams or {}).get("main") or {}
        # a cut is decided here a tick or two before OBS shows it (cuts.py): the first cut_settle s after it are the
        # camera before (13:35's replay opened on "unrelated base capture")
        settled = now - (main.get("since") or 0) >= cfg["cut_settle"]
        if not self.playing and settled and self.shows_battle(main, info, by_name):
            b["shown"].append(now)
        if not b["saved"] and not b["why"] and now >= info["first"] - cfg["battle_lead"] + self.battle_len(info):
            self.judge_start(b, now)

    def judge_start(self, b, now):
        """The start window, judged once it is over (or the battle ended first): saved, or why not."""
        cfg, info = self.cfg, b["info"]
        start = info["first"] - cfg["battle_lead"]
        end = min(start + self.battle_len(info), now)
        shown = self.runs(b["shown"], start, end)
        first_seen = shown[0][0] if shown else None
        covered = sum(r[1] - r[0] + 1 for r in shown)
        if first_seen is None or first_seen > info["first"] + cfg["battle_first_s"]:
            b["why"] = ("aftermath only: no on-air footage of its start" if first_seen is None else
                        f"aftermath only: footage starts {first_seen - info['first']:.0f} s after its first sign")
        elif end - start < cfg["battle_footage"] or covered < cfg["battle_cover"] * (end - start):
            b["why"] = f"too little footage of its start ({covered:.0f} s of {end - start:.0f} s)"
        elif now - start > cfg["buffer_s"] - 1:
            b["why"] = "its start has left the replay buffer"
        else:
            b["saved"] = (start, end)
            self.queue_pending({"kind": "battle", "label": info.get("label") or "Battle", "battle": b["key"],
                                "battle_part": "start", "agent": None, "agent_name": info.get("agent"),
                                "position": info["position"], "save_at": now, "show_from": start, "show_to": end})
            self.log(f"[replays] battle start saved: {end - start:.0f} s from {cfg['battle_lead']:g} s before its first "
                     f"sign ({b['key']}; {covered:.0f} s of it on air)")

    def finish_battle(self, now):
        b, self.battle = self.battle, None
        info = b["info"]
        if not b["saved"] and not b["why"]:
            self.judge_start(b, now)  # a battle over before its start window ended
        self.battle_areas.append((now + 300, info["position"], info.get("extent") or 0))
        span = max(1.0, info["last"] - info["first"])
        live = sum(r[1] - r[0] + 1 for r in self.runs(b["shown"], info["first"], info["last"] + 1))
        if not b["saved"]:
            keep, why = "none", b["why"] or "it ended before its start window was judged"
        elif live / span >= self.cfg["battle_live_frac"]:
            keep, why = "none", f"the program showed {live / span:.0%} of it live"
        else:
            keep, why = "start", f"its start ({live:.0f} s of {span:.0f} s were on air)"
        self.battle_keep[b["key"]] = keep
        self.log(f"[replays] battle over ({info.get('label')}): replay {'none, ' if keep == 'none' else ''}{why}")

    def in_battle_area(self, p, now):
        return any(now < until and p and p.get("x") is not None and
                   (p.get("surface") or "nauvis") == q.get("surface", "nauvis") and
                   ((p["x"] - q["x"]) ** 2 + (p["y"] - q["y"]) ** 2) ** 0.5 <= ext / 2 + 60
                   for until, q, ext in list(self.battle_areas) +
                   ([(now + 1, self.battle["info"]["position"], self.battle["info"].get("extent") or 0)] if self.battle else []))

    def footage(self, w, lo, hi, gap=2.5):
        """The longest stretch in [lo, hi] in which the main view (the camera on air; in a trio the big tile) showed
        w's spot -> (start, end) or None. Only the main view: a replay plays the whole program recording, so footage
        in which the spot was only in the 408x230 inset (or a small trio tile) airs as the agent on air doing
        something else (15:44 on shift01: '3 lost near (36, -76)' replayed from inset-only footage)."""
        shown = [t for t, rows, by_name in self.frames
                 if lo <= t <= hi and self.shows("main", rows.get("main") or {}, w, by_name)]
        runs = []
        for t in shown:
            if runs and t - runs[-1][1] <= gap:
                runs[-1][1] = t
            else:
                runs.append([t, t])
        return tuple(max(runs, key=lambda r: r[1] - r[0])) if runs else None

    def judge_losses(self, now):
        """A loss gets a clip of the program's own footage of its spot, starting where that footage starts."""
        cfg = self.cfg
        for w in [w for w in self.loss_wait if now >= w["t_loss"] + cfg["loss_watch"]]:
            self.loss_wait.remove(w)
            label, p = w["text"] or "Loss", w["position"] or {}
            if self.in_battle_area(p, now):
                self.log(f"[replays] skipped loss: part of the key battle's replay ({label})")
                continue
            run = self.footage(w, w["t_loss"] - cfg["loss_before"], w["t_loss"] + cfg["loss_watch"])
            if not run or run[1] - run[0] < cfg["loss_min_s"]:
                self.log(f"[replays] skipped loss: the program showed its spot "
                         f"{'%.0f s' % (run[1] - run[0]) if run else 'never'} ({label})")
                continue
            start = run[0]
            end = min(run[1], start + cfg["loss_len"])
            dup = next((c for c in self.loss_clips if start < c[1] and c[2] and p and
                        ((c[2]["x"] - p["x"]) ** 2 + (c[2]["y"] - p["y"]) ** 2) ** 0.5 <= cfg["loss_merge"]), None)
            if dup:
                self.log(f"[replays] skipped loss: inside the clip of the same fight already queued ({label})")
                continue
            self.loss_clips.append((start, end, p))
            # waits on the attacks around it (position), not on the loss alert, which stays up ~2 minutes
            self.queue_pending({"kind": "loss", "label": label, "fight": w["fight"], "agent": None, "agent_name": None,
                                "position": w["position"], "save_at": now,
                                "show_from": start, "show_to": end})

    def queue_pending(self, p):
        with self.lock:
            if self.pending is None:
                self.pending = p
            else:
                self.more_pending.append(p)
        self.log(f"[replays] pending {p['kind']}: {p['label']} (airs once the fight has been quiet "
                 f"{self.cfg['quiet_s']:g} s)")

    def on_attack_cut(self, alert, snap, now, framed=None):
        """The director just cut main to a fight, base attack, loss or death. framed: director.last_attack_framed,
        {t, how} when that cut put the fight in frame (an agent in it followed, or a fixed view on its position),
        None when it did not: a replay is the main camera's recording, so without the fight in frame there is
        nothing worth replaying (shake10: an announced turret fight replayed as the factory)."""
        if not alert or now - self.last_replay < self.cfg["spacing"]:
            return
        if alert["kind"] != "death":
            # the main camera is on this fight live from now: no replay of it (shake10: the same stretch aired again
            # while the battle went on). Its losses get loss clips, and side cameras' stretches side clips
            # (watch_fights), aired once it is over.
            return
        name = alert.get("agent")
        seen = any(name in agents for t, agents in self.main_seen if now - t <= self.cfg["seen_window"])
        if not name or not seen:
            return  # it died off camera: there is nothing in the buffer worth showing
        ag = next((a for a in snap.get("agents") or [] if a["name"] == name), {})
        with self.lock:
            p = {"kind": "death", "label": alert["text"], "agent": name, "position": ag.get("position"),
                 "agent_name": ag.get("display_name") or name, "save_at": now + self.cfg["death_save_after"],
                 "show_from": now - self.cfg["death_before"], "show_to": now + self.cfg["death_after"]}
            if self.pending:
                self.more_pending.append(p)  # saved after the one already pending (a death, a loss, a side clip)
                self.log(f"[replays] pending death (after {self.pending['label']}): {p['label']}")
                return
            self.pending = p
        self.log(f"[replays] pending death: {p['label']}")

    # ---- worker ------------------------------------------------------------------------------------------------
    def run(self):
        while True:
            try:
                self.work(time.time())
            except (OSError, OBSError) as e:
                self.status.update(connected=False, error=str(e)[:200])
                self.scene_ready = False
                time.sleep(5)
            except Exception as e:
                self.status["error"] = f"{type(e).__name__}: {e}"[:200]
                traceback.print_exc()
                time.sleep(2)
            time.sleep(0.5)

    def work(self, now):
        o = self.obs
        if not self.scene_ready:
            self.ensure_scene()
            self.scene_ready = True
            self.status.update(connected=True, error=None)
        if now >= self.next_stats:
            self.next_stats = now + self.cfg["stats_every"]
            self.read_stats()
        if not self.status["buffer_active"]:  # re-read every loop until it runs (it takes a moment to start)
            self.status["buffer_active"] = o.call("GetReplayBufferStatus").get("outputActive")
            if not self.status["buffer_active"] and now >= self.next_buffer_try:
                self.next_buffer_try = now + 60
                try:
                    o.call("StartReplayBuffer")
                    self.log("[replays] started the OBS replay buffer")
                except OBSError as e:
                    self.status["error"] = str(e)[:200]
        with self.lock:
            p = self.pending
        if p and now >= p["save_at"] and self.status["buffer_active"]:
            self.save(p, now)
        self.offer(now)
        self.follow_segment(now)

    def save(self, p, now):
        o = self.obs
        try:
            before = o.call("GetLastReplayBufferReplay").get("savedReplayPath")
        except OBSError:  # nothing saved yet this OBS session
            before = None
        saved_t = now  # the clip ends here (the worker's clock, within a second of SaveReplayBuffer)
        o.call("SaveReplayBuffer")
        path = None
        for _ in range(16):  # the file is written asynchronously; the reported path changes when it is done
            time.sleep(0.5)
            try:
                path = o.call("GetLastReplayBufferReplay").get("savedReplayPath")
            except OBSError:
                continue
            if path and path != before:
                time.sleep(0.5)  # let the muxer finish the file
                break
        with self.lock:
            self.pending = self.more_pending.popleft() if self.more_pending else None
            if not path or path == before:
                self.status["error"] = "SaveReplayBuffer produced no new file"
                return
            clip = dict(p, id=f"clip-{next(self.ids)}", path=path, saved_t=saved_t)
            if self.clip:
                self.more_clips.append(clip)  # plays after the one already waiting
            else:
                self.clip = clip
            self.status["replays"] += 1
        self.log(f"[replays] saved {path} for {p['label']}")

    def offer(self, now):
        """Ask segments.py to put the clip on air (bypassing segment spacing; still waits for a busy slot)."""
        c = self.clip
        if not c or self.playing:
            return
        if now - c["show_to"] > self.max_age(c):
            self.log(f"[replays] dropped {c['id']} (never got a free moment, or its fight never ended)")
            self.next_clip()
            return
        keep = self.battle_keep.get(c.get("battle")) if c.get("battle") else None
        if keep is not None and keep != c["battle_part"]:
            self.log(f"[replays] dropped {c['id']}: not the battle's replay ({c['battle_part']} window; keeping {keep})")
            self.next_clip()
            return
        if self.waiting(c, now):
            return  # never during the fight: once it has been quiet quiet_s
        cur = self.segments.cur
        if cur and cur["type"] == "attack_replay" and cur.get("clip") == c["id"]:
            return  # already queued or on air
        code, rep = self.segments.request({"type": "attack_replay", "by": "director", "reason": "replay",
                                           "seconds": c["show_to"] - c["show_from"]}, now, ignore_spacing=True)
        if code == 200:
            self.log(f"[replays] queued {c['id']} as {rep['id']}")
        elif rep.get("skip") and self.more_clips:  # routine (segments.replay_gate): not worth holding up the next one
            self.log(f"[replays] dropped {c['id']} ({rep.get('why')}): {c['label']}")
            self.next_clip()

    def next_clip(self):
        with self.lock:
            self.clip = self.more_clips.popleft() if self.more_clips else None

    def follow_segment(self, now):
        """Switch to the replay scene when the replay segment goes live; back to stream when it is over."""
        o = self.obs
        cur = self.segments.cur
        live = cur if cur and cur["type"] == "attack_replay" and cur["state"] in ("starting", "live") else None
        if live and live["state"] == "starting" and self.refreshed != live["id"]:
            self.refreshed = live["id"]
            try:  # reload the banner page 2.5 s ahead: a browser source that once failed to load stays blank
                o.call("PressInputPropertiesButton", {"inputName": self.cfg["banner"], "propertyName": "refreshnocache"})
            except OBSError as e:
                self.log(f"[replays] banner refresh failed: {e}")
        elif live and not self.playing and live["state"] == "live":
            c = self.clip
            # Nothing would air: its clip was dropped while the segment started (too old, or skipped for the one
            # behind it), or OBS keeps failing to play it. End the segment instead of holding the hosts on a replay
            # nobody sees for its whole length.
            why = ("its clip is gone" if not c or c["id"] != live.get("clip")
                   else "the replay did not start" if now - live["started"] > STARTING_S + self.cfg["play_timeout"] else None)
            if why:
                if self.segments.end(live["id"], why, now):
                    self.log(f"[replays] ended {live['id']}: {why}")
                return
            self.play(c)
            self.playing = c["id"]
            self.last_replay = now
            self.next_clip()
            self.status["last"] = {"id": c["id"], "label": c["label"], "t": now, "path": c["path"]}
        elif self.playing and not live:
            self.to_stream("replay over")
            self.playing = None
        elif not self.playing and now >= self.next_watch:  # watchdog: never leave the replay scene on air by itself
            self.next_watch = now + 5
            prog = o.call("GetCurrentProgramScene").get("currentProgramSceneName")
            self.status["program"] = prog
            if prog == self.cfg["scene"]:
                self.to_stream("watchdog")

    def play(self, c):
        o, m = self.obs, self.cfg["media"]
        o.call("SetInputSettings", {"inputName": m, "inputSettings": {"local_file": c["path"]}, "overlay": True})
        dur = None
        for _ in range(20):
            time.sleep(0.15)
            st = o.call("GetMediaInputStatus", {"inputName": m})
            if st.get("mediaDuration"):
                dur = st["mediaDuration"]
                break
        if dur:  # the clip ends at saved_t; start it show_from seconds back from there (both the Mac's time.time();
            # the file name's box-local time is never read)
            start = max(0, int(dur - (c["saved_t"] - c["show_from"]) * 1000))
            o.call("SetMediaInputCursor", {"inputName": m, "mediaCursor": start})
        o.call("TriggerMediaInputAction", {"inputName": m, "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_PLAY"})
        o.call("SetCurrentProgramScene", {"sceneName": self.cfg["scene"]})
        self.log(f"[replays] on air: {c['label']} ({c['path']}, from {start if dur else 0} ms of {dur} ms)")

    def to_stream(self, why):
        try:
            self.obs.call("SetCurrentProgramScene", {"sceneName": self.cfg["stream_scene"]})
            self.obs.call("TriggerMediaInputAction", {"inputName": self.cfg["media"],
                                                      "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP"})
        finally:
            self.log(f"[replays] back to {self.cfg['stream_scene']} ({why})")

    # ---- OBS setup and health ----------------------------------------------------------------------------------
    def ensure_scene(self):
        """The replay scene: clip (muted, full canvas), REPLAY banner page on top, the live overlay off-canvas so
        its voices stay in the mix. Created once; an existing scene is left as the operator arranged it."""
        o, c = self.obs, self.cfg
        scenes = [s["sceneName"] for s in o.call("GetSceneList")["scenes"]]
        if c["scene"] in scenes:
            return
        o.call("CreateScene", {"sceneName": c["scene"]})
        inputs = {i["inputName"] for i in o.call("GetInputList")["inputs"]}
        if c["media"] not in inputs:
            o.call("CreateInput", {"sceneName": c["scene"], "inputName": c["media"], "inputKind": "ffmpeg_source",
                                   "inputSettings": {"is_local_file": True, "local_file": "", "looping": False,
                                                     "restart_on_activate": False, "close_when_inactive": False,
                                                     "clear_on_media_end": False}})
        else:
            o.call("CreateSceneItem", {"sceneName": c["scene"], "sourceName": c["media"]})
        o.call("SetInputMute", {"inputName": c["media"], "inputMuted": True})  # its audio has the old voices in it
        if c["banner"] not in inputs:
            o.call("CreateInput", {"sceneName": c["scene"], "inputName": c["banner"], "inputKind": "browser_source",
                                   "inputSettings": {"url": self.overlay_url, "width": 1920, "height": 1080, "fps": 30,
                                                     "fps_custom": True, "css": "", "shutdown": False,
                                                     "restart_when_active": False}})
        else:
            o.call("CreateSceneItem", {"sceneName": c["scene"], "sourceName": c["banner"]})
        if c["overlay_input"] in inputs:
            item = o.call("CreateSceneItem", {"sceneName": c["scene"], "sourceName": c["overlay_input"]})["sceneItemId"]
            o.call("SetSceneItemTransform", {"sceneName": c["scene"], "sceneItemId": item,
                                             "sceneItemTransform": {"positionX": 4000.0, "positionY": 0.0}})
        self.log(f"[replays] created OBS scene {c['scene']!r}")

    def read_stats(self):
        """Encoder health while stream + recording + buffer run: skipped frames since the last read."""
        o = self.obs
        st = o.call("GetStats")
        outs = {}
        for req in ("GetStreamStatus", "GetRecordStatus"):
            try:
                outs[req[3:-6].lower()] = o.call(req).get("outputActive")
            except OBSError:
                pass
        self.status["buffer_active"] = o.call("GetReplayBufferStatus").get("outputActive")
        cur = {k: st.get(k) for k in ("renderSkippedFrames", "renderTotalFrames", "outputSkippedFrames",
                                       "outputTotalFrames")}
        prev, self.prev_stats = self.prev_stats, cur
        delta = {k: cur[k] - prev[k] for k in cur if prev and cur[k] is not None and prev.get(k) is not None}
        self.status["stats"] = {"cpu": round(st.get("cpuUsage") or 0, 1), "fps": round(st.get("activeFps") or 0, 1),
                                "render_ms": round(st.get("averageFrameRenderTime") or 0, 2),
                                "skipped_since_last": delta, "outputs": dict(outs, replay_buffer=self.status["buffer_active"]),
                                "t": time.time()}

    def public(self):
        s = dict(self.status)
        s.update(pending=self.pending and {k: self.pending[k] for k in ("kind", "label")},
                 clip=self.clip and {k: self.clip[k] for k in ("id", "label", "path")}, playing=self.playing,
                 waiting=[c["label"] for c in list(self.more_pending) + list(self.more_clips)])
        return s
