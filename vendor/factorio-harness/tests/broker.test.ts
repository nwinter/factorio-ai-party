import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { BrokerTransport, BrokerRefused } from '../host/broker.js';
import { Harness } from '../host/harness.js';
import { RconOutcomeUnknown, RconUnavailable } from '../host/rcon.js';

/** A fake RCON broker: answers each {"command"} line with whatever the handler returns. */
async function fakeBroker(handler: (command: string) => unknown): Promise<{path: string; server: Server; close(): Promise<void>}> {
  // A short folder: macOS caps a Unix socket path at 104 bytes, and a worktree's .cache can be deeper than that.
  const folder = await mkdtemp(join(tmpdir(), 'fhb-'));
  const path = join(folder, 'bot.sock');
  const server = createServer(socket => {
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      buffer += chunk;
      let newline: number;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const reply = handler(JSON.parse(buffer.slice(0, newline)).command);
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

test('harness requests go through the broker socket as the RCON command fh would send', async () => {
  const seen: string[] = [];
  const broker = await fakeBroker(command => {
    seen.push(command);
    const id = JSON.parse(command.slice(command.indexOf('[[\n') + 3, command.lastIndexOf(']]'))).id;
    return {ok:true, text:JSON.stringify({id, ok:true, tick:5, result:{n:seen.length}})};
  });
  const transport = new BrokerTransport(broker.path, 2000);
  try {
    const harness = new Harness(transport, 1, undefined, 'haiku');
    const first = await harness.request('status', {}, 'one');
    const second = await harness.request('walk', {direction:'east'}, 'two');
    assert.equal(first.result.n, 1); assert.equal(second.result.n, 2);
    assert.match(seen[0] ?? '', /^\/silent-command rcon\.print\(remote\.call\("agent_harness", "dispatch", \[\[\n\{"id":"one","action":"status","bot":"haiku","args":\{\}\}\]\]\)\)$/);
  } finally { transport.close(); await broker.close(); }
});

test('a refusal, an unknown outcome and a missing broker are told apart', async () => {
  const broker = await fakeBroker(command => command.includes('refuse') ? {ok:false, refused:true, error:'refused: not sol'}
    : command.includes('lost') ? {ok:false, unknown:true, error:'rcon: closed'} : undefined);
  const transport = new BrokerTransport(broker.path, 300);
  try {
    await assert.rejects(transport.command('refuse'), (e: Error) => e instanceof BrokerRefused && /not sol/.test(e.message));
    await assert.rejects(transport.command('lost'), RconOutcomeUnknown);
    await assert.rejects(transport.command('silence'), RconOutcomeUnknown);  // no reply: timed out
  } finally { transport.close(); await broker.close(); }
  await assert.rejects(new BrokerTransport(join(tmpdir(), 'fhb-none.sock'), 300).command('x'), RconUnavailable);
  await assert.rejects(new BrokerTransport(resolve('/tmp', 'x'.repeat(120), 'bot.sock'), 300).command('x'),
    (e: Error) => e instanceof RconUnavailable && /longer than the 103 bytes/.test(e.message));
});
