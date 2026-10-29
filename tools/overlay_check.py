#!/usr/bin/env python3
"""Is the stream overlay's page connected to the stream service? (d29 batch347 OR, viewer Aurora site:5491: shift100's
start left the "stream overlay" browser source blank for 26 minutes, with no right panel and no voices; the tunnel
answered and the page was served, a refreshnocache did not help, and turning the scene item off and on brought it back
at once.)

  python3 tools/overlay_check.py start --since EPOCH [--wait 30]   # after a start's reload (tools/obs-steps.sh)
  python3 tools/overlay_check.py watch [--stale 120] [--state FILE]  # one pass of a run's watchdog
  python3 tools/overlay_check.py status                            # the main page's stream, one line

The page names itself on its one event stream (/events?audio=1&page=main; the portrait page is "portrait"), and the
service keeps each page's open streams, last connect and last write (GET /overlay/status, tools/stream/serve.py). The
main page is connected when a stream of it is open and had a write in the last 60 s (the service writes at least every
15 s).

start: connected with a connect at or after --since within --wait s: "overlay: connected N s after the reload". Else
the scene item is turned off and on (tools/obs.py toggle-overlay) and checked again for --wait s: "overlay: not
connected N s after the reload; toggled the source: connected N s later", exit 0; or "overlay: FAILED: not connected
after the reload nor after a toggle", exit 1 (the health line then says overlay NOT connected).

watch: nothing printed while it is connected. Not connected for --stale s (default 120; since its stream closed, or
since the service started when it never connected): one toggle, then up to --wait s (default 30) for a connect: "OVERLAY: no main
overlay stream for N s; toggled the source: connected again" or "OVERLAY: ... still not connected" (exit 1). After a
toggle it waits --again s (default 600) before toggling again, and says each pass that it is still down. The state
(last toggle) is kept in --state (default /tmp/claude-501/overlay-check.json).

(d29 batch349 SP, viewer Aurora: "so 'live' alone cannot pass next shift") status and watch also read:
- speech: the service's summary of the page's clip reports (/overlay/status speech): the last clip played whole (state
  end, played >= its length - 0.5 s, not early) and how many in 30 min; bad when clips posted in the last 15 min whose
  time is up (ended, skipped or expired) include none played whole (shift100's blank overlay: none reported at all).
  watch says it only when bad, at most once per --again s; no toggle for speech alone (a page not connected is the
  toggle above);
- the panel: the page's own report that it drew (POST /overlay/render after a state frame, at most every 30 s, with its
  right panel's height): bad when the last is over 90 s old or 0 px high; a page from before batch349 says nothing;
- cams: each camera client's controller by one RCON line on --world (POG_WORLD, else n; 0.68 ms on n, d29): bad for a
  connected one in a cutscene or a character controller. The runtime puts such a client back itself (cameras.lua's
  tick: make_director, exit_cutscene then spectator, every tick while it is not a spectator), so this is a report.
watch prints the panel and cams lines once per change (and when they are good again). Stubs: POG_OC_CAMS (a command
printing the cams JSON); under POG_TEST no world is read without it.

A service from before batch347 has no /overlay/status: "overlay check: skipped (the service has no /overlay/status)",
exit 0, no toggle. Stubs for tests: POG_OC_OBS (the toggle command, split on spaces), POG_OC_SLEEP (seconds between
polls, default 2).
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICE = "http://127.0.0.1:8788"
FRESH_S = 60  # an open stream with no write for this long is taken as gone


class NoStatus(Exception):
    pass


class Down(Exception):
    """The service does not answer."""


def read(service):
    try:
        with urllib.request.urlopen(service.rstrip("/") + "/overlay/status", timeout=5) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise NoStatus()
        raise Down(f"HTTP {e.code}")
    except (OSError, ValueError) as e:
        raise Down(type(e).__name__)


def page(st, name="main"):
    return (st.get("pages") or {}).get(name) or {}


def connected(st, since=None, name="main"):
    """The page has a fresh open stream (and with since: one that connected at or after it)."""
    p, now = page(st, name), st.get("now") or time.time()
    if not p.get("open") or not p.get("seen") or now - p["seen"] > FRESH_S:
        return False
    return since is None or (p.get("connected") or 0) >= since


CAMS_LINE = ("/silent-command local ok,r=pcall(remote.call,'agent_harness','cameras') local names={} "
             "for k,v in pairs(defines.controllers) do names[v]=k end local out={} if ok and type(r)=='string' then "
             "local t=helpers.json_to_table(r) for _,c in ipairs(t and t.cameras or {}) do local p=game.get_player(c.player) "
             "if p then out[#out+1]={name=p.name,controller=names[p.controller_type] or tostring(p.controller_type),"
             "connected=p.connected} end end end rcon.print(helpers.table_to_json(out))")
BAD_CONTROLLERS = ("cutscene", "character")
PANEL_FRESH_S = 90  # a page that drew reports every 30 s


def speech(st, now=None):
    """(d29 batch349 SP) (line, bad) from the service's speech summary, or (None, False) from a service without it."""
    sp = st.get("speech")
    if not isinstance(sp, dict):
        return None, False
    now = now or st.get("now") or time.time()
    due, whole = sp.get("due_15m") or 0, sp.get("due_15m_whole") or 0
    if due and not whole:
        skipped = sp.get("due_15m_skipped") or 0
        return (f"speech NOT playing: {due} clip{'s' if due != 1 else ''} posted in the last 15 min, none played whole"
                f" ({skipped} skipped, {due - skipped} with no end reported)"), True
    last = sp.get("last_whole")
    if not last:
        return "speech: no clip played whole since the service started", False
    ago = max(0, round((now - last) / 60))
    return f"speech: last clip played whole {ago} min ago, {sp.get('whole_30m') or 0} in 30 min", False


