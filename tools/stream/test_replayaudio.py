#!/usr/bin/env python3
"""Replay audio and speaker alarms on air (d28 batch326 RA and RA2, viewer Aurora site:5417, site:5423):
python3 tools/stream/test_replayaudio.py

RA (replays.py): 1. track choice: a clip with its game-only companion plays it with its sound (the clip unmuted, the
ambience off); an old clip with one track, a slow-motion clip and a clip whose window had an audible alarm play muted
over the live ambience; 2. sync: the companion is cued like the clip (same length, the same cursor), at the clip's
speed; 3. a replay cut short (segments.attack_cut) and 4. a service restart mid-replay both leave the clip muted and the
ambience off, the program on "stream"; 5. never the clip's sound and the ambience together (no doubled sound), and the
live "stream game audio" never touched (its level is the live one on return); 6. the box's remux command, and an old
clip's "matches no streams" said as one track.
RA2 (alarmquiet.py): 7. a sustained fault: a short cue, then the hold while it lasts; recovery: off at once; a retrigger
within REARM_S: straight to the hold; after it: a cue again; two alarms: one hold; volume 0, another surface or a local
speaker out of range: not heard; global: heard anywhere; a stale read: nothing sounding; 8. a restart mid-hold (the
state file): the hold at once, and the filters set on the first apply; 9. a listen test on a made-up recording: game
ambience with a siren through a sustained fault, recovery and a retrigger, the gains applied per 50 ms: the siren is on
air at the cue level for at most CUE_S each new fault and 24 dB down while held; the ambience is back at its level
within one read of recovery.
"""
import json, math, os, random, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replays as rp  # noqa: E402
import alarmquiet as aq  # noqa: E402
from segments import Segments  # noqa: E402

rp.time.sleep = lambda s: None


class OBS:
    """A stand-in OBS that keeps the replay scene's sound state: the clip's mute, the ambience item, the program."""
    def __init__(self, program="stream", muted=True, ambience=False):
        self.saved, self.program, self.muted, self.ambience = 0, program, muted, ambience
        self.files, self.cursor, self.speed, self.calls, self.live_volume_set = [], None, None, [], False
        self.filters = {}
        self.states = []  # (program, muted, ambience) after each call

    def call(self, req, data=None):
        self.calls.append((req, data))
        out = {}
        if req == "GetSceneList":
            out = {"scenes": [{"sceneName": "stream"}, {"sceneName": "replay"}]}
        elif req == "GetInputList":
            out = {"inputs": [{"inputName": n} for n in ("stream overlay", "replay clip", "replay banner", "replay game ambience")]}
        elif req == "GetReplayBufferStatus":
            out = {"outputActive": True}
        elif req == "SaveReplayBuffer":
            self.saved += 1
        elif req == "GetLastReplayBufferReplay":
            if not self.saved:
                raise rp.OBSError("no replay yet")
            out = {"savedReplayPath": f"D:/pog/recordings/Replay_{self.saved}.mkv"}
        elif req == "GetMediaInputStatus":
            out = {"mediaDuration": 45000}
        elif req == "SetCurrentProgramScene":
            self.program = data["sceneName"]
        elif req == "GetCurrentProgramScene":
            out = {"currentProgramSceneName": self.program}
        elif req == "SetInputMute" and data["inputName"] == "replay clip":
            self.muted = data["inputMuted"]
        elif req == "GetSceneItemId":
            out = {"sceneItemId": 7}
        elif req == "SetSceneItemEnabled" and data["sceneItemId"] == 7:
            self.ambience = data["sceneItemEnabled"]
        elif req == "SetInputSettings" and data["inputName"] == "replay clip":
            self.files.append(data["inputSettings"]["local_file"])
            self.speed = data["inputSettings"].get("speed_percent")
        elif req == "SetMediaInputCursor":
            self.cursor = data["mediaCursor"]
        elif req == "SetSourceFilterEnabled":
            self.filters[(data["sourceName"], data["filterName"])] = data["filterEnabled"]
        elif req in ("SetInputVolume",) and data.get("inputName") == "stream game audio":
            self.live_volume_set = True
        self.states.append((self.program, self.muted, self.ambience))
        return out


