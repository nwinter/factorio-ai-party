-- Run from repository root: lua tests/d26_batch231.lua
-- d26 batch231 RG (Astra #2427): at 66620993 a queue step lowered Kestrel II's low-density-structure request from
-- Fulgora to max 2100 while it waited there on item_count low-density-structure >= 3500; 1400 went down and the wait
-- could not hold, and the next step's schedule edit was refused (its new waits held: go: true). The queue's dry run had
-- taken both. requests (and its dry run) name the item_count waits at the stop it waits at and its next stop that the
-- new maxes leave unmet; in flight the trash takes what it has room for; the queue's dry run reads platform_schedule
-- steps as the call does (refused now, and what a refusal when it runs turns on) and requests steps as their dry run.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

game={tick=10000}
defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,paused=7},inventory={hub_main=1,hub_trash=2},wire_connector_id={circuit_red=1,circuit_green=2}}
prototypes={space_location={fulgora={},aquilo={},nauvis={}},fluid={['thruster-fuel']={}},
  item={['low-density-structure']={stack_size=50},['firearm-magazine']={stack_size=100},['cryogenic-science-pack']={stack_size=200}}}
local function cond(text)
  local name,cmp,v=text:match('^(%S+) (%S+) (%d+)$')
  return {first_signal={type=prototypes.fluid[name] and 'fluid' or 'item',name=name},comparator=cmp=='>=' and '≥' or cmp,constant=tonumber(v)}
end
-- Kestrel II at Fulgora (stop 1), Aquilo next; stop 1 waits on LDS >= 3500, stop 2 on cryogenic science >= 500
local recs={
  {station='fulgora',wait_conditions={{type='time',ticks=7200},{type='item_count',compare_type='and',condition=cond('low-density-structure >= 3500')},
    {type='item_count',compare_type='and',condition=cond('firearm-magazine >= 1000')}}},
  {station='aquilo',wait_conditions={{type='item_count',condition=cond('cryogenic-science-pack >= 500')},{type='time',compare_type='or',ticks=600}}},
  {station='nauvis',wait_conditions={{type='time',ticks=600}}}}
local cur=1
local sch={get_record_count=function() return #recs end}
setmetatable(sch,{__index=function(_,k) if k=='current' then return cur end end})
sch.get_wait_condition_count=function(pos) return #(recs[pos.schedule_index].wait_conditions or {}) end
sch.remove_wait_condition=function(pos,k) table.remove(recs[pos.schedule_index].wait_conditions,k) end
sch.add_wait_condition=function(pos,k,t) local w=recs[pos.schedule_index].wait_conditions or {}; recs[pos.schedule_index].wait_conditions=w; table.insert(w,k,{type=t}) end
sch.change_wait_condition=function(pos,k,w) recs[pos.schedule_index].wait_conditions[k]=w end
sch.set_wait_condition_mode=function(pos,k,m) recs[pos.schedule_index].wait_conditions[k].compare_type=m end
local pl={valid=true,name='Kestrel II',index=5,state=4,space_location={name='fulgora'},force={},paused=false}
sch.go_to_station=function(i) cur=i; pl.state=3 end
pl.get_schedule=function() return sch end
setmetatable(pl,{__index=function(_,k) if k=='schedule' then return {current=cur,records=recs} end end})
local held={['low-density-structure']=3500,['firearm-magazine']=1825,['cryogenic-science-pack']=500}
local main={get_item_count=function(n) if type(n)=='table' then if (n.quality or 'normal')~='normal' then return 0 end n=n.name end return held[n] or 0 end}
local trash_room={['low-density-structure']=450}
local trash={get_insertable_count=function(f) return trash_room[f.name] or 0 end}
setmetatable(trash,{__len=function() return 10 end})
pl.hub={valid=true,get_item_count=main.get_item_count,get_circuit_network=function() return nil end,
  get_inventory=function(id) return id==defines.inventory.hub_trash and trash or main end}
local p={name='astra',force={platforms={pl}}}
local st={platform_stops={[5]={at='fulgora',tick=1000}},saved_waits={}}
local where={stopped=true,at='fulgora'}
local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
  circuit_condition=function(c) return type(c)=='string' and cond(c) or c end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range: a whole number '..lo..'..'..hi..', got '..tostring(v)); return v end,
  freight={where=function() return where end,pads=function() return {},{} end,leg=function() return nil end}}

