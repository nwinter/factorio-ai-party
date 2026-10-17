import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, execFile } from 'node:child_process';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { promisify } from 'node:util';
const exec = promisify(execFile);
// The d17 batch11 Lua contract.
test('Lua contract: tests/d17_batch11.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch11.lua'], { stdio: 'pipe' });
});
async function engine(reply: (request: any) => any, run: (port: number) => Promise<void>) {
  const sockets = new Set<Socket>();
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
          body = JSON.stringify({id:request.id, tick:1000, ...reply(request)});
        }
        const out = Buffer.alloc(Buffer.byteLength(body) + 14);
        out.writeInt32LE(out.length - 4, 0); out.writeInt32LE(id, 4); out.writeInt32LE(kind === 3 ? 2 : 0, 8); out.write(body, 12);
        socket.write(out);
      }
    });
  }).listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address(); assert(address && typeof address !== 'string');
  try { await run(address.port); }
  finally { for (const socket of sockets) socket.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); }
}
const cli = (port: number, args: string[]) =>
  exec(process.execPath, ['dist/host/cli.js', '--format', 'json', '--port', String(port), ...args], {env:{...process.env, FACTORIO_RCON_PASSWORD:'test-only'}});

test('--then refuses platform_bom with request (A6: it sets the hub\'s requests) and takes it as a read', async () => {
  const seen: any[] = [];
  await engine(request => {
    seen.push(request);
    if (request.action === 'sleep') return {ok:true, result:{until_tick:1300}};
    if (request.action === 'platform_bom') return {ok:true, result:{lines:['ok']}};
    return {ok:true, result:{woke:'condition', until_tick:1300}};
  }, async port => {
    await assert.rejects(cli(port, ['sleep', '5', '--then', 'platform_bom', '{"platform":"Meridian","request":true}']),
      (e: any) => /--then takes platform_bom as a read: request sets the hub's requests/.test(e.stdout + e.stderr));
    assert.equal(seen.length, 0);
    await cli(port, ['sleep', '5', '--then', 'platform_bom', '{"platform":"Meridian"}']);
    assert.ok(seen.some(r => r.action === 'platform_bom'));
  });
});