def world(remux, obs=None, alarm=None):
    seg = Segments(spacing=0)
    o = obs or OBS()
    logs = []
    rpl = rp.Replays(seg, obs=o, log=lambda *a: logs.append(" ".join(map(str, a))), start=False, remux=remux, alarm=alarm)
    rpl.work(0)
    return seg, rpl, o, logs


def air(seg, rpl, o, t0, clip):
    """Put one saved clip on air through the segment and return the time it went on air."""
    with rpl.lock:
        rpl.clip = dict(clip, id="clip-x", saved_t=t0, label=clip.get("label", "a loss"), queued_t=t0)
    for t in range(t0, t0 + 20):
        snap = {"agents": [], "fights": [], "alerts": []}
        seg.step(snap, t)
        rpl.tick(snap, {}, t)
        rpl.work(t)
        if rpl.playing:
            return t
    raise AssertionError("never aired")


def run_out(seg, rpl, o, t, n=40):
    for k in range(t, t + n):
        snap = {"agents": [], "fights": [], "alerts": []}
        seg.step(snap, k)
        rpl.tick(snap, {}, k)
        rpl.work(k)
    return t + n


def ra():
    clean = lambda path: (path[:-4] + "-game.mkv", None)
    old = lambda path: (None, "the clip has one audio track (recorded before track 2)")
    base = {"path": "D:/pog/recordings/Replay_1.mkv", "show_from": 960, "show_to": 972, "kind": "loss"}
    # 1-2. a clip with its companion: the companion with its sound, the ambience off; cued like the clip
    seg, rpl, o, logs = world(clean)
    t = air(seg, rpl, o, 1000, dict(base, clean="D:/pog/recordings/Replay_1-game.mkv"))
    assert o.program == "replay" and o.files[-1].endswith("-game.mkv") and not o.muted and not o.ambience, (o.program, o.files, o.muted, o.ambience)
    assert o.cursor == 45000 - (1000 - 960) * 1000 and o.speed == 100, (o.cursor, o.speed)
    assert "sound: clean" in logs[-1], logs[-1]
    t = run_out(seg, rpl, o, t)
    assert o.program == "stream" and o.muted and not o.ambience, "back: the clip muted, the ambience off"
    # an old clip: the mixed clip muted over the ambience
    seg, rpl, o, logs = world(old)
    air(seg, rpl, o, 1000, dict(base, clean=None, clean_why="the clip has one audio track (recorded before track 2)"))
    assert o.files[-1] == base["path"] and o.muted and o.ambience and o.cursor == 45000 - 40000
    assert "sound: ambience: the clip has one audio track" in logs[-1], logs[-1]
    # slow motion: muted over the ambience, at its speed
    seg, rpl, o, logs = world(clean)
    air(seg, rpl, o, 1000, dict(base, clean="D:/pog/recordings/Replay_1-game.mkv", speed=45))
    assert o.files[-1] == base["path"] and o.muted and o.ambience and o.speed == 45 and "slow motion" in logs[-1]
    # a speaker alarm sounded in its window
    al = aq.AlarmQuiet(log=lambda *a: None)
    al.intervals = [[965.0, 990.0]]
    seg, rpl, o, logs = world(clean, alarm=al)
    air(seg, rpl, o, 1000, dict(base, clean="D:/pog/recordings/Replay_1-game.mkv"))
    assert o.muted and o.ambience and "a speaker alarm sounded in its window" in logs[-1]
    # the companion is made once, when its replay starts (not when the clip is saved)
    made = []
    seg, rpl, o, logs = world(lambda path: made.append(path) or (path[:-4] + "-game.mkv", None))
    air(seg, rpl, o, 1000, dict(base))
    assert made == [base["path"]] and o.files[-1].endswith("-game.mkv") and not o.muted, (made, o.files)
    print("1-2. track choice: the companion with its sound; an old, slow or alarm clip muted over the ambience; cued alike: ok")

    # 3. a replay cut short by an attack
    seg, rpl, o, logs = world(clean)
    t = air(seg, rpl, o, 1000, dict(base, clean="D:/pog/recordings/Replay_1-game.mkv"))
    seg.attack_cut(t + 2)
    run_out(seg, rpl, o, t + 3, 5)
    assert o.program == "stream" and o.muted and not o.ambience, (o.program, o.muted, o.ambience)
    # 4. a restart mid-replay: OBS left on the replay, the clip unmuted, the ambience on
    o2 = OBS(program="replay", muted=False, ambience=True)
    seg, rpl, o2, logs = world(clean, obs=o2)
    assert o2.muted and not o2.ambience, "the first work sets the replay scene's sound back"
    run_out(seg, rpl, o2, 2000, 8)
    assert o2.program == "stream", "the watchdog returns to stream"
    print("3-4. cut short and restarted mid-replay: back on stream, the clip muted, the ambience off: ok")

    # 5. no doubled sound in any state; the live game audio never touched
    reset = next(i for i, c in enumerate(o2.calls) if c[0] == "SetInputMute")  # o2 began doubled (a crash): from its reset on
    for obs, start in ((o, 0), (o2, reset)):
        assert not any(not m and a for _, m, a in obs.states[start:]), "the clip's sound and the ambience together"
    # switching between the two in either order: never both, even between the two calls
    seg, rpl, o3, logs = world(clean)
    for track in ("ambience", "clean", "ambience", None, "clean", None):
        rpl.replay_audio(track)
    assert not any(not m and a for _, m, a in o3.states), o3.states
    for obs in (o, o2, o3):
        assert not obs.live_volume_set and not any(c[0] == "SetInputVolume" for c in obs.calls)
    print("5. never the clip's sound and the ambience together; the live game audio's level untouched: ok")

    # 6. the remux on the box: its command; an old clip's one track
    calls = []

    class R:
        def __init__(self, code, err=""):
            self.returncode, self.stderr, self.stdout = code, err, ""
    seg, rpl, o, logs = world(None)
    out, why = rpl.remux_on_box("D:/pog/recordings/Replay_2026-10-28_19-00-00.mkv", run=lambda cmd, **k: calls.append(cmd) or R(0))
    assert out == "D:/pog/recordings/Replay_2026-10-28_19-00-00-game.mkv" and why is None
    assert calls[0][:2] == ["ssh", "-o"] and calls[0][-2] == "pogwin" and \
        calls[0][-1] == ('ffmpeg -v error -y -i "D:/pog/recordings/Replay_2026-10-28_19-00-00.mkv" -map 0:v:0 -map 0:a:1 '
                         '-c copy "D:/pog/recordings/Replay_2026-10-28_19-00-00-game.mkv"'), calls[0]
    out, why = rpl.remux_on_box("x.mkv", run=lambda cmd, **k: R(1, "Stream map '0:a:1' matches no streams."))
    assert out is None and why == "the clip has one audio track (recorded before track 2)", why
    print("6. the companion made on the box by a stream copy; an old clip's one track said: ok")


