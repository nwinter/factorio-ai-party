## Your shell (Codex)

`exec_command` returns after `yield_time_ms` (about 10 s by default) while the command keeps running. For a `--wait`
action or a `wait_until` longer than that, set `yield_time_ms` above the wait, or the reply comes back before the
result. The opposite also works: start a long action or queue plan with `yield_time_ms` 1000, plan your next step while
your character works, and read the result before you act on it.
