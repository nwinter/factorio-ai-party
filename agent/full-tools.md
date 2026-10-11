## Your tools

Besides `./fh` and `./shot` you have a full engineering setup:
- `tools/` in this directory is yours: scripts, calculators, simulations, blueprint planners, anything you write.
- `team-tools/` is shared with your teammates: what you put there they can read and run, and theirs is there for you.
- `gamedata/` holds the game's own prototype data for this version ({{KB}}): `recipes.json`, `items.json`,
  `entities.json`, `fluids.json`, `technologies.json` and `locations.json`, the same facts the wiki has. Read-only.
- Python 3 with its standard library, and the usual shell programs.
- {{HARNESS}}

Only `./fh` acts in the game: your tools can compute and plan, and they reach the game through `./fh` as you do.
Teammates' workspaces apart from their `notes.md` are theirs.
<!-- harness -->
claude: The Agent tool starts subagents (they get the same tools as you); WebSearch and WebFetch search and read the web (the Factorio wiki, calculators); Bash commands can run in the background, and Read shows images such as your `./shot` screenshots.
codex: Subagents (the multi-agent tools such as spawn_agent), live web search (the Factorio wiki, calculators), and view_image for images such as your `./shot` screenshots.
grok: Subagents (spawn_subagent) and workflows, web search and web_fetch (the Factorio wiki, calculators), commands that run in the background, and read_file shows images such as your `./shot` screenshots.
agy: Subagents (invoke_subagent, define_subagent) and web search and page reading (search_web, read_url_content: the Factorio wiki, calculators).
muse: Subagents (subagent_spawn and the other subagent tools), web_search and web_fetch (the Factorio wiki, calculators), background work (bash_input, monitor), and read_file shows images such as your `./shot` screenshots.
