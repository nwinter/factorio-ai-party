import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { lookaheadDue, lookaheadOffset, LOOKAHEAD_MS, LOOKAHEAD_QUIET_MS } from '../host/lookahead.js';
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
test('the look-ahead comes 20 min plus an offset by agent after the first call, then every 45 min', () => {
  const names = ['astra','sol','luna','muse','opus','sonnet','haiku','grok','gemini'];
  const offsets = names.map(lookaheadOffset);
  for (const o of offsets) assert.ok(o >= 0 && o < LOOKAHEAD_MS);
  assert.ok(new Set(offsets.map(o => Math.floor(o / 60000))).size >= 7, 'spread over the 45 minutes: ' + offsets.join(','));
  assert.equal(lookaheadDue({started:0}, 'astra'), LOOKAHEAD_QUIET_MS + lookaheadOffset('astra'));
  assert.ok(lookaheadDue({started:0}, 'astra') >= 20 * 60000, 'never in the first 20 min');
  assert.equal(lookaheadDue({started:0, last:5000}, 'astra'), 5000 + 45 * 60000);
});
test('a reply carries the look-ahead once when it is due, read with peek, with the time left in the shift', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lookahead-'));
  const file = join(dir, '.lookahead.json'), deadlineFile = join(dir, 'deadline.txt');
  const at = new Date(Date.now() + 90 * 60000 + 30000);
  const pad = (n:number) => String(n).padStart(2, '0');
  writeFileSync(deadlineFile, `${at.getUTCFullYear()}-${pad(at.getUTCMonth()+1)}-${pad(at.getUTCDate())} ${pad(at.getUTCHours())}:${pad(at.getUTCMinutes())} UTC\n`);
  const env = {...process.env, FACTORIO_RCON_PASSWORD:'test-only', FH_LOOKAHEAD_FILE:file, FH_DEADLINE_FILE:deadlineFile};
  const asked: any[] = [];
  await engine(request => {
    asked.push(request);
    if (request.action === 'lookahead') return {ok:true, result:{lines:['your plan line: none','research: none running; nothing queued next'], sentence:'look ahead: a moment to think past the current task.'}};
    return {ok:true, result:{clock:'game 1m'}};
  }, async port => {
    const run = async (action:string) => JSON.parse((await exec(process.execPath, ['dist/host/cli.js','--format','json','--port',String(port),'call',action], {env})).stdout);
    // The first call of the workspace starts the clock; nothing yet.
    let r = await run('status');
    assert.equal(r.result.lookahead, undefined);
    assert.ok(existsSync(file));
    // Three hours on: due. The block, with the time left before the sentence; read with peek.
    writeFileSync(file, JSON.stringify({started:Date.now() - 3 * 3600000}) + '\n');
    r = await run('status');
    assert.deepEqual(r.result.lookahead.slice(0, 2), ['your plan line: none','research: none running; nothing queued next']);
    assert.match(r.result.lookahead[2], /^time left in the shift: 1h(29|30)m$/);
    assert.equal(r.result.lookahead[3], 'look ahead: a moment to think past the current task.');
    const read = asked.find(q => q.action === 'lookahead');
    assert.equal(read.args.peek, true);
    assert.ok(typeof JSON.parse(readFileSync(file, 'utf8')).last === 'number');
    // Shown once: the next reply has none.
    r = await run('status');
    assert.equal(r.result.lookahead, undefined);
    // fh call lookahead reads it any time, with the time left.
    r = await run('lookahead');
    assert.equal(r.result.lines.length, 4);
    assert.match(r.result.lines[2], /^time left in the shift: /);
  });
});
