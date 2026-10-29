#!/usr/bin/env python3
"""A slow shell must not stop a shift start (d29 batch331 LS: shift96's and shift97's starts failed when ai-session gave
a new pane's shell 20 s and start-team ended on the first failed launch): python3 tools/test_launch_resilience.py

With a stub ai-session and a stub herdr on PATH (no Herdr, no world, no clock beyond a few seconds):
- tools/ai-session-spawn.sh: a normal spawn prints its pane; ai-session's "did not finish shell startup" is carried on:
  the pane is sent a marker its shell must compute (the typed text alone never matches), the manifest named in the
  message is run there once the shell answers, and the pane is printed; a shell that never answers within
  POG_SHELL_WAIT_S exits 1 with no manifest run and the pane left; any other ai-session failure exits 1 at once;
- tools/launch-agent.sh's codex case goes through it;
- tools/start-team.sh's agent loop (run on its own from the script's text) with a stub launch failing for one agent:
  the others still start, three to a tab as before, panes.txt leaves the failed one out, not-started.txt names it, the
  log says why and "started: 2/3 agents (not started: sol; ...)".
"""
import os, re, stat, subprocess, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
import testsafe  # noqa: E402  (POG_TEST=1 and no live credentials in the scripts' environment)

SPAWN = REPO / "tools" / "ai-session-spawn.sh"

HERDR = r'''#!/usr/bin/env bash
# stub herdr: pane run types the text on a screen file (as a terminal echoes it) and, once the shell is "ready" (the
# READY_AFTER-th run on), runs it and adds its output; wait-output greps the screen
log="$STUB_DIR/herdr.log"; screen="$STUB_DIR/screen.txt"; n_file="$STUB_DIR/runs"
echo "$*" >> "$log"
case "$1 $2" in
  "pane run")
    n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 )); echo $n > "$n_file"
    printf '%s\n' "$4" >> "$screen"
    if [ "$n" -ge "${READY_AFTER:-1}" ] && [ "${NEVER_READY:-0}" != 1 ]; then bash -c "$4" >> "$screen" 2>&1 || true; fi ;;
  "pane wait-output")
    pat=""; t=1000
    shift 2; pane=$1; shift
    while [ $# -gt 0 ]; do case $1 in --match) pat=$2; shift 2 ;; --timeout) t=$2; shift 2 ;; *) shift ;; esac; done
    end=$(( $(date +%s) + (t + 999) / 1000 ))
    while [ "$(date +%s)" -lt "$end" ]; do grep -qF -- "$pat" "$screen" 2>/dev/null && exit 0; sleep 0.1; done
    exit 1 ;;
esac
exit 0
'''

AI = r'''#!/usr/bin/env bash
# stub ai-session: STUB_MODE ok | slow | other
echo "$*" >> "$STUB_DIR/ai.log"
case "${STUB_MODE:-ok}" in
  ok) echo "Submitted codex in Herdr pane w9:p7."; exit 0 ;;
  slow) echo "ai-session: Herdr pane w9:p8 did not finish shell startup; kept it for inspection. After fixing startup, run $STUB_DIR/ai-session run 0123abcd there." >&2; exit 1 ;;
  other) echo "ai-session: Prompt file does not exist: /nope" >&2; exit 1 ;;
esac
'''


def write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def spawn(d, mode, **env):
    for f in ("herdr.log", "screen.txt", "runs", "ai.log"):
        (d / f).unlink(missing_ok=True)
    e = testsafe.env(PATH=f"{d}:{os.environ['PATH']}", STUB_DIR=str(d), STUB_MODE=mode, POG_AI_SESSION=str(d / "ai-session"),
                     POG_SHELL_WAIT_S="6", POG_SHELL_RETRY_S="1", **env)
    r = subprocess.run([str(SPAWN), "--route", "codex-b", "-C", "/tmp/x", "--start"], capture_output=True, text=True, env=e, timeout=30)
    log = (d / "herdr.log").read_text() if (d / "herdr.log").exists() else ""
    return r, log


def spawn_checks(d):
    write_exec(d / "herdr", HERDR)
    write_exec(d / "ai-session", AI)
    # a normal spawn: its pane, ai-session called once with the arguments, no herdr calls
    r, log = spawn(d, "ok")
    assert r.returncode == 0 and r.stdout.strip() == "w9:p7", (r.stdout, r.stderr)
    assert (d / "ai.log").read_text().strip() == "spawn --route codex-b -C /tmp/x --start" and log == "", log
    # slow shell, ready from the 3rd marker on: the manifest runs there, once, after the marker answered
    r, log = spawn(d, "slow", READY_AFTER="3")
    assert r.returncode == 0 and r.stdout.strip() == "w9:p8", (r.stdout, r.stderr)
    runs = [x for x in log.splitlines() if x.startswith("pane run ")]
    markers = [x for x in runs if "pog-ready-" in x]
    assert len(markers) >= 3 and all(re.search(r"echo pog-ready-\$\(\(\d+ \+ 1\)\)$", x) for x in markers), runs
    n = int(re.search(r"\$\(\((\d+) \+ 1\)\)", markers[0]).group(1))
    waits = [x for x in log.splitlines() if x.startswith("pane wait-output ")]
    assert waits and all(f"--match pog-ready-{n + 1}" in x for x in waits), waits
    assert runs[-1] == f"pane run w9:p8 {d}/ai-session run 0123abcd", runs[-1]
    assert sum("run 0123abcd" in x for x in runs) == 1, runs
    assert "ran manifest 0123abcd there" in r.stderr, r.stderr
    # the typed text alone (echoed, never run) does not count as ready: never ready ends in exit 1, nothing run
    r, log = spawn(d, "slow", NEVER_READY="1")
    assert r.returncode == 1 and r.stdout == "", (r.stdout, r.stderr)
    assert "0123abcd" not in "".join(x for x in log.splitlines() if x.startswith("pane run ")), log
    assert "still not ready after 6 s; left for inspection" in r.stderr and "did not finish shell startup" in r.stderr, r.stderr
    # any other failure: exit 1 at once with ai-session's words, no herdr call
    r, log = spawn(d, "other")
    assert r.returncode == 1 and "Prompt file does not exist" in r.stderr and log == "", (r.stderr, log)


