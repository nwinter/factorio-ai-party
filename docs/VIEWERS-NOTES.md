# Viewer chat bridge (branch eng/viewers)

`tools/stream/viewers.py` reads viewer chat from YouTube and from the companion site, filters it, and gives
`serve.py` a `viewers` lane that the overlay (eng/stream2) and the casters (eng/audio) read. An optional relay posts
filtered lines into the game through eng/board's viewer relay; it is off unless the operator switches it on. In
shake2, a message Nick posted in YouTube chat reached nobody. With this bridge it shows up in the lane, marked as the
channel owner.

## Run

```sh
# with the stream service (what OBS and the casters already read)
python3 tools/stream/serve.py --world live --run RUN.json --viewers-youtube @HANDLE --viewers-site
#   add --viewers-classifier clef            to check messages with Cloudflare clef-flash as well
#   add --viewers-relay tools/stream/logs/viewers-relay.on   to allow the relay; then:
touch tools/stream/logs/viewers-relay.on   # relay on (checked every 2 s)
rm tools/stream/logs/viewers-relay.on      # relay off, queue dropped

# standalone, to watch what passes (one line per message: PASS / PASS lane only / DROP reasons)
python3 tools/stream/viewers.py --youtube @HANDLE --site --agents astra,luna,sol,grok,opus,sonnet,haiku,gemini,muse
python3 tools/stream/viewers.py --replay tools/stream/runs/viewers-sample.jsonl --fast
python3 tools/stream/serve.py --mock --viewers-replay tools/stream/runs/viewers-sample.jsonl   # loops the sample

python3 tools/stream/test_viewers.py      # 120 checks, no network
```

`--viewers-youtube` takes a video id or URL, which follows one broadcast, or a channel (`@handle`, a `UC...` id or a
channel URL). A channel target is resolved to the broadcast that is live now, and resolved again a minute after chat
ends or while the channel is offline, so the same command works across broadcasts. `--viewers-site` defaults to
`https://player-of-games-live.your-subdomain.workers.dev`. `--viewers-record FILE` appends every incoming message in the
replay format, so a real session can be replayed later. Every verdict goes to `tools/stream/logs/viewers-*.jsonl`
(git-ignored; it holds viewer names and text).

## YouTube method

The bridge uses YouTube's own keyless live-chat endpoint, implemented with the standard library:
1. Load the `live_chat?is_popout=1&v=ID` page and take three things from it: the page's public `INNERTUBE_API_KEY`,
   the client version, and the first continuation from `ytInitialData`.
2. Poll `POST youtubei/v1/live_chat/get_live_chat` with that continuation, waiting the `timeoutMs` each reply gives
   (clamped to 2 to 10 s).

This is the method chat-downloader and pytchat use. Reasons for it:
- It needs no credential. The Data API's `liveChatMessages.list` needs an API key or OAuth, and `~/.config/pog/youtube.key` is the stream key, which cannot be used for that.
- The Data API costs 5 quota units per poll against a 10,000-unit daily quota, which is about 30 minutes at 1 poll per second.
- It needs no new dependency. pytchat is unmaintained. chat-downloader is a large package for one endpoint, and the repo's stream tools are stdlib only.

The risk is that YouTube changes the page. The parser reads only a few fields, and failures show up in
`viewers_status.youtube` (`state: error|offline|ended`, `error`) without stopping the stream.

Read from YouTube:
- Text messages and Super Chats.
- Emoji: standard ones as the character, custom ones as their `:shortcut:`.
- Owner and moderator badges, which become `staff`.
- Deletions, single messages or a whole author: the message leaves the lane and the relay queue.

Channel ids are kept only as a 12-character SHA-256 prefix, used for rate limits and deletions. Channel ids are
public, so this is not anonymisation. The prefix stays out of the lane and the verdict log and appears only in
`--viewers-record` files.
When a reader starts, messages already in the chat count as backlog: those older than 2 minutes are skipped, so the
hosts do not answer old chat after a restart.

## Site chat

