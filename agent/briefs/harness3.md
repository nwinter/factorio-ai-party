# Engineer task: harness bugs from shake2 (branch eng/harness3)

The shake2 study (`docs/studies/shake2.md`, section 13, P2 item 10, and the errors in section 7) lists harness bugs that
cost agents time. Fix them in `vendor/factorio-harness`:

- `inventory` as an alias of the inventory part of `status` (15 failed calls in shake2).
- `describe.json` greppable the way agents grep it (`"name": "<action>"` on the action's own line).
- `construct`'s PlayerIdentification bug.
- `shoot` not spending ammo (Grok reported it; check against the survival rules: shooting must use real ammo).
- `observe scope=stock` without an item.
- `./shot` (workspace screenshots) never delivering.

Two other engineers change the harness tonight: eng/board (chat, say, confess, error lines) and eng/harness2 (camera
zoom, in-game name tags and avatars). Stay inside these bugs to keep merges small, and say in your notes which files
you touched.

Rules: survival rules unchanged; every fix gets a fake-engine test; `npm test` and all `lua tests/*.lua` stay green.
Verify live on world `live` with bots named `h3-*` (other engineers use it too; never stop or recreate it, and never
touch worlds a, b, c or n). The guardrail hook blocks `tools/winps.sh` in engineer sessions; if you need something run
on the box, write the exact command in your notes and say so in your final message. Commit to eng/harness3 in small
commits ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; do not push or touch main. Write
`docs/HARNESS3-NOTES.md`. Stop by the deadline in deadline.txt.
