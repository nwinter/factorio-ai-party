#!/usr/bin/env node
import { readFile, writeFile, cp, mkdir } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';
import { createHash, randomUUID } from 'node:crypto';
import { RconClient, RconOutcomeUnknown } from './rcon.js';
import { Harness, type Reply } from './harness.js';
import { renderMap } from './view.js';
import { formatCompact, finalLine } from './format.js';
import { parseDeadline, deadlineText } from './deadline.js';
import { bundleRuntime } from './bundle.js';
import { startSession, stopSession, sessionConnection, connectSession, type SessionConnection } from './session.js';
import { BridgeClient, BridgeOutcomeUnknown } from './bridge.js';

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
  fh observe [--args '{"radius":24}']        Bounded local world state
  fh call ACTION [--args JSON] [--id ID]      Execute an action; keep ID on uncertain outcomes
  fh call walk --args '{"direction":"east","ticks":60}' --wait
  fh wait                                   Block until the character's current action (and combat) ends
  fh sleep SECONDS                          Let the game run up to 900 s; wakes early on damage, death or a mention
  fh view --out artifacts/map.png            Render a local schematic PNG, also works headless
  fh deploy [--file runtime.lua]             Validate and replace live Lua runtime
  fh watch [--file runtime.lua]              Deploy changed Lua; retain old code on invalid update
  fh blueprint import --file blueprint.txt   Import blueprint/book into a named slot
  fh blueprint export --out blueprint.txt    Export stored blueprint/book
  fh blueprint list|inspect|capture|place|copy|cut|paste --args JSON
  fh queue submit --file plan.json           Queue in-game execution; optional --args for mode
  fh queue status|edit|cancel|resume          Inspect/revise pending work; cancel controls immediately
  fh board [--args '{"mine":true}']          Team board (tasks, requests, claims, notes), newest first
  fh board post|update|events|request --args JSON   board_post, board_update, board_events, harness_request
  fh plan save NAME --file plan.json         Save a queue plan by name (yours, up to 50); plan run NAME submits it
  fh plan run|show|delete NAME, fh plan list Run (--args '{"mode":"replace"}'), inspect or delete saved plans
  fh say "text" [--aloud]                   Post in chat; or --text-file F, or stdin (fh say - <<'EOF' ... EOF)
  fh chat [--since SEQ] [--limit N] [--peek] Your unread messages (newest N; remaining=K are still unread), or all after SEQ
  fh confess "text"                         A line for the stream audience only (teammates never see it); input as for say
  fh tell NAME[,NAME]|team "text"           A line to teammates outside chat: their next reply's team block, wakes them; input as for say
  fh tells [--since SEQ]                    Tells you sent or received
  fh stream                                 JSON-lines requests in, replies out; one connection
  fh run --file plan.json                    Sequential actions, waits after each timed action

