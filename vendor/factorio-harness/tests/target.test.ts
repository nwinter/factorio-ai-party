import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { targetLine, whenText } from '../host/target.js';
import { tempDirSync } from './tmp.js';
const exec = promisify(execFile);
// A fake RCON server answering dispatch requests (as in cli.test.ts).
async function engine(reply: (request:any)=>any, run:(port:number)=>Promise<void>) {
  const sockets = new Set<Socket>();
  const server = createServer(socket => {
    sockets.add(socket);socket.on('close',()=>sockets.delete(socket));
    let buffered=Buffer.alloc(0);
    socket.on('data',data=>{
      buffered=Buffer.concat([buffered,data]);
      while (buffered.length>=4 && buffered.length>=buffered.readInt32LE(0)+4) {
        const size=buffered.readInt32LE(0), frame=buffered.subarray(4,size+4);
        buffered=buffered.subarray(size+4);
        const id=frame.readInt32LE(0), kind=frame.readInt32LE(4), text=frame.subarray(8,-2).toString();
        let body='';
        if(kind===2) {
          const match=text.match(/\n(\{.*\})\]\]/);
          assert(match,`bad dispatch: ${text}`);
          const request=JSON.parse(match[1]!);
          body=JSON.stringify({id:request.id,tick:1,...reply(request)});
        }
        const out=Buffer.alloc(Buffer.byteLength(body)+14);
        out.writeInt32LE(out.length-4,0);out.writeInt32LE(id,4);out.writeInt32LE(kind===3?2:0,8);out.write(body,12);
        socket.write(out);
      }
    });
  }).listen(0,'127.0.0.1');
  await once(server,'listening');
  const address=server.address();assert(address && typeof address!=='string');
  try { await run(address.port); }
  finally {for(const socket of sockets)socket.destroy();await new Promise<void>(resolve=>server.close(()=>resolve()));}
}
// (d27 batch277 RT) the run's target: runs/RUN/target.json as tools/run_target.py writes it
const T = {goal:'the Shattered Planet', at:'2026-10-30 23:59 PDT', by:'Nick', kind:'soft', note:"the run's end is not fixed"};
const AT = Date.UTC(2026, 9, 31, 6, 59);  // 2026-10-30 23:59 PDT
test('the target line: who, soft or hard, the goal, its date with weekday and zone, the time left, the note', () => {
  assert.equal(whenText('2026-10-30 23:59 PDT'), 'Fri Oct 30 23:59 PDT');
  assert.equal(whenText('2026-11-02 7:05 PST'), 'Mon Nov 2 07:05 PST');
  const now = AT - (81 * 60 + 30) * 60000;
  assert.equal(targetLine(JSON.stringify(T), now),
    "Target (Nick, soft): the Shattered Planet by Fri Oct 30 23:59 PDT, 81 h 30 m from now; the run's end is not fixed.");
  assert.equal(targetLine(JSON.stringify({...T, kind:'hard', note:undefined}), AT - 45 * 60000),
    'Target (Nick, hard): the Shattered Planet by Fri Oct 30 23:59 PDT, 45 m from now.');
  assert.equal(targetLine(JSON.stringify({...T, by:undefined}), AT + 130 * 60000),
    "Target (soft): the Shattered Planet by Fri Oct 30 23:59 PDT, passed 2 h 10 m ago; the run's end is not fixed.");
  for (const bad of ['', 'not json', '{}', JSON.stringify({...T, goal:' '}), JSON.stringify({...T, at:'Friday night'})])
    assert.equal(targetLine(bad, now), undefined, bad);
  assert.doesNotMatch(targetLine(JSON.stringify(T), now)!, /should|try|hurry|must/i);
});
test("every status reply starts with the run's target line, computed at each read; other replies and no file: none", async () => {
  const dir = tempDirSync('target-');
  const ws = join(dir, 'astra'); mkdirSync(ws);
  const target = join(dir, 'target.json');
  const env = {...process.env, FACTORIO_RCON_PASSWORD:'test-only', FH_LOOKAHEAD_FILE:join(ws, '.lookahead.json'), FH_POLLS_FILE:join(dir, 'none.json')};
  await engine(() => ({ok:true, result:{clock:'game 1m', inv:'2 free'}}), async port => {
    // the run folder is the journal's parent's parent (as for polls.json): no env needed in the agents' fh wrappers
    const run = async (...a:string[]) => JSON.parse((await exec(process.execPath, ['dist/host/cli.js','--format','json','--port',String(port),'--journal',join(ws,'journal.jsonl'),'call',...a], {env})).stdout);
    let r = await run('status');
    assert.equal(r.result.target, undefined);  // no target set
    writeFileSync(target, JSON.stringify({...T, at:new Date(Date.now() + (81 * 60 + 30) * 60000 + 30000).toISOString()}));
    r = await run('status');
    assert.match(r.result.target, /^Target \(Nick, soft\): the Shattered Planet by .+, 81 h 30 m from now; the run's end is not fixed\.$/);
    assert.equal(Object.keys(r.result)[0], 'target');
    r = await run('inventory');
    assert.equal(r.result.target, undefined);  // status only
    writeFileSync(target, JSON.stringify({...T, at:new Date(Date.now() + 90 * 60000 + 30000).toISOString()}));
    assert.match((await run('status')).result.target, /, 1 h 30 m from now;/);  // read again each time
    rmSync(target);
    assert.equal((await run('status')).result.target, undefined);  // cleared
    // FH_TARGET_FILE names another file
    const other = join(dir, 'other.json');
    writeFileSync(other, JSON.stringify({...T, goal:'Aquilo'}));
    const r2 = JSON.parse((await exec(process.execPath, ['dist/host/cli.js','--format','json','--port',String(port),'call','status'], {env:{...env, FH_TARGET_FILE:other}})).stdout);
    assert.match(r2.result.target, /^Target \(Nick, soft\): Aquilo by /);
  });
});
