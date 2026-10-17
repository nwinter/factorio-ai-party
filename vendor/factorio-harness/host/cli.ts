#!/usr/bin/env node
import { readFile, writeFile, cp, mkdir } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';
import { createHash, randomUUID } from 'node:crypto';
import { RconClient, RconOutcomeUnknown, RconUnavailable } from './rcon.js';
import { loadPace, savePace, seeTick, seeDown, slowNote, rolledBack, Pacer, overtime, slowGame, speedText, STALL_MS, type PaceState } from './pace.js';
import { Harness, retryBudgetMs, type Reply } from './harness.js';
import { renderMap } from './view.js';
import { parseLook } from './look.js';
import { writeFileSync, readFileSync, rmSync, appendFileSync, existsSync, renameSync } from 'node:fs';
import { formatCompact, finalLine, actionHelp, paginate } from './format.js';
import { parseDeadline, deadlineText, timeLeftText } from './deadline.js';
import { lookaheadDue } from './lookahead.js';
import { pollNews } from './polls.js';
import { trimRepeats, type ShownState } from './repeats.js';
import { bundleRuntime } from './bundle.js';
import { startSession, stopSession, sessionConnection, connectSession, type SessionConnection } from './session.js';
import { BridgeClient, BridgeOutcomeUnknown } from './bridge.js';
import { BrokerTransport } from './broker.js';
import { refDir, topicText, topicsLine, commandTopics, addReference } from './reference.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const modPath = resolve(root, 'mod/agent-harness_0.1.0');
const help = `fh — Factorio agent CLI

  fh start [--name default] [--space-age]     Start a private server and a graphical client
       [--save world.zip] [--niri]           --niri: client in an unfocused nested Niri window (default: FH_NIRI=1)
  fh start --headless                        Start only the private server
  fh start --bridge                          Vanilla private server played through the client bridge
  fh connect --server HOST:PORT [--name mp]  Join someone else's server with a bridged client
       [--password-file F] [--player-data player-data.json] [--mods DIR] [--space-age] [--niri]
  fh stop-session [NAME]                     Save and stop only this harness session
  fh install --mods /path/to/Factorio/mods   Install bootstrap (one initial game load)
  fh doctor                                 Check connection and available actions
  fh describe                               Discover action arguments from the runtime
  fh help ACTION                            One action's arguments, about 1 KB (also fh call ACTION --help)
  fh help TOPIC                             A reference topic of the workspace's ref/ (FH_REF_DIR); fh help lists them
  fh more                                   The next page of the last long reply (replies over ~10 KB come in 8 KB pages)
  fh observe [--args '{"radius":24}']        Bounded local world state
  fh call ACTION [--args JSON] [--id ID]      Execute an action; keep ID on uncertain outcomes
  fh call walk --args '{"direction":"east","ticks":60}' --wait
  fh wait [--max S]                         Block until the character's current action (and combat) ends, at most S s (at once when
                                            idle; --until idle is the same); a tell or a teammate's mention ends the wait early,
                                            except over a walking or loading tour (collect, transfer, load_silo, feed, rearm, ...)
                                            (exit 3: it still runs; --wait-through-tells keeps waiting)
  fh wait --until tell|alert|COND [--max S] One blocking wait, one line out: ends on a tell or a teammate's mention, a new alert (alert),
                                            a sleep condition (researched [TECH], item_count ITEM>=N, rocket_ready X,Y, ...), or after S s (default 600, up to 900);
                                            your action and queue keep going; the team block waits for your next reply
  fh sleep SECONDS [--until COND]           Wait up to 900 s (never past the deadline) while your action and queue keep going;
                                            wakes on damage, death, a teammate's mention, a tell, board news, your queue finishing or
                                            stalling, or COND: researched [TECH] | crafting_done | item_count ITEM>=N [at X,Y X,Y] | rocket_ready X,Y (a silo)
                                            | rocket_parts>=N at X,Y (the rocket being built at that silo has N parts; silo_parts too)
                                            | queue_done (your queue finishes or stalls; at once when none runs)
  fh sleep|wait ... --then ACTION [JSON]    When the sleep ends, one read (inspect, observe, status, silo, trace, ...) and its reply
                                            with the wake (not when a newer sleep replaced it)
  fh view --out artifacts/map.png            Render a local schematic PNG, also works headless
  fh deploy [--file runtime.lua]             Validate and replace live Lua runtime
  fh watch [--file runtime.lua]              Deploy changed Lua; retain old code on invalid update
  fh blueprint import --file blueprint.txt   Import blueprint/book into a named slot
  fh blueprint export --out blueprint.txt    Export stored blueprint/book
  fh blueprint list|inspect|capture|place|copy|cut|paste --args JSON
  fh blueprint save|rename|delete --args JSON The team library: save {name, area|positions}, place {name, position}
  fh queue submit --file plan.json           Queue in-game execution; optional --args for mode
  fh queue status|edit|cancel|resume          Inspect/revise pending work; cancel controls immediately
  fh board [--args '{"mine":true}']          Team board (tasks, requests, claims, notes, projects), newest first
  fh board projects [--args '{"id":N}']      Open projects: progress, next steps, handoff (an id: one in full)
  fh board post|update|events|request --args JSON   board_post, board_update, board_events, harness_request
  fh board plan [goals "text"|doing "text"|for NAME "text"]
                                            The team plan: goals and one line per agent ("" or - for stdin as for say)
  fh research [done]                        Research queue in full (progress, who queued, time to finish); done: what finished lately
  fh plan save NAME --file plan.json         Save a queue plan by name (yours, up to 50); plan run NAME submits it
  fh plan run|show|delete NAME, fh plan list Run (--args '{"mode":"replace"}'), inspect or delete saved plans
  fh say "text" [--aloud]                   Post in chat; or --text-file F, or stdin (fh say - <<'EOF' ... EOF)
       [--look platform:NAME|agent:NAME|X,Y[@SURFACE]|X1,Y1,X2,Y2[@SURFACE]]  what the stream camera might show
  fh chat [--since SEQ] [--limit N] [--peek] Your unread messages (newest N; remaining=K are still unread), or all after SEQ
  fh confess "text"                         A line for the stream audience only (teammates never see it); input as for say
  fh chronicle "text" [--title T]           An entry in the run's chronicle in your own words (the pog site, by shift); input as for say
  fh operator "text"                        A request to the operator (harness bugs, tools, viewer asks); input as for say
  fh tell NAME[,NAME]|team "text"           A line to teammates outside chat: their next reply's team block, wakes them; input as for say
                                            --fyi: no answer needed; it waits for their next reply and wakes nobody
                                            --wake: also ends their wait that ignores messages or takes tells only from others, every time
  fh tells [--since SEQ] [--limit N]        The last 30 tells you received (time, sender, fyi), shown before or not;
                                            --since SEQ: the ones you sent or received after SEQ
  fh players [NAME] [--args '{"minutes":10}'] Human players on the map: where, group, what each built, removed, ordered, moved
  fh platform [NAME]                        One space platform (the platforms read): hub free slots, cargo, speed, next stop,
                                            ETA; without NAME every platform
  fh vote [no] mute|unmute|kick|ban|trust NAME "reason"
                                            Vote on a stream viewer (mute, unmute) or a human player (kick, ban, trust);
                                            a majority of the agents active in the last 10 minutes carries it; reason - reads stdin
  fh vote list (or fh votes)                Muted viewers, open and recent votes
  fh restore PLAYER [--args '{"minutes":30}'] Cancel the player's pending orders; ghosts of what they removed (built with real items)
  fh stream                                 JSON-lines requests in, replies out; one connection
  fh run --file plan.json                    Sequential actions, waits after each timed action

Options: --player N (default 1), --bot NAME (a bot instead of a player; FH_BOT), --host HOST, --port N, --timeout MS (default 5000; deploy/watch 60000),
         --session NAME (default: auto-use default session), --bridge-socket PATH (bridge without a session),
         --socket PATH (an RCON broker's socket instead of RCON: harness requests only, no password; FH_SOCKET),
         --wait, --wait-timeout MS (default: until the action's own end tick, at least 30000), --journal PATH, --args-file PATH
         --wake-on-tells (fh sleep --until on platform arrivals or departures only: tells end it too; by default such a sleep goes on through them)
         --wait-through-tells (a tell or mention does not end the wait; told_during_wait lists them at the end; fh sleep, fh wait --until
                               and direct waits: wake_on_messages false, so only a tell sent with --wake ends them)
         --wake-on-viewers (fh sleep, fh wait, --wait: a viewer's @mention ends it too; by default it waits for your next reply)
         --wake-from NAMES (fh sleep, fh wait, --wait: only a tell or mention from these comma-separated teammates, or operator, ends it)
         --no-operator-wake (the same waits: operator tells and reminder jobs do not end it; teammates' tells do)
         --no-urgent (fh sleep, fh wait --until, direct wait_ticks/wait_until: an urgent alert does not end it; by default it does)
         --urgent-radius N (the same waits: attacks, enemy groups, losses and teammates' deaths wake it only within N tiles of you, 1..200; default 40)
         --wake-on-orders (fh sleep, fh wait --until: a standing order's round finishing or stalling ends it; by default only your own plan's does)
         --operator-repeat (FH_OPERATOR_REPEAT=1: print an operator message on every reply that carries it; by default once)
         Exit codes: 0 done, 1 failed, 3 the wait ended while the action still runs (a tell or mention, or the wait timeout)
         --full (after --wait: the whole status instead of outcome, position and inventory change)
         --since SEQ (chat, board events), --limit N, --deadline-file PATH (FH_DEADLINE_FILE: time left on the clock line)
         --format json|compact (default compact; stream always uses JSONL)
Failures exit nonzero and end with an error: line; partial results (short, awaiting_craft, not done) end with a warning: line.
Credentials: FACTORIO_RCON_PASSWORD or FACTORIO_RCON_PASSWORD_FILE
Endpoint: FACTORIO_RCON_HOST (127.0.0.1), FACTORIO_RCON_PORT (27015)
Stream input: {"action":"observe","args":{},"id":"optional-stable-id"}
Plan input: [{"action":"walk","args":{"direction":"east","ticks":60}}, ...]
Bridge sessions (start --bridge, connect) act only through normal player input; deploy/watch/view need the harness mod.
No automatic replay of mutations. stdout uses compact labelled tables; --format json is for programs. Diagnostics go to stderr.
`;
/** A via walk's legs, one line each: `(10,100) arrived 1.9s`, `(20,112) unreachable 0.2s: why`, `(32,104) not walked`. */
function legLines(legs: unknown): string[] | undefined {
  if (!Array.isArray(legs)) return undefined;
  return legs.map((leg: any) => {
    let line = `${leg?.to ? `(${leg.to.x},${leg.to.y})` : '?'} ${leg?.outcome ?? '?'}${typeof leg?.s === 'number' ? ` ${leg.s}s` : ''}`;
    if (leg?.why) line += `: ${leg.why}`;
    if (Array.isArray(leg?.avoided_enemies) && leg.avoided_enemies.length > 0) line += `; around ${leg.avoided_enemies.join(', ')}`;
    return line;
  });
}
function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a JSON object`);
  return value as Record<string, unknown>;
}
/**
 * `fh sleep --until`: a wait_until condition as JSON, or as words:
 * `researched [TECH]`, `crafting_done`, `item_count ITEM>=N|ITEM<N [at X,Y X,Y ...]`, `rocket_ready X,Y` (the silo),
 * or any condition name followed by key=value pairs (`ammo_below count=5`).
 */
function parseUntil(text: string): Record<string, unknown> {
  const trimmed = text.trim();
  // Several conditions, whichever holds first (Muse, 21:20: the first of two or three chests to fill; Grok: `alert|
  // platform_arrived NAME`): joined by |, or a JSON list.
  if (trimmed.startsWith('[')) {
    const list = JSON.parse(trimmed);
    if (!Array.isArray(list) || list.length === 0) throw new Error('--until as a JSON list takes wait_until conditions: [{"until":...}, ...]');
    return {until:'any', conditions:list.map(item => object(item,'--until'))};
  }
  if (trimmed.startsWith('{')) return object(JSON.parse(trimmed),'--until');
  const alternatives = splitAlternatives(trimmed);
  if (alternatives.length > 1) return {until:'any', conditions:alternatives.map(part => parseUntil(part))};
  const [kind = '', ...rest] = trimmed.split(/\s+/);
  const usage = '--until takes researched [TECH], crafting_done, alert [KIND ...], item_count ITEM>=N|ITEM<N|ITEM below N [at X,Y X,Y], rocket_ready X,Y, rocket_parts>=N at X,Y (silo_parts too; no count: every part), queue_done (fh sleep and fh wait only), produced [ITEM]>=N at X,Y [X,Y ...] (or ITEM>=N on PLATFORM), platform_arrived PLATFORM [PLANET], platform_left PLATFORM [PLANET], platform PLATFORM at|left PLANET, or a wait_until condition as JSON; several joined by | (or a JSON list) wake on whichever holds first';
  if (kind === 'researched' || kind === 'research') {
    if (rest.length > 1) throw new Error(usage);
    return rest[0] ? {until:'researched', technology:rest[0]} : {until:'researched'};
  }
  if (kind === 'crafting_done' || kind === 'crafted') return {until:'crafting_done'};
  // `platform Wren at vulcanus` (Sonnet 18:20): its arrival there; `platform Wren left gleba` (or leaves): its departure.
  if (kind === 'platform' || kind === 'ship') {
    const m = trimmed.slice(kind.length).trim().match(/^(?:"([^"]+)"|'([^']+)'|(\S+))\s+(at|in|over|left|leaves|leaving|from)\s+(\S+)$/);
    if (!m) throw new Error(`--until ${kind} takes a platform name (quoted if it has spaces), at or left, and a planet: ${kind} Wren at vulcanus`);
    const platform = m[1] ?? m[2] ?? m[3];
    return {until:['left','leaves','leaving','from'].includes(m[4]!) ? 'platform_left' : 'platform_arrived', platform, location:m[5]};
  }
  // alert: a new attack, enemy group or enemy base alert; with kinds (Luna, 19:50), a new or grown alert group of
  // those kinds addressed to you (low_power, no_power, no_fuel, ...), or starved: a machine in your claims that
  // lacks ingredients (`alert low_power starved`, commas also separate).
  // A filter by area and size (Haiku, d15 06:20: "an alert filter by area or minimum size"): near=X,Y [radius=R],
  // area=X1,Y1,X2,Y2, min_size=N, surface=NAME (`alert near=10,-40 radius=80 min_size=5`); it takes no kinds.
  if (kind === 'alert' || kind === 'alerts') {
    const pairs = rest.filter(word => word.includes('='));
    if (pairs.length) {
      if (pairs.length !== rest.length) throw new Error('--until alert takes kinds (alert low_power starved) or a filter (alert near=X,Y radius=R min_size=N, area=X1,Y1,X2,Y2, surface=NAME), not both');
      const condition: Record<string, unknown> = {until:'alert'};
      const numbers = (v: string, n: number, name: string) => {
        const list = v.replace(/[()]/g, '').split(',').map(Number);
        if (list.length !== n || list.some(x => !Number.isFinite(x))) throw new Error(`--until alert ${name}= takes ${n === 1 ? 'a number' : `${n} numbers joined by commas`}`);
        return list;
      };
      for (const pair of pairs) {
        const at = pair.indexOf('='), key = pair.slice(0, at), v = pair.slice(at + 1);
        if (key === 'near' || key === 'at') { const [x, y] = numbers(v, 2, key); condition.near = {x, y}; }
        else if (key === 'radius') condition.radius = numbers(v, 1, key)[0];
        else if (key === 'min_size' || key === 'size') condition.min_size = numbers(v, 1, key)[0];
        else if (key === 'area') { const [x1, y1, x2, y2] = numbers(v, 4, key); condition.area = {left_top:{x:x1, y:y1}, right_bottom:{x:x2, y:y2}}; }
        else if (key === 'surface') condition.surface = v;
        else throw new Error(`--until alert filter keys are near, radius, area, min_size and surface (not ${key})`);
      }
      return condition;
    }
    const kinds = rest.join(' ').split(/[\s,]+/).filter(Boolean);
    return kinds.length ? {until:'alert', kinds} : {until:'alert'};
  }
  // The rocket being built has at least N parts (Sonnet, shift14 22:50): rocket_parts>=N at X,Y (the silo); >N is N+1.
  // silo_parts is the same (A1, Sonnet d16 22:50); with no count, every part of the rocket.
  if (/^(?:rocket|silo)_parts\b/.test(trimmed)) {
    const m = trimmed.match(/^(?:rocket|silo)_parts\s*(?:(>=|>)?\s*(\d+)\s+)?(?:at\s+)?\(?(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\)?$/);
    if (!m) throw new Error('--until rocket_parts (or silo_parts) takes an optional count and the silo position: rocket_parts>=40 at X,Y, or rocket_parts at X,Y for every part');
    const position = {x:Number(m[3]), y:Number(m[4])};
    if (m[2] === undefined) return {until:'rocket_parts', position};
    return {until:'rocket_parts', at_least:Number(m[2]) + (m[1] === '>' ? 1 : 0), position};
  }
  if (kind === 'queue_done' && rest.length === 0) return {until:'queue_done'};
  // What machines made since the wait began (Grok 07:50: robots empty the provider, so item_count never rises):
  // produced ITEM>=N at X,Y [X,Y ...] (items), or produced>=N at X,Y (crafts).
  if (/^produced\b/.test(trimmed)) {
    // On a platform (D4, Astra): produced ITEM>=N on PLATFORM, from its production statistics.
    const on = trimmed.match(/^produced\s*([a-z][\w-]*)\s*(>=|>)\s*(\d+)\s+on\s+(?:platform\s+)?(?:"([^"]+)"|'([^']+)'|(\S+))$/);
    if (on) return {until:'produced', item:on[1], at_least:Number(on[3]) + (on[2] === '>' ? 1 : 0), platform:on[4] ?? on[5] ?? on[6]};
    const m = trimmed.match(/^produced\s*(?:([a-z][\w-]*)\s*)?(>=|>)\s*(\d+)\s+(?:at|in)\s+(.+)$/);
    if (!m) throw new Error('--until produced takes an optional item, a count and the machines: produced iron-gear-wheel>=50 at X,Y [X,Y ...] (produced>=N: crafts)');
    const positions = (m[4] ?? '').split(/[\s;]+/).filter(Boolean).map(pair => {
      const xy = pair.match(/^\(?(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)\)?$/);
      if (!xy) throw new Error(`--until produced positions are X,Y pairs separated by spaces: ${pair}`);
      return {x:Number(xy[1]), y:Number(xy[2])};
    });
    const condition: Record<string, unknown> = {until:'produced', at_least:Number(m[3]) + (m[2] === '>' ? 1 : 0), positions};
    if (m[1]) condition.item = m[1];
    return condition;
  }
  // A silo's rocket built and ready to launch (Luna, shift10: the rocket is no item to count).
  if (kind === 'rocket_ready') {
    const xy = rest.filter(word => word !== 'at').join('').match(/^\(?(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)\)?$/);
    if (!xy) throw new Error('--until rocket_ready takes the silo position: rocket_ready X,Y');
    return {until:'rocket_ready', position:{x:Number(xy[1]), y:Number(xy[2])}};
  }
  // Gemini, shift10: wait for a platform's arrival in orbit (any stop, or the planet named); 16:50: its departure
  // (platform_left, or platform_departed). The name may be quoted ("Big Ship"); "at" or "from" before the planet.
  if ((kind === 'platform_arrived' || kind === 'platform_left' || kind === 'platform_departed') && !rest.some(word => word.includes('='))) {
    const m = trimmed.slice(kind.length).trim().match(/^(?:"([^"]+)"|'([^']+)'|(\S+))(?:\s+(?:(?:at|from)\s+)?(\S+))?$/);
    if (!m) throw new Error(`--until ${kind} takes a platform name (quoted if it has spaces) and an optional planet: ${kind} Sunward gleba`);
    const until = kind === 'platform_arrived' ? 'platform_arrived' : 'platform_left';
    const platform = m[1] ?? m[2] ?? m[3];
    return m[4] ? {until, platform, location:m[4]} : {until, platform};
  }
  const value = (v: string): unknown => /^-?\d+(\.\d+)?$/.test(v) ? Number(v) : v;
  // A level reached or fallen under (Haiku, 12:20: wait until a chest's coal is below 20, then feed): ITEM>=N, ITEM>N,
  // ITEM<N, ITEM<=N, or the words below/under/above/at_least: `item_count coal below 20 at 10,39`.
  if ((kind === 'item_count' || kind === 'items') && /[<>]|\s(below|under|above|at_least)\s/.test(' ' + rest.join(' ') + ' ')) {
    const match = rest.join(' ').match(/^([\w-]+)\s*(>=|<=|<|>|\s+below\s+|\s+under\s+|\s+above\s+|\s+at_least\s+)\s*(\d+)(?:\s+(?:at|in)\s+(.+))?$/);
    if (!match) throw new Error(usage);
    const op = (match[2] ?? '').trim(), n = Number(match[3]);
    const [field, level] = op === '>=' || op === 'at_least' ? ['at_least', n] : op === '>' || op === 'above' ? ['at_least', n + 1]
      : op === '<=' ? ['below', n + 1] : ['below', n];
    const condition: Record<string, unknown> = {until:'item_count', item:match[1], [field]:level};
    if (match[4]) {
      condition.positions = match[4].split(/[\s;]+/).filter(Boolean).map(pair => {
        const xy = pair.match(/^\(?(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)\)?$/);
        if (!xy) throw new Error(`--until positions are X,Y pairs separated by spaces: ${pair}`);
        return {x:Number(xy[1]), y:Number(xy[2])};
      });
    }
    return condition;
  }
  if (!/^[a-z_]+$/.test(kind)) throw new Error(usage);
  const condition: Record<string, unknown> = {until:kind};
  for (const pair of rest) {
    const at = pair.indexOf('=');
    if (at < 1) throw new Error(usage);
    condition[pair.slice(0, at)] = value(pair.slice(at + 1));
  }
  return condition;
}
// Word-form waits in raw calls and plans use the same grammar as fh sleep --until.
// Conflicting structured fields are refused before anything is sent to the game.
function normalizeWaitArgs(action: string, args: Record<string, unknown>, path = 'args', depth = 0): Record<string, unknown> {
  if (depth > 32) throw new Error(`${path}: queue arguments exceed maximum nesting depth`);
  if (action === 'wait_until') {
    const out = {...args};
    for (const alias of ['ticks', 'timeout_ticks']) {
      if (out[alias] === undefined) continue;
      if (out.timeout !== undefined && out.timeout !== out[alias]) throw new Error(`${path}.${alias} conflicts with timeout`);
      out.timeout = out[alias];
      delete out[alias];
    }
    if (typeof out.until === 'string' && /\s|[<>=]/.test(out.until.trim())) {
      const parsed = parseUntil(out.until);
      for (const [key, value] of Object.entries(parsed)) {
        if (key !== 'until' && out[key] !== undefined && JSON.stringify(out[key]) !== JSON.stringify(value)) {
          throw new Error(`${path}.${key} conflicts with the word-form until`);
        }
        out[key] = value;
      }
      if (out.below !== undefined && out.at_least !== undefined) throw new Error(`${path}: below and at_least are mutually exclusive`);
      if (out.position !== undefined && out.positions !== undefined) throw new Error(`${path}: position and positions are mutually exclusive`);
    }
    return out;
  }
  if (!['queue_submit', 'queue_repeat', 'queue_edit'].includes(action)) return args;
  const out = {...args};
  if (action === 'queue_repeat' && out.condition && typeof out.condition === 'object' && !Array.isArray(out.condition)) {
    out.condition = normalizeWaitArgs('wait_until', out.condition as Record<string, unknown>, `${path}.condition`, depth + 1);
  }
  if (Array.isArray(out.steps)) out.steps = out.steps.map((step, i) => {
    if (!step || typeof step !== 'object' || typeof step.action !== 'string' || !step.args || typeof step.args !== 'object') return step;
    return {...step, args:normalizeWaitArgs(step.action, step.args, `${path}.steps[${i + 1}].args`, depth + 1)};
  });
  if (Array.isArray(out.guards)) out.guards = out.guards.map((guard, i) => {
    if (!guard || typeof guard !== 'object') return guard;
    return {...normalizeWaitArgs('queue_submit', guard, `${path}.guards[${i + 1}]`, depth + 1),
      ...(guard.when && typeof guard.when === 'object' ? {when:normalizeWaitArgs('wait_until', guard.when, `${path}.guards[${i + 1}].when`, depth + 1)} : {})};
  });
  return out;
}
/** The parts of an --until joined by | (outside quotes), trimmed, empty ones dropped. */
// A wait_until condition made of platform arrivals and departures only.
function platformOnly(c: Record<string, unknown>): boolean {
  if (c.until === 'any' && Array.isArray(c.conditions)) return c.conditions.length > 0 && c.conditions.every(x => x && typeof x === 'object' && platformOnly(x as Record<string, unknown>));
  return c.until === 'platform_arrived' || c.until === 'platform_left';
}
function splitAlternatives(text: string): string[] {
  const parts: string[] = [];
  let current = '', quote = '';
  for (const ch of text) {
    if (quote) { if (ch === quote) quote = ''; current += ch; continue; }
    if (ch === '"' || ch === "'") { quote = ch; current += ch; continue; }
    if (ch === '|') { parts.push(current); current = ''; continue; }
    current += ch;
  }
  parts.push(current);
  return parts.map(part => part.trim()).filter(Boolean);
}
const TELL_WORDS = new Set(['tell','tells','mention','told']);
// fh sleep/wait --then ACTION [JSON] (A3, Luna 22:50: a Codex shell returned after its yield time, a second sleep
// replaced the first and its chained inspect ran without the wake): one read when the sleep ends, its reply with the
// wake. Read actions only (runtime.lua's reads; tests/d16batch10.test.ts checks the list against it).
const THEN_READS = new Set(['agriculture','artillery','belt_gaps','blueprint_list','boilers','bottleneck','cameras','cargo','conflicts',
  'construction_robots','craftable','damage_log','danger','defense','drill_sites','drops','dry_run','flamers','freight_audit','fuel_budget',
  'game_alerts','grid','heat_budget','inspect','inventory','labs','lookahead','map','nearest','nearest_water','networks','observe','ores',
  'pipe_gaps','placements','platform','platform_bom','platform_endurance','platform_production','platform_defense','circuit_audit','platform_gate','shipment','platform_plan','ghosts','platform_supply','platforms','ports','power','preflight',
  'profiles','rates','recipes','reminders','research_options','reservations','review','scan','science','shortages','silo','status','stock',
  'supply','technologies','trace','turrets','where_is']);
