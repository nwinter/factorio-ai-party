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
print('d18 batch38 ok')
