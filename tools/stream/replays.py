"""Instant replays from the OBS replay buffer (operator go-ahead in REPLAYS.md; docs/STREAM-NOTES.md "Replays").

Factorio cannot rewind in multiplayer, so the replay is OBS's: the replay buffer keeps the last ~45 s of the program
output (all three cameras). A replay shows what a camera recorded and what the main camera's viewers did not just
watch (shake10: the main camera showed a fight live, then the replay aired that same stretch while the battle went on):

  - never during the fight: a clip about a fight waits until that fight (model.py `fights`) has been quiet 20 s
    (`quiet_s`); a death clip waits while any fight within 40 tiles goes on;
  - a fight the main camera showed live gets no replay of it (main covered most of the window, `main_frac`);
  - a loss (something destroyed) or a death: aired only if it was on air when it happened, and the clip is that
    moment. The moment is the event's wall time: a loss's game tick (the incident's last_tick) through the (tick_t,
    tick) samples of the snapshots, else the alert's time less `loss_lag` (a death: the tick of the loss of its
    character, else the alert less `death_lag`). On air: the spot (a dead agent: its character, followed or inside the
    frame) inside the frame of the camera on air for at least `onair_min_s` of the `onair_before` s before the moment
    ("shown" is geometry: cams["main"]["frame"], director.in_frame, the client's view at its zoom after the on-air
    crop; in a trio the big tile; never the inset or a small tile, since the replay is the whole program; not the
    first `cut_settle` s after a cut), sampled every tick into the timeline `frames`; never while a replay is on air
    (the program is the replay then). Otherwise no replay, logged "not on air at the time". The clip runs from
    `clip_before` s before the moment to `clip_after` s after it, saved once that is over, aired after the fight
    ends. shift09 00:40: Sol died on Gleba on air; the loss alert of his character was clipped from the urgent cut 4 s
    later (the longest stretch of footage of the spot: all aftermath) and aired as a second replay (viewer awoo3391:
    "the one we just saw didnt actually capture the death at all"). shift01: a loss 20 tiles from Sol counted as
    shown; the program had Sol in the base and the fight was 35 tiles north, off frame. Several losses of one fight
    within one clip's stretch get one clip;
  - one replay per moment: a loss key (the incident) has one clip; a re-report of the same loss (the alert comes back
    after its 90 s ttl, with the same tick) is no new moment; a later moment of the same incident replaces the clip
    still waiting only if it was on air longer, and never once one aired. A death and the loss of that agent's
    character (only characters lost, within `same_near` tiles and `same_s` s) are one moment: the death's clip;
  - a fight only a side camera showed: that camera's stretch of it (at least `side_min_s`, at most `fight_show`) is
    saved while it is in the buffer and aired after the fight ends. No camera on it: no replay;
  - death: as a loss, the dead agent's character being the spot.

The clip plays as an `attack_replay` segment (segments.py), so the casters see it and talk over it: on "live" the
program scene switches to the "replay" scene (the clip, muted, under a REPLAY banner page; the stream overlay rides
along off-canvas so the casters' voices keep playing), and when the segment ends or is cut the program goes back to
"stream". A watchdog returns to "stream" whenever "replay" is on air without a replay playing.

(d28 batch326 RA, viewer Aurora site:5417: "game-only replay audio, recorded separately from speech, ... duck it
gently under current voices. For old or missing clean tracks, retain quiet live game ambience with the mixed clip
muted. Preserve the full archive mix and keep replay playback out of the clean track.") OBS records two tracks (the
operator's settings, docs/STREAM-NOTES.md): track 1 the full mix (stream, archive, unchanged), track 2 the game audio
alone, from its own capture of the camera client ("stream game clean": not ducked under the voices, so the track has no
dips where a voice spoke). A saved clip gets a game-only companion (`clean`): its video and second audio track
copied, not re-encoded, by ffmpeg on the box (`remux`), "...-game.mkv" beside it. On air:
  - a clip with its clean companion, at full speed, with no speaker alarm audible in its window (alarmquiet.py): the
    companion plays with its sound ("replay clip" unmuted; its "duck under voices" filter keeps it under the live
    voices), the ambience off;
  - otherwise (an old clip, no second track, a slow-motion clip, an alarm in its window): the mixed clip plays muted
    over "replay game ambience" (a live capture of the game at a quiet level, ducked too), so nothing is doubled and
    no recorded voice or siren comes back;
  - back on "stream" (the segment's end, a cut, the watchdog, a restart): the clip muted and the ambience off again;
    the live game audio itself is never touched, so its level is as it was.
Only "stream game clean" is on track 2; "replay clip" and "replay game ambience" are on track 1 alone: replay playback
never feeds the clean track.
"""
import itertools, json, re, subprocess, threading, time, traceback
from collections import deque

