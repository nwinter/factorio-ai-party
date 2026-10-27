-- Run from repository root: lua tests/d27_batch261.lua
-- d27 batch261
-- GR (Sol #2505, from Astra: the AQ dock-capture guards outlived plan 402's six-step cleanup; at Asterion's next departure
-- the platform_left guard fired and its cleanup's circuit_set failed on the removed inserter, the remote lane paused until
-- cancelled at 70081080): guard scope plan (the default) retires a guard in the tick its lane has no step left; standing
-- keeps it; status, the history and the team block name what was retired and what is still armed.
-- AD (Astra #2508: Luna's 15-min PU boost from 70181005 had a relative timeout, set late and restarted by a body
-- pause/resume; the gate was restored 4m21s after its cutoff 70235005): wait_until tick_at_least {tick}, a step, an any
-- member and a guard on every lane; one passed is met at once; a pause or resume never moves it; a deadline guard on a
-- remote or platform lane fires at its tick while the lane is paused or held.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok,'expected a refusal: '..text); assert(tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={inventory={hub_main=1}}
prototypes={item={['processing-unit']={}},entity={},quality={normal={}},space_location={aquilo={},fulgora={}}}
game={tick=70000000}
local pu=0
local hub={valid=true,get_inventory=function() return {get_item_count=function(name) return name=='processing-unit' and pu or 0 end} end}
local asterion={valid=true,name='Asterion',index=3,hub=hub,surface={name='platform-3'},space_location={name='aquilo'}}
local force={name='player',platforms={asterion},technologies={}}
local sol={index=1,position={x=0,y=0},surface={name='nauvis'},force=force,crafting_queue_size=0}
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end}

-- AD: the condition
do
  eq(C.validate({['until']='tick_at_least',tick=70000600})['until'],'tick_at_least')
  has(C.names,'|tick_at_least|')
  local met,saw=C.check(sol,{['until']='tick_at_least',tick=70054000})
  eq(met,false); eq(saw,'tick 70054000: 54000 ticks left (15m00s)')
  met,saw=C.check(sol,{['until']='tick_at_least',tick=70000000}); eq(met,true); eq(saw,'tick 70000000 reached (now 70000000, 0m00s past it)')
  -- one passed already counts as met at once
  eq(C.validate({['until']='tick_at_least',tick=69000000}).tick,69000000)
  met,saw=C.check(sol,{['until']='tick_at_least',tick=69996400}); eq(met,true); has(saw,'1m00s past it')
  fails(function() C.validate({['until']='tick_at_least'}) end,'tick_at_least tick is a whole game tick 0..71296000 (now 70000000')
  fails(function() C.validate({['until']='tick_at_least',tick=70000000.5}) end,'whole game tick')
  fails(function() C.validate({['until']='tick_at_least',tick=71296001}) end,'at most 1296000 ticks, 6 game hours, ahead')
  fails(function() C.validate({['until']='tick_at_least',tick=70000001,platform='Asterion'}) end,'reads no platform')
  fails(function() C.validate({['until']='tick_at_least',tick=70000001,position={x=1,y=1}}) end,'reads the game tick only')
  -- the tick it is met by at the latest: its own; any's earliest member; all is not bounded by it
  eq(C.deadline({['until']='tick_at_least',tick=5}),5)
  eq(C.deadline({['until']='any',conditions={{['until']='item_count',platform='Asterion',item='processing-unit',at_least=1},
    {['until']='tick_at_least',tick=9},{['until']='tick_at_least',tick=7}}}),7)
  eq(C.deadline({['until']='all',conditions={{['until']='tick_at_least',tick=9}}}),nil)
  eq(C.deadline({['until']='crafting_done'}),nil)
  local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){check=function(p,c,record) return C.check(p,c,nil,record) end}
  local row=W.estimate(sol,{['until']='tick_at_least',tick=70003600},false,nil,{})
  eq(row.eta_s,60); eq(row.basis,'the game tick it names')
end
print('d27_batch261 AD tick_at_least: check, validation, deadline, ETA: ok')

-- The lanes as the runtime builds them, with a cleanup write that fails once its target is gone.
local removed=false
local s={active={}}
local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){}
local base={state=function() return s end,player=function() return sol end,
  handlers={platforms=function() return {} end,noop=function() return {done=true} end,
    circuit_set=function() if removed then error('target: entity not found at (-8.5,3.5)',0) end return {entity='fast-inserter'} end},
  busy=function() return false end,stop=function() end,stop_index=function() end,claim=function() end,direct_action=function() end,
  condition=function(p,c,record) return C.check(p,c,nil,record) end,validate_condition=function(c) return C.validate(c) end,
  wait_info=function(out,record) return W.info(out,record) end,outcome=function() return 'done' end,
  deadline=function(c) return C.deadline(c) end}
