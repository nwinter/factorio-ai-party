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
test('raw wait_until word form and timeout aliases normalize before direct and queued calls',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request); return {ok:true,result:{}};},async port=>{
    await cli(port,['call','wait_until','--args',JSON.stringify({until:'item_count yumako>=40',ticks:90})]);
    await cli(port,['call','queue_submit','--args',JSON.stringify({steps:[{action:'wait_until',args:{until:'platform_arrived "Big Ship" gleba',timeout_ticks:600}},
      {action:'wait_until',args:{until:'item_count coal below 20 at 10,39',timeout:30}}],guards:[{when:{until:'researched logistics'},steps:[{action:'wait_until',args:{until:'rocket_ready 2,3',ticks:50}}]}]})]);
    assert.deepEqual(seen[0].args,{until:'item_count',item:'yumako',at_least:40,timeout:90});
    const plan=seen[1].args;
    assert.deepEqual(plan.steps[0].args,{until:'platform_arrived',platform:'Big Ship',location:'gleba',timeout:600});
    assert.deepEqual(plan.steps[1].args,{until:'item_count',item:'coal',below:20,positions:[{x:10,y:39}],timeout:30});
    assert.deepEqual(plan.guards[0].when,{until:'researched',technology:'logistics'});
    assert.deepEqual(plan.guards[0].steps[0].args,{until:'rocket_ready',position:{x:2,y:3},timeout:50});
    await cli(port,['call','queue_repeat','--args',JSON.stringify({condition:{until:'item_count coal>=50'},
      steps:[{action:'wait_until',args:{until:'platform_arrived "Big Ship" gleba',ticks:600}}]})]);
    assert.deepEqual(seen[2].args.condition,{until:'item_count',item:'coal',at_least:50});
    assert.deepEqual(seen[2].args.steps[0].args,{until:'platform_arrived',platform:'Big Ship',location:'gleba',timeout:600});
    const count=seen.length;
    for (const args of [{until:'item_count coal>=5',item:'iron-plate'},{until:'crafting_done',ticks:5,timeout:6},
      {until:'item_count coal>=5',below:10}]) {
      await assert.rejects(cli(port,['call','wait_until','--args',JSON.stringify(args)]));
    }
    await assert.rejects(cli(port,['call','queue_repeat','--args',JSON.stringify({condition:{until:'item_count coal>=50',item:'iron-plate'},
      steps:[{action:'wait_ticks',args:{ticks:60}}]})]),/args\.condition\.item conflicts/);
    assert.equal(seen.length,count,'conflicts send no game request');
  });
});
test('named hub item_count passes through direct waits, queue steps and guards',async()=>{
  const seen:any[]=[];
  const condition={until:'item_count',item:'agricultural-science-pack',at_least:1000,platform:'Big Ship'};
  await engine(request=>{seen.push(request); return {ok:true,result:{}};},async port=>{
    await cli(port,['call','wait_until','--args',JSON.stringify(condition)]);
    await cli(port,['call','queue_submit','--args',JSON.stringify({steps:[{action:'wait_until',args:condition}],
      guards:[{when:condition}]})]);
  });
  assert.deepEqual(seen[0].args,condition);
  assert.deepEqual(seen[1].args.steps[0].args,condition);
  assert.deepEqual(seen[1].args.guards[0].when,condition);
});
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
test('construct --wait (compact) reports what it built and the blockers with coordinates (request #167)',async()=>{
  let polls=0;
  const last={kind:'construct',outcome:'incomplete',built:3,mined:1,remaining:0,
    failed:[{name:'transport-belt',position:{x:-77.5,y:15.5},error:'placement blocked by tree-08 (-77.0625,16.25)'}],
    blockers:[{name:'tree-08',position:{x:-80.9375,y:3.25},ghost:'transport-belt',at:{x:-81.5,y:2.5},cleared:true}]};
  await engine(request=>{
    if(request.action==='construct')return {ok:true,result:{until_tick:600,total:4}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:0,y:0},health:250,max_health:250}}};
    polls++;
    return {ok:true,result:polls===1?{active:{kind:'construct',until_tick:600}}:{active:false,last}};
  },async port=>{
    const out=await exec(process.execPath,['dist/host/cli.js','--port',String(port),'call','construct','--wait'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}}).catch((e:any)=>e);
    const text=String(out.stdout);
    assert.match(text,/built.*3/); assert.match(text,/tree-08/); assert.match(text,/blockers.*\n.*tree-08 position=-80\.94,3\.25 ghost=transport-belt at=-81\.5,2\.5 cleared=true/); assert.match(text,/-77\.0625,16\.25/);
  });
});
test('wait_ticks, a build awaiting a hand craft, and a transfer or collect that walks (walk, pick) are waited for',async()=>{
  for (const [action,kind,args,accepted] of [['wait_ticks','wait_ticks','{"ticks":30}',{until_tick:31}],
    ['build','feed','{"item":"lab","position":{"x":1,"y":1}}',{awaiting_craft:{item:'lab',held:0,need:1,crafting:1},until_tick:900}],
    // Luna 07:57: a courier step runs as a tour (kind gather); --wait returned at once before.
    ['transfer','gather','{"positions":[{"x":1,"y":1}],"item":"yumako-seed","pick":"first_with_stock","to":{"x":9,"y":9}}',{op:'transfer',places:2,until_tick:900}],
    ['collect','gather','{"positions":[{"x":1,"y":1}],"item":"yumako-seed","pick":"most_stock"}',{op:'transfer',places:1,until_tick:900}],
    // Muse 12:20: collect with walk runs as the same tour.
    ['collect','gather','{"positions":[{"x":1,"y":1}],"item":"iron-plate","walk":true}',{op:'transfer',places:1,until_tick:900}]] as const) {
    let polls=0;
    await engine(request=>{
      if(request.action===action)return {ok:true,result:accepted};
      polls++;
      // A walking transfer ends transferred, a success (Astra 07:53: it exited 1).
      return {ok:true,result:polls===1?{active:{kind,until_tick:31}}:{active:false,last:{kind,op:kind==='gather'?'transfer':undefined,
        outcome:kind==='feed'?'fed':kind==='gather'?'transferred':'duration_elapsed'}}};
    },async port=>{
      const {stdout}=await cli(port,['call',action,'--args',args,'--wait']);
      // At least the running poll and the finished one (a final plain status read may follow).
      assert.equal(JSON.parse(stdout).ok,true); assert.ok(polls>=2,action);
    });
  }
});
test('vehicle drive --wait waits for its own drive, never the previous result (request #5)',async()=>{
  // Each drive runs as active kind 'drive'; the status carries the previous drive's result until it ends.
  let tick=100, polls=0, last:any={kind:'feed',outcome:'fed',tick:90};
  const plan=[{at:100,ends:150,outcome:'blocked'},{at:200,ends:260,outcome:'arrived'}];
  let drive=-1;
  await engine(request=>{
    if(request.action==='vehicle'){drive++;polls=0;tick=plan[drive]?.at ?? 300;return {tick,ok:true,result:{driving:true,until_tick:tick+600}};}
    polls++;
    const d=plan[drive];
    if(d && polls<3)return {tick:tick+polls,ok:true,result:{active:{kind:'drive',until_tick:d.at+600},last}};
    if(d){last={kind:'drive',outcome:d.outcome,tick:d.ends};}
    return {tick:(d?.ends ?? tick)+1,ok:true,result:{active:false,last}};
  },async port=>{
    const drive1=cli(port,['call','vehicle','--args','{"drive":{"x":200,"y":-180}}','--wait']);
    await assert.rejects(drive1,(error:any)=>/blocked/.test(JSON.parse(error.stdout).error.message));
    const second=JSON.parse((await cli(port,['call','vehicle','--args','{"drive":{"x":370,"y":-130}}','--wait'])).stdout);
    assert.equal(second.ok,true); assert.match(JSON.stringify(second.result),/"arrived"/); assert.doesNotMatch(JSON.stringify(second.result),/blocked/);
    assert.ok(polls>=3,'the second wait saw its drive running');
    // A drive that never shows as running and leaves no result: the earlier result is not reported as its own.
    const third=JSON.parse((await cli(port,['call','vehicle','--args','{"drive":{"x":0,"y":0}}','--wait'])).stdout);
    assert.doesNotMatch(JSON.stringify(third.result.completion ?? third.result),/"outcome":"arrived"/);
    assert.match(JSON.stringify(third.result),/predates it/);
  });
});
test('--wait polls the brief status, then reads the full status once; a runtime without brief gets full polls',async()=>{
  for (const knowsBrief of [true,false]) {
    const seen:any[]=[];let polls=0;
    await engine(request=>{
      seen.push(request);
      if(request.action==='walk')return {tick:10,ok:true,result:{until_tick:70}};
      if(request.args.brief && !knowsBrief)return {ok:false,error:{code:'action_failed',message:'unknown argument brief for status; valid: since, threats, machines, peek'}};
      polls++;
      if(polls<3)return {tick:10+polls,ok:true,result:{active:{kind:'walk',until_tick:70},last:false,brief:request.args.brief}};
      return {tick:71,ok:true,result:{active:false,last:{kind:'walk',outcome:'duration_elapsed',tick:70},factory:request.args.brief?undefined:{science:'x'}}};
    },async port=>{
      const out=JSON.parse((await cli(port,['--full','call','walk','--args','{"direction":"east","ticks":60}','--wait'])).stdout);
      // The reply the agent sees is the full status, as before.
      assert.equal(out.ok,true); assert.equal(out.result.completion.last.outcome,'duration_elapsed'); assert.equal(out.result.completion.factory.science,'x');
    });
    const statuses=seen.filter(r=>r.action==='status');
    const pollArgs=statuses.slice(0,-1).map(r=>JSON.stringify(r.args));
    if (knowsBrief) assert.deepEqual(pollArgs,Array(pollArgs.length).fill('{"peek":true,"brief":true}'));
    else assert.deepEqual(pollArgs.slice(1),Array(pollArgs.length-1).fill('{"peek":true}'));
    assert.deepEqual(statuses.at(-1).args,{});
  }
});
test('--wait polls once a second, sooner only when the action ends sooner (its own end tick)',async()=>{
  for (const [untilTick,runMs] of [[100000,2500],[16,0]] as const) {
    const times:number[]=[];let started=0;
    await engine(request=>{
      if(request.action==='walk'){started=Date.now();return {tick:10,ok:true,result:{until_tick:untilTick}};}
      if(request.action!=='status' || !request.args.brief)return {ok:true,result:{active:false,last:{kind:'walk',outcome:'duration_elapsed',tick:untilTick}}};
      times.push(Date.now());
      const running=times.length===1 || Date.now()-started<runMs;
      return running?{tick:10,ok:true,result:{active:{kind:'walk',until_tick:untilTick},last:false}}
        :{tick:untilTick+1,ok:true,result:{active:false,last:{kind:'walk',outcome:'duration_elapsed',tick:untilTick}}};
    },async port=>{
      assert.equal(JSON.parse((await cli(port,['call','walk','--args','{"direction":"east","ticks":60}','--wait'])).stdout).ok,true);
    });
    const gaps=times.slice(1).map((t,i)=>t-times[i]!);
    // 2.5 s of a long action: 4 polls (at 100 to 400 ms, 8 or more); 6 ticks left: polled again after ~200 ms.
    if (runMs) { assert.ok(times.length<=4,`${times.length} polls`); assert.ok(gaps.every(g=>g>=950),String(gaps)); }
    else { assert.equal(times.length,2); assert.ok(gaps[0]!<600,String(gaps)); }
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
      'item_count iron-plate >= 200 at -18.5,-34.5 (3,4)','items coal<10','ammo_below count=5 radius=20','rocket_ready 65.5,14.5',
      '{"until":"item_count","item":"gear","at_least":5}','platform_arrived Sunward','platform_arrived Sunward gleba',
      'platform_arrived platform=Sunward location=nauvis',
      // Haiku, 12:20: a level fallen under at a chest, and the other operators.
      'item_count coal below 20 at 10,39','item_count coal under 20 at 10,39','item_count coal <= 19 at 10,39',
      'item_count coal > 9','item_count coal above 9',
      // Gemini, 16:50: departure, a quoted name with spaces, at/from before the planet.
      'platform_left Sunward','platform_departed Sunward from nauvis','platform_arrived "Big Ship" at gleba',
      "platform_left 'Big Ship'",
      // Sonnet, shift14 22:50: the rocket being built has N parts.
      'rocket_parts>=40 at 15.5,59.5','rocket_parts >= 40 (15.5,59.5)','rocket_parts>39 15.5,59.5']) {
      assert.equal(JSON.parse((await cli(port,['sleep','30','--until',until])).stdout).result.woke,'condition');
    }
    await assert.rejects(cli(port,['sleep','30','--until','item_count iron-plate']),(error:any)=>/--until takes/.test(error.stdout));
    await assert.rejects(cli(port,['sleep','30','--until','item_count iron-plate>=5 at north']),(error:any)=>/X,Y pairs/.test(error.stdout));
    await assert.rejects(cli(port,['sleep','30','--until','rocket_ready']),(error:any)=>/rocket_ready X,Y/.test(error.stdout));
    await assert.rejects(cli(port,['sleep','30','--until','rocket_parts 40']),(error:any)=>/rocket_parts>=40 at X,Y/.test(error.stdout));
  });
  assert.deepEqual(seen.filter(r=>r.action==='sleep').map(r=>r.args.condition),[
    {until:'researched'},{until:'researched',technology:'automation-2'},{until:'crafting_done'},
    {until:'item_count',item:'iron-plate',at_least:200},
    {until:'item_count',item:'iron-plate',at_least:200,positions:[{x:-18.5,y:-34.5},{x:3,y:4}]},
    {until:'item_count',item:'coal',below:10},{until:'ammo_below',count:5,radius:20},{until:'rocket_ready',position:{x:65.5,y:14.5}},
    {until:'item_count',item:'gear',at_least:5},{until:'platform_arrived',platform:'Sunward'},
    {until:'platform_arrived',platform:'Sunward',location:'gleba'},{until:'platform_arrived',platform:'Sunward',location:'nauvis'},
    {until:'item_count',item:'coal',below:20,positions:[{x:10,y:39}]},{until:'item_count',item:'coal',below:20,positions:[{x:10,y:39}]},
    {until:'item_count',item:'coal',below:20,positions:[{x:10,y:39}]},
    {until:'item_count',item:'coal',at_least:10},{until:'item_count',item:'coal',at_least:10},
    {until:'platform_left',platform:'Sunward'},{until:'platform_left',platform:'Sunward',location:'nauvis'},
    {until:'platform_arrived',platform:'Big Ship',location:'gleba'},{until:'platform_left',platform:'Big Ship'},
    {until:'rocket_parts',at_least:40,position:{x:15.5,y:59.5}},{until:'rocket_parts',at_least:40,position:{x:15.5,y:59.5}},
    {until:'rocket_parts',at_least:40,position:{x:15.5,y:59.5}}]);
  assert.equal(seen.filter(r=>r.action==='sleep')[0].args.seconds,30);
});
test('fh sleep keeps the team hints the sleep request carried, and prints what keeps going first (compact)',async()=>{
  let checks=0;
  const reply=(request:any)=>{
    if(request.action==='sleep'){checks=0;return {ok:true,result:{while_asleep:'your queue keeps running (move_to running, 2 steps pending); this sleep ends when it finishes or stalls',
      sleeping_s:60,until_tick:3601,team:{mentions:['sol @you, 5s ago: @astra coal?'],alerts:['attack near (16,16)']}}};}
    checks++;
    return {ok:true,result:checks<2?{slept_s:1}:{while_asleep:'your queue keeps running (...)',slept_s:2,woke:'queue_done',
      team:{mentions:['grok @you, 0s ago: @astra done'],board:['#4 (yours) note by sol: ok']}}};
  };
  await engine(reply,async port=>{
    const json=JSON.parse((await cli(port,['sleep','60'])).stdout).result;
    assert.deepEqual(json.team,{mentions:['sol @you, 5s ago: @astra coal?','grok @you, 0s ago: @astra done'],alerts:['attack near (16,16)'],board:['#4 (yours) note by sol: ok']});
    const {stdout}=await exec(process.execPath,['dist/host/cli.js','--port',String(port),'sleep','60'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
    assert.match(stdout.split('\n')[0]!,/^while_asleep: your queue keeps running \(move_to running, 2 steps pending\)/);
    assert.match(stdout,/@astra coal\?/);
  });
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
