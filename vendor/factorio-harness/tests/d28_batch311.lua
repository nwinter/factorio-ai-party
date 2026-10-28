-- Run from repository root: lua tests/d28_batch311.lua
-- d28 batch311 GA (viewer Aurora, site 10:27: "any can match a deadline then throw on a missing turret; scheduler.lua
-- swallows that error and can remove a paused lane's only deadline wake"). A guard {until=any, conditions={ammo_below
-- on a turret, tick_at_least cutoff}} whose turret is removed before the cutoff, through the real conditions.lua,
-- scheduler.lua and queue_lanes.lua: the deadline fires its cleanup once at the cutoff, in either member order, on a
-- running lane and on a paused one; the turret member's error is reported once, not swallowed.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={inventory={hub_main=1,turret_ammo=7}}
prototypes={item={['firearm-magazine']={}},entity={},quality={normal={}},space_location={aquilo={}}}
game={tick=71000000}
-- Asterion with one gun turret at (3.5,-10.5) holding 50 magazines; removed sets it invalid and the find empty
local turret={valid=true,type='ammo-turret',name='gun-turret',position={x=3.5,y=-10.5}}
local ammo_inv={valid=true,get_item_count=function() return 50 end,get_contents=function() return {{name='firearm-magazine',count=50}} end}
turret.get_inventory=function() return ammo_inv end
local surface={name='platform-3',index=3,valid=true}
surface.find_entities_filtered=function() return turret.valid and {turret} or {} end
surface.count_entities_filtered=function() return turret.valid and 1 or 0 end
local hub={valid=true,get_inventory=function() return {get_item_count=function() return 0 end} end}
local asterion={valid=true,name='Asterion',index=3,hub=hub,surface=surface,space_location={name='aquilo'}}
local force={name='player',index=1,platforms={asterion},technologies={}}
local sol={index=1,position={x=0,y=0},surface={name='nauvis'},force=force,crafting_queue_size=0}
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,known=function() return true end}
local s={active={}}
local cleanups=0
local broken=false
local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){}
local base={state=function() return s end,player=function() return sol end,
  handlers={platforms=function() return {} end,noop=function() return {done=true} end,
    circuit_set=function() cleanups=cleanups+1; return {entity='inserter'} end},
  busy=function() return false end,stop=function() end,stop_index=function() end,claim=function() end,direct_action=function() end,
  condition=function(p,c,record) if broken then error('read failed (test)',0) end return C.check(p,c,nil,record) end,validate_condition=function(c) return C.validate(c) end,
  wait_info=function(out,record) return W.info(out,record) end,outcome=function() return 'done' end,
  deadline=function(c) return C.deadline(c) end}
local make=require('scheduler')
local body_api={}; for k,v in pairs(base) do body_api[k]=v end
local lanes=require('queue_lanes'){scheduler=make(body_api),factory=make,base=base,is_read=function(name) return name=='platforms' end}
local h=lanes.handlers
local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; lanes.tick() end end
local function status(lane) return h.queue_status(sol,{lane=lane,history='all'}) end
local function q_of(lane) return lane=='remote' and s.remote_queues[1] or s['lane_queues|'..lane:match('^platform:(.+)$')][1] end

local function run(lane,order,paused)
  turret.valid=true; cleanups=0
  game.tick=game.tick+1000
  local cutoff=game.tick+600
  local members={{['until']='ammo_below',platform='Asterion',positions={{x=3.5,y=-10.5}},count=10},{['until']='tick_at_least',tick=cutoff}}
  if order==2 then members={members[2],members[1]} end
  h.queue_submit(sol,{lane=lane,steps={{action='wait_ticks',args={ticks=50000}}},
    guards={{when={['until']='any',conditions=members},steps={{action='circuit_set',args={platform='Asterion',position={x=-8.5,y=3.5},switch_off=true},label='cleanup'}}}}})
  local what=lane..' order '..order..(paused and ' paused' or ' running')
  eq(q_of(lane).guard_due,cutoff,what..': the deadline wake')
  tick(20)
  if paused then h.queue_pause(sol,{lane=lane}) end
  -- the turret goes before the cutoff
  turret.valid=false
  tick(cutoff-100-game.tick)
  eq(cleanups,0,what..': nothing fires before the cutoff')
  tick(100)
  local st=status(lane)
  local fired
  for _,e in ipairs(st.history) do if e.action=='guard' then fired=e end end
  assert(fired,what..': the deadline guard fired')
  eq(fired.finished_tick,cutoff,what..': at the cutoff')
  has(fired.result.saw,'tick '..cutoff..' reached')
  has(fired.result.saw,'ammo_below: could not be read: no ammo turret of ours at (3.5,-10.5) on Asterion')
  -- the turret's error said once before the cutoff on a running lane (a paused one reads its guards only at the deadline)
  local errs=0
  for _,e in ipairs(st.history) do if e.action=='guard_error' then errs=errs+1 end end
  eq(errs,paused and 0 or 1,what..': the error row')
  eq(cleanups,1,what..': cleanup once')
  tick(200)
  eq(cleanups,1,what..': cleanup once, later too')
  h.queue_cancel(sol,{lane=lane})
  lanes.round_news(1)
  return fired
end
for _,lane in ipairs({'remote','platform:Asterion'}) do
  for order=1,2 do
    for _,paused in ipairs({false,true}) do run(lane,order,paused) end
  end
end
print('d28_batch311 GA an any guard\'s deadline fires once with its turret member erroring: ok')

