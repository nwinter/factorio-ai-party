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
  while (value.includes(`]${equals}]`)) equals += '=';
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

/** Read-only views the runtime serves through `observe`. */
const OBSERVE_SCOPES = new Set(['map', 'nearest', 'craftable', 'scan', 'power', 'grid', 'rates', 'bottleneck', 'stock', 'platforms']);

export class Harness {
  constructor(readonly transport: Transport, readonly player = 1, readonly journal?: string) {}

  async request(action: string, args: Record<string, unknown> = {}, id: string = randomUUID()): Promise<Reply> {
    // Reuse the bootstrap's stable read-only operation. New observation views
    // must not be treated as mutations by a bootstrap already loaded in-game.
    if (OBSERVE_SCOPES.has(action)) { args = {...args, scope:action}; action = 'observe'; }
    const request = { id, action, player: this.player, args };
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

  async deploy(source: string): Promise<Reply> {
    const raw = await this.transport.command(`/silent-command rcon.print(remote.call("agent_harness", "install", ${luaString(source)}))`);
    try { return parseReply(raw); }
    catch (error) { throw new RconOutcomeUnknown('Deployment response could not be verified; inspect the running runtime before redeploying', {cause:error}); }
  }

  private async record(value: object): Promise<void> {
    if (this.journal) await appendFile(this.journal, JSON.stringify({ at: new Date().toISOString(), ...value }) + '\n', { mode: 0o600 });
  }
}
