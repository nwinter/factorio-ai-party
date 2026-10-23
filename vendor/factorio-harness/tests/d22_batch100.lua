-- d22 batch100 BJ1 (Sol #1905): a queued wait_until platform_left right after the platform_schedule step that sent the
-- platform off began with it already on its path and waited for the next departure. Run from the harness root:
-- lua tests/d22_batch100.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- 1. platform_schedule records the departure it causes with a platform that is userdata, as every game object is in
-- 2.0 (the check for a table dropped it, so nothing was ever recorded on the real engine).
do
  game={tick=1000}
  defines={space_platform_state={paused=7,waiting_at_station=6,on_the_path=2,no_schedule=4},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={},
    wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={item={},space_location={nauvis={},vulcanus={}},quality={normal={}},fluid={}}
  local main={get_item_count=function() return 0 end,get_contents=function() return {} end}
  local secs=setmetatable({get_section=function() return nil end},{__index=function(_,k) if k=='sections_count' then return 0 end end})
  local fields={valid=true,name='Meridian-V',index=18,state=6,space_location={name='nauvis'},force='player',paused=false,
    schedule={current=2,records={{station='nauvis'},{station='vulcanus'}}},
    hub={valid=true,unit_number=78,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end,
      get_item_count=function() return 0 end,get_circuit_network=function() return nil end}}
  local sch=setmetatable({},{__index=function(_,k) if k=='current' then return fields.schedule.current end end})
  sch.get_record_count=function() return #fields.schedule.records end
  -- the game's go to station: it leaves the station it waits at
  sch.go_to_station=function(i) fields.schedule.current=i; if fields.state==6 then fields.state=2 end end
  fields.get_schedule=function() return sch end
  -- a userdata platform reading and writing those fields (a file handle with its own metatable)
  local pl=io.tmpfile()
  debug.setmetatable(pl,{__index=fields,__newindex=fields})
  eq(type(pl),'userdata')
  local sol={index=11,name='sol',force={platforms={pl}}}
  local st={}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    integer=function(v,d) v=v==nil and d or v; return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
    circuit_condition=function(c) return c end,
    freight={where=function() return {stopped=true,at='nauvis'} end,pads=function() return {},{} end,leg=function() return nil end}}
  game.tick=48193552
  -- Sol's step: current 2 (vulcanus) while it waits at nauvis on stop 1's... here it waits at nauvis with stop 1 current
  fields.schedule.current=1
  local r=space.platform_schedule(sol,{platform='Meridian-V',current=2})
  has(r.departed,'left nauvis at tick 48193552')
  eq(st.schedule_departures['Meridian-V'].from,'nauvis'); eq(st.schedule_departures['Meridian-V'].by,'sol')
end

-- 2. platform_left counts a departure in the platform log (freight.lua) at or after its baseline: since_tick, or in a
-- queue the start of the step before it in the same plan; a lone wait keeps its first check.
do
  game={tick=5000}
  defines={space_platform_state={waiting_at_station=6,on_the_path=2}}
  prototypes={space_location={nauvis={},vulcanus={}}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields}); return u end
  local our=ud{name='player'}
  local pl=ud{valid=true,name='Meridian-V',index=18,force=our}
  local where={text='flying nauvis->vulcanus 11%',leg={from='nauvis',to='vulcanus',flown=0.11}}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){platform_where=function() return where end,position=function(v) return v end,
    left_since=function(n,f,loc,since) return F.left_since(n,f,loc,since) end}
  local who={force=ud{name='player',platforms={pl}}}
  -- the platform left nauvis; freight logged it on the game second after (4980 -> 5040: logged at 5040)
  F.event(pl,'left','nauvis',5040,'vulcanus')
  F.event(ud{name='Petrel',force=our},'left','nauvis',5100,'gleba')
  game.tick=5100
  -- a lone wait begun now: as before, the departure before it does not count
  local met,saw=C.check(who,{['until']='platform_left',platform='Meridian-V',location='nauvis'},nil,{})
  eq(met,false); has(saw,'(a departure before this wait does not count)')
  -- in a queue: the step before it (platform_schedule) began at 4980, so the departure logged at 5040 counts
  met,saw=C.check(who,{['until']='platform_left',platform='Meridian-V',location='nauvis'},nil,{after_step={tick=4980,action='platform_schedule'}})
  eq(met,true); has(saw,'Meridian-V left nauvis at tick 5040 (after the step before this wait, platform_schedule, began at tick 4980); now flying nauvis->vulcanus 11%')
  -- a step before it that began after the departure: not counted, and saw names the baseline
  met,saw=C.check(who,{['until']='platform_left',platform='Meridian-V',location='nauvis'},nil,{after_step={tick=5041,action='wait_ticks'}})
  eq(met,false); has(saw,'(a departure before tick 5041 does not count)')
  -- another location, or another platform's departure: not counted
  eq((C.check(who,{['until']='platform_left',platform='Meridian-V',location='vulcanus'},nil,{after_step={tick=4980,action='platform_schedule'}})),false)
  -- since_tick given: from that tick, in a queue or not
  met,saw=C.check(who,{['until']='platform_left',platform='Meridian-V',location='nauvis',since_tick=5000},nil,{})
  eq(met,true); has(saw,'(since_tick 5000)')
  eq((C.check(who,{['until']='platform_left',platform='Meridian-V',since_tick=5041},nil,{})),false)
  -- since_tick is checked: a tick up to now, and platform_left's only
  game.tick=5100
  assert(pcall(C.validate,{['until']='platform_left',platform='Meridian-V',since_tick=5000}))
  local ok,err=pcall(C.validate,{['until']='platform_left',platform='Meridian-V',since_tick=9999})
  assert(not ok and tostring(err):find('platform_left since_tick is a game tick up to now',1,true),tostring(err))
  ok,err=pcall(C.validate,{['until']='platform_arrived',platform='Meridian-V',since_tick=5000})
  assert(not ok and tostring(err):find('platform_arrived takes no since_tick',1,true),tostring(err))
