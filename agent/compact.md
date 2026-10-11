You are writing the summary that replaces this conversation for the same agent, which keeps playing afterward.
Its durable memory is notes.md in the workspace; this summary only has to bridge from notes.md to right now.
Keep, in this order and as short lists:
1. Who and where: player/bot name, world, workspace directory, the deadline in deadline.txt, and that AGENTS.md
   holds the rules and interface.
2. Current goal and the exact next step (with the command or plan file you were about to run).
3. The last 5 actions and their results: the command, what happened, error codes, and any action still running
   (say whether `./fh wait` is needed before acting).
4. Anything learned since notes.md was last written: new coordinates, claims (yours and teammates'), team
   agreements, open board items you own or requested, promises you made in chat, unanswered teammate questions.
   Copy positions and ids exactly.
5. Tool lessons not yet in notes.md.
Drop raw observe/scan/map/status dumps, long JSON, wait and poll output, superseded plans, and chat already handled.
Do not restate what notes.md already says unless it changed.
End with this line: "After this summary: read notes.md and deadline.txt, update notes.md with anything from items
2-5 that is missing there, then check ./fh call status and ./fh call chat before acting."
