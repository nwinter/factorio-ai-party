# Shake12, early look, and the night in numbers

Shake12 (02:58 to 06:58 on world n, from game minute 1,047) is the first shift whose agents have the playbook's
tools index (trains, logistics, circuits, modules, nuclear, quality, capsules), the reworded asteroid test, research
notices (with the refreshed `control.lua`), the shift-start block, the team plan (`fh board plan`), station-named
train stops, and the hosts' "previously on" and Sonnet urgent lines. This look covers 02:58 to WINDOWEND. Times are
PDT; game minutes are tick/3600 from shake4's start. Data only, read-only on the game.

## P1

1. **Most of the team's waiting is again out of reach of any wake.** Opus waits in `python3 -c "import
   time;time.sleep(840)"` while its own courier script (`opus/tools/cycle.py`) drives its character: 8 such sleeps
   asking 80.5 of the first 87 minutes, against 4% in `fh sleep`. A tell, a mention or a raid cannot wake it.
   Shake11's P1 item 3 is still open (`tools/launch-agent.sh` allows `Bash(sleep:*)`, `tools/permit.py` lists `sleep`,
   and a Python sleep needs neither); the sleep share in section 4 counts these.
2. **The team's own flamethrowers burn the team's buildings.** Loss lines name a flamethrower turret as a cause in 8
   areas in shake11 and 6 so far in shake12: gun turrets ("1 gun-turret by 1 flamethrower-turret"), radars, belts, a
   character (shake11, (-95,-176)), and the flamethrowers' own oil pipes ((38,84) and (39,85), shake12). The reply
   says it (`by N flamethrower-turret`), among enemy causes; a word that marks our own turret as the cause
   ("friendly fire") would make it stand out. File: `vendor/factorio-harness/mod/agent-harness_0.1.0/runtime.lua`
   (`describe_incident`).
3. **A small harness error hides a useful one.** `observe scope=rates` takes positions as `[x, y]`, but when nothing is
   found its message reads `pos.x`: Gemini got "runtime:5618: attempt to concatenate field 'y' (a nil value)" at 03:57
   instead of "no machine of ours at ...". File: `vendor/factorio-harness/mod/agent-harness_0.1.0/rates.lua:236`
   (format the normalised position).

## Short answer

SHORT

## 1. Research notices

NOTICES

## 2. The tools index in use

TOOLS

## 3. Research choices

RESEARCH

## 4. Sleep

SLEEP

## 5. The night in numbers

NIGHT

## Methods

Scripts in the session scratchpad, read-only on `runs/`: research notices are "research done" lines in replies and
first use is the first successful request naming an unlocked item; tool use is every request whose action is new or
names a feature's entity; research choices are `research` requests with a technology or queue; `fh sleep` from
`sleep` requests and their final `sleep_check`, shell and Python sleeps from each harness's transcript (Claude Code
projects files, Codex rollouts, Grok, agy and Muse sessions); the night table from each run's `scores.jsonl` (first and
last unpaused line), deaths as distinct respawn ticks in the replies, losses as the largest count per area in the
replies' "losses in ..." lines.
