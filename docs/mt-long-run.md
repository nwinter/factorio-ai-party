# Persistent 2.1 runs (private)

World lifetime and agent-shift lifetime are separate. Only the isolated 2.1.24
server is supported. Hold the operator server claim before mutation; never use
these tools against world n. Archive volume must be mounted.
Use `set -e` for operator shell sequences and export POG_CLAIM_OWNER. Server/map
mutators refuse a mismatched claim. For ad-hoc Lua use run_state.rcon, which checks
the claim and 2.1 pins before every command; do not bypass it with raw tools/pog.py.

A fresh map must complete mt_map.py's one-time `join`/`mt_assign` for each selected
force before saving its baseline. Factorio does not chart bot surroundings for a
force with no LuaPlayers, so such a map refuses mining/building even underfoot.
Full launch checks this before starting agents. Keep setup players as spectators,
disconnect their clients, and remove stray player-force bodies before baseline QA.

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

The host copies changed slots to ~/pog-media/pog-runs/team-runs/RUN/saves (POG_MEDIA names another media folder).
Remote hashing/stat use IMAC_PYTHON (default /usr/local/bin/python3, the installed
iMac interpreter); bare python3 there resolves to the unusable Xcode stub.
It checks remote size/mtime around the transfer, compares SHA-256 at both ends,
checks ZIP CRC, atomically commits the archive and records proof in index.json.
Only after that does it prune to the last 12 copies plus the first verified copy
of each game hour. --keep N changes the recent-copy count. The hour uses the save
request tick (the engine serializes at the end of that tick), not wall time.
A rollback retains its later archive alongside earlier branches. Never use a
remote rotating slot as the only backup. A failed copier alerts and retries;
an already-held copy lock skips the periodic pass quietly, since a restore
checkpoint or explicit copy owns that work.
A copy receipt is not proof of a later unobserved engine write.

## Restore

1. Stop this run's watchdog and agents; keep the run's server claim. Preserve a
   final safety save and archive it before deliberately rolling back.
2. Pick an exact filename in the archive index. Verify locally:

       agent-python tools/mt/autosave.py verify RUN --file FILENAME.zip

3. Stop only imac2 with the pinned tools/mt/imac_mt.sh stop. Start its copy using
   tools/mt/imac_mt.sh start ~/pog-media/pog-runs/team-runs/RUN/saves/FILENAME.zip.
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
and clients held. A recorded mismatch requires operator inspection. When the
screenshot camera was connected, the drill relaunches it after the exact-state
comparison (briefly advancing the world for its join), records that later tick,
and pauses again. An ordinary agent handoff never touches the camera.
The operator team view opens a fresh RCON connection on each poll, so partial
read errors during a restore cannot strand its later snapshots on a dead socket.

The closed rehearsal controller is `agent-python tools/mt/rehearse.py RUN --execute`.
Launch with POG_FULL_SHIFTS=1, POG_MT_PAUSED_START=1 and POG_MT_PUBLIC=0 first.
The controller defaults to two 180-minute shifts (`--shift-minutes` changes both),
with an exact-save restore between them. Launch with the same shift length. Its
engineering quota guard defaults to `--quota-profile codex-b --quota-stop 70`;
stale or unavailable engineering telemetry stops the drill too. Agent quota
holds remain the native watchdog's responsibility. Receipts are
op/rehearsal.json and op/restore-drill.json. It stops the run but retains the
claim on both success and failure. `--measure` starts the minute metrics helper
and a separate `load_bench.py` invocation per shift, archiving each native server
profile log before restore/teardown. Restore the prior owner's saves, mods and
configuration, verify the saved hashes and stopped processes, then release.

When unlisted streaming is authorized, use the application Python
(`/opt/homebrew/bin/python3`) and add `--unlisted`. Start and inspect the normal
stream staging/publication after the controller resumes the world. Before the
restore, this option requires an owned full-mode unlisted session, live YouTube
privacy verification, and healthy recording, camera, site and output. The stream
supervisors stay running while the server reloads; exact paused-state comparison
still precedes any camera join ticks. After resuming the second shift, the
controller requires sixty continuous healthy seconds with increasing ticks and
stream bytes. Evidence is op/restore-stream.json. Final teardown completes the
unlisted publication with --keep-world before stopping staging and the game.
Without this option, restore still refuses a publication receipt.

`rehearsal_metrics.py RUN --execute` writes private minute samples directly to
~/pog-media. They include milestones, contacts, market records, moving shipment
positions, account quota observations, UPS and the harness heap. Gaps and restore
outages stay explicit. Use `load_bench.py --window 60 --every 10` separately for
performance, with default GC settings. Stop its collector before restore and
start a new invocation afterward: its persistent RCON sockets do not reconnect.
Preserve the server profile log before restoring. Register helper PIDs in
op/helpers.pid for owned-process cleanup. Quota readings are account-wide and
must be separated at resets; divide observed deltas by the route's measured
agent-hours and report any concurrent usage or stale readings.
The dashboard refreshes every300s and writes ~/.cache/ai-usage/agent-brief.json.
Read this file for routine checks; generated_at or a profile observation older
than15 minutes is unavailable, even when its saved availability flag says true.
The independent helper attempts a fallback only after two missed dashboard
refreshes (10 minutes), at most once per30 minutes; attempts are persisted in
op/quota-fallback.json. It never runs ai-usage on each sample. A bounded provider
adapter can be selected with `quota_refresh.py RUN --reader COMMAND ARG...` if
the installed ai-usage command stalls on transcript-history scans. It must emit
the normal brief JSON and preserve saved observation ages and unknown values.
Record the selected reader and deployment; never fabricate zero usage when a
reset response omits the percentage. Agent quota-hold policy stays separate.
During a diagnosed dashboard outage, `--fallback-every 600 --reader-timeout 300`
allows a bounded live adapter to wait for the dashboard's existing quota lock.
This still reads the cache each minute and only refreshes after two missed
dashboard updates. Record this override as an outage workaround; do not remove
the shared lock or mistake it for a repair of the dashboard's refresh.

