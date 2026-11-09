-- batch407 PA: an arrival remembered after departure, using the existing bounded freight event log.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
game={tick=100,connected_players={}}
defines={space_platform_state={},rocket_silo_status={}}
prototypes={space_location={aquilo={},fulgora={},nauvis={}}}
local state={active={}}
local ship={valid=true,index=1,name='Asterion',schedule={records={{station='aquilo'},{station='fulgora',wait_conditions={{type='time',ticks=600}}}}}}
local force={name='player',platforms={ship},technologies={}}
ship.force=force
local p={index=1,force=force,character={valid=true,health=250}}
local F=require('freight'){state=function() return state end}
local where={text='flying fulgora->aquilo 99%',leg={from='fulgora',to='aquilo',flown=0.99}}
local api={platform_where=function() return where end,arrived_since=F.arrived_since,left_since=F.left_since}
local C=require('conditions')(api)
local function cond(location,since) return {['until']='platform_arrived',platform=ship.name,location=location,since_tick=since} end
local c=cond('aquilo')
local record={start_tick=100}
eq(C.check(p,c,true,record),false)
F.event(ship,'arrived','aquilo',104)
F.event(ship,'left','aquilo',105,'fulgora')
where={text='flying aquilo->fulgora 2%',leg={from='aquilo',to='fulgora',flown=0.02}}
game.tick=110
-- The old current-location predicate misses this dock-and-leave between checks.
eq(where.stopped==true and where.at=='aquilo',false)
local met,saw,o=C.check(p,c,true,record)
eq(met,true); has(saw,'arrived at aquilo at tick 104'); has(saw,'left aquilo at tick 105 for fulgora')
has(saw,'now flying aquilo->fulgora 2%'); eq(o.arrival_tick,104); eq(o.departure_tick,105)
for key in pairs(record.platform_arrivals) do eq(type(key),'string') end -- queue_status JSON keys
-- A later wait cannot consume the old arrival; since_tick deliberately can, including its exact boundary.
eq(C.check(p,cond('aquilo'),true,{start_tick=106}),false)
eq(C.check(p,C.validate(cond('aquilo',104)),true,{}),true)
eq(C.check(p,cond('aquilo',105),true,{}),false)
eq(C.check(p,cond(nil,104),true,{}),true)
eq(C.check(p,cond('nauvis',104),true,{}),false)
eq(F.arrived_since('other','player','aquilo',100),nil)
eq(F.arrived_since(ship.name,'other','aquilo',100),nil)
for _,since in ipairs{-1,110.5,111,'104'} do assert(not pcall(C.validate,cond('aquilo',since))) end
-- Arrival remains latched after the 40-event log rolls over and after module reload.
for i=1,45 do F.event(ship,'left','nauvis',110+i,'fulgora') end
game.tick=160
eq(F.arrived_since(ship.name,force.name,'aquilo',100),nil)
C=require('conditions')(api)
met,saw=C.check(p,c,true,record); eq(met,true); has(saw,'tick 104'); has(saw,'tick 105')
-- Docked arrivals give their recorded tick; an already docked ship still meets a new wait without a log entry.
F.event(ship,'arrived','aquilo',160)
where={stopped=true,at='aquilo',text='at aquilo'}
met,saw=C.check(p,cond('aquilo'),true,{start_tick=159}); eq(met,true); has(saw,'tick 160'); has(saw,'now at aquilo')
game.tick=161
met,saw=C.check(p,cond('aquilo'),true,{start_tick=161}); eq(met,true); eq(saw,'Asterion at aquilo')
where={at='aquilo',stopped=false,text='at aquilo, on its path (not stopped)'}
eq(C.check(p,cond('aquilo'),true,{start_tick=161}),false)
-- Members of all/any and a sleep share a record but never share an arrival latch.
where={text='flying aquilo->fulgora 2%'}
local both={['until']='all',conditions={cond('aquilo',160),cond('fulgora',160)}}
local shared={start_tick=160}
eq(C.check(p,both,true,shared),false)
F.event(ship,'arrived','fulgora',161)
eq(C.check(p,both,true,shared),true)
-- A record-less guard keeps its own persisted baseline across module reloads.
local guard=cond('aquilo')
eq(C.check(p,guard),false)
F.event(ship,'arrived','aquilo',162); F.event(ship,'left','aquilo',162,'fulgora'); game.tick=170
C=require('conditions')(api)
eq(C.check(p,guard),true)
-- Queue dry-run facts, including grouped conditions, matching destinations and schedules with a holding wait.
local S=require('space'){state=function() return state end,freight=F}
local lines=S.world_checks(p,{{action='wait_until',args=cond('aquilo')}})
eq(#lines,1); has(lines[1],'stop 1 (aquilo) has no holding wait condition')
has(lines[1],'a following step or guard may run after departure')
eq(S.world_checks(p,{{action='wait_until',args=cond('fulgora')}}),nil)
eq(#S.world_checks(p,{{action='wait_until',args=both}}),1)
-- Actual queue lanes use the step start, including an arrival before the first evaluation.
local W=require('waiteta'){check=function(p,c,r) return C.check(p,c,true,r) end}
local base={state=function() return state end,player=function() return p end,player_check=function() return true end,
  handlers={},busy=function() return false end,stop=function() end,stop_index=function() end,
  condition=C.check,validate_condition=C.validate,deadline=C.deadline,wait_check=W.check,wait_info=W.info,
  world_checks=S.world_checks}
local make=require('scheduler')
local Q=require('queue_lanes'){scheduler=make(base),base=base,factory=make,is_read=function() return false end}
local function tick() game.tick=game.tick+1; Q.tick() end
for _,lane in ipairs{'body','remote','platform:Asterion'} do
  state.platform_events=nil
  local a={lane=lane,mode='replace',steps={{action='wait_until',args=cond('aquilo')}}}
  a.dry_run=true
  local dry=Q.handlers.queue_submit(p,a); eq(dry.queued,false); has(dry.world_checks[1],'no holding wait condition')
  a.dry_run=nil; Q.handlers.queue_submit(p,a)
  tick()
  F.event(ship,'arrived','aquilo',game.tick); F.event(ship,'left','aquilo',game.tick,'fulgora')
  for i=1,15 do tick() end
  local out=Q.handlers.queue_status(p,{lane=lane})
  eq(out.active,false); eq(out.pending_count,0); has(out.history[#out.history].result.saw,'arrived at aquilo')
end
-- Timeout hold and explicit pause/requeue retain the original baseline, including events while paused.
for _,mode in ipairs{'hold','pause'} do
  state.platform_events=nil
  local c=cond('aquilo'); c.timeout=12; c.on_timeout='hold'
  Q.handlers.queue_submit(p,{lane='platform:Asterion',mode='replace',steps={{action='wait_until',args=c}}})
  tick(); tick()
  if mode=='pause' then Q.handlers.queue_pause(p,{lane='platform:Asterion'})
  else for i=1,25 do tick() end end
  local paused=Q.handlers.queue_status(p,{lane='platform:Asterion'})
  eq(paused.paused,true); eq(paused.pending_count,1)
  F.event(ship,'arrived','aquilo',game.tick); F.event(ship,'left','aquilo',game.tick,'fulgora')
  game.tick=game.tick+5
  Q.handlers.queue_resume(p,{lane='platform:Asterion'})
  for i=1,10 do tick() end
  local out=Q.handlers.queue_status(p,{lane='platform:Asterion'})
  eq(out.active,false); eq(out.pending_count,0); has(out.history[#out.history].result.saw,'arrived at aquilo')
end
-- Sleep also wakes on an arrival and departure between polls.
state.platform_events=nil
local Sleep=require('waits'){state=function() return state end,integer=function(v,d) return v or d end,
  clock_mode=function() return 'realtime' end,condition=W.check,validate_condition=C.validate}
Sleep.handlers.sleep(p,{seconds=60,condition=cond('aquilo')})
F.event(ship,'arrived','aquilo',game.tick+1); F.event(ship,'left','aquilo',game.tick+2,'fulgora')
game.tick=game.tick+10
local out=Sleep.handlers.sleep_check(p,{})
eq(out.woke,'condition'); has(out.saw,'arrived at aquilo'); has(out.saw,'left aquilo')
print('platform arrival latch: predicate, event retention, reload, groups, guards, dry run, lanes and sleep ok')