from alarmquiet import AlarmQuiet
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
    "onair_before": 15.0,          # a loss or death airs only if its spot was on air in the 15 s before it ...
    "onair_min_s": 3.0,            # ... for at least this long
    "clip_before": 8.0,            # its clip: from this long before the moment ...
    "clip_after": 3.0,             # ... to this long after it
    "loss_merge": 30.0,            # tiles: a loss this close to one already clipped, inside its stretch, adds no clip
    "frame_edge": 2.0,             # tiles: a spot this close to a frame's border does not count as shown
    "loss_lag": 2.0,               # a loss alert arrives about this long after the loss (status poll), without a tick
    "death_lag": 1.0,              # a death is seen at the status poll after it, without its character loss's tick
    "same_s": 20.0,                # a death and its character's loss this close in time ...
    "same_near": 40.0,             # ... and place (tiles) are one moment
    "fight_max_age": 300.0,        # a clip waiting for its fight to end is dropped after this long
    "spacing": 120.0,              # at most one replay this often
    "max_age": 120.0,              # a clip not played within this long is dropped
    "stats_every": 30.0,
    "play_timeout": 8.0,           # a replay segment live this long with the clip not on air is ended
    # (d28 batch326 RA) game-only replay audio (module doc)
    "clean_audio": True,
    "clean_track": 1,              # the file's second audio stream (OBS track 2: game audio only)
    "ambience": "replay game ambience",  # a quiet live game capture in the replay scene, for clips without one
    "remux_host": "pogwin",        # ffmpeg runs where OBS wrote the clip
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
    # slow motion (Nick, 14:44: "the demolisher fight was like 5s long, very dramatic though! imagine a slow-mo instant
    # replay"): a big-enemy battle or one with a sudden big loss gets its decisive seconds slowed down, even if seen live
    "battle_grace": 15.0,          # a battle is judged this long after it ends (its next wave may resume it)
    "slowmo": True,
    "slow_speed": 45,              # percent (OBS media source speed_percent)
    "slow_peak_s": 5.0,            # the densest stretch of losses this long is the decisive moment ...
    "slow_before": 3.0,            # ... the clip from this long before it ...
    "slow_after": 5.0,             # ... to this long after its start
    "slow_sudden": 0.4,            # a sudden big loss: that stretch holds this share of the battle's pieces lost ...
    "slow_min_pieces": 5,          # ... and at least this many
    "slow_cover": 0.7,             # on-air footage of the battle must cover this share of the window
    "battle_gap": 2.5,             # seconds: footage samples further apart than this are separate runs
    # (d28 batch312 C, viewer Aurora 10:50: "Could highlights also celebrate clever repairs, successful deliveries and
    # funny real team exchanges? Save short clips from footage actually captured, link them to the later result, and
    # let the hosts explain the payoff. ... clear REPLAY labels, limited repetition and urgent-event interruption.
    # Please start with one engineering highlight using the current one-client setup.") An engineering highlight: a
    # build's close-up on the main camera (onecam work_close, batch312 A) on air highlight_min_s is saved from the
    # buffer (highlight_len from its start, less if the shot ended sooner) and kept; when a later story result on that
    # ship passes (stories.py, batch312 B) within highlight_keep, it airs as a replay labelled "Highlight", with the
    # result as its payoff for the hosts. At most one highlight per highlight_gap, each once; a replay's urgent cut,
    # spacing and news gates as for any replay.
    "highlight": True,
    "highlight_min_s": 6.0,
    "highlight_before": 1.0,
    "highlight_len": 12.0,
    "highlight_keep": 10800.0,
    "highlight_gap": 1200.0,
}


