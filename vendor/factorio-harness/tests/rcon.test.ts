import assert from "node:assert/strict";
import { createServer, type Socket } from "node:net";
import { test } from "node:test";
import { RconClient, RconOutcomeUnknown, RconProtocolError, RconUnavailable } from "../host/rcon.js";

function frame(id: number, type: number, text = ""): Buffer {
  const body = Buffer.from(text);
  const result = Buffer.alloc(body.length + 14);
  result.writeInt32LE(body.length + 10, 0);
  result.writeInt32LE(id, 4);
  result.writeInt32LE(type, 8);
  body.copy(result, 12);
  return result;
}

type Request = { id: number; type: number; text: string };
async function fixture(handle: (socket: Socket, request: Request) => void) {
  const sockets = new Set<Socket>();
  let connections = 0;
  const server = createServer((socket) => {
    connections++;
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    let data = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      data = Buffer.concat([data, chunk]);
      while (data.length >= 4 && data.length >= data.readInt32LE(0) + 4) {
        const length = data.readInt32LE(0) + 4;
        const packet = data.subarray(0, length);
        data = data.subarray(length);
        handle(socket, { id: packet.readInt32LE(4), type: packet.readInt32LE(8), text: packet.subarray(12, length - 2).toString() });
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return {
    client: new RconClient({ port: address.port, password: "secret", timeoutMs: 500 }),
    connections: () => connections,
    close: async () => {
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

function auth(socket: Socket, request: Request): boolean {
  if (request.type !== 3) return false;
  assert.equal(request.text, "secret");
  socket.write(frame(request.id, 2));
  return true;
}

test("auth preamble, fragmented headers and large UTF-8 response", async () => {
  const expected = "矿石🚂".repeat(20_000);
  const f = await fixture((socket, request) => {
    if (request.type === 3) {
      socket.write(Buffer.concat([frame(request.id, 0), frame(request.id, 2)]));
      return;
    }
    const reply = frame(request.id, 0, expected);
    socket.write(reply.subarray(0, 2));
    setImmediate(() => {
      socket.write(reply.subarray(2, 7));
      for (let i = 7; i < reply.length; i += 4093) socket.write(reply.subarray(i, i + 4093));
    });
  });
  try { assert.equal(await f.client.command("read"), expected); }
  finally { f.client.close(); await f.close(); }
});

test("concurrent callers serialize and reuse one authenticated connection", async () => {
  const seen: string[] = [];
  const f = await fixture((socket, request) => {
    if (auth(socket, request)) return;
    seen.push(request.text);
    setTimeout(() => socket.write(frame(request.id, 0, request.text)), 5);
  });
  try {
    assert.deepEqual(await Promise.all([f.client.command("one"), f.client.command("two")]), ["one", "two"]);
    assert.deepEqual(seen, ["one", "two"]);
    assert.equal(f.connections(), 1);
  } finally { f.client.close(); await f.close(); }
});

test("lost mutation is never replayed; next explicit command reconnects", async () => {
  const seen: string[] = [];
  const f = await fixture((socket, request) => {
    if (auth(socket, request)) return;
    seen.push(request.text);
    if (request.text === "mutate") socket.destroy();
    else socket.write(frame(request.id, 0, "state"));
  });
  try {
    await assert.rejects(f.client.command("mutate"), RconOutcomeUnknown);
    assert.equal(await f.client.command("inspect"), "state");
    assert.deepEqual(seen, ["mutate", "inspect"]);
    assert.equal(f.connections(), 2);
  } finally { f.client.close(); await f.close(); }
});

test("authentication denial is known to precede command execution", async () => {
  const f = await fixture((socket, request) => {
    assert.equal(request.type, 3);
    socket.write(frame(-1, 2));
  });
  try { await assert.rejects(f.client.command("mutate"), RconUnavailable); }
  finally { f.client.close(); await f.close(); }
});

for (const fault of ["negative length", "oversized", "wrong id", "bad terminator", "invalid utf8", "truncated"]) {
  test(`malformed reply: ${fault}`, async () => {
    const f = await fixture((socket, request) => {
      if (auth(socket, request)) return;
      const reply = frame(fault === "wrong id" ? request.id + 1 : request.id, 0, "ok");
      if (fault === "negative length") reply.writeInt32LE(-1, 0);
      if (fault === "oversized") reply.writeInt32LE(32 * 1024 * 1024, 0);
      if (fault === "bad terminator") reply[reply.length - 1] = 1;
      if (fault === "invalid utf8") reply[12] = 0xff;
      if (fault === "truncated") socket.end(reply.subarray(0, 8));
      else socket.write(reply);
    });
    try {
      await assert.rejects(f.client.command("mutate"), (error: unknown) => {
        assert.ok(error instanceof RconOutcomeUnknown);
        if (!["invalid utf8", "truncated"].includes(fault)) assert.ok(error.cause instanceof RconProtocolError);
        return true;
      });
    } finally { f.client.close(); await f.close(); }
  });
}

test("silent server times out without replay", async () => {
  const f = await fixture((socket, request) => { auth(socket, request); });
  try { await assert.rejects(f.client.command("mutate"), RconOutcomeUnknown); }
  finally { f.client.close(); await f.close(); }
});

test("reject invalid inputs before connection", () => {
  assert.throws(() => new RconClient({ timeoutMs: NaN }), RangeError);
  const client = new RconClient();
  assert.throws(() => client.command("bad\0command"), TypeError);
  client.close();
});

test("close cancels queued commands instead of reconnecting after shutdown", async () => {
  const seen: string[] = [];
  let received!: () => void;
  const firstReceived = new Promise<void>((resolve) => { received = resolve; });
  const f = await fixture((socket, request) => {
    if (auth(socket, request)) return;
    seen.push(request.text);
    received();
  });
  try {
    const first = f.client.command("first");
    const queued = f.client.command("queued");
    const firstRejected = assert.rejects(first, RconOutcomeUnknown);
    const queuedRejected = assert.rejects(queued, RconUnavailable);
    await firstReceived;
    f.client.close();
    await Promise.all([firstRejected, queuedRejected]);
    await assert.rejects(f.client.command("later"), RconUnavailable);
    assert.deepEqual(seen, ["first"]);
    assert.equal(f.connections(), 1);
  } finally { f.client.close(); await f.close(); }
});
