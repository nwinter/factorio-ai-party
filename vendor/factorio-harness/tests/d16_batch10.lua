-- d16 batch10 (operator 22:55, agents' requests at the 22:50 poll). Run from the harness root: lua tests/d16_batch10.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Sonnet 22:50: until queue_done refused, silo_parts unknown): silo_parts is rocket_parts, at_least optional; all;
-- queue_done is a sleep's.
do
  game={tick=0}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end}
  local c=C.validate({['until']='silo_parts',position={x=1,y=2}})
  eq(c['until'],'rocket_parts')
  fails(function() C.validate({['until']='queue_done'}) end,'until queue_done is a sleep\'s (fh sleep SECONDS --until queue_done')
  fails(function() C.validate({['until']='silo_rockets'}) end,'a sleep also takes queue_done')
  fails(function() C.validate({['until']='all',conditions={}}) end,'until=all takes conditions')
  fails(function() C.validate({['until']='all',conditions={{['until']='any',conditions={}}}}) end,'until=all takes plain conditions')
  local p={crafting_queue_size=0,force={technologies={rail={researched=false}}}}
  local all={['until']='all',conditions={{['until']='crafting_done'},{['until']='researched',technology='rail'}}}
  C.validate(all)
  local met,saw=C.check(p,all)
  eq(met,false); eq(saw,'met: 0 crafts queued; not yet: rail not researched')
  p.force.technologies.rail.researched=true
  eq(C.check(p,all),true)
end
print('d16_batch10 A1 condition names and all: ok')

-- A1: sleep {until=queue_done}: no queue running ends at once (woke queue_done); a running queue (an order's round
-- too) wakes it when it finishes.
do
  game={tick=100}
  local s={active={},queues={}}
  local function integer(v,d,lo,hi,name) if v==nil then v=d end; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end
  local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return s end,integer=integer,replace=function() end,advance=function() end,
    clock_mode=function() return 'realtime' end,validate_condition=function() end}
  local p={index=1,character={valid=true,health=250}}
  local r=W.handlers.sleep(p,{seconds=60,condition={['until']='queue_done'}})
  eq(r.already_met,true); eq(r.condition,'queue_done')
  r=W.handlers.sleep_check(p,{})
  eq(r.woke,'queue_done'); has(r.queue,'no queue of yours runs (queue_status): until queue_done ends at once')
  eq(r.sleep_until,'queue_done'); eq(r.sleep_started_tick,100)
  -- an order's round counts with queue_done (a plain sleep leaves it to wake_on_orders)
  game.tick=2000
  s.queues[1]={pending={{action='refuel'}},history={},order={name='copper-fuel'}}
  r=W.handlers.sleep(p,{seconds=60,condition={['until']='queue_done'}})
  eq(r.already_met,nil); has(r.wakes_on,'your queue finishing or stalling')
  eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
  s.queues[1].pending={}
  game.tick=2010
  eq(W.handlers.sleep_check(p,{}).woke,'queue_done')
end
print('d16_batch10 A1 sleep until queue_done: ok')

