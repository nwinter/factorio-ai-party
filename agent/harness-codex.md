## Your shell (Codex)

Your `exec` tool runs JavaScript; in it, `tools.exec_command` starts a command and `tools.write_stdin` reads a running
one. Each time an `exec` call returns, your model takes a turn that reads your whole context again (about 150,000
tokens late in a shift), so a 300 s `./fh sleep` polled 30 s at a time is ten model turns. Codex 0.162.1, measured
17 Oct:
- `exec_command` `yield_time_ms`: 250 to 30000 ms (default 10000). A command still running then gives `session_id` and
  no `exit_code`; one that ended gives `exit_code` and no `session_id`.
- `write_stdin` with `chars: ""` (a poll): `yield_time_ms` 5000 to 300000 ms; 600000 waited 300 s. It returns when its
  time is up or when the command exits (then with `exit_code`), not when output appears: a line printed at 20 s came
  back at 300 s. A session that has ended is gone: polling it again fails `write_stdin failed: Unknown process id`.
- The `exec` call itself: a first line `// @exec: {"yield_time_ms": 900000}` sets how long it runs before it returns
  to you (default about 30 s); with 900000 one call ran 401 s. Past that it returns `Script running with cell ID N`,
  and `wait {cell_id: "N", yield_time_ms: ...}` goes on with it.
- An error inside the script (a failed tool call) ends the `exec` call at once with `Script failed` and the error.

Example: one `exec` call for a whole sleep, returning within 15 s of the first output, at the exit, or on an error,
with the session and exit code:

```js
// @exec: {"yield_time_ms": 900000}
const t0 = Date.now();
let r = await tools.exec_command({cmd: "./fh sleep 300", yield_time_ms: 30000});
const session_id = r.session_id;
let output = r.output ?? "";
while (r.exit_code === undefined && output === "") {
  r = await tools.write_stdin({session_id, chars: "", yield_time_ms: 15000});
  output += r.output ?? "";
}
text(JSON.stringify({session_id, exit_code: r.exit_code, s: (Date.now() - t0) / 1000, output}));
```

With `exit_code` undefined the command is still running (a `--wait` action prints its acceptance first): poll that
`session_id` again the same way. The same loop works for `./fh wait --until ...` and a `--wait` action.