/** --then's action and arguments: "ACTION", "ACTION {json}", with the JSON as the next positional or --args. */
function thenCall(text: string | undefined, positional: string | undefined, argsText: string | undefined): {action: string, args: Record<string, unknown>} | undefined {
  if (text === undefined) return undefined;
  const trimmed = text.trim();
  const m = trimmed.match(/^([a-z_]+)(?:\s+(\{[\s\S]*\}))?$/);
  if (!m) throw new Error(`--then takes a read action and its arguments: --then inspect '{"position":{"x":1,"y":2}}' (not ${JSON.stringify(text)})`);
  const action = m[1]!;
  if (!THEN_READS.has(action)) throw new Error(`--then takes a read action (inspect, observe, status, silo, trace, platforms, ...), not ${action}: it would change the game while you sleep`);
  const json = m[2] ?? positional ?? argsText;
  const args = json === undefined ? {} : object(JSON.parse(json), '--then arguments');
  // platform_bom {request} sets a hub request section (d17 batch11 A6): a change, not a read.
  if (action === 'platform_bom' && args.request !== undefined) throw new Error('--then takes platform_bom as a read: request sets the hub\'s requests, call it on its own');
  return {action, args};
}
/**
 * `fh wait --until EVENT`: tell (a tell or mention; any wait ends on those), alert (a new attack, enemy group or
 * enemy base alert; `alert KIND ...` for chosen kinds), or a sleep condition as for `fh sleep --until` (researched, item_count, crafting_done, ...);
 * several joined by | wake on whichever comes first (tell among them: every wait ends on a tell anyway).
 */
