/** Client for the native bridge inside a Factorio multiplayer client.
 * The bridge speaks JSON lines over a private Unix socket and submits normal
 * player input through that client, so it works on servers we do not control.
 */
import { createConnection, type Socket } from 'node:net';
import { randomUUID } from 'node:crypto';
import { appendFile } from 'node:fs/promises';
import type { Reply } from './harness.js';

/** The request may have been executed. Inspect state before retrying a mutation. */
export class BridgeOutcomeUnknown extends Error {}
export class BridgeUnavailable extends Error {}

const MAX_LINE_BYTES = 16 * 1024 * 1024;

interface Pending { resolve: (reply: Reply) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }

/** One socket and the requests written to it; nothing carries over a reconnect. */
interface Connection { socket: Socket; buffer: string; pending: Map<string, Pending> }

export class BridgeClient {
  private connection?: Connection;
  private connecting?: Promise<Connection>;
  private closed = false;
  /** Reserved synchronously so concurrent callers cannot share an ID. */
  private readonly inFlight = new Set<string>();

  constructor(readonly path: string, readonly timeoutMs = 10_000, readonly journal?: string) {}

  async request(action: string, args: Record<string, unknown> = {}, id: string = randomUUID()): Promise<Reply> {
    if (this.closed) throw new BridgeUnavailable('Bridge client is closed');
    if (this.inFlight.has(id)) throw new Error(`Request ${id} is already in flight`);
    const request = { id, action, args };
    const line = JSON.stringify(request) + '\n';
    if (Buffer.byteLength(line) > 1048576) throw new Error('Request exceeds 1 MiB limit');
    this.inFlight.add(id);
    try { return await this.send(id, request, line); }
    finally { this.inFlight.delete(id); }
  }

  private async send(id: string, request: object, line: string): Promise<Reply> {
    await this.record({ event: 'request', request });
    const connection = await this.connect();
    const reply = await new Promise<Reply>((resolve, reject) => {
      const timer = setTimeout(() => {
        connection.pending.delete(id);
        reject(new BridgeOutcomeUnknown(`No reply to ${id} within ${this.timeoutMs} ms`));
      }, this.timeoutMs);
      connection.pending.set(id, { resolve, reject, timer });
      connection.socket.write(line);
    }).catch(async error => {
      await this.record({ event: 'transport_error', id, error: String(error) }).catch(() => {});
      throw error;
    });
    try { await this.record({ event: 'response', response: reply }); }
    catch (error) { reply.warnings = [...(reply.warnings ?? []), `Response received but journal write failed: ${String(error)}`]; }
    return reply;
  }

  /** Terminal: pending requests fail as outcome-unknown and new ones are refused. */
  close(): void {
    this.closed = true;
    const connection = this.connection;
    this.connection = undefined;
    if (connection) {
      connection.socket.destroy();
      fail(connection, new BridgeOutcomeUnknown('Bridge connection closed before a reply'));
    }
  }

  private connect(): Promise<Connection> {
    if (this.connection && !this.connection.socket.destroyed) return Promise.resolve(this.connection);
    this.connecting ??= new Promise<Connection>((resolve, reject) => {
      const connection: Connection = { socket: createConnection({ path: this.path }), buffer: '', pending: new Map() };
      const { socket } = connection;
      let established = false;
      socket.setEncoding('utf8');
      socket.once('connect', () => {
        established = true;
        this.connecting = undefined;
        if (this.closed) { socket.destroy(); reject(new BridgeUnavailable('Bridge client is closed')); return; }
        this.connection = connection;
        resolve(connection);
      });
      socket.on('error', error => {
        if (established) return;  // 'close' follows and fails this socket's requests
        this.connecting = undefined;
        reject(new BridgeUnavailable(`Bridge socket ${this.path} is unavailable: ${error.message}`));
      });
      socket.on('close', () => {
        if (this.connection === connection) this.connection = undefined;
        fail(connection, new BridgeOutcomeUnknown('Bridge connection closed before a reply'));
      });
      socket.on('data', (chunk: string) => receive(connection, chunk));
    });
    return this.connecting;
  }

  private async record(value: object): Promise<void> {
    if (this.journal) await appendFile(this.journal, JSON.stringify({ at: new Date().toISOString(), ...value }) + '\n', { mode: 0o600 });
  }
}

function receive(connection: Connection, chunk: string): void {
  connection.buffer += chunk;
  if (connection.buffer.length > MAX_LINE_BYTES) {
    connection.socket.destroy(new Error('Bridge reply exceeds size limit'));
    return;
  }
  let newline: number;
  while ((newline = connection.buffer.indexOf('\n')) >= 0) {
    const line = connection.buffer.slice(0, newline);
    connection.buffer = connection.buffer.slice(newline + 1);
    let reply: Reply;
    try { reply = JSON.parse(line); }
    catch { connection.socket.destroy(new Error('Bridge sent invalid JSON')); return; }
    const pending = typeof reply.id === 'string' ? connection.pending.get(reply.id) : undefined;
    // Replies without a known ID cannot be matched to a caller; drop them.
    if (!pending || typeof reply.ok !== 'boolean') continue;
    connection.pending.delete(reply.id!);
    clearTimeout(pending.timer);
    pending.resolve(reply);
  }
}

function fail(connection: Connection, error: Error): void {
  for (const [id, pending] of connection.pending) {
    clearTimeout(pending.timer);
    pending.reject(error);
    connection.pending.delete(id);
  }
}
