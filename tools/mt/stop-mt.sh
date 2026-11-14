#!/usr/bin/env bash
# (mt277, private) Stop a multi-team run (tools/mt/start-mt.sh): every team's supervisors, broker and helpers and the
# run's own, close the agents' panes, pause the world (imac2), save it (game.server_save RUN on the iMac, and /server-save), gzip the journals.
#   tools/mt/stop-mt.sh RUN_ID
# The teams' folders are in the launch tree start-mt.sh wrote in runs/RUN/op/launch-tree.
# Env: POG_STOP_WORLD=1 also stops the mt server (tools/mt/imac_mt.sh stop: /quit saves over its saves/mt.zip, which
# a later shift starts from).
cd "$(dirname "$0")/../.."
run=${1:?usage: stop-mt.sh RUN_ID} world=imac2 op=runs/$1/op
[ -d "$op" ] || { echo "no multi-team run runs/$run (no op/)" >&2; exit 1; }
# Prevent a launcher still waiting for native prompts from creating helpers after
# teardown has already read helpers.pid. Verify its command before touching a PID.
python3 - "$op" "$run" <<'PY'
import json,os,shlex,signal,subprocess,sys
from pathlib import Path
try:
    pid=int(json.loads((Path(sys.argv[1])/'launch-process.json').read_text())['pid'])
    cmd=shlex.split(subprocess.check_output(['ps','-o','command=','-p',str(pid)],text=True))
    script=str((Path.cwd()/'tools/mt/start-mt.sh').resolve())
    i=cmd.index(script)
    if cmd[i+1]!=sys.argv[2]:raise ValueError('different run')
    if os.getpgid(pid)==pid:os.killpg(pid,signal.SIGTERM)
    else:os.kill(pid,signal.SIGTERM)
except (OSError,ValueError,KeyError,IndexError,subprocess.CalledProcessError):pass
PY
# Public output stops first, while feeds still exist. Its persisted ownership is
# used even if this shell no longer has POG_MT_PUBLIC=1. A live OBS broadcast must
# be stopped by the operator before teardown can blank its program scene.
if [ -f "$op/public-stream.json" ]; then
  python3 tools/mt/public_stream.py stop "$run" || exit $?
fi
if [ -f "$op/full-run.json" ]; then
  python3 tools/mt/full_run.py shutdown "$run" --execute || exit $?
fi
tree=$(cat "$op/launch-tree" 2>/dev/null || pwd)
rundir=$tree/runs/$run
if [ -f "$op/full-run.json" ]; then
  python3 tools/mt/stop_helpers.py "$run" --execute || exit $?
else
  for f in "$rundir"/*/supervisors.pid "$rundir"/*/helpers.pid "$rundir"/*/broker.pid "$op/helpers.pid"; do
    [ -f "$f" ] && while read -r pid; do pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null || true; done < "$f"
  done
fi
python3 tools/pog.py --world "$world" pause || true
saved=1
python3 tools/pog.py --world "$world" rcon "/silent-command game.server_save('$run')" >/dev/null 2>&1 || saved=0
python3 tools/pog.py --world "$world" save >/dev/null 2>&1 || true
if [ -f "$op/autosave-copy.json" ]; then
  python3 tools/mt/autosave.py once "$run" >"$op/autosave-final.json" 2>"$op/autosave-final.err" || true
fi
rm -rf "$rundir"/*/.keys
# The agents' panes (as tools/shift-change.sh closes a shift's); a process left after that (mt-smoke1: a Grok shell's
# fh call, its parent gone) is listed by PID for the operator, not killed here.
if [ -f "$op/panes.txt" ]; then
  while read -r t name pane kind; do
    [ -n "$pane" ] || continue
    herdr pane close "$pane" >/dev/null 2>&1 && echo "closed pane $pane ($t/$name)" || echo "pane $pane ($t/$name): already gone"
  done < "$op/panes.txt"
  sleep 2
  left=$(pgrep -f "$rundir/" | tr '\n' ' ')
  [ -z "$left" ] || echo "still running with $rundir in their command line (PIDs): $left" >&2
fi
# Wait until native clients have closed before compressing their journals. A
# final failed socket call can otherwise recreate journal.jsonl after gzip.
python3 - "$rundir" <<'PY'
import glob, gzip, os, shutil, sys
for j in glob.glob(f"{sys.argv[1]}/*/*/journal.jsonl"):
    with open(j, "rb") as src, gzip.open(j + ".gz", "ab") as g: shutil.copyfileobj(src, g)
    os.remove(j)
PY
python3 tools/mt/imac_cam.py stop || true   # the camera client (start-mt.sh, POG_MT_CAM)
if [ "${POG_STOP_WORLD:-0}" = 1 ]; then tools/mt/imac_mt.sh stop || true; fi
[ $saved = 1 ] && echo "stopped $run; world $world saved as $run (and /server-save)" || { echo "stopped $run; world $world NOT saved as $run" >&2; exit 3; }
