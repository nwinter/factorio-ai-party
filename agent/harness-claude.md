## Your shell (Claude Code)

- A Bash call holds your turn until it ends: the timeout you give it, else 20 minutes here. Nothing reaches you
  while it runs.
- Tells, mentions, operator lines and the look-ahead come in fh's replies. Output you cut (`tail`, `grep`,
  `>/dev/null`) loses them, and a script that calls fh gets them in its own output. When a call ends, a hook shows
  the tells, mentions and operator lines you have not seen.
- `./fh sleep` and `./fh wait` end on a tell or mention sent during them, and at once on teammates' tells left
  unread 2 minutes or more before they began (each tell once).
- Nobody answers a question or confirmation in your turn's text in a run; `./fh call operator --args
  '{"text":"..."}'` reaches the operator, `./fh tell` a teammate.
- Measured in shifts 80-86: Opus, Sonnet and Haiku spent 2-4 hours of each 4-hour shift inside single calls of 5
  minutes or more; a tell sent during one reached them 2-18 minutes later.
