# Engineer task: Space Age feasibility and plan (branch research/spaceage)

Nick wants the long-running game to be Factorio: Space Age, with an unbounded goal: keep raising science production
past the Shattered Planet (promethium science and infinite research). Today everything runs on the base game
2.0.77: a headless server, three standalone base-game director clients (D:\pog\factorio-2.0.77-alpha) and the
agent-harness mod. Earlier, downloading the expansion build from factorio.com with our token returned 403.

Find out and write up, with evidence:

1. Access. What the box needs to host and watch a Space Age game: does the headless server include the expansion
   content; what do the director clients need (an expansion-enabled standalone build? how is it unlocked: owning
   Space Age on Steam and linking the Steam account on factorio.com?); can we run three or more clients without
   Steam, as now. Say exactly what Nick must do, if anything. Don't change Nick's own Steam install or
   %APPDATA%\Factorio.
2. Harness on Space Age Nauvis. Start a peaceful Space Age world on the box (a new instance name such as `sa`, its own
   ports; never touch worlds a, b, c, n or live), deploy the harness, and run its tests and a scripted early game
   with a bot (mine, craft, build, research). List what breaks (prototype names, recipes, quality, surfaces,
   spoilage, the crash site) and fix what's small on this branch.
3. What Space Age needs beyond Nauvis: rockets and cargo pods, space platforms (hub, construction from the hub
   inventory, thrusters, asteroid collection, routes), travel between planets, other surfaces (Vulcanus, Fulgora,
   Gleba, Aquilo), quality, spoilage, elevated rails, the Shattered Planet trip. For each: the harness actions and
   reads needed, and how the no-cheat survival rules map (for example, the player has no character on a platform:
   what is the honest equivalent?). Rough effort per item.
4. Pace and cost. Human first playthroughs to the Shattered Planet take on the order of a hundred hours or more:
   estimate our team's pace from runs so far (docs/PLAN.md, docs/studies/), what that means in agent-hours and
   subscription quota (Codex is the tightest: about 2.5% of a weekly allowance per agent-hour), and a staged plan.

Rules: commit to research/spaceage in small commits ending with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; do not push or touch main. Write `docs/SPACEAGE.md`.
Stop by the deadline in deadline.txt.
