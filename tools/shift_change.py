#!/usr/bin/env python3
"""Helpers for tools/shift-change.sh (one command for a shift change):

  tools/shift_change.py switches PREV_DIR [--explain]   PREV's switches as KEY=VALUE lines for start-team (one per
                                                        line, no quoting: `env` takes them); --explain says where each
                                                        came from
  tools/shift_change.py next-shift MINUTES [--gap MIN]  NEXT's end as an ISO time (POG_NEXT_SHIFT): now + MINUTES +
                                                        the gap (default 6: the start-team run itself)
  tools/shift_change.py health NEXT_DIR --team FILE --since EPOCH [--window S] [--broker] [--stream] [--obs CMD]
                                                        one health line; exit 1 when something is down

Switches, newest source first: runs/RUN/switches.env (start-team writes it from now on); the argv of PREV's helpers
while they still run (stream-service.pid: serve.py --viewers-youtube, caster.py --writer or --model, --urgent-model);
then start.log ("full tools: on", "RCON broker: on", "player votes: on", "helper caster ...", "helper analyst ..."),
caster.log's first line (writer=or:MODEL), stream.json (space_age), viewers-relay.on and team.txt (which
agent/team-*.tsv has the same names). A switch nothing tells is left out, so start-team's default applies.
"""
import argparse
import datetime
import glob
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYS = ["POG_BROKER", "POG_FULL_TOOLS", "POG_SPACE_AGE", "POG_YOUTUBE", "POG_CASTER_MODEL", "POG_CASTER_URGENT",
        "POG_CASTER", "POG_ANALYST", "POG_PLAYERS", "POG_VIEWER_RELAY", "POG_TEAM_FILE"]
# A harness Lua error in a reply: "runtime.lua:123: attempt to ...", "runtime:8746 attempt to compare ...".
LUA_ERROR = re.compile(r"\.lua:\d+:|runtime:\d+|attempt to (index|call|compare|perform|concatenate)")


def read(path):
    try:
        return open(path).read()
    except OSError:
        return ""


def ps_args(pid):
    """The command line of a running process, or None."""
    try:
        out = subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.strip() or None


def helper_args(rundir, ps=ps_args):
    """Command lines of PREV's helpers still running (stream-service.pid), split into words."""
    out = []
    for line in read(os.path.join(rundir, "stream-service.pid")).split():
        if line.isdigit():
            args = ps(int(line))
            if args:
                try:
                    out.append(shlex.split(args))
                except ValueError:
                    out.append(args.split())
    return out


def after(words, flag):
    return words[words.index(flag) + 1] if flag in words and words.index(flag) + 1 < len(words) else None


def team_file(rundir):
    """The agent/team-*.tsv whose names are the run's team (team.txt: name|label lines), or None."""
    names = [l.split("|", 1)[0] for l in read(os.path.join(rundir, "team.txt")).splitlines() if l.strip()]
    if not names:
        return None
    files = sorted(glob.glob(os.path.join(ROOT, "agent", "team-*.tsv")))
    default = os.path.join(ROOT, "agent", "team-nine.tsv")
    for f in ([default] if default in files else []) + [f for f in files if f != default]:
        members = [l.split("\t", 1)[0] for l in read(f).splitlines() if l.strip() and not l.startswith("#")]
        if members == names:
            return os.path.relpath(f, ROOT)
    return None


def switches(rundir, ps=ps_args):
    """{KEY: (value, source)} for the switches the run tells."""
    out = {}
    # 0. The viewer relay's live switch (rm/touch runs/RUN/viewers-relay.on mid-run) beats what the run started with.
    if os.path.exists(os.path.join(rundir, "start.log")) or os.path.exists(os.path.join(rundir, "switches.env")):
        out["POG_VIEWER_RELAY"] = ("1" if os.path.exists(os.path.join(rundir, "viewers-relay.on")) else "0", "viewers-relay.on")
    # 1. What start-team recorded (runs started after shift-change.sh existed).
    for line in read(os.path.join(rundir, "switches.env")).splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            if k in KEYS and k not in out:
                out[k] = (v, "switches.env")
    def put(k, v, src):
        if k not in out:
            out[k] = (v, src)
    # 2. The helpers' own arguments, while they run.
    for words in helper_args(rundir, ps):
        joined = " ".join(words)
        if "serve.py" in joined:
            put("POG_YOUTUBE", after(words, "--viewers-youtube") or "", "serve.py's arguments")
        if "caster.py" in joined:
            put("POG_CASTER", "1", "caster.py running")
            put("POG_CASTER_MODEL", after(words, "--model") if "--writer" in words else "", "caster.py's arguments")
            if "--urgent-model" in words:
                put("POG_CASTER_URGENT", after(words, "--urgent-model"), "caster.py's arguments")
        if "analyst.py" in joined:
            put("POG_ANALYST", "1", "analyst.py running")
    # 3. The start log and the run's files.
    log = read(os.path.join(rundir, "start.log"))
    for key, label in (("POG_FULL_TOOLS", "full tools"), ("POG_BROKER", "RCON broker"), ("POG_PLAYERS", "player votes")):
        m = re.search(r"^\S+ " + label + r": (on|off)", log, re.M)
        if m:
            put(key, "1" if m.group(1) == "on" else "0", "start.log")
    if re.search(r"^\S+ helper \w", log, re.M):  # the helpers' lines are there: one missing was off
        put("POG_CASTER", "1" if re.search(r"^\S+ helper caster ", log, re.M) else "0", "start.log")
        put("POG_ANALYST", "1" if re.search(r"^\S+ helper analyst ", log, re.M) else "0", "start.log")
    m = re.search(r"writer=(\S+)", read(os.path.join(rundir, "caster.log")).split("\n", 1)[0])
    if m:
        put("POG_CASTER_MODEL", m.group(1)[3:] if m.group(1).startswith("or:") else "", "caster.log")
    try:
        sj = json.load(open(os.path.join(rundir, "stream.json")))
        put("POG_SPACE_AGE", "1" if sj.get("space_age") else "0", "stream.json")
    except (OSError, ValueError):
        pass
    tf = team_file(rundir)
    if tf:
        put("POG_TEAM_FILE", tf, "team.txt")
    return {k: out[k] for k in KEYS if k in out}


