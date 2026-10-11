# Engineer task: stream audio, AI shoutcasters, voiced chat (branch eng/audio)

The stream (OBS on the Windows box, scene `stream`, see docs/STREAM-NOTES.md and docs/SETUP.md) has no audio. Build:
1. Game audio: unmute only the main director client (`factorio-cam1.exe`) and capture it with an OBS Application Audio
   Capture source (`wasapi_process_output_capture`) in the stream scene, at a sensible level. Game music off (the
   soundtrack may trigger copyright claims); leave a slot for an original music bed later.
2. Two AI shoutcasters (play-by-play and colour commentary) as a Mac-side service (`tools/stream/caster.py`) that
   consumes the stream service's state/SSE feed (events, research, board, chat, alerts, camera target), writes short,
   lively, varied lines with a fast cheap model (pick one we can use: e.g. `claude -p --model haiku` on the personal
   Claude subscription, or Cloudflare Workers AI text models; measure latency and cost), and speaks them with TTS
   (evaluate Cloudflare Workers AI TTS models on the existing wrangler login, account "the owner's Cloudflare account";
   check docs for current model ids and pricing). Rate-limit (talk on events, at most ~1 line per 20-40 s, no talking
   over each other), never invent facts not in the feed, and keep it fun like a good esports cast.
3. Voiced agent chat: agents' `say` messages can be voiced in a per-agent voice (agents may pick a voice from a list
   via `profile.voice`; default deterministic by name). Only voice lines worth hearing: messages the agent marks
   `aloud: true` (the board engineer adds this flag) or that a classifier judges as banter/strategy/emotion rather
   than logistics; Cloudflare Clef (`@cf/cloudflare/clef-flash`, see docs/clef-sample-request.json) is a good fit for
   that classification. Casters duck under agent voice; game audio ducks under both.
4. Playback path: the overlay page (OBS browser source) plays queued audio clips the service pushes (enable "Control
   audio via OBS" on the source), so OBS mixes everything.
Test with mock events (`tools/stream/serve.py --mock`) and a short OBS recording you start and stop yourself in a
scratch scene (do not touch the `pog` profile's output settings, do not start the YouTube stream). Budget: under $5
of API spend for development. Use WebFetch/WebSearch for docs. Document in `docs/AUDIO-NOTES.md` (how to run, voices,
costs per hour, knobs). Commit to eng/audio with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; don't
push or touch main. Stop by deadline.txt.
