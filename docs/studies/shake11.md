# Shake11, early look (22:54 to about 02:00)

Shake11 resumes shake10's world on world n with the same nine agents, from game minute 810. New in this shift: the
RCON broker (agents hold no password), the viewer relay (viewer lines reach agents through Clef), and, hot-deployed
at about 23:40, research notices in the team block, the team plan (`fh board plan`), circuit, train and rail tools,
and the hosts' round 4. The playbook's tools index and the reworded asteroid test reach agents only from shake12.
Times are PDT; game minutes are tick/3600 from shake4's start. Data only, read-only on the game.

## P1

1. **Research notices never fired in shake11, and cannot until the mod is refreshed.** The notice code reached the
   runtime in the 23:40 hot deploy (the runtime's `describe` lists `board_plan` from 23:45; Luna's `describe.json` was
   rewritten at 23:51), but the game only passes `on_research_finished` to the runtime if the mod's `control.lua`
   forwards it, and that forwarding came with 9246c0f (22:18), after shake11's launch commit 5ce8c32. A hot deploy
   replaces the runtime bundle, not the installed mod's `control.lua`. logistic-system finished at 23:40 and
   worker-robots-speed-1 at 23:52; no reply in any journal carries a "research done" line. The next shift's start
   ("refresh the instance's harness mod", `tools/start-team.sh:65`) installs the new `control.lua`; check the first
   finished technology in shake12 shows up in replies. A deploy check that compares the running mod's forwarded
   events with the bundle's handlers would catch this class of gap (`tools/code_check.py`).
2. **Agents do not know about the team plan.** `fh board plan` works in the runtime from 23:45, but shake11's
   `AGENTS.md` was built from 5ce8c32, which predates the plan's docs (1bca16b): no agent has called `board_plan`.
   The docs reach agents from shake12.
3. **Two agents wait in sleeps the harness cannot see or wake.** Muse waits with a shell `sleep 280` and then reads
   its queue: 46 such sleeps asking 64.6 minutes of its first 72 in shake11, against 5 `fh sleep` calls. Sonnet does
   the same through Python to get past Claude Code's block on chained shell sleeps (`python3 -c "import
   time;time.sleep(1200)"`, up to 20 minutes; 15 calls asking 218 minutes of shake10's 240), each after "Clear the
   mention by reading chat." Neither wakes on a tell, a mention, a board change or an attack, and neither shows in the
   journals, so every journal-based sleep figure so far (the sleep study's, shake10's below) undercounts these two:
   Sonnet's shake10 share reads 1% from the journal. Tool-level options: count shell and Python sleeps in the study
   scripts from the transcripts (as section 3 does), and decide whether the agents' shells should allow a bare
   `sleep` at all (`tools/launch-agent.sh` allows `Bash(sleep:*)` for Claude; `tools/permit.py` lists `sleep`).

## Short answer

SHORT

## 1. Research notices

NOTICES

## 2. The team plan

PLAN

## 3. Sleep

SLEEP

## 4. The broker and the console audit

BROKER

## 5. The viewer relay

RELAY

## 6. Defence and the unused features

FEATURES

## 7. Hosts

HOSTS

## Methods

METHODS