def next_shift(minutes, gap=6, now=None):
    t = (time.time() if now is None else now) + (float(minutes) + gap) * 60
    return datetime.datetime.fromtimestamp(round(t / 60) * 60).astimezone().isoformat(timespec="minutes")


def journal_lines(path):
    for line in read(path).splitlines():
        try:
            yield json.loads(line)
        except ValueError:
            pass


def stamp(at):
    try:
        return datetime.datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def health(rundir, team, since, window=180, broker=False, stream=False, obs=None, state_url="http://127.0.0.1:8788/state.json"):
    """(ok, line): agents up (a request in the journal since the start), broker sockets, OBS and the stream service,
    the viewer relay switch, harness Lua errors in replies during the first `window` seconds."""
    names = [l.split("\t", 1)[0] for l in read(team).splitlines() if l.strip() and not l.startswith("#")]
    parts, bad = [], []
    up, errors, faults = [], [], set()
    for name in names:
        seen = False
        for e in journal_lines(os.path.join(rundir, name, "journal.jsonl")):
            t = stamp(e.get("at"))
            if t is None or t < since:
                continue
            if e.get("event") == "request":
                seen = True
            if e.get("event") == "response" and t <= since + window:
                r = e.get("response") or {}
                err = r.get("error")
                text = err.get("message") if isinstance(err, dict) else err
                if not r.get("ok") and text and LUA_ERROR.search(str(text)):
                    errors.append(f"{name}: {str(text)[:120]}")
                res = r.get("result")
                if isinstance(res, dict) and res.get("runtime_fault"):
                    faults.add(str(res["runtime_fault"])[:120])
        if seen:
            up.append(name)
    missing = [n for n in names if n not in up]
    parts.append(f"agents {len(up)}/{len(names)} up" + (f" (no request yet: {', '.join(missing)})" if missing else ""))
    if missing:
        bad.append("agents")
    if broker:
        socks, dead = 0, []
        for name in names:
            path = os.path.join(rundir, ".sock", name + ".sock")
            try:
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(2)
                s.connect(path)
                s.close()
                socks += 1
            except OSError:
                dead.append(name)
        parts.append(f"broker {'up' if not dead else 'DOWN for ' + ', '.join(dead)} ({socks}/{len(names)} sockets)")
        if dead:
            bad.append("broker")
    else:
        parts.append("broker off")
    try:
        with urllib.request.urlopen(state_url, timeout=5) as r:
            status = getattr(r, "status", None) or 200  # a file:// URL (tests) has none
            service = "service ok" if status == 200 else f"service HTTP {status}"
    except Exception as e:  # noqa: BLE001
        service = f"service DOWN ({type(e).__name__})"
        bad.append("stream service")
    if obs:
        out = run_words(obs + ["stream-status" if stream else "status"])
        active = "active=True" in out
        what = "streaming" if stream else "recording"
        parts.append(f"OBS {what if active else 'NOT ' + what}, {service}")
        if not active:
            bad.append("OBS")
    else:
        parts.append(service)
    parts.append("relay " + ("on" if os.path.exists(os.path.join(rundir, "viewers-relay.on")) else "off"))
    minutes = round(window / 60)
    if errors or faults:
        parts.append(f"harness Lua errors in the first {minutes} min: {len(errors)}" + (f", runtime_fault {sorted(faults)[0]}" if faults else ""))
        bad.append("Lua errors")
    else:
        parts.append(f"no harness Lua errors in the first {minutes} min")
    line = "health: " + "; ".join(parts)
    for e in errors[:5]:
        line += "\n  " + e
    return not bad, line


def run_words(words):
    try:
        return subprocess.run(words, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        return str(e)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("switches"); s.add_argument("rundir"); s.add_argument("--explain", action="store_true")
    n = sub.add_parser("next-shift"); n.add_argument("minutes", type=float); n.add_argument("--gap", type=float, default=6)
    h = sub.add_parser("health"); h.add_argument("rundir"); h.add_argument("--team", required=True)
    h.add_argument("--since", type=float, required=True); h.add_argument("--window", type=float, default=180)
    h.add_argument("--broker", action="store_true"); h.add_argument("--stream", action="store_true")
    h.add_argument("--obs", help="the OBS control command (words), e.g. 'tools/.venv/bin/python tools/obs.py'")
    h.add_argument("--state-url", default="http://127.0.0.1:8788/state.json")
    a = ap.parse_args()
    if a.cmd == "switches":
        for k, (v, src) in switches(a.rundir).items():
            print(f"{k}={v}" + (f"   ({src})" if a.explain else ""))
    elif a.cmd == "next-shift":
        print(next_shift(a.minutes, a.gap))
    else:
        ok, line = health(a.rundir, a.team, a.since, a.window, a.broker, a.stream, shlex.split(a.obs) if a.obs else None,
                          a.state_url)
        print(line)
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
