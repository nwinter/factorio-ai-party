import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server, type Socket } from 'node:net';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import { BridgeClient, BridgeOutcomeUnknown, BridgeUnavailable } from '../host/bridge.js';
import { connectSession, parseServerAddress } from '../host/session.js';

/** A fake bridge: answers each JSON line with whatever the handler returns. */
async function fakeBridge(handler: (request: any, socket: Socket) => unknown): Promise<{path: string; server: Server; close(): Promise<void>}> {
  await mkdir('.cache', {recursive:true});
  const folder = await mkdtemp(resolve('.cache/bridge-'));
  const path = resolve(folder, 'bridge.sock');
  const server = createServer(socket => {
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      buffer += chunk;
      let newline: number;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const reply = handler(JSON.parse(buffer.slice(0, newline)), socket);
        buffer = buffer.slice(newline + 1);
        if (reply !== undefined) socket.write(JSON.stringify(reply) + '\n');
      }
    });
  });
  await new Promise<void>(done => server.listen(path, done));
  return {path, server, async close() {
    await new Promise<void>(done => server.close(() => done()));
    await rm(folder, {recursive:true, force:true});
  }};
}

test('bridge requests carry the caller ID and resolve out-of-order replies by ID', async () => {
  const pending: Array<{request: any; socket: Socket}> = [];
  const bridge = await fakeBridge((request, socket) => { pending.push({request, socket}); return undefined; });
  const client = new BridgeClient(bridge.path, 2000);
  try {
    const first = client.request('observe', {radius:3}, 'first');
    const second = client.request('walk', {direction:'east'}, 'second');
    while (pending.length < 2) await new Promise(done => setTimeout(done, 5));
    assert.deepEqual(pending.map(p => p.request), [
      {id:'first', action:'observe', args:{radius:3}}, {id:'second', action:'walk', args:{direction:'east'}}]);
    // Answer in reverse order, plus a stray reply that matches nobody.
    for (const {request, socket} of [...pending].reverse()) socket.write(JSON.stringify({id:request.id, ok:true, result:request.action}) + '\n');
    pending[0]!.socket.write('{"id":"nobody","ok":true}\n');
    assert.equal((await first).result, 'observe');
    assert.equal((await second).result, 'walk');
  } finally { client.close(); await bridge.close(); }
});

test('bridge timeouts and dropped connections report unknown outcomes, never replay', async () => {
  let received = 0;
  const bridge = await fakeBridge((request, socket) => {
    received++;
    if (request.action === 'drop') socket.destroy();
    return undefined;
  });
  const client = new BridgeClient(bridge.path, 200);
  try {
    await assert.rejects(client.request('craft', {recipe:'iron-gear-wheel'}, 'slow'), BridgeOutcomeUnknown);
    await assert.rejects(client.request('drop', {}, 'dropped'), BridgeOutcomeUnknown);
    assert.equal(received, 2);
  } finally { client.close(); await bridge.close(); }
});

test('a missing bridge socket is unavailable rather than an unknown outcome', async () => {
  const client = new BridgeClient(resolve('.cache/no-such-bridge.sock'), 200);
  await assert.rejects(client.request('observe'), BridgeUnavailable);
});

test('duplicate in-flight IDs are rejected before sending', async () => {
  const bridge = await fakeBridge(() => undefined);
  const client = new BridgeClient(bridge.path, 300);
  try {
    const first = client.request('observe', {}, 'same').catch(error => error);
    await assert.rejects(client.request('observe', {}, 'same'), /already in flight/);
    assert(await first instanceof BridgeOutcomeUnknown);
  } finally { client.close(); await bridge.close(); }
});

test('bridge journal records requests and responses', async () => {
  const bridge = await fakeBridge(request => ({id:request.id, ok:true, tick:7, result:{}}));
  const journal = resolve('.cache', `bridge-journal-${process.pid}.jsonl`);
  const client = new BridgeClient(bridge.path, 2000, journal);
  try {
    await client.request('stop', {}, 'journaled');
    const events = (await readFile(journal, 'utf8')).trim().split('\n').map(line => JSON.parse(line).event);
    assert.deepEqual(events, ['request', 'response']);
  } finally { client.close(); await bridge.close(); await rm(journal, {force:true}); }
});

test('server addresses must be HOST:PORT before any launch', async () => {
  for (const good of ['203.0.113.5:34197', 'factorio.example.com:34197', '[2001:db8::1]:34197']) assert.equal(parseServerAddress(good), good);
  for (const bad of ['203.0.113.5', 'host:0', 'host:65536', 'host:port', '2001:db8::1:34197', '-o ProxyCommand=x:1', '-host:1', 'a b:1', '']) {
    assert.throws(() => parseServerAddress(bad), /HOST:PORT/, bad);
  }
  await assert.rejects(connectSession({name:'../escape', server:'127.0.0.1:34197'}), /slug/);
  await assert.rejects(connectSession({name:'ok', server:'not an address'}), /HOST:PORT/);
});
