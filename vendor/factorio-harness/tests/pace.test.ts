// The game's pace (host/pace.ts; world n 13:41: a crash, a restart from the 13:35 autosave, then 7-10 ticks/s for ten
// minutes): speed between calls and on the clock line, sleeps and waits that go on while a slow game advances and end
// paused when it stops, a rollback said once with what to redo, an outage said while it lasts and when it ends.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { seeTick, seeDown, slowNote, Pacer, overtime, rolledBack, speedText, STALL_MS, clockTime, type PaceState } from '../host/pace.js';
const exec = promisify(execFile);

test('speed between calls, a rollback once, an outage while it lasts and when it ends', () => {
  const s: PaceState = {};
  const t0 = Date.parse('2026-10-14T13:30:00');
  assert.deepEqual(seeTick(s, 1000, t0), {});
  seeTick(s, 1060, t0+2000);                       // 2 s later: too soon to measure
  assert.equal(s.speed, undefined);
  seeTick(s, 1300, t0+10000);                      // 300 ticks in 10 s
  assert.equal(s.speed, 30);
  assert.equal(slowNote(s, t0+10000), 'game speed 30 ticks/s, 50% of normal');
  assert.equal(slowNote(s, t0+10000+181000), undefined, 'measured within the last 3 min only');
  seeTick(s, 1900, t0+20000);                      // back to 60 a second
  assert.equal(s.speed, 60); assert.equal(slowNote(s, t0+20000), undefined);
  // The server restarts from a save 5 game minutes back: said once.
  const seen = seeTick(s, 1900-18000, t0+60000);
  assert.deepEqual(seen.rollback, {from:1900, to:-16100, lastAt:t0+20000});
  assert.equal(seeTick(s, -16000, t0+62000).rollback, undefined, 'once');
  // Calls that cannot reach the game: since when; the first reply after: how long.
  assert.equal(seeDown(s, t0+70000, 'connect ECONNREFUSED'), `game unreachable since ${clockTime(t0+70000)} (0s)`);
  assert.equal(seeDown(s, t0+130000, 'connect ECONNREFUSED'), `game unreachable since ${clockTime(t0+70000)} (1m00s)`);
  const back = seeTick(s, -15000, t0+190000);
  assert.equal(back.outage, `the game was unreachable from ${clockTime(t0+70000)} to about ${clockTime(t0+190000)} (2m00s; the last failed call at ${clockTime(t0+130000)}: connect ECONNREFUSED)`);
  assert.equal(seeTick(s, -14700, t0+196000).outage, undefined, 'once');
  assert.equal(s.speed, 50, 'no speed across the outage: measured from the first reply after it');
});

test('a wait goes on while a slow game advances, ends paused when it stops, and stops at its cap', () => {
  const p = new Pacer();
  const t = 1_000_000;
  for (let i = 0; i <= 20; i++) p.see(1000 + i * 10, t + i * 1000);   // 10 ticks/s
  assert.equal(Math.round(p.speed()!), 10);
  assert.equal(speedText(p.speed()!), '10 ticks/s, 17% of normal');
  assert.equal(overtime(p, t + 30000, t + 60000, t + 20000), 'go', 'before its end');
  assert.equal(overtime(p, t + 10000, t + 60000, t + 20000), 'go', 'past its end, the game slow but moving');
  assert.equal(overtime(p, t + 10000, t + 19000, t + 20000), 'cap');
  // The tick stops: paused after STALL_MS.
  for (let i = 21; i <= 45; i++) p.see(1200, t + i * 1000);
  assert.equal(overtime(p, t + 10000, t + 90000, t + 45000), 'paused');
  assert(p.stalledFor(t + 45000) >= STALL_MS);
  // At normal speed past its end: the end.
  const q = new Pacer();
  for (let i = 0; i <= 10; i++) q.see(i * 60, t + i * 1000);
  assert.equal(overtime(q, t + 5000, t + 60000, t + 10000), 'end');
  // No looks with a tick (a reply without one): the end, never paused.
  const none = new Pacer(); none.see(5, t);
  assert.equal(overtime(none, t + 5000, t + 60000, t + 40000), 'end');
});

