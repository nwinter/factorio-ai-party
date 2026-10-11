#!/usr/bin/env bash
# Stop a team run's helpers and save the world: tools/stop-team.sh RUN_ID [WORLD]
# Env: POG_STOP_WORLD=1 also stops the world's server and clients after the save (shifts).
cd "$(dirname "$0")/.."
run=$1 world=${2:-n} rundir="runs/$1"
tools/.venv/bin/python tools/obs.py stream-stop 2>/dev/null || true
tools/.venv/bin/python tools/obs.py stop 2>/dev/null || true
tools/.venv/bin/python tools/obs.py replay-stop 2>/dev/null || true
for f in stream-service.pid overlay-tunnel.pid supervisors.pid score-loop.pid; do
  [ -f "$rundir/$f" ] && while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$rundir/$f"
done
# Pause first: directors keep the world running, and shake6 ran 5 unplayed game minutes past its deadline
# (docs/studies/shake6.md, P1 item 1). A resumed shift unpauses it (tools/start-team.sh, POG_RESUME).
python3 tools/pog.py --world "$world" pause || true
# Console commands that were not harness requests (the mod's console log): operator tools are labelled, anything
# else is listed as UNKNOWN to read by hand. Saved in the run for the study.
python3 tools/console_audit.py --world "$world" --out "$rundir/console-audit.json" || true
# POG_BROKER=1 runs: what the RCON broker forwarded and refused (it stopped with the helpers above).
[ -f "$rundir/broker.log" ] && { sleep 1; python3 tools/fh_broker.py summary "$rundir/broker.log" || true; }
python3 tools/pog.py --world "$world" save
# The run's copy of the world password is only for its agents' fh: gone with the shift, so later agents cannot read
# it (docs/LAUNCH-NOTES.md). A resumed shift copies it again (tools/new-run.sh).
rm -rf "$rundir/.keys"
# Between shifts (POG_STOP_WORLD=1) the server and its directors stop too, so game time moves only while agents
# play; the next shift resumes from this save (tools/start-team.sh, POG_RESUME).
if [ "${POG_STOP_WORLD:-0}" = 1 ]; then
  sleep 5   # /server-save returns before the file is written
  tools/winps.sh tools/win/stop-world.ps1 -Name "$world" || true
fi
# Journals are mostly wait-poll status traffic: drop it and gzip the rest.
python3 - "$rundir" <<'PY'
import glob, gzip, json, os, sys
for j in glob.glob(f"{sys.argv[1]}/*/journal.jsonl"):
    kept, pending = [], None
    for line in open(j):
        try: e = json.loads(line)
        except Exception: continue
        if e.get("event") == "request":
            pending = e["request"].get("action")
            if pending in ("status", "queue_status"): continue
        elif e.get("event") == "response" and pending in ("status", "queue_status"): continue
        kept.append(line)
    with gzip.open(j + ".gz", "wt") as g: g.writelines(kept)
    os.remove(j)
PY
echo "stopped helpers for $run; world $world saved"