Options: --player N (default 1), --bot NAME (a bot instead of a player; FH_BOT), --host HOST, --port N, --timeout MS (default 5000; deploy/watch 60000),
         --session NAME (default: auto-use default session), --bridge-socket PATH (bridge without a session),
         --wait, --wait-timeout MS (default: until the action's own end tick, at least 30000), --journal PATH, --args-file PATH
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
function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a JSON object`);
  return value as Record<string, unknown>;
}
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
function output(value: unknown) {
  value = withDeadline(value);
  process.stdout.write(outputFormat === 'compact' ? formatCompact(value) : JSON.stringify(value) + '\n');
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
    wait:{type:'boolean'}, 'wait-timeout':{type:'string'},
    name:{type:'string'}, session:{type:'string'}, factorio:{type:'string'}, save:{type:'string'},
    headless:{type:'boolean'}, niri:{type:'boolean'}, 'space-age':{type:'boolean'}, bridge:{type:'boolean'}, server:{type:'string'},
    'password-file':{type:'string'}, 'player-data':{type:'string'}, 'bridge-socket':{type:'string'},
    full:{type:'boolean'}, since:{type:'string'}, limit:{type:'string'}, peek:{type:'boolean'}, aloud:{type:'boolean'},
    'text-file':{type:'string'}, 'deadline-file':{type:'string'},
  }});
  let command = positionals[0];
  if (!command || values.help || command === 'help') { process.stdout.write(help); return; }
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
    if (!['import','export','inspect','list','delete','capture','place','copy','cut','paste'].includes(operation)) throw new Error('Unknown blueprint operation');
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
  if (command === 'board') {
    const operation = positionals[1] ?? 'list';
    const actions: Record<string, string> = {list:'board', post:'board_post', update:'board_update', events:'board_events', request:'harness_request'};
    if (!actions[operation]) throw new Error('board expects list, post, update, events, or request');
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
  if (command === 'call' && (positionals[1] === 'say' || positionals[1] === 'confess') && (positionals.length > 2 || !values.args)) {
    command = positionals[1]!;
    positionals.splice(0, 2, command);
  }
  if (command === 'say' || command === 'confess' || command === 'tell') {
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
      if (command !== 'say') throw new Error(`--aloud applies to say; ${command === 'tell' ? 'a tell stays off the chat and the voice' : 'a confession always goes to the stream'}`);
      args.aloud = true;
    }
    values.args = JSON.stringify(args);
    positionals.splice(1, positionals.length - 1, command);
    command = 'call';
  }
  if (command === 'chat' || command === 'tells') { positionals.splice(1, positionals.length - 1, command); command = 'call'; }
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
  const known = new Set(['doctor','describe','observe','call','view','deploy','watch','stream','run','wait','sleep']);
  if (!known.has(command)) throw new Error(`Unknown command ${command}; use fh help`);
  // A bot is a script-driven character addressed by name (FH_BOT for wrappers).
  const bot = values.bot ?? (values.player ? undefined : process.env.FH_BOT || undefined);
  if (values.bot && values.player) throw new Error('Use --player or --bot, not both');
  if (bot !== undefined && !/^[a-z][a-z0-9_-]{0,15}$/.test(bot)) throw new Error('--bot must be a bot name ([a-z][a-z0-9_-]{0,15})');
  let connection: SessionConnection | undefined;
  if (values.session) {
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
  } else {
    let password = connection ? undefined : process.env.FACTORIO_RCON_PASSWORD;
    const passwordFile = connection?.passwordFile ?? process.env.FACTORIO_RCON_PASSWORD_FILE;
    if (!password && passwordFile) password = (await readFile(passwordFile,'utf8')).trimEnd();
    if (!password) throw new Error('Run fh start, select --session NAME, or set FACTORIO_RCON_PASSWORD_FILE');
    const rcon = new RconClient({host:connection?.host ?? values.host ?? process.env.FACTORIO_RCON_HOST, port:connection?.port ?? integer(values.port ?? process.env.FACTORIO_RCON_PORT,27015), password, timeoutMs:integer(values.timeout,deploying ? 60000 : 5000)});
    harness = deployer = new Harness(rcon, integer(values.player,connection?.player ?? 1), values.journal, bot);
    client = rcon;
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
  const successfulOutcomes = ['duration_elapsed','target_mined','repair_completed','arrived','arrived_near','path_built','collected','topped_up','nothing_to_do','constructed','fed','met'];
  // How long to wait: an explicit --wait-timeout, else until the action's own
  // end tick (at 60 ticks/s plus a margin), never less than 30 s nor more than 15 min.
  // ownEnd: the action's end tick already reflects --wait-timeout (wait_until), so
  // wait for that end plus a margin rather than racing it.
  function waitBudget(untilTick?: number, nowTick?: number, ownEnd = false): number {
    if (values['wait-timeout'] !== undefined && !ownEnd) return integer(values['wait-timeout'],30000);
    const remaining = untilTick !== undefined && nowTick !== undefined ? Math.max(0,untilTick-nowTick) : 0;
    return Math.min(ownEnd ? 960000 : 900000, Math.max(30000, Math.ceil(remaining/60*1000*1.25)+5000));
  }
  // A timed-out wait must not look like a finished action: no completion
  // snapshot, a still_running block, and an error that says what to do.
  function timedOut(action: string, status: Reply, waitedMs: number): Reply {
    const active = status.result?.active;
    const tick = status.tick ?? status.result?.tick;
    const left = active?.until_tick !== undefined && tick !== undefined ? Math.max(0,active.until_tick-tick) : undefined;
    const leftText = left !== undefined ? ` (up to ${Math.ceil(left/60)} s more, until tick ${active.until_tick})` : '';
    return {...status, ok:false,
      result:{timed_out:true, still_running:active ?? status.result?.combat ?? true, waited_ms:waitedMs, last:status.result?.last},
      error:{code:'wait_timeout', message:`${action} is STILL RUNNING: the wait gave up after ${Math.round(waitedMs/1000)} s but the action has not finished${leftText}. `+
        `A new character action would interrupt it. Keep waiting with 'fh wait', or check 'fh call status' (active) before doing anything else.`}};
  }
  // Poll less often while an action has time left: 100 ms near the end, at most 400 ms.
  // (At 100 ms flat, nine waiting agents sent ~20 status requests per second.)
  function pollDelay(status: Reply): number {
    const active = status.result?.active ?? status.result?.combat;
    const tick = status.tick ?? status.result?.tick;
    if (active?.until_tick === undefined || tick === undefined) return 250;
    return Math.min(400, Math.max(100, Math.round((active.until_tick - tick) / 60 * 1000 / 4)));
  }
  // Polls peek, so the team hints and chat trailer they would carry stay
  // pending for the one reply the agent sees. A runtime without peek gets
  // plain polls.
  let peekable = !bridged;
  async function poll(): Promise<Reply> {
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
    return {...fresh, ok:status.ok, ...(status.error ? {error:status.error} : {})};
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
    const last = shot ? status.result?.last_combat : status.result?.last;
    const player = self.ok ? self.result?.player : undefined;
    const result: Record<string, unknown> = {
      outcome: last?.outcome ?? (status.result?.active ? 'running' : 'idle'), action: shot ? 'shoot' : last?.kind,
      waited_s: Math.round((Date.now()-started)/100)/10,
      position: player?.position ?? status.result?.position,
      health: player && player.health < player.max_health ? `${Math.round(player.health)}/${Math.round(player.max_health)}` : undefined,
      inventory: before !== undefined && player ? inventoryChange(before, carried(player)) : undefined,
      ammo_used: shot ? last?.ammo_used : undefined,
      detail: last?.result, alive: status.result?.alive === false ? false : undefined,
      team: carrier.result?.team, clock: carrier.result?.clock, chat: carrier.result?.chat,
    };
    for (const key of Object.keys(result)) if (result[key] === undefined) delete result[key];
    return {...status, tick:carrier.tick ?? status.tick, result};
  }
  async function waitForAction(action: string, untilTick?: number, nowTick?: number, before?: unknown): Promise<Reply> {
    if (bridged) return waitForBridgeAction(action);
    const started = Date.now();
    const done = await waitForActionEnd(action, untilTick, nowTick, started);
    // A timeout or a failed poll is reported as it is.
    if (done.error?.code === 'wait_timeout' || (!done.ok && done.error?.code !== 'action_interrupted' && done.error?.code !== 'timed_out')) return done;
    return compactWaits ? brief(done, started, before, action) : finalReply(done);
  }
  async function waitForActionEnd(action: string, untilTick: number | undefined, nowTick: number | undefined, started: number): Promise<Reply> {
    const deadline = started+waitBudget(untilTick,nowTick,action === 'wait_until');
    while (!stopping && Date.now()<deadline) {
      const status = await poll();
      const active = action === 'shoot' ? status.result?.combat : status.result?.active;
      // active may report shooting when movement has already finished. A
      // transfer/refuel/rearm short of items waits for the hand-craft queue as
      // an active 'feed'; the radius tours run as 'gather'.
      const kinds = action === 'collect' || action === 'feed' ? ['gather'] : ['rearm','refuel'].includes(action) ? ['gather','feed'] : ['transfer','build'].includes(action) ? ['feed'] : [action];
      const stillRunning = active && (action === 'shoot' || kinds.includes(active.kind));
      if (!status.ok || !stillRunning) {
        const last = action === 'shoot' ? status.result?.last_combat : status.result?.last;
        if (status.ok && last?.outcome && !successfulOutcomes.includes(last.outcome)) {
          return {...status,ok:false,error:endedError(action,last)};
        }
        return status;
      }
      await delay(pollDelay(status));
    }
    if (stopping) throw new Error('Stopped waiting for action; inspect status. Game actions have a bounded tick duration.');
    // Still running is not a failure of the action, but it is not done either.
    return timedOut(action, await harness.request('status'), Date.now()-started);
  }
  // A timed action that hit its own limit says so first (timed_out), with the
  // condition a wait_until was still waiting for.
  function endedError(action: string, last: any) {
    if (last.outcome !== 'timed_out') return {code:'action_interrupted',message:`Control ended: ${last.outcome}`};
    const what = action === 'wait_until' ? `wait_until timed_out: ${last.condition ?? 'condition'} not met${last.saw !== undefined ? ` (saw ${JSON.stringify(last.saw)})` : ''}; `+
      `the timeout comes from --wait-timeout MS (up to 900000) or args.timeout ticks (up to 54000)` : `${action} timed_out at its own tick limit`;
    return {code:'timed_out',message:what};
  }
  // fh sleep: the game runs; poll the read-only sleep_check (peek: mentions
  // stay unread) about once a second, then read it once more normally so the
  // reply carries the team block with whatever woke the agent.
  async function sleep(seconds: number): Promise<Reply> {
    const started = await harness.request('sleep',{seconds});
    if (!started.ok) return started;
    const deadline = Date.now()+seconds*1250+10000;
    while (!stopping && Date.now()<deadline) {
      const check = await harness.request('sleep_check',{peek:true});
      if (!check.ok || check.result?.woke) break;
      await delay(1000);
    }
    if (stopping) throw new Error('Stopped sleeping; the game keeps running.');
    const final = await harness.request('sleep_check',{});
    if (final.ok && !final.result?.woke) return {...final, ok:false, error:{code:'timed_out',message:`sleep timed_out: the game advanced less than ${seconds} s in ${Math.round(seconds*1.25+10)} s of real time (paused or slow server)`}};
    if (final.ok && final.result?.woke === 'died') return {...final, ok:false, error:{code:'died',message:'your character died while sleeping'}};
    return final;
  }
  // fh wait: block until whatever the character is doing (and any combat) ends.
  async function waitForIdle(): Promise<Reply> {
    const started = Date.now();
    let first = await poll();
    if (!first.ok) return first;
    const untilTick = first.result?.active?.until_tick ?? first.result?.combat?.until_tick;
    const deadline = started+waitBudget(untilTick,first.tick ?? first.result?.tick);
    let status = first;
    while (!stopping && Date.now()<deadline) {
      if (!status.result?.active && !status.result?.combat) {
        const last = status.result?.last;
        const ok = !last?.outcome || successfulOutcomes.includes(last.outcome);
        const ended = {...status, ok, ...(ok ? {} : {error:endedError(last.kind ?? 'the action',last)})};
        if (compactWaits) return brief(ended, started);
        const full = await finalReply(ended);
        return {...full, result:{idle:true, last, last_combat:status.result?.last_combat, waited_ms:Date.now()-started,
          team:full.result?.team, clock:full.result?.clock, chat:full.result?.chat}};
      }
      await delay(pollDelay(status));
      status = await poll();
      if (!status.ok) return status;
    }
    if (stopping) throw new Error('Stopped waiting; inspect status.');
    return timedOut(status.result?.active?.kind ?? 'the action', status, Date.now()-started);
  }
  async function execute(action: string, args: Record<string,unknown>, id?: string, wait = false, onAccepted?: (reply: Reply) => void): Promise<Reply> {
    const requestId = id ?? randomUUID();
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
    let reply: Reply;
    try { reply = await harness.request(action,args,requestId); }
    catch (error) {
      if (error instanceof RconOutcomeUnknown || error instanceof BridgeOutcomeUnknown) {
        return {id:requestId, ok:false, error:{code:'outcome_unknown', message:error.message, recovery:'Inspect status/state. Retry only the same action, args, player and ID while the dedup cache retains it.'}};
      }
      throw error;
    }
    const waits = bridged ? ['walk','mine','build'].includes(action)
      : ['walk','move_to','build_path','construct','mine','shoot','pickup','repair','wait_until','wait_ticks'].includes(action) || (['collect','rearm','refuel','feed'].includes(action) && args.radius !== undefined)
        || (['transfer','rearm','refuel','build'].includes(action) && reply.result?.awaiting_craft !== undefined);
    if (wait && reply.ok && waits) {
      onAccepted?.(reply);
      const completion = await waitForAction(action, reply.result?.until_tick, reply.tick, before);
      if (completion.error?.code === 'wait_timeout') return {...reply, ok:false, result:{accepted:reply.result, ...completion.result}, error:completion.error};
      // Compact: the brief completion only (the acceptance was printed already when onAccepted is set).
      if (compactWaits && completion.error?.code !== undefined && completion.error.code !== 'action_interrupted') {
        return {...reply, ok:false, result:{accepted:reply.result}, error:completion.error};
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
        if (!reply.ok) {process.exitCode=1; break;}
      }
    } else if (command === 'view') {
      if (!values.out) throw new Error('view requires --out path.png');
      const reply = await execute('observe',{radius:24,...args,tiles:true,resources:'tiles'});
      if (reply.ok) {
        const path = resolve(values.out);
        await mkdir(dirname(path),{recursive:true});
        await writeFile(path,renderMap(reply.result,Number(args.radius ?? 24)));
        output({ok:true,tick:reply.tick,result:{path,kind:'local-schematic',legend:'white=player, blue=iron/water, orange=copper, dark=coal, green=trees/uranium, red=enemies, tan=structures',position:reply.result.player?.position,entities:Object.keys(reply.result.entities ?? {}).length,tiles:Object.keys(reply.result.tiles ?? {}).length,truncated:reply.result.truncated ?? false,tiles_truncated:reply.result.tiles_truncated ?? false}});
      } else {output(reply);process.exitCode=1;}
    } else if (command === 'sleep') {
      if (bridged) throw new Error('sleep needs the harness mod (not a bridge session)');
      const seconds = Number(positionals[1]);
      if (!Number.isSafeInteger(seconds) || seconds < 1 || seconds > 900) throw new Error('sleep requires SECONDS 1..900');
      const reply = await sleep(seconds);
      output(reply);
      if (!reply.ok) process.exitCode=1;
    } else if (command === 'wait') {
      if (bridged) throw new Error('wait needs the harness mod (not a bridge session)');
      const reply = await waitForIdle();
      output(reply);
      if (!reply.ok) process.exitCode=1;
    } else if (command === 'doctor' && bridged) {
      const bridge = await execute('bridge_status',{});
      const player = bridge.ok && bridge.result?.in_game ? await execute('observe',{}) : undefined;
      const ready = bridge.ok && player?.ok === true && player.result?.player?.character === true;
      output({ok:ready,result:{bridge:bridge.result,player:player?.result?.player},
        ...(ready ? {} : {error:bridge.error ?? player?.error ?? {code:'player_not_ready',message:bridge.result?.in_game ? 'The player has no character (dead, spectating, or in a cutscene)' : 'The client is not in a multiplayer game'}})});
      if (!ready) process.exitCode=1;
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
      if (reply.ok && action === 'blueprint_export' && !args.layout && values.out) {
        await mkdir(dirname(resolve(values.out)),{recursive:true});
        await writeFile(values.out,reply.result.blueprint+'\n');
        output({...reply,result:{...reply.result,blueprint:undefined,path:resolve(values.out)}});
      } else output(reply);
      if (!reply.ok) process.exitCode=1;
    }
  } finally {
    client.close();
    process.removeListener('SIGINT',stop); process.removeListener('SIGTERM',stop);
  }
}
main().catch(error => {
  output({ok:false,error:{code:error instanceof RconOutcomeUnknown || error instanceof BridgeOutcomeUnknown ? 'outcome_unknown' : 'client_error',message:error instanceof Error ? error.message : String(error)}});
  process.exitCode=1;
});