function untilEvent(text: string | undefined): Record<string, unknown> | undefined {
  const trimmed = (text ?? '').trim();
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) return parseUntil(trimmed);
  const parts = splitAlternatives(trimmed).filter(part => !TELL_WORDS.has(part.split(/\s+/)[0]!));
  if (parts.length === 0) return undefined;
  return parseUntil(parts.join(' | '));
}
/** The one line `fh wait --until` prints: what woke it, after how long, and what it was. */
function wakeLine(reply: Reply): string {
  const r = reply.result ?? {};
  const said = (value: unknown) => String(value).replace(/\s*\n\s*/g, ' ');
  const detail = r.urgent ?? r.tell ?? r.mention ?? r.board ?? r.eggs ?? r.alert ?? r.queue
    ?? (r.woke === 'condition' && r.saw !== undefined ? `${r.met ? `${r.met}: ` : ''}saw ${typeof r.saw === 'string' ? r.saw : JSON.stringify(r.saw)}` : undefined)
    // (round1950a: and where the character walks away to when hit with nothing walking it)
    ?? (r.woke === 'damaged' ? `health ${r.health}${r.by ? `, hit by ${r.by}` : ''}${r.fled ? `; ${r.fled}` : ''}` : undefined) ?? r.note
    // A sleep cut to 300 s with nothing running and no condition (d15 H4).
    ?? (r.woke === 'elapsed' && r.capped ? r.capped : undefined);
  const more = r.full ? '' : ['told','mentioned','board','eggs','alert','urgent','damaged'].includes(r.woke) ? '; your next reply\'s team block has the rest' : '';
  // What is open for the agent (open.lua; d15 H3), last.
  return `woke: ${r.woke ?? 'nothing'} after ${r.slept_s ?? 0} s${detail !== undefined ? ` (${said(detail)})` : ''}${r.wait_line ? `; ${said(r.wait_line)}` : ''}${more}${r.open ? `; ${said(r.open)}` : ''}`;
}
function deployingCommand(command: string): boolean { return command === 'deploy' || command === 'watch'; }
function integer(value: string | undefined, fallback: number): number {
  const result = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(result) || result < 1) throw new Error('Numeric options must be positive integers');
  return result;
}
let outputFormat: 'json' | 'compact' = 'compact';
let deadline: number | undefined;
// The clock line carries the time left when the workspace has a deadline.
function withDeadline(value: unknown): unknown {
  const result = value && typeof value === 'object' ? (value as Reply).result : undefined;
  if (deadline === undefined || !result || typeof result.clock !== 'string') return value;
  return {...value as Reply, result:{...result, clock:`${result.clock}; ${deadlineText(deadline)}`}};
}
let streaming = false;
// Operator tells (agent-minds study, fix 1: of 15 shift07 nudges 5 never reached the model, its replies sent to a
// file, /dev/null, `tail -c` or a wrapper keeping three keywords). Any reply may carry result.operator until the
// agent's next game action or message; in compact output each is printed on stderr as soon as a reply carries it and
// first on stdout (JSON keeps it in result.operator), and filed for the workspace's post-tool hook (pog tools/context.py), which puts the unseen ones in the model's context.
const operatorLines = new Map<number, string>();
const operatorPrinted = new Set<number>();
let operatorFile: string | undefined;
function agoText(seconds: number): string {
  return seconds >= 120 ? `${Math.floor(seconds/60)} min ago` : `${seconds} s ago`;
}
// Shown once per message (Muse, shift17 10:50: "operator repeat banners flood stdout and bury command output when
// piped"): a tell an earlier fh call already filed in the operator file is left out of this call's output; the
// workspace hook (pog tools/context.py) shows each new one in the model's context once. A workspace without the hook
// (no .context-hooks beside the operator file; Gemini's) shows each on its first OPERATOR_SHOWS replies (d17 lean C2:
// Gemini saw one on 31 replies when it was every reply until its next game action): the file gets a line per showing.
// --operator-repeat (or FH_OPERATOR_REPEAT=1) prints it on every reply that carries it; so does a call without an
// operator file. Within one fh process a message prints once, on stdout as soon as a reply carries it (it went to
// stderr and to stdout before, so a shell that shows both printed it twice).
export const OPERATOR_SHOWS = 3;
let operatorRepeat = false, operatorNoHook = false;
function operatorShown(seq: number): number {
  if (!operatorFile) return 0;
  try { return readFileSync(operatorFile, 'utf8').split(`"seq":${seq},`).length - 1; } catch { return 0; }
}
function noteOperator(reply: unknown) {
  const lines = reply && typeof reply === 'object' ? (reply as Reply).result?.operator : undefined;
  if (!Array.isArray(lines)) return;
  for (const o of lines) {
    if (typeof o?.seq !== 'number' || typeof o.text !== 'string' || operatorLines.has(o.seq)) continue;
    const shown = operatorShown(o.seq);
    if (operatorFile && !operatorRepeat && shown >= (operatorNoHook ? OPERATOR_SHOWS : 1)) {
      operatorLines.set(o.seq, ''); operatorPrinted.add(o.seq); continue;
    }
    const left = OPERATOR_SHOWS - shown - 1;
    const line = `OPERATOR: ${o.text} (sent ${agoText(Number(o.ago_s ?? 0))}; ${!operatorFile || operatorRepeat
      ? 'repeated on every reply until your next game action or message'
      : operatorNoHook ? (left > 0 ? `shown on ${left} more repl${left === 1 ? 'y' : 'ies'}` : 'shown for the last time')
      : 'shown once: later replies leave it out'})`;
    operatorLines.set(o.seq, line);
    // JSON keeps the tell in result.operator and prints nothing more: scripts read `--format json 2>&1`
    // (Muse, shift12: an OPERATOR line ahead of the document on every data call until the next game action).
    if (outputFormat !== 'json') { process.stdout.write(line + '\n'); operatorPrinted.add(o.seq); }
    if (operatorFile && (operatorNoHook || shown === 0)) {
      try { appendFileSync(operatorFile, JSON.stringify({seq:o.seq, text:o.text, at:new Date().toISOString()}) + '\n'); }
      catch (error) { process.stderr.write(`operator file: ${String(error)}\n`); }
    }
  }
}
// Open board projects for the workspace's post-compaction brief (pog tools/context.py): FH_PROJECTS_FILE (default
// .projects.json next to the journal) holds the lines the last list carried (the shift block's `projects`, a plain
// board read's `projects`), with each project item a later reply carried put in by its id, or taken out once closed.
let projectsFile: string | undefined;
const OPEN = new Set(['open','claimed','doing','blocked']);
function projectLine(item: Record<string, unknown>): string {
  const steps = Array.isArray(item.next_steps) ? item.next_steps : Array.isArray(item.steps) ? item.steps : [];
  const next = steps.find((s): s is string => typeof s === 'string' && s.startsWith('[ ] '));
  const handoff = typeof item.handoff === 'string' ? item.handoff.slice(0, 140) : '';
  return `#${item.id} ${item.title}${item.status === 'blocked' ? ' (blocked)' : ''}: ${item.progress}; ${item.owner ? `owner ${item.owner}` : 'no owner'}`
    + (next ? `; next ${next.slice(4)}` : '') + (handoff ? `; handoff: ${handoff}` : '');
}
function noteProjects(reply: unknown) {
  const result = reply && typeof reply === 'object' ? (reply as Reply).result as Record<string, unknown> | undefined : undefined;
  if (!projectsFile || !result || typeof result !== 'object') return;
  const team = result.team && typeof result.team === 'object' ? result.team as Record<string, unknown> : {};
  const shift = team.shift && typeof team.shift === 'object' ? team.shift as Record<string, unknown> : {};
  const lists = [shift.projects, result.projects].filter(Array.isArray) as unknown[][];
  const items = [result.item, ...(Array.isArray(result.items) ? result.items : [])]
    .filter((i): i is Record<string, unknown> => !!i && typeof i === 'object' && (i as Record<string, unknown>).kind === 'project');
  if (!lists.length && !items.length) return;
  try {
    let lines: string[] = [];
    try {
      const saved = JSON.parse(readFileSync(projectsFile, 'utf8')) as {lines?: unknown};
      if (Array.isArray(saved.lines)) lines = saved.lines.filter((l): l is string => typeof l === 'string');
    } catch { /* the first one */ }
    for (const list of lists) lines = list.filter((l): l is string => typeof l === 'string');
    for (const item of items) {
      const at = lines.findIndex(l => l.startsWith(`#${item.id} `));
      if (!OPEN.has(String(item.status))) { if (at >= 0) lines.splice(at, 1); continue; }
      if (at >= 0) lines[at] = projectLine(item); else lines.push(projectLine(item));
    }
    writeFileSync(projectsFile, JSON.stringify({at:new Date().toISOString(), lines}) + '\n');
  } catch (error) { process.stderr.write(`projects file: ${String(error)}\n`); }
}
// The game's pace (pace.ts; world n 13:41: a crash, a restart from the 13:35 autosave, then 7-10 ticks/s): FH_PACE_FILE
// (default .fh-pace.json next to the journal) keeps the last tick, the speed between calls and an outage in course.
// A rollback and the end of an outage are said once, on the reply that sees them (paceNotes, put first by output).
let paceFile: string | undefined;
let journalPath: string | undefined;
let paceState: PaceState | undefined;
const paceNotes: Record<string, unknown> = {};
function pace(): PaceState { return paceState ??= loadPace(paceFile); }
// A reply to an --id retry may come from the game's or the broker's record with its old tick: no rollback, no speed.
let retriedId: string | undefined;
function notePace(reply: unknown) {
  const tick = reply && typeof reply === 'object' ? (reply as Reply).tick : undefined;
  if (typeof tick !== 'number' || !paceFile) return;
  if (retriedId !== undefined && (reply as Reply).id === retriedId) return;
  const now = Date.now();
  const seen = seeTick(pace(), tick, now);
  savePace(paceFile, pace());
  if (seen.outage) paceNotes.outage = seen.outage;
  if (seen.rollback) {
    const back = rolledBack(journalPath, seen.rollback.to, now);
    paceNotes.rolled_back = `the game rolled back from tick ${seen.rollback.from} to tick ${seen.rollback.to} or earlier (the server restarted from a save): `
      + `what you did after ${back.lastAt ?? 'that tick'} is gone; `
      + (back.redo.length ? `redo lists what your journal shows you changed after it (${back.redo.length + back.more} calls), oldest first` : 'your journal shows no change of yours after it');
    if (back.redo.length) paceNotes.redo = back.more ? [...back.redo, `+${back.more} more (your journal: ${journalPath})`] : back.redo;
  }
}
// A call that could not reach the game: since when (pace.ts), and whether the request went out.
function transportError(error: unknown): {code: string, message: string, recovery?: string} | undefined {
  const text = error instanceof Error ? error.message : String(error);
  if (error instanceof RconUnavailable) {
    const since = paceFile ? seeDown(pace(), Date.now(), text) : 'game unreachable';
    savePace(paceFile, pace());
    return {code:'game_unreachable', message:`${since}: ${text}; the request was not sent (nothing was done)`};
  }
  if (error instanceof RconOutcomeUnknown || error instanceof BridgeOutcomeUnknown) {
    const since = paceFile ? seeDown(pace(), Date.now(), text) : undefined;
    savePace(paceFile, pace());
    return {code:'outcome_unknown', message:`${since ? since + ': ' : ''}${text}`,
      recovery:`fh sent it again with the same ID for ${Math.round(retryBudgetMs()/1000)} s without an answer. Inspect status/state. Retry only the same action, args, player and ID (--id) while the dedup cache retains it: the game answers an ID it applied from its record and runs one it never got.`};
  }
  return undefined;
}
function withPace(value: unknown): unknown {
  if (!value || typeof value !== 'object') return value;
  const reply = value as Reply;
  const notes = Object.keys(paceNotes).length ? {...paceNotes} : undefined;
  for (const key of Object.keys(paceNotes)) delete paceNotes[key];
  const result = reply.result && typeof reply.result === 'object' ? reply.result as Record<string, unknown> : undefined;
  const slow = paceFile ? slowNote(pace(), Date.now()) : undefined;
  if (!notes && !(slow && typeof result?.clock === 'string')) return value;
  const clock = slow && typeof result?.clock === 'string' ? `${result.clock}; ${slow}` : result?.clock;
  return {...reply, result:{...(notes ?? {}), ...(result ?? {}), ...(clock !== undefined ? {clock} : {})}};
}
// The look-ahead block (Nick 12:35; when: lookahead.ts), shown once in a reply as `lookahead`. FH_LOOKAHEAD_FILE
// (default .lookahead.json next to the journal) keeps when the workspace's first call came and when it was last shown.
let lookaheadFile: string | undefined;
// fh help's describe cache (FH_DESCRIBE_CACHE, default .fh-describe.json next to the journal): {bundle, describe}.
let describeCache: string | undefined;
export function readDescribeCache(path: string | undefined): {bundle: string, describe: Record<string, unknown>} | undefined {
  if (!path) return undefined;
  try {
    const cached = JSON.parse(readFileSync(path, 'utf8'));
    return typeof cached?.bundle === 'string' && cached.describe && typeof cached.describe === 'object' ? cached : undefined;
  } catch { return undefined; }
}
/** Keeps a describe that names its bundle (written whole, then renamed, so a parallel fh never reads half of it). */
export function keepDescribe(path: string | undefined, describe: unknown) {
  const bundle = describe && typeof describe === 'object' ? (describe as Record<string, unknown>).bundle : undefined;
  if (!path) return;
  // A runtime without bundle ids: nothing to keep, and no stale bundle to ask about next time.
  if (typeof bundle !== 'string') { rmSync(path, { force: true }); return; }
  const temp = `${path}.${process.pid}.tmp`;
  try { writeFileSync(temp, JSON.stringify({bundle, describe})); renameSync(temp, path); }
  catch { rmSync(temp, { force: true }); }
}
let lookaheadName = '';
// The site's polls (polls.ts): a new open poll's line in the team block, once.
let pollsFile: string | undefined, pollsSeenFile: string | undefined;
function addPoll(reply: Reply, action: string, args: Record<string, unknown>) {
  if (!pollsFile || !pollsSeenFile || !reply.ok || !reply.result || typeof reply.result !== 'object') return;
  if (args?.peek === true || ['describe','sleep_check','profiles','cameras','lookahead'].includes(action)) return;
  const lines = pollNews(pollsFile, pollsSeenFile, Date.now());
  if (!lines.length) return;
  const result = reply.result as Record<string, unknown>;
  const team = result.team && typeof result.team === 'object' ? result.team as Record<string, unknown> : {};
  reply.result = {...result, team:{...team, poll:[...(Array.isArray(team.poll) ? team.poll : []), ...lines]}};
}
function lookaheadLines(result: Record<string, unknown>): string[] {
  const lines = Array.isArray(result.lines) ? result.lines.filter((l): l is string => typeof l === 'string') : [];
  if (deadline !== undefined) lines.push(timeLeftText(deadline));
  if (typeof result.sentence === 'string') lines.push(result.sentence);
  return lines;
}
// The OPERATOR: lines not yet on stdout, for the head of the next stdout write.
function operatorHead(): string {
  const out: string[] = [];
  for (const [seq, line] of operatorLines) if (!operatorPrinted.has(seq)) { operatorPrinted.add(seq); out.push(line); }
  return out.length ? out.join('\n') + '\n' : '';
}
function withoutOperator(value: unknown): unknown {
  const result = value && typeof value === 'object' ? (value as Reply).result : undefined;
  if (!result || typeof result !== 'object' || !('operator' in result)) return value;
  const { operator: _, ...rest } = result as Record<string, unknown>;
  return {...value as Reply, result:rest};
}
// Long compact replies come in pages: the rest waits in FH_MORE_FILE (default .fh-more.txt here) for `fh more`.
// FH_PAGE_BYTES sets the page (default 8000; 0 prints everything at once).
function moreFile(): string { return resolve(process.env.FH_MORE_FILE ?? '.fh-more.txt'); }
function pageBytes(): number { const n = Number(process.env.FH_PAGE_BYTES ?? 8000); return Number.isFinite(n) && n >= 0 ? n : 8000; }
function writePaged(text: string) {
  const { shown, rest } = !streaming && pageBytes() > 0 ? paginate(text, pageBytes()) : { shown: text };
  process.stdout.write(shown);
  try { if (rest) writeFileSync(moreFile(), rest); }
  catch (error) { process.stderr.write(`fh more: could not keep the rest (${String(error)}); FH_PAGE_BYTES=0 prints everything\n`); }
}
/** Exit status: 0 done, 1 failed, 3 the wait ended while the action still runs (a tell or mention ended it, or
 * the wait timed out): `fh call X --wait && next` must not run next then (Sol, shift09). */
export const STILL_RUNNING_EXIT = 3;
function exitCode(reply: Reply): number {
  // JSON --wait replies carry the wait's end under completion.
  const ends = [reply.result, reply.result?.completion];
  if (ends.some(r => r && typeof r === 'object' && r.still_running !== undefined && r.still_running !== false)) return STILL_RUNNING_EXIT;
  return reply.ok ? 0 : 1;
}
/** Sets the exit status; exit 3 also says on stderr that the action goes on (Grok, d15: a tell ended --wait on a
 * walking transfer, and the next command was another move). */
