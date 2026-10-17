import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pollAnnouncements, pollLine } from '../host/polls.js';
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
const nowS = 1792200000;
const P1 = {id:1, question:'Should the AI team use blueprints made by people?', options:['No','Ideas only','Yes'], status:'open', closes:nowS + 12 * 3600};
test('a poll line: id, question, options with their numbers, the vote call; facts only', () => {
  const line = pollLine(P1, nowS);
  assert.equal(line, "poll #1 open on the stream's site, closes in 12 h 00 min: Should the AI team use blueprints made by people? "
    + "Options: 0 No; 1 Ideas only; 2 Yes. Vote: ./fh poll vote --args '{\"id\":1,\"option\":K,\"comment\":\"...\"}' "
    + "(one vote per agent, a later one replaces it; ./fh poll shows the intro, each option's details and the counts)");
  assert.doesNotMatch(line, /consider|should you|you should/i);
});
test('each open poll is said once; closed or past ones never', () => {
  const data = {open:[P1, {...P1, id:2, closes:nowS - 5}, {...P1, id:3, status:'closed'}], closed:[{...P1, id:0, status:'closed'}]};
  let r = pollAnnouncements(data, [], nowS);
  assert.equal(r.lines.length, 1);
  assert.deepEqual(r.seen, [1]);
  r = pollAnnouncements(data, r.seen, nowS);
  assert.deepEqual(r.lines, []);
  r = pollAnnouncements({open:[P1, {...P1, id:4}]}, [1], nowS);
  assert.equal(r.lines.length, 1);
  assert.match(r.lines[0]!, /^poll #4 /);
  assert.deepEqual(pollAnnouncements(null, [], nowS).lines, []);
});
test("an open poll's line comes once in the team block of the workspace's next reply, not with peek", async () => {
  const dir = tempDirSync('polls-');
  const polls = join(dir, 'polls.json'), seen = join(dir, '.fh-polls-seen.json');
  const env = {...process.env, FACTORIO_RCON_PASSWORD:'test-only', FH_POLLS_FILE:polls, FH_POLLS_SEEN:seen, FH_LOOKAHEAD_FILE:join(dir, '.lookahead.json')};
  await engine(() => ({ok:true, result:{clock:'game 1m', team:{tells:['luna: hi']}}}), async port => {
    const run = async (...a:string[]) => JSON.parse((await exec(process.execPath, ['dist/host/cli.js','--format','json','--port',String(port),'call',...a], {env})).stdout);
    let r = await run('status');
    assert.equal(r.result.team.poll, undefined);  // no poll file: nothing
    const now = Math.floor(Date.now() / 1000);
    writeFileSync(polls, JSON.stringify({fetched:now, open:[{...P1, closes:now + 3600}], closed:[]}));
    r = await run('status', '--args', '{"peek":true}');
    assert.equal(r.result.team.poll, undefined);  // a peek leaves it for the agent's own reply
    r = await run('status');
    assert.equal(r.result.team.poll.length, 1);
    assert.match(r.result.team.poll[0], /^poll #1 open on the stream's site, closes in (59 min|1 h 00 min): /);
    assert.deepEqual(r.result.team.tells, ['luna: hi']);
    assert.deepEqual(JSON.parse(readFileSync(seen, 'utf8')).seen, [1]);
    r = await run('status');
    assert.equal(r.result.team.poll, undefined);  // once
  });
});
