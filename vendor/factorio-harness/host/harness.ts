import { randomUUID } from 'node:crypto';
import { appendFile } from 'node:fs/promises';
import { RconOutcomeUnknown } from './rcon.js';

export interface Transport { command(command: string): Promise<string> }
export interface Reply {
  id?: string;
  ok: boolean;
  tick?: number;
  result?: any;
  error?: any;
  warnings?: string[];
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
const OBSERVE_SCOPES = new Set(['pipe_gaps','belt_gaps','drill_sites','agriculture', 'map', 'nearest', 'craftable', 'scan', 'power', 'grid', 'rates', 'bottleneck', 'stock', 'platforms', 'labs', 'science', 'supply', 'sleep_check']);

export class Harness {
  /** `bot` addresses a script-driven bot by name instead of a player. */
  constructor(readonly transport: Transport, readonly player = 1, readonly journal?: string, readonly bot?: string) {}

  async request(action: string, args: Record<string, unknown> = {}, id: string = randomUUID()): Promise<Reply> {
    // Reuse the bootstrap's stable read-only operation. New observation views
    // must not be treated as mutations by a bootstrap already loaded in-game.
    if (OBSERVE_SCOPES.has(action)) { args = {...args, scope:action}; action = 'observe'; }
    const request = this.bot === undefined ? { id, action, player: this.player, args } : { id, action, bot: this.bot, args };
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
