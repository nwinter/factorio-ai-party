-- Run from repository root: lua tests/d23_batch127.lua
-- d23 batch127 CJ1 (Sol #2076: Asterion's promethium probe waits, in one lane with its guards, for outward progress
-- or promethium in the hub, whichever comes first; until=any was refused, only all was taken): wait_until
-- {until=any, conditions=[...]}, 1..8 plain conditions, met when one holds; every member read each check; saw names
-- the first that holds (#N) and the others; the record keeps matched {index, until, saw}; every member validated (a
-- dry run too); the remote and platform lanes take it when they take each member; guards run beside it.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={inventory={hub_main=1}}
prototypes={item={['promethium-asteroid-chunk']={}},entity={},quality={normal={}},
  space_location={['shattered-planet']={},['solar-system-edge']={},aquilo={}}}
game={tick=1000}
local chunks=0
local hub={valid=true,get_inventory=function() return {get_item_count=function(name) return name=='promethium-asteroid-chunk' and chunks or 0 end} end}
local asterion={valid=true,name='Asterion',index=3,hub=hub,surface={name='platform-3'}}
local force={name='player',platforms={asterion},technologies={rail={researched=false}}}
local sol={index=1,position={x=0,y=0},surface={name='nauvis'},force=force,crafting_queue_size=0}
local leg={from='solar-system-edge',to='shattered-planet',flown=0.0005,length=4000000}
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
  leg=function() return leg end}
local function probe()
  return {['until']='any',conditions={
    {['until']='platform_progress',platform='Asterion',at_least=0.002,from='solar-system-edge',to='shattered-planet'},
    {['until']='item_count',platform='Asterion',item='promethium-asteroid-chunk',at_least=25}}}
end

