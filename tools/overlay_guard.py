"""OBS overlay readiness, reload budget and cheap source evidence (no game reads)."""
import base64
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

TUNNEL_URL = "http://127.0.0.1:8787/state.json"
SHOT_INTERVAL = 60
HEALTH_STALE = 120
MIN_RELOAD_INTERVAL = 180


def tunnel_ready():
    """Read from pogwin, through the same reverse forward as the browser, not Mac :8788."""
    stub = os.environ.get("POG_OC_READY")
    if os.environ.get("POG_TEST") and not stub:
        return False, "test has no tunnel stub"
    cmd = shlex.split(stub) if stub else [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "pogwin",
        "curl.exe --fail --silent --show-error --max-time 4 " + TUNNEL_URL]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=8, check=True)
        data = json.loads(r.stdout)
        # A listening HTTP socket alone is not enough; Hub starts with an empty snapshot.
        if not isinstance(data, dict) or "tick" not in data or not isinstance(data.get("agents"), list):
            return False, "state.json has no snapshot yet"
        return True, "pogwin state.json ready"
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        return False, type(e).__name__


def wait_ready(wait, clock=time.time, sleep=time.sleep):
    """Bounded tunnel gate; every probe is visible in the start/operator log."""
    began = clock()
    end = began + wait
    attempt = 0
    while True:
        attempt += 1
        ready, detail = tunnel_ready()
        print(f"OVERLAY: readiness try {attempt} at +{clock() - began:g}s: {detail}", flush=True)
        if ready or clock() >= end:
            return ready, detail
        sleep(min(max(0.1, float(os.environ.get("POG_OC_SLEEP", "2"))), max(0, end - clock())))


def reload_once(a, obs, *, wait=0, clock=time.time, sleep=time.sleep,
                startup_id=None, startup_retry=False):
    """One refresh after readiness, shared with startup/legacy recovery/watchdog across processes.

    Reserve the budget durably before OBS, including failed/ambiguous requests. Lock the separate
    budget file so the watchdog's other state writes cannot lose the reservation.
    """
    ready, detail = wait_ready(wait, clock, sleep)
    if not ready:
        return False, f"reload deferred: tunnel not ready ({detail})"
    path = Path(a.state + ".reload")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.seek(0)
            raw = f.read()
            previous = json.loads(raw) if raw else {}
            now = clock()
            interval = max(MIN_RELOAD_INTERVAL, a.again)
            # One extra startup attempt, tied to the first reservation. A new process/token
            # cannot bypass cooldown; watch and legacy recovery never receive this token.
            retry = (startup_retry and startup_id is not None
                     and previous.get("startup_id") == startup_id and not previous.get("retried"))
            if previous.get("at") is not None and now - previous["at"] < interval and not retry:
                return False, f"reload deferred: cooldown ({max(0, round(interval - (now - previous['at'])))} s left)"
            f.seek(0)
            f.truncate()
            json.dump({"at": now, "startup_id": startup_id, "retried": bool(startup_retry)}, f)
            f.flush()
            os.fsync(f.fileno())
            print(f"{time.strftime('%H:%M:%S')} OVERLAY: reload-overlay attempt after {detail}", flush=True)
            try:
                ok, out = obs("reload-overlay")
            except (OSError, subprocess.SubprocessError) as e:
                ok, out = False, type(e).__name__
            return ok, f"reload-overlay {'accepted' if ok else 'FAILED'}: {out}"
    except (OSError, ValueError, TypeError) as e:
        # An unwritable/corrupt budget must not permit repeated reloads.
        return False, f"reload deferred: budget unavailable ({type(e).__name__})"


def health_problem(st):
    """Only OBS main-page reports count; a fresh browser preview/portrait cannot hide a dead source."""
    if "health" not in st:
        return None  # compatible with pre-batch408 services
    now = st["now"]
    rows = [r for r in st["health"].get("sessions", [])
            if r.get("page") == "main" and r.get("capture") is True]
    latest = max(rows, key=lambda r: r.get("received_at", 0), default={})
    ago = now - (latest.get("received_at") or st.get("up") or now)
    if ago >= HEALTH_STALE:
        return f"no OBS main health report for {round(ago)} s"
    age = latest.get("state_age_s")
    if isinstance(age, (int, float)) and age >= HEALTH_STALE:
        return f"OBS main state stale for {round(age)} s"
    if latest and age is None and latest.get("age_s", 0) >= HEALTH_STALE:
        return "OBS main page has received no state for 120 s"
    return None


def source_shot():
    """Exactly one small source screenshot. No automatic websocket retry, no scene screenshot."""
    stub = os.environ.get("POG_OC_SHOT")
    if os.environ.get("POG_TEST") and not stub:
        return None
    t = time.monotonic()
    try:
        if stub:
            r = subprocess.run(shlex.split(stub), capture_output=True, text=True, timeout=8, check=True)
            data = json.loads(r.stdout)
        else:
            from stream.obsws import OBS
            client = OBS(timeout=3)
            try:
                data = client.call("GetSourceScreenshot", {"sourceName": "stream overlay",
                    "imageFormat": "png", "imageWidth": 480, "imageHeight": 270}, retry=False)
            finally:
                client.close()
        png = base64.b64decode(data["imageData"].split(",", 1)[1], validate=True)
        if not png.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("not PNG")
        return {"bytes": len(png), "near_empty": len(png) <= 2048,
                "ms": round((time.monotonic() - t) * 1000, 1)}
    except (OSError, ValueError, KeyError, IndexError, RuntimeError, subprocess.SubprocessError) as e:
        return {"error": type(e).__name__, "ms": round((time.monotonic() - t) * 1000, 1)}


def sample_source(state, now):
    """At most one shot/minute; two consecutive near-empty PNGs before treating it as blank.

    PNG size is a conservative heuristic, not proof of pixel transparency. Errors are reported,
    never used as evidence of a blank source. State contains metrics only, never image data.
    """
    if now - state.get("shot_at", -SHOT_INTERVAL) >= SHOT_INTERVAL:
        state["shot_at"] = now
        shot = source_shot()
        state["shot"] = shot
        state["empty_shots"] = state.get("empty_shots", 0) + 1 if shot and shot.get("near_empty") else 0
    shot = state.get("shot") or {}
    if state.get("empty_shots", 0) >= 2:
        return f"near-empty OBS source PNG ({shot.get('bytes')} bytes, two samples >=60 s apart)"
    return None


def watch_source(path, now):
    """Persist the sample reservation before OBS; overlapping watchdogs share the same limit."""
    path = Path(path + '.shot')
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('a+') as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.seek(0)
            raw = f.read()
            state = json.loads(raw) if raw else {}
            def write(value):
                f.seek(0)
                f.truncate()
                json.dump(value, f)
                f.flush()
                os.fsync(f.fileno())
            if now - state.get('shot_at', -SHOT_INTERVAL) >= SHOT_INTERVAL:
                write(dict(state, shot_at=now))
            problem = sample_source(state, now)
            write(state)
            return problem, state
    except (OSError, ValueError, TypeError) as e:
        return None, {'shot': {'error': f'sample state unavailable: {type(e).__name__}'}}