end

-- 3. the scheduler gives a wait step the step before it in the same plan (after_step), not one of another plan
do
  game={tick=0}
  local state,seen={},{}
  local players={[1]={index=1}}
  local scheduler=dofile('mod/agent-harness_0.1.0/scheduler.lua'){
    state=function() return state end,
    player=function(i) return players[i] end,
    handlers={platform_schedule=function() return {state='on_the_path'} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,
    condition=function(_,c,record) seen[#seen+1]=record and record.after_step or false; return false,'waiting' end,
    validate_condition=function(c) assert(type(c)=='table' and c['until']) end}
  local h=scheduler.handlers
  local function tick() game.tick=game.tick+1; scheduler.tick() end
  game.tick=100
  h.queue_submit(players[1],{steps={{action='platform_schedule',args={platform='Meridian-V',current=2}},
    {action='wait_until',args={['until']='platform_left',platform='Meridian-V',location='nauvis',timeout=50}}}})
  tick(); tick()
  local a=seen[#seen]
  assert(a,'the wait has after_step')
  eq(a.action,'platform_schedule'); eq(a.tick,101,'the step before it began at tick 101')
  -- a new plan whose first step is the wait: no step before it in that plan
  state={}  -- a fresh queue: a plan of one platform_schedule step runs, then a plan whose first step is the wait
  h.queue_submit(players[1],{steps={{action='platform_schedule',args={platform='Meridian-V',current=2}}}})
  tick()
  eq(#h.queue_status(players[1]).history,1,'the first plan done')
  seen={}
  h.queue_submit(players[1],{steps={{action='wait_until',args={['until']='platform_left',platform='Meridian-V',timeout=50}}}})
  for _=1,4 do tick() end
  eq(#seen>0,true); eq(seen[#seen],false,'no after_step from another plan')
end
print('d22_batch100 BJ1 platform_left baseline: ok')
