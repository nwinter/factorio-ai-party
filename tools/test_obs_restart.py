#!/usr/bin/env python3
"""OBS restarts and recovery with stubs for OBS and the box (operator 2026-10-13: at 08:29 Quick Sync failed after
24.5 h in one OBS process, MFX_ERR_MEMORY_ALLOC; only a new OBS process helped): python3 tools/test_obs_restart.py

- obs-restart.sh: outputs stopped first (stream, recording, replay buffer), then the box's obs-restart.ps1, then it
  waits for the websocket; exit 0 once OBS answers, 1 when it never does; --dry-run touches nothing.
- obs-steps.sh: scene, overlay, recording, stream, and last a read of the cameras' crops (obs.py cams); the vertical started only when its status says it is not
  streaming; a failed recording or stream start is exit 1, the rest is reported only.
- obs-recover.sh: an active stream is left alone; one plain retry that works means no restart; an encoder failure
  (outputs never come up) restarts OBS and runs the OBS steps; one at a time.
- start-team's dry run names the restart and the steps; obs-restart.ps1 has the dialogs, the fallback and the log.
"""
import os
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A stateful obs.py: $STATE/stream, $STATE/record hold 0/1; $STATE/down counts websocket answers still refused;
# BROKEN=1: stream-start/start answer ok but the output never comes up (the encoder failure).
OBS = r"""#!/usr/bin/env bash
echo "obs $*" >> "$STUB_LOG"
s=$STATE
down=$(cat "$s/down" 2>/dev/null || echo 0)
if [ "$down" -gt 0 ]; then echo $((down - 1)) > "$s/down"; echo "ConnectionRefusedError: [Errno 61]" >&2; exit 1; fi
st() { [ "$(cat "$s/$1" 2>/dev/null)" = 1 ] && echo True || echo False; }
case $1 in
  stream-status) echo "active=$(st stream) reconnecting=False time=00:00:00 skipped=0/0 congestion=0.00" ;;
  status) echo "active=$(st record) paused=False time=00:00:00 bytes=0" ;;
  stream-start) [ "$(cat "$s/broken" 2>/dev/null)" = 1 ] || echo 1 > "$s/stream"; echo "streaming to YouTube" ;;
  start) [ "$(cat "$s/broken" 2>/dev/null)" = 1 ] || echo 1 > "$s/record"; echo "recording" ;;
  stream-stop) echo 0 > "$s/stream"; echo "stream stopped" ;;
  stop) echo 0 > "$s/record"; echo "saved D:/rec/x.mkv" ;;
  replay-stop) echo "replay buffer stopped" ;;
  stream-scene) echo "scene stream" ;;
  scene) echo "program scene $2" ;;
  reload-overlay) echo "reloaded" ;;
esac
"""
# The box: the restart clears the encoder failure; RESTART_DOWN websocket refusals follow it.
WINPS = r"""#!/usr/bin/env bash
echo "winps $*" >> "$STUB_LOG"
if [ "${2:-}" = -DryRun ]; then echo "dry run: nothing closed or started"; exit 0; fi
echo 0 > "$STATE/broken"; echo 0 > "$STATE/stream"; echo 0 > "$STATE/record"
echo "${RESTART_DOWN:-2}" > "$STATE/down"
echo "10:59:01 close: CloseMainWindow on pid 4242 (up 24.5 h): sent"
echo "10:59:04 close: exited cleanly in 3 s"
echo "10:59:20 start: OBS up in 15 s (window 'OBS 32.2.2 - Profile: pog', websocket 4455 listening)"
case ${QSV:-ok} in  # 15:06: Quick Sync did not load in the new process
  ok) echo "10:59:23 qsv: ok (no Quick Sync encoder missing in the log)" ;;
  once) echo "10:59:23 qsv: MISSING in the new process (obs_qsv11_hevc, obs_qsv11_v2 not found): restarting once more"
        echo "10:59:45 start: OBS up in 16 s (window 'OBS 32.2.2 - Profile: pog', websocket 4455 listening)"
        echo "10:59:48 qsv: ok after the second start" ;;
  missing) echo "10:59:23 qsv: MISSING in the new process (obs_qsv11_hevc, obs_qsv11_v2 not found): restarting once more"
           echo "10:59:45 start: OBS up in 16 s (window 'OBS 32.2.2 - Profile: pog', websocket 4455 listening)"
           echo "10:59:48 qsv: MISSING again (obs_qsv11_hevc, obs_qsv11_v2 not found): the stream cannot start; a reboot of the box may be needed"
           echo "10:59:48 done"; exit 2 ;;
esac
echo "10:59:48 done"
exit "${BOX_FAILS:-0}"
"""
VERTICAL = r"""#!/usr/bin/env bash
echo "vertical $*" >> "$STUB_LOG"
case $1 in
  status) echo "{'status': 'ok', 'streaming': ${VERTICAL_ON:-True}}" ;;
  start) echo "{'status': 'ok'}" ;;
esac
"""