-- a deadline passed while a paused lane's guard could not be read at all: its wake is kept (CHECK_TICKS on), it fires
-- once the read works again
do
  local lane='platform:Asterion'
  game.tick=game.tick+1000
  local cutoff=game.tick+300
  cleanups=0
  h.queue_submit(sol,{lane=lane,steps={{action='wait_ticks',args={ticks=50000}}},
    guards={{when={['until']='tick_at_least',tick=cutoff},steps={{action='circuit_set',args={platform='Asterion',position={x=-8.5,y=3.5},switch_off=true}}}}}})
  tick(5); h.queue_pause(sol,{lane=lane})
  tick(cutoff-1-game.tick)
  broken=true
  tick(15)
  eq(cleanups,0)
  local q=q_of(lane)
  eq(q.guard_due,cutoff+20,'read again 10 ticks on')
  local st=status(lane)
  eq(st.guards[1].read_error.error,'read failed (test)'); eq(st.guards[1].read_error.checks,2); eq(st.guards[1].read_error.first_tick,cutoff)
  local rows=0
  for _,e in ipairs(st.history) do if e.action=='guard_error' then rows=rows+1; has(e.result.line,st.guards[1].id..' (tick_at_least) could not be read at tick '..cutoff..': read failed (test); it stays armed') end end
  eq(rows,1,'said once')
  local news=table.concat(lanes.round_news(1),'\n')
  has(news,'could not be read at tick '..cutoff)
  broken=false
  tick(10)
  eq(cleanups,1)
  st=status(lane)
  eq(st.history[#st.history-1].action,'guard'); eq(st.history[#st.history-1].finished_tick,cutoff+20)
  tick(50); eq(cleanups,1)
  h.queue_cancel(sol,{lane=lane})
  lanes.round_news(1)
end
print('d28_batch311 GA a paused lane keeps a passed deadline\'s wake: ok')

-- baselines: an any of the turret's ammo and the platform's departure, the turret removed before the submit: the
-- departure member is read at every check (its first check's stop kept), and the departure fires it, both orders
for order=1,2 do
  local lane='remote'
  game.tick=game.tick+1000
  turret.valid=false; asterion.space_location={name='aquilo'}; cleanups=0
  local members={{['until']='ammo_below',platform='Asterion',positions={{x=3.5,y=-10.5}},count=10},{['until']='platform_left',platform='Asterion'}}
  if order==2 then members={members[2],members[1]} end
  h.queue_submit(sol,{lane=lane,steps={{action='wait_ticks',args={ticks=50000}}},
    guards={{when={['until']='any',conditions=members},steps={{action='circuit_set',args={platform='Asterion',position={x=-8.5,y=3.5},switch_off=true}}}}}})
  tick(300)
  local st=status(lane)
  eq(cleanups,0); eq(#st.guards,1)
  local e=st.guards[1].read_error
  has(e.error,'none yet, and a member could not be read: '); has(e.error,'ammo_below: could not be read: no ammo turret of ours'); has(e.error,'platform_left: not yet: Asterion at aquilo (met when it leaves)')
  assert(e.checks>=29,'read at each check: '..e.checks)
  local rows=0
  for _,x in ipairs(st.history) do if x.action=='guard_error' then rows=rows+1 end end
  eq(rows,1,'said once')
  asterion.space_location=nil
  tick(10)
  eq(cleanups,1,'order '..order..': the departure fires it')
  st=status(lane)
  has(st.history[#st.history-1].result.saw,'platform_left: met: Asterion left aquilo')
  h.queue_cancel(sol,{lane=lane})
  lanes.round_news(1)
end
asterion.space_location={name='aquilo'}
print('d28_batch311 GA a member after an erroring one keeps its baseline: ok')

-- a wait_until step: an any of the removed turret and the cutoff is met at the cutoff (it failed at its first check);
-- all with that member still fails with the turret's error
do
  local lane='remote'
  game.tick=game.tick+1000
  turret.valid=false
  local cutoff=game.tick+120
  h.queue_submit(sol,{lane=lane,steps={{action='wait_until',args={['until']='any',conditions={
    {['until']='ammo_below',platform='Asterion',positions={{x=3.5,y=-10.5}},count=10},{['until']='tick_at_least',tick=cutoff}}}},
    {action='circuit_set',args={platform='Asterion',position={x=-8.5,y=3.5},switch_off=true},label='after'}}})
  tick(cutoff+2-game.tick)
  local st=status(lane)
  local w=st.history[#st.history-1]
  eq(w.action,'wait_until'); eq(w.ok,true); eq(w.result.outcome,'met'); eq(w.finished_tick,cutoff)
  eq(w.result.matched['until'],'tick_at_least'); eq(w.result.member_errors[1].index,1); has(w.result.member_errors[1].error,'no ammo turret of ours')
  eq(st.history[#st.history].label,'after')
  local rows=0
  for _,e in ipairs(st.history) do if e.action=='wait_error' then rows=rows+1; has(e.result.line,'wait_until could not be read at tick '); has(e.result.line,'its deadline tick '..cutoff..' still ends it') end end
  eq(rows,1,'said once')
  h.queue_submit(sol,{lane=lane,steps={{action='wait_until',args={['until']='all',conditions={
    {['until']='tick_at_least',tick=game.tick},{['until']='ammo_below',platform='Asterion',positions={{x=3.5,y=-10.5}},count=10}}}}}})
  tick(12)
  st=status(lane)
  w=st.history[#st.history]
  eq(w.ok,false); eq(w.result.reason,'no ammo turret of ours at (3.5,-10.5) on Asterion')
  h.queue_cancel(sol,{lane=lane})
  lanes.round_news(1)
end
print('d28_batch311 GA wait_until any and all with a member erroring: ok')
