-- d18 batch38 (the 18:20 poll). Run from the harness root: lua tests/d18_batch38.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A1 (Sol 18:21: platform_schedule failed for no_schedule while the platform began flying moments later): a queue step
-- whose platform read no_schedule in the call's tick waits for the second read; it fails only when that still reads it.
do
  game={tick=0}
  local st={}
  local players={{index=1,valid=true,name='sol',force={name='player'}}}
  local verdict
  local calls=0
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,
    handlers={platform_schedule=function() calls=calls+1; return {state='no_schedule',recheck={platform='Wayfarer',first='no_schedule'}} end,craft=function() return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,validate_condition=function() end,
    recheck_read=function(rc) return verdict end}
  local function run(n) for _=1,n do game.tick=game.tick+1; S.tick() end end
  S.handlers.queue_submit(players[1],{steps={{action='platform_schedule',args={platform='Wayfarer',next=true}},{action='craft'}}})
  run(25)
  local q=st.queues[1]
  eq(calls,1); assert(q.current and q.current.action=='platform_schedule','the step waits for the second read')
  eq(#q.pending,1,'craft waits behind it')
  verdict={ok=true,line='Wayfarer read no_schedule at tick 1 and on_the_path 39 ticks later'}
  run(10)
  eq(q.current,nil); eq(q.history[1].ok,true); eq(q.history[1].result.recheck_read,verdict.line)
  run(2); eq(#q.pending,0,'then the next step')
  -- still stuck: the step fails with the second read
  verdict=nil
  S.handlers.queue_submit(players[1],{steps={{action='platform_schedule',args={platform='Wayfarer',next=true}},{action='craft'}}})
  run(20)
  verdict={ok=false,line='x',error='Wayfarer read no_schedule at tick 40 and still no_schedule 300 ticks later; the call failed'}
  run(10)
  local last=q.history[#q.history]
  eq(last.ok,false); has(last.result.reason,'still no_schedule 300 ticks later')
  game=nil
end
print('d18_batch38 A1 a queue step waits for the second read: ok')


-- A2 (Grok 18:20, twice: copper from Petrel read "to the ground (no pad takes it)" and landed in the pad at (54,8)): a
-- pod that names no station yet goes to the planet's landing pad, said so; the station once named; no pad: the ground.
do
  defines={inventory={cargo_unit=1}}
  local st={}
  local glebapad={valid=true,position={x=54,y=8}}
  local pads={gleba={glebapad},vulcanus={}}
  game={forces={},get_surface=function(n) return {valid=true,name=n,find_entities_filtered=function(f)
    eq(f.type,'cargo-landing-pad'); assert(f.limit==1,'bounded'); return pads[n] or {} end} end}
  local P=dofile('mod/agent-harness_0.1.0/pods.lua'){state=function() return st end}
  local on_deck={}
  local deck={name='platform-7',valid=true,find_entities_filtered=function() return on_deck end}
  local function pod(unit,dest) return {valid=true,unit_number=unit,cargo_pod_state='awaiting_launch',surface=deck,cargo_pod_destination=dest,
    get_inventory=function() return {get_contents=function() return {{name='copper-ore',count=500,quality='normal'}} end} end} end
  game.forces.player={name='player',platforms={{valid=true,name='Petrel',space_location={name='gleba'},surface=deck}}}
  local a=pod(1,{type=1,surface='gleba'})
  on_deck={a}
  P.tick(60)
  local f=P.in_flight('player','gleba')
  eq(f[1].pad.x,54); eq(f[1].guessed,true)
  eq(P.line('player','gleba'),"1 cargo pod from Petrel still in the air: copper-ore*500 (to the landing pad at (54,8) (gleba's pad: pods from a platform land in it; this one names no station yet); 1 awaiting_launch)")
  -- the station named later: what the pod says
  a.cargo_pod_destination={type=1,station={valid=true,position={x=54,y=8},surface={name='gleba'}}}
  P.tick(120)
  eq(P.in_flight('player','gleba')[1].guessed,nil)
  has(P.line('player','gleba'),'(to the landing pad at (54,8); 1 awaiting_launch)')
  -- a planet with no landing pad of ours
  game.forces.player.platforms[1].space_location={name='vulcanus'}
  on_deck={pod(2,{type=1,surface='vulcanus'})}
  P.tick(180)
  has(P.line('player','vulcanus'),'(to the ground (no landing pad of ours on vulcanus);')
  game,defines=nil,nil
end
print('d18_batch38 A2 a pod with no station yet lands in the planet\'s pad: ok')

-- A3 (Astra: the warned worm read as dead, and a live scan found it): each warned enemy with its read's age and whether
-- its chunk is in sight now.
do
  game={tick=3600}
  prototypes={entity={['construction-robot']={max_payload_size=1},['logistic-robot']={max_payload_size=1}}}
  local function ent(name,x,y,u) return {valid=true,name=name,position={x=x,y=y},unit_number=u} end
  local port=ent('roboport',0,0,1)
  local net={network_id=7,cells={{owner=port,stationed_construction_robot_count=50,stationed_logistic_robot_count=0}},available_construction_robots=50,
    available_logistic_robots=0,select_pickup_point=function() return {owner=ent('storage-chest',5,0,3)} end,select_drop_point=function() return {owner=ent('storage-chest',5,0,3)} end}
  local visible={}
  local force={worker_robots_storage_bonus=0,find_logistic_network_by_position=function() return net end,
    is_chunk_visible=function(_,c) return visible[c.x..','..c.y]==true end}
  local surf={find_logistic_networks_by_construction_area=function() return {net} end}
  local worms={{name='medium-worm-turret',x=-65.59,y=-322.04,seen=3000,cx=-3,cy=-11}}
  local av={chunks_near=function() return {{-3,-11,'-3,-11'}} end,structures=function() return {list=worms,unread=0} end,
    reach=function() return 30 end,seg_dist=function() return 6 end}
  local DP=dofile('mod/agent-harness_0.1.0/robottrips.lua'){avoid=function() return av end}
  local lines=DP.preview(surf,force,{{kind='construct',pos={x=-60,y=-320},item='big-electric-pole',count=1}})
  local warn
  for _,l in ipairs(lines) do if l:find('medium-worm-turret',1,true) then warn=l end end
  has(warn,'passes 6 tiles from medium-worm-turret (-65.6,-322) (reach 30; read 10s ago, its chunk charted, not in sight now)')
  visible['-3,-11']=true
  lines=DP.preview(surf,force,{{kind='construct',pos={x=-60,y=-320},item='big-electric-pole',count=1}})
  for _,l in ipairs(lines) do if l:find('medium-worm-turret',1,true) then warn=l end end
  has(warn,'(reach 30; read 10s ago, its chunk in sight now)')
  game,prototypes=nil,nil
end
print('d18_batch38 A3 a warned enemy\'s read age and sight: ok')

-- A4 (Astra: "its network holds no big-electric-pole" while a robot carried one to it): ghosts and construction_robots
-- count what construction robots with an order on the ghost carry first, and say the shortage only of the rest.
do
  defines={inventory={robot_cargo=9}}
  prototypes={entity={}}
  local big={name='big-electric-pole',collision_box={left_top={x=-0.9,y=-0.9},right_bottom={x=0.9,y=0.9}},items_to_place_this={{name='big-electric-pole',count=1}}}
  local force={}
  local surf={name='nauvis'}
  local ghosts={}
  for i=1,3 do ghosts[i]={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='big-electric-pole',ghost_prototype=big,position={x=100+i*8,y=-400},
    force=force,surface=surf,unit_number=700+i,bounding_box={left_top={x=99+i*8,y=-401},right_bottom={x=101+i*8,y=-399}}} end
  local function bot(x,y,target,n)
    return {valid=true,name='construction-robot',position={x=x,y=y},energy=1,prototype={max_energy=1},robot_order_queue={{type=3,target=target}},
      get_inventory=function(i) eq(i,9); return {get_item_count=function(item) return item=='big-electric-pole' and n or 0 end,
        get_contents=function() return n>0 and {{name='big-electric-pole',count=n,quality='normal'}} or {} end} end}
  end
  local net={valid=true,network_id=12,all_construction_robots=40,available_construction_robots=30,cells={{owner={valid=true,position={x=150,y=-380}},construction_radius=110}},
    storages={},providers={},find_cell_closest_to=function() return true end,get_item_count=function() return 0 end,
    construction_robots={bot(108,-420,ghosts[1],1),bot(116,-300,ghosts[2],0)}}
  surf.find_entities_filtered=function(f) if f.type then return ghosts end return {} end
  surf.find_logistic_networks_by_construction_area=function() return {net} end
  local GL=dofile('mod/agent-harness_0.1.0/ghostlist.lua'){position=function(v) return v end,integer=function(v,d) return v or d end,
    distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end}
  local r=GL.read({surface=surf,position={x=100,y=-400},force=force,get_main_inventory=function() return nil end},{})
  local by={}
  for _,g in ipairs(r.ghosts) do by[g.position.x]=g end
  eq(by[108].robots,'in transit: a construction robot carries big-electric-pole to it (20 tiles away, its order 1)')
  eq(by[108].in_transit.count,1); eq(by[108].in_transit.distance,20)
  eq(by[116].robots,'its network holds no big-electric-pole and no robot carries one to it','a robot with an order on it and an empty cargo')
  eq(by[124].robots,'its network holds no big-electric-pole and no robot carries one to it')
  has(r.summary,'1 in transit: a construction robot carries big-electric-pole to it')
  -- construction_robots sources: in transit first, the shortage of the rest
  local RB=dofile('mod/agent-harness_0.1.0/robots.lua'){position=function(v) return v end}
  local lines=RB.sources({surface=surf,force=force},net)
  has(lines[1],'3 ghosts for big-electric-pole near (116,-400): 1 in transit in construction robots\' cargo (1 big-electric-pole, the nearest 20 tiles off); for the other 2: no chest in the network holds it')
  net.construction_robots={bot(108,-420,ghosts[1],1),bot(116,-395,ghosts[2],1),bot(124,-405,ghosts[3],1)}
  lines=RB.sources({surface=surf,force=force},net)
  has(lines[1],'3 ghosts for big-electric-pole near (116,-400): 3 in transit in construction robots\' cargo (3 big-electric-pole, the nearest 5 tiles off)')
  assert(not lines[1]:find('no chest',1,true),lines[1])
  defines,prototypes=nil,nil
end
print('d18_batch38 A4 a robot carrying the item reads in transit: ok')

-- B1 (Haiku, 3 times: "construct stops the whole batch when one item is missing"; on shift36 the poles were left out
-- inside a spitter spawner's sight and the 2 laser ghosts skipped for no lasers held): the reply and the result say what
-- it builds, what it skips for a missing item (the count short) and what it leaves out.
do
  prototypes={entity={['laser-turret']={items_to_place_this={{name='laser-turret',count=1}}},['medium-electric-pole']={items_to_place_this={{name='medium-electric-pole',count=1}}}}}
  local C=dofile('mod/agent-harness_0.1.0/construction.lua'){directions={}}
  local action={to_build={['laser-turret']=2},left_names={['medium-electric-pole']=3,['laser-turret']=2},built=0,missing={['laser-turret']=2},failed={}}
  local inv={get_item_count=function(i) return i=='medium-electric-pole' and 9 or 0 end}
  eq(C.plan_line({get_main_inventory=function() return inv end},action),
    "2 ghosts to build: 2 laser-turret; you hold too few for 2 laser-turret (those are skipped unless crafted in time; the rest are built); left out inside an enemy's reach: 3 medium-electric-pole, 2 laser-turret")
  eq(C.result_line(action),"built 0 of the 2 ghosts it took up; skipped, item missing (none held and none crafting; the rest built): 2 laser-turret short; left out inside an enemy's reach the map shows (unsafe_goal: true builds them): 3 medium-electric-pole, 2 laser-turret")
  -- the first batch: poles built, lasers short
  local a2={to_build={['laser-turret']=2,['medium-electric-pole']=3},built=3,missing={['laser-turret']=2},failed={}}
  eq(C.result_line(a2),'built 3 of the 5 ghosts it took up; skipped, item missing (none held and none crafting; the rest built): 2 laser-turret short')
  eq(C.result_line({to_build={['medium-electric-pole']=4},built=4,missing={},failed={}}),'built 4 of the 4 ghosts it took up')
  prototypes=nil
end
print('d18_batch38 B1 construct says built, skipped and left out: ok')

-- B2 (Haiku: big pole ghosts whose network held none, 3 times; a pole ghost outside every roboport's construction area):
-- robot_dispatch names the covering network holding none of the item, and the nearest roboport and how far outside.
do
  prototypes={entity={['construction-robot']={max_payload_size=1},['logistic-robot']={max_payload_size=1}}}
  local port={valid=true,name='roboport',position={x=0,y=0},unit_number=1}
  local net={network_id=5,cells={{owner=port,construction_radius=55,stationed_construction_robot_count=10,stationed_logistic_robot_count=0}},
    available_construction_robots=10,available_logistic_robots=0,get_item_count=function() return 0 end,
    select_pickup_point=function() return nil end,select_drop_point=function() return nil end}
  local force={worker_robots_storage_bonus=0,logistic_networks={nauvis={net}},find_logistic_network_by_position=function() return net end}
  local surf={name='nauvis',find_logistic_networks_by_construction_area=function(pos) if math.abs(pos.x)<=55 and math.abs(pos.y)<=55 then return {net} end return {} end}
  local DP=dofile('mod/agent-harness_0.1.0/robottrips.lua'){}
  local lines=DP.preview(surf,force,{{kind='construct',pos={x=10,y=10},item='big-electric-pole',count=1},{kind='construct',pos={x=12,y=10},item='big-electric-pole',count=1},
    {kind='construct',pos={x=67,y=3},item='big-electric-pole',count=1}})
  local all=table.concat(lines,' | ')
  has(all,'2 big-electric-pole ghosts near (11,10): network 5 covering them holds no big-electric-pole')
  has(all,"1 big-electric-pole ghost near (67,3): no roboport's construction area covers it; the nearest roboport, roboport (0,0) (network 5), covers 55 tiles round it, and it is 12 tiles outside that")
  assert(not all:find('no chest of the network',1,true),all)
  prototypes=nil
end
print('d18_batch38 B2 robot_dispatch: none held, outside every construction area: ok')

-- B3 (Luna: the only roboport that landed was built at a duplicate ghost (67,44), not the claimed one at (204,69)): more
-- ghosts of ours in the network want the item than it holds: each named, its claim and distance, in the drop's receipt
-- and the ghosts read.
do
  prototypes={item={roboport={place_result={name='roboport'}},['iron-plate']={}},entity={roboport={items_to_place_this={{name='roboport',count=1}}}}}
  local g1={valid=true,type='entity-ghost',ghost_name='roboport',position={x=204,y=69}}
  local g2={valid=true,type='entity-ghost',ghost_name='roboport',position={x=67,y=44}}
  local net={network_id=98,cells={{owner={valid=true,position={x=100,y=50}},construction_radius=110}},get_item_count=function() return 0 end}
  local surf={name='gleba',find_logistic_networks_by_construction_area=function() return {net} end,
    find_entities_filtered=function(f) eq(f.ghost_name,'roboport'); eq(f.type,'entity-ghost'); assert(f.limit,'bounded'); return {g1,g2} end}
  local GL=dofile('mod/agent-harness_0.1.0/ghostlist.lua'){position=function(v) return v end,integer=function(v,d) return v or d end,
    distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end,
    claim_at=function(s,pos) if pos.x==204 then return {id=1112,owner='luna',title='Gleba east farm defense'} end end}
  local c=GL.contested(surf,{},'roboport',{x=54,y=8})
  eq(c.wanted,2); eq(c.holds,0); eq(c.network,98)
  eq(c.lines[1],'roboport (67,44) (no claim), 38 tiles from (54,8)')
  eq(c.lines[2],'roboport (204,69) (claim #1112 Gleba east farm defense, luna), 162 tiles from (54,8)')
  has(c.line,'2 roboport ghosts of ours in network 98 want roboport and it holds 0: ')
  has(c.line,'robots build whichever they take it to first (the game sets no order among ghosts')
  eq(GL.contested(surf,{},'iron-plate',{x=54,y=8}),nil,'an item that places nothing')
  net.get_item_count=function() return 2 end
  eq(GL.contested(surf,{},'roboport',{x=54,y=8}),nil,'the network holds enough')
  -- the drop's receipt: once when it lands
  net.get_item_count=function() return 0 end
  local st={}
  game={tick=100,surfaces={gleba={name='gleba',find_entities_filtered=function() return {} end}},forces={player={name='player'}}}
  defines={inventory={cargo_unit=1}}
  local D=dofile('mod/agent-harness_0.1.0/drops.lua'){state=function() return st end,who=function(p) return p.name end,
    contested=function(s,f,item,at) eq(s.name,'gleba'); return GL.contested(surf,f,item,at) end}
  local id=D.record({name='luna',force={name='player'}},{platform='Swiftlet',surface='gleba',pad={x=54,y=8},sent={'roboport*1'}})
  st.drops.list[1].pod=nil
  game.tick=200; D.tick(210)
  local lines=D.lines({name='luna'},{})
  has(lines[1],'drop #'..id..' from Swiftlet landed in the landing pad at (54,8) on gleba: roboport*1')
  has(lines[1],'; 2 roboport ghosts of ours in network 98 want roboport and it holds 0: roboport (67,44) (no claim), 38 tiles from (54,8); roboport (204,69) (claim #1112')
  game,defines,prototypes=nil,nil,nil
end
print('d18_batch38 B3 ghosts that want an item the network holds too few of: ok')

-- C3 (Sonnet: 0.3 a minute idle against 55 while a load waits read as a contradiction): the part rate's window and what
-- the silo did in it (parts are made only while it builds).
do
  game={tick=0}
  defines={rocket_silo_status={building_rocket=0,rocket_ready=7}}
  local st={}
  local status='working'
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return st end,status_name=function() return status end}
  local silo={unit_number=5,products_finished=0,rocket_silo_status=0}
  S.sample_made(silo)
  -- 1 min building: 50 parts; then 9 min with a built rocket standing
  game.tick=3600; silo.products_finished=50; silo.rocket_silo_status=7; S.sample_made(silo)
  for i=1,9 do game.tick=3600+i*3600; S.sample_made(silo) end
  local m=S.sample_made(silo)
  eq(m.per_min,5); eq(m.while_building,50); eq(m.state,'ready')
  eq(S.rate_text(m),'5 a minute over the last 10m00s (samples at most every 10 s): building parts 1m00s (50 a minute then), holding a built rocket (no parts until it launches) 9m00s')
  -- short of an ingredient while building
  silo.rocket_silo_status=0; status='item_ingredient_shortage'
  game.tick=game.tick+1200; S.sample_made(silo)
  game.tick=game.tick+1200; m=S.sample_made(silo)
  has(S.rate_text(m),'short of an ingredient 20s')
  game,defines=nil,nil
end
print('d18_batch38 C3 the part rate says its window and what the silo did: ok')

-- C4 (Grok 18:20: about 200 agricultural packs were inside 5 minutes of spoiling after Petrel left): staged cargo that
-- spoils before the platform asking for it is back.
do
  game={tick=60000}
  defines={inventory={rocket_silo_rocket=1,chest=2}}
  prototypes={item={['agricultural-science-pack']={get_spoil_ticks=function() return 216000 end},['iron-plate']={get_spoil_ticks=function() return 0 end}}}
  local function stack(name,count,spoil) return {valid_for_read=true,name=name,count=count,spoil_tick=spoil} end
  local rocket={stack('agricultural-science-pack',200,60000+18000),stack('agricultural-science-pack',100,60000+90000)}
  local chest_inv={stack('agricultural-science-pack',50,60000+30000)}
  local chest={valid=true,type='container',name='storage-chest',position={x=24.5,y=47.5},get_item_count=function() return 50 end,get_inventory=function() return chest_inv end}
  local ln={storages={chest},providers={}}
  local hub={valid=true,get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,
    filters={{value={name='agricultural-science-pack'},min=400,import_from='gleba'},{value={name='iron-plate'},min=100,import_from='gleba'}}} end} end}
  local petrel={valid=true,name='Petrel',hub=hub,space_location={name='nauvis'}}
  local surf={name='gleba',planet={name='gleba'},find_logistic_network_by_position=function() return ln end}
  local silo={valid=true,name='rocket-silo',position={x=65.5,y=14.5},surface=surf,force={platforms={petrel}},get_inventory=function(i) eq(i,1); return rocket end}
  local eta=600
  local PA=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return {} end,platform_eta=function(pl,loc) eq(pl.name,'Petrel'); eq(loc,'gleba'); return eta end}
  local k,d=PA.silo_spoils(silo,surf)
  eq(k,'silo_spoils')
  eq(d,'rocket-silo (65.5,14.5): 250 agricultural-science-pack staged for Petrel (its hub asks gleba for it) spoil before its next arrival here in about 600s: the first in 300s (the silo\'s rocket); in storage-chest (24.5,47.5) 50, the silo\'s rocket 200')
  eta=200
  eq(PA.silo_spoils(silo,surf),nil,'back before any spoils')
  -- a platform here now: no alert
  eta=600; petrel.space_location={name='gleba'}
  eq(PA.silo_spoils(silo,surf),nil)
  game,defines,prototypes=nil,nil,nil
end
print('d18_batch38 C4 staged cargo spoiling before its platform is back: ok')

-- D1 with batch37 D2 (Sol: a filter set from a constant minus a whole-belt reader; the count took in belts the feeder could
-- not reach): circuit_audit's feeders: the signals, the combinators, each belt reader's exact belts, past the pickup.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2,combinator_input_red=3,combinator_input_green=4,combinator_output_red=5,combinator_output_green=6},
    wire_origin={player=0},control_behavior={transport_belt={content_read_mode={pulse=0,hold=1,entire_belt_hold=2}}}}
  prototypes={item={['iron-plate']={}}}
  local nets={}
  local function net(id,sigs) nets[id]={network_id=id,signals=sigs}; return nets[id] end
  local conns={}
  local function conn(e,id,netid) local c={owner=e,wire_connector_id=id,connections={},net=netid}; conns[#conns+1]=c; return c end
  local function link(a,b) a.connections[#a.connections+1]={target=b,origin=0}; b.connections[#b.connections+1]={target=a,origin=0} end
  local unit=0
  local function ent(t,name,x,y,f) unit=unit+1; local e={valid=true,type=t,name=name,position={x=x,y=y},unit_number=unit,wires={}}
    for k,v in pairs(f or {}) do e[k]=v end
    e.get_wire_connector=function(id) return e.wires[id] end
    e.get_circuit_network=function(id) local c=e.wires[id]; return c and nets[c.net] end
    return e end
  -- a belt line of 6, flowing east; 1 tile segment length each; items on each
  local belts={}
  for i=1,6 do belts[i]=ent('transport-belt','transport-belt',i,0,{direction=4,get_max_transport_line_index=function() return 2 end,
    get_transport_line=function(l) return {get_item_count=function(n) return n=='iron-plate' and 5 or 0 end,get_contents=function() return {{name='iron-plate',count=5}} end,total_segment_length=6} end}) end
  for i=1,6 do belts[i].belt_neighbours={inputs={belts[i-1]},outputs={belts[i+1]}} end
  local side=ent('transport-belt','transport-belt',2,1,{direction=0,belt_neighbours={inputs={},outputs={belts[2]}},get_max_transport_line_index=function() return 2 end,
    get_transport_line=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end,total_segment_length=1} end})
  table.insert(belts[2].belt_neighbours.inputs,side)
  local reader=belts[3]
  reader.get_control_behavior=function() return {read_contents=true,read_contents_mode=2} end
  net(14,{{signal={name='iron-plate'},count=30}})
  net(12,{{signal={name='iron-plate'},count=70}})
  local comb=ent('arithmetic-combinator','arithmetic-combinator',0,5)
  local hub=ent('space-platform-hub','space-platform-hub',0,0,{get_control_behavior=function() return {read_contents=true} end,get_item_count=function() return 500 end})
  local ins=ent('inserter','inserter',4,1,{filter_slot_count=1,get_filter=function() return {name='iron-plate'} end,pickup_target=belts[4],
    get_control_behavior=function() return {circuit_set_filters=true} end})
  ins.wires[1]=conn(ins,1,12); comb.wires[5]=conn(comb,5,12); hub.wires[1]=conn(hub,1,12)
  link(ins.wires[1],comb.wires[5]); link(ins.wires[1],hub.wires[1])
  comb.wires[4]=conn(comb,4,14); reader.wires[2]=conn(reader,2,14); link(comb.wires[4],reader.wires[2])
  local CA=dofile('mod/agent-harness_0.1.0/circaudit.lua'){circuit_short=function(e) return e==comb and 'each * -1 -> each' or nil end}
  CA.feeders_begin(); local line=CA.feeder(ins); CA.feeders_end()
  has(line,'inserter (4,1): its filters set by the circuit (now iron-plate); picks up from transport-belt (4,0)')
  has(line,'red #12: iron-plate 70')
  has(line,'put out by arithmetic-combinator (0,5) (each * -1 -> each)')
  has(line,'its green input #14: iron-plate 30')
  has(line,'transport-belt (3,0) reads its whole belt: its count covers 6 belts from (1,0) to (6,0) (the game\'s segment, in flow order), holding iron-plate 60 now')
  has(line,'2 of those belts lie past the inserter\'s pickup (4,0), from (5,0) to (6,0): it cannot take what they hold (iron-plate 20 now)')
  has(line,'belts joining inside the count (their items count in it): transport-belt (2,1) into (2,0) (upstream of the pickup)')
  has(line,'the hub (0,0) reads its contents onto it: iron-plate 500 (its own signal, apart from any belt read)')
  -- an inserter the circuit does not set: none
  eq(CA.feeder(ent('inserter','inserter',9,9,{get_control_behavior=function() return {} end})),nil)
  defines,prototypes=nil,nil
end
print('d18_batch38 D1/batch37 D2 circuit-gated feeders and their belt readers: ok')

-- D2 (Opus 18:23: advanced circuits made and used at 216 a minute; which machines or chests took them?): supply {item,
-- consumers: "all"}: every machine whose recipe takes it and every chest asking for it, the largest use first.
do
  game={tick=7200}
  defines={logistic_member_index={logistic_container=1},logistic_mode={requester=1,buffer=2}}
  prototypes={item={['advanced-circuit']={}},recipe={['processing-unit']={energy=10,ingredients={{name='advanced-circuit',amount=2},{name='electronic-circuit',amount=20}}},
    ['electric-furnace']={energy=5,ingredients={{name='advanced-circuit',amount=5},{name='steel-plate',amount=10}}},['iron-plate']={energy=3.2,ingredients={{name='iron-ore',amount=1}}}}}
  local function m(x,recipe,speed,status) return {valid=true,type='assembling-machine',name='assembling-machine-3',position={x=x,y=0},unit_number=x,crafting_speed=speed,
    status=status,get_recipe=function() return {name=recipe} end,bounding_box={left_top={x=x-1.5,y=-1.5},right_bottom={x=x+1.5,y=1.5}}} end
  local list={m(1,'processing-unit',1.25,'working'),m(5,'processing-unit',1.25,'working'),m(9,'electric-furnace',1.25,'item_ingredient_shortage'),m(13,'iron-plate',1,'working')}
  local surf={index=1,name='nauvis',find_entities_filtered=function() return {} end}
  local force={name='player',logistic_networks={nauvis={}}}
  local S=dofile('mod/agent-harness_0.1.0/supply.lua'){census_crafters=function() return list,0 end,status_name=function(e) return e.status end}
  local r=S.consumers({force=force,surface=surf},surf,'advanced-circuit',{consumers='all'})
  eq(r.machines,3); eq(r.working,2); eq(r.per_min,30); eq(r.full_per_min,105)
  eq(r.line,'advanced-circuit on nauvis: 3 machines take it (1 electric-furnace, 2 processing-unit), 2 working, 30 a minute now (105 at full speed); 0 requester or buffer chests ask for it')
  eq(r.rows[1].recipe,'processing-unit'); eq(r.rows[1].per_min,15)
  eq(r.rows[3].line,'assembling-machine-3 (9,0) electric-furnace: item ingredient shortage; takes 0 a minute now (75 at full speed)')
  local ok,err=pcall(S.consumers,{force=force,surface=surf},surf,'advanced-circuit',{consumers=true}); assert(not ok and tostring(err):find('consumers is "all"',1,true),err)
  game,defines,prototypes=nil,nil,nil
end
print('d18_batch38 D2 supply consumers: ok')
print('d18 batch38 ok')
