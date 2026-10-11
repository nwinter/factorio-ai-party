# Shake7, early look (first ~100 minutes)

Shake7 resumes shake6's world (saved at game minute 244, tick 879043) with the same nine agents, full tools
(`POG_FULL_TOOLS=1`: own `tools/`, shared `team-tools/`, subagents, web, `gamedata/`), tells and board news
(eng/board) and the hosts' copy filter (eng/audio). It launched earlier than planned: world resumed 12:58:24, agents
13:00:47 to 13:01:10, deadline 17:00 (`runs/shake7/start.log`). This look covers WINDOW. Times are PDT; game
minutes are tick/3600 from shake4's start. Data only, read-only on the game; nothing on the box was touched.

## P1

1. **The world runs unattended at both ends of a shift.** It resumed at 12:58:24 and the first agent acted at about
   13:01:10, during a 125-biter raid: the hosts reported "Two pipes and the boiler gone" at 13:00:47 and "Thirty walls
   and four inserters lost" at 13:01:01, before any agent had played (`caster.log`). The save it resumed from was
   taken after shake6 ran about 5 minutes past its deadline (resume tick 879043, game minute 244.2). Keep the world
   paused from the resume until the agents are running, and pause it at the deadline before saving.
   Files: `tools/start-team.sh` (resume after the agents' first request, not before the directors join),
   `tools/stop-team.sh`.
2. **Two agents still speak in one voice.** Sol and Muse both hold `oa-cedar` (the `profiles` reply in
   `astra/journal.jsonl`; Muse's aloud lines play as `[voice:Muse Spark/oa-cedar]`). The shake5 fix refuses a new pick
   that another agent holds, but a duplicate already in the save is kept. Clear or reassign duplicates when a shift
   starts. File: `vendor/factorio-harness/mod/agent-harness_0.1.0/profiles.lua` (or the operator `shift_start`).
3. **The launch went ahead on a checkout that lacked the hosts' fix.** `start.log` 12:58:09: "WARNING code: branch
   eng/audio has 2 commits ... that neither this checkout nor main has". One was 84b8749, the shift-number and
   planets-reached fix for the hosts (shake6 P1 items 2 and 3). The hosts got the shift number right anyway ("Big step
   for shift four", 13:35:58) and named no planet, so no harm showed yet, but the warning did not stop the launch.
   Make the code check refuse to start unless an override is set. File: `tools/start-team.sh`.

## 1. Tells and chat

TELLS

## 2. Sleep

SLEEP

## 3. Full tools

TOOLS

## 4. Hosts

HOSTS

## 5. Progress

PROGRESS

## Methods

Scripts (scratchpad, read-only on `runs/shake7/`): tells and say counts from each agent's `journal.jsonl` (a `tell`
request's `to` and `text`, classified with `tools/analysis/chat_logistics.py`'s `classify`); chat logistics share with
`tools/analysis/chat_logistics.py runs/shake7 --since-tick 879043`; sleep from `sleep` requests and the final
`sleep_check` reply (`woke`, the `clock:` line's idle share), as in `docs/studies/sleep.md`; full tools from each
harness's transcript (Claude Code projects files, Codex rollouts, Grok `updates.jsonl`, agy `transcript.jsonl`, Muse
`session.jsonl`) and the workspaces' `tools/` and `team-tools/`; hosts from `runs/shake7/caster.log`; progress from
`runs/shake7/scores.jsonl`.
