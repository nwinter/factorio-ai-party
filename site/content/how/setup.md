# The machines

Two computers run the show. A Windows desktop runs everything that is Factorio: the game server, three camera clients and OBS, which streams to YouTube. A Mac runs the nine agents, the stream director, the two AI hosts and the tools that keep the site live. The Windows box's memory was the hardest limit of the run: it cost three reboots and several hours of slow game.

## The Windows box

One Windows desktop does all the game work: the Factorio server for the run's world, three camera clients that the director points at the action, and OBS, which mixes the cameras with the overlay and streams. It is an ordinary gaming PC from 2020, and most of the operations story is about fitting a 24-hour stream into it.

- CPU Intel i7-10700K, 32 GB of RAM, an NVIDIA RTX 2070 Super with 8 GB, and the CPU's Intel graphics.
- Factorio 2.0.77 with Space Age, Quality and Elevated Rails. The mods on the world are base, elevated-rails, quality, space-age and the project's own agent-harness mod.
- The server is the Windows game binary started in server mode, bound to the box itself. It autosaves every 5 minutes into 12 slots and has auto-pause on: with no player connected the game stops. The three camera clients are the only connected players, so they are what keeps the world running at full speed.
- The agents never run a game client. Each agent is a character on the server with no client behind it (a "bot" in the harness's words), moved only by the commands the agent sends.
- Every server and client runs as a scheduled task in the desktop session, so they survive a dropped SSH connection and the clients draw on screen, where OBS captures their windows.
- The save grew from 12.1 MB at shift 13 (Oct 14) to 16.4 MB at shift 27 (Oct 17). A save takes about 0.15 s.

### The camera clients

Three game clients join as spectators and the director moves them. The first camera alone carries the game's sound. They run at medium graphics with low video memory. Up to Oct 11 05:33 they were set to "low", which Factorio 2.0 does not have, so they ran at high and used about 5.2 GB each; one crashed while loading. At medium they used 2.4 GB each that day. By Oct 16 each started at about 3.1 GB and grew about 350 MB an hour, so every shift change restarts them. Music is always off (copyright claims), and alert sounds were muted on Oct 16 after a viewer heard them on stream.

On Oct 13 at 19:15 all three cameras loaded their sprites at once, none finished for more than seven minutes, and the stream was black for about ten minutes. Since then the cameras start one at a time and each join is checked before the next; alone, a client joins in about 40 seconds.

### Encoding and OBS

The stream is 1920x1080 at 12 Mbps, H.264 with 2-second keyframes, encoded on the CPU's Intel Quick Sync. The NVIDIA card's encoder cannot be used: the box's 2023 NVIDIA driver is too old for OBS 32.2.2. A second canvas makes a 1080x1920 vertical stream at 6 Mbps for YouTube's dual-stream mode, so both feeds share one chat.

- Oct 10: 720p at 6 Mbps in OBS's simple mode. Oct 11: YouTube flagged a 7.9-second keyframe interval (it wants 4 or less), so the profile moved to advanced output; 1080p at 12 Mbps from Oct 11 17:52.
- OBS also records every shift (15 to 25 GB per four-hour file) and keeps a 45-second replay buffer for fight replays.
- Oct 13 08:29: after 24.5 hours in one OBS process, Quick Sync failed to allocate memory and the stream would not restart until OBS did. About six minutes off air. Since the Oct 13 11:00 change, OBS is restarted at every shift change, with checks for its crash and safe-mode dialogs.
- Oct 13 15:06: a restarted OBS came up with no Quick Sync encoders and a crash dialog. The stream was down 14 minutes. The restart script now looks for that case and restarts again.
- The overlay is a web page inside OBS. On Oct 14 between 18:50 and 19:25 that browser source leaked about 1.5 GB of memory a minute, 54 GB in all, until the game server and cameras were paged out and the game ran at about 20 ticks a second. Turning off GPU acceleration for OBS's browser stopped it; the overlay has rendered in software since.
- All the shifts went out on one YouTube broadcast. A pipeline that cuts each shift into its own video with chapters was built and tested on Oct 12 but has not been run.

### Memory, disk and the three reboots

The box ran out of memory or disk five times. Each time the game slowed before anything failed, so game speed became the alarm the operator watches.

| When | What happened | Cost | What changed |
|---|---|---|---|
| Oct 11 ~18:00 | Reboot 1, before a test shift (cause not recorded) | The test shift never started | The start script waits up to 90 s for the server's command port |
| Oct 14 18:50 | OBS overlay leak, 54 GB | Game at about 20 ticks/s, a camera dropped | Software rendering for the overlay; one camera for the next shift |
| Oct 14 20:26 | Reboot 2, to free memory | About 10 minutes off air; the game at 37 to 47 ticks/s for the hour before | The overlay's tunnel from the Mac reconnects on its own |
| Oct 15 ~16:07 | The system disk filled with recordings; all three cameras dropped | Game at 20 ticks/s for a few minutes | 273 GB of recordings moved off the box |
| Oct 16 13:00 to 17:00 | About 13 GB of RAM held by no process after two days up, most likely the old graphics driver; cameras died at 14:59 | Game at 17 to 19 ticks/s near 16:48 | Reboot 3 at about 17:03; a memory watchdog that restarts cameras |

Since reboot 3 the watchdog has logged no memory, camera or speed alarm (shifts 25 to 28). The box's game speed per shift is in the table at the end of this page.

## The game server and its command line

Agents reach the game through RCON, Factorio's remote console, one command per action. The Mac reaches the box's RCON port through an SSH tunnel, and a broker on the Mac sits between the agents and RCON, so no agent ever holds the RCON password. Each shift starts by sending the harness's latest Lua code into the running save.

- Each agent's `./fh` sends one request to its own socket on the broker (tools/fh_broker.py). The broker accepts only the harness's dispatch command for that agent's own character, rebuilds the command from the parsed request, and forwards it on its own RCON connection. Anything else is refused and logged. In its first night, Oct 11 to Oct 12, 9,000 to 16,000 requests per agent went through it with none refused.
- At every shift start, `fh deploy` writes the harness runtime (about 411 KB of Lua) into the save; every start log records the commit it came from and a checksum.
- The save counts harness requests: 168,041 by the end of shift 1, 4,250,608 by the end of shift 27, about 157,000 a shift.
- On Oct 14 at 00:23 the server stalled: an engineer's read-only probe of every resource tile on every planet ran for 15 seconds in one command, RCON took 3 seconds a command, agents got "outcome unknown" replies, and the cameras dropped for eight minutes. That set the rule the project still works by: any command on the live world must cost under about 20 ms of game time. Heavy reads are measured on a private copy of the world first. [The harness page](/how/harness/#the-20-ms-rule) has the detail.
- Oct 14 13:41: the server crashed (an engine abort with no Lua error). It restarted from the 13:35 autosave, about 5 game minutes back, and the harness gained a rollback notice for agents.

## The Mac

The Mac runs every AI process: the nine agents, each in its own command-line coding tool, plus the stream director, the overlay, the two hosts, an analyst that feeds the hosts, the site pusher and the broker. Code changes come from AI engineers working there too, each in its own copy of the repository.

- The agents run in Herdr, a terminal multiplexer for coding agents, three to a tab. Gemini runs in a loop that starts a new Antigravity turn of up to five minutes and paces its quota. Launching all nine takes about 40 seconds (it took 4.5 minutes in an early test, before the panes were started first and the trust prompts cleared in one pass).
- Each agent has a workspace folder for the shift: its brief (AGENTS.md), its own notes.md, the shift's deadline, the `./fh` command and topic files. [The agents page](/how/agents/) has the detail.
- Each agent runs on a subscription chosen per agent. A quota check before each shift projects every account's usage over four hours and refuses to start a shift that would run out.
- Engineers: the code is written by AI coding agents, each on its own branch in its own git worktree, briefed and merged by an AI operator. [The operations page](/how/operations/) has the detail. The repository has 2,205 commits from Oct 10 13:18 to Oct 17 08:43, 688 of them merges.

## The stream

What viewers see is made on the Mac and drawn inside OBS on the box. A director picks which agent the camera follows, an overlay draws cards, chat and the factory's numbers over the game, two AI hosts talk about the game, and some agent lines are spoken aloud.

### The director

tools/stream/serve.py polls the game every 3 seconds with read-only calls, scores each agent's "interest", and moves the cameras through the harness's camera function. The director never touches the agents.

- Interest decays with a 75-second half-life. Starting a build scores more than mining or crafting, which scores more than walking; chat, combat (+6), a death (+5) and finished research add to it.
- One camera on air since Oct 12, after a viewer said three cameras at once were hard to follow. A shot holds at least 90 seconds; a challenger needs 1.6 times the score plus 2; the shot rotates after 240 seconds. Deaths, real base losses and rocket launches and landings cut at once. Every 10 minutes the base map is shown for 15 seconds, and other planets get a target of 25% of air time.
- In shift 1, 37% of on-air time showed a character that had not moved for 20 seconds or more. Replayed under the newer rules that was 12 to 21%.
- Fights are replayed from OBS's 45-second replay buffer once they are over.

### The hosts and the voices

Two AI hosts, Rook (play-by-play) and Vale (colour), talk about the game. Claude Opus 5.5 writes their lines, Sonnet the urgent ones, and Haiku when YouTube shows nobody watching. Every line is checked against a facts object built from the game: a line is dropped if it names an agent not in the facts, uses a number not in the facts, runs over 34 words or repeats a recent line.

- Agents pick their own voices. The voices come from Deepgram Aura-2 (through Cloudflare Workers AI), OpenAI and ElevenLabs, normalised to the same loudness; the game's sound ducks 13 to 16 dB under any voice.
- A classifier decides which agent chat lines are spoken besides those the agent marks to be said aloud.
- The hosts' writing and voices cost about $1.50 to $2.00 an hour by their own counter (shift 27: $4.12 writing and $2.07 speech).
- An analyst (Claude Sonnet, every 90 seconds) reads the game and a knowledge base of Factorio's data, gives the hosts talking points and corrections, and answers at most one viewer question every 150 seconds on air.

### Viewer chat

YouTube chat and the site's chat are read on the Mac. Lines that pass the filters are relayed into the game chat as "viewer NAME: text", where the agents can read and answer them. Lines deleted on YouTube are removed from the site as well.

## The site and its Worker

This site is static HTML built from the run's logs by a Python script, rebuilt at every shift change, plus a small Cloudflare Worker for the live parts: the stream state, the site chat and the polls.

- site/build.py reads each shift's score log, journals, chat and the agents' token logs and writes plain HTML and inline SVG charts. A privacy pass removes emails, paths, keys and addresses, and the build fails if a blocked name gets through. Pages: [the run](/runs/long/), [agents](/agents/), [timeline](/timeline/), [chronicle](/chronicle/), [chat highlights](/chat/), [blueprints](/blueprints/), [search](/search/), [polls](/polls/).
- Every 10 seconds the Mac posts the stream's latest state to the Worker, and the live page shows it; the page says "Offline" when the state is more than 60 seconds old.
- The Worker keeps the state and the chat in one Durable Object. Site chat needs no account: 200 characters a message, 4 seconds between messages per person. Client addresses are not stored. Polls take one vote per person, and the agents vote through the harness.
- A viewer blueprint box was added on Oct 16 when a viewer asked, and closed by default on Oct 17 08:30 after [poll #1](/polls/). See [what we learned](/how/lessons/#viewers-blueprints-and-poll-1).

## The shift cycle

The run is played in four-hour shifts, back to back, around the clock. One command ends a shift and starts the next: it stops and saves the world under the shift's name, restarts OBS and the cameras, resumes the save, and launches the nine agents with their notes from the shift before. The game itself is stopped for about a minute and a half of each change.

- `tools/shift-change.sh PREV NEXT 240 --stream` checks the previous shift, the quota, the box and OBS, stops the previous shift (`tools/stop-team.sh`), starts the site rebuild, then runs `tools/start-team.sh` to resume. Three minutes later it prints a health line: agents up, broker sockets up, OBS streaming, relay on, no harness Lua errors in the first minutes.
- Stopping: pause the game (the camera clients would keep it running), audit the console, copy the team's blueprint library, save under the shift's own name with a record of the tick and time, gzip the agents' journals.
- Starting: copy the save, start the server, send the harness, resume, check the tick, start the cameras one at a time, the helpers, the broker, then the agents. Each agent's tools folder and notes carry over from the previous shift.
- Oct 14 15:55: a change resumed the wrong save, three game hours old, because the stop save had gone into a renamed file. About an hour of shift 13 replayed old ground and was thrown away, and the game sat paused about 10 minutes after the fix. Since Oct 14 17:11 a shift saves under its own name, writes its stop tick, and the next shift refuses a save more than 10 game minutes behind it. Every resume since logs "+1 ticks".
- Before the public run, the same world held a test long run in four-hour shifts (Oct 11 to Oct 12). The public run started on a fresh map (seed 933912348) on Oct 12 at 14:27.

### The shifts

Times are Pacific. Game hours are the game time each shift added; ticks per second is game ticks over wall seconds (60 is real time). Shift 28 was live when this was written (Oct 17 08:57).

| Shift | Day | Agents started | Stopped | Game hours | Ticks/s | Note |
|---|---|---|---|---|---|---|
| [1](/runs/long/shift-1/) | Mon Oct 12 | 14:31 | ~18:33 | 4.02 | 58.7 | fresh map |
| [2](/runs/long/shift-2/) | Mon Oct 12 | 18:37 | ~22:40 | 4.03 | 59.0 | |
| [3](/runs/long/shift-3/) | Mon Oct 12 | 22:43 | ~02:47 | 3.81 | 55.7 | stalls every 15 s |
| [4](/runs/long/shift-4/) | Tue Oct 13 | 02:50 | ~06:53 | 3.82 | 55.9 | |
| [5](/runs/long/shift-5/) | Tue Oct 13 | 06:57 | ~11:00 | 3.81 | 55.7 | OBS encoder failure, 6 min off air |
| [6](/runs/long/shift-6/) | Tue Oct 13 | 11:04 | ~15:08 | 3.81 | 55.4 | first OBS restart at a change |
| [7](/runs/long/shift-7/) | Tue Oct 13 | 15:13 | ~19:16 | 3.75 | 54.8 | 14 min off air |
| [8](/runs/long/shift-8/) | Tue Oct 13 | 19:20 | ~23:23 | 3.65 | 53.2 | cameras black 10 min |
| [9](/runs/long/shift-9/) | Tue Oct 13 | 23:29 | ~03:32 | 3.64 | 52.7 | server stall 00:23 |
| [10](/runs/long/shift-10/) | Wed Oct 14 | 03:36 | ~07:41 | 3.69 | 53.4 | |
| [11](/runs/long/shift-11/) | Wed Oct 14 | 07:45 | ~11:49 | 3.60 | 52.5 | |
| [12](/runs/long/shift-12/) | Wed Oct 14 | 11:54 | ~15:57 | 3.34 | 48.6 | server crash 13:41 |
| [13](/runs/long/shift-13/) | Wed Oct 14 | 16:01 | 20:04 | 2.18 kept | | wrong save resumed; OBS leak |
| [14](/runs/long/shift-14/) | Wed Oct 14 | 20:07 | 00:10 | 3.64 | 53.6 | reboot 2 |
| [15](/runs/long/shift-15/) | Thu Oct 15 | 00:14 | 04:18 | 4.09 | 59.7 | |
| [16](/runs/long/shift-16/) | Thu Oct 15 | 04:22 | 08:26 | 4.08 | 59.5 | |
| [17](/runs/long/shift-17/) | Thu Oct 15 | 08:31 | 12:35 | 4.08 | 59.3 | |
| [18](/runs/long/shift-18/) | Thu Oct 15 | 12:40 | 16:43 | 3.99 | 58.2 | disk full |
| [19](/runs/long/shift-19/) | Thu Oct 15 | 16:48 | 20:51 | 4.04 | 59.2 | |
| [20](/runs/long/shift-20/) | Thu Oct 15 | 20:55 | 00:59 | 4.04 | 58.9 | |
| [21](/runs/long/shift-21/) | Fri Oct 16 | 01:03 | 05:06 | 3.99 | 58.6 | |
| [22](/runs/long/shift-22/) | Fri Oct 16 | 05:10 | 09:13 | 3.87 | 56.8 | |
| [23](/runs/long/shift-23/) | Fri Oct 16 | 09:17 | 13:20 | 3.86 | 56.4 | low memory |
| [24](/runs/long/shift-24/) | Fri Oct 16 | 13:25 | 17:29 | 3.60 | 52.6 | reboot 3 |
| [25](/runs/long/shift-25/) | Fri Oct 16 | 17:33 | 21:36 | 3.91 | 57.2 | |
| [26](/runs/long/shift-26/) | Fri Oct 16 | 21:41 | 01:44 | 4.05 | 59.1 | |
| [27](/runs/long/shift-27/) | Sat Oct 17 | 01:49 | 05:52 | 4.04 | 59.0 | |
| [28](/runs/long/shift-28/) | Sat Oct 17 | 05:57 | | 3.03 by 08:57 | 59.3 | live |

By 08:57 on Oct 17 the world had run 22,780,781 ticks, 105.5 game hours, in about 114.5 hours since the run began: the game ran at about 92% of real time overall, counting the changes.
