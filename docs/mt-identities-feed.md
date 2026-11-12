# Identities and broadcast speech (private, mt295)

The routing ID stays stable (`gemini`, `gemini2`, etc.). The existing `profile` action now also accepts `persona`
(one line, up to160 characters); display names are trimmed and case-insensitively unique within a team, without
revealing names on other teams. Existing glyph/color/voice uniqueness remains team-local. Profile fields persist
in the save and appear through the scoped `profiles` read, ordinary stream agent rows and operator team views.

The roster's visual seeds are in `agent/mt/identities.tsv`. `tools/mt/identities.py` fills missing color/glyph only,
never chooses a name/persona or overwrites a chosen profile. Other roster IDs get unused colors/icons from a
twelve-agent palette. The brief tells each agent to choose its identity in the first minute, introduce itself,
then build/scout; later shifts preserve that identity. Models remain separate metadata.

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