class Replays:
    def __init__(self, segments, overlay_url="http://127.0.0.1:8787/replay", obs=None, log=print, start=True, remux=None,
                 alarm=None, **cfg):
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
        self.ticks = deque(maxlen=240)     # (wall time, game tick) as the snapshots read them: a tick's wall time
        self.moments = deque(maxlen=32)    # losses and deaths with a clip: one replay per moment (module doc)
        self.mids = itertools.count(1)
        self.status = {"enabled": True, "connected": False, "buffer_active": None, "error": None, "stats": None,
                       "replays": 0, "last": None, "program": None}
        self.prev_stats = None
        self.next_stats = 0
        # (batch326 RA) clip path -> its game-only companion, or (None, why): "box" (serve.py) runs ffmpeg on the box;
        # by default none (a test's stand-in OBS never reaches the box)
        self.remux = self.remux_on_box if remux == "box" else remux or (lambda path: (None, "no remux here"))
        self.alarm = alarm or AlarmQuiet(log=log)  # (batch326 RA2) speaker alarms quiet on air
        self.audio_reset = False  # (RA) the replay scene's audio set back once after a start (a restart mid-replay)
        self.next_buffer_try = 0
        self.scene_ready = False
        self.next_watch = 0
        self.refreshed = None  # segment id whose banner page was reloaded
        self.hold = False      # serve.py: an operator follow is on; no replay cuts away from it
        self.ending = None     # a battle just over, judged after battle_grace (the director may resume it)
        self.battle = None     # the key battle being covered: {key, info, shown: [t], parts: {part: score}, ...}
        self.battle_keep = {}  # battle key -> the part to air ("start" / "end"), or "none", once it is over
        self.battle_areas = deque(maxlen=8)  # (until, position+surface, extent): losses there are the battle's
        self.hl_on = None                    # (batch312 C) the build close-up on air: {key, platform, ..., pending}
        self.hl_saved = deque(maxlen=4)      # saved build clips waiting for their ship's result
        self.hl_results = set()              # story result keys looked at
        self.hl_aired = -1e9                 # when the last highlight was queued to air
        if start:  # selftest drives work() by hand
            threading.Thread(target=self.run, daemon=True).start()

    # ---- availability for segments.py --------------------------------------------------------------------------
    def why(self, now=None):
        now = now or time.time()
        if not self.status["connected"]:
            return "OBS not connected" + (f" ({self.status['error']})" if self.status["error"] else "")
        if not self.status["buffer_active"]:
            return "OBS replay buffer not running"
        if not self.clip or now - self.clip.get("queued_t", self.clip["show_to"]) > self.max_age(self.clip):
            return "no fresh clip (one is saved after a death on the main camera, a loss, or a fight a side camera showed)"
        if self.waiting(self.clip, now):
            return "the fight is still going on (a replay airs once it has been quiet 20 s)"
        return None

    def max_age(self, c):
        if c.get("kind") == "highlight":
            return 600.0  # from when its result queued it: a free moment within 10 min
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
        out = {"event": c["label"], "kind": c["kind"], "agent": c.get("agent_name"),
               "seconds": round(c["show_to"] - c["show_from"]), "ago_s": round(now - c["show_to"]),
               "speed": c.get("speed") or 100}  # (the banner: "Replay · slow motion" under 100)
        if c.get("kind") == "highlight":  # (batch312 C) what the clip shows, and the result it led to
            out.update(highlight=c.get("built"), payoff=c.get("payoff"), result=c.get("verdict"), platform=c.get("platform"))
        return out, c["id"]

    # ---- hooks from serve.py's ticker ---------------------------------------------------------------------------
    def tick(self, snap, cams, now):
        main = (cams or {}).get("main") or {}
        self.main_seen.append((now, list(main.get("agents") or [])))
        if isinstance(snap.get("tick"), (int, float)) and (not self.ticks or snap["tick"] != self.ticks[-1][1]):
            self.ticks.append((snap.get("tick_t") or now, snap["tick"]))
        self.fights = {f["key"]: f for f in snap.get("fights") or []}
        if not self.playing:  # while a replay is on air the program is the replay, not the cameras
            by_name = {a["name"]: {k: a.get(k) for k in ("position", "surface")} for a in snap.get("agents") or []}
            self.frames.append((now, {s: dict(c) for s, c in (cams or {}).items()}, by_name))
        self.alarm.decide(snap.get("speaker_alarms"), now)
        self.watch_fights(snap, cams or {}, now)
        self.watch_battle(snap.get("battle"), snap, cams or {}, now)
        self.judge_losses(now)
        if self.cfg["highlight"]:
            self.watch_highlights(snap, cams or {}, now)

    def watch_highlights(self, snap, cams, now):
        """(d28 batch312 C) A build's close-up on air highlight_min_s: its clip is saved and kept (save: hl_saved). A
        story result that passed on that ship later (snapshot `stories`) puts the latest such clip on air as a
        highlight, at most once per highlight_gap; each clip and each result once."""
        cfg = self.cfg
        wc = ((cams or {}).get("main") or {}).get("work_close")
        on = self.hl_on
        if on and (not wc or (wc["platform"], wc["since"]) != on["key"]):
            p = on.get("pending")
            if p and now < p["show_to"]:  # the shot ended sooner: the clip ends with it
                p["show_to"], p["save_at"] = now, now + 1.0
            self.hl_on = on = None
        if wc and not self.playing:
            if on is None:
                self.hl_on = on = {"key": (wc["platform"], wc["since"]), "platform": wc["platform"], "agent": wc.get("agent"),
                                   "since": wc["since"], "label": ((cams.get("main") or {}).get("work") or wc["platform"])}
            if not on.get("pending") and now - on["since"] >= cfg["highlight_min_s"]:
                start = on["since"] - cfg["highlight_before"]
                p = {"kind": "highlight", "label": on["label"], "agent": on["agent"], "platform": on["platform"],
                     "show_from": start, "show_to": start + cfg["highlight_len"], "save_at": start + cfg["highlight_len"] + 1.0}
                on["pending"] = p
                with self.lock:  # saved when its time comes, kept (not aired) until its result
                    if self.pending is None:
                        self.pending = p
                    else:
                        self.more_pending.append(p)
                self.log(f"[replays] highlight footage: {on['label']} (saved, kept for its ship's result)")
        for b in snap.get("stories") or []:
            if b.get("beat") != "result" or b.get("key") in self.hl_results:
                continue
            self.hl_results.add(b["key"])
            if b.get("verdict") != "passed":
                continue
            ready = [c for c in self.hl_saved if c.get("platform") == b.get("platform") and c["saved_t"] <= b.get("t", now)
                     and now - c["saved_t"] <= cfg["highlight_keep"]]
            if not ready:
                continue
            if now - self.hl_aired < cfg["highlight_gap"]:
                self.log(f"[replays] highlight not aired ({b.get('caption')}): one aired less than "
                         f"{cfg['highlight_gap'] / 60:g} min ago")
                continue
            c = ready[-1]
            self.hl_saved.remove(c)
            clip = dict(c, built=c["label"], payoff=b.get("caption"), verdict=b.get("verdict"), queued_t=now,
                        label=f"Highlight: {c['label']}, then {b.get('caption')}")
            with self.lock:
                if self.clip:
                    self.more_clips.append(clip)
                else:
                    self.clip = clip
            self.hl_aired = now
            self.log(f"[replays] highlight queued: {clip['label']}")

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
            ticks = f.get("loss_ticks") or []
            for i, lt in enumerate(f.get("losses") or []):
                if lt in c["losses_done"]:
                    continue
                c["losses_done"].add(lt)
                self.loss_wait.append({"key": key, "t_alert": lt, "tick": ticks[i] if i < len(ticks) else None,
                                       "text": f.get("text"), "position": f.get("position"),
                                       "fight": key if f.get("kind") != "loss" else None})
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
            # over (or another battle): judged after battle_grace, unless the director resumes it (its next wave)
            self.battle, self.ending = None, b
            b["ended"] = now
            b = None
        e = self.ending
        if e and (now - e["ended"] >= cfg["battle_grace"] or (info and info["key"] != e["key"])):
            self.battle, self.ending = e, None
            self.finish_battle(now)
            e = None
        if not info:
            return
        if not b and e and info["key"] == e["key"]:
            b, self.battle, self.ending = e, e, None  # resumed: the same battle
            b["gap"] = b.get("gap", 0) + now - e["ended"]  # (the lull is no part of it the program missed)
            self.log(f"[replays] battle resumed after {now - e['ended']:.0f} s ({e['key']})")
        if not b:
            b = self.battle = {"key": info["key"], "info": info, "shown": [], "saved": None, "why": None,
                               "pieces": {}, "losses": [], "tier": 0, "slow": None, "slow_n": 0}
        b["info"] = info
        self.watch_losses(b, snap, now)
        by_name = {a["name"]: {k: a.get(k) for k in ("position", "surface")} for a in snap.get("agents") or []}
        main = (cams or {}).get("main") or {}
        # a cut is decided here a tick or two before OBS shows it (cuts.py): the first cut_settle s after it are the
        # camera before (13:35's replay opened on "unrelated base capture")
        settled = now - (main.get("since") or 0) >= cfg["cut_settle"]
        if not self.playing and settled and self.shows_battle(main, info, by_name):
            b["shown"].append(now)
        if not b["saved"] and not b["why"] and now >= info["first"] - cfg["battle_lead"] + self.battle_len(info):
            self.judge_start(b, now)
        self.judge_slow(b, now)

    def watch_losses(self, b, snap, now):
        """The battle's losses as they come in (each loss entry's pieces count up through a raid: the rise is what
        was destroyed then, about loss_lag before the alert), and the enemy's tier from the alert texts."""
        from threats import tier_of
        from onecam import loss_pieces
        info, q = b["info"], b["info"]["position"]
        for f in snap.get("fights") or []:
            p = f.get("position") or {}
            if p.get("x") is None or (p.get("surface") or "nauvis") != q.get("surface", "nauvis") or \
                    ((p["x"] - q["x"]) ** 2 + (p["y"] - q["y"]) ** 2) ** 0.5 > (info.get("extent") or 0) / 2 + 60:
                continue
            b["tier"] = max(b["tier"], tier_of(f.get("text")))
            # live.py's loss alerts carry the raid's running total (19, 44, 55 ... at new positions, new keys):
            # what was destroyed is the rise of the battle's highest count
            n = loss_pieces(f.get("text"))
            before = b["pieces"].get("max", 0)
            if n > before:
                b["losses"].append((now - self.cfg["loss_lag"], n - before))
                b["pieces"]["max"] = n

    def peak(self, b):
        """-> (start of the densest slow_peak_s of losses, pieces in it), or None."""
        w, best = self.cfg["slow_peak_s"], None
        for t, _ in b["losses"]:
            n = sum(d for u, d in b["losses"] if t <= u <= t + w)
            if best is None or n > best[1]:
                best = (t, n)
        return best

    def slow_worthy(self, b):
        """A big-enemy battle (behemoths, demolishers, a nest assault) or a sudden big loss (module doc)."""
        pk = self.peak(b)
        if not pk:
            return None
        total = sum(d for _, d in b["losses"])
        text = (b["info"].get("label") or "") + " " + str(b["info"].get("why") or "")
        if b["tier"] >= 4 or "spawner" in text or "nest" in text:
            return "big enemy"
        if pk[1] >= max(self.cfg["slow_min_pieces"], self.cfg["slow_sudden"] * total):
            return f"sudden loss ({pk[1]} of {total} pieces in {self.cfg['slow_peak_s']:g} s)"
        return None

    def judge_slow(self, b, now):
        """Once the decisive window is over (and while it is still in the buffer), save it if the program's footage
        of the battle covers it; a later, denser stretch saves again (the best one airs)."""
        cfg = self.cfg
        if not cfg["slowmo"]:
            return
        pk = self.peak(b)
        if not pk or (b["slow"] and pk[1] <= b["slow"]["pieces"]):
            return
        start, end = pk[0] - cfg["slow_before"], pk[0] + cfg["slow_after"]
        if now < end + 1 or now - start > cfg["buffer_s"] - 2:
            return
        if b.get("slow_tried") == pk:
            return
        b["slow_tried"] = pk
        covered = sum(r[1] - r[0] + 1 for r in self.runs(b["shown"], start, end))
        if covered < cfg["slow_cover"] * (end - start):
            self.log(f"[replays] battle slow motion: no footage of its decisive moment ({covered:.0f} s of "
                     f"{end - start:.0f} s on air) ({b['key']})")
            return
        b["slow_n"] += 1
        part = f"slow{b['slow_n']}"
        b["slow"] = {"part": part, "pieces": pk[1], "start": start, "end": end}
        info = b["info"]
        self.queue_pending({"kind": "battle", "label": info.get("label") or "Battle", "battle": b["key"],
                            "battle_part": part, "speed": cfg["slow_speed"], "agent": None,
                            "agent_name": info.get("agent"), "position": info["position"], "save_at": now,
                            "show_from": start, "show_to": end})
        self.log(f"[replays] battle slow motion saved: {end - start:.0f} s around {pk[1]} pieces lost in "
                 f"{cfg['slow_peak_s']:g} s ({b['key']}, {covered:.0f} s on air)")

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
        span = max(1.0, info["last"] - info["first"] - b.get("gap", 0))
        live = sum(r[1] - r[0] + 1 for r in self.runs(b["shown"], info["first"], info["last"] + 1))
        worthy = self.slow_worthy(b) if b.get("slow") else None
        if worthy and now - self.last_replay < self.cfg["spacing"]:
            worthy = None  # the replay budget: one replay per spacing
        if worthy:
            keep, why = b["slow"]["part"], f"slow motion of its decisive moment: {worthy}"
        elif not b["saved"]:
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

    # ---- the on-air timeline and the moment of an event --------------------------------------------------------
    def wall_of(self, tick):
        """A game tick's wall time from the (wall time, tick) samples, 60 ticks a second between them; None without."""
        if not self.ticks or not isinstance(tick, (int, float)):
            return None
        after = next((i for i, (_, k) in enumerate(self.ticks) if k >= tick), None)
        if after is None:
            t, k = self.ticks[-1]
            return t + (tick - k) / 60.0
        t1, k1 = self.ticks[after]
        if after == 0 or k1 == tick:
            return t1 - (k1 - tick) / 60.0
        t0, k0 = self.ticks[after - 1]
        return t0 + (t1 - t0) * (tick - k0) / (k1 - k0)

    def loss_time(self, w):
        """-> (wall time of a loss, how): its tick when that maps to a time up to 5 minutes before its alert (an old
        incident re-reported keeps its tick), else the alert less loss_lag."""
        t = self.wall_of(w.get("tick"))
        if t is not None and w["t_alert"] - 300 <= t <= w["t_alert"] + 1:
            return t, "tick"
        return w["t_alert"] - self.cfg["loss_lag"], "alert"

    def spot_shown(self, cam, spot, by_name):
        """Does this camera row show the spot: {"agent": name} (followed, or its character inside the frame), or a
        position (shows)."""
        if not spot.get("agent"):
            return self.shows("main", cam, spot, by_name)
        name, fr = spot["agent"], cam.get("frame")
        if fr and fr.get("follow") == name:
            return True
        if fr:
            a = by_name.get(name) or {}
            point = dict(a["position"], surface=a.get("surface") or "nauvis") if a.get("position") else spot.get("position")
            return in_frame(fr, point, by_name, self.cfg["frame_edge"])
        return name in (cam.get("agents") or [])  # a row without a frame (older directors): it follows the agent

    def onair_s(self, spot, lo, hi):
        """-> (seconds the main view showed the spot in [lo, hi], seconds only a small view did): the timeline's
        samples, the first cut_settle s after a cut not counted (the program still shows the camera before)."""
        times, main_n, small_n = [], 0, 0
        for t, rows, by_name in self.frames:
            if not lo <= t <= hi:
                continue
            times.append(t)
            main = rows.get("main") or {}
            if t - (main.get("since") or 0) >= self.cfg["cut_settle"] and self.spot_shown(main, spot, by_name):
                main_n += 1
            elif any(self.spot_shown(r, spot, by_name) for k, r in rows.items() if k != "main"):
                small_n += 1
        gaps = sorted(b - a for a, b in zip(times, times[1:]) if b > a)
        dt = min(self.cfg["battle_gap"], gaps[len(gaps) // 2]) if gaps else 1.0
        return main_n * dt, small_n * dt

    def not_on_air(self, seen, small):
        return (f"not on air at the time ({seen:.0f} s of the {self.cfg['onair_before']:g} s before it"
                + (f"; {small:.0f} s only in the inset or a small tile" if small else "") + ")")

    # ---- one replay per moment ---------------------------------------------------------------------------------
    @staticmethod
    def characters_only(text):
        """'1 lost on Gleba near (264, 25): 1 character (by small wriggler pentapod prematures)' -> True."""
        what = (text or "").split(": ", 1)[1] if ": " in (text or "") else ""
        what = what.split(" (by ", 1)[0]
        parts = [x.strip() for x in what.split(",") if x.strip()]
        return bool(parts) and all(re.fullmatch(r"\d+ characters?", x) for x in parts)

    def same_place(self, m, t, position):
        p, q = position or {}, m.get("position") or {}
        if p.get("x") is None or q.get("x") is None or (p.get("surface") or "nauvis") != (q.get("surface") or "nauvis"):
            return False
        return abs(m["t"] - t) <= self.cfg["same_s"] and \
            ((p["x"] - q["x"]) ** 2 + (p["y"] - q["y"]) ** 2) ** 0.5 <= self.cfg["same_near"]

    def drop_ref(self, mid):
        """Take a moment's clip out of the queues (pending or saved, not on air)."""
        with self.lock:
            if self.pending and self.pending.get("mid") == mid:
                self.pending = self.more_pending.popleft() if self.more_pending else None
            self.more_pending = deque((x for x in self.more_pending if x.get("mid") != mid), maxlen=4)
            if self.clip and self.clip.get("mid") == mid:
                self.clip = self.more_clips.popleft() if self.more_clips else None
            self.more_clips = deque((x for x in self.more_clips if x.get("mid") != mid), maxlen=4)

    def moment(self, kind, key, t, position, seen, label, agent=None):
        """Register a loss or death about to get a clip -> its id, or None (logged) when it is one already clipped:
        the same loss again, a moment already aired, or one whose waiting clip was on air as long or longer."""
        char = kind == "loss" and self.characters_only(label)
        for m in self.moments:
            if m["state"] == "dropped":
                continue
            same_key = m["key"] == key
            death_pair = (char and m["kind"] == "death") or (kind == "death" and m.get("char"))
            if not (same_key or (death_pair and self.same_place(m, t, position))):
                continue
            if same_key and abs(m["t"] - t) < 1.0:
                self.log(f"[replays] skipped {kind}: the same moment reported again ({label})")
                return None
            if m["state"] == "aired":
                self.log(f"[replays] skipped {kind}: a replay of {m['label']} already aired ({label})")
                return None
            if kind == "death" and m["kind"] == "loss":
                why = "the death's replay replaces its character loss's"
            elif m["kind"] == "death":
                self.log(f"[replays] skipped {kind}: the death replay of {m['label']} covers it ({label})")
                return None
            elif seen > m["seen"] + 0.5:
                why = f"on air {seen:.0f} s before it, the waiting clip {m['seen']:.0f} s"
            else:
                self.log(f"[replays] skipped {kind}: the waiting clip of the same loss was on air as long or longer "
                         f"({m['seen']:.0f} s vs {seen:.0f} s) ({label})")
                return None
            m["state"] = "dropped"
            self.drop_ref(m["mid"])
            self.log(f"[replays] replaced the waiting clip of {m['label']}: {why}")
        mid = f"m{next(self.mids)}"
        self.moments.append({"mid": mid, "kind": kind, "key": key, "t": t, "position": position, "seen": seen,
                             "label": label, "agent": agent, "char": char, "state": "pending"})
        return mid

    def judge_losses(self, now):
        """A loss gets a clip of its moment if its spot was on air just before it (module doc)."""
        cfg = self.cfg
        for w in list(self.loss_wait):
            t, how = self.loss_time(w)
            if now < t + cfg["clip_after"] + 1:
                continue
            self.loss_wait.remove(w)
            label, p = w["text"] or "Loss", w["position"] or {}
            if self.in_battle_area(p, now):
                self.log(f"[replays] skipped loss: part of the key battle's replay ({label})")
                continue
            start, end = t - cfg["clip_before"], t + cfg["clip_after"]
            if now - start > cfg["buffer_s"] - 2:  # (an old incident re-reported: its tick is minutes back)
                self.log(f"[replays] skipped loss: its moment has left the replay buffer ({label})")
                continue
            seen, small = self.onair_s({"key": w["key"], "position": p}, t - cfg["onair_before"], t)
            if seen < cfg["onair_min_s"]:
                self.log(f"[replays] skipped loss: {self.not_on_air(seen, small)} ({label})")
                continue
            dup = next((c for c in self.loss_clips if start < c[1] and c[2] and p and
                        ((c[2]["x"] - p["x"]) ** 2 + (c[2]["y"] - p["y"]) ** 2) ** 0.5 <= cfg["loss_merge"]), None)
            if dup:
                self.log(f"[replays] skipped loss: inside the clip of the same fight already queued ({label})")
                continue
            mid = self.moment("loss", w["key"], t, p, seen, label)
            if not mid:
                continue
            self.loss_clips.append((start, end, p))
            # waits on the attacks around it (position), not on the loss alert, which stays up ~2 minutes
            self.queue_pending({"kind": "loss", "label": label, "fight": w["fight"], "agent": None, "agent_name": None,
                                "position": w["position"], "save_at": now, "show_from": start, "show_to": end,
                                "mid": mid, "moment": f"{time.strftime('%H:%M:%S', time.localtime(t))} ({how}), "
                                                      f"{seen:.0f} s on air before it"})

    def queue_pending(self, p):
        with self.lock:
            if self.pending is None:
                self.pending = p
            else:
                self.more_pending.append(p)
        self.log(f"[replays] pending {p['kind']}: {p['label']} (airs once the fight has been quiet "
                 f"{self.cfg['quiet_s']:g} s{'; moment ' + p['moment'] if p.get('moment') else ''})")

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
        if not name:
            return
        cfg = self.cfg
        t, how = self.death_time(name, snap, alert.get("t") or now)
        seen, small = self.onair_s({"agent": name}, t - cfg["onair_before"], t)
        if seen < cfg["onair_min_s"]:
            self.log(f"[replays] skipped death: {self.not_on_air(seen, small)} ({alert['text']})")
            return
        ag = next((a for a in snap.get("agents") or [] if a["name"] == name), {})
        pos = self.last_position(name, t) or (dict(ag["position"], surface=ag.get("surface") or "nauvis")
                                              if ag.get("position") else None)
        mid = self.moment("death", f"death:{name}:{int(t)}", t, pos, seen, alert["text"], agent=name)
        if not mid:
            return
        with self.lock:
            p = {"kind": "death", "label": alert["text"], "agent": name, "position": pos,
                 "agent_name": ag.get("display_name") or name, "save_at": max(now, t + cfg["clip_after"] + 1),
                 "show_from": t - cfg["clip_before"], "show_to": t + cfg["clip_after"], "mid": mid,
                 "moment": f"{time.strftime('%H:%M:%S', time.localtime(t))} ({how}), {seen:.0f} s on air before it"}
            if self.pending:
                self.more_pending.append(p)  # saved after the one already pending (a death, a loss, a side clip)
                self.log(f"[replays] pending death (after {self.pending['label']}): {p['label']}; moment {p['moment']}")
                return
            self.pending = p
        self.log(f"[replays] pending death: {p['label']}; moment {p['moment']}")

    def last_position(self, name, t):
        """Where an agent's character stood at the last sample up to t (a dead agent's row may already be its
        respawn)."""
        for ft, _, by_name in reversed(self.frames):
            a = by_name.get(name) or {}
            if ft <= t and a.get("position"):
                return dict(a["position"], surface=a.get("surface") or "nauvis")
        return None

    def death_time(self, name, snap, t_alert):
        """-> (wall time of a death, how): the tick of the loss of a character where the agent last stood (the
        harness reports the death as an incident too), else the alert less death_lag."""
        here = self.last_position(name, t_alert)
        best = None
        for f in snap.get("fights") or []:
            if f.get("kind") != "loss" or not self.characters_only(f.get("text")) or not here:
                continue
            q = f.get("position") or {}
            if (q.get("surface") or "nauvis") != here["surface"] or q.get("x") is None or \
                    ((q["x"] - here["x"]) ** 2 + (q["y"] - here["y"]) ** 2) ** 0.5 > self.cfg["same_near"]:
                continue
            for tick in f.get("loss_ticks") or []:
                t = self.wall_of(tick)
                if t is not None and t_alert - 60 <= t <= t_alert + 1 and (best is None or t > best):
                    best = t
        if best is not None:
            return best, "tick"
        return t_alert - self.cfg["death_lag"], "alert"

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
        try:
            self.alarm.apply(o.call)  # (RA2) the alarm gains on the game audio, as decided
        except Exception as e:
            self.status["error"] = f"alarm gains: {str(e)[:160]}"
        if not self.audio_reset and not self.playing:
            self.audio_reset = True
            self.replay_audio(None)  # (RA) a start: the clip muted and the ambience off, whatever a crash left
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
        with self.lock:
            if clip.get("kind") == "highlight":  # (batch312 C) kept until its ship's result (watch_highlights)
                self.hl_saved.append(clip)
                self.status["replays"] += 1
                self.log(f"[replays] saved {path} for {p['label']} (a highlight: waits for its result)")
                return
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
        if now - c.get("queued_t", c["show_to"]) > self.max_age(c):  # (a highlight: from its result)
            self.log(f"[replays] dropped {c['id']} (never got a free moment, or its fight never ended)")
            self.next_clip()
            return
        keep = self.battle_keep.get(c.get("battle")) if c.get("battle") else None
        if keep is not None and keep != c["battle_part"]:
            self.log(f"[replays] dropped {c['id']}: not the battle's replay ({c['battle_part']} window; keeping {keep})")
            self.next_clip()
            return
        if self.hold:
            return  # an operator follow is on (serve.py): the replay airs once it ends
        if self.waiting(c, now):
            return  # never during the fight: once it has been quiet quiet_s
        cur = self.segments.cur
        if cur and cur["type"] == "attack_replay" and cur.get("clip") == c["id"]:
            return  # already queued or on air
        code, rep = self.segments.request({"type": "attack_replay", "by": "director", "reason": "replay",
                                           # a slowed clip plays longer: its seconds at speed
                                           "seconds": (c["show_to"] - c["show_from"]) * 100.0 / (c.get("speed") or 100)},
                                          now, ignore_spacing=True)
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
            c = self.clip
            if c and c["id"] == live.get("clip"):
                self.prepare_audio(c)  # (RA) its game-only companion while the segment starts
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
            for m in self.moments:  # one replay per moment: none of this one again
                if c.get("mid") and m["mid"] == c["mid"]:
                    m["state"] = "aired"
            self.last_replay = now
            self.next_clip()
            self.status["last"] = {"id": c["id"], "label": c["label"], "t": now, "path": c["path"], "clean": c.get("clean"),
                                   "audio": c.get("audio")}
        elif self.playing and not live:
            self.to_stream("replay over")
            last = self.status.get("last") or {}
            self.drop_companion(last.get("clean"))  # (RA) after the scene left it
            self.playing = None
        elif not self.playing and now >= self.next_watch:  # watchdog: never leave the replay scene on air by itself
            self.next_watch = now + 5
            prog = o.call("GetCurrentProgramScene").get("currentProgramSceneName")
            self.status["program"] = prog
            if prog == self.cfg["scene"]:
                self.to_stream("watchdog")

    def remux_on_box(self, path, run=subprocess.run):
        """(RA) The clip's video and game-only track (audio stream clean_track) copied into "<clip>-game.mkv" beside it
        by ffmpeg on the box: (path, None), or (None, why): an old clip with one track, or ffmpeg failing."""
        out = re.sub(r"\.(mkv|mp4|mov|flv)$", "", path) + "-game.mkv"
        cmd = (f'ffmpeg -v error -y -i "{path}" -map 0:v:0 -map 0:a:{int(self.cfg["clean_track"])} -c copy "{out}"')
        r = run(["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", self.cfg["remux_host"], cmd],
                capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            err = (r.stderr or r.stdout or "").strip().splitlines()
            why = err[-1][:160] if err else f"ffmpeg exit {r.returncode}"
            if "matches no streams" in why or "Stream map" in why:
                why = "the clip has one audio track (recorded before track 2)"
            return None, why
        return out, None

    def prepare_audio(self, c):
        """(RA) The clip's game-only companion, made once as its replay starts (only clips that air get one; it is
        deleted when the replay ends): c["clean"] is its path, or None with c["clean_why"]."""
        if "clean" in c or not self.cfg["clean_audio"]:
            return
        try:
            c["clean"], why = self.remux(c["path"])
        except Exception as e:
            c["clean"], why = None, f"{type(e).__name__}: {str(e)[:120]}"
        if not c["clean"]:
            c["clean_why"] = why
            self.log(f"[replays] {c['path']}: no game-only track ({why}); it airs muted over the live ambience")

    def drop_companion(self, path, run=subprocess.run):
        """(RA) The companion of a replay that ended, deleted on the box (only a "-game.mkv" this module made)."""
        if not path or not path.endswith("-game.mkv") or self.remux != self.remux_on_box:
            return
        try:
            run(["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", self.cfg["remux_host"],
                 f'del /q "{path.replace("/", chr(92))}"'], capture_output=True, text=True, timeout=15)
        except Exception as e:
            self.log(f"[replays] deleting {path}: {type(e).__name__}: {e}")

    def audio_for(self, c):
        """(RA) ("clean", None) when the clip airs its game-only track, else ("ambience", why)."""
        if not self.cfg["clean_audio"]:
            return "ambience", "clean audio off"
        if not c.get("clean"):
            return "ambience", c.get("clean_why") or "no game-only track"
        if int(c.get("speed") or 100) != 100:
            return "ambience", "slow motion (its sound would be slowed too)"
        if self.alarm.overlaps(c["show_from"], c["show_to"]):
            return "ambience", "a speaker alarm sounded in its window"
        return "clean", None

    def replay_audio(self, track):
        """(RA) The replay scene's sound: "clean" (the clip's own game-only sound, no ambience), "ambience" (the clip
        muted, the live ambience on), None (both off: off the air). A missing ambience source is said, not fatal."""
        o, c = self.obs, self.cfg

        def mute():
            try:
                o.call("SetInputMute", {"inputName": c["media"], "inputMuted": track != "clean"})
            except OBSError as e:
                self.log(f"[replays] the clip's mute: {e}")

        def ambience():
            try:
                item = o.call("GetSceneItemId", {"sceneName": c["scene"], "sourceName": c["ambience"]}).get("sceneItemId")
                o.call("SetSceneItemEnabled", {"sceneName": c["scene"], "sceneItemId": item,
                                               "sceneItemEnabled": track == "ambience"})
            except OBSError as e:
                if track == "ambience":
                    self.log(f"[replays] no {c['ambience']!r} in the {c['scene']!r} scene ({e}): the replay airs silent under the voices")
        # what is turned off goes first: never the clip's sound and the ambience at once, even between two calls
        for step in ((ambience, mute) if track == "clean" else (mute, ambience)):
            step()

    def play(self, c):
        o, m = self.obs, self.cfg["media"]
        self.prepare_audio(c)  # (RA) made in the segment's start; here if that was missed
        track, why = self.audio_for(c)
        c["audio"] = track if not why else f"{track}: {why}"
        self.replay_audio(track)
        # speed_percent every time (a slow-motion clip at slow_speed, every other at 100: OBS keeps the last setting)
        o.call("SetInputSettings", {"inputName": m, "inputSettings": {"local_file": c["clean"] if track == "clean" else c["path"],
                                                                     "speed_percent": int(c.get("speed") or 100)},
                                    "overlay": True})
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
        self.log(f"[replays] on air: {c['label']} ({c['path']}, from {start if dur else 0} ms of {dur} ms; sound: {c['audio']})")

    def to_stream(self, why):
        try:
            self.obs.call("SetCurrentProgramScene", {"sceneName": self.cfg["stream_scene"]})
            self.obs.call("TriggerMediaInputAction", {"inputName": self.cfg["media"],
                                                      "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP"})
            self.replay_audio(None)  # (RA) the clip muted, the ambience off: nothing of the replay stays in the mix
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
        s.update(highlights_saved=[c["label"] for c in self.hl_saved],
                 pending=self.pending and {k: self.pending[k] for k in ("kind", "label")},
                 clip=self.clip and {k: self.clip[k] for k in ("id", "label", "path")}, playing=self.playing,
                 waiting=[c["label"] for c in list(self.more_pending) + list(self.more_clips)])
        return s
