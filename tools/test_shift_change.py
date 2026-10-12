#!/usr/bin/env python3
"""tools/shift-change.sh with stubs for every outside command: python3 tools/test_shift_change.py

- switches: switches.env first, then the helpers' own arguments, then start.log, caster.log, stream.json and team.txt;
  the viewer relay's live file beats what the run started with; a switch nothing tells is left out.
- refusals: PREV without agents' notes, a quota WARNING, the box unreachable, OBS down, another start-team running,
  PREV streaming without --stream/--no-stream; --ignore skips a named check.
- --dry-run: the plan and start-team's own dry run with PREV's switches; nothing stopped or started.
- a shift change: stop-team PREV with POG_STOP_WORLD=1, PREV's panes closed, start-team NEXT with PREV's switches,
  POG_RESUME and POG_NEXT_SHIFT; then a health line and PREV's console audit; a harness Lua error makes it exit 1.
- start-team.sh writes switches.env with every switch shift-change reads.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import shift_change as sc  # noqa: E402

TEAM = os.path.join(ROOT, "agent", "team-nine.tsv")
NAMES = [l.split("\t", 1)[0] for l in open(TEAM) if l.strip() and not l.startswith("#")]

STUB = """#!/usr/bin/env bash
# logs its name, arguments and the switches it was given
{ printf '%s' "$(basename "$0")"; printf ' %s' "$@"; echo; env | grep -E '^POG_' | grep -v '^POG_SC_' | sort | sed 's/^/  /'; } >> "$STUB_LOG"
"""
START = STUB + """
[ "${POG_DRY_RUN:-0}" = 1 ] && { echo "start-team dry run"; exit 0; }
# agents launch: a request in each journal; LUA_ERROR_FOR gets a harness Lua error in its reply
for n in $STUB_NAMES; do
  mkdir -p "$STUB_RUNS/$1/$n"
  at=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
  echo "{\\"at\\":\\"$at\\",\\"event\\":\\"request\\",\\"request\\":{\\"action\\":\\"status\\",\\"bot\\":\\"$n\\"}}" >> "$STUB_RUNS/$1/$n/journal.jsonl"
  if [ "$n" = "${LUA_ERROR_FOR:-}" ]; then
    echo "{\\"at\\":\\"$at\\",\\"event\\":\\"response\\",\\"response\\":{\\"ok\\":false,\\"error\\":{\\"code\\":\\"runtime_error\\",\\"message\\":\\"runtime:8746: attempt to compare number with nil\\"}}}" >> "$STUB_RUNS/$1/$n/journal.jsonl"
  fi
done
touch "$STUB_RUNS/$1/viewers-relay.on"
exit "${START_FAILS:-0}"
"""
QUOTA = STUB + """
echo "quota claude_personal (sonnet,haiku) 5-hour session: 2% used: ok"
[ -n "${QUOTA_WARN:-}" ] && echo "WARNING quota agy_local (gemini) Gemini 5-hour: likely to run dry at about 01:37"
exit 0
"""
SSH = STUB + 'exit "${BOX_DOWN:-0}"\n'
OBS = STUB + """
[ -n "${OBS_DOWN:-}" ] && { echo "ConnectionRefusedError" >&2; exit 1; }
case $1 in
  status) echo "active=True paused=False time=01:00:00" ;;
  stream-status) echo "active=${STREAMING:-False} reconnecting=False" ;;