export function stillRunningLine(reply: Reply): string | undefined {
  if (exitCode(reply) !== STILL_RUNNING_EXIT) return undefined;
  const ends = [reply.result, reply.result?.completion];
  const what = ends.map(r => r && typeof r === 'object' ? r.still_running : undefined).find(v => v !== undefined && v !== false);
  const label = typeof what === 'string' ? what : typeof what === 'object' && what && typeof (what as any).kind === 'string' ? (what as any).kind : 'the action';
  return `still running (exit 3): ${label} goes on after this wait ended (a walk keeps walking); fh wait resumes waiting for it. A call that drives your character (move_to, transfer, collect, feed, build, mine, rearm, refuel ...) stops it; reads (observe, inspect, status, trace, supply ...), say, tell, chat, craft, planners (place_ghosts, deconstruct, requests) and calls by remote view or on another surface leave it running`;
}
function setExit(reply: Reply) {
  process.exitCode = exitCode(reply);
  const line = stillRunningLine(reply);
  if (line) process.stderr.write(line + '\n');
}
// fh ACTION run as fh call ACTION (round1650d: Haiku's fh transfer, Luna's fh move_to): said once, in corrected (or on
// the error).
let cliCorrected: string | undefined;
function withCliNote(value: unknown): unknown {
  if (!cliCorrected || !value || typeof value !== 'object') return value;
  const note = cliCorrected;
  cliCorrected = undefined;
  const reply = value as Reply;
  if (!reply.ok && reply.error) return {...reply, error:{...reply.error, message:`${reply.error.message} [${note}]`}};
  const result = reply.result && typeof reply.result === 'object' ? reply.result as Record<string, unknown> : {};
  return {...reply, result:{...result, corrected:typeof result.corrected === 'string' ? `${note}; ${result.corrected}` : note}};
}
// The orders and lessons lines when they changed or every 10 minutes (host/repeats.ts): FH_SHOWN_FILE, default
// .fh-shown.json next to the journal, keeps what this workspace last showed; without a journal every reply shows them.
let shownFile: string | undefined;
function withoutRepeats(value: unknown): unknown {
  if (!shownFile) return value;
  let state: ShownState = {};
  try { state = JSON.parse(readFileSync(shownFile, 'utf8')); } catch { /* the workspace's first reply */ }
  const out = trimRepeats(value, state, Date.now());
  if (out.changed) { try { writeFileSync(shownFile, JSON.stringify(out.state)); } catch { /* shown again next time */ } }
  return out.reply;
}
function output(value: unknown) {
  value = withPace(withDeadline(withCliNote(value)));
  if (outputFormat === 'compact') writePaged(operatorHead() + formatCompact(withoutOperator(withoutRepeats(value))));
  else process.stdout.write(JSON.stringify(value) + '\n');
  // JSON stays one document on stdout; the error:/warning: line goes to stderr
  // so a reader of the terminal (or 2>&1 | tail -1) still sees it.
  if (outputFormat === 'json' && !streaming) {
    const line = finalLine(value);
    if (line) process.stderr.write(line + '\n');
  }
}
async function readStdin(waitMs?: number): Promise<string> {
  const chunks: Buffer[] = [];
  return new Promise((resolve, reject) => {
    const timer = waitMs === undefined ? undefined : setTimeout(() => { if (!chunks.length) { process.stdin.pause(); resolve(''); } }, waitMs);
    process.stdin.on('data', chunk => chunks.push(Buffer.from(chunk)));
    process.stdin.on('end', () => { clearTimeout(timer); resolve(Buffer.concat(chunks).toString('utf8')); });
    process.stdin.on('error', reject);
  });
}
// Item counts by name@quality from an observe player inventory.
function counts(inventory: unknown): Map<string, number> {
  const out = new Map<string, number>();
  for (const stack of Array.isArray(inventory) ? inventory : []) {
    if (!stack || typeof stack.name !== 'string') continue;
    const key = stack.quality && stack.quality !== 'normal' ? `${stack.name}@${stack.quality}` : stack.name;
    out.set(key, (out.get(key) ?? 0) + Number(stack.count ?? 0));
  }
  return out;
}
// What the character carries: the main inventory plus the gun ammo slots,
// where crafted magazines land and shooting spends them.
function carried(player: any): unknown[] {
  return [...(Array.isArray(player?.inventory) ? player.inventory : []), ...(Array.isArray(player?.ammo) ? player.ammo : [])];
}
function inventoryChange(before: unknown, after: unknown): string | undefined {
  const a = counts(before), b = counts(after), parts: string[] = [];
  for (const key of new Set([...a.keys(), ...b.keys()])) {
    const delta = (b.get(key) ?? 0) - (a.get(key) ?? 0);
    if (delta) parts.push(`${key}${delta > 0 ? '+' : ''}${delta}`);
  }
  return parts.length ? parts.join(' ') : 'unchanged';
}
async function main() {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    format:{type:'string'}, help: { type:'boolean', short:'h' }, args:{type:'string'}, 'args-file':{type:'string'}, player:{type:'string'}, bot:{type:'string'},
    host:{type:'string'}, port:{type:'string'}, timeout:{type:'string'}, id:{type:'string'},
    file:{type:'string'}, out:{type:'string'}, mods:{type:'string'}, journal:{type:'string'},
    wait:{type:'boolean'}, 'wait-timeout':{type:'string'}, 'wait-through-tells':{type:'boolean'}, 'wake-on-tells':{type:'boolean'}, 'wake-from':{type:'string'}, 'no-operator-wake':{type:'boolean'}, 'wake-on-viewers':{type:'boolean'}, 'no-urgent':{type:'boolean'}, 'urgent-radius':{type:'string'}, 'wake-on-orders':{type:'boolean'}, 'operator-repeat':{type:'boolean'},
    name:{type:'string'}, session:{type:'string'}, factorio:{type:'string'}, save:{type:'string'},
    headless:{type:'boolean'}, niri:{type:'boolean'}, 'space-age':{type:'boolean'}, bridge:{type:'boolean'}, server:{type:'string'},
    'password-file':{type:'string'}, 'player-data':{type:'string'}, 'bridge-socket':{type:'string'}, socket:{type:'string'},
    full:{type:'boolean'}, since:{type:'string'}, limit:{type:'string'}, peek:{type:'boolean'}, aloud:{type:'boolean'}, look:{type:'string'}, fyi:{type:'boolean'}, wake:{type:'boolean'},
    'text-file':{type:'string'}, 'deadline-file':{type:'string'}, until:{type:'string'}, then:{type:'string'},
    max:{type:'string'}, title:{type:'string'},
  }});
  let command = positionals[0];
  // fh help ACTION (or fh call ACTION --help): that action's arguments, about 1 KB.
  if (values.help && command === 'call' && positionals[1]) { command = 'help'; positionals.splice(0, 2, 'help', positionals[1]); }
  if (!command || (values.help && command !== 'help') || (command === 'help' && !positionals[1])) {
    const dir = refDir();
    process.stdout.write(help + (dir ? topicsLine(dir) : ''));
    return;
  }
  // fh help TOPIC: the workspace's reference topic (no game call); journaled, so lookups can be counted.
  if (command === 'help') {
    const dir = refDir(), text = dir ? topicText(dir, positionals[1]!) : undefined;
    if (values.journal) {
      try { appendFileSync(values.journal, JSON.stringify({at:new Date().toISOString(), event:'help', [text ? 'topic' : 'action']:positionals[1]})+'\n'); }
      catch { /* the journal is best effort here */ }
    }
    if (text !== undefined) { process.stdout.write(text); return; }
  }
  // fh more: the next page of the last long reply (no game call).
  if (command === 'more') {
    let rest: string;
    try { rest = readFileSync(moreFile(), 'utf8'); } catch { process.stdout.write('nothing more: the last reply was shown in full\n'); return; }
    rmSync(moreFile(), { force: true });
    writePaged(rest);
    return;
  }
  if (values.format && !['json','compact'].includes(values.format)) throw new Error('--format must be json or compact');
  outputFormat = command === 'stream' || values.format === 'json' ? 'json' : 'compact';
  streaming = command === 'stream';
  const deadlineFile = values['deadline-file'] ?? process.env.FH_DEADLINE_FILE;
  if (deadlineFile) {
    // A missing or unreadable deadline only drops the time left, never the request.
    try { deadline = parseDeadline(await readFile(deadlineFile,'utf8')); }
    catch (error) { process.stderr.write(`deadline: ${String(error)}\n`); }
  }
  // FH_NIRI=1 makes Niri isolation the default for graphical clients.
  const niri = values.niri ?? (!values.headless && process.env.FH_NIRI === '1');
  if (command === 'start') {
    output({ok:true,result:await startSession({name:values.name ?? 'default',factorio:values.factorio,save:values.save,headless:values.headless,spaceAge:values['space-age'],bridge:values.bridge,niri})});
    return;
  }
  if (command === 'connect') {
    if (!values.server) throw new Error('connect requires --server HOST:PORT');
    output({ok:true,result:await connectSession({name:values.name ?? 'default',server:values.server,factorio:values.factorio,
      spaceAge:values['space-age'],passwordFile:values['password-file'],playerData:values['player-data'],mods:values.mods,niri})});
    return;
  }
  if (command === 'stop-session') {
    output({ok:true,result:await stopSession(positionals[1] ?? values.session ?? values.name ?? 'default')});
    return;
  }
  if (command === 'install') {
    if (!values.mods) throw new Error('install requires --mods /path/to/Factorio/mods');
    const target = resolve(values.mods, 'agent-harness_0.1.0');
    await mkdir(dirname(target), {recursive:true});
    // No overwrite of local modifications; use deploy for runtime updates.
    await cp(modPath, target, {recursive:true, force:false, errorOnExist:true});
    output({ok:true, result:{path:target, next:'Enable agent-harness and load your save once. Runtime updates use fh deploy.'}});
    return;
  }
  if (values['args-file']) {
    if (values.args) throw new Error('Use either --args or --args-file');
    values.args = await readFile(values['args-file'],'utf8');
  }
  if (command === 'blueprint') {
    const operation = positionals[1] ?? 'list';
    // save and rename: the team library (blueprint_save, blueprint_rename).
    if (!['import','export','inspect','list','delete','capture','place','copy','cut','paste','save','rename'].includes(operation)) throw new Error('Unknown blueprint operation');
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    if (operation === 'import') {
      if (!values.file) throw new Error('blueprint import requires --file blueprint.txt');
      args.blueprint = (await readFile(values.file,'utf8')).trim();
    }
    if (operation === 'inspect') args.layout = true;
    values.args = JSON.stringify(args);
    positionals[1] = operation === 'inspect' ? 'blueprint_export' : ['copy','cut','paste'].includes(operation) ? operation : `blueprint_${operation}`;
    command = 'call';
  }
  if (command === 'queue') {
    const operation = positionals[1] ?? 'status';
    if (!['submit','repeat','status','edit','cancel','resume'].includes(operation)) throw new Error('queue expects submit, repeat, status, edit, cancel, or resume');
    let args = object(JSON.parse(values.args ?? '{}'),'args');
    // fh queue status orders: the standing orders' history entries too (round2250a, Grok: by default the plan last
    // submitted only).
    if (operation === 'status' && positionals[2] !== undefined) {
      if (positionals[2] !== 'orders' || positionals.length > 3) throw new Error('queue status takes nothing, or orders (the standing orders\' entries too)');
      args.orders = true;
    }
    if (values.file) {
      const steps: unknown = JSON.parse(await readFile(values.file,'utf8'));
      // An object (one step, or {steps:[...]}) would submit nothing silently.
      if (!Array.isArray(steps)) throw new Error('queue file must be a JSON array of steps: [{"action":...,"args":{...}}, ...]');
      args = {...args,steps};
    }
    values.args = JSON.stringify(args);
    positionals[1] = `queue_${operation}`;
    command = 'call';
  }
  // fh board plan [goals TEXT|doing TEXT|for NAME TEXT]: the team plan (board_plan); TEXT - reads stdin, "" clears.
  if (command === 'board' && positionals[1] === 'plan') {
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    const part = positionals[2];
    if (part !== undefined) {
      if (!['goals','doing','for'].includes(part)) throw new Error('board plan takes goals "text", doing "text" or for NAME "text"');
      if (part === 'for') {
        if (!positionals[3]) throw new Error('board plan for needs a NAME: fh board plan for luna "text"');
        args.agent = positionals[3];
      }
      const words = positionals.slice(part === 'for' ? 4 : 3);
      const text = words.length === 1 && words[0] === '-' ? (await readStdin()).trim() : words.join(' ');
      // No words (or empty stdin) is not a clear: the goals go as "" without clear, which the mod refuses naming the
      // current goals; an explicit "" clears them (clear: true). For doing, no words is refused here.
      if (part !== 'goals' && words.length === 0) throw new Error(`board plan ${part === 'for' ? 'for NAME' : 'doing'} needs the text ("" removes the line)`);
      if (part === 'goals' && words.length === 1 && words[0]?.trim() === '') args.clear = true;
      else args[part === 'goals' ? 'goals' : 'doing'] = text;
    }
    values.args = JSON.stringify(args);
    positionals.splice(0, positionals.length, 'call', 'board_plan');
    command = 'call';
  }
  // fh research [done]: the queue in full, or what finished lately.
  if (command === 'research') {
    const operation = positionals[1];
    if (operation !== undefined && operation !== 'done') throw new Error('research takes nothing or done; queue technologies with fh call research --args JSON');
    positionals.splice(0, positionals.length, 'call', operation === 'done' ? 'research_done' : 'research');
    command = 'call';
  }
  if (command === 'board') {
    const operation = positionals[1] ?? 'list';
    const actions: Record<string, string> = {list:'board', projects:'board', post:'board_post', update:'board_update', events:'board_events', request:'harness_request'};
    if (!actions[operation]) throw new Error('board expects list, projects, post, update, events, request, or plan');
    // fh board projects: the open projects as rows (progress, the next steps, the handoff); --args '{"id":N}' shows one in full.
    if (operation === 'projects') {
      const args = object(JSON.parse(values.args ?? '{}'),'args');
      if (args.id === undefined) { args.kind ??= 'project'; args.status ??= 'active'; }
      values.args = JSON.stringify(args);
    }
    positionals[1] = actions[operation]!;
    command = 'call';
  }
  if (command === 'plan') {
    const operation = positionals[1] ?? 'list';
    if (!['save','run','show','delete','list'].includes(operation)) throw new Error('plan expects save, run, show, delete, or list');
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    if (operation !== 'list') {
      if (!positionals[2]) throw new Error(`plan ${operation} requires a plan NAME`);
      args.name = positionals[2];
    }
    if (operation === 'save') {
      if (!values.file) throw new Error('plan save requires --file plan.json (a JSON array of queue steps)');
      const steps: unknown = JSON.parse(await readFile(values.file,'utf8'));
      if (!Array.isArray(steps)) throw new Error('plan file must be a JSON array of steps: [{"action":...,"args":{...}}, ...]');
      args.steps = steps;
    }
    if (operation === 'delete') args.delete = true;
    values.args = JSON.stringify(args);
    positionals[1] = operation === 'save' || operation === 'delete' ? 'plan_save' : operation === 'run' ? 'plan_run' : 'plans';
    command = 'call';
  }
  // `fh call say words...` used to drop the words and send {} ("text is required").
  if (command === 'call' && ['say','confess','tell','operator','chronicle'].includes(positionals[1] ?? '') && (positionals.length > 2 || !values.args)) {
    command = positionals[1]!;
    positionals.splice(0, 2, command);
  }
  if (command === 'say' || command === 'confess' || command === 'tell' || command === 'operator' || command === 'chronicle') {
    // Text as arguments, a file or stdin: no JSON quoting, apostrophes are fine.
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    // fh tell NAME[,NAME]|team text...: the first word names the recipients.
    if (command === 'tell' && args.to === undefined) {
      if (!positionals[1]) throw new Error('tell needs a name: fh tell luna "text", fh tell luna,sol "text" or fh tell team "text"');
      args.to = positionals.splice(1, 1)[0];
    }
    const words = positionals.slice(1);
    let text: string | undefined;
    if (values['text-file']) text = await readFile(values['text-file'],'utf8');
    else if (words.length === 1 && words[0] === '-') text = await readStdin();
    else if (words.length) text = words.join(' ');
    else if (args.text === undefined && !process.stdin.isTTY) text = await readStdin(1000);
    if (text !== undefined) args.text = text.trim();
    const usage = command === 'tell' ? 'tell NAME' : command;
    if (typeof args.text !== 'string' || !args.text) throw new Error(`${command} needs text: fh ${usage} "text", fh ${usage} --text-file F, or fh ${usage} - with the text on stdin`);
    if (values.aloud) {
      if (command !== 'say') throw new Error(`--aloud applies to say; ${command === 'tell' ? 'a tell stays off the chat and the voice' : command === 'operator' ? 'an operator request goes to the operator, not the voice' : command === 'chronicle' ? 'a chronicle entry goes to the site\'s chronicle' : 'a confession always goes to the stream'}`);
      args.aloud = true;
    }
    if (values.look !== undefined) {
      if (command !== 'say') throw new Error('--look applies to say');
      args.look = parseLook(values.look);
    }
    if (values.fyi) {
      if (command !== 'tell') throw new Error('--fyi applies to tell');
      args.fyi = true;
    }
    if (values.wake) {
      if (command !== 'tell') throw new Error('--wake applies to tell');
      args.wake = true;
    }
    if (values.title !== undefined) {
      if (command !== 'chronicle') throw new Error('--title applies to chronicle');
      args.title = values.title;
    }
    values.args = JSON.stringify(args);
    positionals.splice(1, positionals.length - 1, command);
    command = 'call';
  }
  // One vote command: fh vote [yes|no] mute|unmute VIEWER|kick|ban|trust PLAYER reason... (or - for the reason on
  // stdin), fh vote list (= fh votes); fh players [NAME], fh restore PLAYER (also after fh call with the same words).
  if (command === 'call' && ['vote','players','restore'].includes(positionals[1] ?? '') && positionals.length > 2) {
    command = positionals[1]!;
    positionals.splice(0, 2, command);
  }
  if (command === 'vote') {
    const words = positionals.slice(1);
    if (words.length === 0 || words[0] === 'list') { positionals.splice(1, positionals.length - 1, 'votes'); command = 'call'; }
    else {
      const args = object(JSON.parse(values.args ?? '{}'),'args');
      if (words[0] === 'yes' || words[0] === 'no') args.yes = words.shift() === 'yes';
      const kind = words.shift()!;
      const viewerKind = kind === 'mute' || kind === 'unmute';
      if (!viewerKind && !['kick','ban','trust'].includes(kind)) throw new Error('vote takes mute, unmute, kick, ban, trust or list: fh vote mute VIEWER "reason", fh vote kick PLAYER "reason"');
      const who = viewerKind ? 'viewer' : 'player';
      const name = words.shift();
      if (!name) throw new Error(`vote ${kind} needs a ${who}: fh vote ${kind} ${who.toUpperCase()} "reason"`);
      const reason = words.length === 1 && words[0] === '-' ? (await readStdin()).trim() : words.join(' ');
      // A no needs no reason; the harness asks for one only to open a vote.
      if (!reason && args.yes !== false) throw new Error(`vote ${kind} needs a reason: fh vote ${kind} ${name} "reason"`);
      args.kind = kind;
      args[who] = name;
      if (reason) args.reason = reason;
      values.args = JSON.stringify(args);
      positionals.splice(1, positionals.length - 1, 'vote');
      command = 'call';
    }
  }
  if (command === 'players' || command === 'restore') {
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    if (positionals[1] !== undefined) args.player = positionals[1];
    if (command === 'restore' && typeof args.player !== 'string') throw new Error('restore needs a player: fh restore PLAYER [--args \'{"minutes":30}\']');
    values.args = JSON.stringify(args);
    positionals.splice(1, positionals.length - 1, command);
    command = 'call';
  }
  if (command === 'chat' || command === 'tells' || command === 'votes') { positionals.splice(1, positionals.length - 1, command); command = 'call'; }
  // fh platform NAME (Gemini, 07:55): the platforms read of one platform (hub slots, cargo, speed, next stop, ETA);
  // without a name, every platform.
  if (command === 'platform') {
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    if (positionals[1] !== undefined) args.platform = positionals.slice(1).join(' ');
    values.args = JSON.stringify(args);
    positionals.splice(1, positionals.length - 1, 'platforms');
    command = 'call';
  }
  // --since/--limit/--peek for the reads that take them.
  if (values.since !== undefined || values.limit !== undefined || values.peek) {
    const action = positionals[1];
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    if (values.since !== undefined) {
      const since = Number(values.since);
      if (!Number.isSafeInteger(since) || since < 0) throw new Error('--since must be a sequence number (0 or more)');
      if (action === 'chat' || action === 'confessions' || action === 'tells') args.since = since;
      else if (action === 'board_events') args.since_seq = since;
      else throw new Error('--since applies to fh chat, fh tells, fh board events and fh call confessions');
    }
    if (values.limit !== undefined) args.limit = integer(values.limit, 30);
    if (values.peek) args.peek = true;
    values.args = JSON.stringify(args);
  }
  const known = new Set(['doctor','describe','observe','call','view','deploy','watch','stream','run','wait','sleep','help']);
  if (!known.has(command) && /^[a-z][a-z0-9_]*$/.test(command)) {
    cliCorrected = `fh ${command} runs as fh call ${command}`;
    positionals.splice(0, 1, 'call', command);
    command = 'call';
  }
  if (!known.has(command)) throw new Error(`Unknown command ${command}; use fh help`);
  // A bot is a script-driven character addressed by name (FH_BOT for wrappers).
  const bot = values.bot ?? (values.player ? undefined : process.env.FH_BOT || undefined);
  if (values.bot && values.player) throw new Error('Use --player or --bot, not both');
  if (bot !== undefined && !/^[a-z][a-z0-9_-]{0,15}$/.test(bot)) throw new Error('--bot must be a bot name ([a-z][a-z0-9_-]{0,15})');
  // An RCON broker (pog tools/fh_broker.py) holds the password and forwards only this bot's harness requests.
  const brokerSocket = values.socket ?? (process.env.FH_SOCKET || undefined);
  if (brokerSocket && (values.session || values['bridge-socket'] || values.host || values.port)) {
    throw new Error('Use --socket alone: the broker chooses the world');
  }
  if (brokerSocket && (deployingCommand(command) || values.player)) {
    throw new Error(`${values.player ? '--player' : command} is not available through the RCON broker: it forwards only a bot's harness requests`);
  }
  let connection: SessionConnection | undefined;
  if (brokerSocket) {
    connection = undefined;
  } else if (values.session) {
    if (values.host || values.port || values['bridge-socket']) throw new Error('Use --session, --bridge-socket, or --host/--port, not several');
    connection = await sessionConnection(values.session);
  } else if (values['bridge-socket']) {
    if (values.host || values.port) throw new Error('Use --bridge-socket or --host/--port, not both');
    connection = {kind:'bridge', socket:resolve(values['bridge-socket']), player:1};
  } else if (!values.host && !values.port && !process.env.FACTORIO_RCON_HOST && !process.env.FACTORIO_RCON_PORT && !process.env.FACTORIO_RCON_PASSWORD && !process.env.FACTORIO_RCON_PASSWORD_FILE) {
    try { connection = await sessionConnection(); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
  }
  // Compiling and validating a large bundle in-game can take longer than a gameplay reply.
  const deploying = command === 'deploy' || command === 'watch';
  let harness: Pick<Harness,'request'>;
  let deployer: Harness | undefined;
  let client: {close(): void};
  const bridged = connection?.kind === 'bridge';
  if (connection?.kind === 'bridge') {
    if (deploying || command === 'view') throw new Error(`${command} needs the agent-harness mod on the server; bridge sessions act through normal player input only`);
    if (values.player || bot) throw new Error('A bridge controls its own client\'s player; --player/--bot do not apply');
    // Bridge replies wait for the next game tick; allow for a busy client.
    const bridge = new BridgeClient(connection.socket, integer(values.timeout,10000), values.journal);
    harness = bridge; client = bridge;
  } else if (brokerSocket) {
    const broker = new BrokerTransport(resolve(brokerSocket), integer(values.timeout,5000));
    harness = new Harness(broker, 1, values.journal, bot);
    client = broker;
  } else {
    let password = connection ? undefined : process.env.FACTORIO_RCON_PASSWORD;
    const passwordFile = connection?.passwordFile ?? process.env.FACTORIO_RCON_PASSWORD_FILE;
    if (!password && passwordFile) password = (await readFile(passwordFile,'utf8')).trimEnd();
    if (!password) throw new Error('Run fh start, select --session NAME, or set FACTORIO_RCON_PASSWORD_FILE');
    const rcon = new RconClient({host:connection?.host ?? values.host ?? process.env.FACTORIO_RCON_HOST, port:connection?.port ?? integer(values.port ?? process.env.FACTORIO_RCON_PORT,27015), password, timeoutMs:integer(values.timeout,deploying ? 60000 : 5000)});
    harness = deployer = new Harness(rcon, integer(values.player,connection?.player ?? 1), values.journal, bot);
    client = rcon;
  }
  operatorFile = process.env.FH_OPERATOR_FILE || (values.journal ? resolve(dirname(resolve(values.journal)), '.operator-tells.jsonl') : undefined);
  // A workspace without the post-tool hook (no .context-hooks beside the operator file; Gemini's) shows each tell on
  // OPERATOR_SHOWS replies: nothing else would put a missed tell in front of the model.
  operatorRepeat = values['operator-repeat'] === true || process.env.FH_OPERATOR_REPEAT === '1';
  operatorNoHook = operatorFile !== undefined && !existsSync(resolve(dirname(operatorFile), '.context-hooks'));
  paceFile = process.env.FH_PACE_FILE || (values.journal ? resolve(dirname(resolve(values.journal)), '.fh-pace.json') : undefined);
  journalPath = values.journal ? resolve(values.journal) : undefined;
  retriedId = values.id;
  projectsFile = process.env.FH_PROJECTS_FILE || (values.journal ? resolve(dirname(resolve(values.journal)), '.projects.json') : undefined);
  shownFile = process.env.FH_SHOWN_FILE || (values.journal ? resolve(dirname(resolve(values.journal)), '.fh-shown.json') : undefined);
  describeCache = process.env.FH_DESCRIBE_CACHE || (values.journal ? resolve(dirname(resolve(values.journal)), '.fh-describe.json') : undefined);
  lookaheadFile = process.env.FH_LOOKAHEAD_FILE || (values.journal ? resolve(dirname(resolve(values.journal)), '.lookahead.json') : undefined);
  lookaheadName = bot ?? (values.journal ? dirname(resolve(values.journal)).split('/').pop() ?? '' : '');
  // pog's RUN/polls.json: the workspace is the journal's folder, the run its parent
  pollsFile = process.env.FH_POLLS_FILE || (values.journal ? resolve(dirname(dirname(resolve(values.journal))), 'polls.json') : undefined);
  pollsSeenFile = process.env.FH_POLLS_SEEN || (values.journal ? resolve(dirname(resolve(values.journal)), '.fh-polls-seen.json') : undefined);
  {
    const inner = harness;
    harness = {request: async (...a: Parameters<Harness['request']>) => { const reply = await inner.request(...a); noteOperator(reply); noteProjects(reply); notePace(reply); return reply; }};
  }
  // The look-ahead block on a reply when it is due (LOOKAHEAD_MS); the first call of a workspace starts its clock. Read
  // with peek, so the extra request leaves the agent's team news for its own replies.
  async function addLookahead(reply: Reply, action: string, args: Record<string, unknown>) {
    if (!lookaheadFile || !reply.ok || !reply.result || typeof reply.result !== 'object') return;
    if (args?.peek === true || ['describe','sleep_check','profiles','cameras','lookahead'].includes(action)) return;
    const now = Date.now();
    let state: {started: number; last?: number} | undefined;
    try { state = JSON.parse(readFileSync(lookaheadFile, 'utf8')); } catch { /* the workspace's first call */ }
    if (!state || typeof state.started !== 'number') {
      try { writeFileSync(lookaheadFile, JSON.stringify({started:now}) + '\n'); } catch (error) { process.stderr.write(`lookahead file: ${String(error)}\n`); }
      return;
    }
    if (now < lookaheadDue(state, lookaheadName)) return;
    const block = await harness.request('lookahead', {peek:true});
    if (!block.ok || !block.result) return;
    reply.result = {...reply.result, lookahead:lookaheadLines(block.result)};
    try { writeFileSync(lookaheadFile, JSON.stringify({...state, last:now}) + '\n'); } catch (error) { process.stderr.write(`lookahead file: ${String(error)}\n`); }
  }
  let stopping = false;
  const stop = () => { stopping = true; client.close(); };
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  async function waitForBridgeAction(action: string): Promise<Reply> {
    const deadline = Date.now()+integer(values['wait-timeout'],30000);
    while (!stopping && Date.now()<deadline) {
      // status is observe without the entity scan.
      const status = await harness.request('status');
      if (!status.ok) return status;
      if (!status.result?.controls?.[action]) {
        const last = status.result?.last?.[action];
        if (last?.outcome && !['duration_elapsed','target_mined','built'].includes(last.outcome)) {
          return {...status,ok:false,error:{code:'action_interrupted',message:`Control ended: ${last.outcome}`}};
        }
        return status;
      }
      await delay(100);
    }
    if (stopping) throw new Error('Stopped waiting for action; inspect observe. Game actions have a bounded tick duration.');
    const status = await harness.request('status');
    return {...status, ok:false, error:{code:'wait_timeout', message:`${action} still running after the wait timeout; it continues in game: poll status or wait again (--wait-timeout MS)`}};
  }
  // arrived_near: stopped beside a goal inside an entity, which is where callers want to be.
  // target_destroyed: a shoot at an entity ended because it is gone.
  // transferred: a transfer that walked (walk, pick, a courier's to) moved items (Astra 07:53: exit 1 'Control ended:
  // transferred' after moving 200 solid fuel); unreached and nothing_collected still fail.
  const successfulOutcomes = ['told','mentioned','urgent','duration_elapsed','target_mined','mined','repair_completed','arrived','arrived_near','path_built','collected','topped_up','nothing_to_do','constructed','fed','met','picked_up','target_destroyed','clear','dropped','transferred','previewed',
    // clear_cliffs (use_item cliff-explosives): the explosives destroyed cliffs (Sol 17:21/17:32: fh wait exited 1 on it)
    'cliffs_destroyed',
    // load_silo walk (Luna, shift14 21:20): the list aboard, and launched; short and no_rocket still fail.
    'loaded','launched',
    // a call made after its walk into reach (autowalk.lua)
    'done'];
  // How long to wait: an explicit --wait-timeout, else until the action's own
  // end tick (at 60 ticks/s plus a margin), never less than 30 s nor more than 15 min.
  // ownEnd: the action's end tick already reflects --wait-timeout (wait_until), so
  // wait for that end plus a margin rather than racing it.
  function waitBudget(untilTick?: number, nowTick?: number, ownEnd = false): number {
    if (values['wait-timeout'] !== undefined && !ownEnd) return integer(values['wait-timeout'],30000);
    const remaining = untilTick !== undefined && nowTick !== undefined ? Math.max(0,untilTick-nowTick) : 0;
    return Math.min(ownEnd ? 960000 : 900000, Math.max(30000, Math.ceil(remaining/60*1000*1.25)+5000));
  }
  // A silo can extend its idle deadline when it observes another part. Base
  // the host budget on ticks since this wait began, never on repeated polls.
  function siloBudget(status: Reply, startTick: number | undefined, budget: number): number {
    const active = status.result?.active;
    const end = active?.until_tick, limit = active?.silo_wait?.gives_up_tick;
    if (startTick === undefined || !Number.isFinite(end) || !Number.isFinite(limit)) return budget;
    return Math.max(budget, waitBudget(Math.min(end, limit), startTick));
  }
  // A timed-out wait must not look like a finished action: no completion
  // snapshot, a still_running block, and an error that says what to do.
  function timedOut(action: string, status: Reply, waitedMs: number, pacer?: Pacer, ending?: string): Reply {
    const active = status.result?.active;
    const tick = status.tick ?? status.result?.tick;
    const left = active?.until_tick !== undefined && tick !== undefined ? Math.max(0,active.until_tick-tick) : undefined;
    const leftText = left !== undefined ? ` (up to ${Math.ceil(left/60)} s more, until tick ${active.until_tick})` : '';
    const slow = pacer ? slowGame(pacer) : undefined;
    // Why it gave up: the game stopped (no tick for STALL_MS), or it ran slow past 3 x the time + 60 s.
    const why = ending === 'paused' ? ` (no game tick passed for ${Math.round(STALL_MS/1000)} s: the game is paused or stopped)`
      : slow && ending === 'cap' ? ` (slow_game: ${slow}; a wait goes on while the game advances, up to 3 x its game time + 60 s)`
      : slow ? ` (slow_game: ${slow})` : '';
    return {...status, ok:false,
      result:{timed_out:true, still_running:active ?? status.result?.combat ?? true, waited_ms:waitedMs, last:status.result?.last, ...(slow ? {slow_game:slow} : {})},
      error:{code:'wait_timeout', message:`${action} is STILL RUNNING: the wait gave up after ${Math.round(waitedMs/1000)} s${why} but the action has not finished${leftText}. `+
        `A new character action would interrupt it. Keep waiting with 'fh wait', or check 'fh call status' (active) before doing anything else.`}};
  }
  // A computed wait budget's ceiling while the game runs slow: 3 x the game time it covers + 60 s (the budget is that
  // time x 1.25 + 5 s), at most 45 min. An explicit --wait-timeout stays as given.
  function slowCap(started: number, budget: number): number {
    return started+Math.min(2700000, Math.max(budget, Math.round((budget-5000)/1.25*3)+60000));
  }
  let lastPacer: Pacer | undefined;
  function withSlow(reply: Reply): Reply {
    const slow = lastPacer ? slowGame(lastPacer) : undefined;
    return slow && reply.result && typeof reply.result === 'object' ? {...reply, result:{...reply.result, slow_game:slow}} : reply;
  }
  // Poll once a second, every 2 s once the wait passes 10 s; when the action's
  // own end tick is nearer, just after it (at least 100 ms).
  // (At 100 to 400 ms, waiting agents sent ~7 polls a second on world n.)
  function pollDelay(status: Reply, started: number): number {
    const every = Date.now()-started < 10000 ? 1000 : 2000;
    const active = status.result?.active ?? status.result?.combat;
    const tick = status.tick ?? status.result?.tick;
    if (active?.until_tick === undefined || tick === undefined) return every;
    return Math.min(every, Math.max(100, Math.round((active.until_tick - tick) / 60 * 1000) + 100));
  }
  // Polls peek, so the team hints and chat trailer they would carry stay
  // pending for the one reply the agent sees. A runtime without peek gets
  // plain polls.
  // Polls ask for the brief status (the action running and the last results,
  // none of status's factory and threat scans); a runtime without it gets
  // the full one.
  let peekable = !bridged;
  let briefable = !bridged;
  // urgentSince: a body action's wait asks the runtime for an urgent alert since that tick (A2).
  let urgentPollable = true;
  async function poll(urgentSince?: number): Promise<Reply> {
    if (urgentSince !== undefined && urgentPollable && briefable) {
      const radius = urgentRadius();
      const reply = await harness.request('status',{peek:true,brief:true,urgent_since:urgentSince,...(radius !== undefined ? {urgent_radius:radius} : {})});
      if (reply.ok || !/argument urgent_(since|radius)\b/.test(String(reply.error?.message ?? ''))) return reply;
      urgentPollable = false;
    }
    if (briefable) {
      const reply = await harness.request('status',{peek:true,brief:true});
      const message = String(reply.error?.message ?? '');
      if (reply.ok || !/argument (brief|peek)\b/.test(message)) return reply;
      briefable = false;
      if (/argument peek\b/.test(message)) peekable = false;
    }
    if (peekable) {
      const reply = await harness.request('status',{peek:true});
      if (reply.ok || !/peek/.test(String(reply.error?.message ?? ''))) return reply;
      peekable = false;
    }
    return harness.request('status');
  }
  // The finished wait's own reply: full status, or (compact) outcome,
  // position and inventory change from one small observe.
  async function finalReply(status: Reply): Promise<Reply> {
    if (!peekable) return status;
    const fresh = await harness.request('status');
    if (!fresh.ok) return status;
    // An earlier action's result set aside by the wait stays out (request #5).
    const stale = status.result?.note !== undefined && status.result?.last === undefined;
    const result = stale ? {...fresh.result, last:undefined, note:status.result!.note} : fresh.result;
    return {...fresh, result, ok:status.ok, ...(status.error ? {error:status.error} : {})};
  }
  // fh help ACTION's describe, kept per runtime bundle (d17 audit: 540-1070 help calls a shift each pulled the whole
  // 280 KB describe over RCON): the workspace's describe cache holds the last describe and its bundle id, and the game,
  // asked with if_bundle, answers {unchanged} while that bundle runs. A runtime without bundle ids (the mod's folder
  // runtime, or one from before them) is read whole each time, as before.
  async function helpDescribe(): Promise<Reply> {
    const cached = readDescribeCache(describeCache);
    if (cached) {
      const reply = await execute('describe',{if_bundle:cached.bundle});
      if (reply.ok && reply.result?.unchanged === true && reply.result?.bundle === cached.bundle) return {...reply, result:cached.describe};
      if (reply.ok && reply.result?.actions) { keepDescribe(describeCache, reply.result); return reply; }
    }
    const reply = await execute('describe',{});
    if (reply.ok) keepDescribe(describeCache, reply.result);
    return reply;
  }
  const compactWaits = !bridged && !values.full && outputFormat === 'compact';
  const OBSERVE_SELF = {radius:1,limit:1,exclude_resources:true,entity_types:['character']};
  async function brief(status: Reply, started: number, before?: unknown, action?: string): Promise<Reply> {
    const self = await harness.request('observe',OBSERVE_SELF);
    // A dead character cannot observe; status still carries the hints.
    const carrier = self.ok ? self : await harness.request('status');
    // shoot runs on the combat channel: its own outcome is last_combat, not
    // the previous movement's last (shake2: a shoot "returned outcome move_to").
    const shot = action === 'shoot';
    // A full drop's waiting pods run on their own channel too (drop_pending, then last_drop).
    const last = shot ? status.result?.last_combat : action === 'drop' ? status.result?.last_drop : status.result?.last;
    const player = self.ok ? self.result?.player : undefined;
    const result: Record<string, unknown> = {
      // A feed is the call that waited for a hand craft (build, transfer, rearm, refuel): named as that call.
      outcome: last?.outcome ?? (status.result?.active ? 'running' : 'idle'),
      action: shot ? 'shoot' : last?.kind === 'feed' && typeof last?.handler === 'string' ? last.handler : last?.walking_for ?? last?.kind,
      waited_s: Math.round((Date.now()-started)/100)/10,
      wait_estimates: last?.wait_estimates, idle_s: last?.idle_s, wait_line: last?.wait_line,
      position: player?.position ?? status.result?.position,
      health: player && player.health < player.max_health ? `${Math.round(player.health)}/${Math.round(player.max_health)}` : undefined,
      inventory: before !== undefined && player ? inventoryChange(before, carried(player)) : undefined,
      ammo_used: shot ? last?.ammo_used : undefined,
      detail: last?.result, alive: status.result?.alive === false ? false : undefined,
      // construct: what it did and what stopped it, blockers with coordinates (request #167); kite: why it stopped.
      ...(last?.kind === 'construct' ? {built: last.built, mined: last.mined, tiles_mined: last.tiles_mined, remaining: last.remaining || undefined,
        missing: last.missing, failed: last.failed, blockers: last.blockers} : {}),
      // mine {tiles} (minetile, Sol 15:28): each tile mined and what went back, those skipped and why.
      ...(last?.kind === 'mine' && (last?.tiles !== undefined || last?.skipped !== undefined) ? {mined: last.mined,
        tiles: Array.isArray(last.tiles) ? last.tiles.map((t: {tile?: string, restored?: string, position?: {x?: number, y?: number}}) =>
          `${t.tile} (${t.position?.x},${t.position?.y}) -> ${t.restored}`) : undefined,
        skipped: last.skipped, left: last.left, error: last.error} : {}),
      // kite: what it killed, what is left, the ammunition, where it retreated from (kite.lua).
      ...(last?.kind === 'kite' ? {kills: last.kills, enemies_left: last.enemies_left, ammo_used: last.ammo_used, ammo_left: last.ammo_left,
        reloads: last.reloads, retreated_from: last.retreated_from} : {}),
      // move_to: where it can get to when it gave up, and how it ended off a belt (pathing.lua); a gap it
      // stopped before, a squeeze it walked out of, what to mine when closed in; enemies gone around (avoid.lua).
      ...(last?.kind === 'move_to' ? {nearest_reachable: last.nearest_reachable, reachable_gap: last.reachable_gap, off_belt: last.off_belt,
        path: last.path, steered: last.steered, pocket: last.pocket, escaped: last.escaped, mine_to_get_out: last.mine_to_get_out,
        // not closed in, yet no way to the target: what to mine for one (round1820a)
        mine_for_a_way: last.mine_for_a_way,
        // an attack that started on the way: planned again round it (round1950a)
        replanned: last.replanned,
        // a spot it reaches within build reach when it gave up, a squeeze walked along gaps, each leg of a via walk (round0620c)
        build_spot: last.build_spot, build_spot_note: last.build_spot_note, build_spot_squeeze: last.build_spot_squeeze, squeezed: last.squeezed,
        legs: legLines(last.legs),
        // a walk to a target's reach: how near it ended, an end within reach counted as arrived, a spot walked to (movetarget)
        reach: last.reach, reach_note: last.reach_note, reach_walk: last.reach_walk,
        // a position nothing led to, walked near instead (friction2)
        near_walk: last.near_walk, target: last.near_walk ? last.target : undefined} : {}),
      // vehicle drive: the path it followed and a back-up (vehicles.lua).
      ...(last?.kind === 'drive' ? {path_length: last.path_length, backed_up: last.backed_up,
        // drivesafe: the box it planned for, a stop short of the target, ours it braked or stopped for, a dry run's path
        plan: last.plan, stopped_short: last.stopped_short, spared: last.spared, preview: last.preview,
        // remote driving and a drive's guns (remotedrive): the vehicle driven by remote view, rounds fired and kills
        remote: last.remote, vehicle: last.vehicle, shots: last.shots, kills: last.kills, kills_by_name: last.kills_by_name, combat_ended: last.combat_ended} : {}),
      ...(last?.kind === 'move_to' || last?.kind === 'drive' ? {avoided_enemies: last.avoided_enemies,
        enemies_at_start_or_goal: last.enemies_at_start_or_goal, passed_within_margin: last.passed_within_margin} : {}),
      why: last?.why, note: status.result?.note,
      silo_wait: last?.silo_wait ?? status.result?.active?.silo_wait,
      // a call made after its walk into reach, or not made when the walk did not get there (autowalk.lua)
      walked: last?.walked, not_made: last?.not_made,
      // a tour's places left out for an enemy (round1950a)
      danger: last?.danger, dangers: last?.dangers,
      // waits short of rails a moving train was about to pass, on any walk, and a walk ending on rails (round1520d)
      train_waits: last?.train_waits, on_rails: last?.on_rails,
      // retreat (operator 12:27): why it went back, from where, the health then and now, where to.
      retreated: last?.retreated,
      // collect over a radius: moved per item, places touched, what fell short.
      tally: last?.tally,
      // build_path: belts placed, where it stopped, and the trees and rocks it mined in its way (round1050f).
      ...(last?.kind === 'build_path' ? {placed: last.placed, skipped: last.skipped || undefined, next_index: last.next_index, total: last.total,
        next_position: last.outcome === 'path_built' ? undefined : last.next_position, cleared: last.cleared, cleared_names: last.cleared_names} : {}),
      // collect waiting at a machine (collectwait): what it took against what the machine made and its inserters took.
      ...(last?.kind === 'gather' && last?.took !== undefined ? {took: last.took, made: last.made, inserters_took: last.inserters_took,
        crafts: last.crafts, waited_s: last.waited_s, counted_from: last.counted_from} : {}),
      // An item move that ran over time: what it moved and the inventory line after (Muse 06:27).
      moved: last?.moved, inv: last?.inv, route_failures: last?.route_failures,
      // A short feed still says how many stops remain when up_to makes its exit successful.
      ...(last?.kind === 'gather' ? {left:last.left, short_allowed:last.short_allowed, short:last.short} : {}),
      ...(last?.fuel_taken !== undefined ? {fuel_taken:last.fuel_taken, sources:last.sources, source_read_capped:last.source_read_capped} : {}),
      // Transfer tours retain the inventory selected and local delivery/refusal facts in compact waits too.
      ...(last?.op === 'transfer' && Array.isArray(last.entities) ? {
        transfers:last.entities.slice(0,8), transfers_more:last.entities.length>8?last.entities.length-8:undefined,
      } : {}),
      // A courier (transfer or collect with pick and to): where it took from, what it took and what arrived.
      picked: last?.picked, taken: last?.taken, delivered: last?.delivered,
      team: carrier.result?.team, clock: carrier.result?.clock, orders: carrier.result?.orders, chat: carrier.result?.chat,
    };
    for (const key of Object.keys(result)) if (result[key] === undefined) delete result[key];
    return {...status, tick:carrier.tick ?? status.tick, result};
  }
  async function waitForAction(action: string, untilTick?: number, nowTick?: number, before?: unknown): Promise<Reply> {
    if (bridged) return waitForBridgeAction(action);
    const started = Date.now();
    const done = await waitForActionEnd(action, untilTick, nowTick, started, nowTick);
    if (done.result?.interrupted) return interruptedReply(done, started, before, action);
    // A timeout or a failed poll is reported as it is.
    if (done.error?.code === 'wait_timeout' || (!done.ok && done.error?.code !== 'action_interrupted' && done.error?.code !== 'timed_out')) return withTells(done);
    return withSlow(withTells(compactWaits ? await brief(done, started, before, action) : await finalReply(done)));
  }
  async function waitForActionEnd(action: string, untilTick: number | undefined, nowTick: number | undefined, started: number, acceptedTick?: number): Promise<Reply> {
    let budget = waitBudget(untilTick,nowTick,action === 'wait_until');
    let deadline = started+budget;
    const explicit = values['wait-timeout'] !== undefined && action !== 'wait_until';
    // (an explicit --wait-timeout: the cap is the deadline; the overtime check still names a stopped game)
    let cap = explicit ? deadline : slowCap(started, budget);
    const pacer = lastPacer = new Pacer();
    pacer.see(nowTick, started);
    let staleLooks = 0;
    let ending: ReturnType<typeof overtime> = 'go';
    // Tours that walk or load (A2): only an urgent alert ends their wait, not a tell.
    const bodyWait = ['collect','feed','load_silo','rearm','refuel','recover','transfer','pickup'].includes(action);
    // The poll after the deadline is judged like the others: an action that ended since the previous poll ends the
    // wait by its outcome (Sol 12:20: collect --wait --wait-timeout 60000 read STILL RUNNING at 62 s over a gather
    // collected 10 of 10 at 54.2 s game time; the timeout's own status read already showed it ended). The overtime
    // rule (pace.ts) says when that last look comes: past the deadline a slow game that still advances keeps the wait.
    while (!stopping) {
      ending = overtime(pacer, deadline, cap);
      let lastLook = ending !== 'go';
      const status = await poll(bodyWait && values['no-urgent'] !== true ? acceptedTick : undefined);
      pacer.see(status.tick);
      const active = action === 'shoot' ? status.result?.combat : action === 'drop' ? status.result?.drop_pending : status.result?.active;
      // active may report shooting when movement has already finished. A
      // transfer/refuel/rearm short of items waits for the hand-craft queue as
      // an active 'feed'; the radius tours run as 'gather'; vehicle drive runs
      // as 'drive' (request #5: the wait returned the previous action's result). A transfer that walks (walk, pick)
      // runs as 'gather' too.
      const kinds = action === 'collect' || action === 'feed' || action === 'recover' ? ['gather'] : ['rearm','refuel','transfer'].includes(action) ? ['gather','feed'] : action === 'build' ? ['feed'] : action === 'load_silo' ? ['feed','gather']
        : action === 'vehicle' ? ['drive'] : action === 'use_item' ? ['clear_cliffs'] : [action];
      // A walk into reach that the call makes first (autowalk.lua) runs as a move_to naming the call (walking_for).
      const stillRunning = active && (action === 'shoot' || action === 'drop' || kinds.includes(active.kind) || active.walking_for === action);
      if (!explicit && status.ok && stillRunning) {
        const extended = siloBudget(status, nowTick, budget);
        if (extended > budget) {
          budget = extended; deadline = started+budget; cap = slowCap(started,budget);
          ending = overtime(pacer,deadline,cap); lastLook = ending !== 'go';
        }
      }
      // A walking or loading tour (collect, feed, transfer and load_silo walks, rearm, refuel, recover: gather; a load
      // waiting for its rocket: feed) goes on through tells (Grok 18:20: a tell cut load_silo twice, and a launch then
      // left packs in the inventory); an urgent alert ends the wait.
      if (status.ok && stillRunning && bodyWait && typeof status.result?.urgent === 'string') {
        return {...status, result:{...status.result, interrupted:{inbox:{tick:status.tick ?? 0, woke:'urgent', from:status.result.urgent}, active}}};
      }
      // A tell sent with --wake ends any wait (batch8 A4), one that goes on through tells too.
      const wakeTell = status.result?.inbox_wake;
      if (status.ok && stillRunning && (bodyWait || throughTells) && acceptedTick !== undefined && typeof wakeTell?.tick === 'number' && wakeTell.tick >= acceptedTick
        && action !== 'wait_ticks' && action !== 'wait_until') {
        return {...status, result:{...status.result, interrupted:{inbox:wakeTell, active}}};
      }
      if (status.ok && stillRunning && told(status, acceptedTick) && action !== 'wait_ticks' && action !== 'wait_until') {
        if (!throughTells && !bodyWait) return {...status, result:{...status.result, interrupted:{inbox:wakeInbox(status, acceptedTick), active}}};
        noteTell(wakeInbox(status, acceptedTick));
      }
      if (!status.ok || !stillRunning) {
        const last = action === 'shoot' ? status.result?.last_combat : action === 'drop' ? status.result?.last_drop : status.result?.last;
        // A result that ended before this action was accepted belongs to an
        // earlier action: look again briefly, then report none rather than it.
        if (status.ok && action !== 'shoot' && acceptedTick !== undefined && typeof last?.tick === 'number' && last.tick < acceptedTick) {
          if (++staleLooks <= 3 && !lastLook) { await delay(250); continue; }
          return {...status, result:{...status.result, last:undefined,
            note:`${action} is not running and recorded no result of its own (the last result, ${last.kind} ${last.outcome} at tick ${last.tick}, predates it)`}};
        }
        // A kite that ran its ticks out kited for as long as it was asked: done, as shoot's duration_elapsed is.
        if (status.ok && last?.outcome && !successfulOutcomes.includes(last.outcome) && !(last.op === 'feed' && last.outcome === 'out_of_items' && last.short_allowed === true) && !(action === 'kite' && last.outcome === 'timed_out')) {
          return {...status,ok:false,error:endedError(action,last)};
        }
        return status;
      }
      if (lastLook) break;
      await delay(pollDelay(status, started));
    }
    if (stopping) throw new Error('Stopped waiting for action; inspect status. Game actions have a bounded tick duration.');
    // Still running is not a failure of the action, but it is not done either.
    return timedOut(action, await harness.request('status'), Date.now()-started, pacer, explicit && ending === 'cap' ? 'end' : ending);
  }
  // A tell or mention that arrived after `since` (a tick) ends any wait (agent-minds study, fix 5: agents moved to
  // waits nobody could interrupt; the operator's typed message to Sonnet waited 33 minutes behind its waits). The
  // action keeps going; direct waits end themselves (told|mentioned). Polls carry the newest one (status peek: inbox).
  // A viewer's @mention ends it only with --wake-on-viewers (Sonnet and Opus, shift12 13:50: viewers' @mentions ended a
  // sleep, a wait and a move_to --wait every minute or so); either way the next reply's team block has it. The poll's
  // inbox is the newest tell or teammate's mention, inbox_viewer the newest viewer's @mention (a runtime from before
  // that puts viewers' mentions in inbox too).
  const wakeViewers = values['wake-on-viewers'] === true;
  // --wake-from NAMES and --no-operator-wake (Opus 06:33: only named teammates; Sonnet 06:20: not the operator's or
  // automatic tells): a tell from anyone else does not end the wait.
  const wakeFrom = typeof values['wake-from'] === 'string' ? values['wake-from'].split(',').map(s => s.trim().toLowerCase()).filter(Boolean) : undefined;
  const noOperatorWake = values['no-operator-wake'] === true;
  function wakesFrom(from?: string): boolean {
    const who = String(from ?? '').toLowerCase();
    const auto = who === 'operator' || who.startsWith('reminder');
    if (noOperatorWake && auto) return false;
    if (wakeFrom && !wakeFrom.includes(who)) return false;
    return true;
  }
  const wakeArgs = (): Record<string, unknown> => ({...(wakeFrom ? {wake_from:wakeFrom} : {}), ...(noOperatorWake ? {wake_on_operator:false} : {})});
  function wakeInbox(status: Reply, since?: number): {tick:number, woke?:string, from?:string} | undefined {
    if (since === undefined) return undefined;
    for (const inbox of [status.result?.inbox, wakeViewers ? status.result?.inbox_viewer : undefined]) {
      if (typeof inbox?.tick === 'number' && inbox.tick >= since && wakesFrom(inbox.from)) return inbox;
    }
    return undefined;
  }
  function told(status: Reply, since?: number): boolean {
    return wakeInbox(status, since) !== undefined;
  }
  // --wait-through-tells: the wait goes on; each tell or mention seen is listed when it ends
  // (Sol, shift09: `fh ... --wait && next` ran the next step while the action still ran).
  const throughTells = values['wait-through-tells'] === true;
  const toldDuring: string[] = [];
  function noteTell(inbox?: {tick:number, woke?:string, from?:string}) {
    const line = `${inbox?.woke === 'mentioned' ? 'mention' : 'tell'} from ${inbox?.from ?? '?'} at tick ${inbox?.tick}`;
    if (!toldDuring.includes(line)) toldDuring.push(line);
  }
  function withTells(reply: Reply): Reply {
    return toldDuring.length && reply.result && typeof reply.result === 'object' ? {...reply, result:{...reply.result, told_during_wait:[...toldDuring]}} : reply;
  }
  async function interruptedReply(done: Reply, started: number, before: unknown, action: string): Promise<Reply> {
    const {inbox, active} = done.result!.interrupted;
    const base: Reply = {...done, result:{...done.result, last:undefined, interrupted:undefined, inbox:undefined}};
    const shown = compactWaits ? await brief(base, started, before, action) : await finalReply(base);
    const tick = shown.tick ?? done.tick;
    const left = active?.until_tick !== undefined && tick !== undefined ? `, up to ${Math.max(0, Math.ceil((active.until_tick-tick)/60))} s more` : '';
    return {...shown, ok:true, error:undefined, result:{...shown.result, last:undefined, outcome:inbox.woke, from:inbox.from, action:undefined,
      still_running:`${active.kind}${left}`,
      note:`a ${inbox.woke === 'told' ? 'tell' : 'mention'} from ${inbox.from} ended this wait (the team block has it); your ${active.kind} keeps going: fh wait waits for it again`}};
  }
  // A timed action that hit its own limit says so first (timed_out), with the
  // condition a wait_until was still waiting for.
  function endedError(action: string, last: any) {
    // A walk that gave up says why on the error line (move_to: unreachable, blocked); an action that failed says
    // its error (Sol, shift09: a build that waited for a hand craft and then hit trees read "Control ended: failed").
    const why = typeof last.why === 'string' ? last.why : typeof last.error === 'string' ? last.error : undefined;
    if (last.outcome !== 'timed_out') return {code:'action_interrupted',message:`Control ended: ${last.outcome}${why !== undefined ? `: ${why}` : ''}`};
    const what = action === 'wait_until' ? `wait_until timed_out: ${last.condition ?? 'condition'} not met${last.saw !== undefined ? ` (saw ${JSON.stringify(last.saw)})` : ''}; `+
      `the timeout comes from --wait-timeout MS (up to 900000) or args.timeout ticks (up to 54000)`
      // and why, when the action says it (round1820a: a move_to's limit and the leg it ran out on)
      : `${action} timed_out at its own tick limit${why !== undefined ? `: ${why}` : ''}`;
    return {code:'timed_out',message:what};
  }
  // The sleep request's own reply carries the team hints pending when it
  // started (they are shown once): keep them for the reply the agent sees.
  function mergeTeam(started: Reply, final: Reply): Reply {
    const early = started.result?.team;
    if (!early || !final.result) return final;
    const team: Record<string, unknown> = {...early};
    for (const [key, value] of Object.entries(final.result.team ?? {})) {
      const before = team[key];
      team[key] = Array.isArray(before) && Array.isArray(value) ? [...before, ...value] : value;
    }
    return {...final, result:{...final.result, team}};
  }
  // fh sleep: the game runs; poll the read-only sleep_check (peek: mentions
  // stay unread) about once a second, then read it once more normally so the
  // reply carries the team block with whatever woke the agent. A sleep never
  // runs past the workspace deadline: it is cut to the time left and ends there.
  // --urgent-radius N: 1..200 tiles, or undefined when not given.
  function urgentRadius(): number | undefined {
    const raw = values['urgent-radius'];
    if (raw === undefined) return undefined;
    const n = Number(raw);
    if (!Number.isFinite(n) || n < 1 || n > 200) throw new Error(`--urgent-radius takes 1..200 tiles, not ${String(raw)}`);
    return n;
  }
  // --then's read, run once when the sleep ends (not when a newer sleep replaced it: that call runs its own).
  async function withThen(reply: Reply, then: {action: string, args: Record<string, unknown>} | undefined): Promise<Reply> {
    if (!then || stopping) return reply;
    if (reply.result?.woke === 'replaced') {
      return {...reply, result:{...reply.result, then_skipped:`--then ${then.action} not run: this sleep was replaced, and the newer call runs its own`}};
    }
    const read = await execute(then.action, then.args);
    const shown = read.ok ? {action:then.action, ...(read.result ?? {})} : {action:then.action, error:read.error};
    return {...reply, result:{...(reply.result ?? {}), then_read:shown}};
  }
  async function sleep(seconds: number, condition?: Record<string,unknown>, quiet = false, begunReply?: Reply): Promise<Reply> {
    const left = deadline === undefined ? undefined : deadline-Date.now();
    if (left !== undefined && left <= 1000) {
      return {ok:true, result:{woke:'deadline', slept_s:0, note:`no sleep: ${deadlineText(deadline!)}`}};
    }
    const capped = left !== undefined && left < seconds*1000;
    if (capped) seconds = Math.max(1, Math.floor(left/1000));
    // quiet (fh wait --until): peek requests leave the team block for the agent's next reply; one line out.
    // --wake-on-viewers: a viewer's @mention ends the sleep too (a runtime from before it ends a sleep on one anyway).
    let viewers = wakeViewers;
    // --no-urgent: an urgent alert does not end it (urgent.lua; a runtime from before urgent wakes takes no wake_on_urgent).
    let noUrgent = values['no-urgent'] === true;
    // --urgent-radius N (Grok, d15 14:07): urgent wakes only within N tiles of you; a runtime from before it says
    // wake_on_urgent must be true or false, and the sleep runs with the default 40 (said on stderr).
    let radius = noUrgent ? undefined : urgentRadius();
    // --wait-through-tells: no tell or mention ends the sleep (wake_on_messages: false; a tell with --wake still does).
    // A sleep on platform arrivals or departures alone does so too (Sonnet 18:20: "so I do not wake on every unrelated
    // tell while waiting for a ship"); --wake-on-tells keeps tells ending it.
    const shipWait = !!condition && platformOnly(condition);
    let deaf = values['wait-through-tells'] === true || (shipWait && values['wake-on-tells'] !== true);
    const sleepArgs = (peek: boolean) => ({seconds, ...(condition ? {condition} : {}), ...(peek ? {peek:true} : {}), ...(viewers ? {wake_on_viewers:true} : {}),
      ...(noUrgent ? {wake_on_urgent:false} : radius !== undefined ? {wake_on_urgent:{radius}} : {}), ...(values['wake-on-orders'] === true ? {wake_on_orders:true} : {}),
      ...(deaf ? {wake_on_messages:false} : {}), ...wakeArgs()});
    // A direct wait the runtime ran as a sleep (your queue runs: as_sleep) is followed from its reply.
    let started = begunReply ?? await harness.request('sleep',sleepArgs(quiet));
    if (!started.ok && deaf && /unknown argument wake_on_messages/.test(String(started.error?.message ?? ''))) {
      deaf = false;
      process.stderr.write('--wait-through-tells: this runtime\'s sleep takes no wake_on_messages yet (it comes with the next harness deploy); a tell ends this sleep\n');
      started = await harness.request('sleep',sleepArgs(quiet));
    }
    if (!started.ok && radius !== undefined && /wake_on_urgent must be true or false/.test(String(started.error?.message ?? ''))) {
      radius = undefined;
      process.stderr.write('--urgent-radius: this runtime has no urgent radius yet (it comes with the next harness deploy); urgent wakes use 40 tiles\n');
      started = await harness.request('sleep',sleepArgs(quiet));
    }
    if (!started.ok && noUrgent && /unknown argument wake_on_urgent/.test(String(started.error?.message ?? ''))) {
      noUrgent = false;
      started = await harness.request('sleep',sleepArgs(quiet));
    }
    if (!started.ok && viewers && /unknown argument wake_on_viewers/.test(String(started.error?.message ?? ''))) {
      viewers = false;
      started = await harness.request('sleep',sleepArgs(quiet));
    }
    // A runtime from before eng/minds-waits takes no peek on sleep: the sleep runs as fh sleep's, shown whole (full).
    let full = false;
    if (!started.ok && quiet && /unknown argument peek/.test(String(started.error?.message ?? ''))) {
      quiet = false; full = true;
      started = await harness.request('sleep',sleepArgs(false));
    }
    if (!started.ok) {
      if (condition?.until === 'alert') return {...started, error:{...started.error, message:`${started.error?.message ?? 'sleep failed'}; the alert wake comes with the next harness deploy`}};
      if (condition?.until === 'any') return {...started, error:{...started.error, message:`${started.error?.message ?? 'sleep failed'}; several conditions joined by | come with the next harness deploy`}};
      return started;
    }
    // A sleep within 10 s of a wake the agent read repeats that wake at once (waits.lua repeat_of, for shell loops of
    // sleeps). Muse, shift08: "woke 4s ago" refusals burn turns when tells arrive mid-cycle. Wait out the rest of the
    // 10 s and start the sleep then (at most 3 tries); the team block those replies carried is kept.
    let waitedOut: string | undefined;
    for (let tries = 0; started.ok && started.result?.repeat === true && tries < 3 && !stopping; tries++) {
      const text = String(started.result?.while_asleep ?? '');
      const match = /you woke \(([^)]+)\) (\d+) s ago/.exec(text);
      const ago = match ? Number(match[2]) : 0;
      const wait = Math.min(11, Math.max(1, 11-ago));
      await delay(wait*1000);
      if (stopping) break;
      const again = await harness.request('sleep',sleepArgs(quiet));
      if (!again.ok) return mergeTeam(started, again);
      const first = waitedOut === undefined;
      if (first) waitedOut = `your previous sleep woke (${match?.[1] ?? started.result?.woke ?? 'event'}) ${ago} s before this one, and a sleep `+
        `within 10 s of a wake repeats that wake; this sleep started after ${wait} s more`;
      else waitedOut += ` and ${wait} s more`;
      started = mergeTeam(started, again);
    }
    if (started.result?.repeat === true) waitedOut = undefined;
    // What keeps going, at once (a shell that returns early, as Codex's, shows it before the wake).
    if (!quiet && outputFormat === 'compact' && typeof started.result?.while_asleep === 'string') process.stdout.write(`${operatorHead()}while_asleep: ${started.result.while_asleep}\n`);
    if (!quiet && outputFormat === 'compact' && typeof started.result?.wait_line === 'string') process.stdout.write(`${operatorHead()}wait: ${started.result.wait_line}\n`);
    // The sleep's real-time end: its game time at 60 ticks/s plus a margin; past it, it goes on while the game still
    // advances but runs slow (Luna, Astra, Sol, 13:41: 12 game s in 85 real s ended timed_out), up to 3 x SECONDS +
    // 60 s, and ends paused once no tick passed for STALL_MS.
    const begun = Date.now();
    let until = begun+seconds*1250+10000;
    let cap = begun+(seconds*3+60)*1000;
    if (capped) { until = Math.min(until, deadline!+1000); cap = Math.min(cap, deadline!+1000); }
    // One sleep per agent: a newer sleep (another fh sleep while this one ran: shift08 20:07, Sol's Codex shell
    // returned at 30 s and it slept again, so this call polled the new sleep and gave up as timed_out) replaces this
    // one's record. Its end tick tells them apart; this call then ends without reading the other's wake.
    const mine = started.result?.until_tick;
    const pacer = new Pacer();
    pacer.see(started.tick, begun);
    const firstTick = started.tick;
    let ending: ReturnType<typeof overtime> = 'go';
    while (!stopping) {
      ending = overtime(pacer, until, cap);
      if (ending !== 'go') break;
      const check = await harness.request('sleep_check',{peek:true});
      pacer.see(check.tick);
      const theirs = check.result?.until_tick;
      if (check.ok && typeof mine === 'number' && typeof theirs === 'number' && theirs !== mine) {
        // Which sleep replaced it (A3, Luna 22:50): when it began, for how long, and its condition.
        const from = check.result?.sleep_started_tick, cond = check.result?.sleep_until;
        const began = typeof from === 'number' ? ` began ${typeof firstTick === 'number' ? `${Math.max(0, Math.round((from-firstTick)/60))} s after this one ` : ''}(tick ${from}), for ${Math.round((theirs-from)/60)} s` : '';
        return {...check, ok:true, result:{woke:'replaced', waited_s:Math.round((Date.now()-begun)/1000), until_tick:mine,
          replaced_by:{started_tick:from, until_tick:theirs, until:cond},
          note:`replaced: a newer sleep${began} until tick ${theirs}${cond ? `, until ${cond}` : ''} (a later fh sleep, fh wait --until or sleep call: one sleep per agent); that call reports its own wake, and this one ends here without one`}};
      }
      if (!check.ok || check.result?.woke) break;
      await delay(1000);
    }
    if (stopping) throw new Error('Stopped sleeping; the game keeps running.');
    const final = quiet ? await harness.request('sleep_check',{peek:true}) : mergeTeam(started, await harness.request('sleep_check',{}));
    pacer.see(final.tick);
    const woke = final.result?.woke;
    const slow = slowGame(pacer);
    if (final.ok && capped && (!woke || woke === 'elapsed')) {
      return {...final, result:{...final.result, woke:'deadline', note:'this sleep was cut to end at the deadline', ...(slow ? {slow_game:slow} : {})}};
    }
    if (final.ok && !woke) {
      const real = Math.round((Date.now()-begun)/1000);
      const ran = typeof firstTick === 'number' && typeof final.tick === 'number' ? Math.max(0, Math.round((final.tick-firstTick)/60)) : undefined;
      const advanced = ran !== undefined ? `the game advanced ${ran} of the ${seconds} s asked in ${real} s of real time` : `the game advanced less than ${seconds} s in ${real} s of real time`;
      if (ending === 'paused') return {...final, ok:false, error:{code:'paused',message:`sleep ended: no game tick passed for ${Math.round(STALL_MS/1000)} s (the game is paused or stopped); ${advanced}`}};
      return {...final, ok:false, ...(slow ? {result:{...final.result, slow_game:slow}} : {}),
        error:{code:'timed_out',message:`sleep timed_out: ${advanced}${slow ? ` (slow_game: ${slow})` : ''}; it waits up to 3 x SECONDS + 60 s while the game advances`}};
    }
    if (final.ok && woke === 'died') return {...final, ok:false, error:{code:'died',message:'your character died while sleeping'}};
    const shown = waitedOut !== undefined && final.result ? {...final, result:{...final.result, waited_out:waitedOut}} : final;
    const said = slow && shown.result ? {...shown, result:{...shown.result, slow_game:slow}} : shown;
    return full ? {...said, result:{...said.result, full:true}} : said;
  }
  // fh wait: block until whatever the character is doing (and any combat) ends.
  // capMs: fh wait --max S (or --until idle): at most that long (friction1300: Grok and Haiku took `fh wait --max 150`
  // for a wait on the walk; it slept the whole 150 s, the walk done after 46).
  async function waitForIdle(capMs?: number): Promise<Reply> {
    const started = Date.now();
    // The newest reply's tick before this wait (the pace file): an action that ended before it is not this wait's.
    const priorTick = paceFile ? pace().tick : undefined;
    let first = await poll();
    if (!first.ok) return first;
    const since = typeof first.tick === 'number' ? first.tick + 1 : undefined;
    const untilTick = first.result?.active?.until_tick ?? first.result?.combat?.until_tick;
    let budget = capMs ?? waitBudget(untilTick,first.tick ?? first.result?.tick);
    let deadline = started+budget;
    // --wait-timeout, or fh wait --max S: the end as given, with no slow-game overtime.
    const explicit = values['wait-timeout'] !== undefined || capMs !== undefined;
    let cap = explicit ? deadline : slowCap(started, budget);
    const pacer = lastPacer = new Pacer();
    pacer.see(first.tick, started);
    let status = first;
    let ending: ReturnType<typeof overtime> = 'go';
    // The poll after the deadline still counts: idle there ends the wait as idle (as in waitForActionEnd); the
    // overtime rule (pace.ts) says when the deadline has come.
    while (!stopping) {
      if (!status.result?.active && !status.result?.combat) {
        const last = status.result?.last;
        // Nothing running when the wait began, and the last action ended before the call before this one (friction3:
        // Haiku's two waits after a rearm had ended printed its old timed_out as a fresh error, exit 1; Luna and Muse took
        // a walk's and a collect's old outcome as the wait's): said so, exit 0.
        if (status === first && typeof last?.tick === 'number' && typeof priorTick === 'number' && last.tick < priorTick) {
          const ago = typeof status.tick === 'number' ? Math.max(0, Math.round((status.tick - last.tick)/60)) : undefined;
          const note = `nothing was running when this wait began: the last action, ${last.kind ?? 'an action'}, ended ${last.outcome ?? 'earlier'}`
            + `${ago !== undefined ? ` ${ago} s ago` : ''}, before your previous call; its result is given as it ended`;
          // Its result kept (E10, Luna 2x: a transfer and a load_silo that ended before fh wait read as a bare idle line),
          // never an error exit for an old outcome (friction3).
          const quiet = {...status, ok:true, result:{...status.result, note}};
          if (compactWaits) return withSlow(withTells(await brief(quiet, started)));
          const full = await finalReply(quiet);
          return withSlow(withTells({...full, result:{idle:true, nothing_running:true, note, last, last_combat:status.result?.last_combat,
            waited_ms:Date.now()-started, team:full.result?.team, clock:full.result?.clock, orders:full.result?.orders, chat:full.result?.chat}}));
        }
        const ok = !last?.outcome || successfulOutcomes.includes(last.outcome) || (last.op === 'feed' && last.outcome === 'out_of_items' && last.short_allowed === true);
        const ended = {...status, ok, ...(ok ? {} : {error:endedError(last.kind ?? 'the action',last)})};
        if (compactWaits) return withSlow(withTells(await brief(ended, started)));
        const full = await finalReply(ended);
        return withSlow(withTells({...full, result:{idle:true, last, last_combat:status.result?.last_combat, waited_ms:Date.now()-started,
          team:full.result?.team, clock:full.result?.clock, orders:full.result?.orders, chat:full.result?.chat}}));
      }
      if (!explicit) {
        budget = siloBudget(status, first.tick ?? first.result?.tick, budget);
        deadline = started+budget; cap = slowCap(started,budget);
      }
      ending = overtime(pacer, deadline, cap);
      if (ending !== 'go') break;
      await delay(pollDelay(status, started));
      // A walking or loading tour (gather, feed: collect, transfer, load_silo, rearm, refuel, recover walks; a walk into
      // reach for one) goes on through plain tells here too, as --wait does (D10, Grok 00:22: a tell ended fh wait on a
      // rocket load and an egg handoff, and robots took the eggs); an urgent alert or a tell with --wake ends it.
      const wasActive = status.result?.active;
      const tour = !!wasActive && (['gather','feed'].includes(wasActive.kind) || ['collect','feed','load_silo','rearm','refuel','recover','transfer','pickup'].includes(wasActive.walking_for));
      status = await poll(tour && values['no-urgent'] !== true ? since : undefined);
      pacer.see(status.tick);
      if (!status.ok) return status;
      const active = status.result?.active;
      const body = !!active && (['gather','feed'].includes(active.kind) || ['collect','feed','load_silo','rearm','refuel','recover','transfer','pickup'].includes(active.walking_for));
      if (active && body && typeof status.result?.urgent === 'string') {
        return interruptedReply({...status, result:{...status.result, interrupted:{inbox:{tick:status.tick ?? 0, woke:'urgent', from:status.result.urgent}, active}}}, started, undefined, active.kind);
      }
      const wakeTell = status.result?.inbox_wake;
      if (active && body && since !== undefined && typeof wakeTell?.tick === 'number' && wakeTell.tick >= since) {
        return interruptedReply({...status, result:{...status.result, interrupted:{inbox:wakeTell, active}}}, started, undefined, active.kind);
      }
      if (active && told(status, since) && active.kind !== 'wait_ticks' && active.kind !== 'wait_until') {
        if (!throughTells && !body) return interruptedReply({...status, result:{...status.result, interrupted:{inbox:wakeInbox(status, since), active}}}, started, undefined, active.kind);
        noteTell(wakeInbox(status, since));
      }
    }
    if (stopping) throw new Error('Stopped waiting; inspect status.');
    return timedOut(status.result?.active?.kind ?? 'the action', status, Date.now()-started, pacer, explicit && ending === 'cap' ? 'end' : ending);
  }
  async function execute(action: string, args: Record<string,unknown>, id?: string, wait = false, onAccepted?: (reply: Reply) => void): Promise<Reply> {
    args = normalizeWaitArgs(action, args);
    const requestId = id ?? randomUUID();
    // `fh call sleep` (with or without --wait) blocks like fh sleep: the raw
    // action only starts a sleep (shake4-6: Luna's 103 sleeps that never waited).
    if (action === 'sleep' && !bridged) {
      const seconds = args.seconds;
      if (typeof seconds !== 'number' || !Number.isSafeInteger(seconds) || seconds < 1 || seconds > 900) throw new Error('sleep requires seconds 1..900: fh sleep SECONDS');
      if (args.condition !== undefined && (typeof args.condition !== 'object' || args.condition === null)) throw new Error('sleep condition must be an object; or use fh sleep SECONDS --until ...');
      return sleep(seconds, args.condition as Record<string,unknown> | undefined);
    }
    // A waited wait_until runs as long as the CLI waits: --wait-timeout MS
    // becomes its timeout in ticks (up to 15 minutes) unless args name one.
    if (action === 'wait_until' && wait && args.timeout === undefined && values['wait-timeout'] !== undefined) {
      args = {...args, timeout:Math.min(54000, Math.max(1, Math.ceil(integer(values['wait-timeout'],30000)*60/1000)))};
    }
    // The compact wait reports the inventory change, so read it first (peek: no hints consumed).
    let before: unknown;
    if (wait && compactWaits) {
      const self = await harness.request('observe',{...OBSERVE_SELF,peek:true}).catch(() => undefined);
      if (self?.ok) before = carried(self.result?.player);
    }
    // --wake-on-viewers: a direct wait ends on a viewer's @mention too (the runtime ends it told|mentioned).
    const viewersArg = wakeViewers && (action === 'wait_ticks' || action === 'wait_until') && args.wake_on_viewers === undefined;
    if (viewersArg) args = {...args, wake_on_viewers:true};
    // --wait-through-tells: a direct wait no tell ends (wake_on_messages: false), also when it runs as a sleep.
    if (throughTells && (action === 'wait_ticks' || action === 'wait_until') && args.wake_on_messages === undefined) args = {...args, wake_on_messages:false};
    // --wake-from, --no-operator-wake: who may end a direct wait.
    if ((action === 'wait_ticks' || action === 'wait_until') && args.wake_from === undefined && args.wake_on_operator === undefined) args = {...args, ...wakeArgs()};
    // --no-urgent: an urgent alert does not end a direct wait (by default it ends it, outcome urgent, last.why naming it).
    if (values['no-urgent'] === true && (action === 'wait_ticks' || action === 'wait_until') && args.wake_on_urgent === undefined) args = {...args, wake_on_urgent:false};
    // --urgent-radius N: urgent wakes only within N tiles of you.
    const radiusArg = values['no-urgent'] !== true && (action === 'wait_ticks' || action === 'wait_until') && args.wake_on_urgent === undefined ? urgentRadius() : undefined;
    if (radiusArg !== undefined) args = {...args, wake_on_urgent:{radius:radiusArg}};
    let reply: Reply;
    try {
      reply = await harness.request(action,args,requestId);
      if (radiusArg !== undefined && !reply.ok && /wake_on_urgent must be true or false/.test(String(reply.error?.message ?? ''))) {
        const {wake_on_urgent: _dropped, ...rest} = args;
        args = rest;
        process.stderr.write('--urgent-radius: this runtime has no urgent radius yet (it comes with the next harness deploy); urgent wakes use 40 tiles\n');
        reply = await harness.request(action,args,randomUUID());
      }
      // A runtime from before it ends a direct wait on a viewer's @mention anyway.
      if (viewersArg && !reply.ok && /unknown argument wake_on_viewers/.test(String(reply.error?.message ?? ''))) {
        const {wake_on_viewers: _ignored, ...rest} = args;
        args = rest;
        reply = await harness.request(action,args,randomUUID());
      }
    }
    catch (error) {
      const failed = transportError(error);
      if (failed) return {id:requestId, ok:false, error:failed};
      throw error;
    }
    // Sent again with the same ID across a drop (harness.ts requestRetrying, A1): said once, on this reply.
    if (reply.retried && reply.result && typeof reply.result === 'object') {
      const r = reply.retried;
      reply.result = {...reply.result, retried:`the game did not answer at first (${r.first_error}); sent again with the same ID ${r.attempts - 1} time${r.attempts === 2 ? '' : 's'} over ${r.waited_s} s: this is the game's one answer to it (an ID it had applied is answered from its record, never run twice)`};
    }
    // A direct wait while your queue runs ran as a sleep (as_sleep): --wait follows it as fh sleep does.
    if (wait && reply.ok && typeof reply.result?.as_sleep === 'string' && (action === 'wait_ticks' || action === 'wait_until')) {
      const seconds = typeof reply.result?.sleeping_s === 'number' ? reply.result.sleeping_s : 60;
      const slept = await sleep(seconds, undefined, false, reply);
      return slept.ok && slept.result ? {...slept, result:{...slept.result, as_sleep:reply.result.as_sleep}} : slept;
    }
    // craft --wait (Grok: it returned when hand crafting started, and the silo transfer after it moved nothing): waits
    // until the hand-craft queue is done (crafting_done), as a sleep on that condition.
    if (wait && reply.ok && action === 'craft' && !bridged) {
      const started = reply.result?.started;
      const n = typeof started === 'number' ? started : Object.values((started ?? {}) as Record<string,unknown>).reduce((s: number, v) => s + (typeof v === 'number' ? v : 0), 0);
      if (n > 0) {
        const queued = typeof reply.result?.queue_s === 'number' ? reply.result.queue_s : 30;
        const seconds = Math.min(900, Math.max(5, Math.ceil(queued*1.25) + 5));
        const slept = await sleep(seconds, {until:'crafting_done'}, true);
        const done = slept.ok && slept.result?.woke === 'condition';
        return {...slept, ok:slept.ok, result:{...reply.result, crafted:done ? 'the hand-craft queue is done: the items are in your inventory'
          : `not done: the wait ended (${String(slept.result?.woke ?? slept.error?.code ?? 'ended')}) with crafts still queued`,
          ...(done || !slept.ok ? {} : {still_running:'hand crafting'}), wait:slept.result}};
      }
    }
    // kite runs until no enemy is left in its radius, its health or ammo floor, or its ticks (Sol, shift09: kite --wait
    // returned at once while the fight went on).
    const waits = bridged ? ['walk','mine','build'].includes(action)
      : ['walk','move_to','build_path','construct','mine','shoot','pickup','repair','wait_until','wait_ticks','kite'].includes(action) || (['collect','rearm','refuel','feed'].includes(action) && args.radius !== undefined)
        // rearm over an area or the whole surface: the same tour (Opus, shift12 13:50).
        || (['rearm','refuel'].includes(action) && (args.area !== undefined || args.surface !== undefined) && reply.result?.until_tick !== undefined)
        // recover: the walk to your corpses (round1520d).
        || (action === 'recover' && reply.result?.until_tick !== undefined)
        || (['transfer','rearm','refuel','build'].includes(action) && reply.result?.awaiting_craft !== undefined)
        // build stepping off its own footprint, then placing the rest (Sol 11:18: --wait returned at "built 1 of 5")
        || (action === 'build' && reply.result?.stepping_aside !== undefined)
        // load_silo waiting for its rocket (no rocket yet, or launch=true before it is ready), then loading (shift12 15:20);
        // a walking load (op load_silo, until_tick) is a tour (Sol 07:50: --wait returned the acceptance)
        || (action === 'load_silo' && (reply.result?.waiting !== undefined || reply.result?.until_tick !== undefined))
        // launch {wait_ready}: the wait for the rocket, then the launch (last.launch)
        || (action === 'launch' && reply.result?.waiting_to_launch !== undefined)
        // A transfer or collect that walks (walk, pick, pick with to) runs as a timed tour.
        || (['transfer','collect'].includes(action) && reply.result?.op === 'transfer' && reply.result?.until_tick !== undefined)
        // feed over positions with walk: a tour when any was out of reach (Opus 10:50).
        || (action === 'feed' && args.walk === true && reply.result?.until_tick !== undefined)
        // transfer {walk: true} with a target out of reach: a tour (until_tick); all in reach, it moved at once
        || (action === 'transfer' && args.walk === true && reply.result?.until_tick !== undefined)
        // collect {wait_ticks | keep_taking}: standing at a machine, taking its products as they come (collectwait)
        || (action === 'collect' && (args.wait_ticks !== undefined || args.keep_taking !== undefined) && reply.result?.until_tick !== undefined)
        || (action === 'vehicle' && args.drive !== undefined)
        // drop full: pods past the free hatches go as each hatch frees up (space.lua).
        || (action === 'drop' && reply.result?.until_tick !== undefined)
        // cliff explosives thrown by hand: each lands before the next (clear_cliffs; use_item cliff-explosives runs it;
        // Sol 17:21/17:32: --wait returned at once with until_tick)
        || (['clear_cliffs','use_item'].includes(action) && reply.result?.until_tick !== undefined);
    // A call out of reach that walks first by default (autowalk.lua; the reply's walking line): waited for as --wait does,
    // since the same call in reach would have been done at once.
    const walked = reply.ok && reply.result?.walking !== undefined && reply.result?.until_tick !== undefined;
    if ((wait || walked) && reply.ok && (waits || walked)) {
      onAccepted?.(reply);
      const completion = await waitForAction(action, reply.result?.until_tick, reply.tick, before);
      if (completion.error?.code === 'wait_timeout') return {...reply, ok:false, result:{accepted:reply.result, ...completion.result}, error:completion.error};
      // Compact: the brief completion only (the acceptance was printed already when onAccepted is set).
      if (compactWaits && completion.error?.code !== undefined && completion.error.code !== 'action_interrupted'
        && !(completion.error.code === 'timed_out' && completion.result?.silo_wait)
        && !completion.result?.route_failures) {
        return {...reply, tick:completion.tick ?? reply.tick, ok:false,
          result:{accepted:reply.result, ...(action === 'wait_until' ? completion.result : {})}, error:completion.error};
      }
      if (compactWaits) return {...reply, tick:completion.tick ?? reply.tick, ok:completion.ok,
        result:onAccepted ? completion.result : {accepted:reply.result, ...completion.result}, ...(completion.ok ? {} : {error:completion.error})};
      return {...reply, ok:completion.ok, result:{accepted:reply.result, completion:completion.result}, ...(completion.ok ? {} : {error:completion.error})};
    }
    return reply;
  }
  try {
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    if (command === 'deploy' || command === 'watch') {
      const path = resolve(values.file ?? resolve(modPath,'runtime.lua'));
      let previous = '';
      do {
        try {
          const source = await bundleRuntime(path);
          const hash = createHash('sha256').update(source).digest('hex');
          if (hash !== previous) {
            const reply = await deployer!.deploy(source);
            output({...reply, source_sha256:hash});
            // Reject invalid edits once; retry connection failures on the next pass.
            previous = hash;
            if (!reply.ok && command === 'deploy') process.exitCode = 1;
          }
        } catch (error) {
          if (command === 'deploy' || error instanceof RconOutcomeUnknown) throw error;
          process.stderr.write(`watch: ${String(error)}\n`);
        }
        if (command === 'watch' && !stopping) await delay(500);
      } while (command === 'watch' && !stopping);
    } else if (command === 'stream') {
      const lines = createInterface({input:process.stdin, crlfDelay:Infinity});
      for await (const line of lines) {
        if (stopping) break;
        if (!line.trim()) continue;
        try {
          const request = object(JSON.parse(line),'request');
          if (typeof request.action !== 'string') throw new Error('action must be a string');
          if (request.id !== undefined && typeof request.id !== 'string') throw new Error('id must be a string');
          output(await execute(request.action, object(request.args ?? {},'args'),request.id as string | undefined));
        } catch (error) { output({ok:false,error:{code:'client_error',message:String(error)}}); }
      }
    } else if (command === 'run') {
      if (!values.file) throw new Error('run requires --file plan.json');
      const plan: unknown = JSON.parse(await readFile(values.file,'utf8'));
      if (!Array.isArray(plan) || plan.length > 1000) throw new Error('Plan must be an array of at most 1000 requests');
      // Validate the whole shape before executing any effects.
      const steps = plan.map((value,index) => {
        const step = object(value,`step ${index}`);
        if (typeof step.action !== 'string' || (step.id !== undefined && typeof step.id !== 'string')) throw new Error(`Invalid step ${index}`);
        return {action:step.action, args:object(step.args ?? {},'args'), id:step.id as string | undefined};
      });
      for (const [index,step] of steps.entries()) {
        if (stopping) break;
        const reply = await execute(step.action,step.args,step.id,true);
        output({step:index,...reply});
        if (exitCode(reply)) {setExit(reply); break;}
      }
    } else if (command === 'view') {
      if (!values.out) throw new Error('view requires --out path.png');
      for (const word of positionals.slice(1)) {
        if (!word.startsWith('platform=') || !word.slice(9)) throw new Error('view accepts platform=NAME and --args JSON');
        if (args.platform !== undefined) throw new Error('view platform was given twice');
        args.platform=word.slice(9);
      }
      const reply = await execute('observe',{radius:24,...args,tiles:true,resources:'tiles'});
      if (reply.ok) {
        const path = resolve(values.out);
        await mkdir(dirname(path),{recursive:true});
        await writeFile(path,renderMap(reply.result,Number(args.radius ?? 24)));
        output({ok:true,tick:reply.tick,result:{path,kind:reply.result.platform ? 'platform-schematic' : 'local-schematic',platform:reply.result.platform,legend:reply.result.platform ? 'gray=foundation, dark=space/footprint edges, gold=belts/inserters, teal=machines, blue=solar/ghosts, purple=accumulators/thrusters, red=turrets, green=collectors, pale=hub, steel=pipes' : 'white=player, blue=iron/water, orange=copper, dark=coal, green=trees/uranium, red=enemies, tan=structures',position:reply.result.position ?? reply.result.player?.position,entities:Object.keys(reply.result.entities ?? {}).length,tiles:reply.result.tile_count ?? Object.keys(reply.result.tiles ?? {}).length,truncated:reply.result.truncated ?? false,tiles_truncated:reply.result.tiles_truncated ?? false}});
      } else {output(reply);process.exitCode=1;}
    } else if (command === 'sleep') {
      if (bridged) throw new Error('sleep needs the harness mod (not a bridge session)');
      const seconds = Number(positionals[1]);
      if (!Number.isSafeInteger(seconds) || seconds < 1 || seconds > 900) throw new Error('sleep requires SECONDS 1..900');
      const then = thenCall(values.then, positionals[2], values.args);
      const reply = await sleep(seconds, untilEvent(values.until));
      output(await withThen(reply, then));
      if (!reply.ok) process.exitCode=1;
    } else if (command === 'wait' && (values.until === undefined || /^\s*idle\s*$/.test(values.until)) && values.max !== undefined) {
      // fh wait --max S, fh wait --until idle --max S: the action (and combat) to end, at most S s; at once when idle.
      if (bridged) throw new Error('wait needs the harness mod (not a bridge session)');
      const max = integer(values.max, 600);
      if (max > 900) throw new Error('wait --max takes 1..900 seconds');
      const reply = await waitForIdle(max*1000);
      output(reply);
      setExit(reply);
    } else if (command === 'wait' && values.until !== undefined && /^\s*idle\s*$/.test(values.until)) {
      if (bridged) throw new Error('wait needs the harness mod (not a bridge session)');
      const reply = await waitForIdle();
      output(reply);
      setExit(reply);
    } else if (command === 'wait' && (values.until !== undefined || values.max !== undefined)) {
      if (bridged) throw new Error('wait needs the harness mod (not a bridge session)');
      const max = integer(values.max, 600);
      if (max > 900) throw new Error('wait --max takes 1..900 seconds');
      const then = thenCall(values.then, positionals[1], values.args);
      const reply = await sleep(max, untilEvent(values.until), true);
      // An older runtime delivered the team block with the sleep (full): the line, then the whole reply.
      if (reply.ok && outputFormat === 'compact' && !reply.result?.full) {
        process.stdout.write(operatorHead() + wakeLine(reply) + '\n');
        const read = await withThen(reply, then);
        if (read.result?.then_read) output({ok:true, tick:read.tick, result:read.result.then_read});
        else if (read.result?.then_skipped) process.stdout.write(`then: ${read.result.then_skipped}\n`);
      }
      else output(await withThen(reply.ok ? {...reply, result:{...reply.result, line:wakeLine(reply)}} : reply, then));
      if (!reply.ok) process.exitCode=1;
    } else if (command === 'wait') {
      if (bridged) throw new Error('wait needs the harness mod (not a bridge session)');
      const reply = await waitForIdle();
      output(reply);
      setExit(reply);
    } else if (command === 'doctor' && bridged) {
      const bridge = await execute('bridge_status',{});
      const player = bridge.ok && bridge.result?.in_game ? await execute('observe',{}) : undefined;
      const ready = bridge.ok && player?.ok === true && player.result?.player?.character === true;
      output({ok:ready,result:{bridge:bridge.result,player:player?.result?.player},
        ...(ready ? {} : {error:bridge.error ?? player?.error ?? {code:'player_not_ready',message:bridge.result?.in_game ? 'The player has no character (dead, spectating, or in a cutscene)' : 'The client is not in a multiplayer game'}})});
      if (!ready) process.exitCode=1;
    } else if (command === 'help') {
      const reply = await helpDescribe();
      if (!reply.ok) { output(reply); process.exitCode=1; }
      else {
        const dir = refDir(), topic = dir ? commandTopics(dir).get(positionals[1] ?? '') : undefined;
        process.stdout.write(actionHelp(reply.result, positionals[1] ?? '') + (topic && topic !== 'core' ? `documented in: ./fh help ${topic}\n` : ''));
      }
    } else if (command === 'doctor') {
      const runtime = await execute('describe',{});
      const player = runtime.ok ? await execute('status',{}) : undefined;
      const fault = runtime.result?.runtime_fault || player?.result?.runtime_fault;
      const ready = runtime.ok && player?.ok === true && player.result?.supported_control === true && !fault;
      output({ok:ready,result:{runtime:runtime.result,player:player?.result},
        ...(ready ? {} : {error:player?.error ?? runtime.error ?? (fault ? {code:'runtime_fault',message:fault.message} : undefined) ?? {code:'player_not_ready',message:player?.result?.control_error ?? 'Join the server with a living player character'}})});
      if (!ready) process.exitCode=1;
    } else {
      const action = command === 'call' ? positionals[1] : command;
      if (!action) throw new Error('call requires an action; use fh describe');
      // A long wait shows its acceptance first, so an interrupted client still
      // saw what the game took on (compact output only; JSON stays one reply).
      const reply = await execute(action,args,values.id,values.wait,
        outputFormat === 'compact' ? accepted => output({...accepted, waiting:`until completion (poll status if interrupted)`,
          // The completion carries the clock line.
          ...(compactWaits && accepted.result ? {result:{...accepted.result, clock:undefined}} : {})}) : undefined);
      // The look-ahead: fh call lookahead with the time left in the shift; on any other reply when it is due.
      // An argument refusal or an unknown action names the reference topic of the call (host/reference.ts).
      addReference(reply, action);
      if (action === 'lookahead' && reply.ok && reply.result) reply.result = {lines:lookaheadLines(reply.result)};
      else await addLookahead(reply, action, args);
      addPoll(reply, action, args);
      if (reply.ok && action === 'blueprint_export' && !args.layout && values.out) {
        await mkdir(dirname(resolve(values.out)),{recursive:true});
        await writeFile(values.out,reply.result.blueprint+'\n');
        output({...reply,result:{...reply.result,blueprint:undefined,path:resolve(values.out)}});
      } else output(reply);
      setExit(reply);
    }
  } finally {
    client.close();
    process.removeListener('SIGINT',stop); process.removeListener('SIGTERM',stop);
  }
}
main().catch(error => {
  output({ok:false,error:transportError(error) ?? {code:'client_error',message:error instanceof Error ? error.message : String(error)}});
  process.exitCode=1;
});
