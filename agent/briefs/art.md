# Engineer task: agent avatars and a Factorio-native visual kit (branch eng/art)

1. Avatars that agents design themselves. Extend the harness `profile` action (vendor/factorio-harness,
   `profiles.lua`; read docs/BOTS-NOTES.md) with an optional `avatar` spec: a small parametric, Factorio-flavoured
   pixel-art portrait (engineer/robot/biter-ish bases, helmet, visor, emblem, accessories, palette from the agent's
   colour) that agents choose with a few fields (no free-form images, no copyrighted game sprites). Validate and
   store it; `profiles` returns it. Write the renderer once as a dependency-free JS module
   (`tools/stream/static/avatar.js`, SVG output) plus a Python port or a node CLI for the website, and a gallery page
   showing ~40 random valid avatars and the 9 current agents' defaults (`tools/stream/static/avatars.html`). Agents
   without an avatar get a deterministic default from their name and colour (never just a letter).
2. A Factorio-native design kit for the overlay and the website: CSS tokens and components that echo the game's GUI
   (dark beveled panels, inset slots, orange highlights, the game's typographic feel via a free web font such as
   Titillium Web), item-slot styled badges, progress bars like the research bar. Put it in
   `tools/stream/static/factorio-ui.css` with a demo page. Do not copy game image assets.
Coordinate: the overlay engineer (branch eng/stream2) owns overlay layout/logic and will adopt the kit; the site
engineer (branch site) will adopt it too: keep the kit self-contained and documented in `docs/ART-NOTES.md`.
Harness rules: runtime-only change, fake-engine tests, `npm test` green; verify `profile` with an avatar live on world
`live` (see docs/SETUP.md; never touch worlds a, b, c, n). Commit to eng/art with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; don't push or touch main. Stop by deadline.txt.
