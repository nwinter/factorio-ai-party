# Engineer task: the commentators' Factorio knowledge and an analyst agent (branch eng/analyst)

The stream's two hosts (`tools/stream/caster.py`, being reworked on eng/audio into bantering streamer hosts) write
each line with a fast small model (Gemma 4 26B on Workers AI, about 1 s) from a small snapshot of facts. They don't
know much Factorio and get things wrong: they mix up our damaged buildings with attacking enemies, think research
progress can be lost, and can't say what comes next or whether the team is playing well. Nick wants them to know a
lot about the game, the experiment and AI. Speed matters for live lines, so split the work like a broadcast: a slow,
knowledgeable analyst feeds talking points to fast on-air hosts.

Build:

1. A Factorio knowledge base from the game itself, exact for our version: dump prototypes over RCON (recipes with
   ingredients and times, technologies with costs, prerequisites and unlocks, items, machines with speeds, mining
   rates, power) from world `live` for base 2.0.77, and later Space Age (eng/spaceage is setting up a Space Age world;
   coordinate via docs). Add short curated notes for what the data doesn't say (milestones and typical pacing,
   what good vs poor play looks like, common mistakes, how biters and pollution work, Space Age planets and the
   Shattered Planet). Wiki text may be summarised for our own use; cite sources in the notes.
2. Lookup tools in Python over that base: recipe and tech lookups, prerequisites to a goal, ratio and rate
   calculations (e.g. how many assemblers for N science per minute), compare our production with the target.
3. The analyst: a strong model (Claude Sonnet or Opus through `claude -p` on a subscription route, or another you
   justify) running every 60 to 120 s during a run, with read-only tools: game reads through `bin/fh` with
   `"peek":true` so agents' hints are untouched (production statistics, research, entity counts, power, board,
   chat), the knowledge tools, run history (docs/PLAN.md, docs/studies/) and the agents' notes.md files. It
   writes talking points, storylines and judgements with their facts (for example: "15 SPM at 40 min, shake1 had 11;
   green science is starved by copper; next milestone is oil, which usually comes at about 2 h"), into the stream
   service (`tools/stream/serve.py`) for the hosts, and suggests segments (eng/stream2 is building segment types such
   as a production analysis or a map overview).
4. A check: 30 Factorio questions of the kind viewers would ask, answered by the analyst with its tools and by the
   hosts' writer without them; report accuracy and latency.

Coordinate with eng/audio (consumes talking points in the hosts' prompts) and eng/stream2 (segments) through
docs/ANALYST-NOTES.md. Rules: never write to a game (reads only), never touch worlds a, b, c or n during a run;
commit to eng/analyst in small commits ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; do not
push or touch main. Stop by the deadline in deadline.txt.
