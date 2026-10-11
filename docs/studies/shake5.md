# Study: shake5, the first resumed shift

Shake5 resumed shake4's saved world for one more hour with the same nine agents (Sun 2026-10-11, agents 05:21 to
06:21 PDT, world n, Space Age, normal enemies, streamed unlisted, code 41f8a20). The world was loaded at tick 446842
(game 124.1m) and the last score was taken at 186.4m. Game times below continue from shake4's start (tick/3600);
clock times are PDT.

Sources: runs/shake5/ (start.log, scores.jsonl, chat.jsonl, caster.log, analyst.log, each agent's journal.jsonl.gz,
supervisor.log and notes.md), runs/shake4/ for the handover, runs/_tests/shift-test1/, tools/stream/logs/ and the
harness source in vendor/factorio-harness/mod/agent-harness_0.1.0/. Line numbers are on main (183a2dc); `record_loss`
and `build_direct` are unchanged since 41f8a20.

## P1: before the next shift

1. Loss alerts never close. The harness keeps one loss incident per 64-tile cell for the life of the save
   (`runtime.lua:566-590`, `record_loss`), so a resumed world reports totals that began in the previous shift. The
   workshop cell's incident opened at shake4's 66-biter raid (game ~68m) and was still growing at 06:19:56: "losses in
   (-56,0)-(-4,28) 156 destroyed: 93 transport-belt, ... 9 assembling-machine-2 ... 1h56m-1s ago" (Luna's journal).
   Shake4 left that cell at 69 destroyed. At 05:45 Luna told the team a raid "killed me and has destroyed 96
   structures (53 belts, 11 inserters, 10 poles, 5 turrets, 6 assemblers, etc.)" (chat seq 1205), reading the
   two-shift total as one raid. Fix: start a new incident when the cell has been quiet for a few minutes, and at
   resume; keep the old one in `status alerts` history.
2. `build` over an existing machine places a second one on the same tiles. At 05:27:57 Opus built four
   assembling-machine-2 on its four assembling-machine-1 sites (green science). The score shows assembling-machine-2
   10 to 14 with assembling-machine-1 unchanged at 35 (05:27:51 to 05:29:52). The old machines kept taking
   ingredients, the new ones came up with no recipe (Opus 05:32:39: "the 4 green asm2 had lost their recipe"), and
   the overlap lasted until Sol found "BOTH asm1 and asm2 on each tile" at 06:14:50 and mined the asm1s
   (assembling-machine-1 34 to 30 at 06:16). Opus filed it with `harness_request` at 06:15:23. Cause:
   `build_direct` (`runtime.lua:1801-1805`) checks `can_place_entity` with the manual build check, which allows a
   fast-replace, then calls `create_entity` without `fast_replace=true`, so the old machine stays. Fix: pass
   `fast_replace=true, spill=false` with the player (the old machine returns to the inventory and the recipe carries
   over), or refuse with an error that names the machine in the way.
3. The hosts were never told this was a later shift, and they ended it as if the run were over. No fact set
   mentions the resume or shake4 (178 fact sets, `tools/stream/logs/caster-20261011-052058.jsonl`). The opening line
   was "Two hours in and the team's cracking oil!" (05:21:04, `caster.log:2`). At the deadline Vale asked "will the
   horn freeze their queue again?" (06:20:22) and Rook said "Horn swallows them whole—Processing unit dies at
   sixty-five!" (06:20:37, `caster.log:453`). The world was saved with processing-unit at 74% in the queue. The
   writer rule "The run goes on until the deadline" (`tools/stream/caster.py:495-496`) reads as "the run ends at the
   deadline". Fix: when `runs/<run>/resumed-from` exists, add a `shift` fact in `facts_for` (`caster.py:470`, open
   event) and `context_facts` (`:361`) giving the shift number, the run it continues, the game minute it resumed at
   and "at the deadline the world is saved and the next shift continues it". Reword `:495-496` to match.
4. The stage label "Oil" was read as "the oil is dry" after blue science started. All 178 fact sets carry stage
   "Oil", because stage 3 covers both oil products and chemical science (`tools/stream/model.py:44`). Petroleum
   reached the sulfur plant at 05:38:48 and the run made 566 blue packs. Still, ten host lines after 05:54 said the oil
   was dry, among them "oil stage choking—can they crack blue?" (05:54:00) and "Twenty-three pipes drowned in crude
   that never reached the refineries" (06:12:06). Fix: rename `STAGE_LABELS[3]` to "Oil and blue science", or have
   the stage fact say what is being made.
5. A chosen ElevenLabs voice outlived the fix. Hiding the `el-` voices in agent/voices.md did not reset Opus's
   existing pick, which is in the save: both Opus aloud lines were sent to ElevenLabs as el-george, got 401 "0
   credits" (`caster.log:15`, `:389`) and played as OpenAI fable. Sol and Muse also share oa-cedar. Fix: map an `el-`
   pick to its fallback in the TTS path without calling ElevenLabs while it has no credits, and have
   `profiles.lua` refuse a voice another agent holds. Seven lines of airtime, so do it if cheap.
