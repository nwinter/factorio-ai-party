# Team board, reply hints, harness requests: interface contract

Shared contract for branch `eng/board` (harness) and branch `eng/stream2` (overlay). Principle: the harness gives
agents honest primitives and the information a human player gets from the GUI; strategy (roles, defense, belts, lab
supply) stays theirs.

## Board (shared team memory in the game save)

- Item: `{id, kind, title, owner, requested_by, status, area?, needs?, tags?, notes[], created_tick, updated_tick}`.
  `kind`: `task` | `request` | `claim` | `note` | `harness`. `status`: `open` | `claimed` | `doing` | `done` |
  `blocked` | `dropped`. `owner`/`requested_by` are agent names (bot or player name), owner may be null only while
  `open`. `area` is `{left_top={x,y}, right_bottom={x,y}}` (claims). `notes` holds `{tick, by, text}` (last 10).
- Actions (any agent):
  - `board` (read): optional `mine` (owned or requested by me), `status`, `kind`, `since_tick`, `limit` (default 30,
    newest first) -> items plus `open_unowned` count.
  - `board_post`: `{kind, title (1..120), owner?, area?, needs?, tags?}`. A `request` must either name an `owner`
    or will be shown to everyone as unowned until someone claims it. A `claim` needs `area`, owner = poster.
  - `board_update`: `{id, status?, owner?, note?}`. Taking an open item = `owner` = me. Anyone may add a note; only
    owner or requester may change status (except taking an unowned open item).
- Bounds: at most 300 items kept (oldest `done`/`dropped` pruned first); titles/notes truncated, never fail.
- Every board change is also appended to an event log the overlay can read: read action `board_events`
  `{since_seq}` -> `{events:[{seq, tick, by, id, change, title}], cursor}`.
- The team plan (eng/research): one item `kind=plan` (`goals`, `lines` of `{agent, text, by, tick}`), edited with
  `board_plan {goals?, doing?, agent?}`; `board` reads return it as `plan {id, goals, doing[], edited}`, never as a row.
  Each edit is an event `{kind:"plan", change:"edited", text, owner: the agent whose line changed}`.
- A finished technology (research.lua) is an event with no item: `{by:"research", kind:"research", change:"done",
  title: technology, text:"unlocks: ..."}`.

## Reply hints (pushed to the agent on every reply, only when non-empty)

`team` block added to every dispatch reply for the requesting agent, describing what is new since its previous
request (per-agent cursor; never repeats an item once shown):
- `mentions`: unread chat messages that contain the agent's name or display name (count + latest one).
- `board`: items newly assigned to me, items I requested that changed status, open unowned requests older than
  2 game minutes (count + oldest title).
- `alerts`: attacks and losses since my last request: enemy damage to our entities (area, attacker, entities hit),
  entities destroyed, my character taking damage. Summarized (one line per incident), bounded.
- `research`: technologies the agent's force finished since its previous request, with what each unlocks (a first
  request looks back 10 game minutes).
- `reminders`: `profile` until the agent has set display_name/glyph/color once.

## Harness requests (agents asking for tools)

- Action `harness_request` `{title (1..120), problem, proposal?}` creates a board item `kind=harness`,
  `owner="operator"`. Operator tools read them (`tools/harness-requests.py`), an on-call engineer agent may implement,
  and the operator answers with `board_update` notes and a chat line `server: harness vN: ...`.
- Agents cannot change harness code themselves. Saved macros are allowed: `plan_save {name, steps}` (same schema as
  queue plans, per agent, up to 50) and `plan_run {name}` (submits it as a queue plan); `plans` lists them.

## Overlay (stream)

- Board panel: recent board events (posted / taken / done / blocked, with agent avatars), open unowned request count,
  and active claims; a "harness changelog" line when a `harness` item is done; the team plan's goals on one line, and
  research finished as a "Research finished: NAME" event.
- Alert banners driven by the same attack/loss incidents the agents receive.