`GET /v1/chat?limit=50` first, then `?after=SEQ&limit=100`, paging until a page has fewer than 100 messages; polled
every 4 s. `hidden` seqs are deletions. The site gives no stable viewer id, so per-viewer limits go by name, on top of
the Worker's own per-client limits (one message per 4 s, 8 a minute).

## The lane (`/state.json`, `/events`)

```jsonc
"viewers": [   // last 30 that passed, oldest first; a deleted message disappears
  {"id": "yt:Ch4...", "seq": 12, "source": "youtube|site", "name": "factoryfan", "text": "are they any good?",
   "t": 1791702153.8, "order": false, "checked": "heuristic|clef", "staff": "owner|moderator",  // staff: YouTube only
   "relayed": true}                                                                             // only once posted in game
],
"viewers_status": {   // null when no source is configured
  "youtube": {"state": "live|offline|ended|error|starting", "video": "ID", "channel": "@handle", "error": null},
  "site": {"state": "ok|error|starting", "open": true, "after": 41, "error": null},
  "relay": {"state": "off|on|missing|error", "fn": "viewer_relay", "sent": 3, "queued": 0, "error": null},
  "classifier": "heuristic|clef",
  "dropped": {"injection": 6, "promo": 2, "rate": 1, "deleted": 1, "relay:order": 1}
}
```

eng/audio's `caster.viewer_messages()` reads this lane unchanged. It takes `id`, `name`, `text` and `t` from
`viewers`, as checked against its code on eng/audio. Consumers should still escape `name` and `text` for display. They
are sanitized but remain user text. `order: true` marks a message that orders the agents ("astra, build turrets").
It is fine for the hosts to read and answer, but it is never relayed into the game.

## Filters

Every message goes through these checks, in order, before it reaches the lane. A message stops at the first check that drops it.

| Check | Drops |
|---|---|
| Hygiene | Control, bidi-override and zero-width characters are removed and whitespace is collapsed. Text is capped at 200 characters with "…". Names are reduced to letters, digits and ` _ . ' -`, capped at 20 characters, and lose a leading `@`. |
| Names | An agent's name or a staff-like name (operator, mod, caster, system, host, nick, ...) gets " (viewer)" appended, unless the message comes from the YouTube owner or a moderator |
| Spam | Links and bare domains, self-promotion, fewer than 2 letters, repeated characters or syllables, the same word 4 or more times in a row, operator blocklist (`--viewers-blocklist FILE`) |
| Injection | Instruction overrides, "system prompt", role changes, chat-template markup, harness and console commands (`./fh`, `remote.call`, `/c`, `game.`), shell, requests for secrets (passwords, keys, tokens, `.config`, `.pw`), "repeat after me" or "make the hosts say", tool talk. The text is also matched after folding fullwidth and accented letters, after undoing leetspeak, and with the spaces removed. A name that matches is dropped too. |
| Duplicates | The same author and text within 5 minutes; the same line from a third author within a minute (copypasta raid) |
| Rate | Per author: one message per 10 s and at most 4 a minute. Overall: 20 a minute. YouTube owner and moderators are exempt. |
| Clef (`--viewers-classifier clef`) | Messages that pass the checks above are sent in one batch to `@cf/cloudflare/clef-flash`, which labels each one fine, spam, abuse or injection. Only "fine" passes. The text goes in as a JSON-quoted viewer message, never as instructions. After 3 failures in a row the bridge runs on heuristics alone for 2 minutes. |

