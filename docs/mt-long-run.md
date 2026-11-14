# Persistent 2.1 runs (private)

World lifetime and agent-shift lifetime are separate. Only the isolated 2.1.24
server is supported. Hold the operator server claim before mutation; never use
these tools against world n. Archive volume must be mounted.

## Saves

The existing control.lua tick handler reads operator-armed storage.pog_autosave.
Every 54,000 game ticks it calls game.server_save with RUN-auto-01 through 12,
rotating in place. The first save is one game second after arming. Clock, slots
and sequence survive save/load and runtime deployment; runtime faults do not
skip this clock. Paused time does not advance it. No new require is introduced.
This uses the pinned 2.1.24 server API:
https://lua-api.factorio.com/2.1.24/classes/LuaGameScript.html#server_save

With the normal 2.1 environment exported:

    agent-python tools/mt/autosave.py arm RUN
    agent-python tools/mt/autosave.py watch RUN

The host copies changed slots to /Volumes/POG Media/pog-runs/team-runs/RUN/saves.
It checks remote size/mtime around the transfer, compares SHA-256 at both ends,
checks ZIP CRC, atomically commits the archive and records proof in index.json.
Only after that does it prune to the last 12 copies plus the first verified copy
of each game hour. --keep N changes the recent-copy count. The hour uses the save
request tick (the engine serializes at the end of that tick), not wall time.
A rollback retains its later archive alongside earlier branches. Never use a
remote rotating slot as the only backup. A failed copier alerts and retries;
its receipt is not proof of a later unobserved engine write.

## Restore

1. Stop this run's watchdog and agents; keep the run's server claim. Preserve a
   final safety save and archive it before deliberately rolling back.
2. Pick an exact filename in the archive index. Verify locally:

       agent-python tools/mt/autosave.py verify RUN --file FILENAME.zip

3. Stop only imac2 with the pinned tools/mt/imac_mt.sh stop. Start its copy using
   tools/mt/imac_mt.sh start '/Volumes/POG Media/pog-runs/team-runs/RUN/saves/FILENAME.zip'.
   The input archive is immutable; the launcher copies it to the server's mt.zip.
4. Read game.tick, storage.pog_autosave and own-force profiles/production after
   load, verify the selected save, then restart agents from their private notes
   with POG_RESUME. Notes may describe work after the restored tick: explicitly
   tell each affected team to reconcile its own current status before acting.
   Do not re-run fresh setup or reset identities/inventories. Restore is a
   deliberate world outage, separate from an ordinary shift change.

The source archive, actual loaded tick, identities, and post-restore health must
be recorded in the run's operator receipt. Never claim a hash alone proves the
engine loaded or that the agent resumed.
