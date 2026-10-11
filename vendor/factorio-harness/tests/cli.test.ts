import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
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
test('CLI help works without a server or credentials',async()=>{
  const {stdout}=await exec(process.execPath,['dist/host/cli.js','--help']);
  assert.match(stdout,/queue submit/);assert.match(stdout,/blueprint import/);
});
test('queue command maps to runtime protocol with JSON-only stdout',async()=>{
  await engine(request=>{
    assert.equal(request.action,'queue_status');assert.equal(request.player,2);
    return {ok:true,result:{revision:5,pending:[]}};
  },async port=>{
    const {stdout,stderr}=await cli(port,['queue','status','--player','2']);
    assert.equal(stderr,'');assert.equal(JSON.parse(stdout).result.revision,5);
  });
});
test('--bot and FH_BOT address a bot by name instead of a player',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{}};},async port=>{
    await cli(port,['call','status','--bot','astra']);
    await exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),'call','status'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only',FH_BOT:'opus'}});
    await exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),'call','status','--player','2'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only',FH_BOT:'opus'}});
  });
  assert.equal(seen[0].bot,'astra');assert.equal(seen[0].player,undefined);
  assert.equal(seen[1].bot,'opus');
  assert.equal(seen[2].player,2);assert.equal(seen[2].bot,undefined);
  await assert.rejects(cli(1,['call','status','--bot','astra','--player','2']),(e:any)=>/not both/.test(e.stdout+e.stderr));
  await assert.rejects(cli(1,['call','status','--bot','Astra!']),(e:any)=>/must be a bot name/.test(e.stdout+e.stderr));
});
test('queue submit rejects a plan file that is not an array before contacting the game',async()=>{
  const {writeFile,mkdtemp}=await import('node:fs/promises');
  const {tmpdir}=await import('node:os');
  const {join}=await import('node:path');
  const dir=await mkdtemp(join(tmpdir(),'fh-plan-'));
  const file=join(dir,'plan.json');
  await writeFile(file,JSON.stringify({action:'walk',args:{direction:'east',ticks:10}}));
  await engine(()=>{assert.fail('no request expected');},async port=>{
    await assert.rejects(cli(port,['queue','submit','--file',file]),(error:any)=>{
      assert.match(String(error.stderr)+String(error.stdout),/must be a JSON array of steps/); return true;
    });
  });
});
test('--wait waits for shoot channel and reports interrupted completion',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='shoot')return {ok:true,result:{until_tick:60}};
    assert.equal(request.action,'status');polls++;
    if(polls<=2)assert.equal(request.args.peek,true);
    return {ok:true,result:polls===1?{active:{kind:'shoot'},combat:{until_tick:60}}:{active:false,combat:false,last_combat:{outcome:'interrupted'}}};
  },async port=>{
    try {
      await cli(port,['call','shoot','--args','{"auto":true,"ticks":60}','--wait']);
      assert.fail('interrupted action must exit nonzero');
    } catch(error:any) {
      assert.equal(error.code,1);
      assert.equal(JSON.parse(error.stdout).error.code,'action_interrupted');
      assert.equal(polls,3); // two peek polls, then the reply the agent sees
    }
  });
});
test('--wait on a transfer that is awaiting a hand craft waits for the feed to land',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='transfer')return {ok:true,result:{awaiting_craft:{item:'lab',held:0,need:1,crafting:1},until_tick:900}};
    assert.equal(request.action,'status');polls++;
    return {ok:true,result:polls===1?{active:{kind:'feed',awaiting_craft:true,until_tick:900}}:{active:false,last:{kind:'feed',outcome:'fed',result:{transferred:1}}}};
  },async port=>{
    const {stdout}=await cli(port,['call','transfer','--args','{"position":{"x":1,"y":1},"item":"lab"}','--wait']);
    const reply=JSON.parse(stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.outcome,'fed'); assert.equal(polls,3);
  });
});
test('compact CLI output preserves failure details and nonzero exit status',async()=>{
  await engine(()=>({ok:false,error:{code:'placement_blocked',message:'Cannot build here'}}),async port=>{
    await assert.rejects(cli(port,['call','build','--format','compact']), (error:any)=>{
      assert.equal(error.code,1);
      assert.match(error.stdout,/error: placement_blocked: Cannot build here\n$/);
      return true;
    });
  });
});