def setup():
    tmp = tempfile.mkdtemp(prefix="obsrestart")
    bin_, state = os.path.join(tmp, "bin"), os.path.join(tmp, "state")
    os.makedirs(bin_)
    os.makedirs(state)
    for name, body in (("obs", OBS), ("winps", WINPS), ("vertical", VERTICAL)):
        p = os.path.join(bin_, name)
        open(p, "w").write(body)
        os.chmod(p, 0o755)
    return tmp, bin_, state


def put(state, **kv):
    for k, v in kv.items():
        open(os.path.join(state, k), "w").write(str(v))


def run(tmp, bin_, state, script, *args, **env):
    log = os.path.join(tmp, "calls.log")
    open(log, "w").close()
    e = {k: v for k, v in os.environ.items() if not k.startswith("POG_")}
    e.update(STUB_LOG=log, STATE=state, POG_OR_OBS=f"{bin_}/obs", POG_OR_WINPS=f"{bin_}/winps", POG_OR_SLEEP="0",
             POG_OS_OBS=f"{bin_}/obs", POG_OS_VERTICAL=f"{bin_}/vertical", POG_OS_SLEEP="0",
             POG_OS_POLL="0", POG_OS_ACTIVE_WAIT="2",
             POG_REC_OBS=f"{bin_}/obs", POG_REC_SETTLE="0",
             # (d24 batch186) a test run: the recovery lock in the temp folder, never the live checkout's runs/ (the
             # gate runs the tests there, and the watchdog's real recovery takes runs/.obs-recover.lock)
             POG_TEST="1", POG_REC_LOCK=os.path.join(tmp, "obs-recover.lock"))
    e.update(env)
    r = subprocess.run([os.path.join(ROOT, "tools", script), *args], cwd=ROOT, env=e, capture_output=True, text=True,
                       timeout=60)
    return r, open(log).read()


