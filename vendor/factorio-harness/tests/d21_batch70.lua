-- d20 batch70 (operator d21 13:09). Run from the harness root: lua tests/d21_batch70.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- AF2 (viewer Aurora: "Freight review shows 12 missed runs despite newer freight work in chat"; world n #107
-- verify-native-freight-receipts went to its owner Astra alone, every 10 min, and no one was told of the misses): a
-- backup told once when a recipient misses a run, a result the backup records for them, each recipient's latest.
do
  game={tick=0}
  local st={}
  local agents={{name='astra',index=1},{name='sol',index=2},{name='luna',index=3}}
  local boxes={}
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua'){state=function() return st end,
    resolve=function(w) for _,a in ipairs(agents) do if a.name==w then return w end end error('no teammate '..w,0) end,
    agents=function() return agents end,who=function(p) return p.name end,
    deliver=function(index,t) boxes[index]=boxes[index] or {}; table.insert(boxes[index],t) end}
  local astra,sol,luna={name='astra',index=1},{name='sol',index=2},{name='luna',index=3}
  local function run(ticks) for _=1,ticks do game.tick=game.tick+1; R.tick() end end
  fails(function() R.handlers.reminder_add(astra,{message='x',every_ticks=36000,backup='team'}) end,'backup: one teammate\'s name')
  fails(function() R.handlers.reminder_add(astra,{message='x',every_ticks=36000,backup={'sol'}}) end,'backup: one teammate\'s name')
  local add=R.handlers.reminder_add(astra,{name='verify-native-freight-receipts',message='Verify native-route receipts',every_ticks=36000,backup='sol'})
  eq(add.reminder.backup,'sol')
  run(36000)  -- the first run: astra's line, nothing to sol
  eq(#boxes[1],1); eq(boxes[2],nil)
  R.handlers.reminder_ack(astra,{id=1,result='K2 Fulgora PU777/1000, LDS1156'})
  run(36000)  -- the second run, acknowledged: no miss
  eq(boxes[2],nil)
  run(36000)  -- the third: astra's second line waits; a run missed, the backup told once
  eq(#boxes[2],1)
  eq(boxes[2][1].from,'reminder #1')
  eq(boxes[2][1].text,'astra missed a run of reminder #1 verify-native-freight-receipts (astra\'s, every 10m00s; you are its backup): not acknowledged since tick 72000 (10m00s ago), 1 run missed (tick 108000, 0s ago); astra\'s last result: K2 Fulgora PU777/1000, LDS1156 (20m00s ago); reminder_ack {id: 1, for: "astra", result} records one for them')
  run(36000*2)
  eq(#boxes[2],1,'once until astra acknowledges')
  local r=R.handlers.reminders(sol,{all=true}).reminders[1]
  has(r.states,'astra overdue (3 runs missed (the first at tick 108000, 20m00s ago; the last at tick 180000, 0s ago), backup sol told)')
  eq(#r.latest,1); local l=r.latest[1]
  eq(l.name,'astra'); eq(l.waiting_since_tick,72000); eq(l.missed,3); eq(l.acked_tick,36000); eq(l.result,'K2 Fulgora PU777/1000, LDS1156'); eq(l.backup_told_tick,108000)
  eq(l.line,'astra: waiting since tick 72000 (30m00s), 3 runs missed (the first at tick 108000, 20m00s ago; the last at tick 180000, 0s ago), backup sol told; last acknowledged 40m00s ago: K2 Fulgora PU777/1000, LDS1156')
  has(r.line,'; backup sol; ')
  has(r.line,'; latest: astra: waiting since tick 72000')
  -- the backup records a result for astra; only the backup or the owner may, for a recipient, not a checklist
  fails(function() R.handlers.reminder_ack(luna,{id=1,['for']='astra',result='x'}) end,'only reminder #1\'s backup (sol) or its owner')
  fails(function() R.handlers.reminder_ack(sol,{id=1,['for']='luna',result='x'}) end,'luna is not a recipient of reminder #1')
  local a=R.handlers.reminder_ack(sol,{id=1,['for']='astra',result='Kestrel II receipts in the pod ledger: PU 346 landed'})
  eq(a['for'],'astra'); eq(a.missed,3)
  l=R.handlers.reminders(astra,{}).reminders[1].latest[1]
  eq(l.state,'acknowledged'); eq(l.by,'sol'); eq(l.result,'Kestrel II receipts in the pod ledger: PU 346 landed'); eq(l.missed,nil)
  eq(l.line,'astra: acknowledged; last acknowledged 0s ago by sol for them: Kestrel II receipts in the pod ledger: PU 346 landed')
  eq(R.handlers.reminders(astra,{}).reminders[1].result_by,'sol')
  -- a new miss tells the backup again; a backup who is the recipient is not told; false clears it
  run(36000*2)
  eq(#boxes[2],2)
  R.handlers.reminder_edit(astra,{id=1,recipients='astra,sol'})
  R.handlers.reminder_ack(astra,{id=1}); R.handlers.reminder_ack(sol,{id=1})
  local before=#boxes[2]
  run(36000*2)
  eq(#boxes[2],before+2,'sol\'s own run line and the line for astra\'s miss; none for its own miss')
  has(boxes[2][#boxes[2]].text,'astra missed a run of reminder #1')
  r=R.handlers.reminders(astra,{}).reminders[1]
  local by={}; for _,x in ipairs(r.latest) do by[x.name]=x end
  eq(by.astra.backup_told_tick,game.tick); eq(by.sol.backup_told_tick,nil)
  eq(by.astra.result,nil,'acknowledged without a result'); has(by.astra.line,'last acknowledged 20m00s ago (no result given)')
  R.handlers.reminder_edit(astra,{id=1,backup=false})
  eq(R.handlers.reminders(astra,{}).reminders[1].backup,nil)
  -- a job from before results were kept: the last result by that recipient
  local j=st.reminders.jobs[1]
  j.results=nil; j.pending={}; j.acked={astra=game.tick-60,sol=game.tick-30}
  j.result_by='astra'; j.result_tick=game.tick-60; j.last_result='old result'
  by={}; for _,x in ipairs(R.handlers.reminders(astra,{}).reminders[1].latest) do by[x.name]=x end
  eq(by.astra.result,'old result'); eq(by.sol.result,nil)
  game=nil
end
print('d21_batch70 AF2 reminder backup and latest results: ok')

-- AF3 (viewer Aurora, 15:07: "Could agent cards show the engineer's own current task plus background tests/deadlines,
-- and flag stale plan/focus text?"): status {brief, work} gives the watches running or needing the agent
-- (measures.card); a queue's active step names its label and the submission it came in (queue_lanes run).
do
  game={tick=10000}
  local st={turret_tally={},uptime={}}
  local Ms=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return st end}
  eq(Ms.card(1),nil,'no watches')
  st.turret_tally[1]={start=9400,until_tick=12400,next_tick=10060,samples=10,sampled=10000,reason='Sol asked for 50 s',
    turrets={{position={x=4,y=5},k0=1,k1=3,first=9500},{position={x=6,y=5},k0=0,k1=0}}}
  st.uptime[1]={start=1000,until_tick=4600,samples=60,read_tick=4000,result={},machines={{position={x=1,y=1},recipe='iron-plate',status={working=60}}}}
  local c=Ms.card(1)
  eq(#c,2,'the running one and the done one with its final not read')
  eq(c[1].id,'turret_tally@9400'); eq(c[1].state,'running'); eq(c[1].end_tick,12400); eq(c[1].start_tick,9400)
  eq(c[1].scope,'2 turrets from (4,5)'); eq(c[1].latest.line,'1 of 2 turrets with a change, kills +2'); eq(c[1].latest.tick,10000)
  eq(c[1].reason,'Sol asked for 50 s')
  eq(c[2].id,'uptime@1000'); eq(c[2].state,'done')
  st.uptime[1].read_tick=4700
  eq(#Ms.card(1),1,'its final read: not on the card')
  st.uptime[1].read_tick=nil
  game.tick=4600+216001
  st.turret_tally[1]=nil
  eq(Ms.card(1),nil,'ended over an hour ago: off the card, read or not')
  eq(#Ms.flags(1),0)
  game.tick=10000
  -- a statistics watch (items, no machines): its items are its scope; a belt_flow from before surface_name
  st.uptime[1]={start=9900,until_tick=17100,samples=5,sampled=10000,machines={},flows={surface='nauvis',rows={{name='iron-plate',quality='normal'},{name='iron-plate',quality='rare'},{name='copper-cable',quality='normal'}}}}
  st.belt_flow={[1]={start=9990,until_tick=10500,samples=2,sampled=10000,path_from={x=1,y=2},path_to={x=9,y=2},tiles=8,surface='nauvis',points={{left={{},{}}}}}}
  c=Ms.card(1)
  eq(c[1].id,'belt_flow@9990'); eq(c[1].scope,'belt line (1,2) to (9,2) (8 tiles) on nauvis')
  eq(c[2].id,'uptime@9900'); eq(c[2].state,'running'); eq(c[2].scope,'items iron-plate, copper-cable'); eq(c[2].latest.line,'production statistics')
  st.uptime[1]=nil; st.belt_flow=nil
  -- the queue's active step: its label and the submission it came in
  local qs={}
  local base={state=function() return qs end,player=function() return {index=1,valid=true} end,handlers={},
    condition=function() return false end,wait_check=function() return false end,validate_condition=function() end,
    busy=function() return false end,stop=function() end,stop_index=function() end}
  local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
  local S=dofile('mod/agent-harness_0.1.0/queue_lanes.lua'){scheduler=factory(base),factory=factory,base=base,is_read=function() return false end}
  local p={index=1,valid=true}
  S.handlers.queue_submit(p,{steps={{action='wait_ticks',args={ticks=600},label='hold the line'},{action='wait_ticks',args={ticks=60}}}})
  for _=1,3 do game.tick=game.tick+1; S.tick() end
  local b=S.lanes(1).body
  eq(b.active.label,'hold the line'); eq(b.active.run.kind,'submit'); eq(b.active.run.tick,10000); eq(b.active.run.steps,2)
  S.handlers.queue_submit(p,{steps={{action='wait_ticks',args={ticks=60}}}})
  eq(S.lanes(1).body.active.run,nil,'a step from an earlier submission than the latest')
  game=nil
end
print('d21_batch70 AF3 card watches and queue runs: ok')