test('CLI defaults to compact output',async()=>{
  await engine(()=>({ok:true,result:{revision:5}}),async port=>{
    const {stdout}=await exec(process.execPath,['dist/host/cli.js','--port',String(port),'queue','status'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
    assert.match(stdout,/revision: 5/);
    assert.throws(()=>JSON.parse(stdout));
  });
});
test('blueprint inspection uses the existing read-only export protocol',async()=>{
  await engine(request=>{
    assert.equal(request.action,'blueprint_export');
    assert.deepEqual(request.args,{slot:'plan',layout:true});
    return {ok:true,result:{layout:[]}};
  },async port=>{await cli(port,['blueprint','inspect','--args','{"slot":"plan"}']);});
});
test('a --wait that outlasts its timeout reports the action still running, after showing acceptance in compact output',async()=>{
  await engine(request=>{
    if(request.action==='construct')return {ok:true,result:{until_tick:36000,total:4}};
    return {ok:true,result:{active:{kind:'construct',remaining:4,awaiting_craft:true}}};
  },async port=>{
    try {
      await exec(process.execPath,['dist/host/cli.js','--port',String(port),'call','construct','--wait','--wait-timeout','250'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
      assert.fail('an unfinished wait must exit nonzero');
    } catch(error:any) {
      assert.equal(error.code,1);
      assert.match(error.stdout,/^tick: 1\nwaiting: .*\nuntil_tick: 36000\ntotal: 4\n/);
      assert.match(error.stdout,/wait_timeout/);
      assert.match(error.stdout,/STILL RUNNING/);
      assert.match(error.stdout,/timed_out: true/);
      assert.match(error.stdout,/still_running:/);
      assert.match(error.stdout,/awaiting_craft/);
      assert.doesNotMatch(error.stdout,/completion:/);
    }
  });
});
test('a timed-out --wait in JSON has no completion, only timed_out and still_running',async()=>{
  await engine(request=>{
    if(request.action==='construct')return {ok:true,result:{until_tick:36000,total:4}};
    return {ok:true,result:{active:{kind:'construct',until_tick:36000,remaining:4}}};
  },async port=>{
    try {
      await cli(port,['call','construct','--wait','--wait-timeout','250']);
      assert.fail('an unfinished wait must exit nonzero');
    } catch(error:any) {
      const reply=JSON.parse(error.stdout);
      assert.equal(reply.ok,false); assert.equal(reply.error.code,'wait_timeout');
      assert.equal(reply.result.timed_out,true); assert.equal(reply.result.still_running.kind,'construct');
      assert.equal(reply.result.completion,undefined); assert.equal(reply.result.accepted.total,4);
      assert.match(reply.error.message,/fh wait/);
    }
  });
});
test('fh wait blocks until the character is idle and reports the last outcome',async()=>{
  let polls=0;
  await engine(request=>{
    assert.equal(request.action,'status'); polls++;
    return {ok:true,tick:polls*10,result:polls<3?{active:{kind:'construct',until_tick:600}}:{active:false,combat:false,last:{kind:'construct',outcome:'constructed'}}};
  },async port=>{
    const {stdout}=await cli(port,['wait']);
    const reply=JSON.parse(stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.idle,true); assert.equal(reply.result.last.outcome,'constructed'); assert.equal(polls,4);
  });
});
test('fh wait exits nonzero when the action ended badly or is still running at the timeout',async()=>{
  await engine(()=>({ok:true,result:{active:false,combat:false,last:{kind:'move_to',outcome:'blocked'}}}),async port=>{
    await assert.rejects(cli(port,['wait']),(error:any)=>{ assert.equal(JSON.parse(error.stdout).error.code,'action_interrupted'); return true; });
  });
  await engine(()=>({ok:true,tick:5,result:{active:{kind:'mine',until_tick:65}}}),async port=>{
    await assert.rejects(cli(port,['wait','--wait-timeout','200']),(error:any)=>{
      const reply=JSON.parse(error.stdout);
      assert.equal(reply.error.code,'wait_timeout'); assert.equal(reply.result.still_running.kind,'mine'); assert.match(reply.error.message,/up to 1 s more/);
      return true;
    });
  });
});
test('board and plan commands map to the board actions',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{}};},async port=>{
    await cli(port,['board','--bot','astra']);
    await cli(port,['board','post','--bot','astra','--args','{"kind":"task","title":"x"}']);
    await cli(port,['board','request','--bot','astra','--args','{"title":"x","problem":"y"}']);
    const dir=await (await import('node:fs/promises')).mkdtemp('.cache/plan-');
    const file=`${dir}/plan.json`;
    await (await import('node:fs/promises')).writeFile(file,'[{"action":"walk","args":{"direction":"east","ticks":5}}]');
    await cli(port,['plan','save','east','--file',file,'--bot','astra']);
    await cli(port,['plan','run','east','--bot','astra']);
    await cli(port,['plan','delete','east','--bot','astra']);
    await cli(port,['plan','list','--bot','astra']);
  });
  assert.deepEqual(seen.map(r=>r.action),['board','board_post','harness_request','plan_save','plan_run','plan_save','plans']);
  assert.equal(seen[1].args.title,'x'); assert.equal(seen[1].bot,'astra');
  assert.equal(seen[3].args.name,'east'); assert.equal(seen[3].args.steps[0].action,'walk');
  assert.equal(seen[4].args.name,'east'); assert.equal(seen[5].args.delete,true);
  await assert.rejects(cli(1,['plan','run']),(e:any)=>/requires a plan NAME/.test(e.stdout+e.stderr));
  await assert.rejects(cli(1,['board','bogus']),(e:any)=>/board expects/.test(e.stdout+e.stderr));
});
function compact(port:number,args:string[],env:Record<string,string>={},input?:string) {
  const child=execFile(process.execPath,['dist/host/cli.js','--port',String(port),...args],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only',...env}});
  const done=new Promise<{code:number|null,stdout:string}>((resolve)=>{
    let stdout='';child.stdout!.on('data',d=>stdout+=d);child.on('close',code=>resolve({code,stdout}));
  });
  if(input!==undefined)child.stdin!.end(input);
  return done;
}
test('say takes plain text, a file or stdin, without JSON quoting',async()=>{
  const seen:any[]=[];
  const {writeFile,mkdtemp}=await import('node:fs/promises');
  const dir=await mkdtemp('.cache/say-');
  await writeFile(`${dir}/line.txt`,"it's \"done\" $HOME\n");
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length}};},async port=>{
    await cli(port,['say',"I'll","bring","gears",'--bot','astra']);
    await cli(port,['say','--text-file',`${dir}/line.txt`,'--aloud','--bot','astra']);
    assert.equal((await compact(port,['say','-','--bot','astra'],{},"from stdin, it's fine\n")).code,0);
    assert.equal((await compact(port,['say','--bot','astra'],{},'piped\n')).code,0);
    const empty=await compact(port,['say','--bot','astra'],{},'');
    assert.equal(empty.code,1); assert.match(empty.stdout,/error: client_error: say needs text/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args.text,r.args.aloud]),[
    ['say',"I'll bring gears",undefined],['say','it\'s "done" $HOME',true],['say',"from stdin, it's fine",undefined],['say','piped',undefined]]);
});
test('chat and board events take --since; chat --limit and --peek',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{messages:[],cursor:9}};},async port=>{
    await cli(port,['chat','--bot','astra']);
    await cli(port,['chat','--since','0','--limit','5','--peek','--bot','astra']);
    await cli(port,['call','chat','--since','7','--bot','astra']);
    await cli(port,['board','events','--since','12','--bot','astra']);
    await assert.rejects(cli(port,['call','status','--since','3']),(e:any)=>/--since applies to/.test(e.stdout));
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['chat',{}],['chat',{since:0,limit:5,peek:true}],['chat',{since:7}],['board_events',{since_seq:12}]]);
});
test('the clock line carries the time left from the deadline file',async()=>{
  const {writeFile,mkdtemp}=await import('node:fs/promises');
  const dir=await mkdtemp('.cache/deadline-');
  const at=new Date(Date.now()+23*60000+30000);
  const pad=(n:number)=>String(n).padStart(2,'0');
  await writeFile(`${dir}/deadline.txt`,`${at.getFullYear()}-${pad(at.getMonth()+1)}-${pad(at.getDate())} ${pad(at.getHours())}:${pad(at.getMinutes())}\n`);
  await engine(()=>({ok:true,result:{clock:'game 1m; +5s since your last request'}}),async port=>{
    const viaEnv=await compact(port,['call','status'],{FH_DEADLINE_FILE:`${dir}/deadline.txt`});
    assert.match(viaEnv.stdout,/clock: "game 1m; \+5s since your last request; deadline in 2[23]m"/);
    const viaFlag=await compact(port,['call','status','--deadline-file',`${dir}/deadline.txt`]);
    assert.match(viaFlag.stdout,/deadline in 2[23]m/);
    const missing=await compact(port,['call','status','--deadline-file',`${dir}/none.txt`]);
    assert.equal(missing.code,0); assert.doesNotMatch(missing.stdout,/deadline/);
  });
});
test('compact --wait: outcome, position, inventory change and one clock line; peek polls leave the hints for that reply',async()=>{
  const seen:any[]=[];
  let polls=0;
  await engine(request=>{
    seen.push(request);
    if(request.action==='observe'){
      const inventory=request.args.peek?[{name:'coal',count:10}]:[{name:'coal',count:4},{name:'iron-ore',count:12}];
      return {ok:true,result:{player:{position:{x:5,y:-2},health:250,max_health:250,inventory},
        ...(request.args.peek?{}:{team:{alerts:['attack near (0,0)']},clock:'game 2m; +3s since your last request',chat:{unread:1,latest:'sol: hi'}})}};
    }
    if(request.action==='mine')return {ok:true,result:{until_tick:120},};
    polls++;
    assert.equal(request.args.peek,true);
    return {ok:true,result:polls===1?{active:{kind:'mine',until_tick:120}}:{active:false,last:{kind:'mine',outcome:'target_mined',result:{mined:12}},position:{x:5,y:-2},
      factory:{huge:'status block'},evolution:{factor:0.1}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','mine','--args','{"position":{"x":5,"y":-3}}','--wait']);
    assert.equal(code,0);
    const second=stdout.slice(stdout.indexOf('\ntick:',1)+1);
    assert.match(second,/outcome: target_mined\naction: mine\nwaited_s: [\d.]+\nposition: 5,-2\ninventory: "coal-6 iron-ore\+12"\ndetail: mined=12\nteam: alerts=\["attack near \(0,0\)"\]\nclock: "game 2m; \+3s since your last request"\nchat: unread=1 latest="sol: hi"\n$/);
    assert.doesNotMatch(stdout,/huge|evolution/);
    assert.equal(stdout.match(/clock:/g)?.length,1);
  });
  assert.deepEqual(seen.map(r=>r.action),['observe','mine','status','status','observe']);
});
test('compact --wait on shoot reports the combat outcome, ammo used and the ammo-slot change, not the last movement',async()=>{
  // shake2: Grok's shoot "returned outcome move_to and did not spend ammo";
  // the magazines had gone from the ammo slots, which the diff skipped.
  let polls=0;
  await engine(request=>{
    if(request.action==='observe'){
      const ammo=request.args.peek?[{name:'firearm-magazine',count:10}]:[{name:'firearm-magazine',count:8}];
      return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[{name:'coal',count:5}],ammo},clock:'c'}};
    }
    if(request.action==='shoot')return {ok:true,result:{until_tick:60,ammo:10}};
    polls++;
    return {ok:true,result:polls===1?{active:false,combat:{until_tick:60}}
      :{active:false,combat:false,last:{kind:'move_to',outcome:'arrived'},last_combat:{outcome:'duration_elapsed',ammo_used:2}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','shoot','--args','{"auto":true,"ticks":60}','--wait']);
    assert.equal(code,0);
    const second=stdout.slice(stdout.indexOf('\ntick:',1)+1);
    assert.match(second,/outcome: duration_elapsed\naction: shoot\nwaited_s: [\d.]+\nposition: 1,1\ninventory: firearm-magazine-2\nammo_used: 2\n/);
    assert.doesNotMatch(second,/move_to|arrived/);
  });
});
test('--full keeps the whole completion status; fh wait is compact too',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='walk')return {ok:true,result:{until_tick:60}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:10,max_health:250,inventory:[]},clock:'c'}};
    polls++;
    return {ok:true,result:{active:false,last:{kind:'walk',outcome:'duration_elapsed'},evolution:{factor:0.1},team:request.args.peek?undefined:{board:['x']}}};
  },async port=>{
    const full=await compact(port,['call','walk','--args','{"direction":"east","ticks":60}','--wait','--full']);
    assert.match(full.stdout,/completion:/); assert.match(full.stdout,/evolution/); assert.match(full.stdout,/board=\[x\]/);
    const idle=await compact(port,['wait']);
    assert.match(idle.stdout,/^outcome: duration_elapsed\naction: walk\nwaited_s: [\d.]+\nposition: 1,1\nhealth: "10\/250"\nclock: c\n$/m);
  });
});
test('a compact wait that ends badly still ends with the error line and exits nonzero',async()=>{
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:60}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]},clock:'c'}};
    return {ok:true,result:{active:false,last:{kind:'move_to',outcome:'blocked'}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','move_to','--args','{"position":{"x":9,"y":9}}','--wait']);
    assert.equal(code,1);
    assert.match(stdout,/outcome=blocked/);
    assert.match(stdout,/\nerror: action_interrupted: Control ended: blocked\n$/);
  });
});
test('polls fall back to plain status on a runtime without peek',async()=>{
  const seen:any[]=[];
  await engine(request=>{
    seen.push(request);
    if(request.args?.peek)return {ok:false,error:{code:'invalid_argument',message:'unknown argument peek for status'}};
    if(request.action==='walk')return {ok:true,result:{until_tick:60}};
    return {ok:true,result:{active:false,last:{kind:'walk',outcome:'duration_elapsed'}}};
  },async port=>{
    const {stdout}=await cli(port,['call','walk','--args','{"direction":"east","ticks":60}','--wait']);
    assert.equal(JSON.parse(stdout).ok,true);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args.peek??false]),[['walk',false],['status',true],['status',false]]);
});