test('rolledBack lists the changes a journal shows after the tick the game went back to', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'fh-pace-'));
  const file = join(dir, 'journal.jsonl');
  const at = (hms: string) => `2026-10-14T${hms}.000Z`;
  const lines: unknown[] = [];
  const call = (id: string, hms: string, action: string, args: object, tick: number, ok = true) => {
    lines.push({at:at(hms), event:'request', request:{id, action, args}});
    lines.push({at:at(hms), event:'response', response:{id, ok, tick, result:{}}});
  };
  call('a', '20:30:00', 'build', {name:'stone-furnace', position:{x:1, y:2}}, 1000);
  call('b', '20:35:00', 'status', {}, 19000);
  call('c', '20:36:00', 'build', {name:'assembling-machine-2', position:{x:5, y:5}}, 20000);
  call('d', '20:37:00', 'craft', {recipe:'iron-gear-wheel', count:20}, 21000);
  call('e', '20:38:00', 'requests', {platform:'Sunward'}, 22000);                       // a read
  call('f', '20:38:30', 'requests', {platform:'Sunward', set:[{item:'coal', min:5}]}, 22500);
  call('g', '20:39:00', 'build', {name:'lab', position:{x:9, y:9}}, 23000, false);       // failed: nothing to redo
  call('h', '20:39:30', 'move_to', {position:{x:0, y:0}}, 23500);                        // a walk
  await writeFile(file, lines.map(l => JSON.stringify(l)).join('\n') + '\n');
  const r = rolledBack(file, 19000, Date.parse(at('20:45:00')));
  assert.equal(r.lastAt, clockTime(Date.parse(at('20:35:00'))).slice(0, 5));
  assert.deepEqual(r.redo.map(l => l.slice(9)), [
    'build {"name":"assembling-machine-2","position":{"x":5,"y":5}}',
    'craft {"recipe":"iron-gear-wheel","count":20}',
    'requests {"platform":"Sunward","set":[{"item":"coal","min":5}]}']);
  assert.equal(rolledBack(file, 19000, Date.parse(at('20:45:00')), 2).more, 1, 'past the limit: counted');
  assert.deepEqual(rolledBack(undefined, 19000, Date.now()).redo, []);
});

// A fake RCON server answering dispatch requests (as in waitevents.test.ts); the reply sets the tick.
async function engine(reply: (request:any)=>any, run:(port:number)=>Promise<void>) {
  const sockets = new Set<Socket>();
  const server = createServer(socket => {
    sockets.add(socket); socket.on('close', () => sockets.delete(socket));
    let buffered = Buffer.alloc(0);
    socket.on('data', data => {
      buffered = Buffer.concat([buffered, data]);
      while (buffered.length >= 4 && buffered.length >= buffered.readInt32LE(0)+4) {
        const size = buffered.readInt32LE(0), frame = buffered.subarray(4, size+4);
        buffered = buffered.subarray(size+4);
        const id = frame.readInt32LE(0), kind = frame.readInt32LE(4), text = frame.subarray(8, -2).toString();
        let body = '';
        if (kind === 2) {
          const match = text.match(/\n(\{.*\})\]\]/);
          assert(match, `bad dispatch: ${text}`);
          const request = JSON.parse(match[1]!);
          body = JSON.stringify({id:request.id, tick:1, ...reply(request)});
        }
        const out = Buffer.alloc(Buffer.byteLength(body)+14);
        out.writeInt32LE(out.length-4, 0); out.writeInt32LE(id, 4); out.writeInt32LE(kind === 3 ? 2 : 0, 8); out.write(body, 12);
        socket.write(out);
      }
    });
  }).listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address(); assert(address && typeof address !== 'string');
  try { await run(address.port); }
  finally { for (const socket of sockets) socket.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); }
}
const env = {...process.env, FACTORIO_RCON_PASSWORD:'test-only', FH_OPERATOR_FILE:'', FH_PROJECTS_FILE:''};
function cli(port: number, args: string[], extra: Record<string,string> = {}) {
  return exec(process.execPath, ['dist/host/cli.js', '--format', 'json', '--port', String(port), ...args], {env:{...env, ...extra}})
    .catch((e: any) => ({stdout:e.stdout as string, stderr:e.stderr as string}));
}

