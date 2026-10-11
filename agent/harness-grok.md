## Shell tip for this harness

Your shell refuses loops and other control flow (`for`, `while`, `if`), whatever is inside them. To repeat a call,
use a short `python3` script, which runs without asking, for example
`python3 -c 'import subprocess; [subprocess.run(["./fh", "call", a]) for a in ("status", "board")]'`, or a queue plan.