-- the check: none yet, the second member, the first member (and both)
do
  local c=C.validate(probe())
  local record={}
  local met,saw=C.check(sol,c,nil,record)
  eq(met,false)
  eq(saw,'none yet: #1 platform_progress: not yet: platform Asterion: flying solar-system-edge->shattered-planet, 0.1% of 4000000 km flown (met at 0.2%); '..
    '#2 item_count: not yet: promethium-asteroid-chunk 0 in Asterion hub (landed stock; excludes incoming cargo and hub trash)')
  eq(record.matched,nil)
  chunks=30
  met,saw=C.check(sol,c,nil,record)
  eq(met,true); eq(record.matched.index,2); eq(record.matched['until'],'item_count')
  eq(record.matched.saw,'promethium-asteroid-chunk 30 in Asterion hub (landed stock; excludes incoming cargo and hub trash)')
  has(saw,'#2 item_count: met: promethium-asteroid-chunk 30'); has(saw,' (others: #1 platform_progress: not yet: ')
  chunks=0; leg.flown=0.0021
  met,saw=C.check(sol,c,nil,record)
  eq(met,true); eq(record.matched.index,1); eq(record.matched['until'],'platform_progress')
  has(saw,'#1 platform_progress: met: platform Asterion: flying solar-system-edge->shattered-planet, 0.2% of 4000000 km flown')
  -- both hold: the first named
  chunks=40
  met,saw=C.check(sol,c,nil,record)
  eq(met,true); eq(record.matched.index,1); has(saw,'(others: #2 item_count: met: promethium-asteroid-chunk 40')
  -- a member that holds now and fails later: not met, matched cleared
  chunks=0; leg.flown=0.001
  met=C.check(sol,c,nil,record); eq(met,false); eq(record.matched,nil)
  -- with no record (a guard's when): the same answer
  chunks=25
  met,saw=C.check(sol,c)
  eq(met,true); has(saw,'#2 item_count: met: promethium-asteroid-chunk 25')
  chunks=0
end
print('d23_batch127 CJ1 any: first, second, none: ok')

-- validation: 1..8 plain members, each checked as a condition of its own (a member's refusal names it)
do
  fails(function() C.validate({['until']='any',conditions={}}) end,'until=any takes conditions: 1..8 wait_until conditions, met when one of them holds')
  local nine={}; for i=1,9 do nine[i]={['until']='crafting_done'} end
  fails(function() C.validate({['until']='any',conditions=nine}) end,'until=any takes conditions: 1..8')
  fails(function() C.validate({['until']='any',conditions={{['until']='all',conditions={{['until']='crafting_done'}}}}}) end,'until=any takes plain conditions')
  fails(function() C.validate({['until']='any',conditions={{['until']='crafting_done'},{['until']='any',conditions={}}}}) end,'until=any takes plain conditions')
  fails(function() C.validate({['until']='all',conditions={{['until']='any',conditions={}}}}) end,'until=all takes plain conditions')
  local bad=probe(); bad.conditions[2].item='promethium-chunk'
  fails(function() C.validate(bad) end,'any conditions[2] (item_count): item_count requires a known item')
  bad=probe(); bad.conditions[1].at_least=2
  fails(function() C.validate(bad) end,'any conditions[1] (platform_progress): platform_progress at_least')
  -- an alias in a member goes by its name
  local c=C.validate({['until']='any',conditions={{['until']='crafting_done'},{['until']='platform_damage',platform='Asterion'}}})
  eq(c.conditions[2]['until'],'platform_hit')
  eq(C.validate({['until']='any',conditions={{['until']='crafting_done'}}})['until'],'any')
  has(C.names,'|all|any')
end
print('d23_batch127 CJ1 any validation: ok')

-- the platform lane: a step waiting on any, the guards beside it; met by the second member, then none to its timeout,
-- then a guard fires mid-wait; a malformed member refused in a dry run and in a submit
do
  local s={active={}}
  local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){}
  local base={state=function() return s end,player=function() return sol end,handlers={platforms=function() return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,claim=function() end,direct_action=function() end,
    condition=function(p,c,record) return C.check(p,c,nil,record) end,validate_condition=function(c) return C.validate(c) end,
    wait_info=function(out,record) return W.info(out,record) end,outcome=function() return 'done' end}
  local make=require('scheduler')
  local body_api={}; for k,v in pairs(base) do body_api[k]=v end
  local body=make(body_api)
  local q=require('queue_lanes'){scheduler=body,factory=make,base=base,is_read=function(name) return name=='platforms' end}
  local h=q.handlers
  local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; q.tick() end end
  local lane='platform:Asterion'
  local function status() return h.queue_status(sol,{lane=lane,history='all'}) end
  local guards={{when={['until']='researched',technology='rail'}},
    {when={['until']='item_count',platform='Asterion',item='promethium-asteroid-chunk',at_least=1000}}}
  -- a dry run checks every member
  local bad=probe(); bad.conditions[2].at_least=nil; bad.timeout=600
  fails(function() h.queue_submit(sol,{lane=lane,dry_run=true,steps={{action='wait_until',args=bad}},guards=guards}) end,
    'any conditions[2] (item_count): item_count requires at_least or below')
  fails(function() h.queue_submit(sol,{lane=lane,steps={{action='wait_until',args=bad}}}) end,'any conditions[2] (item_count)')
  -- a member the lane does not take (a body wait) refuses the any
  fails(function() h.queue_submit(sol,{lane=lane,dry_run=true,steps={{action='wait_until',args={['until']='any',conditions={{['until']='crafting_done'},probe().conditions[2]}}}}}) end,
    'remote lane wait_until supports')
  local ok=probe(); ok.timeout=600
  local dry=h.queue_submit(sol,{lane=lane,dry_run=true,steps={{action='wait_until',args=ok}},guards=guards})
  eq(dry.dry_run,true); eq(dry.queued,false)
  -- met by the second member
  leg.flown=0.0005; chunks=0
  h.queue_submit(sol,{lane=lane,steps={{action='wait_until',args=ok,label='probe'},{action='platforms'}},guards=guards})
  tick(20)
  eq(status().active.action,'wait_until')
  has(status().waiting.saw or s['lane_queues|Asterion'][1].current.saw,'none yet: #1 platform_progress')
  chunks=26; tick(10)
  local st=status()
  local entry=st.history[1]
  eq(entry.action,'wait_until'); eq(entry.ok,true); eq(entry.result.outcome,'met')
  eq(entry.result.matched.index,2); eq(entry.result.matched['until'],'item_count')
  has(entry.result.saw,'#2 item_count: met: promethium-asteroid-chunk 26')
  eq(st.history[2].action,'platforms')
  -- (d27 batch261 GR) the plan done: its guards (scope plan, the default) retire with it
  eq(#s['lane_queues|Asterion'][1].guards,0,'the guards retire with the plan')
  -- none to its timeout: the step fails with what each member read
  chunks=0
  local short=probe(); short.timeout=60
  h.queue_submit(sol,{lane=lane,steps={{action='wait_until',args=short}},guards=guards})
  tick(80)
  st=status()
  entry=st.history[#st.history]
  eq(entry.ok,false); eq(entry.result.outcome,'timed_out'); eq(entry.result.matched,nil)
  has(entry.result.saw,'none yet: #1 platform_progress: not yet:'); has(entry.result.saw,'#2 item_count: not yet: promethium-asteroid-chunk 0')
  -- a guard fires while the any waits: the step stops, the queue pauses
  h.queue_submit(sol,{lane=lane,steps={{action='wait_until',args=ok}},guards=guards})
  tick(20); eq(status().active.action,'wait_until')
  force.technologies.rail.researched=true; tick(10)
  st=status()
  eq(st.paused,true); eq(st.history[#st.history].action,'guard'); eq(st.history[#st.history].result.condition,'researched')
  force.technologies.rail.researched=false
end
print('d23_batch127 CJ1 any in a platform lane with guards: ok')

-- a guard on any: the member's evidence kept; an any guard is refused only when no member can be met
do
  local lanes={}
  local function unwired(platform) return {['until']='circuit_signal',platform=platform,signal='signal-check',at_least=2} end
  local pl={valid=true,name='Mute',hub={valid=true,get_circuit_network=function() return nil end}}
  force.platforms[#force.platforms+1]=pl
  defines.wire_connector_id={circuit_red=1,circuit_green=2}
  eq(C.guard_refusal(sol,{['until']='any',conditions={unwired('Mute'),{['until']='crafting_done'}}}),nil)
  has(C.guard_refusal(sol,{['until']='any',conditions={unwired('Mute'),unwired('Mute')}}),'any: no member can be met: circuit_signal signal-check at_least 2 on Mute')
  has(C.guard_refusal(sol,{['until']='all',conditions={unwired('Mute'),{['until']='crafting_done'}}}),'circuit_signal signal-check at_least 2 on Mute')
  table.remove(force.platforms)
end
print('d23_batch127 CJ1 any guard refusal: ok')
