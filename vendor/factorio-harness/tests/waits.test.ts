import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
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
function cli(port:number,args:string[]) {
  return exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),...args],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
}
test('move_to ending arrived_near is a success (exit 0)',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:60}};
    polls++;
    return {ok:true,result:polls===1?{active:{kind:'move_to',until_tick:60}}:{active:false,last:{kind:'move_to',outcome:'arrived_near'}}};
  },async port=>{
    const {stdout}=await cli(port,['call','move_to','--args','{"position":{"x":5,"y":5}}','--wait']);
    assert.equal(JSON.parse(stdout).ok,true);
  });
});
test('wait_until --wait takes its timeout from --wait-timeout and reports timed_out first',async()=>{
  const seen:any[]=[];let polls=0;
  await engine(request=>{
    seen.push(request);
    if(request.action==='wait_until')return {ok:true,result:{until_tick:1+request.args.timeout,condition:'item_count'}};
    polls++;
    return {ok:true,result:polls===1?{active:{kind:'wait_until',until_tick:30}}:{active:false,last:{kind:'wait_until',outcome:'timed_out',condition:'item_count',saw:3}}};
  },async port=>{
    await assert.rejects(cli(port,['call','wait_until','--args','{"until":"item_count","item":"iron-plate","at_least":50}','--wait','--wait-timeout','600000']),(error:any)=>{
      const reply=JSON.parse(error.stdout);
      assert.equal(error.code,1);
      assert.equal(reply.error.code,'timed_out');
      assert.match(reply.error.message,/wait_until timed_out: item_count not met \(saw 3\)/);
      return true;
    });
  });
  assert.equal(seen[0].args.timeout,36000);
  // Capped at 15 minutes; an explicit args.timeout wins.
  await engine(request=>{seen.push(request);return request.action==='wait_until'?{ok:true,result:{outcome:'met',until_tick:1}}:{ok:true,result:{active:false,last:{outcome:'met'}}};},async port=>{
    await cli(port,['call','wait_until','--args','{"until":"crafting_done"}','--wait','--wait-timeout','3600000']);
    await cli(port,['call','wait_until','--args','{"until":"crafting_done","timeout":120}','--wait','--wait-timeout','3600000']);
  });
  const waits=seen.filter(r=>r.action==='wait_until');
  assert.equal(waits[1].args.timeout,54000); assert.equal(waits[2].args.timeout,120);
});
test('wait_ticks and a build awaiting a hand craft are waited for',async()=>{
  for (const [action,kind,args,accepted] of [['wait_ticks','wait_ticks','{"ticks":30}',{until_tick:31}],
    ['build','feed','{"item":"lab","position":{"x":1,"y":1}}',{awaiting_craft:{item:'lab',held:0,need:1,crafting:1},until_tick:900}]] as const) {
    let polls=0;
    await engine(request=>{
      if(request.action===action)return {ok:true,result:accepted};
      polls++;
      return {ok:true,result:polls===1?{active:{kind,until_tick:31}}:{active:false,last:{kind,outcome:kind==='feed'?'fed':'duration_elapsed'}}};
    },async port=>{
      const {stdout}=await cli(port,['call',action,'--args',args,'--wait']);
      // At least the running poll and the finished one (a final plain status read may follow).
      assert.equal(JSON.parse(stdout).ok,true); assert.ok(polls>=2,action);
    });
  }
});
test('fh sleep polls sleep_check with peek, then reads once normally; death exits nonzero',async()=>{
  for (const woke of ['mentioned','died','respawned']) {
    const seen:any[]=[];let checks=0;
    await engine(request=>{
      seen.push(request);
      if(request.action==='sleep')return {ok:true,result:{sleeping_s:30,until_tick:1801}};
      checks++;
      return {ok:true,result:checks<2?{slept_s:1}:{slept_s:2,woke,mention:'sol: @astra coal please'}};
    },async port=>{
      const run=cli(port,['sleep','30']);
      if (woke==='died') await assert.rejects(run,(error:any)=>JSON.parse(error.stdout).error.code==='died');
      else assert.equal(JSON.parse((await run).stdout).result.woke,woke); // a dead bot's sleep ends at its respawn
    });
    assert.equal(seen[0].args.seconds,30);
    assert.deepEqual(seen.slice(1,-1).map(r=>r.args.peek),[true,true]);
    assert.equal(seen.at(-1).args.peek,undefined);
  }
  await assert.rejects(cli(1,['sleep','901']),(error:any)=>/SECONDS 1\.\.900/.test(error.stdout));
});
function sleepEngine(seen:any[], woke='condition') {
  let checks=0;
  return (request:any)=>{
    seen.push(request);
    if(request.action==='sleep'){checks=0;return {ok:true,result:{while_asleep:'no queue and no action: your character stands idle for up to 30 s',sleeping_s:request.args.seconds,until_tick:1801}};}
    checks++;
    return {ok:true,result:checks<2?{slept_s:1}:{slept_s:2,woke}};
  };
}
test('fh sleep --until sends a wait_until condition: words or JSON',async()=>{
  const seen:any[]=[];
  await engine(sleepEngine(seen),async port=>{
    for (const until of ['researched','researched automation-2','crafting_done','item_count iron-plate>=200',
      'item_count iron-plate >= 200 at -18.5,-34.5 (3,4)','items coal<10','ammo_below count=5 radius=20',
      '{"until":"item_count","item":"gear","at_least":5}']) {
      assert.equal(JSON.parse((await cli(port,['sleep','30','--until',until])).stdout).result.woke,'condition');
    }
    await assert.rejects(cli(port,['sleep','30','--until','item_count iron-plate']),(error:any)=>/--until takes/.test(error.stdout));
    await assert.rejects(cli(port,['sleep','30','--until','item_count iron-plate>=5 at north']),(error:any)=>/X,Y pairs/.test(error.stdout));
  });
  assert.deepEqual(seen.filter(r=>r.action==='sleep').map(r=>r.args.condition),[
    {until:'researched'},{until:'researched',technology:'automation-2'},{until:'crafting_done'},
    {until:'item_count',item:'iron-plate',at_least:200},
    {until:'item_count',item:'iron-plate',at_least:200,positions:[{x:-18.5,y:-34.5},{x:3,y:4}]},
    {until:'item_count',item:'coal',below:10},{until:'ammo_below',count:5,radius:20},
    {until:'item_count',item:'gear',at_least:5}]);
  assert.equal(seen.filter(r=>r.action==='sleep')[0].args.seconds,30);
});
test('fh call sleep blocks like fh sleep (with or without --wait)',async()=>{
  for (const extra of [['--wait'],[]]) {
    const seen:any[]=[];
    await engine(sleepEngine(seen,'mentioned'),async port=>{
      const reply=JSON.parse((await cli(port,['call','sleep','--args','{"seconds":120}',...extra])).stdout);
      assert.equal(reply.result.woke,'mentioned');
    });
    // sleep_check travels as observe {scope: sleep_check} (harness.ts).
    assert.deepEqual(seen.map(r=>[r.args.scope ?? r.action,r.args.peek]),[['sleep',undefined],['sleep_check',true],['sleep_check',true],['sleep_check',undefined]]);
  }
  await assert.rejects(cli(1,['call','sleep','--args','{"seconds":0}']),(error:any)=>/seconds 1\.\.900: fh sleep SECONDS/.test(error.stdout));
});
test('a sleep never runs past the deadline: cut to the time left, or none after it',async()=>{
  const { mkdtemp, writeFile } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const dir=await mkdtemp(`${tmpdir()}/fh-deadline-`);
  const stamp=(ms:number)=>new Date(ms).toISOString().replace('T',' ').replace(/\.\d+Z$/,' UTC');
  const run=(port:number,args:string[],file:string)=>exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),...args],
    {env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only',FH_DEADLINE_FILE:file}});
  await writeFile(`${dir}/past.txt`,stamp(Date.now()-60000)+'\n');
  await writeFile(`${dir}/soon.txt`,stamp(Date.now()+65000)+'\n');
  const seen:any[]=[];
  await engine(sleepEngine(seen,'elapsed'),async port=>{
    const none=JSON.parse((await run(port,['sleep','300'],`${dir}/past.txt`)).stdout);
    assert.equal(none.result.woke,'deadline'); assert.match(none.result.note,/no sleep: deadline passed/);
    assert.equal(seen.length,0);
    const cut=JSON.parse((await run(port,['sleep','300'],`${dir}/soon.txt`)).stdout);
    assert.equal(cut.result.woke,'deadline'); assert.match(cut.result.note,/cut to end at the deadline/);
  });
  const seconds=seen[0].args.seconds;
  assert.ok(seconds>=55 && seconds<=65,String(seconds));
});
