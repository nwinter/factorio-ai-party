// Agent-minds study fixes in the CLI (eng/minds-waits): the OPERATOR: line (fix 1), waits a tell or mention ends
// (fix 5), and one blocking wait on an event with one line out (fh wait --until, fix 5).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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
const env={...process.env,FACTORIO_RCON_PASSWORD:'test-only',FH_OPERATOR_FILE:''};
function cli(port:number,args:string[],format:'json'|'compact'='json',extra:Record<string,string>={}) {
  return exec(process.execPath,['dist/host/cli.js','--format',format,'--port',String(port),...args],{env:{...env,...extra}});
}
const OPERATOR={seq:7,ago_s:30,text:'Operator (automatic, facts only): your character has stood idle for 12 min.'};
test('an operator tell prints an OPERATOR: line on stderr and first on stdout, and is filed once for the hook',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'fh-operator-'));
  await engine(request=>({ok:true,result:{clock:'game 1s',position:{x:1,y:2},...(request.action==='status'?{operator:[OPERATOR]}:{})}}),async port=>{
    for (let i=0;i<2;i++) {
      const {stdout,stderr}=await cli(port,['call','status','--journal',join(dir,'journal.jsonl')],'compact');
      const line='OPERATOR: Operator (automatic, facts only): your character has stood idle for 12 min. (sent 30 s ago; repeated on every reply until your next game action or message)';
      assert.equal(stdout.split('\n')[0],line);
      assert.equal(stdout.split('\n').filter(l=>l.startsWith('OPERATOR:')).length,1,'once on stdout');
      assert.doesNotMatch(stdout,/^operator/m,'not again as a field');
      assert.match(stderr,/^OPERATOR: Operator \(automatic/m);
    }
    const filed=(await readFile(join(dir,'.operator-tells.jsonl'),'utf8')).trim().split('\n').map(l=>JSON.parse(l));
    assert.equal(filed.length,1,'filed once across calls'); assert.equal(filed[0].seq,7); assert.equal(filed[0].text,OPERATOR.text);
    // JSON keeps the field (programs read it); stderr still has the line.
    const {stdout,stderr}=await cli(port,['call','status']);
    assert.deepEqual(JSON.parse(stdout).result.operator,[OPERATOR]); assert.match(stderr,/OPERATOR:/);
  });
});
test('an OPERATOR: line seen on a --wait poll leads the reply',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='walk')return {ok:true,result:{until_tick:60}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:3},inventory:[]}}};
    polls++;
    return {ok:true,result:polls<2?{active:{kind:'walk',until_tick:60}}:{active:false,operator:[OPERATOR],last:{kind:'walk',outcome:'duration_elapsed',tick:30}}};
  },async port=>{
    // The acceptance prints before the wait; the OPERATOR: line leads what follows it.
    const {stdout}=await cli(port,['call','walk','--args','{"direction":"east","ticks":60}','--wait'],'compact');
    const at=stdout.indexOf('\nOPERATOR: ');
    assert(at>0 && at<stdout.indexOf('duration_elapsed'),stdout);
  });
});
test('a tell or mention ends --wait on an action that keeps going (exit 0, outcome told, from, still_running)',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:600}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:3},inventory:[]},team:{tells:['astra, 0s ago: stop, coal first']}}};
    polls++;
    const active={kind:'move_to',until_tick:600};
    return {ok:true,result:polls<2?{active}:{active,inbox:{tick:5,woke:'told',from:'astra'},last:{kind:'walk',outcome:'duration_elapsed',tick:0}}};
  },async port=>{
    const {stdout}=await cli(port,['call','move_to','--args','{"position":{"x":50,"y":5}}','--wait']);
    const reply=JSON.parse(stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.outcome,'told'); assert.equal(reply.result.completion.from,'astra');
    assert.match(reply.result.completion.still_running,/^move_to, up to \d+ s more$/);
    assert.match(reply.result.completion.note,/a tell from astra ended this wait/);
    assert.equal(reply.result.completion.last,undefined,'no earlier result passed off as this one');
  });
});
test('a tell from before the wait began does not end it',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='mine')return {ok:true,result:{until_tick:600}};
    polls++;
    return {ok:true,result:polls<2?{active:{kind:'mine',until_tick:600},inbox:{tick:0,woke:'told',from:'sol'}}
      :{active:false,last:{kind:'mine',outcome:'target_mined',tick:40}}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['call','mine','--args','{"position":{"x":1,"y":1}}','--wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.outcome,'target_mined');
  });
});
test('a direct wait a tell ended (outcome told) is a success',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='wait_ticks')return {ok:true,result:{until_tick:600}};
    polls++;
    return {ok:true,result:polls<2?{active:{kind:'wait_ticks',until_tick:600}}:{active:false,last:{kind:'wait_ticks',outcome:'told',why:'told by astra',tick:40}}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['call','wait_ticks','--args','{"ticks":600}','--wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.why,'told by astra');
  });
});
test('fh wait ends early on a tell or mention while the action keeps going',async()=>{
  let polls=0;
  await engine(request=>{
    polls++;
    const active={kind:'mine',until_tick:900};
    return {ok:true,result:polls<3?{active}:{active,inbox:{tick:2,woke:'mentioned',from:'sol'}}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.outcome,'mentioned'); assert.match(reply.result.note,/a mention from sol/);
  });
});
test('fh wait --until EVENT --max S: one sleep, peek reads only, one line out',async()=>{
  const seen:any[]=[];let checks=0;
  await engine(request=>{
    seen.push(request);
    if(request.action==='sleep'){checks=0;return {ok:true,result:{while_asleep:'no queue and no action',sleeping_s:request.args.seconds,team:{tells:['x']}}};}
    checks++;
    return {ok:true,result:checks<2?{slept_s:1}:{slept_s:4,woke:'told',tell:'astra: coal please'}};
  },async port=>{
    const {stdout}=await cli(port,['wait','--until','tell','--max','30'],'compact');
    assert.equal(stdout,"woke: told after 4 s (astra: coal please); your next reply's team block has the rest\n");
    await cli(port,['wait','--until','alert'],'compact');
    await cli(port,['wait','--until','item_count coal>=5','--max','120'],'compact');
    const json=JSON.parse((await cli(port,['wait','--max','60'])).stdout);
    assert.equal(json.result.line,"woke: told after 4 s (astra: coal please); your next reply's team block has the rest");
    await assert.rejects(cli(port,['wait','--max','901']),(error:any)=>/1\.\.900/.test(error.stdout));
  });
  const sleeps=seen.filter(r=>r.action==='sleep');
  assert.deepEqual(sleeps.map(r=>[r.args.seconds,r.args.condition,r.args.peek]),[
    [30,undefined,true],[600,{until:'alert'},true],[120,{until:'item_count',item:'coal',at_least:5},true],[60,undefined,true]]);
  assert(seen.filter(r=>r.action==='sleep_check').every(r=>r.args.peek===true),'the team block waits for the next reply');
});
