# Public race conversations — mt289 cp3 / mt290 handoff

The audience sees all teams; game agents must consume only their team's own feed and the
separate moderated viewer relay. The public overlay/site projection is **not an agent inbox**.
No team conversation is flattened into viewer messages, news, or another team panel.

## Layout

The camera transform remains **(24,248,1280,720)**, so cp3 does not compete with the 2.1 camera
change. Three team panels at x=1328 show both roster agents, their activity, a minimap and the
last **two** conversation messages. Each message gets a sender/recipient heading, game time
and up to two text lines. Four-team/twelve-agent stress mode fits three activities and one
conversation message per panel. Long messages truncate within their panel.

The permanent viewer area is **(24,980,1280,88)**. It shows two recent site/YouTube messages,
source badges and available delivery receipts. An empty or connecting lane keeps its place.
The right footer shows two recent race events. No change to game polling or camera selection.

## Team conversation projection

`public_race.team_chat(team, state.chat, roster_names, private_names)` is called by
`public_overlay.project()` through `public_race.project()`. The six most recent eligible
messages stay exclusively under `teams[i].chat`, with this shape:

```json
{
  "team": "green",
  "name": "gemini2",
  "to": ["gemini"],
  "kind": "tell",
  "text": "I will feed the labs while you connect oil.",
  "tick": 184800,
  "t": null
}
```

Allowed inputs:

- Ordinary team speech: lane absent or `talk`, canonical roster sender, no `to` recipients.
- Main-stream tell: lane `tell` / `tell:true`, sender in the team's roster, nonempty recipients
  entirely in that roster or the literal `team`, and a safe **body**. The main stream emits
  the raw/summary body separately from `text` and `to_shown`, which contain presentation
  identities; only `body` is read. `pog-AGENT` aliases normalize to their roster names.

All present sender fields (`agent`, `from`, `name`) must agree. Explicit `team`/`force` tags
must agree with the parent team. Reject unknown/cross-team recipients as a whole, operator
requests, confessions, notices, viewer/source rows and sensitive-looking speech. Do not read
or forward arbitrary payloads, errors, quota, tokens, requests, display names or paths.
Existing board/site projection work is owned by mt290 and can remain beside this helper.

The renderer checks the team tag, sender and recipients again. Preserve the new team/kind/to
fields during the merge; cp2-style messages without them intentionally do not render. This
is a bounded public presentation format, not permission to feed these messages to other agents.

## Viewer producer compatibility

Cp3 was checked against mt290's `audience(states, teams, now)` interface as present in its
worktree on 2026-11-10. Keep mt290's audience aggregator and existing moderated site/YouTube
readers; cp3 does **not** replace them or start another relay.

```json
{
  "viewers": [
    {"id":"site:104", "name":"Viewer", "source":"site", "text":"Keep the labs fed!", "t":1794325000},
    {"name":"Viewer", "source":"youtube", "text":"Can Yellow catch up?", "t":1794325002}
  ],
  "viewer_status":"on",
  "viewer_delivery": {
    "104":{"s":"held", "teams":["green"], "t":1794325003}
  }
}
```

`on` renders the live viewer heading; `waiting` renders connecting. Site receipts are keyed
by the public numeric sequence, without `site:`. Only known team names count: the example
shows **1/3 SENT**. Three confirmed team receipts show **SENT → ALL**. No receipt means no
claim of delivery (including YouTube). `held` with no confirmed team is **QUEUED**. Never copy
private delivery explanations/errors. Moderated/deleted messages disappear when the producer
replaces the lane; the renderer keeps no message history of its own. Messages older than ten
minutes do not render. The producer's stricter 180s window remains valid.

An optional stricter helper, `project_viewers(messages, now, teams)`, accepts already-moderated
rows from only `site` and `youtube`, anonymizes authors, rejects team/tell/operator fields,
checks finite timestamps and exposes only text/source/time plus enum delivery and known
team targets. It preserves only numeric `site:N` IDs for the receipt map. It is an allowlist,
**not a moderation or relay replacement**. The renderer also accepts its optional per-message
`delivery:sent|held|not_relayed` / `targets:[team|all]` fields, but never invents a receipt.

## Merge ownership

Mt290 has already merged cp2 and owns the live audience/relay/roster/site work. Cp3 has no
changes to `public_stream.py`, roster files, Lua, site build or worker. Its one-line
`public_overlay.py` change adds `source:youtube` to the legacy reader's output so this
standalone branch still displays it; discard that hunk when retaining mt290's aggregator.
The likely merge overlap is `public_race.py`'s chat block and return dictionary: retain the
`team_chat()` call and its six tagged messages while retaining mt290's separate board field.
Keep `audience()` and its `viewer_delivery` / `viewer_read` state intact. Do not restore the
legacy standalone YouTube reader when resolving the merge.

The private cp3 branch is for mt290's merge. Public site code must stay independent of this
private module and consume only the operator-pushed public projection, with each team's
chat nested in that team's view. All relay/game-agent isolation tests remain mt290's scope.
