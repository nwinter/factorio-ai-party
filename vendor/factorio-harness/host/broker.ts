/** Transport through an RCON broker (pog tools/fh_broker.py): the broker holds the RCON password and listens on
 * one Unix socket per bot; it forwards only harness requests for that bot. The wire format is JSON lines:
 * {"command": "<the RCON command>"} in, {"ok": true, "text": "<the RCON reply>"} or
 * {"ok": false, "error": "...", "refused"?: true, "unknown"?: true} out, one exchange at a time.
 */
import { createConnection, type Socket } from 'node:net';
import { RconOutcomeUnknown, RconUnavailable, RconError } from './rcon.js';
import type { Transport } from './harness.js';

/** The broker would not forward this command (not a harness request, or another bot's). Nothing was sent. */
export class BrokerRefused extends RconError {}

const MAX_LINE_BYTES = 16 * 1024 * 1024;

export class BrokerTransport implements Transport {
  private socket?: Socket;
  private buffer = '';
  private waiting?: { resolve: (line: string) => void; reject: (error: Error) => void };
  private queue: Promise<unknown> = Promise.resolve();
  private closed = false;

  constructor(readonly path: string, readonly timeoutMs = 5000) {}

  private fail(error: Error): void {
    const waiting = this.waiting;
    this.waiting = undefined;
    this.socket?.destroy();
    this.socket = undefined;
    this.buffer = '';
    waiting?.reject(error);
  }

  private connect(): Promise<Socket> {
    if (this.socket && !this.socket.destroyed) return Promise.resolve(this.socket);
    return new Promise((resolve, reject) => {
      const socket = createConnection({ path: this.path });
      socket.setEncoding('utf8');
      socket.once('connect', () => { this.socket = socket; resolve(socket); });
      socket.on('error', error => {
        if (this.socket !== socket) reject(new RconUnavailable(`RCON broker socket ${this.path} is unavailable: ${error.message}`));
        else this.fail(error);
      });
      socket.on('close', () => { if (this.socket === socket) this.fail(new Error('RCON broker connection closed')); });
      socket.on('data', (chunk: string) => {
        if (this.socket !== socket) return;
        this.buffer += chunk;
        if (this.buffer.length > MAX_LINE_BYTES) { this.fail(new Error('RCON broker reply exceeds size limit')); return; }
        const end = this.buffer.indexOf('\n');
        if (end < 0) return;
        const line = this.buffer.slice(0, end);
        this.buffer = this.buffer.slice(end + 1);
        const waiting = this.waiting;
        this.waiting = undefined;
        waiting?.resolve(line);
      });
    });
  }

  command(text: string): Promise<string> {
    const operation = this.queue.then(async () => {
      if (this.closed) throw new RconUnavailable('RCON broker client is closed');
      const socket = await this.connect();
      let line: string;
      try {
        line = await new Promise<string>((resolve, reject) => {
          const timer = setTimeout(() => this.fail(new Error('RCON broker exchange timed out')), this.timeoutMs);
          this.waiting = { resolve: v => { clearTimeout(timer); resolve(v); }, reject: e => { clearTimeout(timer); reject(e); } };
          socket.write(JSON.stringify({ command: text }) + '\n');
        });
      } catch (error) {
        throw new RconOutcomeUnknown('RCON command outcome unknown; command was not replayed', { cause: error });
      }
      let reply: { ok?: boolean; text?: string; error?: string; refused?: boolean; unknown?: boolean };
      try { reply = JSON.parse(line); }
      catch { throw new RconOutcomeUnknown(`RCON broker sent invalid JSON: ${line.slice(0, 200)}`); }
      if (reply.ok && typeof reply.text === 'string') return reply.text;
      const message = `RCON broker: ${reply.error ?? 'no reply text'}`;
      if (reply.refused) throw new BrokerRefused(message);
      if (reply.unknown) throw new RconOutcomeUnknown(message);
      throw new RconUnavailable(message);
    });
    this.queue = operation.catch(() => undefined);
    return operation;
  }

  close(): void {
    this.closed = true;
    this.fail(new Error('RCON broker client closed'));
  }
}
