import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, execFile } from 'node:child_process';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { promisify } from 'node:util';
const exec = promisify(execFile);
// The d17 batch18 Lua contract.
test('Lua contract: tests/d17_batch18.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch18.lua'], { stdio: 'pipe' });
});
test('Lua contract through the runtime: tests/d17_batch18_rt.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d17_batch18_rt.lua'], { stdio: 'pipe' });
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

test('A3: a place_ghosts dry run that fails exits 1; one that passes exits 0', async () => {
  let ok = false;
  await engine(() => ({ok:true, result:{dry_run:true, dry_run_ok:ok, verdict:ok ? 'ok' : 'fails: 1 setting refused'}}), async port => {
    await assert.rejects(cli(port, ['call', 'place_ghosts', '--args', '{"dry_run":true,"entities":[]}']), (e: any) => e.code === 1 && /fails: 1 setting refused/.test(e.stdout));
    ok = true;
    await cli(port, ['call', 'place_ghosts', '--args', '{"dry_run":true,"entities":[]}']);
  });
});
