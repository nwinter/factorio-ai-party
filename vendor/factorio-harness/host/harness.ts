import { randomUUID } from 'node:crypto';
import { appendFile } from 'node:fs/promises';
import { RconOutcomeUnknown, RconUnavailable } from './rcon.js';

/** stampsWall: the transport adds the request's wall clock itself (the broker, tools/fh_broker.py: it refuses other
 * fields from its clients, and a resend must carry the first send's clock). */
export interface Transport { command(command: string): Promise<string>; readonly stampsWall?: boolean }
export interface Reply {
  id?: string;
  ok: boolean;
  tick?: number;
  result?: any;
  error?: any;
  warnings?: string[];
  /** The request was sent again with the same ID across a drop (requestRetrying). */
  retried?: {attempts: number, waited_s: number, first_error: string};
}
/** How long a request is retried across an RCON or broker drop (A1, shift24: Grok 3x, Luna 4x, Haiku 2x at 89h52-53
 * for about a minute): FH_RETRY_MS, default 90 s. The same ID each time: the game answers an ID it applied from its
 * record (the dedup window) and runs one it never got, so nothing is done twice. */
export function retryBudgetMs(): number {
  const n = Number(process.env.FH_RETRY_MS ?? 90000);
  return Number.isFinite(n) && n >= 0 ? n : 90000;
}
const RETRY_STEPS = [1000, 2000, 4000, 8000, 10000];
function retryable(error: unknown): boolean {
  if (error instanceof RconOutcomeUnknown) return true;
  // Nothing was sent: the connection or login failed. A rejected password is not a drop.
  return error instanceof RconUnavailable && !/authentication rejected|path is longer/i.test(error.message);
}

/** Lua long strings preserve JSON and UTF-8 without interpreting escape sequences. */
export function luaString(value: string): string {
  let equals = '';
  // A value ending in "]" (plus the level's "="s) would close the string early.
  while (value.includes(`]${equals}]`) || value.endsWith(`]${equals}`)) equals += '=';
  // Initial newline is discarded by Lua; adding our own preserves input-leading newlines.
  return `[${equals}[\n${value}]${equals}]`;
}

export function parseReply(text: string): Reply {
  let parsed: unknown;
  try { parsed = JSON.parse(text.trim()); }
  catch { throw new Error(`Invalid bridge response. Is agent-harness enabled? ${text.slice(0,500)}`); }
  if (!parsed || typeof parsed !== 'object' || typeof (parsed as Reply).ok !== 'boolean') {
    throw new Error('Bridge response is missing its ok field');
  }
  return parsed as Reply;
}

/** control.lua's install caps: worlds made before chunked installs take one
 * install of at most LEGACY_INSTALL_BYTES; current ones report install_limits. */
export const LEGACY_INSTALL_BYTES = 524288;
export const MAX_RUNTIME_BYTES = 8 * 1024 * 1024;
/** Split text into pieces of at most max UTF-8 bytes, never inside a character. */
export function utf8Chunks(text: string, max: number): string[] {
  const out: string[] = [];
  let start = 0, size = 0;
  for (let i = 0; i < text.length;) {
    const cp = text.codePointAt(i)!;
    const bytes = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    if (size + bytes > max) { out.push(text.slice(start, i)); start = i; size = 0; }
    size += bytes; i += cp > 0xffff ? 2 : 1;
  }
  out.push(text.slice(start));
  return out;
}

/** Read-only views the runtime serves through `observe`. */
const OBSERVE_SCOPES = new Set(['danger','pipe_gaps','belt_gaps','drill_sites','agriculture', 'map', 'nearest', 'craftable', 'scan', 'power', 'grid', 'rates', 'bottleneck', 'stock', 'platforms', 'labs', 'science', 'supply', 'sleep_check']);

/** A subagent's call (d15 trajectory analysis: Astra's helpers share its character, and 12-22% of its tells were shown
 * to whichever helper called next): Codex and Muse give each thread its id and the session's, equal for the main
 * thread. The request then carries helper=true and the runtime leaves the tells and mentions for the main session. */
export function helperThread(env: NodeJS.ProcessEnv = process.env): boolean {
  const pairs: Array<[string, string]> = [['CODEX_THREAD_ID', 'CODEX_SESSION_ID'], ['MUSE_THREAD_ID', 'MUSE_SESSION_ID']];
  for (const [thread, session] of pairs) {
    const t = env[thread], s = env[session];
    if (t && s && t !== s) return true;
  }
  return false;
}
let runtimeTakesHelper = true;

export class Harness {
  /** `bot` addresses a script-driven bot by name instead of a player. */
  constructor(readonly transport: Transport, readonly player = 1, readonly journal?: string, readonly bot?: string) {}

  async request(action: string, args: Record<string, unknown> = {}, id: string = randomUUID()): Promise<Reply> {
    if (!runtimeTakesHelper || !helperThread() || args.helper !== undefined) return this.requestRetrying(action, args, id);
    const reply = await this.requestRetrying(action, {...args, helper:true}, id);
    // A runtime from before helper refuses the argument: once, then never again in this process.
    if (!reply.ok && /unknown argument helper\b/.test(String(reply.error?.message ?? ''))) {
      runtimeTakesHelper = false;
      return this.requestOnce(action, args, randomUUID());
    }
    return reply;
  }

