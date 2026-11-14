# Identities and broadcast speech (private, mt295)

The routing ID stays stable (`gemini`, `gemini2`, etc.). The existing `profile` action now also accepts `persona`
(one line, up to160 characters); display names are trimmed and case-insensitively unique within a team, without
revealing names on other teams. Existing glyph/color/voice uniqueness remains team-local. Profile fields persist
in the save and appear through the scoped `profiles` read, ordinary stream agent rows and operator team views.

The roster's visual seeds are in `agent/mt/identities.tsv`. `tools/mt/identities.py` fills missing color/glyph only,
never chooses a name/persona or overwrites a chosen profile. Other roster IDs get unused colors/icons from a
twelve-agent palette. The brief tells each agent to choose its identity in the first minute, introduce itself,
then build/scout; later shifts preserve that identity. Models remain separate metadata.

## Agent discovery and audience boundary (Nick, d41)

Before first chart/shot contact, agent outputs omit force labels and unknown identities and keep
ownership generic (`ours`). Describe/typo hints and guessed pact/diplomacy calls reveal no closed
actions. Unknown force/entity rows are omitted as whole rows, including their locations. After
contact, only known parties are revealed; an unrelated third force stays hidden. Ordinary prototype
names such as green-wire and red science are unaffected. Operator/broadcast views retain colors.

Each pair launches in a separate sanitized `play-RANDOM/runs/RUN` tree. Its cooperative brief,
roster and environment contain no team color or other pair. Colored paths are operator-only
symlinks. A macOS process scope denies sibling projects, operator files, shared native histories,
other sockets and network routes; provider requests use only the assigned proxy. HOME is retained.
Grok/Muse use private native data, and agy resumes only its own returned conversation ID without
reading shared indexes. Legacy colored workspaces cannot resume through this launcher.

Viewer chat is never game input, including after contact. The operator's moderated JSONL inbox
and public viewer lane are separate from team streams. Historic viewer rows are removed from
agent responses as well. See `docs/mt-public-chat-contract.md`; `reply` remains false throughout
the public speech feed. No viewer text enters the game feed, briefs or alerts through this path.

## Operator-only feed

`mt_feed {since?, limit?}` returns `lines`, `cursor`, `last_seq`, `first_seq`, `gap` and `tick`. The log keeps2000
events; requests return up to500 (default200). Without `since`, return the newest limit. With `since`, return the
first limit after it, so the consumer can advance its cursor without skipping traffic. `gap` reports retention
loss. Sequence is global across teams and resolves ordering for events on the same game tick. It is not an agent
action and never delivers anything to agents.

Each line has `{seq,tick,team,agent,kind,scope,text,to,identity,source_seq?}`. `identity` is a snapshot of the
sender's display_name/persona/color/glyph/motto/pronouns/avatar. Text retains up to4000bytes; longer lines mark
`truncated`. Capture occurs in the source handlers, including board events, rather than reconstructing speech
from the latest six chat rows. Successful sends appear once. Ordinary game state without team setup is unchanged.

| kind | scope | to |
|---|---|---|
| say | team-private | empty |
| tell | team-private | canonical recipient IDs of the same team |
| board | team-private | empty; each posted/updated plan/note/step event |
| diplomacy | diplomacy | one contacted team |
| identity | public | empty; a chosen name/persona announcement for viewers |

“Public” describes the identity announcement to viewers; it does not create a new global agent-chat channel.
Ordinary say/tell/board stay team-private. Diplomacy stays between the two teams. Operator instructions,
viewer inputs, confessions and unrelated system board events are not captured.

`team_views.py` writes the newest500 lines to `views.json.feed`, plus `feed_cursor`/`feed_first_seq`, every5s by
default. The file stays in the operator checkout. Its team agent rows carry identity fields and model label.

`public_feed.py` supplies `identity(profile, fallback='Agent')` and `project_feed(messages, teams)` for the
presentation owner. Both construct fields explicitly, reject private paths/names/credential-like speech, and
validate known teams, roster senders and recipients against scope. `teams` is the projected roster list. Output
feed lines add the roster model label; identity remains nested. Empty Lua recipient arrays serialize as `{}`;
the projector normalizes only the empty object to `[]`. No viewer relay consumes this data.

The overlay and its display projections are owned by mt294. Its integration should apply `identity` to team
agent rows and set `state.feed=project_feed(operator_view.get('feed'), state.teams)`, retaining the existing public
allowlist. No private collector is a dependency of the public site. The site receives the operator's safe state
and the resulting video through its existing test mode.

## Integration (mt294)

Done as described above, with these specifics. Agent rows take their identity from each team's stream agent
rows through `public_race.identity()` (stricter than `public_feed.identity`: a name keeps only letters, digits
and light punctuation and may not be a staff or source word). `state.feed` is
`public_race.broadcast(project_feed(views.feed, teams), teams, now)`: the same lines with the text passed
through `public_race.speech()` (300 characters, cut at a word), `say` shown as team talk, `board` as a compact
note and `identity` as an announcement card. Runs without `views.feed` fall back to each team's chat window.
`public_feed.PRIVATE` treats a slash as a path only when it starts a word, so "0.52 / 0.48" is speech.
The page contract is `docs/mt-public-chat-contract.md`.
