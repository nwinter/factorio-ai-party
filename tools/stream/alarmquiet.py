"""Speaker alarms quiet on air (d28 batch326 RA2, viewer Aurora site:5423: "make future alarms quiet by default.
Preserve visible warnings, ambience and voices. Use brief quiet cues for new faults, no continuous or overlapping sirens,
clear on recovery and re-arm afterward. Persist ... through saves, restarts and camera changes").

The Gleba egg breeder's programmable speaker (gleba (3.5,13.5), alarm instrument, local) sounded while its condition
held, and pog-cam1 on Gleba carried it into the stream's game audio until Sonnet set its volume to 0. Speakers are the
agents' game; the stream only decides how much of one it airs:

- what the camera hears: harness ALARMS_LUA (live.py every 2 s, the snapshot's `speaker_alarms`): the camera player's
  custom alerts whose target is a programmable speaker (an alarm raises its alert while its condition holds), with
  its playback volume and mode. Audible: volume above 0, and global, or on the camera's surface and either surface-wide
  or local within LOCAL_RANGE tiles of the camera. (An alarm that raises no alert is not seen.)
- a new alarm is a cue: CUE_S at the "alarm cue" gain (CUE_DB) on the game audio, then while it holds the "alarm hold"
  gain (HOLD_DB): no continuous siren on air; any number of alarms make one hold (no overlap). Voices, the overlay and
  the visible alerts are untouched; the game's ambience stays, quieter, only while an audible alarm holds.
- recovery: the alarm's alert gone (or the camera out of its reach) ends the hold at once; it re-arms once it has been
  quiet REARM_S: back within that, it goes straight to the hold, after that it cues again.
- restarts and camera moves: the state (each alarm's first and last sound, cued) is kept in a file beside stream.json
  and read at start; the OBS filters are set from the decision on the first apply after a start (a restart mid-hold
  never leaves them on or off by mistake). A camera move changes what is audible at the next read.
- replays: OBS records each source after its filters, so the clean game track (track 2, replays.py) holds an alarm at
  the gains above; a clip whose window had an audible alarm (`overlaps`) plays muted over the quiet live ambience,
  so no old clip brings a siren back.

OBS (the operator applies it; docs/STREAM-NOTES.md): on "stream game audio", "stream game clean" (the clean track's
capture) and "replay game ambience", two Gain filters, "alarm cue" (CUE_DB) and "alarm hold" (HOLD_DB), both disabled.
This module only enables and disables them.
"""
import json, math, os, threading, time

CUE_S = 3.0          # a new alarm aired this long at the cue gain
CUE_DB = -6.0
HOLD_DB = -24.0
REARM_S = 30.0       # quiet this long: the next sound of it cues again
LOCAL_RANGE = 64.0   # tiles: a local speaker the camera hears
KEEP_S = 1800.0      # intervals and alarms remembered this long
FILTERS = {"cue": "alarm cue", "hold": "alarm hold"}
# (d29 batch335 AQ, viewer Aurora site:5438: "AlarmQuiet.apply catches failed OBS filter writes but caches the desired
# mode as applied, so recovery is never retried") each source's filter has a desired and a confirmed state: a write is
# read back (GetSourceFilter) and only a read that matches confirms it; a failed or unconfirmed write stays pending and
# is tried again after RETRY_S, doubling to RETRY_MAX_S, with no change of alarm needed; every VERIFY_S each filter is
# read again, so one changed outside the service (by hand, an OBS restart) is put back.
RETRY_S, RETRY_MAX_S, VERIFY_S = 2.0, 120.0, 60.0
SOURCES = ("stream game audio", "stream game clean", "replay game ambience")


def audible(a, cam):
    """Whether the camera client hears speaker alarm a: volume above 0; global, or on its surface and surface-wide or
    local within LOCAL_RANGE tiles."""
    if not cam or not isinstance(a, dict) or not (a.get("volume") or 0) > 0:
        return False
    mode = str(a.get("mode") or "local")
    if mode == "global":
        return True
    if a.get("surface") != cam.get("surface"):
        return False
    if mode == "surface":
        return True
    return math.hypot(float(a.get("x") or 0) - float(cam.get("x") or 0), float(a.get("y") or 0) - float(cam.get("y") or 0)) <= LOCAL_RANGE