-- A2 (Sonnet 22:50: "why is this silo part short", by hand down to coal): the ingredient picked, its feeders, the chain.
do
  game={tick=0}
  defines={inventory={chest=1},logistic_member_index={logistic_container=0},logistic_mode={requester=2,buffer=3}}
  local asked
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return {} end,
    bottleneck=function(p,a) asked=a; return {line='chain: low-density-structure: 4 of 4 makers lack plastic-bar, made 0/min, used 0/min; plastic-bar: no assembler, furnace, silo, mining drill or pump makes it, made 0/min, used 0/min',
      root='plastic-bar: no assembler, furnace, silo, mining drill or pump makes it, made 0/min, used 0/min',path={'low-density-structure','plastic-bar'},
      not_working={'low-density-structure: assembling-machine-2 (1.5,2.5) item_ingredient_shortage (lacks plastic-bar)'}} end}
  local chest={valid=true,type='logistic-container',name='requester-chest',position={x=20.5,y=138.5},unit_number=9,
    get_inventory=function() return {get_item_count=function() return 0 end} end,
    get_output_inventory=function() return nil end,
    get_logistic_point=function() return {mode=2,filters={{name='low-density-structure',count=100}},targeted_items_deliver={},
      logistic_network={get_item_count=function() return 0 end}} end}
  local ins={valid=true,pickup_target=chest}
  local silo={name='rocket-silo',position={x=14.5,y=140.5},force='player',surface={name='vulcanus',find_entities_filtered=function() return {ins} end}}
  ins.drop_target=silo
  local row={ingredients={{name='processing-unit',per_part=1,in_silo=3,in_hands=0,at_sources=301,needed=45},
    {name='low-density-structure',per_part=1,in_silo=0,in_hands=0,at_sources=0,needed=45,short=45}},lacks={'low-density-structure'}}
  local w=S.why({},silo,row)
  eq(w.item,'low-density-structure'); eq(w.picked,'it lacks one for the next part')
  eq(asked.item,'low-density-structure'); eq(asked.surface,'vulcanus')
  eq(w.feeders[1],'requester-chest (20.5,138.5) holds 0, asks 100; its logistic network holds 0 (robots bringing 0)')
  has(w.line,'low-density-structure: the silo holds 0 (1 a part, 45 for the parts left; it lacks one for the next part), 0 in feeding inserters\' hands')
  has(w.line,'root: plastic-bar: no assembler')
  eq(#w.not_working,1)
  -- nothing to make: said so
  has(S.why({},silo,{ingredients={},rocket='rocket built (50/50 parts) and ready to launch'}).line,'no rocket part to make now (rocket built')
  defines=nil
end
print('d16_batch10 A2 silo why: ok')

-- B1 (Grok 22:50, twice: from nearest with fresh could not deliver to a machine): from "nearest" with to stays a
-- courier from the nearest chest (it was rewritten to a give at to and refused).
do
  local A=dofile('mod/agent-harness_0.1.0/aliases.lua')({})
  local takes=function(_,k) return ({from=true,to=true,item=true,count=true,fresh=true,to_inventory=true,position=true,direction=true})[k]==true end
  local _,f=A.fix('transfer',{from='nearest',item='nutrients',count=40,fresh=true,to={x=7.5,y=20.5},to_inventory='assembling_machine_input'},takes)
  eq(f.from,'nearest'); eq(f.to.x,7.5); eq(f.position,nil); eq(f.direction,nil)
  -- to alone is still the give's target
  _,f=A.fix('transfer',{item='coal',count=5,to={x=1,y=2}},takes)
  eq(f.position.x,1); eq(f.direction,'to_entity')
end
print('d16_batch10 B1 from nearest with to: ok')

-- B3 (Sol 22:50: the remaining bill of materials reconciled by hand every five minutes): ghosts' need less hub and
-- in-flight cargo, packed into rockets.
do
  game={tick=0}
  defines={cargo_destination={station=1,space_platform=2},inventory={hub_main=1,cargo_unit=2}}
  prototypes={item={['space-platform-foundation']={weight=20000,stack_size=50},pipe={weight=5000,stack_size=100}}}
  local hub={valid=true,get_inventory=function() return {get_item_count=function(n) return n=='pipe' and 100 or 0 end} end,
    get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={{value={name='space-platform-foundation'},min=2826}}} end} end}
  local floor={name='space-platform-foundation',items_to_place_this={{name='space-platform-foundation',count=1}}}
  local pipe={name='pipe',items_to_place_this={{name='pipe',count=1}}}
  local ghosts={}
  for i=1,120 do ghosts[#ghosts+1]={type='tile-ghost',ghost_name='space-platform-foundation',ghost_prototype=floor} end
  for i=1,165 do ghosts[#ghosts+1]={type='entity-ghost',ghost_name='pipe',ghost_prototype=pipe} end
  local pl
  local surface={find_entities_filtered=function() return ghosts end,count_entities_filtered=function() return 0 end,count_tiles_filtered=function() return 639 end}
  pl={name='Meridian',surface=surface,hub=hub}
  local pod={valid=true,cargo_pod_destination={type=2,space_platform=pl},get_inventory=function() return {get_contents=function() return {{name='pipe',count=50}} end} end}
  game.surfaces={fulgora={find_entities_filtered=function() return {pod} end}}
  local cargo=dofile('mod/agent-harness_0.1.0/cargo.lua'){}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,cargo=cargo}
  local r=B.read({force='player'},{platform='Meridian',pack=true})
  eq(r.pods_in_flight,1); eq(r.tile_ghosts,120); eq(r.entity_ghosts,165)
  eq(r.lines[1],'space-platform-foundation: ghosts need 120 (639 built); hub holds 0; 120 to send (the hub asks 2826)')
  eq(r.lines[2],'pipe: ghosts need 165 (0 built); hub holds 100, 50 in flight; 15 to send (the hub asks none)')
  has(r.lines[3],'to send: 2475 kg, at least 3 rockets by weight and slots; pack: 3 rockets')
  eq(r.pack.split[1].items,'space-platform-foundation*50')
  defines,prototypes=nil,nil; game={tick=0}
end
print('d16_batch10 B3 platform bill of materials: ok')
