# Engineer task: better voices, agent-chosen voices, pronunciation (branch eng/voices)

The stream speaks two kinds of lines (docs/AUDIO-NOTES.md): the casters' lines and agents' chat lines marked `aloud`
or classified as talk. Today both use Cloudflare Workers AI Aura-2 voices, and Nick finds them flat. Budget: up to a
couple dozen dollars a day of TTS. Another engineer (eng/audio) is rewriting the casters themselves in `caster.py`;
you own `tools/stream/voices.py` (the TTS layer) and the voice catalog. Coordinate through docs/AUDIO-NOTES.md.

Do:

1. Provider adapters behind the existing `TTS.speak(text, voice, caster=None)` interface: ElevenLabs (an expressive
   model and a low-latency one), OpenAI's steerable TTS, and one or two others you judge competitive in Oct 2026
   (Cartesia, Hume, Google, Inworld...). Keys, when Nick provides them, are files in `~/.config/pog/` (for example
   `elevenlabs.key`, `openai.key`); never print, log or commit a key. Without a key an adapter is skipped, not fatal.
2. A bench: the same 20 lines (caster banter, an excited agent line, a frustrated one, a deadpan one) through every
   available provider and voice, with latency, cost per hour at our measured volume (docs/AUDIO-NOTES.md "Costs per
   hour", and expect more talk now), and the audio files in a folder Nick can listen to. Recommend a default per role.
3. Voice catalog the agents choose from: each entry with an id and a short description (timbre, age, accent, energy;
   let the description say how it sounds rather than labelling a gender) generated into the agent docs so an agent
   picks with `profile {"voice": id}`. If a provider supports designing a voice from a text description (ElevenLabs
   voice design), support `profile {"voice_description": "..."}`: generate once, cache the resulting voice id per agent.
   The harness `profile` already stores `voice`; ask eng/board (via notes) for `voice_description` if you need it.
4. Pronunciation: `voices.pronounce()` (on main) rewrites names before synthesis (Sol is said "Soul"). Move it to a
   lexicon file, add the agents' and casters' names and common Factorio terms TTS gets wrong, and use provider
   pronunciation dictionaries or phoneme tags where they exist. Captions keep the written text.
5. Loudness normalisation and caching stay as they are (every clip to the same LUFS).

Rules: commit to eng/voices in small commits ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
do not push or touch main. Do not play audio on this Mac's speakers; write files. Keep total test spend under $15 and
report it. Write results in docs/AUDIO-NOTES.md (a "Voices round 2" section). Stop by the deadline in deadline.txt.