class AlarmQuiet:
    def __init__(self, path=None, log=print, sources=SOURCES):
        self.path, self.log, self.sources = path, log, sources
        self.lock = threading.Lock()
        self.alarms = {}      # key -> {first, last, cued, message}: an alarm sounding, or quiet under REARM_S
        self.intervals = []   # [start, end or None]: when any audible alarm sounded (replays.overlaps)
        self.want = "none"    # none | cue | hold
        self.applied = None   # the gain every filter confirms, None until they all do (a start reads them all)
        # (AQ) (source, filter) -> {desired, confirmed (None: not read), pending, attempts, next_try, error, checked}
        self.filters = {(src, name): {"desired": False, "confirmed": None, "pending": True, "attempts": 0, "next_try": float("-inf"),
                                      "error": None, "checked": None} for src in sources for name in FILTERS.values()}
        self.said_missing = False
        self._load()

    def _load(self):
        if not self.path:
            return
        try:
            d = json.load(open(self.path))
        except (OSError, ValueError):
            return
        self.alarms = {k: v for k, v in (d.get("alarms") or {}).items() if isinstance(v, dict)}
        self.intervals = [list(x) for x in d.get("intervals") or [] if isinstance(x, list) and len(x) == 2]

    def _save(self):
        if not self.path:
            return
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump({"alarms": self.alarms, "intervals": self.intervals[-200:]}, f)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def decide(self, read, now):
        """From the snapshot's speaker_alarms: the gain wanted now (none, cue, hold)."""
        read = read if isinstance(read, dict) else {}
        if read.get("t") is not None and now - float(read["t"]) > 30:
            read = {}  # a stale read (the game not answering): nothing is known to sound
        cam = read.get("cam")
        on = {str(a.get("unit")): a for a in read.get("alarms") or [] if audible(a, cam)}
        with self.lock:
            changed = False
            for k, a in on.items():
                r = self.alarms.get(k)
                if r and now - r["last"] <= REARM_S + 2.5:  # still sounding, or back within REARM_S: keeps its cue
                    r["last"] = now
                else:
                    self.alarms[k] = {"first": now, "last": now, "cued": False, "message": str(a.get("message") or "")[:120]}
                    changed = True
                    self.log(f"[alarms] {a.get('surface')} speaker {k} sounding ({a.get('mode')}, volume "
                             f"{a.get('volume')}): {str(a.get('message') or '')[:80]}")
            for k in [k for k, r in self.alarms.items() if now - r["last"] > max(KEEP_S, REARM_S)]:
                del self.alarms[k]
            want = "none"
            for k in on:
                r = self.alarms[k]
                if r["cued"] or now - r["first"] >= CUE_S:
                    r["cued"] = True
                    want = "hold"
                elif want != "hold":
                    want = "cue"
            if on and (not self.intervals or self.intervals[-1][1] is not None):
                self.intervals.append([now, None])
                changed = True
            elif not on and self.intervals and self.intervals[-1][1] is None:
                self.intervals[-1][1] = now
                changed = True
                self.log(f"[alarms] clear: game audio back to its level")
            self.intervals = [x for x in self.intervals if x[1] is None or now - x[1] < KEEP_S]
            if want != self.want:
                changed = True
                if want == "hold":
                    self.log(f"[alarms] an alarm holds: game audio at {HOLD_DB:g} dB until it clears")
            self.want = want
        if changed:
            self._save()
        return want

    def overlaps(self, t0, t1):
        """Whether an audible alarm sounded between t0 and t1 (a replay's window)."""
        with self.lock:
            return any(s < t1 and (e is None or e > t0) for s, e in self.intervals)

    def apply(self, call, now=None):
        """Bring the OBS filters to the decision (call: obsws OBS.call). Each filter whose confirmed state differs from
        its desired one (or not confirmed yet, or due for its VERIFY_S read) is written if needed and read back; a failure
        or a read that does not match stays pending and is tried again after its backoff. Returns how many were written."""
        now = time.time() if now is None else now
        want = self.want
        wrote, missing = 0, []
        for (src, name), f in self.filters.items():
            f["desired"] = name == FILTERS.get(want)
            due = f["pending"] or f["confirmed"] != f["desired"] or f["checked"] is None or now - f["checked"] >= VERIFY_S
            if not due or now < f["next_try"]:
                continue
            try:
                written = False
                for _ in range(2):  # a read that finds it otherwise (changed by hand since) is written in the same pass
                    if f["confirmed"] != f["desired"] and not written:  # never read, or reads otherwise: write it
                        call("SetSourceFilterEnabled", {"sourceName": src, "filterName": name, "filterEnabled": f["desired"]})
                        wrote += 1
                        written = True
                    got = call("GetSourceFilter", {"sourceName": src, "filterName": name})
                    f["confirmed"], f["checked"] = bool((got or {}).get("filterEnabled")), now
                    if f["confirmed"] == f["desired"] or written:
                        break
                if f["confirmed"] != f["desired"]:
                    # read back otherwise (the write did not take, or OBS changed it since): written again next time
                    raise RuntimeError(f"OBS reads it {'enabled' if f['confirmed'] else 'disabled'} after the write")
                f.update(pending=False, attempts=0, next_try=float("-inf"), error=None)
            except Exception as x:
                f["pending"] = True
                f["attempts"] += 1
                f["next_try"] = now + min(RETRY_MAX_S, RETRY_S * 2 ** (f["attempts"] - 1))
                f["error"] = f"{type(x).__name__}: {str(x)[:160]}"
                if "not found" in str(x).lower() or "600" in str(x) or "no such" in str(x).lower():
                    missing.append(f"{src}/{name}")
        if missing and not self.said_missing:  # not set up yet (tools/obs_setup_326.py): said once a run
            self.said_missing = True
            self.log(f"[alarms] no alarm gains in OBS yet ({', '.join(missing)}): alarms air as before until "
                     f"tools/obs_setup_326.py --apply; tried again with backoff")
        ok = all(not f["pending"] and f["confirmed"] == f["desired"] for f in self.filters.values())
        self.applied = want if ok else None
        return wrote

    def public(self, now=None):
        """For the service's /state.json (replays.alarm): the gain wanted, whether OBS confirms it, and each filter's
        desired and confirmed state, pending writes, attempts, next try and last error."""
        now = time.time() if now is None else now
        with self.lock:
            sounding = len([1 for r in self.alarms.values() if now - r["last"] < 5])
        rows = [{"source": src, "filter": name, "desired": f["desired"], "confirmed": f["confirmed"], "pending": f["pending"],
                 "attempts": f["attempts"], "next_try_in": round(max(0.0, f["next_try"] - now), 1) if f["pending"] else None,
                 "error": f["error"], "checked_ago": round(now - f["checked"], 1) if f["checked"] is not None else None}
                for (src, name), f in self.filters.items()]
        return {"gain": self.want, "confirmed": self.applied == self.want, "sounding": sounding, "filters": rows,
                "pending": sum(1 for r in rows if r["pending"])}
