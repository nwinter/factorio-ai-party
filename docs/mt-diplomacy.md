# Pacts between teams (mt278 part I design; built in mt281 with the operator's defaults, Nick d29 12:30)

Private, mt branches only (tools/mt/launch-tree.sh leaves `docs/mt-*.md` out of the agents' tree). Sources: Nick's d29
10:20 brainstorm (multiteam-design.md), the scoring of d28 13:35 (solo edge x1.5, allied edge x1.0 each member,
alliance status fixed at departure, the home must hold until arrival), and the harness as it is on mt/batch278:
first contact (multiteam.lua `record`, the fact lines of mt276 G), progressive disclosure (disclosure.lua, batch317),
team-scoped stores (mt276 B).

## What a pact is
One record between two teams (forces), proposed by one, accepted by the other. Its terms are any of:
- **cease-fire**: the engine's `set_cease_fire` both ways while the pact holds. Turrets do not fire at the other team;
  it is not friendship (no shared chart, no access to its chests or vehicles).
- **shares**: how an allied edge's points are split between the two (e.g. 0.9 and 0.1). Read only by the scoring.
- **depot**: a border trade depot at an agreed spot; items put into one team's chest arrive in the other's, less a
  deadweight cut (default 20%).
- **obligations**: promises the harness watches and reports as facts to both teams, without enforcing them (deliver N
  of an item per hour through the depot; keep no building within R of a point; no hit on a named third team).

Vassalage has no name of its own: a 0.9/0.1 share with the small team's deliveries as an obligation is one.
Science donation is science packs sent through the depot (the receiver's labs use them); no other research transfer.

A team can hold several pacts (one per other team). Teams of three AI agents (and the human team, mt278 H) act the
same way: any agent of a team can propose, accept or end for it, and every agent of both teams sees the facts.

## Unlock: at first contact
- The pact actions are shut for a team until its first contact with another team (multiteam.lua's `record`: a chart of
  the other's entity or a hit). Progressive disclosure has the means: an atom `contact` set for both teams by
  `record` (`disclosure.mark(force, 'contact')`), and the pact actions' units opening on it. In a run without
  disclosure filtering, the actions refuse with a fact until contact: "no contact with another team yet".
- A team can propose only to a team it has had contact with (a recorded contact either way).
- The rules-of-contact message (mt_rules, sent when the operator chooses) names the pact tools and the scoring, so
  a team learns what a pact is worth; before it, a team that finds `pact_propose` open sees only its description.

## Data (state().mt.pacts; team-independent, beside multiteam's contacts)
```
pacts = {next = 7, by_id = {
  [3] = {id = 3, a = 'red', b = 'blue', status = 'active',      -- proposed | active | declined | withdrawn | expired | ended
         terms = {cease_fire = true, shares = {red = 0.9, blue = 0.1},
                  depot = {surface = 'nauvis', x = 12.5, y = -340.5, cut = 0.2, a_chest = UNIT, b_chest = UNIT},
                  obligations = {{id = 1, who = 'blue', kind = 'deliver', item = 'iron-plate', count = 600, per_h = 1},
                                 {id = 2, who = 'red',  kind = 'keep_out', surface = 'nauvis', x = 0, y = 0, r = 200}}},
         proposed_by = {team = 'red', agent = 'astra', tick = 1200000}, accepted_by = {team = 'blue', agent = 'haiku', tick = 1210000},
         expires_tick = 1236000,                                   -- a proposal not accepted by then lapses
         ended = {team = 'blue', agent = 'haiku', tick = 2000000, note = '...'},
         ledger = {sent = {red = {...}, blue = {...}}, cut = {...}, by_hour = {...}},   -- the depot's moves, item counts
         checks = {[1] = {last_h = 420, due = 600, tick = ...}}}}}  -- obligations as last measured
```
The engine's cease-fire settings before a pact are kept on it (`prev`), and put back when the last pact that set them
ends (two pacts between the same pair are not allowed: a new one replaces the old by agreement, pact_amend below).

## Actions (agents; shut until contact)
- `pact_propose {with, terms, note?, expires_min=60}`: a proposal to the other team. The note (500 bytes) travels with
  it. It reaches every agent of the other team as a fact line ("red proposes pact #3: cease-fire; shares red 0.9, blue
  0.1; a depot at (12,-340), cut 20%; blue delivers 600 iron-plate an hour; expires in 60 min. Note: ...").
- `pact_accept {id}` and `pact_decline {id, note?}`: the other team's answer. Accepting makes the terms take effect at
  once: the cease-fire set both ways, the depot's two chests placed (one per team, side by side, indestructible,
  marked on both teams' maps), the obligations' checks started.
- `pact_withdraw {id}`: the proposer takes back an open proposal.
- `pact_amend {id, terms, note?}`: a new proposal that replaces pact #id when accepted (#id stays in force until then).
- `pact_end {id, note?}`: either team ends it, at once, alone. The other team gets the fact at once ("blue ended pact
  #3 at tick ..."), the cease-fire goes back to war both ways, the depot's chests stop moving items (what is in each
  chest stays its owner's), obligations stop being checked. A betrayal is a `pact_end` (or simply a broken
  obligation); there is no enforcement beyond the engine cease-fire.
- `pacts {}`: the team's pacts and open proposals, with the depot ledger and the obligations' last measurements.

Arguments are checked (team names a contacted team; shares sum to 1 between exactly the two teams; a depot spot on a
surface both teams have, on dry ground, within no other team's buildings; obligations of the three kinds only).

## What the agents see
- The team block of `status`: one line per active pact and per open proposal ("pact #3 with blue: cease-fire; shares
  red 0.9 / blue 0.1; depot (12,-340): sent 1200 iron-plate, got 960 copper-plate this hour, cut 20%; blue's 600
  iron-plate an hour: 420 in the last hour").
- Fact lines (board.deliver, the team's own box) when a proposal comes, is accepted, declined, withdrawn or lapses,
  when a pact ends, and when an obligation's hour closes short ("blue's delivery: 420 of 600 iron-plate in the hour
  to tick ..."). Facts only: no advice, no judgement of the other team.
- Nothing about pacts between other pairs of teams: a team learns of those only from what its own partners say.

## The depot
- Two containers (steel chests, 48 slots), one per team, adjacent, placed by the harness at the agreed spot, each
  indestructible and in its owner's force. Every 600 ticks the harness moves the contents of each chest to the other,
  less the cut: per item stack, `floor(count x (1 - cut))` arrives and the rest is removed (deterministic, no
  randomness). Quality and spoilage are kept (spoil percent carried; Gleba items spoil as usual).
- Science packs go the same way: donation is a delivery of packs.
- A full receiving chest: what does not fit waits in the sender's chest for the next move (nothing is lost but the
  cut).
- The ledger counts items sent, received and cut per team per hour of game time (the obligations read it).

## Scoring (how the operator's scoring reads it)
- The alliance status that counts is the one when a team's edge-run platform leaves its last planet (d27 10:45 rule).
  The harness records a snapshot of that team's active pacts at that departure (a `departure` record on the platform's
  first move away from the last planet past a set distance; the platform watch already sees routes).
- An allied edge: the platform's team and every team holding an active pact with cease-fire and shares with it at
  the snapshot score; the allied total is 1.0 x the number of those teams, split by the shares (no shares: even).
  The cap (mt281, setting `share_cap_score`, default 1.5): no team's allied score above the solo edge's 1.5; what the
  cap takes off goes to the other members by their shares. A 0.9/0.1 pact of two: 1.8 and 0.2 before the cap, 1.5
  and 0.5 after it. A 0.5/0.5 pact: 1.0 and 1.0. So allying never pays a leader more than going alone, and a share
  moves points to the smaller team only up to the cap.
- The home-must-hold rule is unchanged (the team's Nauvis landing pad, powered, when its platform arrives).
- A mid-run milestone ranking (if Nick adds one): pacts do not change it.

## Interactions
- Freeze (mt278 H): a frozen team's pacts stay; its depot does not move items while it is frozen (its players cannot
  act, so an obligation to deliver is reported as "frozen" rather than short).
- The human team: the same actions, through chat commands (`!pact ...`) or an operator relay, since humans have no
  fh; to build with the rest if Nick wants humans in pacts.
- Contact detection, the census and the team views read pacts (the team page lists them).

## Cost
- Pacts are few (at most 6 pairs for 4 teams, 10 for 5). Per 600 ticks: each depot's two chests read and written
  (about 0.1-0.3 ms for 48 slots each), each obligation checked: `deliver` from the ledger (no game read), `keep_out`
  one count_entities_filtered in its circle (memory: counts are cheaper than finds; a 200-tile circle about 0.1-0.5
  ms), `no_attack` from the damage hook multiteam already has (a per-pair last-hit tick). Under 0.01 ms a tick on
  average; nothing in the 10 ms range.
- Storage: a pact is under 2 KB with its hourly ledger kept for 24 h.

## Built (mt281): the operator's defaults, each a setting in mt_pacts' config
- Terms: cease-fire, shares, depot, the three obligation kinds; no shared chart.
- Shares: the allied total 1.0 x the members, split by shares, capped at share_cap_score (1.5).
- Depot: cut 0.2, a move every move_s (10 s). Four chests, harness-placed, indestructible and not minable: each team
  has a sending chest and a receiving chest of its own force (a team opens only its own), A-send, A-receive,
  B-receive, B-send in a row at the agreed spot, tagged on each team's map.
- pact_end: ended at once in the record, both teams told; the engine cease-fire lifts end_notice_s (600 s) later, and
  the fact line says when.
- The human team: the same terms through chat, `!pact ACTION {json}` (propose, accept, decline, withdraw, amend, end,
  list); the reply in its console.
- Unlock: at first contact (the pact actions out of describe and refused until then; a `new:` fact line at the
  contact; disclosure's atom event:contact for a filtered run), explained by the rules-of-contact message.
- Obligations are measured each check_s (3600 s): a delivery counts what arrived at the other team.
- Proposals lapse after expires_min (60).

## The questions the operator decided (d29 12:40)
1. The terms: cease-fire, shares, depot, the three obligation kinds. Others to add (shared chart between allies via
   `set_friend`? passage only?).
2. Shares and scoring: the allied total of 1.0 per member split by shares, and whether to cap a share.
3. The depot's cut (20%), its move period (10 s), and whether either team may move or empty it.
4. Whether `pact_end` acts at once (as now) or after a notice period (e.g. 10 min, which turns a surprise attack
   into an announced one).
5. Whether the human team joins pacts (and how: chat commands or the operator).
6. The unlock: at first contact (as here), or only after the rules-of-contact message.