test('the CLI: the clock names a slow game, a rollback is said once with redo, an outage with since when and how long', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'fh-pace-cli-'));
  const journal = join(dir, 'journal.jsonl');
  let tick = 100000;
  await engine(request => ({ok:true, tick, result:{clock:'game 27h46m'}}), async port => {
    await cli(port, ['call', 'build', '--args', '{"name":"lab","position":{"x":1,"y":1}}', '--journal', journal]);
    // 10 s later at 10 ticks/s (the pace file says when the last reply came).
    const pace = JSON.parse(await readFile(join(dir, '.fh-pace.json'), 'utf8'));
    pace.base_at -= 10000; pace.at -= 10000;
    await writeFile(join(dir, '.fh-pace.json'), JSON.stringify(pace));
    tick += 100;
    let out = JSON.parse((await cli(port, ['call', 'status', '--journal', journal])).stdout);
    // (100 ticks over the 10 s set back plus the real time between the calls: 10 a second or a little under)
    const m = /^game 27h46m; game speed (\d+) ticks\/s, (\d+)% of normal$/.exec(out.result.clock);
    assert(m && Number(m[1]) >= 5 && Number(m[1]) <= 10, out.result.clock);
    // The game goes back 5 minutes: said once, with the build after that tick to redo.
    tick = 100100 - 18000;
    out = JSON.parse((await cli(port, ['call', 'status', '--journal', journal])).stdout);
    assert.match(out.result.rolled_back, /^the game rolled back from tick 100100 to tick 82100 or earlier \(the server restarted from a save\): what you did after .* is gone; redo lists what your journal shows you changed after it \(1 calls\), oldest first$/);
    assert.equal(out.result.redo.length, 1); assert.match(out.result.redo[0], / build \{"name":"lab","position":\{"x":1,"y":1\}\}$/);
    assert.equal(Object.keys(out.result)[0], 'rolled_back', 'first in the reply');
    out = JSON.parse((await cli(port, ['call', 'status', '--journal', journal])).stdout);
    assert.equal(out.result.rolled_back, undefined, 'once');
  });
  // The game is unreachable: since when, and nothing was sent; the first reply after says how long.
  const closed = await new Promise<number>(resolve => { const s = createServer().listen(0, '127.0.0.1', () => { const a = s.address() as any; s.close(() => resolve(a.port)); }); });
  const down = JSON.parse((await cli(closed, ['call', 'status', '--journal', journal])).stdout);
  assert.equal(down.error.code, 'game_unreachable');
  assert.match(down.error.message, /^game unreachable since \d\d:\d\d:\d\d \(0s\): .*; the request was not sent \(nothing was done\)$/);
  await engine(() => ({ok:true, tick, result:{clock:'game 27h47m'}}), async port => {
    const out = JSON.parse((await cli(port, ['call', 'status', '--journal', journal])).stdout);
    assert.match(out.result.outage, /^the game was unreachable from \d\d:\d\d:\d\d to about \d\d:\d\d:\d\d \(\d+s; the last failed call at \d\d:\d\d:\d\d: /);
  });
});

test('a sleep in a slow game goes on past its usual end while the game advances, then wakes normally', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'fh-pace-sleep-'));
  // 2 game seconds at 30 ticks/s take 4 real seconds; the usual end is 2 x 1.25 + 10 = 12.5 s, so make the game slower:
  // 6 ticks/s, 20 s for the 120 ticks; it wakes once the ticks reach its end.
  const start = Date.now();
  const now = () => 5000 + Math.floor((Date.now() - start) / 1000 * 6);
  const end = 5000 + 120;
  await engine(request => {
    const check = request.action === 'sleep_check' || (request.action === 'observe' && request.args?.scope === 'sleep_check');
    if (request.action === 'sleep') return {ok:true, tick:now(), result:{until_tick:end, while_asleep:'no queue and no action'}};
    if (check) return {ok:true, tick:now(), result:{until_tick:end, ...(now() >= end ? {woke:'elapsed', slept_s:2} : {})}};
    return {ok:true, tick:now(), result:{}};
  }, async port => {
    const out = JSON.parse((await cli(port, ['sleep', '2', '--journal', join(dir, 'journal.jsonl')])).stdout);
    assert.equal(out.ok, true, JSON.stringify(out));
    assert.equal(out.result.woke, 'elapsed');
    assert.match(out.result.slow_game, /^[5-7] ticks\/s, \d+% of normal$/);
    assert(Date.now() - start > 12500, 'past the usual end');
  });
});
