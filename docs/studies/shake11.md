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
