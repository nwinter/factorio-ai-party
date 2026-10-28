# Tests and the live stream

The gate (the operator's gate.sh) runs `npm test` and every `tools/test_*.py`, `tools/stream/test_*.py` and
`site/test_*.py` in the live checkout, `/Users/owner/code/player-of-games`, after `git merge --no-commit`. In a test
there, `ROOT` is the live checkout and `ROOT/runs` the live runs. A test must reach nothing outside its temp folder:
no live process, OBS, RCON world, box, site worker or run folder.

On d24 between 18:03 and 18:32, tools/test_shift_recovery.py ran a copy of stop-team.sh for a run named shift71. Its
push_live match also caught the live pusher's log, so every full test run stopped the live site pusher (batch185).

## The guard: POG_TEST=1 (d24 batch186)

`tools/testsafe.py` `env(**over)` is what a test runs a repo script with. It takes `os.environ` without `POG_*`, `FH_*`
and `FACTORIO_RCON_*`, sets `POG_TEST=1`, then applies `over`. Under `POG_TEST=1` these tools refuse their live
defaults:

| Tool | Refuses | Instead |
|---|---|---|
| tools/pog.py `Rcon` | a world's port (`PORTS`) | a test's own server on another port |
| tools/obs.py `client()` | OBS (obs.pw, 4455) | a fake client |
| tools/winps.sh | ssh and scp to the box | (exit 3) |
| tools/shot-sync.sh | host `pogwin` | `POG_WIN_HOST` |
| tools/stop-team.sh | its OBS calls without `POG_STOP_OBS` | `POG_STOP_OBS` (a stub) |
| tools/new-run.sh | copying `~/.config/pog/rcon-WORLD.pw` | no key in the run |
| tools/obs-recover.sh | the lock in `runs/` without `POG_REC_LOCK` | `POG_REC_LOCK` |
| site/build.py | the repo's `runs/` as `--runs-dir` | a temp runs folder |
| site/chart_deploy.py | its wrangler deploy without `POG_WRANGLER` (batch241) | `POG_WRANGLER` or a stub runner |
| tools/pane_resume.py `HerdrPanes` | herdr pane reads and typing | fake panes (tools/test_pane_resume.py, tools/test_pane_resume_stop.py) |
| tools/public-push.sh | the public repo, the main checkout, its clean copy and the state folder without `POG_PUBLIC_REMOTE`, `POG_PUBLIC_SOURCE`, `POG_PUBLIC_WORKTREE` and `POG_PUBLIC_DIR` (batch272, batch290; `--start-loop` too) | a local bare repo, a temp source, a temp worktree path and state folder |
| tools/site-refresh.sh | the clean copy of main (a worktree of the main checkout) without `POG_SITE_WORKTREE`: a test run builds in place (batch290) | a temp source repo and worktree path |

Two more changes keep a live tool from mistaking a test's process for the live run's:
- **start-team plans:** a plan-only start-team (`POG_DRY_RUN=1` or `POG_TEST=1`) leaves `$TMPDIR/pog-start-team-plan.PID`
  while it runs, and tools/shift-change.sh counts only start-teams without one. Before this, the gate's dry runs of
  start-team in the live checkout made a live shift change refuse with "another start-team is running".
- **The pusher check:** start-team counts only push_live processes whose working folder is its own checkout.

The guard sits in the tools, not in the gate, so a test is safe wherever it runs: in the gate, by an engineer, or
alone. It is an environment variable because every test reaches the tools through a subprocess or an import.
`tools/test_live_guard.py` checks the guards, with network and box calls stubbed so even a tool without its guard
touches nothing. It also scans the gate's tests: one that runs a repo shell script must use `testsafe.env()` or set
`POG_TEST=1`; the exceptions are listed there with why.

For the operator's gate.sh, `export POG_TEST=1` before the test steps would cover tests that call a tool directly.
That is a change to gate.sh, outside the repo.
