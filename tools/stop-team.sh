#!/usr/bin/env bash
# Stop a team run's helpers and save the world: tools/stop-team.sh RUN_ID [WORLD]
cd "$(dirname "$0")/.."
run=$1 world=${2:-n} rundir="runs/$1"
tools/.venv/bin/python tools/obs.py stream-stop 2>/dev/null || true
tools/.venv/bin/python tools/obs.py stop 2>/dev/null || true
for f in stream-service.pid overlay-tunnel.pid supervisors.pid; do
  [ -f "$rundir/$f" ] && while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$rundir/$f"
done
python3 tools/pog.py --world "$world" save
echo "stopped helpers for $run; world $world saved"
