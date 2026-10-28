#!/usr/bin/env bash
# (mt277, private) Stop a multi-team run (tools/mt/start-mt.sh): every team's supervisors, broker and helpers and the
# run's own, pause the world (imac2), save it (game.server_save RUN on the iMac, and /server-save), gzip the journals.
#   tools/mt/stop-mt.sh RUN_ID
# The teams' folders are in the launch tree start-mt.sh wrote in runs/RUN/op/launch-tree.
# Env: POG_STOP_WORLD=1 also stops the mt server (tools/mt/imac_mt.sh stop: /quit saves over its saves/mt.zip, which
# a later shift starts from).
cd "$(dirname "$0")/../.."
run=${1:?usage: stop-mt.sh RUN_ID} world=imac2 op=runs/$1/op
[ -d "$op" ] || { echo "no multi-team run runs/$run (no op/)" >&2; exit 1; }
tree=$(cat "$op/launch-tree" 2>/dev/null || pwd)
rundir=$tree/runs/$run
for f in "$rundir"/*/supervisors.pid "$rundir"/*/helpers.pid "$rundir"/*/broker.pid "$op/helpers.pid"; do
  [ -f "$f" ] && while read -r pid; do pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null || true; done < "$f"
done
python3 tools/pog.py --world "$world" pause || true
saved=1
python3 tools/pog.py --world "$world" rcon "/silent-command game.server_save('$run')" >/dev/null 2>&1 || saved=0
python3 tools/pog.py --world "$world" save >/dev/null 2>&1 || true
python3 - "$rundir" <<'PY'
import glob, gzip, os, shutil, sys
for j in glob.glob(f"{sys.argv[1]}/*/*/journal.jsonl"):
    with open(j, "rb") as src, gzip.open(j + ".gz", "wb") as g: shutil.copyfileobj(src, g)
    os.remove(j)
PY
rm -rf "$rundir"/*/.keys
if [ "${POG_STOP_WORLD:-0}" = 1 ]; then tools/mt/imac_mt.sh stop || true; fi
[ $saved = 1 ] && echo "stopped $run; world $world saved as $run (and /server-save)" || { echo "stopped $run; world $world NOT saved as $run" >&2; exit 3; }
