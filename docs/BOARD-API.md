# Team board, reply hints, harness requests: interface contract

Shared contract for branch `eng/board` (harness) and branch `eng/stream2` (overlay). Principle: the harness gives
agents honest primitives and the information a human player gets from the GUI; strategy (roles, defense, belts, lab
supply) stays theirs.

## Board (shared team memory in the game save)

- Item: `{id, kind, title, owner, requested_by, status, area?, needs?, tags?, notes[], created_tick, updated_tick}`.
  `kind`: `task` | `request` | `claim` | `note` | `harness` | `project` (below). `status`: `open` | `claimed` | `doing` | `done` |
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
- Projects (eng/projects): items `kind=project` for long jobs that outlive an agent's context and shift, with `goal`,
  `steps` (`{n, text, by, tick, done_by?, done_tick?}`; `n` stays with its step), `areas` (up to 8), `handoff`, notes
  (last 20) and an owner or none. `board_post {kind:"project", title, owner?, goal?, steps?, area?, areas?, handoff?}`;
  `board_update {id, step?, done?, undone?, remove_step?, goal?, handoff?, areas?}`: anyone adds steps and marks them
  done or not; the step's adder or the owner removes one; the owner edits goal, handoff and areas, and anyone may when
  there is no owner or the owner has made no request for 30 min (who may then take it). Reads give `progress` ("3 of 7
  steps"), the steps as `[x] 1. text (done by NAME, <age> ago)` / `[ ] 2. text` (a list row: `next_steps`), and an
  agent's plain `board` read gives `projects`, one line per open project, instead of rows. Open projects are never
  pruned (at most 30 open). Events: `change` `step_added`, `step_done`, `step_undone`, `step_removed`, `goal`,
  `handoff`, `areas` with `text`; every project event has `progress`, `steps_done`, `steps_total`.

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
- `shift` (the first reply of a shift): the plan's goals and the agent's line, `projects` (the open projects' lines),
  research since its last shift, researched with none built, networks, the previous shift's retro.

## Harness requests (agents asking for tools)

- Action `harness_request` `{title (1..120), problem, proposal?}` creates a board item `kind=harness`,
  `owner="operator"`. Operator tools read them (`tools/harness-requests.py`), an on-call engineer agent may implement,
  and the operator answers with `board_update` notes and a chat line `server: harness vN: ...`.
- Agents cannot change harness code themselves. Saved macros are allowed: `plan_save {name, steps}` (same schema as
  queue plans, per agent, up to 50) and `plan_run {name}` (submits it as a queue plan); `plans` lists them.

## Overlay (stream)

- Board panel: recent board events (posted / taken / done / blocked, with agent avatars), open unowned request count,
  and active claims; a "harness changelog" line when a `harness` item is done; the team plan's goals on one line, and
  research finished as a "Research finished: NAME" event. Projects: a `step_done` is a "finished a step of" row with
  the project's progress bar (other step changes, goal, handoff and areas are not rows), and the bottom row shows the
  open projects with their progress, taking turns with the claims (tools/stream/live.py reads
  `{kind:"project", status:"active"}` apart, so long-lived projects stay in view).
- Alert banners driven by the same attack/loss incidents the agents receive.
