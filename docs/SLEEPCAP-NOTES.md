# Wait cap for the agents' shells (eng/sleepcap)

The shake11 study (docs/studies/shake11.md, P1 item 3) found waits the harness cannot see or wake: Muse's shell
`sleep 280` (89% of shake11 so far, 2% in the journal) and Sonnet's `python3 -c "import time;time.sleep(1200)"`
(218 of shake10's 240 minutes). Now one such wait longer than 60 s waits 60 s and prints one line on stderr:

    ./fh sleep N waits longer and wakes on tells, mentions and attacks

## How

`tools/sleepcap/run CMD...` starts each harness (tools/launch-agent.sh):

| Piece | Covers |
| --- | --- |
| `bin/sleep` first on PATH | `sleep N` in `bash -c`, `zsh -c`, `sh -c` |
| exported bash function `sleep` (`BASH_FUNC_sleep%%`) | every bash, login or not (`bash -lc`): `/etc/profile`'s `path_helper` puts `/bin` first, but a function comes before PATH |
| `py/sitecustomize.py` on PYTHONPATH | `time.sleep` in any Python; then runs the interpreter's own sitecustomize (Homebrew's adds its site-packages) |

Per harness:

| Harness | How the cap reaches its commands | Offline test |
| --- | --- | --- |
| Claude Code | pane command under `run`; a SessionStart hook writes `export PATH=<shim>:$PATH` to `CLAUDE_ENV_FILE`, which Claude Code sources before every Bash command, after its shell snapshot | hook, env file, `zsh -lc` after sourcing it: capped |
| Codex | `ai-session` passes no environment: `[shell_environment_policy] set = {...}` in the workspace's `.codex/config.toml` (PATH is the launch's PATH with the shim first) | config written once; `bash -lc`, `bash -c`, `python3` with those variables: capped |
| Grok Build | `.grok-run.sh` runs grok under `run`; its allowlist has no bare shell command, so the Python cap is the one that matters | the launch's own script with a stand-in grok: capped |
| Muse | `.muse-run.sh` runs muse under `run` | (same wrapper) |
| agy | the loop runs `agy` under `run`; the loop's own sleep until a quota reset is a plain sleep | loop script checked |

Untouched: `./fh` and `./shot` (they set `POG_SLEEP_CAP=0` for everything they run), scripts under our `tools/`,
`bin/` and `vendor/` (`POG_SLEEP_CAP_EXEMPT`: the calling script's path, else the parent's command line), waits of
60 s or less, arguments `sleep` cannot read, supervisors and the other helpers (started outside the agents'
environment), Claude's allowlist and `tools/permit.py`.

Not covered: a zsh login shell (`zsh -lc`): `/etc/zprofile`'s `path_helper` puts `/bin` first and zsh imports no
functions from the environment; covering it would take a ZDOTDIR whose startup files source the owner's and then
put the shim first (writing those files was refused in the engineer sandbox; not done). Also `/bin/sleep N` by
path, `timeout`, `perl`/`node` sleeps, and `python3 -I` or `-E` (no PYTHONPATH).

## Checks

- Offline: `python3 tools/test_sleepcap.py` (1 s cap).
- Live, per harness, outside the sandbox (one short turn each, cap at 3 s, 8 s waits):
  `tools/sleepcap/probe.sh claude sonnet`, `tools/sleepcap/probe.sh codex gpt-6-astra codex-b`,
  `tools/sleepcap/probe.sh grok grok-4.7`, `tools/sleepcap/probe.sh muse muse-spark-1.3`,
  `tools/sleepcap/probe.sh agy gemini-3.8-flash-high`. "capped" with "slept 3 s" lines and the cap's line means it
  works; "NOT capped" with `command -v sleep` showing `/bin/sleep` means that harness runs a zsh login shell.
- In a shift: the cap's line in the transcripts after a long shell or Python sleep; the study's shell-sleep minutes
  should drop to at most one minute per call.