def read(alarms, cam=("gleba", 0, 0), t=None):
    return {"cam": {"surface": cam[0], "x": cam[1], "y": cam[2]}, "alarms": alarms, "t": t}


EGG = {"unit": 1001, "surface": "gleba", "x": 3.5, "y": 13.5, "volume": 1.0, "mode": "local", "message": "Gleba west egg breeder"}


def ra2():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "alarm-quiet.json")
        a = aq.AlarmQuiet(path, log=lambda *x: None)
        seq = []
        for t in range(0, 200):  # 2 s reads: a fault 10-70 s, recovery, a retrigger at 80 (within REARM_S), quiet,
            now = float(t)       # another at 150 (after it)
            on = (10 <= t < 70) or (80 <= t < 90) or (150 <= t < 170)
            seq.append((t, a.decide(read([EGG] if on else [], t=now), now)))
        g = dict(seq)
        assert g[9] == "none" and g[10] == "cue" and g[12] == "cue" and g[13] == "hold" and g[69] == "hold", "a short cue, then the hold"
        assert g[70] == "none", "clear at once on recovery"
        assert g[80] == "hold", "a retrigger within REARM_S: straight to the hold"
        assert g[90] == "none" and g[150] == "cue" and g[153] == "hold", "re-armed after REARM_S: a cue again"
        cues = [t for t, w in seq if w == "cue"]
        assert len(cues) == 2 * int(aq.CUE_S), cues
        assert a.overlaps(60, 75) and not a.overlaps(100, 140)
        # two alarms make one hold; volume 0, another surface, out of range: none; global: anywhere; stale read: none
        b = aq.AlarmQuiet(None, log=lambda *x: None)
        two = [EGG, dict(EGG, unit=1002, x=10.5)]
        assert [b.decide(read(two, t=float(t)), float(t)) for t in range(0, 6)][-1] == "hold"
        c = aq.AlarmQuiet(None, log=lambda *x: None)
        for alarm, cam, what in ((dict(EGG, volume=0), ("gleba", 0, 0), "volume 0 (Sonnet's change)"),
                                 (EGG, ("nauvis", 0, 0), "the camera on another surface"),
                                 (EGG, ("gleba", 200, 0), "a local speaker 200 tiles away")):
            assert all(c.decide(read([alarm], cam, t=float(t)), float(t)) == "none" for t in range(0, 6)), what
        assert aq.audible(dict(EGG, mode="global"), {"surface": "nauvis", "x": 0, "y": 0})
        assert aq.audible(dict(EGG, mode="surface"), {"surface": "gleba", "x": 900, "y": 0})
        assert c.decide(read([EGG], t=0.0), 100.0) == "none", "a stale read: nothing known to sound"
        print("7. a sustained fault: a short cue then the hold; clear on recovery; re-armed after REARM_S; one hold for two: ok")

        # 8. a restart mid-hold: the state file; the filters set on the first apply whatever OBS had
        a2 = aq.AlarmQuiet(path, log=lambda *x: None)
        a2.decide(read([EGG], t=200.0), 200.0)  # the fault is back right after the restart (the 150 one, cued)
        a3 = aq.AlarmQuiet(path, log=lambda *x: None)
        assert a3.decide(read([EGG], t=201.0), 201.0) == "hold", "cued before the restart: no second cue"
        o = OBS()
        assert a3.apply(o.call) and o.filters == {(src, f): f == "alarm hold" for src in aq.SOURCES for f in ("alarm cue", "alarm hold")}, o.filters
        assert set(aq.SOURCES) == {"stream game audio", "stream game clean", "replay game ambience"}
        assert not a3.apply(o.call), "applied once per change"
        a3.decide(read([], t=202.0), 202.0)
        assert a3.apply(o.call) and not any(o.filters.values())
        print("8. a restart mid-hold: the hold at once (no second cue), the filters set on the first apply: ok")

        # 9. a listen test on a made-up recording: 8 kHz, ambience noise at -30 dBFS, a 900 Hz siren at -12 dBFS during
        # the faults; the gain decided at each 2 s read, applied per 50 ms frame; the siren measured on air
        rnd = random.Random(7)
        rate, frame = 8000, 400
        q = aq.AlarmQuiet(None, log=lambda *x: None)
        want, siren_on_air, worst_held, amb_after = "none", 0.0, -999.0, []
        db = {"none": 0.0, "cue": aq.CUE_DB, "hold": aq.HOLD_DB}
        faults = ((10, 70), (80, 90), (150, 170))
        for f in range(int(200 * rate / frame)):
            t = f * frame / rate
            on = any(s <= t < e for s, e in faults)
            if abs(t - round(t / 2) * 2) < 1e-9:  # a read every 2 s
                want = q.decide(read([EGG] if on else [], t=t), t)
            gain = 10 ** (db[want] / 20)
            n = sum((rnd.gauss(0, 10 ** (-30 / 20))) ** 2 for _ in range(frame)) / frame
            s = (10 ** (-12 / 20)) ** 2 / 2 if on else 0.0
            if on:
                siren_db = 10 * math.log10(s * gain * gain)
                if siren_db > -13:
                    siren_on_air += frame / rate
                if want == "hold":
                    worst_held = max(worst_held, siren_db)
            elif 70 <= t < 72 or 170 <= t < 172:
                amb_after.append(10 * math.log10(n * gain * gain))
        assert siren_on_air <= 2 * aq.CUE_S + 0.01, f"the siren at full level only during the cues ({siren_on_air} s)"
        assert worst_held <= -12 + aq.HOLD_DB + 0.1, worst_held
        assert all(abs(x + 30) < 1.0 for x in amb_after), amb_after[:5]
        print(f"9. listen test: the siren never at full level (cue level {aq.CUE_DB:g} dB for {2 * aq.CUE_S:g} s over two new "
              f"faults), held at {worst_held:.1f} dBFS (from -12); the ambience back at -30 dBFS on recovery: ok")


if __name__ == "__main__":
    ra()
    ra2()
    print("test_replayaudio: all ok")