`mt_map.py create --teams 3 --team-names green yellow blue ...` aligns forces
with the six-agent roster. A failed setup join now returns failure. Native
`map_probe.py --dir EVIDENCE --execute` is destructive acceptance on a disposable
copy only: it adds stand-in bots, research, contacts and stock, obtains native
shipment-prototype paths and proves three physical market deliveries. Reject
timer fallback or loss. Reload the untouched, hash-verified baseline afterward;
the path probe is not real-agent play and its synthetic contacts never enter the
rehearsal.

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

    /opt/homebrew/bin/python3 tools/mt/public_session.py start RUN --run-mode full --execute

Use the verified application Python with Pillow for both stream supervisors and
team feeds: feed recovery inherits the publication supervisor's interpreter.
The stdlib-only agent-python runtime remains suitable for the shift/watch tools.
Streaming recovery and staffed pogwin maintenance are documented in
`docs/mt-stream-recovery.md`.

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
The quota helper reads the dashboard cache each minute and alerts on missing or
stale playing routes. It uses the rare fallback described above if dashboard
refreshes stop; failures retain the last known observation and its actual age.

POG_IDLE_NUDGE defaults to 1 in full mode. Scoped idle_report and scoped tells
use only that pair; running queue lanes and quota rests suppress reminders. The
message asks for own status/notes and productive teammate work without rival
hints. Interactive idle prompts are nudged only after local requests go quiet.
Grok can finish normally while Herdr reports `unknown`. In that case, the watch
requires a successful `end_turn` receipt from the current native session and an
empty prompt, with no busy or purchase indicator, before using the same quiet
intervals and continuation message. An old receipt or silence alone is not
enough. Accepted and failed prompt attempts are recorded in shifts.jsonl.
The existing unscoped single-team idle helper is not used by full mode.

Live shift announcements use the existing /v1/announce path as Operator and
contain only counts and lifecycle facts. Closed runs log the same lines with
sent:false, making no site mutation. Alerts append to op/alerts.jsonl and
POG_OPERATOR_WAKE (default /Users/owner/code/pog-operator/mt300-wake.jsonl).
The operator must point that setting at its watched wake file. Receipts and
shifts.jsonl stay private. One process lock prevents duplicate watchdogs and
one mutation lock serializes watchdog recovery against manual shift commands.
Bounded completion releases the watchdog lock immediately. Final helper cleanup
checks each PID's current script and run/path binding, so a recycled PID belonging
to another run is left alone.

Final stop, with the same 2.1 pins and claim:

    POG_STOP_WORLD=1 tools/mt/stop-mt.sh RUN

Check stopped clients, server status, external save receipts and any broadcast
receipt before releasing server-claim.txt. Disk growth in native histories and
journals still requires archiving after closure; only save archives are pruned
by the automated retention policy. Continuous multi-day streaming recovery is
owned by separate work, beyond the agent-shift contract here.

## Web searches (mt302)

Nick (d44) kept Grok's web search on for the full run and asked the operator to
watch whether agents search for the project. The watchdog runs
`tools/mt/search_watch.py` once a minute and once more when the shifts complete,
outside the mutation lock; `POG_SEARCH_WATCH=0` turns it off. It reads each
playing agent's own session logs, read only, from where the last pass stopped:

- Grok: `.grok-home/sessions/<quoted workspace>/*/updates.jsonl`, the completed
  `Web search` calls (`rawOutput.action`: search with its query and result
  sources, open_page, find_in_page) and shell commands.
- Muse: `data/muse/sessions/...` under the workspace's `.native-root`,
  `web_search`, `web_fetch` and `bash` calls.
- agy: the run's `brain/*` transcripts, `search_web`, `read_url_content`,
  `browser_subagent` and `run_command` calls.

Shell commands count only for the http(s) URLs they name; localhost is ignored.
A query, URL or shell URL that matches `tools/mt/search-terms.json` is a hit:

- project, operator, site, repo, channel and "AI party" terms flag alone;
- Factorio plus an AI word plus a team, stream or competition word flags as
  `ai-factorio-run`;
- another team's color flags next to a team word ("blue team"), and another
  team's agent names (teams.tsv, the config's `extra_names`, or
  `op/search-names.txt` lines `team<TAB>name` for chosen display names) flag
  with a context word.

The agent's own team never flags for its own color or names. Grok's result
sources are checked against the strong terms only (kind `result`).

Each hit is written once:

- to `/Users/owner/code/pog-operator/search-wake.jsonl` (`{"t","from","text"}`,
  for the operator's watcher);
- to `op/alerts.jsonl` (event `search-hit`);
- to `op/search-hits.jsonl` (the whole record).

Every web call is counted per agent per local hour in `op/search-watch.json`,
along with the read offsets and the counted call ids, so a restarted watchdog
neither repeats a hit nor counts a call twice. The hours table:

    python3 tools/mt/search_watch.py hours RUN

To read past team folders without writing anything:

    python3 tools/mt/search_watch.py report ../play-*/runs/RUN

`tools/mt/start-mt.sh` sets POG_WEB_BLOCK for every team run: Grok's search
excludes factorio.nickwinter.net, YouTube and GitHub hosts, and agy and Muse run
with their web tools off (each workspace's `.web-state` says so). A query is
still the agent's own and still reaches the provider, so the watcher reads all
three kinds.
