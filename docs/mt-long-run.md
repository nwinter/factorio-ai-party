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
Remote hashing/stat use IMAC_PYTHON (default /usr/local/bin/python3, the installed
iMac interpreter); bare python3 there resolves to the unusable Xcode stub.
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
4. Read game.tick, remote.call("agent_harness","autosave_status") and own-force profiles/production after
   load, verify the selected save, then restart agents from their private notes
   with POG_RESUME. Notes may describe work after the restored tick: explicitly
   tell each affected team to reconcile its own current status before acting.
   Do not re-run fresh setup or reset identities/inventories. Restore is a
   deliberate world outage, separate from an ordinary shift change.

The source archive, actual loaded tick, identities, and post-restore health must
be recorded in the run's operator receipt. Never claim a hash alone proves the
engine loaded or that the agent resumed.

For a closed run, `agent-python tools/mt/restore.py RUN --execute` holds clients,
pauses, requests and verifies an exact checkpoint, reloads that archive, and
compares tick, pause state, team research and profiles. It leaves the world paused
and clients held. A recorded mismatch requires operator inspection.

The closed rehearsal controller is `agent-python tools/mt/rehearse.py RUN --execute`.
Launch with POG_FULL_SHIFTS=1, POG_MT_PAUSED_START=1 and POG_MT_PUBLIC=0 first.
The controller gives the first shift 90 minutes after all clients launch, verifies
the restore, starts shift two for 90 minutes, then stops the run and releases its
server claim. Receipts are op/rehearsal.json and op/restore-drill.json.

## World and shift lifetime

    POG_MT_FRESH=1 POG_MT_PUBLIC=0 POG_FULL_TOOLS=1 \
      agent-python tools/mt/launch.py RUN 90 --run-mode full --execute

MINUTES is the agent shift length. Test mode remains the default and retains its
90-minute launch/publication bounds. Full mode starts a persistent supervisor:
it replaces agent conversations at shift boundaries without calling stop-mt,
restarting the server, pausing the game, touching OBS, or completing YouTube.
POG_FULL_SHIFTS=2 limits the rehearsal to two shifts; default 0 repeats until
explicitly stopped. After the limited shifts the world and save copier remain
running until the operator's explicit final stop.

Public staging is still separate. After reviewing the actual staged picture:

    agent-python tools/mt/public_session.py start RUN --run-mode full --execute

This defaults to an unlisted broadcast created by public_broadcast.py. Public
visibility requires both explicit creation with --privacy public and explicit
public_session --public. Full publication has no time deadline. A publication
failure alerts and retains the world; an explicit clean session stop performs
final run teardown. A shift command never calls the publication lifecycle.
Viewer inbox lifetime also follows full mode, always operator/display-only.

## Agent changes and supervision

    agent-python tools/mt/full_run.py shift RUN --select green --minutes 90 --execute
    agent-python tools/mt/full_run.py shift RUN --select all --minutes 90 --execute
    agent-python tools/mt/full_run.py hold RUN --select muse --execute
    agent-python tools/mt/full_run.py release RUN --select muse --minutes 90 --execute
    agent-python tools/mt/full_run.py status RUN

Without --execute, mutation commands print a plan. Selection accepts a team,
one stable routing ID, or all. The same anonymous pair tree, broker sockets,
provider proxy and native process scope remain. Selected agents stop before
notes/journals are snapshotted into their own pair's private handoff directory.
POG_RESUME and POG_RESUME_DIR feed the normal notes handover. Bot state and chosen
profiles stay in the world. Operator manifests and colored names are never added
to the playing-agent environment. No replacement provider is selected.

The native process wrapper writes its PID/exit receipt. The host watches every
pane, verifies process ownership, stops descendants as a process group, and
restarts dead clients with notes. Provider stops back off; four retries per
shift exhaust the automatic retry budget and alert. Login errors hold the agent.
Quota at-limit windows use the existing route/model selection and quota_rest.py
format/push. Rest is firm until the actual reset, survives shifts, and suppresses
nudges. A limit screen with unknown reset is held until fresh quota shows room
or an explicit release. Stale telemetry never invents a reset or available quota.
An independent quota helper checks each minute, refreshes ai-usage when its cache
is older than eight minutes, and alerts on missing/stale playing routes. It does
not depend on the desktop widget. Refresh failures retain the last known cache.

POG_IDLE_NUDGE defaults to 1 in full mode. Scoped idle_report and scoped tells
use only that pair; running queue lanes and quota rests suppress reminders. The
message asks for own status/notes and productive teammate work without rival
hints. Interactive idle prompts are nudged only after local requests go quiet.
The existing unscoped single-team idle helper is not used by full mode.

Live shift announcements use the existing /v1/announce path as Operator and
contain only counts and lifecycle facts. Closed runs log the same lines with
sent:false, making no site mutation. Alerts append to op/alerts.jsonl and
POG_OPERATOR_WAKE (default /Users/owner/code/pog-operator/mt300-wake.jsonl).
The operator must point that setting at its watched wake file. Receipts and
shifts.jsonl stay private. One process lock prevents duplicate watchdogs and
one mutation lock serializes watchdog recovery against manual shift commands.

Final stop, with the same 2.1 pins and claim:

    POG_STOP_WORLD=1 tools/mt/stop-mt.sh RUN

Check stopped clients, server status, external save receipts and any broadcast
receipt before releasing server-claim.txt. Disk growth in native histories and
journals still requires archiving after closure; only save archives are pruned
by the automated retention policy. Continuous multi-day streaming recovery is
owned by separate work, beyond the agent-shift contract here.