local make=require('scheduler')
local body_api={}; for k,v in pairs(base) do body_api[k]=v end
local body=make(body_api)
local lanes=require('queue_lanes'){scheduler=body,factory=make,base=base,is_read=function(name) return name=='platforms' end}
local h=lanes.handlers
local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; lanes.tick() end end
local function status(lane) return h.queue_status(sol,{lane=lane,history='all'}) end
local function q_of(lane) return lane=='remote' and s.remote_queues[1] or lane=='body' and s.queues[1] or s['lane_queues|'..lane:match('^platform:(.+)$')][1] end
local function cleanup()
  return {{action='circuit_set',args={platform='Asterion',position={x=-8.5,y=3.5},switch_off=true},label='cleanup'},
    {action='circuit_set',args={platform='Asterion',position={x=1.5,y=4.5},remove_condition=true}}}
end

-- GR: Astra's dock capture replayed in the remote lane: four guards on the cleanup, the plan runs its cleanup and is
-- done; at the next departure no guard is left to fire (scope plan, the default). A standing one keeps the old way.
do
  local guards={{when={['until']='platform_left',platform='Asterion',location='aquilo'},steps=cleanup()},
    {when={['until']='item_count',platform='Asterion',item='processing-unit',below=1},steps=cleanup()}}
  pu=50
  local r=h.queue_submit(sol,{lane='remote',steps={{action='circuit_set',args={platform='Asterion',position={x=-8.5,y=3.5},enable='signal-Z > 0'}},
    {action='wait_ticks',args={ticks=120}},cleanup()[1],cleanup()[2]},guards=guards})
  eq(#r.guards,2); eq(r.guards[1].scope,'plan'); eq(r.guards[2].scope,'plan')
  tick(60)
  eq(#q_of('remote').guards,2,'armed while the plan runs')
  tick(80)
  local st=status('remote')
  eq(st.active,false); eq(#st.pending,0)
  eq(st.guards,nil,'retired with the plan')
  local row=st.history[#st.history]
  eq(row.action,'guards_retired'); eq(row.result.guards[1],'guard-1'); eq(row.result.guards[2],'guard-2')
  has(row.result.line,'guards retired with it (scope plan): guard-1 platform_left, guard-2 item_count')
  -- retired in the tick of the last step
  eq(row.finished_tick,st.history[#st.history-1].finished_tick)
  local news=lanes.round_news(1)
  has(news[1],'remote queue plan #1 finished at tick '); has(news[1],'retired with it (scope plan)')
  eq(st.guards_after_plan,nil)
  -- the departure and the stock dip after it: nothing fires
  removed=true; asterion.space_location=nil; pu=0
  tick(40)
  st=status('remote')
  eq(st.paused,false); eq(st.history[#st.history].action,'guards_retired')
  -- the same plan with the departure guard standing: armed after the plan, named in status and the team line, and it
  -- fires at the next departure against the removed arm, as at 70081080
  removed=false; asterion.space_location={name='aquilo'}; pu=50
  guards[1].scope='standing'
  h.queue_submit(sol,{lane='remote',steps={{action='wait_ticks',args={ticks=30}},cleanup()[1]},guards=guards})
  tick(40)
  st=status('remote')
  eq(#st.guards,1); eq(st.guards[1].id,'guard-3'); eq(st.guards[1].scope,'standing')
  has(st.guards_after_plan,'1 guard still armed with no step left since plan #2 finished at tick ')
  has(st.guards_after_plan,'(scope standing: each fires on its condition with no plan running, until removed or the queue is cancelled): guard-3 platform_left')
  news=lanes.round_news(1)
  has(news[1],'guard retired with it (scope plan): guard-4 item_count; still armed (scope standing): guard-3 platform_left')
  removed=true; asterion.space_location=nil
  tick(20)
  st=status('remote')
  eq(st.paused,true); has(st.paused_why,'circuit_set failed: target: entity not found')
  eq(st.history[#st.history-1].action,'guard'); eq(st.history[#st.history-1].result.guard,'guard-3')
  h.queue_cancel(sol,{lane='remote'})
  removed=false; asterion.space_location={name='aquilo'}
end
print('d27_batch261 GR the dock-capture replay: plan guards retire, a standing one fires later: ok')

-- GR: a guard's own steps are the plan's last: the guards left retire after them; a lane paused with no step left keeps
-- its plan guards (status says so) until queue_resume; a guard set before scopes (none) stays standing.
do
  pu=50
  h.queue_submit(sol,{lane='remote',steps={{action='wait_ticks',args={ticks=600}}},guards={
    {when={['until']='item_count',platform='Asterion',item='processing-unit',below=10},steps={{action='platforms',args={}}}},
    {when={['until']='tick_at_least',tick=game.tick+100000}}}})
  tick(10); pu=5; tick(10)
  local st=status('remote')
  eq(st.guards,nil); eq(st.history[#st.history].action,'guards_retired'); eq(st.history[#st.history-1].action,'platforms')
  eq(st.history[#st.history-2].action,'guard')
  lanes.round_news(1)
  -- a step fails with on_fail abort and nothing after it: paused, the guard kept
  pu=50; removed=true
  h.queue_submit(sol,{lane='remote',steps={cleanup()[1]},guards={{when={['until']='item_count',platform='Asterion',item='processing-unit',below=1}}}})
  tick(2)
  st=status('remote')
  eq(st.paused,true); eq(#st.guards,1)
  has(st.guards_after_plan,'1 scope-plan guard kept while the lane is paused with no step left (queue_resume retires them in its next tick')
  h.queue_resume(sol,{lane='remote'}); tick(1)
  eq(status('remote').guards,nil)
  removed=false
  lanes.round_news(1)
  -- a guard from a runtime before scopes: no scope field, kept as standing
  h.queue_submit(sol,{lane='remote',steps={{action='wait_ticks',args={ticks=5}}},guards={{when={['until']='item_count',platform='Asterion',item='processing-unit',below=1}}}})
  q_of('remote').guards[1].scope=nil
  tick(10)
  st=status('remote')
  eq(#st.guards,1); eq(st.guards[1].scope,'standing'); has(st.guards_after_plan,'guard-')
  h.queue_cancel(sol,{lane='remote'})
  eq(status('remote').guards,nil); eq(status('remote').guards_after_plan,nil)
end
print('d27_batch261 GR guard steps, a paused lane, guards from before scopes: ok')

-- GR: refusals and queue_edit: a scope-plan guard on a lane that would have no step left is refused; standing is taken;
-- a replaced guard keeps its scope unless given; scope takes plan or standing only
do
  local g={when={['until']='item_count',platform='Asterion',item='processing-unit',below=1}}
  fails(function() h.queue_submit(sol,{lane='remote',steps={},guards={g}}) end,
    'guards[1]: scope plan (the default) retires a guard when the lane has no step left, and this lane would have none')
  fails(function() h.queue_submit(sol,{lane='remote',dry_run=true,steps={},guards={g}}) end,'guards[1]: scope plan (the default)')
  fails(function() h.queue_submit(sol,{lane='remote',steps={},guards={{when=g.when,scope='forever'}}}) end,'guard scope is "plan" (the default')
  local r=h.queue_submit(sol,{lane='remote',steps={},guards={{when=g.when,scope='standing'}}})
  eq(r.guards[1].scope,'standing')
  local rev=status('remote').revision
  fails(function() h.queue_edit(sol,{lane='remote',expected_revision=rev,guards={add={g}}}) end,'guards.add[1]: scope plan (the default)')
  local id=r.guards[1].id
  fails(function() h.queue_edit(sol,{lane='remote',expected_revision=rev,guards={replace={{id=id,when=g.when,scope='plan'}}}}) end,'guards.replace[1]: scope plan')
  local e=h.queue_edit(sol,{lane='remote',expected_revision=rev,guards={replace={{id=id,when={['until']='item_count',platform='Asterion',item='processing-unit',below=2}}}}})
  eq(e.guards[1].scope,'standing'); eq(e.guards[1].edit,'replaced')
  -- with a step pending, a plan guard is taken; it retires when the lane empties
  h.queue_submit(sol,{lane='remote',steps={{action='wait_ticks',args={ticks=20}}}})
  e=h.queue_edit(sol,{lane='remote',expected_revision=status('remote').revision,guards={add={g}}})
  eq(e.guards[2].scope,'plan')
  tick(25)
  local st=status('remote')
  eq(#st.guards,1); eq(st.guards[1].id,id)
  h.queue_cancel(sol,{lane='remote'})
  lanes.round_news(1)
end
print('d27_batch261 GR refusals and queue_edit scopes: ok')

-- GR: the body lane the same; a repeating plan keeps its plan guards between rounds
do
  h.queue_submit(sol,{steps={{action='noop',args={}},{action='wait_ticks',args={ticks=10}}},guards={{when={['until']='crafting_done'},scope='plan'}}})
  -- crafts queued: the guard holds back, the plan runs to its end
  sol.crafting_queue_size=3
  tick(15)
  local st=status('body')
  eq(st.guards,nil); eq(st.history[#st.history].action,'guards_retired')
  h.queue_repeat(sol,{steps={{action='wait_ticks',args={ticks=5}}},interval_ticks=60,times=2})
  e=h.queue_edit(sol,{expected_revision=status('body').revision,guards={add={{when={['until']='crafting_done'}}}}})
  tick(30)
  eq(#status('body').guards,1,'between rounds')
  tick(120)
  st=status('body')
  eq(st.repeating,false); eq(st.guards,nil); eq(st.history[#st.history].action,'guards_retired')
  sol.crafting_queue_size=0
  h.queue_cancel(sol,{})
  lanes.round_news(1)
end
print('d27_batch261 GR the body lane and a repeating plan: ok')

-- AD: Luna's boost as a remote-lane plan: wait for the stock or the cutoff, then restore. Installed late (19276 ticks
-- after the boost began, as at 70200281), the wait still ends at 70235005, not a timeout from the install.
do
  game.tick=70200281
  pu=2099
  local cutoff=70235005
  local r=h.queue_submit(sol,{lane='remote',steps={
    {action='wait_until',args={['until']='any',conditions={{['until']='item_count',platform='Asterion',item='processing-unit',at_least=3000},
      {['until']='tick_at_least',tick=cutoff}}},label='boost'},
    {action='circuit_set',args={platform='Asterion',position={x=-11,y=-205},logistic='processing-unit < 2000'},label='restore'}}})
  tick(2)
  local st=status('remote')
  eq(st.active.action,'wait_until'); eq(st.active.until_tick,cutoff,'no timeout given: the wait runs to the cutoff')
  game.tick=cutoff-3; tick(3)
  st=status('remote')
  local w=st.history[#st.history-1]
  eq(w.action,'wait_until'); eq(w.ok,true); eq(w.result.outcome,'met'); eq(w.result.matched['until'],'tick_at_least')
  eq(w.finished_tick,cutoff,'met on the cutoff tick')
  eq(st.history[#st.history].label,'restore'); eq(st.history[#st.history].finished_tick,cutoff,'restored in that tick')
  lanes.round_news(1)
end
print('d27_batch261 AD a late install still ends at the cutoff: ok')

-- AD: pause and resume across the deadline. A body-lane wait on the cutoff, paused before it and resumed after it: met at
-- its first check, never restarted. A deadline guard on a paused body lane fires at the resume before any step runs.
do
  game.tick=70300000
  local cutoff=game.tick+600
  h.queue_submit(sol,{steps={{action='wait_until',args={['until']='tick_at_least',tick=cutoff}},{action='noop',args={},label='restore'}}})
  tick(20)
  body.pause(1,'paused by your direct equipment call')
  game.tick=cutoff+3000
  h.queue_resume(sol,{})
  local resumed=game.tick
  tick(2)
  local st=status('body')
  local w=st.history[#st.history-1]
  eq(w.action,'wait_until'); eq(w.ok,true); eq(w.result.outcome,'met'); has(w.result.saw,'tick '..cutoff..' reached')
  eq(w.started_tick,resumed+1); eq(w.finished_tick,resumed+2,'its first check, the tick after it starts again')
  eq(st.history[#st.history].label,'restore')
  lanes.round_news(1)
  -- the guard: the lane paused with a step pending; the deadline passes; the resume fires it first (not at a 10-tick
  -- check), and its steps replace the pending one
  cutoff=game.tick+100
  h.queue_submit(sol,{steps={{action='wait_ticks',args={ticks=50000}},{action='noop',args={},label='late'}},
    guards={{when={['until']='tick_at_least',tick=cutoff},steps={{action='noop',args={},label='restore'}}}}})
  tick(3)
  local rows=h.queue_edit(sol,{expected_revision=status('body').revision,guards={replace={}}})
  eq(rows.guards[1].deadline_tick,cutoff); eq(rows.guards[1].ticks_left,97)
  has(rows.guards[1].baseline,'deadline tick '..cutoff..': 97 ticks left (0m01s); a pause or resume never moves it')
  eq(status('body').guards[1].ticks_left,97); eq(status('body').guards[1].deadline_tick,cutoff); eq(status('body').guards[1].deadline,nil)
  body.pause(1,'paused by your direct equipment call')
  game.tick=cutoff+501
  tick(5)
  eq(status('body').paused,true,'the body lane waits for its resume')
  if (game.tick+1)%10==0 then tick(1) end
  h.queue_resume(sol,{})
  tick(1)
  assert(game.tick%10~=0,'resumed off the 10-tick check')
  st=status('body')
  eq(st.history[#st.history-1].action,'guard'); has(st.history[#st.history-1].result.saw,'tick '..cutoff..' reached')
  eq(st.history[#st.history].label,'restore'); eq(st.history[#st.history].finished_tick,game.tick)
  for _,e in ipairs(st.history) do assert(e.label~='late','the pending step never ran') end
  h.queue_cancel(sol,{})
  lanes.round_news(1)
end
print('d27_batch261 AD body lane: pause and resume across the deadline: ok')

-- AD: a deadline guard on a platform lane fires at its tick while the lane is held (queue_pause) or paused by a failed
-- step, and its steps run then; a deadline passed already at the submit fires on the first tick, not the 10-tick check.
do
  local lane='platform:Asterion'
  game.tick=70400003
  local cutoff=game.tick+200
  h.queue_submit(sol,{lane=lane,steps={{action='wait_ticks',args={ticks=5000}}},
    guards={{when={['until']='tick_at_least',tick=cutoff},steps={{action='circuit_set',args={platform='Asterion',position={x=-11,y=-205},logistic='processing-unit < 2000'},label='restore'}}}}})
  tick(10)
  h.queue_pause(sol,{lane=lane})
  game.tick=cutoff-2
  tick(1)
  eq(status(lane).paused,true)
  eq(q_of(lane).held~=nil,true)
  tick(1)
  local st=status(lane)
  local fired=st.history[#st.history-1]
  eq(fired.action,'guard'); eq(fired.result.while_paused,true); eq(fired.finished_tick,cutoff)
  eq(st.history[#st.history].label,'restore'); eq(st.history[#st.history].finished_tick,cutoff,'its steps run in that tick')
  eq(st.paused,false); eq(q_of(lane).held,nil)
  has(q_of(lane).resumed_why.line,'guard-1 (tick_at_least) fired at its deadline while the lane was paused; its steps ran from then')
  lanes.round_news(1)
  -- passed already: the first tick after the submit
  game.tick=70500001
  h.queue_submit(sol,{lane=lane,steps={{action='wait_ticks',args={ticks=5000}}},
    guards={{when={['until']='tick_at_least',tick=70400000}}}})
  eq(q_of(lane).guard_due,70400000)
  tick(1)
  eq(game.tick%10,2)
  st=status(lane)
  eq(st.history[#st.history].action,'guard'); eq(st.paused,true,'a guard with no goto or steps pauses the lane'); has(st.paused_why,'a guard fired: tick_at_least')
  eq(q_of(lane).guard_due,nil)
  h.queue_cancel(sol,{lane=lane})
  -- a non-deadline guard on a paused lane is not checked
  pu=0
  h.queue_submit(sol,{lane=lane,steps={{action='wait_ticks',args={ticks=5000}}},guards={{when={['until']='item_count',platform='Asterion',item='processing-unit',below=1}}}})
  h.queue_pause(sol,{lane=lane})
  tick(30)
  st=status(lane)
  eq(#st.guards,1)
  for _,e in ipairs(st.history) do assert(e.action~='guard','no guard fired') end
  h.queue_cancel(sol,{lane=lane})
  lanes.round_news(1)
end
print('d27_batch261 AD platform lane: a deadline guard fires while held; one passed fires at once: ok')

-- the remote lanes take tick_at_least in steps, guards, all and any
do
  local r=h.queue_submit(sol,{lane='remote',dry_run=true,steps={{action='wait_until',args={['until']='all',conditions={
    {['until']='tick_at_least',tick=game.tick+60},{['until']='item_count',platform='Asterion',item='processing-unit',at_least=1}}}}},
    guards={{when={['until']='tick_at_least',tick=game.tick+60}}}})
  eq(r.dry_run,true)
  fails(function() h.queue_submit(sol,{lane='remote',steps={{action='wait_until',args={['until']='crafting_done'}}}}) end,
    'remote lane wait_until supports platform_arrived, platform_left, platform_built, researched, tick_at_least,')
end
print('d27_batch261 AD remote lanes take tick_at_least: ok')
