// d16 batch8 A1 (Grok 3x, Luna 4x, Haiku 2x at 89h52-53: a short RCON drop failed a call or a wait with
// outcome_unknown while the action went on): the host sends the request again with the same ID across a drop of up to
// FH_RETRY_MS; the game's answer to that ID is the one answer, and the reply says it was retried.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join } from 'node:path';
import { tempDir } from './tmp.js';

const exec = promisify(execFile);

// An RCON engine that drops the connection (no reply) on the first `drops` dispatches, then answers.
async function engine(drops: number, reply: (request: any) => any, run: (port: number, seen: string[]) => Promise<void>) {
  const sockets = new Set<Socket>();
  const seen: string[] = [];
  let left = drops;
  const server = createServer(socket => {
    sockets.add(socket); socket.on('close', () => sockets.delete(socket));
    let buffered = Buffer.alloc(0);
    socket.on('data', data => {
      buffered = Buffer.concat([buffered, data]);
      while (buffered.length >= 4 && buffered.length >= buffered.readInt32LE(0) + 4) {
        const size = buffered.readInt32LE(0), frame = buffered.subarray(4, size + 4);
        buffered = buffered.subarray(size + 4);
        const id = frame.readInt32LE(0), kind = frame.readInt32LE(4), text = frame.subarray(8, -2).toString();
        let body = '';
        if (kind === 2) {
          const match = text.match(/\n(\{.*\})\]\]/);
          assert(match, `bad dispatch: ${text}`);
          const request = JSON.parse(match[1]!);
          seen.push(request.id);
          if (left > 0) { left--; socket.destroy(); return; }
          body = JSON.stringify({id:request.id, tick:1, ...reply(request)});
        }
        const out = Buffer.alloc(Buffer.byteLength(body) + 14);
        out.writeInt32LE(out.length - 4, 0); out.writeInt32LE(id, 4); out.writeInt32LE(kind === 3 ? 2 : 0, 8); out.write(body, 12);
        socket.write(out);
      }
    });
  }).listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address(); assert(address && typeof address !== 'string');
  try { await run(address.port, seen); }
  finally { for (const socket of sockets) socket.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); }
}
const env = {...process.env, FACTORIO_RCON_PASSWORD:'test-only', FH_OPERATOR_FILE:'', FH_PROJECTS_FILE:''};
function cli(port: number, args: string[], extra: Record<string, string> = {}) {
  return exec(process.execPath, ['dist/host/cli.js', '--format', 'json', '--port', String(port), ...args], {env:{...env, ...extra}})
    .catch((e: any) => ({stdout:e.stdout as string, stderr:e.stderr as string}));
}

test('a call across a short drop is sent again with the same ID and answered once', async () => {
  const dir = await tempDir('fh-retry-');
  await engine(2, () => ({ok:true, result:{started:1}}), async (port, seen) => {
    const out = JSON.parse((await cli(port, ['call', 'craft', '--args', '{"recipe":"lab","count":1}', '--journal', join(dir, 'j.jsonl')], {FH_RETRY_MS:'20000'})).stdout);
    assert.equal(out.ok, true, JSON.stringify(out));
    assert.equal(seen.length, 3); assert.equal(new Set(seen).size, 1, 'the same ID each time');
    assert.match(out.result.retried, /^the game did not answer at first \(.*\); sent again with the same ID 2 times over [\d.]+ s: this is the game's one answer to it/);
  });
});

test('past the retry budget the call ends outcome_unknown, saying it was sent again', async () => {
  const dir = await tempDir('fh-retry-');
  await engine(100, () => ({ok:true, result:{}}), async port => {
    const out = JSON.parse((await cli(port, ['call', 'craft', '--args', '{"recipe":"lab","count":1}', '--journal', join(dir, 'j.jsonl')], {FH_RETRY_MS:'1500'})).stdout);
    assert.equal(out.ok, false);
    assert.equal(out.error.code, 'outcome_unknown');
    assert.match(out.error.recovery, /^fh sent it again with the same ID for 2 s without an answer/);
  });
});
