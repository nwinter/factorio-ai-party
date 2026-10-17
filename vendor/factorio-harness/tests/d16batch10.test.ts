import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, execFile } from 'node:child_process';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { readFileSync } from 'node:fs';
// The d16 batch10 contract: its Lua file, and fh sleep/wait --then and the replaced line (host/cli.ts).
const exec = promisify(execFile);

test('Lua contract: tests/d16_batch10.lua', () => {
  execFileSync(process.env.LUA_BIN ?? 'lua', ['tests/d16_batch10.lua'], { stdio: 'pipe' });
});

test('--then takes only actions runtime.lua counts as reads', () => {
  const cli = readFileSync('host/cli.ts', 'utf8');
  const runtime = readFileSync('mod/agent-harness_0.1.0/runtime.lua', 'utf8');
  const list = cli.match(/const THEN_READS = new Set\(\[([\s\S]*?)\]\)/);
  assert(list, 'THEN_READS in host/cli.ts');
  const names = [...list[1]!.matchAll(/'([a-z_]+)'/g)].map(m => m[1]!);
  const reads = runtime.match(/^local reads=\{(.*)\}$/m);
  assert(reads, 'local reads in runtime.lua');
  const known = new Set([...reads[1]!.matchAll(/(\w+)=true/g)].map(m => m[1]!));
  for (const m of runtime.matchAll(/^reads\.(\w+)=true/gm)) known.add(m[1]!);
  for (const name of names) assert(known.has(name), `${name} is not a read in runtime.lua`);
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

test('fh sleep --then runs one read when the sleep ends and returns it with the wake; a replaced sleep runs none', async () => {
  const seen: any[] = [];
  let until = 1300;
  await engine(request => {
    seen.push(request);
    if (request.action === 'sleep') return {ok:true, result:{until_tick:1300, sleeping_s:5}};
    // (sleep_check travels as observe {scope: sleep_check}: harness.ts)
    if (request.action === 'sleep_check' || request.args?.scope === 'sleep_check') return {ok:true, result:{woke:'condition', saw:'nutrients 40', until_tick:until, sleep_started_tick:1120, sleep_until:'item_count nutrients'}};
    if (request.action === 'inspect') return {ok:true, result:{name:'requester-chest', holds:'nutrients*40'}};
    if (request.action === 'observe') return {ok:true, result:{}};
    return {ok:false, error:{code:'action_failed', message:`unexpected ${request.action}`}};
  }, async port => {
    const {stdout} = await cli(port, ['sleep', '5', '--until', 'queue_done', '--then', 'inspect', '{"position":{"x":1,"y":2}}']);
    const reply = JSON.parse(stdout);
    assert.equal(reply.result.woke, 'condition');
    assert.deepEqual(reply.result.then_read, {action:'inspect', name:'requester-chest', holds:'nutrients*40'});
    assert.deepEqual(seen[0].args.condition, {until:'queue_done'});
    assert.deepEqual(seen.at(-1).args, {position:{x:1, y:2}});
    // A newer sleep replaced this one: named, and no read.
    seen.length = 0; until = 1500;
    const out = JSON.parse((await cli(port, ['sleep', '5', '--then', 'inspect {"position":{"x":1,"y":2}}'])).stdout);
    assert.equal(out.result.woke, 'replaced');
    assert.equal(out.result.note, 'replaced: a newer sleep began 2 s after this one (tick 1120), for 6 s until tick 1500, until item_count nutrients (a later fh sleep, fh wait --until or sleep call: one sleep per agent); that call reports its own wake, and this one ends here without one');
    assert.equal(out.result.then_skipped, '--then inspect not run: this sleep was replaced, and the newer call runs its own');
    assert(!seen.some(r => r.action === 'inspect'));
    // fh wait --until ... --then: the wake line, then the read.
    seen.length = 0; until = 1300;
    const waited = await exec(process.execPath, ['dist/host/cli.js', '--port', String(port), 'wait', '--until', 'queue_done', '--max', '5', '--then', 'inspect', '{"position":{"x":1,"y":2}}'],
      {env:{...process.env, FACTORIO_RCON_PASSWORD:'test-only'}});
    assert.match(waited.stdout, /^woke: condition after 0 s \(saw nutrients 40\)\n/);
    assert.match(waited.stdout, /holds: nutrients\*40/);
  });
});

test('--then refuses an action that changes the game, before sleeping; silo_parts and queue_done word forms', async () => {
  const seen: any[] = [];
  await engine(request => {
    seen.push(request);
    if (request.action === 'sleep') return {ok:true, result:{until_tick:1300}};
    return {ok:true, result:{woke:'condition', until_tick:1300}};  // (sleep_check, as observe {scope})
  }, async port => {
    await assert.rejects(cli(port, ['sleep', '5', '--then', 'transfer', '{"item":"coal"}']),
      (e: any) => /--then takes a read action \(inspect, observe, status, silo, trace, platforms, \.\.\.\), not transfer/.test(e.stdout + e.stderr));
    assert.equal(seen.length, 0);
    await cli(port, ['sleep', '5', '--until', 'silo_parts>=40 at 14.5,140.5']);
    assert.deepEqual(seen[0].args.condition, {until:'rocket_parts', at_least:40, position:{x:14.5, y:140.5}});
    seen.length = 0;
    await cli(port, ['sleep', '5', '--until', 'rocket_parts at 14.5,140.5']);
    assert.deepEqual(seen[0].args.condition, {until:'rocket_parts', position:{x:14.5, y:140.5}});
  });
});