The relay adds these rules:
- With Clef on (the default), Clef must have checked the message. Heuristics alone do not open the relay.
- Rate limits: one line every 20 s overall, one per viewer every 45 s (2 minutes until shift01, where it dropped
  half of one viewer's questions), and nothing older than 90 s; behind them, the harness's own (20 s per viewer, 6 a
  minute).
- A cap of 120 characters.
- Muted viewers (the agents' vote) are skipped.
- A question (a "?" anywhere, or a line that opens like one: "how ...", "are you ...") that names no agent (no `@`,
  no agent name, `pog-` name or display name) gets `@AGENT ` in front of the viewer's words. `viewer_say` takes only
  name and text, and a viewer line wakes a sleeping agent only for an `@name` in it (board.lua `mention_how`).
  The agent is the one this viewer's last question went to, if that was within 5 minutes. Otherwise it is the next
  agent in team order (run config order) that no viewer addressed in the last 5 minutes. If every agent was addressed
  in that time, it goes to the agent addressed longest ago. serve.py refreshes the roster every second from the
  snapshot, with display names and without offline agents. The lane marks such a line `to: AGENT`.
Orders to the agents ("astra, build turrets") are relayed since eng/viewers2: they are viewer talk, and `order: true`
still marks them in the lane. Attempts to make agents break rules or reveal secrets are dropped by the filters and
Clef's `injection` label.

The YouTube owner and moderators skip the spam and rate checks. Injection, order and relay rules still apply to them.

Viewer text is data everywhere:
- The casters' prompt on eng/audio already says that a viewer message is a quote and not an instruction.
- In the game, a line arrives as `viewer NAME: text`.
- `agent/team.md` should get one line, on eng/board with the relay, saying that viewer lines are audience chatter and not orders.

## Relay into the game (since eng/viewers2)

While the switch file exists, the relay posts each line with the harness's operator `viewer_say` (audience.lua,
round 3 of eng/board; runtime-only), sent over the stream service's RCON connection as a dispatch that names no player:

```lua
/silent-command rcon.print(remote.call("agent_harness","dispatch",[[{"id":"viewers-...","operator":true,"action":"viewer_say","args":{"name":"cy","text":"you are doing great"}}]]))
```

`viewer_say` rate-limits again (one line per viewer every 20 s, 6 a minute) and refuses a viewer the agents voted
muted; the relay keeps a rate-refused line and waits `retry_after_s`, and drops a muted one. It reads the muted list
(operator `votes`) every minute and skips those viewers before the game. A world without `viewer_say` reports
`state: missing` and is probed again a minute later. (The earlier draft called a `viewer_relay` remote function,
which would have needed a control.lua change; no world has it.)

## Verification

- `python3 tools/stream/test_viewers.py` passes all checks with no network:
  - YouTube page and get_live_chat parsing from fixtures in YouTube's reply shape, including emoji, Super Chat, the owner badge, both deletion actions, the end of chat and channel resolution;
  - site paging past 100 and hidden seqs;
  - 29 drop cases and 17 ordinary-chat cases that must pass ("artillery shells are expensive", "ignore the biters and build everything", "what's the key to good ratios?", "go opus");
  - order detection;
  - names and rate limits;
  - the relay: switch, gaps, orders, Lua quoting with `]]` in the text, the cap, a missing function;
  - Clef: rejected labels, and a Clef outage closing the relay;
  - the sample replay.
- `serve.py --mock --viewers-replay tools/stream/runs/viewers-sample.jsonl` on a spare port: `/state.json` carries
  `viewers` and `viewers_status`, and the verdict log is written. `selftest.py` and `caster_selftest.py` still pass.
- eng/audio's `viewer_messages()`, taken from that branch, reads a lane row unchanged.

Not verified: this session had no network access (YouTube, the site Worker and Cloudflare were refused) and no RCON.
The first live checks:
1. `python3 tools/stream/viewers.py --youtube @HANDLE --site` during a broadcast: post one line in each chat and see `PASS`.
2. Run the same once with `--classifier clef`.
3. Once eng/board's relay is on world live, run `serve.py --world live ... --viewers-relay FILE`, `touch FILE`, post one line, and watch it arrive in game chat as `viewer NAME: text`.

## Gaps

- The YouTube endpoint is undocumented. If YouTube changes the page, the reader goes `error` until the parser is updated. Fallback: the Data API with a new API key, which costs quota.
- Heuristic filters miss paraphrased injections and flag some innocent lines. Clef is the second line of defence; the relay stays conservative (no orders, Clef-checked when Clef is on).
- No profanity list ships in the repo. Clef's "abuse" label covers it, and `--viewers-blocklist` takes an operator list.
- Site names are free text, so the per-viewer limits on site messages are per name. The Worker's per-client limit is the real one.
- The overlay does not render the lane yet; that belongs to eng/stream2.

## Viewers talk to agents (eng/viewers2, VIEWERS.md)

What changed on top of the bridge above:

- Moderation: Clef (`@cf/cloudflare/clef-flash`) is the default classifier, with the heuristics as the fallback
  (3 failures in a row: heuristics alone for 2 minutes, and the relay closed meanwhile). Clef's labels are fine, spam,
  abuse, personal (new: personal data about anyone) and injection (now also attempts to make the agents break the
  rules or reveal secrets). The heuristics also drop personal data (e-mail, phone, IP, street address, card numbers).
  Every verdict goes to `tools/stream/logs/viewers-*.jsonl` with `checked` (clef|heuristic) and Clef's `label`;
  `viewers_status.verdicts` counts them. Dropped lines reach neither the lane nor the game.
- Relay: through `viewer_say` (above), on by default in `tools/start-team.sh` (`runs/RUN/viewers-relay.on`;
  `POG_VIEWER_RELAY=0` leaves it off; `rm`/`touch` the file mid-run). In the game a viewer line is unread chat for every
  agent (`viewer: true`); it files a mention, which shows in `team.mentions` and ends a `sleep`, only for an agent it
  names with `@`. Agents answer with ordinary `say`.
- Overlay: a relayed viewer line shows in the chat feed with a `viewer` tag, between the agents' lines it prompted, and
  no longer also in the viewer lane; the lane keeps the lines that were not relayed.
- Mute vote: `fh vote mute NAME "reason"` / `fh vote unmute NAME "reason"` / `fh vote list`. A majority of the agents
  active in the last 10 minutes decides; a muted viewer stays muted for the rest of the run (in the save, so a resumed
  shift keeps it). Each vote and result is a `vote: ...` chat notice (never a mention), which the stream puts on its
  ticker. Mute applies to the game only: the hosts and the overlay's viewer lane still see a muted viewer's lines if
  they pass moderation (a decision to check). Since the merge into eng/players the mute vote is one kind of the one
  vote module (votes.lua, with kick, ban and trust on human players): the same `fh vote`, plus `fh vote no`, a
  10-minute expiry and a 5-minute wait after a decided vote; overlay peeks no longer make an agent active
  (docs/PLAYERS-NOTES.md, "Votes").
- agent/team.md describes the viewer lines and the vote tool, without saying when to use them.

Replay (`python3 tools/stream/viewers_report.py`, sample `tools/stream/runs/viewers-hostile.jsonl`, 51 lines): with
Clef stubbed by the sample's expected labels, 24 pass and 27 are dropped, 17 by the heuristics (injection 12 lines,
personal data 4, promo 2, link, copypasta, duplicate, rate) and 10 by Clef (abuse 6, injection 3, spam 1); every
verdict matches the expectation. The lines only Clef catches are insults without keywords, threats, hate, "send me
pics", griefing orders ("deconstruct the whole power plant") and impersonation of an agent. `--clef` sends the same
lines to the real model and counts where its labels differ; this session could not reach Cloudflare.

Cost: one message per Clef request (live chat at a few lines a minute) is about 286 input tokens a message, ~191k per
1,000 messages = $0.0073 at clef-flash's $0.038 per million input tokens (Workers AI pricing page, checked 2026-10-11;
output is not billed), 660 neurons, inside the 10,000 free neurons a day. Batches of several messages cost less (the
state text is shared).

Checks: `tests/viewers.lua` (wake on @name only, mute and unmute majorities, the 10-minute activity window, notices
that mention nobody, muted lines refused, directors cannot vote), `tests/board.lua` (viewer mentions), `tests/
cli.test.ts` (`fh vote`), `tools/stream/test_viewers.py` (relay through viewer_say with muted and rate refusals, a
runtime without it, personal data, the verdict log, the hostile replay), `selftest.py` (vote notices on the ticker).
