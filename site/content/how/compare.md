# Comparing harnesses

This page puts the project's numbers next to the best-documented other Factorio harness for language models, the Factorio Learning Environment (FLE). The two answer different questions: FLE is a benchmark in which one agent writes Python programs against a game API, while this project is a nine-agent team playing one Space Age world in real time through survival-rule actions. FLE's facts are quoted from its paper and repository, with links; ours come from this run's logs, with dates.

## Side by side

The table sets the two designs next to each other. Where FLE's published sources do not say something, the cell says so; nothing here is a measured head-to-head.

| | This project (Oct 17) | FLE |
|---|---|---|
| Purpose | A live stream: nine AI agents play one world toward the Shattered Planet | A benchmark of "long-term planning, program synthesis, and resource optimization" ([paper](https://arxiv.org/abs/2503.09617)) |
| Game | Factorio 2.0.77 with Space Age, Quality and Elevated Rails | "compatible with v1.110 of Factorio" in the paper's first version; the repository lists Factorio 2.0.73 or later "only for optional rendering" ([repo](https://github.com/JackHopkins/factorio-learning-environment)) |
| How an agent acts | One shell command per action (`./fh ACTION`), each a JSON request to a Lua mod that runs it tick by tick | Python programs in a read-eval-print loop; a step is one program submitted to the server ([paper](https://arxiv.org/html/2503.09617v1)) |
| What an agent reads | Compact text replies with a clock, team news and alerts; screenshots on request, rarely used | "the output streams (stderr/stdout) of their last program" ([repo](https://github.com/JackHopkins/factorio-learning-environment)); version 0.2.0 added vision and 0.3.0 a headless renderer with "realistic pixel observations" ([v0.3.0](https://jackhopkins.github.io/factorio-learning-environment/versions/0.3.0.html)) |
| Actions | 186 named actions (113 at the run's start); the top 39 carry 90% of calls | 23 core API methods, 10 for observation and 13 for action, in the paper's first version |
| Character rules | Survival-fair: items from the inventory, the game's reach (10 tiles), walking at character speed, hand crafting time, only what the team can see | Not described in the sections quoted here |
| Time | Real time: the game runs at 60 ticks a second while agents think (57.0 median over the run) | A step returns "in-game wall-clock time"; whether the game runs between steps is not stated in the paper |
| Agents per world | Nine at once, from five labs, in five coding tools | One in the paper's experiments; multi-agent play listed as future work. Version 0.2.0 "introduced multi-agency" |
| Memory | Each tool's own compaction (thresholds 120k to 250k tokens), plus the agent's notes file across shifts | Observations and programs more than 32 steps old "summarised into a report of 1024 tokens" |
| Length | 28 four-hour shifts, 105.5 game hours, by Oct 17 08:57, one continuous world | Open-play: up to 5,000 steps per run, 8 runs per model; lab-play: 128 API calls per task, 4 runs per task (paper v1) |
| Tasks | One open goal, the Shattered Planet; the team sets its own milestones | Lab-play: 24 tasks (v1), "33 bounded tasks across three settings" in the NeurIPS version ([NeurIPS 2025](https://proceedings.neurips.cc/paper_files/paper/2025/hash/75f3a62e55187bc3e5e5961fa2a46bcf-Abstract-Datasets_and_Benchmarks_Track.html)); open-play: "build the largest factory" |
| Models | GPT-6 Astra, GPT-6.1 Sol, GPT-6 Luna, Claude Opus, Sonnet and Haiku 5.5, Grok 4.7, Gemini 3.8 Flash, Muse Spark 1.3 | Claude 3.5 Sonnet, GPT-4o, GPT-4o-Mini, DeepSeek-v3, Gemini-2-Flash, Llama-3.3-70B (paper v1) |
| Tokens | 22.6 billion over 28 shifts, 552M to 1.2B a shift | 154.5M for Claude 3.5 Sonnet's runs, about $1,318 for all experiments (paper v1, appendix B) |

## What the agents can observe

Everything an agent knows about the game comes back as text from an `./fh` call, limited to what a player could see on screen or remember. There is no map of the world beyond what the team has charted, and nothing about chunks nobody can see now except dated memory.

- Around the character: anything within 32 tiles in a visible chunk can be read (inspect, scan, status).
- At a distance: anything in a chunk the team sees now, through radar or a character, like the game's map and remote view. Replies say `by: remote view`.
- Out of sight: the last observation, marked "last seen memory" with its tick and age. Memory holds 2,048 entity summaries, 256 detailed reads and 256 belt chunks. A chest out of sight reads "unknown".
- The map: charted chunks only. Routes stay off uncharted ground. Moving enemy groups are known only where the team can see them now.
- Reads built for analysis: production rates, supply and bottleneck chains, power networks, trains, platforms and their endurance, research options. 31 actions are factory analysis reads, and in shifts 22 to 28 reads and talk outnumbered building, item moves and walking together.
- Every reply ends with the game clock, the agent's idle share and the time left in the shift, plus alerts and team news. The game speed is named when it falls under 55 ticks a second.
- Pictures: `./shot` saves a real screenshot (1280x720) rendered by a camera client, and `./fh view` draws a schematic map. 257 screenshots were taken in 28 shifts and about 410 images reached any model, against 226,467 model turns (about 0.2%). Gemini's tool showed it none. No model is fed frames automatically, and the agents do not see the stream.
- Also available: the game's prototype data as JSON (recipes, items, entities, technologies, asteroids), teammates' notes, the team board, and the web for facts.

## What the agents can do

Each agent drives one character. Every action goes through the same rules a player's character follows, and the harness refuses anything else. Agents can also write their own scripts, but the scripts act only through the same `./fh`.

- Allowed: walk at character speed (pathfinding, vehicles, trains), mine by hand, craft by hand at the game's speed, place and pick up within reach, move items between inventories, configure machines, wire circuits, set research, place ghosts and deconstruction marks in charted chunks, use construction robots once researched, launch rockets and run space platforms, fight. Agents capture and place their own blueprints.
- Not allowed: items or buildings from nothing, teleporting, seeing unexplored map, changing the game's speed, console commands, Lua or talking to the server directly, changing the harness. Since Oct 17 08:30, no blueprint strings made by viewers or found on the web.
- Not supported yet (usage doc, Oct 17): elevated rails and rail ramps, the selector combinator, and moving fluids by hand.
- Waiting: queues of up to 128 steps run inside the game with no round trip; standing orders run the agent's own routines when the character is free; `fh sleep` waits up to 900 seconds and wakes on events.
- Size of an action: one call can place up to 256 ghosts, submit a 128-step queue, or run a refuel tour over a radius. A call is not a keypress.

## Action counts

Over shifts 1 to 28 the agents sent 431,520 requests that were not the host's own polls, about 1.9 per model turn. 140,286 of them were game actions, about 1,270 an hour for the team or 141 per agent-hour. 0.8% of all requests failed.

- "Game action" is the agents page's definition: a request that is neither a read nor talk. It counts some newer reads (trace, supply, platforms, stock) as actions, so it overstates acting in later shifts.
- The most used over the run: inspect 51,676; transfer 38,525; tell 28,478; move_to 24,291; sleep 19,837; chat 13,551; place_ghosts 8,378; build 8,315; say 7,789. (A further 120,700 `observe` requests were mostly fh's own reads at the end of each wait.)
- Agent calls per shift in shifts 22 to 27, counted without help lookups or the host's reads: 10,203 to 16,326.
- 62 distinct actions were used in shift 1, and 106 to 117 a shift from shift 20.
- An fh call's round trip, from the request to the reply in the journal: a median of 45 to 60 ms in every shift, 90th percentile 67 to 195 ms (365 ms in shift 13, during the memory trouble). The model's own think time per step is seconds (median 2.2 to 8.6 s for the Codex agents in a Oct 11 test), so the game interface is 1 to 2% of a step.
- For scale, FLE's paper measured its headless server at "an average of 218 operations per second across core API functions" on a MacBook Pro M4, and 68 a second with the Python interpreter in the loop. That is throughput of API calls, not a round trip, so the two numbers measure different things.

## Tokens

Tokens are counted from each coding tool's own session logs. The run has used 22.6 billion in 226,467 model turns, about 100k tokens a turn and 161k per game action. 97% of input tokens were read from cache, and output was 0.37% of the total (84M). There is no dollar figure: the agents run on subscriptions, not metered API keys.

| Agent | Tokens, shifts 1 to 28 | Model turns | Tokens a turn | Compactions |
|---|--:|--:|--:|--:|
| Gemini | 3.87B | 34,677 | 112k | (a new conversation each turn) |
| Luna | 3.82B | 40,240 | 95k | 372 |
| Sol | 3.75B | 41,723 | 90k | 494 |
| Astra | 3.60B | 45,665 | 79k | 567 |
| Muse | 2.37B | 18,826 | 126k | 70 |
| Grok | 1.87B | 16,309 | 114k | 181 |
| Opus | 1.68B | 12,137 | 138k | 29 |
| Sonnet | 0.90B | 7,589 | 118k | 33 |
| Haiku | 0.72B | 9,301 | 77k | 236 |

The Oct 17 audit found that tokens follow turns, not reply size: every agent but Gemini compacts at a fixed threshold, so a turn costs about half of (the context after a compaction plus the threshold) whatever the replies hold. Trimming repeated reply parts would save 2 to 3M of about 870M tokens a shift. [The agents page](/how/agents/#tokens-and-context) has the detail, and [the agents' numbers](/agents/) are on the site.

For scale: FLE's paper reports 154,543,150 tokens for all of Claude 3.5 Sonnet's runs and $1,318.28 for every experiment in it. One four-hour shift here is about 870M tokens.

## Game speed and length

The run has been one continuous world since Oct 12 14:27, in real time. Over 3,290 two-minute samples the median game speed was 57.0 ticks a second (60 is real time); after the Oct 16 perf work it has stayed at 59.3 to 59.4. By Oct 17 09:01 the world had run 105h32m of game time in about 110.5 hours of score rows, about 0.95 game hours per wall hour.

- The slow stretches each had a cause: the stream's score read (fixed Oct 14 21:34), the box's memory (Oct 14 and Oct 16), and the census pass that feeds the agents' memory (fixed Oct 16 20:02). See [the harness page](/how/harness/#from-56-to-59-ticks-a-second-oct-16).
- Turn mode, which pauses the game while the agent thinks, exists in the mod and was tested on Oct 10; the live world has never used it. In that test it cut game time to early milestones by a third or more, but the game clients in paused worlds were dropped several times.
- A pre-run estimate (Oct 10 to Oct 11) put promethium science at 38, 60 or 140 game hours (low, central, high). The team researched it at 98h09m of game time.

## The run, shift by shift

Numbers at each shift's end, from the score log and the agents' logs. Shift 28 is to Oct 17 08:49.

| Shift | Technologies | Rockets | Game actions | Tokens | Model turns | fh median ms |
|---|--:|--:|--:|--:|--:|--:|
| [1](/runs/long/shift-1/) | 36 | 0 | 9,881 | 1,205M | 11,194 | 45 |
| [2](/runs/long/shift-2/) | 54 | 12 | 7,684 | 808M | 7,622 | 46 |
| [3](/runs/long/shift-3/) | 79 | 27 | 8,923 | 614M | 6,030 | 45 |
| [4](/runs/long/shift-4/) | 95 | 39 | 9,205 | 597M | 6,253 | 46 |
| [5](/runs/long/shift-5/) | 97 | 50 | 4,706 | 822M | 7,931 | 48 |
| [6](/runs/long/shift-6/) | 104 | 59 | 4,207 | 869M | 7,981 | 48 |
| [7](/runs/long/shift-7/) | 125 | 85 | 5,241 | 918M | 8,995 | 48 |
| [8](/runs/long/shift-8/) | 132 | 112 | 5,664 | 846M | 8,125 | 48 |
| [9](/runs/long/shift-9/) | 147 | 137 | 4,312 | 655M | 7,343 | 50 |
| [10](/runs/long/shift-10/) | 155 | 161 | 6,161 | 841M | 9,283 | 50 |
| [11](/runs/long/shift-11/) | 167 | 184 | 6,033 | 1,001M | 11,014 | 50 |
| [12](/runs/long/shift-12/) | 169 | 231 | 5,880 | 973M | 11,168 | 53 |
| [13](/runs/long/shift-13/) | 171 | 250 | 3,602 | 633M | 6,903 | 60 |
| [14](/runs/long/shift-14/) | 171 | 299 | 3,025 | 552M | 6,021 | 51 |
| [15](/runs/long/shift-15/) | 175 | 321 | 4,762 | 634M | 6,787 | 50 |
| [16](/runs/long/shift-16/) | 175 | 382 | 3,608 | 639M | 6,691 | 50 |
| [17](/runs/long/shift-17/) | 182 | 473 | 3,422 | 747M | 8,157 | 52 |
| [18](/runs/long/shift-18/) | 185 | 579 | 3,981 | 893M | 9,947 | 54 |
| [19](/runs/long/shift-19/) | 187 | 685 | 3,474 | 782M | 6,818 | 53 |
| [20](/runs/long/shift-20/) | 190 | 796 | 3,341 | 716M | 6,163 | 50 |
| [21](/runs/long/shift-21/) | 190 | 959 | 2,858 | 698M | 5,884 | 53 |
| [22](/runs/long/shift-22/) | 193 | 1,187 | 2,715 | 679M | 6,036 | 56 |
| [23](/runs/long/shift-23/) | 194 | 1,376 | 4,697 | 835M | 7,970 | 57 |
| [24](/runs/long/shift-24/) | 199 | 1,535 | 4,081 | 1,034M | 10,084 | 60 |
| [25](/runs/long/shift-25/) | 202 | 1,758 | 4,533 | 1,110M | 10,871 | 55 |
| [26](/runs/long/shift-26/) | 204 | 1,986 | 4,213 | 956M | 9,745 | 52 |
| [27](/runs/long/shift-27/) | 207 | 2,236 | 6,189 | 871M | 9,033 | 54 |
| [28](/runs/long/shift-28/) | 211 | 2,342 | 3,888 | 643M | 6,418 | 54 |

- Gemini's game actions fell from 700 to 3,758 a shift in shifts 1 to 12 to 16 to 65 in shifts 14 to 24, while its weekly quota allowed it about 6% of the time; that is most of the drop in the team's total.
- Shift 13 resumed from an old save for its first hour (see [the failures](/how/lessons/#failures)); counts of science packs made, which add up rises between score rows, count about 29,500 packs twice there. Rockets and technologies are the game's own counters.

## What we looked at before building

On Oct 10 the project surveyed existing Factorio harnesses before choosing one. That survey is the only comparison in the repository, and it shaped the design.

- [CarsonBurke/factorio-harness](https://github.com/CarsonBurke/factorio-harness) was chosen as the base: a command-line tool over RCON to a Lua mod running per-tick actions, with no teleport or free items. See [the harness page](/how/harness/#where-it-came-from).
- FLE was noted for its evaluation method and renderer.
- Four MCP-based harnesses were looked at for ideas: one with honest pathfinding and one instance per character, one where two Codex agents steer one character through Space Age, one with blueprint catalogues, and one that sends literal keyboard and mouse input.
- The takeaway written then, from earlier long agent runs: "the wins came from long-horizon persistence, a testing sandbox, and letting the model write its own tools on top of honest primitives. Reaction speed matters less than keeping the LLM out of low-level loops."

## Caveats

These numbers are this run's, under its conditions. They are not a benchmark score, and the run changed its own harness while it played.

- The harness grew from 113 to 186 actions during the run, by 875 commits, in answer to the agents. Early and late shifts did not play with the same tools.
- Game actions depend on which actions count as reads; requests include those the agents' own scripts send.
- Wall hours are first to last score row in each shift; about an hour of rows is missing around shifts 6 and 7 after a broken score read.
- "Compactions" mean different things per tool: Codex compacts on the server, Gemini's tool starts fresh conversations.
- The models, their tools and their settings differ from agent to agent, and they share one world, so a number for one agent is shaped by the other eight.
