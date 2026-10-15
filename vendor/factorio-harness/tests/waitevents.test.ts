// Agent-minds study fixes in the CLI (eng/minds-waits): the OPERATOR: line (fix 1), waits a tell or mention ends
// (fix 5), and one blocking wait on an event with one line out (fh wait --until, fix 5). Also the open board projects
// fh files for the post-compaction brief (eng/projects).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const exec = promisify(execFile);
// sleep_check goes over the wire as observe {scope: sleep_check} (host/harness.ts).
const isCheck=(r:any)=>r.action==='sleep_check'||(r.action==='observe'&&r.args?.scope==='sleep_check');
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
const env={...process.env,FACTORIO_RCON_PASSWORD:'test-only',FH_OPERATOR_FILE:'',FH_PROJECTS_FILE:''};
function cli(port:number,args:string[],format:'json'|'compact'='json',extra:Record<string,string>={}) {
  return exec(process.execPath,['dist/host/cli.js','--format',format,'--port',String(port),...args],{env:{...env,...extra}});
}
const OPERATOR={seq:7,ago_s:30,text:'Operator (automatic, facts only): your character has stood idle for 12 min.'};
test('an operator tell prints an OPERATOR: line on stderr and first on stdout, and is filed once for the hook',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'fh-operator-'));
  await writeFile(join(dir,'.context-hooks'),'claude haiku 140000\n');  // a workspace with the post-tool hook
  await engine(request=>({ok:true,result:{clock:'game 1s',position:{x:1,y:2},...(request.action==='status'?{operator:[OPERATOR]}:{})}}),async port=>{
    // shown once per message (Muse, shift17 10:50: repeated banners buried piped output): the first call prints it, a
    // later call whose reply still carries it (filed already) leaves it out; --operator-repeat prints it again
    for (let i=0;i<2;i++) {
      const {stdout,stderr}=await cli(port,['call','status','--journal',join(dir,'journal.jsonl')],'compact');
      const line='OPERATOR: Operator (automatic, facts only): your character has stood idle for 12 min. (sent 30 s ago; shown once: later replies leave it out)';
      if (i===0) {
        assert.equal(stdout.split('\n')[0],line);
        assert.equal(stdout.split('\n').filter(l=>l.startsWith('OPERATOR:')).length,1,'once on stdout');
        assert.match(stderr,/^OPERATOR: Operator \(automatic/m);
      } else {
        assert.doesNotMatch(stdout+stderr,/OPERATOR:/,'not again in a later call');
      }
      assert.doesNotMatch(stdout,/^operator/m,'not again as a field');
    }
    const again=await cli(port,['call','status','--journal',join(dir,'journal.jsonl'),'--operator-repeat'],'compact');
    assert.match(again.stdout.split('\n')[0]!,/^OPERATOR: Operator \(automatic.*repeated on every reply until your next game action or message\)$/);
    const env=await cli(port,['call','status','--journal',join(dir,'journal.jsonl')],'compact',{FH_OPERATOR_REPEAT:'1'});
    assert.match(env.stdout.split('\n')[0]!,/^OPERATOR: /);
    // a workspace without the hook (no .context-hooks; Gemini's): every call prints it, as before
    const bare=await mkdtemp(join(tmpdir(),'fh-operator-bare-'));
    for (let i=0;i<2;i++) assert.match((await cli(port,['call','status','--journal',join(bare,'journal.jsonl')],'compact')).stdout.split('\n')[0]!,/^OPERATOR: .*repeated on every reply/);
    // no operator file (no journal, no FH_OPERATOR_FILE): every call prints it, as before
    for (let i=0;i<2;i++) assert.match((await cli(port,['call','status'],'compact')).stdout.split('\n')[0]!,/^OPERATOR: .*repeated on every reply/);
    const filed=(await readFile(join(dir,'.operator-tells.jsonl'),'utf8')).trim().split('\n').map(l=>JSON.parse(l));
    assert.equal(filed.length,1,'filed once across calls'); assert.equal(filed[0].seq,7); assert.equal(filed[0].text,OPERATOR.text);
    // JSON keeps the field (programs read it) and nothing else is printed, so `--format json 2>&1` parses whole
    // (Muse, shift12, read every data call that way and cut the OPERATOR line off by hand).
    const {stdout,stderr}=await cli(port,['call','status']);
    assert.deepEqual(JSON.parse(stdout).result.operator,[OPERATOR]); assert.equal(stderr,'');
    assert.deepEqual(JSON.parse(stderr+stdout).result.operator,[OPERATOR]);
  });
});
test('open projects from the shift block, board reads and project items are filed for the post-compaction brief',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'fh-projects-'));
  const lines=['#12 nuclear plant: 1 of 4 steps; owner astra (last request 0s ago); next 2. centrifuges','#15 robot mall: 0 of 1 step; owner grok (last request 3m00s ago); next 1. roboports'];
  const replies:Record<string,any>={
    status:{team:{shift:{shift:'shift 3, started 0s ago',projects:lines}}},
    board_update:{item:{id:12,kind:'project',title:'nuclear plant',status:'claimed',owner:'astra',progress:'2 of 4 steps',
      steps:['[x] 1. mine uranium (done by astra, 1m00s ago)','[x] 2. centrifuges (done by sol, 0s ago)','[ ] 3. reactor','[ ] 4. turbines'],handoff:'centrifuges run; reactor next at (130,120)'}},
    board_post:{item:{id:15,kind:'project',title:'robot mall',status:'done',owner:'grok',progress:'1 of 1 step'}},
    board:{items:[{id:20,kind:'project',title:'rail to iron',status:'open',progress:'no steps yet'},{id:21,kind:'task',title:'x',status:'open'}]},
  };
  await engine(request=>({ok:true,result:{clock:'game 1s',...(replies[request.action]??{})}}),async port=>{
    const journal=['--journal',join(dir,'journal.jsonl')];
    const read=async()=>JSON.parse(await readFile(join(dir,'.projects.json'),'utf8'));
    await cli(port,['call','status',...journal]);
    assert.deepEqual((await read()).lines,lines);
    await cli(port,['call','board_update','--args','{"id":12,"done":2}',...journal]);
    assert.equal((await read()).lines[0],'#12 nuclear plant: 2 of 4 steps; owner astra; next 3. reactor; handoff: centrifuges run; reactor next at (130,120)');
    await cli(port,['call','board_post','--args','{"kind":"project","title":"robot mall"}',...journal]);
    await cli(port,['board','projects',...journal]);
    const filed=await read();
    assert.deepEqual(filed.lines.map((l:string)=>l.split(':')[0]),['#12 nuclear plant','#20 rail to iron'],'done ones leave; a row read adds');
    assert.equal(filed.lines[1],'#20 rail to iron: no steps yet; no owner');
    assert.match(filed.at,/^\d{4}-\d\d-\d\dT/);
  });
});
test('fh board projects reads the open projects',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request);return {ok:true,result:{items:[]}};},async port=>{
    await cli(port,['board','projects']);
    await cli(port,['board','projects','--args','{"id":12}']);
  });
  assert.deepEqual(seen.map(r=>[r.action,r.args]),[['board',{kind:'project',status:'active'}],['board',{id:12}]]);
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
test('a tell or mention ends --wait on an action that keeps going (exit 3, outcome told, from, still_running)',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:600}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:3},inventory:[]},team:{tells:['astra, 0s ago: stop, coal first']}}};
    polls++;
    const active={kind:'move_to',until_tick:600};
    return {ok:true,result:polls<2?{active}:{active,inbox:{tick:5,woke:'told',from:'astra'},last:{kind:'walk',outcome:'duration_elapsed',tick:0}}};
  },async port=>{
    // Sol, shift09: `fh ... --wait && next` ran next while the walk still ran: exit 3 says it still runs.
    const failed:any=await cli(port,['call','move_to','--args','{"position":{"x":50,"y":5}}','--wait']).then(()=>assert.fail('exit 3 expected'),(error:any)=>error);
    assert.equal(failed.code,3);
    const reply=JSON.parse(failed.stdout);
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
    const failed:any=await cli(port,['wait']).then(()=>assert.fail('exit 3 expected'),(error:any)=>error);
    assert.equal(failed.code,3);
    const reply=JSON.parse(failed.stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.outcome,'mentioned'); assert.match(reply.result.note,/a mention from sol/);
  });
});
test('--wait-through-tells keeps waiting past a tell; the end lists it and the exit is the action\'s',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:600}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:50,y:5},inventory:[]},team:{tells:['astra, 2s ago: coal first']}}};
    polls++;
    const active={kind:'move_to',until_tick:600};
    if(polls<2)return {ok:true,result:{active}};
    if(polls<4)return {ok:true,result:{active,inbox:{tick:5,woke:'told',from:'astra'}}};
    return {ok:true,result:{active:false,inbox:{tick:5,woke:'told',from:'astra'},last:{kind:'move_to',outcome:'arrived',tick:300}}};
  },async port=>{
    const {stdout}=await cli(port,['call','move_to','--args','{"position":{"x":50,"y":5}}','--wait','--wait-through-tells']);
    const reply=JSON.parse(stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.outcome,'arrived');
    assert.deepEqual(reply.result.completion.told_during_wait,['tell from astra at tick 5']);
    // compact: the end shows the outcome, the tells and the team block
    polls=0;
    const compact=await cli(port,['call','move_to','--args','{"position":{"x":50,"y":5}}','--wait','--wait-through-tells'],'compact');
    assert.match(compact.stdout,/outcome: arrived/); assert.match(compact.stdout,/told_during_wait: \["tell from astra at tick 5"\]/);
    assert.match(compact.stdout,/coal first/);
  });
});
test('fh wait --wait-through-tells waits for the action through a mention',async()=>{
  let polls=0;
  await engine(()=>{
    polls++;
    const active={kind:'mine',until_tick:900};
    if(polls<3)return {ok:true,tick:polls,result:{active}};
    if(polls<5)return {ok:true,tick:polls,result:{active,inbox:{tick:3,woke:'mentioned',from:'sol'}}};
    return {ok:true,tick:polls,result:{active:false,combat:false,last:{kind:'mine',outcome:'target_mined'}}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['wait','--wait-through-tells'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.last.outcome,'target_mined');
    assert.deepEqual(reply.result.told_during_wait,['mention from sol at tick 3']);
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
    await cli(port,['wait','--until','alert low_power, starved','--max','300'],'compact');
    await cli(port,['wait','--until','item_count coal>=5','--max','120'],'compact');
    const json=JSON.parse((await cli(port,['wait','--until','tell','--max','60'])).stdout);
    assert.equal(json.result.line,"woke: told after 4 s (astra: coal please); your next reply's team block has the rest");
    await assert.rejects(cli(port,['wait','--until','tell','--max','901']),(error:any)=>/1\.\.900/.test(error.stdout));
  });
  const sleeps=seen.filter(r=>r.action==='sleep');
  assert.deepEqual(sleeps.map(r=>[r.args.seconds,r.args.condition,r.args.peek]),[
    [30,undefined,true],[600,{until:'alert'},true],[300,{until:'alert',kinds:['low_power','starved']},true],[120,{until:'item_count',item:'coal',at_least:5},true],[60,undefined,true]]);
  const reads=seen.filter(isCheck); assert(reads.length>0 && reads.every(r=>r.args.peek===true),'the team block waits for the next reply');
});
test('fh wait/sleep --until A|B: whichever holds first (Grok: alert|platform_arrived NAME was a client_error; Muse: the first chest to fill)',async()=>{
  const seen:any[]=[];
  await engine(request=>{
    seen.push(request);
    if(request.action==='sleep')return {ok:true,result:{while_asleep:'no queue and no action',sleeping_s:request.args.seconds}};
    return {ok:true,result:{slept_s:7,woke:'condition',met:'item_count coal',saw:'coal 60 at (10,39)'}};
  },async port=>{
    await cli(port,['wait','--until','alert|platform_arrived Sunward gleba','--max','300'],'compact');
    const {stdout}=await cli(port,['wait','--until','item_count coal>=50 at 10,39 | item_count iron-plate>=100 at 12,39 | tell','--max','120'],'compact');
    assert.equal(stdout,'woke: condition after 7 s (item_count coal: saw coal 60 at (10,39))\n');
    await cli(port,['wait','--until','tell|mention','--max','30'],'compact');
    await cli(port,['wait','--until','[{"until":"crafting_done"},{"until":"alert","kinds":["no_power"]}]','--max','60'],'compact');
    await cli(port,['sleep','45','--until','crafting_done | researched'],'compact');
    await cli(port,['sleep','30','--until','tell|alert'],'compact');
    await cli(port,['sleep','30','--until','tell|mention'],'compact');
    await cli(port,['sleep','30','--until','tell|alert|item_count item=coal at_least=50 platform=Sunward'],'compact');
  });
  const sleeps=seen.filter(r=>r.action==='sleep');
  assert.deepEqual(sleeps.map(r=>[r.args.seconds,r.args.condition]),[
    [300,{until:'any',conditions:[{until:'alert'},{until:'platform_arrived',platform:'Sunward',location:'gleba'}]}],
    [120,{until:'any',conditions:[{until:'item_count',item:'coal',at_least:50,positions:[{x:10,y:39}]},{until:'item_count',item:'iron-plate',at_least:100,positions:[{x:12,y:39}]}]}],
    [30,undefined],
    [60,{until:'any',conditions:[{until:'crafting_done'},{until:'alert',kinds:['no_power']}]}],
    [45,{until:'any',conditions:[{until:'crafting_done'},{until:'researched'}]}],
    [30,{until:'alert'}],[30,undefined],
    [30,{until:'any',conditions:[{until:'alert'},{until:'item_count',item:'coal',at_least:50,platform:'Sunward'}]}]]);
});
test('fh wait --max S waits for the action to end, at most S s; at once when idle; --until idle the same',async()=>{
  // friction1300 (Grok, Haiku): `fh wait --max 150` slept the whole 150 s while the walk had ended after 46.
  const seen:any[]=[];let polls=0;
  await engine(request=>{
    seen.push(request); polls++;
    return {ok:true,tick:polls*10,result:polls<3?{active:{kind:'move_to',until_tick:3600}}:{active:false,combat:false,last:{kind:'move_to',outcome:'arrived'}}};
  },async port=>{
    const started=Date.now();
    const reply=JSON.parse((await cli(port,['wait','--max','150'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.idle,true); assert.equal(reply.result.last.outcome,'arrived');
    assert(Date.now()-started<20000,'it returned when the walk ended, not after 150 s');
    assert.equal(seen.filter(r=>r.action==='sleep').length,0,'no sleep');
    polls=10;
    const idle=JSON.parse((await cli(port,['wait','--until','idle','--max','5'])).stdout);
    assert.equal(idle.result.idle,true);
  });
  await engine(()=>({ok:true,tick:5,result:{active:{kind:'mine',until_tick:99999}}}),async port=>{
    const started=Date.now();
    await assert.rejects(cli(port,['wait','--max','1']),(error:any)=>{
      assert.equal(error.code,3);
      const reply=JSON.parse(error.stdout);
      assert.equal(reply.error.code,'wait_timeout'); assert.equal(reply.result.still_running.kind,'mine');
      return true;
    });
    assert(Date.now()-started<15000,'it gave up after about 1 s');
    await assert.rejects(cli(port,['wait','--max','901']),(error:any)=>/1\.\.900/.test(error.stdout));
  });
});
test('fh wait with nothing running: the last action ended before the previous call is not the wait\'s, exit 0',async()=>{
  // friction3 (Haiku 23:03): two waits after a rearm had ended printed its old timed_out as a fresh error, exit 1;
  // Luna and Muse took a walk's and a collect's old outcome as the wait's.
  const dir=await mkdtemp(join(tmpdir(),'fh-idle-'));
  const pace=join(dir,'.fh-pace.json');
  await engine(()=>({ok:true,tick:6040,result:{active:false,combat:false,last:{kind:'gather',outcome:'timed_out',tick:640}}}),async port=>{
    // No call before it on record: the outcome is the wait's, as before (a failure exits 1).
    await assert.rejects(cli(port,['wait','--until','idle','--max','150'],'json',{FH_PACE_FILE:pace}),(error:any)=>{
      assert.equal(error.code,1); assert.equal(JSON.parse(error.stdout).error.code,'timed_out'); return true;
    });
    // That call's reply (tick 6040) came after the gather ended (tick 640): the next wait says nothing ran.
    const json=JSON.parse((await cli(port,['wait','--until','idle','--max','150'],'json',{FH_PACE_FILE:pace})).stdout);
    assert.equal(json.ok,true); assert.equal(json.result.idle,true); assert.equal(json.result.nothing_running,true);
    assert.equal(json.result.note,'nothing was running when this wait began: the last action, gather, ended timed_out 90 s ago, before your previous call');
    const {stdout}=await cli(port,['wait','--max','60'],'compact',{FH_PACE_FILE:pace});
    assert.match(stdout,/^outcome: idle$/m); assert.doesNotMatch(stdout,/timed_out at its own tick limit|^error/m);
    assert.match(stdout,/nothing was running when this wait began: the last action, gather, ended timed_out 90 s ago/);
  });
  // An action that ended after the previous call (a fast walk between its start and the wait) is still the wait's.
  await writeFile(pace,JSON.stringify({tick:600})+'\n');
  await engine(()=>({ok:true,tick:700,result:{active:false,combat:false,last:{kind:'move_to',outcome:'arrived',tick:640}}}),async port=>{
    const json=JSON.parse((await cli(port,['wait','--max','60'],'json',{FH_PACE_FILE:pace})).stdout);
    assert.equal(json.ok,true); assert.equal(json.result.last.outcome,'arrived'); assert.equal(json.result.nothing_running,undefined);
  });
});
test('a timed_out error line carries the action\'s why (round1820a: a move_to\'s limit and leg)',async()=>{
  const why='time ran out at (265.4,-251.7), 160.2 tiles from the target: its limit, 3600 ticks (1m00s), ran out on leg 4 of 7 (to (300,-260))';
  await engine(()=>({ok:true,tick:700,result:{active:false,combat:false,last:{kind:'move_to',outcome:'timed_out',tick:640,why}}}),async port=>{
    await assert.rejects(cli(port,['wait','--max','5']),(error:any)=>{
      const reply=JSON.parse(error.stdout);
      assert.equal(reply.error.code,'timed_out'); assert.equal(reply.error.message,`move_to timed_out at its own tick limit: ${why}`); return true;
    });
  });
});
test('fh ACTION runs as fh call ACTION, said in corrected (round1650d: Haiku\'s fh transfer, Luna\'s fh move_to)',async()=>{
  const seen:any[]=[];
  await engine(request=>{seen.push(request); return request.action==='mine' ? {ok:false,error:{code:'action_failed',message:'nothing to mine'}} : {ok:true,result:{moved:5}};},async port=>{
    const json=JSON.parse((await cli(port,['transfer','--args','{"position":{"x":1,"y":2},"item":"coal","count":5}'])).stdout);
    assert.equal(json.ok,true); assert.equal(json.result.corrected,'fh transfer runs as fh call transfer');
    assert(seen.some(r=>r.action==='transfer' && r.args.item==='coal'),'sent as the transfer action');
    const {stdout}=await cli(port,['transfer','--args','{"position":{"x":1,"y":2},"item":"coal","count":5}'],'compact');
    assert.match(stdout,/corrected: fh transfer runs as fh call transfer/);
    await assert.rejects(cli(port,['mine','--args','{"position":{"x":1,"y":2}}']),(error:any)=>{
      assert.match(JSON.parse(error.stdout).error.message,/nothing to mine \[fh mine runs as fh call mine\]/); return true;
    });
  });
  await assert.rejects(cli(1,['Transfer']),(error:any)=>/Unknown command Transfer/.test(error.stderr+error.stdout));
});
test('a sleep replaced by a newer one ends (woke replaced) without reading the other sleep\'s wake',async()=>{
  // shift08 20:07: Sol's Codex shell returned at 30 s, it slept again; the first call polled the new sleep and
  // ended timed_out ("advanced 16 game seconds in 48 real seconds").
  const seen:any[]=[];let checks=0;
  await engine(request=>{
    seen.push(request);
    if(request.action==='sleep')return {ok:true,result:{while_asleep:'no queue and no action',sleeping_s:30,until_tick:1801}};
    checks++;
    return {ok:true,result:checks<2?{slept_s:1,until_tick:1801}:{slept_s:0,until_tick:5400}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['sleep','30'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.woke,'replaced'); assert.match(reply.result.note,/another sleep \(until tick 5400\)/);
  });
  const reads=seen.filter(isCheck); assert(reads.length>0 && reads.every(r=>r.args.peek===true),'no read of the other sleep');
});
test('a sleep that would repeat a wake read under 10 s ago waits out the rest and then sleeps (team block kept)',async()=>{
  // Muse, shift08: "woke 4s ago" refusals burn turns when tells arrive mid-cycle.
  const seen:any[]=[];let sleeps=0;
  await engine(request=>{
    seen.push(request);
    if(request.action==='sleep'){
      sleeps++;
      if(sleeps===1)return {ok:true,result:{repeat:true,woke:'board',sleeping_s:0,until_tick:900,
        while_asleep:'this sleep did not start: you woke (board) 9 s ago; it ends at once and repeats that wake',team:{tells:['astra, 1s ago: coal please']}}};
      return {ok:true,result:{while_asleep:'no queue and no action',sleeping_s:5,until_tick:1500}};
    }
    return {ok:true,result:{slept_s:5,until_tick:1500,woke:'elapsed'}};
  },async port=>{
    const began=Date.now();
    const reply=JSON.parse((await cli(port,['sleep','5'])).stdout);
    assert(Date.now()-began>=2000,'waited out the rest of the 10 s');
    assert.equal(reply.ok,true); assert.equal(reply.result.woke,'elapsed'); assert.equal(reply.result.repeat,undefined);
    assert.equal(reply.result.waited_out,'your previous sleep woke (board) 9 s before this one, and a sleep within 10 s of a wake repeats that wake; this sleep started after 2 s more');
    assert.deepEqual(reply.result.team.tells,['astra, 1s ago: coal please']);
  });
  assert.equal(seen.filter(r=>r.action==='sleep').length,2);
});
test('fh wait --until on a runtime without sleep peek: the sleep as fh sleep, shown whole; alert says when it comes',async()=>{
  const seen:any[]=[];let checks=0;
  await engine(request=>{
    seen.push(request);
    if(request.action==='sleep'){
      if(request.args.peek)return {ok:false,error:{code:'invalid_request',message:'unknown argument peek for sleep; valid: condition, seconds'}};
      if(request.args.condition?.until==='alert')return {ok:false,error:{code:'invalid_request',message:'unknown condition alert'}};
      checks=0;return {ok:true,result:{while_asleep:'no queue and no action',sleeping_s:30,until_tick:1801,team:{tells:['astra, 1s ago: coal please']}}};
    }
    checks++;
    return {ok:true,result:checks<2?{slept_s:1,until_tick:1801}:{slept_s:4,until_tick:1801,woke:'told',tell:'astra: coal please'}};
  },async port=>{
    const {stdout}=await cli(port,['wait','--until','tell','--max','30'],'compact');
    assert.match(stdout,/coal please/); assert.match(stdout,/woke: told after 4 s \(astra: coal please\)/);
    await assert.rejects(cli(port,['wait','--until','alert']),(error:any)=>/alert wake comes with the next harness deploy/.test(error.stdout));
  });
  const sleeps=seen.filter(r=>r.action==='sleep');
  assert.deepEqual(sleeps.slice(0,2).map(r=>r.args.peek),[true,undefined],'tried with peek, then without');
  assert(seen.some(r=>isCheck(r)&&!r.args.peek),'the final read delivers the team block, shown');
});
// Astra 07:53: transfer {walk: true} moved 200 solid fuel, and the wait exited 1 with "Control ended: transferred".
// The walk runs as a 'gather' tour: the wait follows it and ends ok on transferred (exit 0, so && chains go on);
// a walk that reached nothing still fails.
test('transfer --wait with walk follows the tour and ends ok on transferred',async()=>{
  let polls=0, outcome='transferred';
  await engine(request=>{
    if(request.action==='transfer')return {ok:true,result:{op:'transfer',places:1,out_of_reach:1,direction:'to_entity',until_tick:3600}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:5,y:5},inventory:[]}}};
    polls++;
    if(polls<3)return {ok:true,tick:10+polls,result:{active:{kind:'gather',op:'transfer',until_tick:3600}}};
    return {ok:true,tick:300,result:{active:false,last:{kind:'gather',op:'transfer',outcome,transferred:200,tick:300}}};
  },async port=>{
    const args=['call','transfer','--args','{"position":{"x":40,"y":2},"item":"solid-fuel","count":200,"direction":"to_entity","walk":true}','--wait'];
    const reply=JSON.parse((await cli(port,args)).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.accepted.op,'transfer');
    assert.equal(reply.result.completion.last.outcome,'transferred'); assert.equal(reply.result.completion.last.transferred,200);
    assert(polls>=3,'it waited while the tour ran');
    // compact output too, and fh wait on a running walk
    polls=0;
    const compact=await cli(port,args,'compact');
    assert.match(compact.stdout,/transferred/); assert.doesNotMatch(compact.stdout,/Control ended/);
    polls=0;
    const waited=JSON.parse((await cli(port,['wait'])).stdout);
    assert.equal(waited.ok,true); assert.equal(waited.result.last.outcome,'transferred');
    // nothing reached: exit 1 with the outcome
    polls=0; outcome='unreached';
    const failed:any=await cli(port,args).then(()=>assert.fail('exit 1 expected'),(error:any)=>error);
    assert.equal(failed.code,1); assert.match(failed.stdout,/Control ended: unreached/);
  });
  // every target in reach: the runtime moved the items in the call (no until_tick); nothing to wait for
  let statusPolls=0;
  await engine(request=>{
    if(request.action==='transfer')return {ok:true,result:{transferred:5,moved:5,inventory:'fuel'}};
    statusPolls++;
    return {ok:true,result:{active:false}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['call','transfer','--args','{"position":{"x":1,"y":2},"item":"coal","count":5,"walk":true}','--wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.transferred,5); assert.equal(statusPolls,0);
  });
});
// Sol 11:18: build --wait over the character's own footprint stepped aside and returned at once ("built 1 of 5",
// until_tick), so the next chained call interrupted the rest. The step-aside runs as a timed 'feed' action that builds
// the rest: the wait follows it and exits by its outcome (fed: 0; failed: 1).
test('build --wait follows a step-aside through the rest of the batch and exits by its outcome',async()=>{
  let polls=0, outcome='fed';
  const builds='{"builds":[{"item":"stone-furnace","position":{"x":1,"y":1}},{"item":"stone-furnace","position":{"x":3,"y":1}},{"item":"stone-furnace","position":{"x":5,"y":1}},{"item":"stone-furnace","position":{"x":7,"y":1}},{"item":"stone-furnace","position":{"x":9,"y":1}}]}';
  await engine(request=>{
    if(request.action==='build')return {ok:true,result:{stepping_aside:{from:{x:3,y:1},to:{x:3,y:4}},until_tick:8891438,built:1,placed:[{x:1,y:1}]}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:3,y:4},inventory:[]}}};
    polls++;
    if(polls<3)return {ok:true,tick:8891300+polls,result:{active:{kind:'feed',until_tick:8891438}}};
    return {ok:true,tick:8891400,result:{active:false,last:{kind:'feed',outcome,tick:8891400,
      result:outcome==='fed'?{built:4,placed:[{x:3,y:1},{x:5,y:1},{x:7,y:1},{x:9,y:1}]}:undefined,
      error:outcome==='failed'?'build 2/4 failed after 1 built: trees in the way':undefined}}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['call','build','--args',builds,'--wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.accepted.built,1);
    assert.equal(reply.result.completion.last.outcome,'fed'); assert.equal(reply.result.completion.last.result.built,4);
    assert(polls>=3,'it waited while the character stepped aside and built the rest');
    polls=0; outcome='failed';
    const failed:any=await cli(port,['call','build','--args',builds,'--wait']).then(()=>assert.fail('exit 1 expected'),(error:any)=>error);
    assert.equal(failed.code,1); assert.match(failed.stdout,/Control ended: failed: build 2\/4 failed after 1 built: trees in the way/);
  });
  // a build placed at once (no step-aside): nothing to wait for
  let statusPolls=0;
  await engine(request=>{
    if(request.action==='build')return {ok:true,result:{built:1,entity:{name:'stone-furnace',position:{x:1,y:1}}}};
    statusPolls++;
    return {ok:true,result:{active:false}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['call','build','--args','{"item":"stone-furnace","position":{"x":1,"y":1}}','--wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.built,1); assert.equal(statusPolls,0);
  });
});
// shift12 15:20 (Sonnet): load_silo waiting for its rocket runs as a timed 'feed' action that loads (and launches)
// once the rocket is there: --wait follows it and exits by its outcome; loaded at once, there is nothing to wait for.
test('load_silo --wait follows the wait for the rocket and exits by its outcome',async()=>{
  let polls=0, outcome='fed';
  const args='{"position":{"x":65.5,"y":14.5},"items":{"agricultural-science-pack":1000},"launch":true,"platform":"Sunward"}';
  await engine(request=>{
    if(request.action==='load_silo')return {ok:true,tick:100,result:{waiting:{why:'the rocket is not ready to launch yet',rocket:'building the rocket: parts 46/50'},until_tick:3700}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:60,y:12},inventory:[]}}};
    polls++;
    if(polls<3)return {ok:true,tick:100+polls,result:{active:{kind:'feed',handler:'load_silo',until_tick:3700}}};
    return {ok:true,tick:900,result:{active:false,last:{kind:'feed',handler:'load_silo',outcome,tick:900,
      result:outcome==='fed'?{complete:true,launch:{launched:true,to:'platform Sunward'}}:undefined,
      error:outcome==='failed'?'not launched: agricultural-science-pack 200 short':undefined}}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['call','load_silo','--args',args,'--wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.accepted.waiting.why,'the rocket is not ready to launch yet');
    assert.equal(reply.result.completion.last.outcome,'fed'); assert.equal(reply.result.completion.last.result.launch.launched,true);
    assert(polls>=3,'it waited for the rocket');
    polls=0; outcome='failed';
    const failed:any=await cli(port,['call','load_silo','--args',args,'--wait']).then(()=>assert.fail('exit 1 expected'),(error:any)=>error);
    assert.equal(failed.code,1); assert.match(failed.stdout,/Control ended: failed/);
  });
  let statusPolls=0;
  await engine(request=>{
    if(request.action==='load_silo')return {ok:true,result:{complete:true,loaded:[{item:'agricultural-science-pack',loaded:1000}]}};
    statusPolls++;
    return {ok:true,result:{active:false}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['call','load_silo','--args',args,'--wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.complete,true); assert.equal(statusPolls,0);
  });
});
// Sol 12:20: collect --wait --wait-timeout 60000 read STILL RUNNING at 62 s over a gather that had ended collected
// (got 10 of 10) at 54.2 s game time: the poll after the deadline showed it ended and was not judged. That poll now
// ends the wait by the outcome; fh wait likewise. An action still running there still times out (exit 3).
test('--wait and fh wait judge the poll after the deadline: an action that ended there ends the wait by its outcome',async()=>{
  let began=0, endsAfter=1600, outcome='collected';
  const accepted=9079299, ended=9082549;
  await engine(request=>{
    if(request.action==='collect'){began=Date.now();return {ok:true,tick:accepted,result:{until_tick:9086499,got:0,want:10}};}
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:44,y:28},inventory:[]}}};
    if(Date.now()-began<endsAfter)return {ok:true,tick:accepted+60,result:{active:{kind:'gather',until_tick:9086499,got:9}}};
    return {ok:true,tick:ended+18,result:{active:false,last:{kind:'gather',outcome,got:10,want:10,tick:ended}}};
  },async port=>{
    const args=['call','collect','--args','{"position":{"x":44.5,"y":26.5},"item":"nutrients","count":10,"wait_ticks":3600}','--wait','--wait-timeout','1500'];
    const reply=JSON.parse((await cli(port,args)).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.outcome,'collected'); assert.equal(reply.result.completion.last.got,10);
    assert.equal(reply.result.timed_out,undefined);
    // ended badly at the deadline: exit 1 with its outcome
    outcome='nothing_collected';
    const failed:any=await cli(port,args).then(()=>assert.fail('exit 1 expected'),(error:any)=>error);
    assert.equal(failed.code,1); assert.match(failed.stdout,/Control ended: nothing_collected/);
    // fh wait: idle at the poll after the deadline is idle
    outcome='collected'; began=Date.now();
    const waited=JSON.parse((await cli(port,['wait','--wait-timeout','1500'])).stdout);
    assert.equal(waited.ok,true); assert.equal(waited.result.last.outcome,'collected');
    // still running at the poll after the deadline: STILL RUNNING, exit 3
    endsAfter=60000;
    const still:any=await cli(port,args).then(()=>assert.fail('exit 3 expected'),(error:any)=>error);
    assert.equal(still.code,3); assert.match(still.stdout,/STILL RUNNING/);
    began=Date.now();
    const stillIdle:any=await cli(port,['wait','--wait-timeout','1500']).then(()=>assert.fail('exit 3 expected'),(error:any)=>error);
    assert.equal(stillIdle.code,3); assert.equal(JSON.parse(stillIdle.stdout).result.still_running.kind,'gather');
  });
});
// Viewers' @mentions (Sonnet and Opus, shift12 13:50: they ended a sleep, a wait and a move_to --wait every minute or
// so): the poll carries them apart (inbox_viewer); they end a wait only with --wake-on-viewers.
test('a viewer\'s @mention does not end --wait; with --wake-on-viewers it does',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='move_to')return {ok:true,result:{until_tick:600}};
    if(request.action==='observe')return {ok:true,result:{player:{position:{x:50,y:5},inventory:[]}}};
    polls++;
    const active={kind:'move_to',until_tick:600};
    if(polls<2)return {ok:true,result:{active}};
    if(polls<4)return {ok:true,result:{active,inbox_viewer:{tick:5,woke:'mentioned',from:'viewer mo'}}};
    return {ok:true,result:{active:false,inbox_viewer:{tick:5,woke:'mentioned',from:'viewer mo'},last:{kind:'move_to',outcome:'arrived',tick:300}}};
  },async port=>{
    const reply=JSON.parse((await cli(port,['call','move_to','--args','{"position":{"x":50,"y":5}}','--wait'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.completion.last.outcome,'arrived');
    polls=0;
    const failed:any=await cli(port,['call','move_to','--args','{"position":{"x":50,"y":5}}','--wait','--wake-on-viewers']).then(()=>assert.fail('exit 3 expected'),(error:any)=>error);
    assert.equal(failed.code,3);
    const woke=JSON.parse(failed.stdout);
    assert.equal(woke.result.completion.outcome,'mentioned'); assert.equal(woke.result.completion.from,'viewer mo');
    assert.match(woke.result.completion.note,/a mention from viewer mo ended this wait/);
  });
});
test('--wake-on-viewers asks a sleep and a direct wait for it; a runtime without it is asked again without',async()=>{
  const seen:any[]=[];let checks=0;let old=true;
  await engine(request=>{
    seen.push(request);
    if(request.action==='sleep'){
      if(old&&request.args.wake_on_viewers)return {ok:false,error:{code:'action_failed',message:'unknown argument wake_on_viewers for sleep; valid: condition, peek, seconds'}};
      checks=0;return {ok:true,result:{while_asleep:'no queue and no action',sleeping_s:request.args.seconds}};
    }
    if(request.action==='wait_ticks'){
      if(old&&request.args.wake_on_viewers)return {ok:false,error:{code:'action_failed',message:'unknown argument wake_on_viewers for wait_ticks; valid: pause_queue, ticks'}};
      return {ok:true,result:{until_tick:60}};
    }
    if(request.action==='observe'&&!isCheck(request))return {ok:true,result:{player:{position:{x:0,y:0},inventory:[]}}};
    if(request.action==='status')return {ok:true,result:{active:false,last:{kind:'wait_ticks',outcome:'duration_elapsed',tick:61}}};
    checks++;
    return {ok:true,result:checks<2?{slept_s:1}:{slept_s:2,woke:'mentioned',mention:'viewer mo: @sol hi'}};
  },async port=>{
    old=false;
    await cli(port,['sleep','5','--wake-on-viewers']);
    let sleeps=seen.filter(r=>r.action==='sleep');
    assert.equal(sleeps.length,1); assert.equal(sleeps[0].args.wake_on_viewers,true);
    await cli(port,['sleep','5']);
    sleeps=seen.filter(r=>r.action==='sleep');
    assert.equal(sleeps[1].args.wake_on_viewers,undefined,'not asked without the flag');
    await cli(port,['call','wait_ticks','--args','{"ticks":60}','--wait','--wake-on-viewers']);
    assert.equal(seen.filter(r=>r.action==='wait_ticks')[0].args.wake_on_viewers,true);
    // A runtime from before it: asked again without (it wakes on viewers anyway).
    old=true;seen.length=0;
    const reply=JSON.parse((await cli(port,['sleep','5','--wake-on-viewers'])).stdout);
    assert.equal(reply.ok,true); assert.equal(reply.result.woke,'mentioned');
    sleeps=seen.filter(r=>r.action==='sleep');
    assert.equal(sleeps.length,2); assert.equal(sleeps[1].args.wake_on_viewers,undefined);
    seen.length=0;
    const waited=JSON.parse((await cli(port,['call','wait_ticks','--args','{"ticks":60}','--wait','--wake-on-viewers'])).stdout);
    assert.equal(waited.ok,true);
    const waits=seen.filter(r=>r.action==='wait_ticks');
    assert.equal(waits.length,2); assert.equal(waits[1].args.wake_on_viewers,undefined); assert.notEqual(waits[0].id,waits[1].id);
  });
});
test('urgent alerts (d15): --until alert takes an area and size filter, --no-urgent opts out, the wake line names the alert',async()=>{
  const seen:any[]=[];
  await engine(request=>{
    seen.push(request);
    if(request.action==='sleep')return {ok:true,result:{while_asleep:'no queue and no action',sleeping_s:request.args.seconds}};
    if(request.action==='wait_ticks')return {ok:true,result:{until_tick:100}};
    return {ok:true,result:{slept_s:3,woke:'urgent',urgent:'attack on our structures 14 tiles from you: attack #40 at (10,10)'}};
  },async port=>{
    const {stdout}=await cli(port,['wait','--until','alert near=10,-40 radius=80 min_size=5','--max','300'],'compact');
    assert.equal(stdout,"woke: urgent after 3 s (attack on our structures 14 tiles from you: attack #40 at (10,10)); your next reply's team block has the rest\n");
    await cli(port,['sleep','120','--until','alert area=-50,-50,50,50 surface=gleba','--no-urgent'],'compact');
    await cli(port,['wait','--until','tell|alert min_size=3'],'compact');
    await assert.rejects(cli(port,['wait','--until','alert low_power min_size=3']),(error:any)=>/kinds .* or a filter/.test(error.stdout+error.stderr));
    await assert.rejects(cli(port,['wait','--until','alert near=1']),(error:any)=>/near= takes 2 numbers/.test(error.stdout+error.stderr));
    await cli(port,['call','wait_ticks','--args','{"ticks":60}','--no-urgent'],'compact');
  });
  const sleeps=seen.filter(r=>r.action==='sleep');
  assert.deepEqual(sleeps.map(r=>[r.args.seconds,r.args.condition,r.args.wake_on_urgent]),[
    [300,{until:'alert',near:{x:10,y:-40},radius:80,min_size:5},undefined],
    [120,{until:'alert',area:{left_top:{x:-50,y:-50},right_bottom:{x:50,y:50}},surface:'gleba'},false],
    [600,{until:'alert',min_size:3},undefined]]);
  assert.equal(seen.find(r=>r.action==='wait_ticks').args.wake_on_urgent,false);
});
test('d15 H3/H4: fh wait prints the cap and what is open for the agent last',async()=>{
  await engine(request=>{
    if(request.action==='sleep')return {ok:true,result:{while_asleep:'no queue and no action: your character stands idle for up to 300 s',sleeping_s:300,capped:'capped at 300 s: no queue, action or condition'}};
    return {ok:true,result:{slept_s:300,woke:'elapsed',capped:'capped at 300 s: no queue, action or condition',
      open:'open for you: 1 board item of yours (#425 purple science [doing])'}};
  },async port=>{
    const {stdout}=await cli(port,['wait','--until','tell','--max','900'],'compact');
    assert.equal(stdout,'woke: elapsed after 300 s (capped at 300 s: no queue, action or condition); open for you: 1 board item of yours (#425 purple science [doing])\n');
    const out=(await cli(port,['sleep','900'],'compact')).stdout;
    assert.match(out,/^capped: "?capped at 300 s: no queue, action or condition"?$/m);
    assert.match(out,/^open: "?open for you: 1 board item of yours/m);
  });
});
