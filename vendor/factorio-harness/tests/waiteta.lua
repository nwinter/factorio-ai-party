-- Pure predicate/estimate tests; one existing observation, no second entity scan.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local checks=0
local function eq(a,b) checks=checks+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) checks=checks+1; assert(s and s:find(part,1,true),tostring(s)..' lacks '..part) end
game={tick=0}
defines={inventory={hub_main=1,rocket_silo_rocket=2},rocket_silo_status={building_rocket=0,rocket_rising=5,rocket_ready=7}}
prototypes={item={coal={}},space_location={nauvis={},gleba={}}}
local state={active={},queues={},remote_queues={},sleeps={}}
local tech={name='automation',research_unit_count=100,research_unit_energy=60,researched=false}
local nexttech={name='logistics',research_unit_count=200,research_unit_energy=60,saved_progress=0.25,researched=false}
local force={name='player',technologies={automation=tech,logistics=nexttech},current_research=tech,research_progress=0.5,research_queue={tech,nexttech}}
local scans,counts,items=0,0,10
local chest={valid=true,type='container',get_item_count=function() counts=counts+1; return items end}
local silo={valid=true,position={x=1,y=1},rocket_silo_status=0,rocket_parts=30,prototype={rocket_parts_required=50},
  is_crafting=function() return true end,get_recipe=function() return {energy=3} end,crafting_speed=2,productivity_bonus=1,crafting_progress=0.5,
  get_inventory=function() return {get_contents=function() return {} end} end}
local surface={index=1,find_entities_filtered=function(f) scans=scans+1; return f.type=='rocket-silo' and {silo} or {chest} end}
local hub={valid=true,get_inventory=function() return {get_item_count=chest.get_item_count} end}
local platform={valid=true,name='Sunward',hub=hub}
force.platforms={platform}
local where={stopped=false,text='flying gleba->nauvis',leg={to='nauvis',eta_ticks=600}}
local p={index=1,force=force,surface=surface,position={x=0,y=0},character={valid=true},crafting_queue_size=2,
  get_main_inventory=function() return {get_item_count=chest.get_item_count} end}
local C=require('conditions'){position=function(v) return v end,platform_where=function() return where end}
local rate,window,fallback=1,3600,nil
local busy=require('idle'){state=function() return state end}.busy
local W=require('waiteta'){state=function() return state end,check=function(p,c) return C.check(p,c,true) end,
  research_rate=function() return rate,window,fallback end,crafting_left=function() return 12.2 end,
  busy=busy,has_body=function() return p.character~=nil end}
local function row(c,record)
  C.validate(c)
  local _,_,r=W.check(p,c,record or {})
  assert(not r.line:find('\n',1,true)); return r
