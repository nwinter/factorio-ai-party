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
    return {ok:true,result:polls===1?{active:{kind:'shoot'},combat:{until_tick:60}}:{active:false,combat:false,last_combat:{outcome:'interrupted'}}};
  },async port=>{
    try {
      await cli(port,['call','shoot','--args','{"auto":true,"ticks":60}','--wait']);
      assert.fail('interrupted action must exit nonzero');
    } catch(error:any) {
      assert.equal(error.code,1);
      assert.equal(JSON.parse(error.stdout).error.code,'action_interrupted');
      assert.equal(polls,2);
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
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.outcome,'fed'); assert.equal(polls,2);
  });
});
test('compact CLI output preserves failure details and nonzero exit status',async()=>{
  await engine(()=>({ok:false,error:{code:'placement_blocked',message:'Cannot build here'}}),async port=>{
    await assert.rejects(cli(port,['call','build','--format','compact']), (error:any)=>{
      assert.equal(error.code,1);
      assert.match(error.stdout,/^error: code=placement_blocked message="Cannot build here"/);
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
    assert.equal(reply.ok,true); assert.equal(reply.result.idle,true); assert.equal(reply.result.last.outcome,'constructed'); assert.equal(polls,3);
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
