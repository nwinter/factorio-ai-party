# Lua heap probes (batch334)

Measurement scripts for the harness's Lua heap, for a private copy only (`--world imac`). `rc.py` refuses world n
unless `--n` follows the code; on n, send only `collectgarbage("count")` reads. Nothing here is a test.

- `rc.py WORLD FILE.lua` or `rc.py WORLD -e CODE`: one `/silent-command __agent-harness__` (no `--` comments in the Lua).
- `calls.py WORLD N MODE`: N rounds of `signal_watch {}` and `status` as bot sol through dispatch. Each call is timed
  with the heap before and after. MODE is `normal`, `stop` (collector stopped around each call) or `collect` (a full
  collect before each call). It writes calls_MODE_TIME.json in the current directory.
- `steps_live.lua` with `steps_sum.py OUT`: steps the cycle in progress to its end, 142 KB a step, and times each step.
  `twocycles.lua` does two cycles back to back.
- `walk.lua` and `walk2.lua`: storage size estimated per top-level key, and per child of the largest keys.
  `calib.lua`: deep copies against the estimate. `codesize3.lua`: the compiled runtime's size.
- `reads.lua`: bytes allocated per API read (collector stopped).
- Per-part allocation: `remote.call('agent_harness','profile_ticks',{seconds=30, alloc=true, gc='stop'})`, then
  `tools/profile_log.py --run -1 LOG`. A part's count includes the parts nested inside it.