end
local research={['until']='researched',technology='logistics'}
eq(row(research).eta_s,200); has(row(research).basis,'queued lab work')
force.research_queue={tech}; has(row(research).no_estimate,'not in the current research queue')
force.research_queue={tech,nexttech}; rate=0; has(row(research).no_estimate,'no measured research throughput')
rate=nil; eq(row(research).eta_s,nil)
rate=1; fallback=true; has(row(research).no_estimate,'last minute'); fallback=nil
force.research_enabled=false; has(row(research).no_estimate,'disabled'); force.research_enabled=true
nexttech.researched=true; eq(row(research).eta_s,0); nexttech.researched=false
eq(row({['until']='crafting_done'}).eta_s,13); p.crafting_queue_size=0; eq(row({['until']='crafting_done'}).eta_s,0)
-- Part thresholds use the current part's progress and productivity; launch-ready has an unmeasured final stage.
local rocket={['until']='rocket_parts',position={x=1,y=1},at_least=50}
scans=0; eq(row(rocket).eta_s,15); eq(scans,1)
local r=row({['until']='rocket_ready',position={x=1,y=1}})
eq(r.eta_s,nil); eq(r.parts_eta_s,15); has(r.no_estimate,'then rocket raising')
silo.is_crafting=function() return false end; has(row(rocket).no_estimate,'not crafting'); silo.is_crafting=function() return true end
rocket.at_least=51; has(row(rocket).no_estimate,'exceeds'); rocket.at_least=50
silo.rocket_silo_status=5; eq(row(rocket).eta_s,0)
has(row({['until']='rocket_ready',position={x=1,y=1}}).no_estimate,'rising')
silo.rocket_silo_status=7; eq(row({['until']='rocket_ready',position={x=1,y=1}}).eta_s,0)
-- Inventory rates belong to the exact place, including a named hub; no scan beyond the predicate's one.
local c={['until']='item_count',item='coal',at_least=50,positions={{x=2,y=3}}}
local record={}; scans,counts=0,0
has(row(c,record).no_estimate,'two inventory observations'); eq(scans,1); eq(counts,1)
game.tick=60; items=20; eq(row(c,record).eta_s,3); eq(scans,2); eq(counts,2)
game.tick=70; items=21; eq(row(c,record).eta_s,3)
game.tick=120; items=20; has(row(c,record).no_estimate,'no net inventory change')
game.tick=180; items=15; has(row(c,record).no_estimate,'moving away')
c.at_least=nil; c.below=10; game.tick=240; items=10; eq(row(c,record).eta_s,1)
game.tick=300; items=9; eq(row(c,record).eta_s,0)
c.below=nil; c.at_least=50; c.positions={{x=3,y=3}}; has(row(c,record).no_estimate,'two inventory observations')
c.positions=nil; c.platform='Sunward'; has(row(c,record).no_estimate,'two inventory observations')
game.tick=360; items=19; scans,counts=0,0; eq(row(c,record).eta_s,4); eq(scans,0); eq(counts,1)
eq(row(c,{}).eta_s,nil) -- no inherited rate from an earlier wait
-- Distance/speed comes from the same oriented flight leg as the predicate, including reverse flights.
c={['until']='platform_arrived',platform='Sunward',location='nauvis'}
eq(row(c).eta_s,10); where.leg.eta_ticks=300; eq(row(c).eta_s,5)
platform.paused=true; has(row(c).no_estimate,'paused'); platform.paused=false
where.leg.eta_ticks=nil; has(row(c).no_estimate,'speed is zero')
where.leg.to='gleba'; has(row(c).no_estimate,'ends at gleba')
where.leg=nil; has(row(c).no_estimate,'not departed')
where.stopped=true; where.at='nauvis'; eq(row(c).eta_s,0)
where.at='gleba'; has(row({['until']='platform_left',platform='Sunward',location='gleba'}).no_estimate,'no measured rate')
-- Idle is per wait, not reset by a status request; work during sleep and no-body time do not count.
local sleep={until_tick=game.tick+600}; state.sleeps[1]=sleep
for _=1,60 do W.idle_tick(1) end; eq(W.info({},sleep).idle_s,1)
state.active[1]={kind='walk'}; for _=1,60 do W.idle_tick(1) end; eq(W.info({},sleep).idle_s,1)
local act={kind='wait_until'}; state.active[1]=act
for _=1,60 do W.idle_tick(1) end; eq(W.info({},act).idle_s,1); eq(W.info({},sleep).idle_s,2)
sleep.woke='condition'; for _=1,60 do W.idle_tick(1) end; eq(W.info({},sleep).idle_s,2)
state.active[1]=nil
local step={action='wait_until'}; state.queues[1]={current=step,loop={},pending={}}
for _=1,60 do W.idle_tick(1) end; eq(W.info({},step).idle_s,1)
local rs={action='wait_until'}; state.remote_queues[1]={current=rs,pending={}}
for _=1,60 do W.idle_tick(1) end; eq(W.info({},rs).idle_s,1)
state.active[1]={kind='walk'}; for _=1,60 do W.idle_tick(1) end; eq(W.info({},rs).idle_s,1)
state.active[1]=nil; p.character=nil; for _=1,60 do W.idle_tick(1) end; eq(W.info({},rs).idle_s,1)
eq(W.info({}, {wait_estimates={{line='ship\nname\r ETA 10s'}}}).wait_line,'ship name  ETA 10s; character idle 0s in this wait')
-- Body-independent waits still refresh and wake aboard, with no character idle time.
state={active={}}
local sleeps=require('waits'){state=function() return state end,integer=function(v,d) return v or d end,
  clock_mode=function() return 'realtime' end,traveling=function() return true end,
  condition=W.check,validate_condition=C.validate,wait_info=W.info}
where.stopped=true; where.at='gleba'; where.leg=nil
local out=sleeps.handlers.sleep(p,{seconds=30,condition={['until']='platform_arrived',platform='Sunward',location='nauvis'}})
eq(out.idle_s,0); has(out.wait_estimates[1].no_estimate,'not departed')
where.at='nauvis'; out=sleeps.handlers.sleep_check(p,{peek=true})
eq(out.woke,'condition'); eq(out.wait_estimates[1].eta_s,0); eq(out.idle_s,0)
print('waiteta: '..checks..' assertions passed')
