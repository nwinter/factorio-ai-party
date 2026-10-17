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

-- C2 (Opus 22:50, two deaths on walks past the nest at (-260,-168)): a walk begun inside a worm's reach goes out the
-- shortest way first (avoid.exit_point); the dry run names every reach the planned route enters, attacks within 24
-- tiles too (C4, Haiku 23:40).
do
  game={tick=0}
  local A=dofile('mod/agent-harness_0.1.0/avoid.lua'){state=function() return {} end}
  -- death 2's start: 15 tiles from a big worm (range 38 + 4), the goal outside it
  local worm={x=-262,y=-160,r=42,range=38,name='big-worm-turret'}
  local blobs={{members={worm}}}
  local q,text=A.exit_point({x=-247,y=-155.7},{x=-222,y=-132},blobs)
  assert(q,'an exit point')
  assert(((q.x+262)^2+(q.y+160)^2)^0.5>=43,'outside the reach with a tile to spare')
  assert(q.x>-247,'away from the worm (east), not along it')
  has(text,'the walk began inside the reach of big-worm-turret (-262,-160) (16 tiles; range 38): it went out the shortest way first')
  -- the goal inside it too: no exit leg (a goal in a reach takes unsafe_goal)
  eq(A.exit_point({x=-247,y=-155.7},{x=-250,y=-150},blobs),nil)
  eq(A.exit_point({x=-200,y=-100},{x=-222,y=-132},blobs),nil,'not inside: nothing')
  local R=dofile('mod/agent-harness_0.1.0/routecheck.lua'){avoid=A}
  local route={{x=-205,y=-146},{x=-300,y=-150}}
  local rows={{d=2,range=38,name='big-worm-turret',x=-262,y=-152},{d=10,range=24,attack=true,name='attack #4338',x=-224,y=-157,ago=1,size=19},
    {d=60,range=38,name='big-worm-turret',x=-262,y=-90}}
  local e=R.enters(route,rows)
  eq(#e,2)
  has(e[1],'big-worm-turret (-262,-152) (range 38): the route is inside it from')
  has(e[2],'attack #4338 at (-224,-157), under attack now (last hit 1 s ago, 19 attackers seen; 24 tiles round it): the route is inside it from (-205,-146)')
  eq(R.enters(route,{{d=60,range=38,name='w',x=0,y=0}}),nil)
end
print('d16_batch10 C2/C4 exit leg and route enters: ok')

-- C2: construct leaves out a ghost inside an enemy's reach (Opus's second death: a construct by a big worm), and by
-- default its walks avoid worms and spawners only.
do
  game={tick=0}
  local ghosts={{valid=true,type='entity-ghost',position={x=-252,y=-158},ghost_prototype={}},{valid=true,type='entity-ghost',position={x=-200,y=-140},ghost_prototype={}}}
  local p={position={x=-205,y=-146},surface={find_entities_filtered=function() return {} end}}
  local seen_mode
  local C=dofile('mod/agent-harness_0.1.0/construction.lua'){position=function(v) return v end,distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end,
    integer=function(v,d) return v or d end,known=function() return true end,directions={north=0},
    avoid_mode=function(v) return {spawners=true,attacks=true,pad=4} end,
    goal_inside=function(_,pos,mode) seen_mode=mode; if pos.x<-240 then return {m={name='big-worm-turret',x=-262,y=-160,range=38},d=10} end end}
  C.mark_obstacles=function() return {} end; C.tile_obstacles=function() return {} end
  local a=C.plan_ghosts(p,{},{left_top={x=-260,y=-170},right_bottom={x=-190,y=-130}},ghosts)
  eq(#a.pending,1); eq(a.pending[1].ghost,ghosts[2])
  eq(a.left_out,'1 ghost left out, inside an enemy\'s reach the map shows: 1 in big-worm-turret (-262,-160) range 38 (unsafe_goal: true builds them; avoid_enemies: false checks none)')
  eq(seen_mode.attacks,nil,'construct\'s default leaves areas under attack out')
  a=C.plan_ghosts(p,{unsafe_goal=true},{left_top={x=-260,y=-170},right_bottom={x=-190,y=-130}},ghosts)
  eq(#a.pending,2); eq(a.left_out,nil)
end
print('d16_batch10 C2 construct leaves out ghosts in reach: ok')

-- C1 (Opus 22:50: roboports took 55 of 81 MW): a network's draw by cause, and the robots' share.
do
  game={tick=0}
  defines={flow_precision_index={five_seconds=0},logistic_mode={requester=2,storage=1,passive_provider=3,active_provider=4,buffer=5},logistic_member_index={logistic_container=0}}
  prototypes={entity={['logistic-robot']={speed=0.05,energy_per_move=5000,energy_per_tick=50},['construction-robot']={speed=0.06,energy_per_move=5000,energy_per_tick=50}}}
  local per5={roboport=55000*1000/60,['assembling-machine-2']=20000*1000/60,accumulator=0}
  local stats={input_counts={roboport=1,['assembling-machine-2']=1},output_counts={['steam-engine']=1},
    get_flow_count=function(a) if a.category=='output' then return 81000*1000/60 end return per5[a.name] end}
  local pole={valid=true,electric_network_statistics=stats,position={x=0,y=0}}
  local req={valid=true,type='logistic-container',name='requester-chest',position={x=40,y=0},get_logistic_point=function() return {mode=2} end}
  local robot={valid=true,position={x=0,y=0},robot_order_queue={{target=req}}}
  local ln={network_id=7,all_logistic_robots=3000,available_logistic_robots=2000,all_construction_robots=50,available_construction_robots=50,
    cells={{owner={valid=true,position={x=1,y=1}},charging_robots={1,2},to_charge_robots={1}}},logistic_robots={robot},
    requester_points={{owner=req,targeted_items_deliver={{name='iron-plate',count=100}}}}}
  local force={name='player',worker_robots_speed_modifier=1.75,logistic_networks={nauvis={ln}}}
  local P=dofile('mod/agent-harness_0.1.0/powercause.lua'){pole_map=function() return {[2]={pole=pole,poles=10,sx=0,sy=0,surface='nauvis',force='player'}} end}
  local r=P.read({surface={name='nauvis'},force=force},{})
  eq(r.lines[1],'electric network 2 near (0,0): draws 75.0 MW, made 81.0 MW (last 5 s): roboport 55.0 MW (73%), assembling-machine-2 20.0 MW (27%)')
  has(r.lines[2],'logistic network 7 (1 roboports, near (1,1)): 3000 logistic robots, 1 flying, 2000 idle; 50 construction robots, 0 busy; 2 charging, 1 waiting to charge. A flying logistic robot draws about 44 kW (8.25 tiles/s with our speed research)')
  has(r.lines[2],'trips (1 sampled): 40 tiles on average, the longest 40, 100% to requesters; most on its way to: requester-chest (40,0): 100 coming (iron-plate 100)')
  defines,prototypes=nil,nil
end
print('d16_batch10 C1 power by cause: ok')
