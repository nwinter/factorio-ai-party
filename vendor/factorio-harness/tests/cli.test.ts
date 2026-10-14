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
test('fh help ACTION and fh call ACTION --help print that action from describe (help was an unknown command)',async()=>{
  await engine(request=>{
    assert.equal(request.action,'describe');
    return {ok:true,result:{actions:{circuit_set:{position:'{x,y} of the entity',enable:'a condition',returns:'the readback'}}}};
  },async port=>{
    for (const args of [['help','circuit_set'],['call','circuit_set','--help']]) {
      const {stdout}=await cli(port,args);
      assert.equal(stdout,"circuit_set: fh call circuit_set --args '{...}'\n  position: {x,y} of the entity\n  enable: a condition\nreturns: the readback\n");
    }
  });
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
test('--wait on a pickup that took everything succeeds (picked_up)',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='pickup')return {ok:true,result:{until_tick:60,item_stacks:2}};
    assert.equal(request.action,'status');polls++;
    return {ok:true,result:polls===1?{active:{kind:'pickup'}}:{active:false,last:{kind:'pickup',outcome:'picked_up',picked:{coal:100}}}};
  },async port=>{
    const {stdout}=await cli(port,['call','pickup','--args','{"radius":8}','--wait']);
    assert.equal(JSON.parse(stdout).ok,true);
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
      assert.equal(error.code,3,'3: the action still runs');
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
      assert.equal(error.code,3);
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
test('confess takes text like say and maps to the confess action',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length,note:'viewers hear this; teammates do not'}};},async port=>{
    await cli(port,['confess',"I","don't","trust","grok's","belts",'--bot','astra']);
    assert.equal((await compact(port,['confess','-','--bot','astra'],{},"it's going fine\n")).code,0);
    const loud=await compact(port,['confess','x','--aloud','--bot','astra']);
    assert.equal(loud.code,1); assert.match(loud.stdout,/error: client_error: --aloud applies to say/);
    const empty=await compact(port,['confess','--bot','astra'],{},'');
    assert.match(empty.stdout,/error: client_error: confess needs text/);
    await cli(port,['call','confessions','--since','4','--bot','astra']);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['confess',{text:"I don't trust grok's belts"}],['confess',{text:"it's going fine"}],['confessions',{since:4}]]);
});
test('operator takes text like say and maps to the operator action',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length,note:'filed for the operator'}};},async port=>{
    await cli(port,['operator','a','viewer',"wants","Grok's",'voice','louder','--bot','astra']);
    assert.equal((await compact(port,['operator','-','--bot','astra'],{},"belt_route can't start diagonally\n")).code,0);
    await cli(port,['call','operator','tools','request','--bot','astra']);
    const loud=await compact(port,['operator','x','--aloud','--bot','astra']);
    assert.equal(loud.code,1); assert.match(loud.stdout,/an operator request goes to the operator/);
    const empty=await compact(port,['operator','--bot','astra'],{},'');
    assert.match(empty.stdout,/error: client_error: operator needs text/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['operator',{text:"a viewer wants Grok's voice louder"}],
    ['operator',{text:"belt_route can't start diagonally"}],['operator',{text:'tools request'}]]);
});
test('tell takes recipients then text like say; tells reads with --since',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:seen.length,to:['sol']}};},async port=>{
    await cli(port,['tell','sol',"29","plates","in","the","chest","at","(-18.5,-34.5)",'--bot','astra']);
    assert.equal((await compact(port,['tell','luna,sol','-','--bot','astra'],{},"it's in the mall chest\n")).code,0);
    await cli(port,['tell','team','north belt is down','--bot','astra']);
    const loud=await compact(port,['tell','sol','x','--aloud','--bot','astra']);
    assert.equal(loud.code,1); assert.match(loud.stdout,/error: client_error: --aloud applies to say; a tell stays off/);
    const noname=await compact(port,['tell','--bot','astra']);
    assert.match(noname.stdout,/error: client_error: tell needs a name/);
    const empty=await compact(port,['tell','sol','--bot','astra'],{},'');
    assert.match(empty.stdout,/error: client_error: tell needs text: fh tell NAME "text"/);
    await cli(port,['tells','--since','2','--bot','astra']);
    await cli(port,['call','tell','sol','call','form','--bot','astra']);
    await cli(port,['call','tell','--args','{"to":"sol","text":"json form"}','--bot','astra']);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['tell',{to:'sol',text:'29 plates in the chest at (-18.5,-34.5)'}],
    ['tell',{to:'luna,sol',text:"it's in the mall chest"}],['tell',{to:'team',text:'north belt is down'}],['tells',{since:2}],
    ['tell',{to:'sol',text:'call form'}],['tell',{to:'sol',text:'json form'}]]);
});
test('vote, votes, players and restore take words; fh call accepts the same words',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{id:1}};},async port=>{
    await cli(port,['vote','kick','nick','mined',"the","bus's","poles",'--bot','astra']);
    await cli(port,['vote','no','kick','nick','--bot','astra']);
    await cli(port,['call','vote','yes','trust','nick','rebuilt it','--bot','astra']);
    await cli(port,['votes','--bot','astra']);
    await cli(port,['players','--bot','astra']);
    await cli(port,['players','nick','--args','{"minutes":30}','--bot','astra']);
    await cli(port,['call','restore','nick','--bot','astra']);
    await cli(port,['restore','--args','{"player":"nick","minutes":5}','--bot','astra']);
    const bare=await compact(port,['vote','kick','--bot','astra']);
    assert.equal(bare.code,1); assert.match(bare.stdout,/error: client_error: vote kick needs a player: fh vote kick PLAYER/);
    assert.match((await compact(port,['restore','--bot','astra'])).stdout,/error: client_error: restore needs a player/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['vote',{kind:'kick',player:'nick',reason:"mined the bus's poles"}],
    ['vote',{yes:false,kind:'kick',player:'nick'}],['vote',{yes:true,kind:'trust',player:'nick',reason:'rebuilt it'}],['votes',{}],
    ['players',{}],['players',{minutes:30,player:'nick'}],['restore',{player:'nick'}],['restore',{player:'nick',minutes:5}]]);
});
test('vote mute|unmute VIEWER reason maps to the vote action; vote list to votes',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{votes:1,needed:2,active:3}};},async port=>{
    await cli(port,['vote','mute','Troll42','slurs','in','chat','--bot','astra']);
    assert.equal((await compact(port,['vote','unmute','Troll42','-','--bot','astra'],{},"he's sorry\n")).code,0);
    await cli(port,['vote','list','--bot','astra']);
    const bad=await compact(port,['vote','poke','x','y','--bot','astra']);
    assert.equal(bad.code,1); assert.match(bad.stdout,/vote takes mute, unmute, kick, ban, trust or list/);
    assert.match((await compact(port,['vote','mute','--bot','astra'])).stdout,/vote mute needs a viewer/);
    assert.match((await compact(port,['vote','mute','bob','--bot','astra'])).stdout,/vote mute needs a reason/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['vote',{kind:'mute',viewer:'Troll42',reason:'slurs in chat'}],
    ['vote',{kind:'unmute',viewer:'Troll42',reason:"he's sorry"}],['votes',{}]]);
});
test('board plan takes goals, doing and for NAME as words; research [done] maps to research and research_done',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{plan:false}};},async port=>{
    await cli(port,['board','plan','--bot','astra']);
    await cli(port,['board','plan','goals','robots',"by",'hour','3','--bot','astra']);
    await cli(port,['board','plan','doing','oil','at','the','north','field','--bot','astra']);
    await cli(port,['board','plan','for','luna','scout','south','--bot','astra']);
    assert.equal((await compact(port,['board','plan','goals','-','--bot','astra'],{},"it's the plan\n")).code,0);
    await cli(port,['board','plan','doing','','--bot','astra']);
    await cli(port,['research','--bot','astra']);
    await cli(port,['research','done','--bot','astra']);
    assert.match((await compact(port,['board','plan','why','--bot','astra'])).stdout,/board plan takes goals "text", doing "text" or for NAME "text"/);
    assert.match((await compact(port,['board','plan','for','--bot','astra'])).stdout,/board plan for needs a NAME/);
    assert.match((await compact(port,['research','queue','--bot','astra'])).stdout,/research takes nothing or done/);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['board_plan',{}],['board_plan',{goals:'robots by hour 3'}],
    ['board_plan',{doing:'oil at the north field'}],['board_plan',{agent:'luna',doing:'scout south'}],['board_plan',{goals:"it's the plan"}],
    ['board_plan',{doing:''}],['research',{}],['research_done',{}]]);
});
test('fh call say with words sends them as text (it used to send {})',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{seq:1}};},async port=>{
    await cli(port,['call','say',"it's","fine",'--bot','astra']);
    await cli(port,['call','confess','quietly','--bot','astra']);
    await cli(port,['call','say','--args','{"text":"json form"}','--bot','astra']);
    await assert.rejects(cli(port,['call','say','--bot','astra']),(e:any)=>/say needs text/.test(e.stdout));
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args.text]),[['say',"it's fine"],['confess','quietly'],['say','json form']]);
});
test('--format json failures keep stdout one JSON document and print the error: line on stderr',async()=>{
  await engine(()=>({ok:false,error:{code:'action_failed',message:'no transport-belt in inventory'}}),async port=>{
    await assert.rejects(cli(port,['call','build']),(e:any)=>{
      assert.equal(JSON.parse(e.stdout).error.code,'action_failed');
      assert.equal(e.stderr.trim().split('\n').pop(),'error: action_failed: no transport-belt in inventory');
      return true;
    });
  });
  await engine(()=>({ok:true,result:{crafted:2,short:{'iron-plate':4}}}),async port=>{
    const {stdout,stderr}=await cli(port,['call','craft']);
    assert.equal(JSON.parse(stdout).result.crafted,2);
    assert.match(stderr,/^warning: short: /m);
  });
  await engine(()=>({ok:true,result:{seq:1}}),async port=>{
    assert.equal((await cli(port,['call','status'])).stderr,'');
  });
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
test('kite --wait waits for the fight to end and reports it like move_to',async()=>{
  // Sol, shift09: kite --wait returned at once while the kite still ran.
  for (const end of [
    {last:{kind:'kite',outcome:'clear',why:'no enemies left within the scan radius',kills:7,enemies_left:0,ammo_used:24,ammo_left:16}, code:0},
    {last:{kind:'kite',outcome:'timed_out',why:'time up',kills:2,enemies_left:5,ammo_used:10,ammo_left:30}, code:0},
    {last:{kind:'kite',outcome:'low_health',why:'health 38% fell below min_health 40%',kills:1,enemies_left:9,ammo_used:20,ammo_left:20}, code:1},
  ]) {
    let polls=0;
    await engine(request=>{
      if(request.action==='kite')return {ok:true,result:{until_tick:180,ammo:40,equipped:true}};
      if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:4},health:250,max_health:250,inventory:[]},clock:'c'}};
      polls++;
      return {ok:true,result:polls<3?{active:{kind:'kite',until_tick:180},combat:false}:{active:false,combat:false,last:end.last}};
    },async port=>{
      const {code,stdout}=await compact(port,['call','kite','--args','{"radius":30}','--wait']);
      assert.equal(code,end.code,stdout);
      assert.ok(polls>=3,'it polled until the kite ended');
      const second=stdout.slice(stdout.indexOf('\ntick:',1)+1);
      // A kite that stopped early is a failed wait: the same fields under error_result.
      assert.match(second,new RegExp(`outcome: ${end.last.outcome}\\n\\s*action: kite\\n`));
      for (const key of ['kills','enemies_left','ammo_used','ammo_left'] as const) assert.match(second,new RegExp(`\\n\\s*${key}: ${end.last[key]}\\n`));
      assert.match(second,new RegExp(`\\n\\s*why: "${end.last.why}"\\n`));
      if (end.code) assert.match(stdout,/\nerror: action_interrupted: Control ended: low_health: health 38% fell below min_health 40%\n$/);
    });
  }
});
test('a walk that gave up says why on the error line',async()=>{
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:60}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]},clock:'c'}};
    return {ok:true,result:{active:false,last:{kind:'move_to',outcome:'unreachable',why:'closed in: the character (0.4 tiles wide) fits through no gap out of the area (9,42)-(14,53) (about 45 tiles)',nearest_reachable:{x:9.5,y:42.5}}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','move_to','--args','{"position":{"x":6.5,"y":38.9}}','--wait']);
    assert.equal(code,1);
    assert.match(stdout,/nearest_reachable/);
    assert.match(stdout,/\nerror: action_interrupted: Control ended: unreachable: closed in: the character \(0\.4 tiles wide\) fits through no gap out of the area \(9,42\)-\(14,53\) \(about 45 tiles\)\n$/);
  });
});
test('move_to and drive --wait show gaps, escapes, enemies gone around; no_safe_route fails with why',async()=>{
  // Sol (shift09 03:13): trapped in gaps between pipes and machines; Opus (03:20): walked past a nest, a tank stuck on cliffs.
  const ends=[
    {action:'move_to',last:{kind:'move_to',outcome:'arrived_near',pocket:'(55,21) lies in a gap narrower than 0.7 tiles (assembling-machine-2 (53.5,22.5)) that no path led into; stopped at (51.5,24.4), 4.8 tiles from it (squeeze=true walks in)'},code:0,shown:['pocket']},
    {action:'move_to',last:{kind:'move_to',outcome:'arrived',escaped:'no path led out of the gap at (54.2,21): walked out to (55,24.3) first',avoided_enemies:['2 big-worm-turret around (88,165)'],passed_within_margin:['medium-worm-turret (60,170): 33.7 tiles (range 30)']},code:0,shown:['escaped','avoided_enemies','passed_within_margin']},
    {action:'move_to',last:{kind:'move_to',outcome:'unreachable',why:'closed in: ...; mining pipe (-27.5,69.5) opens a way out to (-26.7,69.5)',mine_to_get_out:['pipe (-27.5,69.5)']},code:1,shown:['mine_to_get_out']},
    {action:'move_to',last:{kind:'move_to',outcome:'no_safe_route',why:'no way to (100,0) around 4 medium-worm-turret around (100,0): the path passes medium-worm-turret (60,0) (range 30 + 4) at 0.0 tiles'},code:1,shown:[]},
    // movetarget: a walk to an entity's reach, an end within reach counted as arrived.
    {action:'move_to',last:{kind:'move_to',outcome:'arrived',reach:'iron-chest (20.5,0.5): 9.6 tiles to its box (transfer reach 10)',reach_note:'within its reach already when the walk ended unreachable'},code:0,shown:['reach','reach_note'],lines:['9.6 tiles to its box (transfer reach 10)','when the walk ended unreachable']},
    // round0620c: a via walk's legs, a build spot, a squeeze walked along gaps.
    {action:'move_to',last:{kind:'move_to',outcome:'arrived',legs:[{to:{x:10,y:100},outcome:'arrived',s:1.9,avoided_enemies:['1 medium-worm-turret around (14,104)']},{to:{x:32,y:104},outcome:'arrived',s:2.4}],squeezed:'no path request led into the gaps: walked them from (60.5,160.5) to (60,150.5)'},code:0,shown:['legs','squeezed'],lines:['(10,100) arrived 1.9s; around 1 medium-worm-turret around (14,104)','(32,104) arrived 2.4s']},
    {action:'move_to',last:{kind:'move_to',outcome:'unreachable',why:'no path request found a way for the character to (60.5,140.5), nor to anywhere within 15 tiles of it',build_spot:{x:60,y:150},build_spot_note:'(60,150) is reachable and within build reach of (60.5,140.5): 9.5 tiles (build reach 10); it lies in a gap narrower than 0.7 tiles',build_spot_squeeze:true,legs:[{to:{x:10,y:100},outcome:'unreachable',s:0.2,why:'no path'},{to:{x:32,y:104},outcome:'not walked'}]},code:1,shown:['build_spot','build_spot_note','build_spot_squeeze','legs'],lines:['(10,100) unreachable 0.2s: no path','(32,104) not walked']},
    {action:'vehicle',last:{kind:'drive',outcome:'arrived',path_length:69,backed_up:'stuck at (30.0,123.7) (in front: cliff (30,126.5)): backed up and asked for a new path',avoided_enemies:['1 medium-worm-turret around (60,170)']},code:0,shown:['path_length','backed_up','avoided_enemies']},
  ];
  for (const end of ends) {
    let polls=0;
    await engine(request=>{
      if(request.action===end.action)return {ok:true,result:{until_tick:180}};
      if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:4},health:250,max_health:250,inventory:[]},clock:'c'}};
      polls++;
      return {ok:true,result:polls<2?{active:{kind:end.last.kind,until_tick:180}}:{active:false,last:end.last}};
    },async port=>{
      const args=end.action==='vehicle'?'{"drive":{"x":30,"y":145}}':'{"position":{"x":55,"y":21}}';
      const {code,stdout}=await compact(port,['call',end.action,'--args',args,'--wait']);
      assert.equal(code,end.code,stdout);
      // A wait that ended in success lists fields one per line; a failed one on the error_result line (key=value).
      for (const key of end.shown) assert.match(stdout,new RegExp(`(\\n\\s*|\\s)${key}[:=]`),key);
      for (const line of (end as any).lines ?? []) assert.ok(stdout.includes(line),`${line} in ${stdout}`);
      if (end.last.outcome==='no_safe_route') assert.match(stdout,/\nerror: action_interrupted: Control ended: no_safe_route: no way to \(100,0\) around/);
    });
  }
});
test('a build that waited for a hand craft and then failed keeps the blocker on the error line',async()=>{
  // Sol, shift09: the silo build hit trees after its craft and read "Control ended: failed".
  let polls=0;
  const error='placement blocked by stingfrond (63.9375,11.375), stingfrond (68.125,12.4375); it needs the trees mined first (mine them, or place_ghosts marks them and construct clears them)';
  await engine(request=>{
    if(request.action==='build')return {ok:true,result:{awaiting_craft:{item:'rocket-silo',held:0,need:1,crafting:1},until_tick:900}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:60,y:19},health:250,max_health:250,inventory:[]},clock:'c'}};
    polls++;
    return {ok:true,result:polls<2?{active:{kind:'feed',awaiting_craft:true,until_tick:900}}:{active:false,last:{kind:'feed',handler:'build',outcome:'failed',tick:5,error}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','build','--args','{"item":"rocket-silo","position":{"x":65.5,"y":14.5}}','--wait']);
    assert.equal(code,1);
    assert.match(stdout,/error_result: outcome=failed action=build /);
    assert.ok(stdout.endsWith(`\nerror: action_interrupted: Control ended: failed: ${error}\n`),stdout);
  });
});
test('drop --wait follows a full drop\'s pods that wait for a hatch, apart from the character\'s action',async()=>{
  let polls=0;
  const pods=[{pod:1,drop:4,items:'iron-plate*1000',slots:10},{pod:2,drop:5,items:'coal*300',slots:6}];
  await engine(request=>{
    if(request.action==='drop')return {ok:true,result:{drop:4,pods:[pods[0]],pods_waiting:'1 more pod wait for a free hatch',until_tick:900}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]},clock:'c'}};
    polls++;
    // The character walks meanwhile: its own action is no part of the drop's wait.
    return {ok:true,result:polls<3?{active:{kind:'move_to',until_tick:5000},drop_pending:{kind:'drop',pods_sent:1,pods_left:1,until_tick:900}}
      :{active:{kind:'move_to',until_tick:5000},last_drop:{kind:'drop',outcome:'dropped',tick:7,result:{pods,dropped:['iron-plate*1000','coal*300']}}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','drop','--args','{"platform":"Sunward","full":true,"items":[{"item":"iron-plate","count":1000},{"item":"coal","count":300}]}','--wait']);
    assert.equal(code,0,stdout);
    assert.ok(polls>=3,'it polled until the pods were sent');
    assert.match(stdout,/outcome: dropped\n\s*action: drop\n/);
    assert.match(stdout,/coal\*300/);
  });
  // Pods not sent: the error line says why.
  polls=0;
  await engine(request=>{
    if(request.action==='drop')return {ok:true,result:{drop:4,pods:[pods[0]],until_tick:900}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:1,y:1},health:250,max_health:250,inventory:[]},clock:'c'}};
    polls++;
    return {ok:true,result:polls<2?{drop_pending:{kind:'drop',pods_left:1,until_tick:900}}
      :{last_drop:{kind:'drop',outcome:'failed',tick:7,why:'platform Sunward left vulcanus (at vulcanus->nauvis 2%)',result:{pods:[pods[0]],not_sent:'coal*300'}}}};
  },async port=>{
    const {code,stdout}=await compact(port,['call','drop','--args','{"platform":"Sunward","full":true,"items":[{"item":"coal","count":300}]}','--wait']);
    assert.equal(code,1);
    assert.ok(stdout.endsWith('\nerror: action_interrupted: Control ended: failed: platform Sunward left vulcanus (at vulcanus->nauvis 2%)\n'),stdout);
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