def restart():
    tmp, bin_, state = setup()
    try:
        put(state, stream=1, record=1)
        r, calls = run(tmp, bin_, state, "obs-restart.sh")
        assert r.returncode == 0, r.stdout + r.stderr
        order = [l.split()[1] for l in calls.splitlines()]
        assert order[:4] == ["stream-stop", "stop", "replay-stop", "tools/win/obs-restart.ps1"], calls
        assert "box: 10:59:04 close: exited cleanly in 3 s" in r.stdout and "OBS answers after" in r.stdout, r.stdout
        assert r.stdout.strip().splitlines()[-1].split(" ", 1)[1].startswith("obs-restart: OBS answers"), r.stdout
        # a broken OBS refusing the stops: going on
        put(state, down=3)
        r, calls = run(tmp, bin_, state, "obs-restart.sh")
        assert r.returncode == 0 and "stream-stop: failed (ignored)" in r.stdout, r.stdout
        # never answers again
        r, _ = run(tmp, bin_, state, "obs-restart.sh", "--wait", "0", RESTART_DOWN="1000")
        assert r.returncode == 1 and "FAILED: OBS does not answer after 0 s: ConnectionRefusedError" in r.stdout, r.stdout
        # the box's script fails (no session?) but OBS answers: exit 0, the problem printed
        r, _ = run(tmp, bin_, state, "obs-restart.sh", BOX_FAILS="1", RESTART_DOWN="0")
        assert r.returncode == 0 and "reported a problem (exit 1)" in r.stdout, r.stdout
        # Quick Sync missing once (15:06): the box restarts once more, then fine; missing twice: FAILED although OBS answers
        r, _ = run(tmp, bin_, state, "obs-restart.sh", QSV="once", RESTART_DOWN="0")
        assert r.returncode == 0 and "box: 10:59:48 qsv: ok after the second start" in r.stdout, r.stdout
        r, _ = run(tmp, bin_, state, "obs-restart.sh", QSV="missing", RESTART_DOWN="0")
        last = r.stdout.strip().splitlines()[-1]
        assert r.returncode == 1 and "FAILED: OBS answers but Quick Sync did not load after two starts" in last, r.stdout
        assert "obs_qsv11_v2 not found" in last, last
        # dry run: the plan and the box's own dry run, nothing stopped
        r, calls = run(tmp, bin_, state, "obs-restart.sh", "--dry-run")
        assert r.returncode == 0 and "plan: 1." in r.stdout and "box: dry run: nothing closed or started" in r.stdout
        assert calls.strip() == "winps tools/win/obs-restart.ps1 -DryRun", calls
        print("obs-restart: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def steps():
    tmp, bin_, state = setup()
    try:
        r, calls = run(tmp, bin_, state, "obs-steps.sh", "--stream")
        assert r.returncode == 0, r.stdout + r.stderr
        assert [l for l in calls.splitlines()] == ["obs stream-scene", "obs scene stream", "obs reload-overlay", "obs start",
                                                   "obs status", "obs stream-start", "obs stream-status",
                                                   "vertical status", "obs cams"], calls
        assert "recording: active" in r.stdout and "stream: active" in r.stdout, r.stdout
        assert "vertical: streaming (started with the main stream)" in r.stdout, r.stdout
        put(state, stream=0, record=0)
        r, calls = run(tmp, bin_, state, "obs-steps.sh", "--stream", VERTICAL_ON="False")
        assert "vertical start --yes" in calls and "vertical start: " in r.stdout, (calls, r.stdout)
        r, calls = run(tmp, bin_, state, "obs-steps.sh")  # no --stream: recording only
        assert "stream-start" not in calls and "vertical" not in calls and r.returncode == 0, calls
        # 15:06: StartStream accepted, the output never active (Quick Sync missing): FAILED, exit 1, no vertical
        put(state, stream=0, record=0, broken=1)
        r, calls = run(tmp, bin_, state, "obs-steps.sh", "--stream")
        assert r.returncode == 1 and "stream: FAILED: not active after 2 s" in r.stdout, r.stdout
        assert "recording: FAILED: not active" in r.stdout and "vertical" not in calls, (r.stdout, calls)
        put(state, broken=0)
        put(state, down=100)
        r, _ = run(tmp, bin_, state, "obs-steps.sh", "--stream")
        assert r.returncode == 1 and "recording: FAILED" in r.stdout and "stream: FAILED" in r.stdout, r.stdout
        r, calls = run(tmp, bin_, state, "obs-steps.sh", "--stream", "--dry-run")
        assert r.returncode == 0 and not calls and "plan:" in r.stdout
        print("obs-steps: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def recover():
    tmp, bin_, state = setup()
    rec = dict(POG_REC_RESTART=os.path.join(ROOT, "tools", "obs-restart.sh"),
               POG_REC_STEPS=os.path.join(ROOT, "tools", "obs-steps.sh"))
    try:
        put(state, stream=1, record=1)
        r, calls = run(tmp, bin_, state, "obs-recover.sh", **rec)
        assert r.returncode == 0 and "stream active: nothing to do" in r.stdout and "stream-start" not in calls, r.stdout
        # dropped, a plain retry works: no restart
        put(state, stream=0, record=0)
        r, calls = run(tmp, bin_, state, "obs-recover.sh", **rec)
        assert r.returncode == 0 and "recovered without a restart" in r.stdout and "winps" not in calls, r.stdout
        # the encoder failure: StartStream answers but nothing comes up -> restart, then the OBS steps
        put(state, stream=0, record=0, broken=1)
        r, calls = run(tmp, bin_, state, "obs-recover.sh", **rec)
        assert r.returncode == 0 and "restarting OBS" in r.stdout and "recovered after a restart" in r.stdout, r.stdout
        c = calls.splitlines()
        i = c.index("winps tools/win/obs-restart.ps1")
        assert c[i + 1:].count("obs stream-start") == 1 and "obs stream-scene" in c[i + 1:] and "vertical status" in c, calls
        assert not os.path.exists(os.path.join(tmp, "obs-recover.lock"))
        # still broken after the restart: exit 1
        r, _ = run(tmp, bin_, state, "obs-recover.sh", POG_REC_RESTART="true", POG_REC_STEPS="true")
        put(state, stream=0, broken=1)
        r, _ = run(tmp, bin_, state, "obs-recover.sh", POG_REC_RESTART="true", POG_REC_STEPS="true")
        assert r.returncode == 1 and "FAILED: the stream is still not active" in r.stdout, r.stdout
        # one at a time
        os.makedirs(os.path.join(tmp, "obs-recover.lock"))
        try:
            r, _ = run(tmp, bin_, state, "obs-recover.sh", POG_REC_RESTART="true", POG_REC_STEPS="true")
            assert r.returncode == 2 and "another obs-recover is running" in r.stdout, r.stdout
        finally:
            os.rmdir(os.path.join(tmp, "obs-recover.lock"))
        # POG_TEST=1 without POG_REC_LOCK: the live lock is refused
        r, _ = run(tmp, bin_, state, "obs-recover.sh", POG_REC_LOCK="", POG_REC_RESTART="true", POG_REC_STEPS="true")
        assert r.returncode == 3 and "not taking the live lock" in r.stdout, r.stdout
        r, calls = run(tmp, bin_, state, "obs-recover.sh", "--dry-run")
        assert r.returncode == 0 and "plan:" in r.stdout and "stream-start" not in calls
        print("obs-recover: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def scripts():
    ps = open(os.path.join(ROOT, "tools", "win", "obs-restart.ps1")).read()
    for s in ("LogonType Interactive", "CloseMainWindow", "Stop-Process -Id $p.Id -Force", "Start-ScheduledTask -TaskName '__OBSTASK__'",
              "'Safe Mode|Crash Detected'", "Press $w 'Normal'", "'{ESC}'", "Authentication Failure", "LocalPort 4455",
              "-DryRun", "Say 'done'", "'.sentinel'", "-Filter 'run_*'", "Encoder ID '(obs_qsv11[^']*)' not found",
              "qsv: MISSING again", "if ($stale)", "exit 2"):
        assert s in ps, s
    st = open(os.path.join(ROOT, "tools", "start-team.sh")).read()
    assert "tools/obs-restart.sh" in st and "tools/obs-steps.sh $stream" in st and "POG_OBS_RESTARTED" in st
    print("scripts: ok")


if __name__ == "__main__":
    restart()
    steps()
    recover()
    scripts()