  /** requestOnce, sent again with the same ID across a drop for up to retryBudgetMs(). */
  async requestRetrying(action: string, args: Record<string, unknown> = {}, id: string = randomUUID()): Promise<Reply> {
    const started = Date.now();
    let first: unknown;
    for (let attempt = 0; ; attempt++) {
      try {
        // (d29 batch336 FL6) the wall clock goes in the envelope, once per ID: a resend must match the first send
        const reply = await this.requestOnce(action, args, id, started);
        if (attempt > 0) reply.retried = {attempts:attempt + 1, waited_s:Math.round((Date.now() - started) / 100) / 10, first_error:String(first instanceof Error ? first.message : first)};
        return reply;
      } catch (error) {
        if (!retryable(error)) throw error;
        first ??= error;
        const waited = Date.now() - started;
        const budget = retryBudgetMs();
        if (waited >= budget) throw error;
        await new Promise(done => setTimeout(done, Math.min(RETRY_STEPS[Math.min(attempt, RETRY_STEPS.length - 1)] ?? 10000, budget - waited)));
      }
    }
  }

  /** wall: the request's wall clock (ms since 1970) for the runtime, which has none (board review times). */
  async requestOnce(action: string, args: Record<string, unknown> = {}, id: string = randomUUID(), wall: number = Date.now()): Promise<Reply> {
    // Reuse the bootstrap's stable read-only operation. New observation views
    // must not be treated as mutations by a bootstrap already loaded in-game.
    if (OBSERVE_SCOPES.has(action)) { args = {...args, scope:action}; action = 'observe'; }
    const stamp = this.transport.stampsWall ? {} : {wall};
    const request = this.bot === undefined ? { id, action, player: this.player, args, ...stamp } : { id, action, bot: this.bot, args, ...stamp };
    const json = JSON.stringify(request);
    if (Buffer.byteLength(json) > 1048576) throw new Error('Request exceeds 1 MiB limit');
    await this.record({ event: 'request', request });
    let reply: Reply;
    try {
      const body = luaString(json);
      const raw = await this.transport.command(`/silent-command rcon.print(remote.call("agent_harness", "dispatch", ${body}))`);
      try {
        reply = parseReply(raw);
        if (reply.id !== id) throw new Error(`Bridge response ID mismatch for ${id}; do not replay with a new ID`);
      } catch (error) {
        throw new RconOutcomeUnknown(`Response could not be verified for ${id}: ${String(error)}`, {cause:error});
      }
    } catch (error) {
      await this.record({ event: 'transport_error', id, error: String(error) }).catch(() => {});
      throw error;
    }
    try { await this.record({ event: 'response', response: reply }); }
    catch (error) { reply.warnings = [...(reply.warnings ?? []), `Response received but journal write failed: ${String(error)}`]; }
    return reply;
  }

  /** One install call when the runtime fits every world's cap; otherwise
   * install_chunk calls and install_commit, which need a current control.lua. */
  async deploy(source: string): Promise<Reply> {
    const bytes = Buffer.byteLength(source);
    if (bytes <= LEGACY_INSTALL_BYTES) return this.install(`remote.call("agent_harness", "install", ${luaString(source)})`);
    const limits = await this.installLimits();
    if (!limits) throw new Error(`The runtime bundle is ${bytes} bytes, but this world's control.lua takes at most ${LEGACY_INSTALL_BYTES} bytes and has no chunked install. `+
      'Restart the world with the current agent-harness mod (control.lua changed; refresh client mod copies too), or shrink the runtime.');
    if (bytes > limits.max_bytes) throw new Error(`The runtime bundle is ${bytes} bytes; this world accepts at most ${limits.max_bytes}`);
    const id = randomUUID().slice(0, 8);
    // Leave room in each RCON command for the call around the chunk.
    const parts = utf8Chunks(source, limits.chunk_bytes - 64);
    for (const [index, part] of parts.entries()) {
      const reply = await this.install(`remote.call("agent_harness", "install_chunk", "${id}", ${index+1}, ${parts.length}, ${luaString(part)})`);
      if (!reply.ok) return reply;
    }
    const reply = await this.install(`remote.call("agent_harness", "install_commit", "${id}", ${bytes})`);
    return reply.ok ? {...reply, result:{...reply.result, chunks:parts.length}} : reply;
  }

  /** The world's install caps, or undefined for a control.lua without chunked installs. */
  async installLimits(): Promise<{max_bytes: number, chunk_bytes: number} | undefined> {
    const raw = await this.transport.command('/silent-command local i=remote.interfaces.agent_harness; rcon.print(i and i.install_limits and remote.call("agent_harness","install_limits") or "{}")');
    let parsed: any;
    try { parsed = JSON.parse(raw.trim()); } catch { throw new Error(`Could not read the world's install limits: ${raw.slice(0,200)}`); }
    return typeof parsed?.max_bytes === 'number' && typeof parsed?.chunk_bytes === 'number' ? parsed : undefined;
  }

  private async install(call: string): Promise<Reply> {
    const raw = await this.transport.command(`/silent-command rcon.print(${call})`);
    try { return parseReply(raw); }
    catch (error) { throw new RconOutcomeUnknown('Deployment response could not be verified; inspect the running runtime before redeploying', {cause:error}); }
  }

  private async record(value: object): Promise<void> {
    if (this.journal) await appendFile(this.journal, JSON.stringify({ at: new Date().toISOString(), ...value }) + '\n', { mode: 0o600 });
  }
}