def panel(st, name="main"):
    """(d29 batch349) (line, bad) for the page's own report that it drew (POST /overlay/render), or (None, False) from a
    page or service without it."""
    p, now = page(st, name), st.get("now") or time.time()
    if not p.get("rendered"):
        return None, False
    ago, px = round(now - p["rendered"]), p.get("panel_px")
    if ago > PANEL_FRESH_S:
        return f"panel NOT drawn (its last report {ago} s ago)", True
    if not px:
        return f"panel NOT drawn ({px or 0} px high {ago} s ago)", True
    return f"panel drew {px} px {ago} s ago", False


def cameras(world=None):
    """(d29 batch349) [{name, controller, connected}] of the camera clients, by one RCON line (0.68 ms on world n,
    d29), or None when it cannot be read. POG_OC_CAMS: a stub command printing that JSON."""
    cmd = os.environ.get("POG_OC_CAMS")
    if not cmd and os.environ.get("POG_TEST"):
        return None  # a test reads no world without a stub
    words = cmd.split() if cmd else [sys.executable, os.path.join(HERE, "pog.py"), "--world", world or os.environ.get("POG_WORLD", "n"), "rcon", CAMS_LINE]
    try:
        r = subprocess.run(words, capture_output=True, text=True, timeout=20)
        out = r.stdout.strip().splitlines()
        return json.loads(out[-1]) if out else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def cams_line(cams):
    """(line, bad): "cams: pog-cam1 spectator" (the connected ones; bad: one in a cutscene or a character controller)."""
    if cams is None:
        return None, False
    if isinstance(cams, dict):
        cams = []
    on = [c for c in cams if c.get("connected")]
    if not on:
        return "cams: none connected", False
    bad = [c for c in on if c.get("controller") in BAD_CONTROLLERS]
    return "cams: " + ", ".join(f"{c.get('name')} {c.get('controller')}" for c in on), bool(bad)


def toggle():
    cmd = os.environ.get("POG_OC_OBS")
    words = cmd.split() if cmd else [os.path.join(HERE, ".venv", "bin", "python") if os.path.exists(os.path.join(HERE, ".venv", "bin", "python"))
                                     else os.path.expanduser("~/code/player-of-games/tools/.venv/bin/python"), os.path.join(HERE, "obs.py")]
    r = subprocess.run(words + ["toggle-overlay"], capture_output=True, text=True, timeout=60)
    out = (r.stdout.strip().splitlines() or [r.stderr.strip()[-160:]])[-1] if (r.stdout or r.stderr) else ""
    return r.returncode == 0, out


def wait_for(service, since, wait, step, clock=time.time, sleep=time.sleep):
    """Seconds until the main page connected at or after since, or None after wait s."""
    end = clock() + wait
    while True:
        st = read(service)
        if connected(st, since):
            return max(0, round(page(st).get("connected") - since))
        if clock() >= end:
            return None
        sleep(step)


def start(a, clock=time.time, sleep=time.sleep):
    step = float(os.environ.get("POG_OC_SLEEP", "2"))
    try:
        got = wait_for(a.service, a.since, a.wait, step, clock, sleep)
    except NoStatus:
        print("overlay check: skipped (the service has no /overlay/status)")
        return 0
    except Down as e:
        print(f"overlay: FAILED: the stream service does not answer ({e})")
        return 1
    if got is not None:
        print(f"overlay: connected {got} s after the reload")
        return 0
    ok, out = toggle()
    if not ok:
        print(f"overlay: FAILED: not connected {a.wait:g} s after the reload, and the toggle failed: {out}")
        return 1
    t = clock()
    try:
        again = wait_for(a.service, t, a.wait, step, clock, sleep)
    except (NoStatus, Down) as e:
        again = None
        out = f"{out}; then the service did not answer ({e})"
    if again is not None:
        print(f"overlay: not connected {a.wait:g} s after the reload; toggled the source: connected {again} s later")
        return 0
    print(f"overlay: FAILED: not connected {a.wait:g} s after the reload nor {a.wait:g} s after a toggle ({out})")
    return 1