-- 1. gate lines: Astra's change, 3500..3500 to max 2100 from fulgora where it waits; the next stop's too.
local LDS,CRYO='low-density-structure@normal','cryogenic-science-pack@normal'
local before={fulgora={[LDS]=3500},nauvis={[LDS]=2100},aquilo={[CRYO]=1000}}
local after={fulgora={[LDS]=2100},nauvis={[LDS]=2100},aquilo={[CRYO]=300}}
local g=space.gate_lines(pl,pl.hub,before,after)
eq(#g,2)
eq(g[1],'low-density-structure: stop 1 (fulgora), where it waits now, waits for item_count low-density-structure >= 3500; its requests from fulgora would keep at most 2100 there (were 3500), so that wait cannot hold while it is there (the hub holds 3500 now)')
eq(g[2],'cryogenic-science-pack: stop 2 (aquilo), its next stop, waits for item_count cryogenic-science-pack >= 500; its requests from aquilo would keep at most 300 there (were 1000), so that wait cannot hold while it is there (the hub holds 500 now); the stop\'s waits are joined by or: another group can send it on')
-- a max at or above the wait, no max, or a max the change left as it was: no line
eq(space.gate_lines(pl,pl.hub,before,{fulgora={[LDS]=3500},aquilo={[CRYO]=1000}}),nil)
eq(space.gate_lines(pl,pl.hub,before,{fulgora={[LDS]=math.huge},aquilo={[CRYO]=1000}}),nil)
eq(space.gate_lines(pl,pl.hub,{fulgora={[LDS]=2000}},{fulgora={[LDS]=2000}}),nil)
-- a request from another planet keeps nothing at fulgora: no line (KEEP_RULE: it stays in the hub until it flies)
eq(space.gate_lines(pl,pl.hub,before,{fulgora={},nauvis={[LDS]=100},aquilo={[CRYO]=1000}}),nil)
-- in flight to stop 1: only its next stop
pl.state=3
eq(#space.gate_lines(pl,pl.hub,before,after),1)
has(space.gate_lines(pl,pl.hub,before,after)[1],'stop 1 (fulgora), its next stop,')
pl.state=4

-- 2. sends_down in flight: the trash takes what it has room for (a copy of world n: 450 of 2000), the rest stays.
where={stopped=false}
pl.space_location=nil
local d=space.sends_down(pl.hub,pl,{fulgora={[LDS]=3500}},{fulgora={[LDS]=500},nauvis={[LDS]=1000}})
has(d[1],'2000 over its max 1500: 450 go to the hub\'s trash now (the room its trash has) and down to fulgora at its next stop, asked or not; 1550 stay in the hub while it flies')
-- room for all of it: as before
trash_room[LDS:match('^[^@]+')]=5000
d=space.sends_down(pl.hub,pl,{fulgora={[LDS]=3500}},{fulgora={[LDS]=500},nauvis={[LDS]=1000}})
has(d[1],'2000 over its max 1500 go to the hub\'s trash now and down to fulgora at its next stop, asked or not')
-- stopped at fulgora, a max from another planet: the trash once it flies, at most its 10 slots (500 of 50s)
where={stopped=true,at='fulgora'}
pl.space_location={name='fulgora'}
d=space.sends_down(pl.hub,pl,{fulgora={[LDS]=3500}},{aquilo={[LDS]=1000}})
has(d[1],'2500 over its max 1000: at most 500 (its 10 trash slots) go to the hub\'s trash once it flies and down to aquilo at its next stop, asked or not; the rest stays in the hub while it flies')
-- Astra's case at the stop: all over the stop's max goes down there
d=space.sends_down(pl.hub,pl,{fulgora={[LDS]=3500}},{fulgora={[LDS]=2100}})
has(d[1],'1400 over its max 2100 go to the hub\'s trash now and down to fulgora (here), asked or not')
has(space.KEEP_RULE,'as much as the trash (10 slots) has room for')

-- 3. schedule_check: the call's own refusals, read now, and what a refusal when it runs turns on.
local function refusal(a) local ok,err=pcall(space.platform_schedule,p,a); assert(not ok,'refused'); return (tostring(err):gsub('^[^:]*:%d+: ','')) end
-- the waits without the LDS gate hold now (time passed, magazines 1825): the call refuses; the check says the same
local edit={platform='Kestrel II',stop=1,wait={{type='time',ticks=7200},{type='item_count',condition='firearm-magazine >= 1000',compare='and'}}}
local c=space.schedule_check(p,edit)
eq(c.refused,refusal(edit))
has(c.refused,'nothing changed: its new waits at stop 1 (fulgora), where it waits, hold now')
has(c.depends,'the edit makes it leave at once if it then waits at stop 1 (fulgora) and its new waits hold then')
has(c.depends,'that is refused, nothing changed, without go: true')
eq(#recs[1].wait_conditions,3,'nothing changed by the check')
-- with go: true no refusal; it says it would leave now
local go={platform='Kestrel II',stop=1,go=true,wait=edit.wait}
c=space.schedule_check(p,go)
eq(c.refused,nil); has(c.now,'it would leave at once now'); has(c.depends,'go: true makes it then')
eq(#recs[1].wait_conditions,3)
-- waits that do not hold now: no refusal, the dependence
c=space.schedule_check(p,{platform='Kestrel II',stop=1,wait={{type='item_count',condition='firearm-magazine >= 5000'}}})
eq(c.refused,nil); has(c.depends,'if it then waits at stop 1 (fulgora)')
-- out of range, current on the stop it waits at, an unknown platform: the call's texts
local a={platform='Kestrel II',stop=9,wait={}}
eq(space.schedule_check(p,a).refused,refusal(a))
a={platform='Kestrel II',current=1}
eq(space.schedule_check(p,a).refused,refusal(a))
has(space.schedule_check(p,a).depends,'refused if stop 1 (fulgora) is then the current stop')
a={platform='Nowhere',stop=1,wait={}}
eq(space.schedule_check(p,a).refused,refusal(a))
-- keep_leg while it waits: flies no leg
a={platform='Kestrel II',stops={{station='fulgora'},{station='aquilo'}},keep_leg=true}
eq(space.schedule_check(p,a).refused,refusal(a))
-- save_as is not kept by the check
c=space.schedule_check(p,{platform='Kestrel II',stops={{station='aquilo',wait={{type='time',ticks=60}},save_as='x'}}})
eq(c.refused,nil); eq(st.saved_waits.x,nil,'the check keeps no saved list')
eq(cur,1); eq(pl.state,4)

-- 4. world_checks: each platform_schedule step and each requests step on a platform (its dry run), named by step.
local asked
local real=space.requests
space.requests=function(_,b) asked=b; return {waits_unmet={'gate line'},sends_down={'down line'}} end
local lines=space.world_checks(p,{
  {action='wait_until',args={until_='item_count'}},
  {action='requests',args={platform='Kestrel II',section=2,set={{item='low-density-structure',min=1000,max=2100,from='fulgora'}}}},
  {action='platform_schedule',args=edit}})
space.requests=real
eq(asked.dry_run,true,'requests read as its dry run'); eq(asked.section,2)
eq(lines[1],'step 2 (requests Kestrel II): if it ran now: gate line')
eq(lines[2],'step 2 (requests Kestrel II): if it ran now: down line')
eq(lines[3],'step 3 (platform_schedule Kestrel II stop 1): refused if it ran now: '..refusal(edit))
has(lines[4],'step 3 (platform_schedule Kestrel II stop 1): when it runs: the edit makes it leave at once')
eq(#lines,4)
-- the first 4 requests steps are read; past them named, not read
local n=0
space.requests=function() n=n+1; return {} end
local many={}
for i=1,6 do many[i]={action='requests',args={platform='Kestrel II',section=1,set={}}} end
lines=space.world_checks(p,many)
space.requests=real
eq(n,space.REQUEST_CHECKS); eq(n,4)
eq(lines[1],'requests steps 5, 6: not read (the first 4 requests steps on a platform are read, each a dry run of the call)')

-- 5. queue_submit dry_run carries them (scheduler api.world_checks), with the tick and that earlier steps are not applied;
-- a world_checks that fails is said, and the dry run still answers.
do
  local got
  local checks=function(_,items) got=items; return {'step 1 (platform_schedule K stop 1): refused if it ran now: x'} end
  local api={state=function() return {} end,handlers={platform_schedule=function() end},world_checks=function(...) return checks(...) end}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua')(api)
  local plan={dry_run=true,steps={{action='platform_schedule',args={platform='K',stop=1,wait={}}}}}
  game.tick=66523494
  local r=S.handlers.queue_submit({index=1,name='astra'},plan)
  eq(r.dry_run,true); eq(r.queued,false); eq(#got,1)
  eq(r.world_checks[1],'step 1 (platform_schedule K stop 1): refused if it ran now: x')
  eq(r.world_checks_note,'read at tick 66523494, each step as if it ran now: the steps before it are not applied')
  checks=function() error('boom') end
  r=S.handlers.queue_submit({index=1,name='astra'},plan)
  eq(r.world_checks,nil); has(r.world_checks_error,'boom')
  -- the runtime wires it to space.lua
  local rt=io.open('mod/agent-harness_0.1.0/runtime.lua'):read('*a')
  assert(rt:find('world_checks=function(p,items) return space.world_checks(p,items) end',1,true),'runtime wires world_checks')
end
print('d26_batch231 RG: ok')
