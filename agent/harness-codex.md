## Your shell (Codex)

Your `exec` tool runs JavaScript; in it `tools.exec_command` starts a command and `tools.write_stdin` reads a running
one. Each `exec` return is a model turn that reads your whole context again (about 150,000 tokens late in a shift):
a 300 s `./fh sleep` polled 30 s at a time is ten turns. Codex 0.162.1, measured 17 Oct:
- `exec_command` `yield_time_ms`: 250 to 30000 ms. Running then: `session_id`, no `exit_code`; ended:
  `exit_code`, no `session_id`.
- `write_stdin` with `chars: ""` (a poll): `yield_time_ms` 5000 to 300000 ms. It returns at its
  time or at the command's exit (with `exit_code`), not when output appears: a line printed at 20 s came
  back at 300 s. Polling an ended session fails `Unknown process id`.
- The `exec` call itself: a first line `// @exec: {"yield_time_ms": 900000}` sets how long it runs before returning
  (default about 30 s); with 900000 one call ran 401 s. Past that: `Script running with cell ID N`;
  `wait {cell_id: "N"}` goes on with it.
- A failed tool call ends the `exec` call (`Script failed` and the error).

Example: one `exec` call for a whole sleep, returning within 15 s of the first output, at the exit or on an error:

```js
// @exec: {"yield_time_ms": 900000}
const t0 = Date.now();
let r = await tools.exec_command({cmd: "./fh sleep 300", yield_time_ms: 15000});
const session_id = r.session_id;
let output = r.output ?? "";
while (r.exit_code === undefined && output === "") {
  r = await tools.write_stdin({session_id, chars: "", yield_time_ms: 15000});
  output += r.output ?? "";
}
text(JSON.stringify({session_id, exit_code: r.exit_code, s: (Date.now() - t0) / 1000, output}));
```

`exit_code` undefined: it still runs (a `--wait` action prints its acceptance first); poll that `session_id` again.

`request_user_input_async` reaches no one in a run: it returns `{"accepted":true}` and no answer comes.
`./fh call operator --args '{"text":"..."}'` reaches the operator.