def launch_agent_uses_it():
    text = (REPO / "tools" / "launch-agent.sh").read_text()
    codex = text[text.index("  codex)"):text.index("  grok)")]
    assert '"$root/tools/ai-session-spawn.sh" "${args[@]}" -C "$dir" --name "$name" --herdr tab --prompt-file "$prompt" --start' in codex, codex
    assert "ai-session spawn" not in codex.replace("tools/ai-session-spawn.sh", ""), "no direct spawn left"


LAUNCH = r'''#!/usr/bin/env bash
# stub launch-agent.sh: RUN WORLD NAME MINUTES KIND MODEL EFFORT; fails for FAIL_NAME
echo "$3 tab=${POG_TAB:-new}" >> "$STUB_DIR/launches"
if [ "$3" = "${FAIL_NAME:-}" ]; then echo "ai-session: pane w1:p2 shell still not ready after 90 s; left for inspection" >&2; exit 1; fi
n=$(wc -l < "$STUB_DIR/launches" | tr -d ' ')
echo "w1:p$n ${POG_TAB:-w1:t$n} $STUB_DIR/$3"
'''


def start_team_loop(d):
    """start-team.sh's agent loop and its started line, run on their own with a stub launch failing for sol."""
    text = (REPO / "tools" / "start-team.sh").read_text()
    loop = text[text.index('POG_TEAM="$rundir/team.txt"'):text.index('done < "$team"') + len('done < "$team"')]
    started = next(x for x in text.splitlines() if x.startswith('log "started: '))
    write_exec(d / "launch", LAUNCH)
    (d / "team.tsv").write_text("# name kind route model effort label harness\n"
                                "astra\tcodex\tcodex-b\tm\tlow\tAstra\tCodex\n"
                                "sol\tcodex\tcodex-b\tm\tlow\tSol\tCodex\n"
                                "opus\tclaude\tclaude-b\topus\tlow\tOpus\tClaude Code\n"
                                "luna\tcodex\tcodex-b\tm\tlow\tLuna\tCodex\n")
    rundir = d / "run"
    rundir.mkdir()
    script = (f"set -euo pipefail\nrundir={rundir}\nrun=shift99\nworld=n\nminutes=240\nteam={d}/team.tsv\nenemies=on\nseed=1\n"
              "log() { echo \"LOG $*\"; }\n" + loop + "\n" + started + "\necho END\n")
    e = testsafe.env(STUB_DIR=str(d), FAIL_NAME="sol", POG_LAUNCH_AGENT=str(d / "launch"))
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=e, timeout=30)
    assert r.returncode == 0 and "END" in r.stdout, (r.stdout, r.stderr)
    assert (d / "launches").read_text().split("\n")[:4] == ["astra tab=new", "sol tab=w1:t1", "opus tab=w1:t1", "luna tab=w1:t1"], (d / "launches").read_text()
    panes = (rundir / "panes.txt").read_text().splitlines()
    assert [p.split()[0] for p in panes] == ["astra", "opus", "luna"], panes
    ns = (rundir / "not-started.txt").read_text().splitlines()
    assert len(ns) == 1 and ns[0].startswith("sol\tcodex\t"), ns
    assert "LOG agent sol (Sol, codex) NOT STARTED: launch failed: ai-session: pane w1:p2 shell still not ready after 90 s" in r.stdout, r.stdout
    assert "LOG started: 3/4 agents (not started: sol; runs/shift99/not-started.txt); deadline" in r.stdout, r.stdout
    assert "still not ready" in r.stderr, "launch errors still reach the start's own stderr"
    assert (rundir / "launch-sol.err").read_text().strip().endswith("left for inspection")
    # three to a tab counts started agents: astra, opus, luna share the first tab
    # every one failing: the loop ends with an empty panes.txt and "started: 0/4"
    for f in ("launches",):
        (d / f).unlink()
    for f in ("panes.txt", "not-started.txt"):
        (rundir / f).unlink()
    e["FAIL_NAME"] = "nobody"
    e2 = dict(e)
    write_exec(d / "launch", LAUNCH.replace('if [ "$3" = "${FAIL_NAME:-}" ]', 'if true'))
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=e2, timeout=30)
    assert r.returncode == 0 and "LOG started: 0/4 agents (not started: astra sol opus luna;" in r.stdout, (r.stdout, r.stderr)
    assert (rundir / "panes.txt").read_text() == ""


def main():
    with tempfile.TemporaryDirectory() as d:
        spawn_checks(Path(d))
    launch_agent_uses_it()
    with tempfile.TemporaryDirectory() as d:
        start_team_loop(Path(d))
    print("launch resilience: ok (slow shell waited for and the manifest run; never ready and other failures exit 1; "
          "a failed launch leaves the others starting, panes.txt without it, not-started.txt and the N/M line)")


if __name__ == "__main__":
    main()
