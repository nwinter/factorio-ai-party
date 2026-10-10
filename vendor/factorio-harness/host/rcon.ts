/** Factorio returns one arbitrarily large framed response per command.
 * It does not implement Source's RESPONSE_VALUE delimiter trick.
 * https://forums.factorio.com/viewtopic.php?t=86598
 */
import { createConnection, type Socket } from "node:net";

export class RconError extends Error {}
export class RconUnavailable extends RconError {}
export class RconProtocolError extends RconError {}
/** Sending may have succeeded. Inspect state before retrying a mutation. */
export class RconOutcomeUnknown extends RconError {}

export interface RconOptions {
  host?: string;
  port?: number;
  password?: string;
  timeoutMs?: number;
}

const MAX_PACKET_BYTES = 16 * 1024 * 1024;

function packet(id: number, kind: number, text: string): Buffer {
  if (typeof text !== "string" || text.includes("\0")) {
    throw new TypeError("RCON text must be a string without NUL");
  }
  const size = Buffer.byteLength(text) + 10;
  if (size > MAX_PACKET_BYTES) throw new RangeError("RCON packet too large");
  const result = Buffer.alloc(size + 4);
  result.writeInt32LE(size, 0);
  result.writeInt32LE(id, 4);
  result.writeInt32LE(kind, 8);
  result.write(text, 12, "utf8");
  return result;
}

type Frame = { id: number; kind: number; body: Buffer };
type Pending = {
  accept: (frame: Frame) => boolean;
  resolve: (frame: Frame) => void;
  reject: (error: Error) => void;
};

/** One command at a time. A failed connection is replaced on the next call,
 * never by replaying the command whose outcome was lost.
 */
export class RconClient {
  private readonly options: Required<RconOptions>;
  private socket?: Socket;
  private header = Buffer.alloc(4);
  private headerBytes = 0;
  private incoming?: Buffer;
  private incomingBytes = 0;
  private pending?: Pending;
  private queue: Promise<unknown> = Promise.resolve();
  private sequence = 0;
  private closed = false;

  constructor(options: RconOptions = {}) {
    this.options = {
      host: options.host ?? "127.0.0.1",
      port: options.port ?? 27015,
      password: options.password ?? "",
      timeoutMs: options.timeoutMs ?? 5000,
    };
    if (!Number.isFinite(this.options.timeoutMs) || this.options.timeoutMs <= 0 || this.options.timeoutMs > 0x7fffffff) {
      throw new RangeError("timeoutMs must be positive and at most 2147483647");
    }
    if (!Number.isInteger(this.options.port) || this.options.port < 1 || this.options.port > 65535) {
      throw new RangeError("port must be between 1 and 65535");
    }
    packet(1, 3, this.options.password);
  }

  private nextId(): number {
    this.sequence = (this.sequence % 0x7fffffff) + 1;
    return this.sequence;
  }

  private fail(error: Error): void {
    const pending = this.pending;
    this.pending = undefined;
    const socket = this.socket;
    this.socket = undefined;
    this.headerBytes = 0;
    this.incoming = undefined;
    this.incomingBytes = 0;
    socket?.destroy();
    pending?.reject(error);
  }

  private receive(data: Buffer): void {
    try {
      let offset = 0;
      while (offset < data.length) {
        if (!this.incoming) {
          const count = Math.min(4 - this.headerBytes, data.length - offset);
          data.copy(this.header, this.headerBytes, offset, offset + count);
          this.headerBytes += count;
          offset += count;
          if (this.headerBytes < 4) return;
          const size = this.header.readInt32LE(0);
          if (size < 10 || size > MAX_PACKET_BYTES) {
            throw new RconProtocolError("RCON packet length outside allowed bounds");
          }
          this.incoming = Buffer.allocUnsafe(size);
          this.incomingBytes = 0;
          this.headerBytes = 0;
        }
        const count = Math.min(this.incoming.length - this.incomingBytes, data.length - offset);
        data.copy(this.incoming, this.incomingBytes, offset, offset + count);
        this.incomingBytes += count;
        offset += count;
        if (this.incomingBytes < this.incoming.length) return;
        const bytes = this.incoming;
        const size = bytes.length;
        this.incoming = undefined;
        this.incomingBytes = 0;
        if (bytes[size - 1] !== 0 || bytes[size - 2] !== 0 || bytes.subarray(8, size - 2).includes(0)) {
          throw new RconProtocolError("Invalid RCON string terminators");
        }
        const frame = { id: bytes.readInt32LE(0), kind: bytes.readInt32LE(4), body: bytes.subarray(8, size - 2) };
        const pending = this.pending;
        if (!pending) throw new RconProtocolError("Unsolicited RCON response");
        if (pending.accept(frame)) {
          this.pending = undefined;
          pending.resolve(frame);
        }
      }
    } catch (error) {
      this.fail(error instanceof Error ? error : new RconProtocolError(String(error)));
    }
  }

  private exchange(request: Buffer, accept: Pending["accept"]): Promise<Frame> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail(new Error("RCON exchange timed out")), this.options.timeoutMs);
      this.pending = {
        accept,
        resolve: (frame) => { clearTimeout(timer); resolve(frame); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      };
      try {
        if (!this.socket) throw new Error("RCON socket is not connected");
        const socket = this.socket;
        socket.write(request, (error) => {
          if (error && this.socket === socket) this.fail(error);
        });
      } catch (error) {
        this.fail(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private async connect(): Promise<void> {
    try {
      const socket = createConnection({ host: this.options.host, port: this.options.port });
      this.socket = socket;
      socket.setNoDelay(true);
      socket.on("data", (data) => { if (this.socket === socket) this.receive(data); });
      socket.on("error", (error) => { if (this.socket === socket) this.fail(error); });
      socket.on("close", () => { if (this.socket === socket) this.fail(new Error("RCON connection closed")); });
      // Node queues writes until connected, so this deadline bounds connect+auth.
      const id = this.nextId();
      let seenPreamble = false;
      await this.exchange(packet(id, 3, this.options.password), (frame) => {
        if (!seenPreamble && frame.id === id && frame.kind === 0 && frame.body.length === 0) {
          seenPreamble = true;
          return false;
        }
        if (frame.kind === 2 && frame.id === -1) throw new RconUnavailable("RCON authentication rejected");
        if (frame.kind !== 2 || frame.id !== id || frame.body.length !== 0) {
          throw new RconProtocolError("Unexpected RCON authentication response");
        }
        return true;
      });
    } catch (error) {
      this.fail(error instanceof Error ? error : new Error(String(error)));
      if (error instanceof RconError) throw error;
      throw new RconUnavailable("Could not connect or authenticate with RCON", { cause: error });
    }
  }

  command(text: string): Promise<string> {
    // Validate now, before queuing or opening a connection.
    packet(1, 2, text);
    const operation = this.queue.then(async () => {
      if (this.closed) throw new RconUnavailable("RCON client is closed");
      if (!this.socket) await this.connect();
      const id = this.nextId();
      try {
        const frame = await this.exchange(packet(id, 2, text), (response) => {
          if (response.kind !== 0 || response.id !== id) {
            throw new RconProtocolError("Unexpected RCON command response");
          }
          return true;
        });
        return new TextDecoder("utf-8", { fatal: true }).decode(frame.body);
      } catch (error) {
        this.fail(error instanceof Error ? error : new Error(String(error)));
        throw new RconOutcomeUnknown("RCON command outcome unknown; command was not replayed", { cause: error });
      }
    });
    this.queue = operation.catch(() => undefined);
    return operation;
  }

  close(): void {
    this.closed = true;
    this.fail(new Error("RCON client closed"));
  }
}