esac
"""
PGREP = STUB + '[ -n "${OTHER_START:-}" ] && echo 4242; exit 0\n'
# tools/site-refresh.sh: its last line says how it went, as the real one's does
SITE = STUB + """
if [ -n "${SITE_FAILS:-}" ]; then echo "03:00:01 site-refresh: FAILED: deploy to preview (production left as it was)"; exit 1; fi
echo "03:00:01 site-refresh: done"
"""
HERDR = STUB + "exit 0\n"


def started(calls, name):
    """Whether the stub log has a call of `name` (a line starting with it)."""
    return any(l.startswith(name + " ") for l in calls.splitlines())


def setup():
    tmp = tempfile.mkdtemp(prefix="shiftchange")
    runs, bin_ = os.path.join(tmp, "runs"), os.path.join(tmp, "bin")
    os.makedirs(bin_)
    for name, body in (("stop-team", STUB), ("start-team", START), ("quota", QUOTA), ("ssh", SSH), ("obs", OBS),
                       ("pgrep", PGREP), ("herdr", HERDR), ("site-refresh", SITE)):
        p = os.path.join(bin_, name)
        open(p, "w").write(body)
        os.chmod(p, 0o755)
    prev = os.path.join(runs, "shake11")
    for n in NAMES:
        os.makedirs(os.path.join(prev, n))
        open(os.path.join(prev, n, "notes.md"), "w").write("# notes\n")
    open(os.path.join(prev, "start.log"), "w").write(
        "22:50:34 full tools: on (docs/TOOLS-NOTES.md)\n22:50:34 RCON broker: on (agents get no password)\n"
        "22:50:34 player votes: off\n22:53:21 helper stream-service pid 1 up: x\n22:53:21 helper caster pid 2 up: x\n"
        "22:53:21 helper analyst pid 3 up: x\n")
    open(os.path.join(prev, "caster.log"), "w").write("22:53:13 [caster] feed http://127.0.0.1:8788  writer=or:anthropic/claude-opus-5.5  tts=auto\n")
    json.dump({"space_age": True}, open(os.path.join(prev, "stream.json"), "w"))
    open(os.path.join(prev, "viewers-relay.on"), "w").close()
    open(os.path.join(prev, "team.txt"), "w").write("".join(f"{n}|X (y)\n" for n in NAMES))
    open(os.path.join(prev, "panes.txt"), "w").write("".join(f"{n} w1:p{i} claude\n" for i, n in enumerate(NAMES)))
    json.dump({"ok": True, "tick": 9, "harness": 120, "other": 1, "entries": [
        {"seq": 1, "command": "kick", "first_text": "nick mined the bus", "count": 1, "first_tick": 5, "last_tick": 5,
         "players": ["rcon"]}]}, open(os.path.join(prev, "console-audit.json"), "w"))
    state = os.path.join(tmp, "state.json")
    open(state, "w").write("{}")
    return tmp, runs, bin_, state


def run(tmp, runs, bin_, state, *args, **env):
    e = dict(os.environ, POG_SC_STOP_TEAM=f"{bin_}/stop-team", POG_SC_START_TEAM=f"{bin_}/start-team",
             POG_SC_QUOTA=f"{bin_}/quota", POG_SC_SSH=f"{bin_}/ssh", POG_SC_OBS=f"{bin_}/obs", POG_SC_PGREP=f"{bin_}/pgrep",
             POG_SC_HERDR=f"{bin_}/herdr", POG_SC_RUNS=runs, POG_SC_STATE_URL="file://" + state, POG_SC_HEALTH_WAIT="0",
             POG_SC_SITE_REFRESH=f"{bin_}/site-refresh",  # never the real one: it deploys the site
             STUB_LOG=os.path.join(tmp, "calls.log"), STUB_RUNS=runs, STUB_NAMES=" ".join(NAMES))
    for k in [k for k in e if k.startswith("POG_") and not k.startswith("POG_SC_")]:
        del e[k]
    e.update(env)
    open(e["STUB_LOG"], "w").close()
    r = subprocess.run([os.path.join(ROOT, "tools", "shift-change.sh"), *args], cwd=ROOT, env=e, capture_output=True,
                       text=True, timeout=120)
    return r, open(e["STUB_LOG"]).read()


def switches():
    tmp, runs, _, _ = setup()
    try:
        prev = os.path.join(runs, "shake11")
        got = sc.switches(prev, ps=lambda pid: None)
        assert {k: v for k, (v, _) in got.items()} == {
            "POG_BROKER": "1", "POG_FULL_TOOLS": "1", "POG_SPACE_AGE": "1", "POG_CASTER_MODEL": "anthropic/claude-opus-5.5",
            "POG_CASTER": "1", "POG_ANALYST": "1", "POG_PLAYERS": "0", "POG_VIEWER_RELAY": "1",
            "POG_TEAM_FILE": "agent/team-nine.tsv"}, got
        assert "POG_YOUTUBE" not in got  # nothing tells: start-team's default
        # The helpers' arguments, while they run.
        open(os.path.join(prev, "stream-service.pid"), "w").write("11\n12\n13\n")
        argv = {11: "python3 tools/stream/serve.py --world n --viewers-site --viewers-youtube dQw4w9WgXcQ --viewers-relay x",
                12: "python3 tools/stream/caster.py --feed http://127.0.0.1:8788 --writer or --model anthropic/claude-sonnet-5.5 --urgent-model or:anthropic/claude-haiku-5.5",
                13: None}
        got = sc.switches(prev, ps=argv.get)
        assert got["POG_YOUTUBE"] == ("dQw4w9WgXcQ", "serve.py's arguments"), got
        assert got["POG_CASTER_MODEL"][0] == "anthropic/claude-sonnet-5.5"
        assert got["POG_CASTER_URGENT"][0] == "or:anthropic/claude-haiku-5.5"
        argv[11] = "python3 tools/stream/serve.py --world n --viewers-site"
        argv[12] = "python3 tools/stream/caster.py --feed x --tts auto"
        got = sc.switches(prev, ps=argv.get)
        assert got["POG_YOUTUBE"][0] == "" and got["POG_CASTER_MODEL"][0] == "", got  # YouTube off; Workers AI writer
        # switches.env first; the relay's live file beats it.
        open(os.path.join(prev, "switches.env"), "w").write("POG_BROKER=0\nPOG_YOUTUBE=@NickWinter\nPOG_VIEWER_RELAY=1\nPOG_BOGUS=1\n")
        os.remove(os.path.join(prev, "viewers-relay.on"))
        got = sc.switches(prev, ps=argv.get)
        assert got["POG_BROKER"] == ("0", "switches.env") and got["POG_YOUTUBE"][0] == "@NickWinter", got
        assert got["POG_VIEWER_RELAY"] == ("0", "viewers-relay.on") and "POG_BOGUS" not in got, got
        # NEXT's end, as an ISO time to the minute.
        assert sc.next_shift(240, 6, now=0).startswith("1970-01-01T") or sc.next_shift(240, 6, now=0).startswith("1969-12-31T")
        print("switches: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def refusals():
    tmp, runs, bin_, state = setup()
    try:
        cases = [({"QUOTA_WARN": "1"}, "check quota: FAILED: WARNING quota agy_local"),
                 ({"BOX_DOWN": "1"}, "check box: FAILED: pogwin is not reachable"),
                 ({"OBS_DOWN": "1"}, "check obs: FAILED: OBS is not answering"),
                 ({"OTHER_START": "1"}, "check running: FAILED: another start-team is running (pid 4242)"),
                 ({"STREAMING": "True"}, "check stream: FAILED: shake11 is streaming: pass --stream")]
        for env, text in cases:
            r, calls = run(tmp, runs, bin_, state, "shake11", "shake12", "240", **env)
            assert r.returncode == 2 and text in r.stdout, (env, r.stdout, r.stderr)
            assert "refused:" in r.stderr and not started(calls, "stop-team") and not started(calls, "start-team"), (env, calls)
        r, calls = run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--ignore", "quota", "--dry-run", QUOTA_WARN="1")
        assert r.returncode == 0 and "check quota: FAILED, ignored (--ignore quota)" in r.stdout, r.stdout + r.stderr
        r, _ = run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--no-stream", "--dry-run", STREAMING="True")
        assert r.returncode == 0, r.stdout + r.stderr
        # A PREV whose agents never launched (shake9).
        os.makedirs(os.path.join(runs, "shake9"))
        r, _ = run(tmp, runs, bin_, state, "shake9", "shake12", "240")
        assert r.returncode == 2 and "shake9 ran no agents (no notes.md" in r.stdout, r.stdout
        r, _ = run(tmp, runs, bin_, state, "nope", "shake12", "240")
        assert r.returncode == 2 and "no run directory for nope" in r.stderr, r.stderr
        r, _ = run(tmp, runs, bin_, state, "shake11", "shake11", "240")
        assert r.returncode == 64 and "same run" in r.stderr
        print("refusals: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def dry_run():
    tmp, runs, bin_, state = setup()
    try:
        r, calls = run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--stream", "--dry-run", STREAMING="True")
        assert r.returncode == 0, r.stdout + r.stderr
        assert "POG_BROKER=1   (start.log)" in r.stdout and "POG_CASTER_MODEL=anthropic/claude-opus-5.5   (caster.log)" in r.stdout
        assert "close 9 agent panes of shake11" in r.stdout and "POG_RESUME=shake11, POG_NEXT_SHIFT=" in r.stdout, r.stdout
        assert "start-team dry run" in r.stdout
        assert not started(calls, "stop-team") and not started(calls, "herdr"), calls
        start = calls.split("\nstart-team", 1)[1]
        for line in ("POG_DRY_RUN=1", "POG_BROKER=1", "POG_FULL_TOOLS=1", "POG_SPACE_AGE=1", "POG_RESUME=shake11",
                     "POG_TEAM_FILE=agent/team-nine.tsv"):
            assert "  " + line in start, (line, start)
        assert start.startswith(" shake12 240 --stream"), start
        assert not os.path.exists(os.path.join(runs, ".shift-change.lock"))
        print("dry run: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def change():
    tmp, runs, bin_, state = setup()
    try:
        # The broker's sockets cannot be made here (the engineer sandbox refuses Unix sockets): this shift runs without
        # it; unhealthy() checks a broker shift whose sockets are missing.
        log = os.path.join(runs, "shake11", "start.log")
        text = open(log).read().replace("RCON broker: on", "RCON broker: off")
        open(log, "w").write(text)
        r, calls = run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--stream", STREAMING="True")
        assert r.returncode == 0, r.stdout + r.stderr
        stop, rest = calls.split("\nstart-team", 1)
        assert "stop-team shake11\n" in stop and "  POG_STOP_WORLD=1" in stop, stop
        assert stop.count("herdr pane close w1:p") == len(NAMES), stop
        assert rest.startswith(" shake12 240 --stream\n"), rest
        for line in ("POG_RESUME=shake11", "POG_BROKER=0", "POG_FULL_TOOLS=1", "POG_SPACE_AGE=1",
                     "POG_CASTER_MODEL=anthropic/claude-opus-5.5", "POG_VIEWER_RELAY=1", "POG_PLAYERS=0"):
            assert "  " + line + "\n" in rest, (line, rest)
        nxt = [l for l in rest.splitlines() if l.startswith("  POG_NEXT_SHIFT=")][0]
        assert "T" in nxt and nxt[-6] in "+-", nxt
        assert "POG_DRY_RUN" not in rest
        out = r.stdout
        assert f"closed {len(NAMES)} agent panes of shake11" in out, out
        assert f"health: agents {len(NAMES)}/{len(NAMES)} up" in out, out
        assert "broker off" in out and "OBS streaming, service ok" in out and "relay on" in out and "no harness Lua errors in the first" in out, out
        assert "console audit of shake11:" in out and "moderation: 1 shapes, 1 commands" in out, out
        assert not os.path.exists(os.path.join(runs, ".shift-change.lock"))
        # the site: refreshed for shake11 once it was stopped (in the background), its outcome reported at the end
        assert "site-refresh --last-run shake11\n" in calls, calls
        assert calls.index("site-refresh --last-run shake11") > calls.index("stop-team shake11"), calls
        assert "site refresh started" in out and "site refresh: done" in out, out
        assert os.path.exists(os.path.join(runs, "shake11", "site-refresh.log"))
        # a failed site refresh never fails the shift
        shutil.rmtree(os.path.join(runs, "shake12"))
        r, calls = run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--stream", STREAMING="True", SITE_FAILS="1")
        assert r.returncode == 0 and started(calls, "start-team"), r.stdout + r.stderr
        assert "site refresh FAILED (the shift is unaffected): FAILED: deploy to preview" in r.stdout, r.stdout
        # POG_SITE_REFRESH=0 skips it
        shutil.rmtree(os.path.join(runs, "shake12"))
        r, calls = run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--stream", STREAMING="True", POG_SITE_REFRESH="0")
        assert r.returncode == 0 and "site-refresh" not in calls and "site refresh" not in r.stdout, r.stdout
        print("shift change: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def unhealthy():
    tmp, runs, bin_, state = setup()
    try:
        r, _ = run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--stream", STREAMING="True", LUA_ERROR_FOR="sol")
        assert r.returncode == 1 and "harness Lua errors in the first " in r.stdout and ": 1" in r.stdout and "sol: runtime:8746" in r.stdout, r.stdout
        # shake11 ran the broker: no sockets for shake12 is a broker down.
        assert "broker DOWN for astra" in r.stdout and "(0/9 sockets)" in r.stdout, r.stdout
        shutil.rmtree(os.path.join(runs, "shake12"))
        r, _ = run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--stream", STREAMING="True", START_FAILS="1")
        assert r.returncode == 1 and "start-team shake12 FAILED" in r.stderr, r.stderr
        print("unhealthy: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def start_team_writes_switches():
    src = open(os.path.join(ROOT, "tools", "start-team.sh")).read()
    block = src.split('> "$rundir/switches.env"', 1)[0].rsplit("printf '%s\\n'", 1)[1]
    for key in sc.KEYS:
        assert f'"{key}=' in block, key
    print("start-team switches.env: ok")


if __name__ == "__main__":
    switches()
    refusals()
    dry_run()
    change()
    unhealthy()
    start_team_writes_switches()