def load_state(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    try:
        with open(path, "w") as f:
            json.dump(state, f)
    except OSError:
        pass


def watch(a, clock=time.time, sleep=time.sleep):
    try:
        st = read(a.service)
    except NoStatus:
        return 0  # an older service: nothing to say each pass
    except Down as e:
        print(f"{time.strftime('%H:%M')} OVERLAY: the stream service does not answer ({e})")
        return 1
    rc = watch_overlay(a, st, clock, sleep)
    return max(rc, watch_more(a, st, clock))


def watch_more(a, st, clock=time.time):
    """(d29 batch349 SP) speech, the panel's own report and the cameras: speech only when it is bad (at most once per
    --again s), the panel and the cameras once per change of their line."""
    state = load_state(a.state)
    stamp, now, rc = time.strftime("%H:%M"), st.get("now") or clock(), 0
    line, bad = speech(st, now)
    if bad:
        rc = 1
        if not state.get("speech_said") or now - state["speech_said"] >= a.again:
            print(f"{stamp} SPEECH: {line}")
            state["speech_said"] = now
    elif line and state.get("speech_said"):
        print(f"{stamp} speech again: {line}")
        state["speech_said"] = None
    for key, (text, worse) in (("panel", panel(st)), ("cams", cams_line(cameras(getattr(a, "world", None))))):
        if text is None:
            continue
        rc = max(rc, 1 if worse else 0)
        if state.get(key) != text and (worse or state.get(key + "_bad")):
            print(f"{stamp} {key.upper() if worse else key}: {text}")
        state[key], state[key + "_bad"] = text, worse
    save_state(a.state, state)
    return rc


def watch_overlay(a, st, clock=time.time, sleep=time.sleep):
    if connected(st):
        return 0
    now = st.get("now") or clock()
    p = page(st)
    since = p.get("closed") or p.get("seen") or st.get("up") or now
    gone = round(now - since)
    if gone < a.stale:
        return 0
    state = load_state(a.state)
    stamp = time.strftime("%H:%M")
    if state.get("toggled") and now - state["toggled"] < a.again:
        print(f"{stamp} OVERLAY: no main overlay stream for {gone} s; still not connected (toggled {round(now - state['toggled'])} s ago)")
        return 1
    ok, out = toggle()
    state["toggled"] = clock()
    save_state(a.state, state)
    if not ok:
        print(f"{stamp} OVERLAY: no main overlay stream for {gone} s; the toggle failed: {out}")
        return 1
    try:
        got = wait_for(a.service, state["toggled"], a.wait, float(os.environ.get("POG_OC_SLEEP", "2")), clock, sleep)
    except (NoStatus, Down):
        got = None
    if got is not None:
        print(f"{stamp} OVERLAY: no main overlay stream for {gone} s; toggled the source: connected again ({got} s)")
        return 0
    print(f"{stamp} OVERLAY: no main overlay stream for {gone} s; toggled the source: still not connected")
    return 1


def status(a):
    try:
        st = read(a.service)
    except NoStatus:
        print("overlay status: n/a (the service has no /overlay/status)")
        return 0
    except Down as e:
        print(f"overlay NOT connected (the service does not answer: {e})")
        return 1
    p = page(st)
    more = [x for x in (speech(st), panel(st), cams_line(cameras(a.world))) if x[0]]
    tail = "".join("; " + t for t, _ in more)
    if connected(st):
        print(f"overlay connected ({p.get('open')} stream{'s' if p.get('open') != 1 else ''}, since {round(st['now'] - p['connected'])} s){tail}")
        return 1 if any(b for _, b in more) else 0
    print("overlay NOT connected" + (f" (closed {round(st['now'] - p['closed'])} s ago)" if p.get("closed") else " (never since the service started)") + tail)
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["start", "watch", "status"])
    ap.add_argument("--service", default=SERVICE)
    ap.add_argument("--since", type=float, help="start: the reload's time (epoch seconds)")
    ap.add_argument("--wait", type=float, default=30)
    ap.add_argument("--stale", type=float, default=120)
    ap.add_argument("--again", type=float, default=600)
    ap.add_argument("--state", default="/tmp/claude-501/overlay-check.json")
    ap.add_argument("--world", default=None, help="the world the camera clients are on (default POG_WORLD, else n)")
    a = ap.parse_args(argv)
    if a.cmd == "start":
        if a.since is None:
            ap.error("start needs --since")
        return start(a)
    if a.cmd == "watch":
        return watch(a)
    return status(a)


if __name__ == "__main__":
    sys.exit(main())
