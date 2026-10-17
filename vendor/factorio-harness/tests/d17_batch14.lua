-- d17 batch14 contracts. Run from the harness root: lua tests/d17_batch14.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A2 (Haiku: a standing order walked him 31 tiles during a sleep): order_set max_walk holds an order whose place lies
-- farther than that; a sleep with orders: false starts none while it runs.
do
  game={tick=1}
  local st={}
  local started=0
  local char={valid=true,position={x=0,y=0}}
  local api={state=function() return st end,last_seen=function() return game.tick end,player=function() return {character=char} end,busy=function() return nil end,
    condition=function() return true,'ok' end,
    scheduler={order_result=function() return nil end,order=function() return nil end,free=function() return true end,
      resting=function() return nil end,run_order=function() started=started+1 end,loop_orders=function() return nil end}}
  local O=dofile('mod/agent-harness_0.1.0/orders.lua')(api)
  st.orders={[1]={list={{name='boilerfuel',steps={{action='refuel',args={position={x=-30,y=40}}}},interval=600,cooldown=600,max_ticks=3600,failures=0,runs=0,next_tick=0,priority=0,max_walk=20}},hold=0,rr=0,busy_tick=0,drove_tick=0}}
  local o=st.orders[1].list[1]
  for _=1,120 do game.tick=game.tick+1; O.tick() end
  eq(started,0,'50 tiles off, over max_walk 20: it waits'); has(o.far,'lies 50 tiles from you, over max_walk 20')
  char.position={x=-25,y=35}
  for _=1,700 do game.tick=game.tick+1; O.tick() end
  assert(started>=1,'within 20 tiles: it starts')
  -- a sleep with orders: false
  o.max_walk=nil; o.next_tick=0; started=0
  st.sleeps={[1]={no_orders=true,until_tick=game.tick+600}}
  for _=1,300 do game.tick=game.tick+1; O.tick() end
  eq(started,0,'none starts during the sleep')
  st.sleeps={}
  for _=1,120 do game.tick=game.tick+1; O.tick() end
  assert(started>=1,'starts once it ends')
  game=nil
  print('d17_batch14 A2 orders held: ok')
end

-- A7b (Sol): two whole-belt readers on one network whose belts share tiles are named; a collector whose filters the
-- circuit sets shows its chunk signals and what it holds.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2},control_behavior={transport_belt={content_read_mode={entire_belt_hold=2}}}}
  local belts={}
  local function belt(x,net,read)
    local b={type='transport-belt',name='transport-belt',unit_number=x+100,position={x=x+0.5,y=0.5},belt_neighbours={inputs={},outputs={}}}
    b.get_control_behavior=function() return read and {read_contents=true,read_contents_mode=2} or {} end
    b.get_circuit_network=function(w) if net and w==2 then return {network_id=net,signals={}} end end
    belts[#belts+1]=b
    return b
  end
  -- a line of 6 tiles, x=0..5, read at 0 and 4 onto green #7; a separate line read onto #7 too
  for x=0,5 do belt(x,(x==0 or x==4) and 7 or nil,x==0 or x==4) end
  for i=1,5 do belts[i].belt_neighbours.outputs={belts[i+1]}; belts[i+1].belt_neighbours.inputs={belts[i]} end
  belt(20,7,true)
  local col={type='asteroid-collector',position={x=-0.5,y=-13.5},filter_slot_count=1,get_filter=function() return nil end,
    get_control_behavior=function() return {set_filter=true} end,
    get_circuit_network=function(w) if w==2 then return {network_id=9,signals={{signal={type='item',name='metallic-asteroid-chunk'},count=-5}}} end end}
  local surface={find_entities_filtered=function(f) if f.type=='asteroid-collector' then return {col} end return belts end}
  local pl={name='Swift',surface=surface,force='player'}
  local C=dofile('mod/agent-harness_0.1.0/circaudit.lua'){platform=function() return pl end}
  local r=C.read({}, {platform='Swift'})
  eq(r.belt_readers,3)
  eq(#r.double_counts,1,'one pair shares tiles')
  has(r.double_counts[1],'(0.5,0.5) and transport-belt (4.5,0.5) both read the whole belt (6 tiles shared) onto green network #7')
  eq(#r.collectors,1)
  has(r.lines[#r.lines],'holds no filter now; chunk signals on its networks: metallic-asteroid-chunk -5 (green #9) (none positive')
  defines=nil
  print('d17_batch14 A7b circuit audit: ok')
end

-- A8 (Luna: 94 rocket fuel in a passive provider 32 tiles off went unfound behind 256 belts): chests and belts are read
-- apart, so a fuel chest behind a thousand empty belts is found.
do
  defines={inventory={chest=1}}
  local belts,chests={},{}
  for i=1,1000 do belts[i]={valid=true,type='transport-belt',name='transport-belt',unit_number=i,position={x=i%30,y=math.floor(i/30)}} end
  for i=1,40 do chests[i]={valid=true,type='container',name='iron-chest',unit_number=5000+i,position={x=-i,y=0},get_inventory=function() return {get_item_count=function() return 0 end} end} end
  chests[41]={valid=true,type='logistic-container',name='passive-provider-chest',unit_number=9999,position={x=30.5,y=8.5},
    get_inventory=function() return {get_item_count=function() return 94 end} end}
  -- as the engine: every entity of the types asked, belts first here, cut at the limit
  local surface={find_entities_filtered=function(f)
    local want={} for _,t in ipairs(f.type) do want[t]=true end
    local out={}
    for _,list in ipairs({belts,chests}) do for _,e in ipairs(list) do if want[e.type] and #out<f.limit then out[#out+1]=e end end end
    return out end,
    find_logistic_network_by_position=function() return nil end}
  local p={position={x=0,y=0},surface=surface,force={is_chunk_visible=function() return true end}}
  local api={distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end,belt_count=function() return 0 end,
    held=function() return 0 end,screen=function(_,places) return places end}
  local F=dofile('mod/agent-harness_0.1.0/fuelround.lua')(api)
  local action={item='rocket-fuel',index=1,targets={{needed=5}},fuel_round={nearest=true,radius=64,tried={},attempts=0,sources={},taken=0}}
  F.tick(p,action)
  local child=action.fuel_round.source
  assert(child and child.targets[1].entity.name=='passive-provider-chest','the fuel chest is found')
  defines=nil
  print('d17_batch14 A8 refuel sources read apart: ok')
end

-- Opus's deaths at 13:46 and 13:48 (operator): (1) a walk started again on a tour's nav (a spot within the target's
-- reach) keeps the tour's enemy checks; (2) construct stands no nearer a spawner than its reach + the margin.
do
  game={tick=100,forces={player={name='player',players={{}},is_chunk_visible=function() return false end},enemy={name='enemy',players={}}}}
  local enemy=game.forces.enemy
  local spawner={type='unit-spawner',name='biter-spawner',position={x=116.5,y=177.5},force=enemy}
  local surface={name='nauvis',index=1,find_entities_filtered=function(f)
    local a=f.area
    if a and spawner.position.x>=a[1][1] and spawner.position.x<a[2][1] and spawner.position.y>=a[1][2] and spawner.position.y<a[2][2] then return {spawner} end
    return {} end}
  local st={}
  _G.prototypes={entity={['biter-spawner']={result_units={}}}}
  local A=dofile('mod/agent-harness_0.1.0/avoid.lua'){state=function() return st end,charted=function() return true end}
  local p={surface=surface,force=game.forces.player,position={x=235.5,y=-152.3}}
  local nav={position={x=76.7,y=173.1},tolerance=1}
  local mode=A.mode(nil)
  A.start(p,nav,mode)
  assert(nav.avoid_mode==mode,'the mode stays on the nav, for a walk started again on it')
  -- the margin round the spawner: 40 + 4
  local d=A.margin_discs(p,{x=76.7,y=173.1},mode,10)
  eq(#d,1); eq(d[1].r,44)
  assert(((76.7-116.5)^2+(173.1-177.5)^2)^0.5<d[1].r,'where Opus stood is inside it')
  game=nil; prototypes=nil
  print('d17_batch14 Opus 13:46/13:48 walks keep the enemy margin: ok')
end

-- B1 (Sol for viewer Foobator): a viewer's @mention stays owed through reads until a say names them; one reminder at 10 min.
do
  game={tick=0}
  local st,woke={},{}
  local O=dofile('mod/agent-harness_0.1.0/owed.lua'){state=function() return st end,deliver=function(index,t) woke[#woke+1]={index=index,t=t} end}
  O.add(3,{key='m41',seq=41,tick=0,from='viewer Foobator',text='@sol what is Swift carrying?',viewer=true,source='YouTube'})
  game.tick=600*60
  has(O.line(3),'1 unanswered (oldest 10m00s ago: viewer Foobator (YouTube) #41')
  O.tick(); O.tick()
  eq(#woke,1,'one reminder'); eq(woke[1].t.wake,true); has(woke[1].t.text,'viewer Foobator asked you 10m00s ago')
  eq(O.said(3,'Swift carries iron for Aquilo'),0,'a say not naming them answers nothing')
  eq(O.said(3,'@Foobator Swift carries iron for Aquilo'),1)
  eq(O.line(3),nil)
  O.add(3,{key='t9',seq=9,tick=game.tick,from='luna',text='can you send 50?',tell=true})
  eq(O.told(3,{'luna'}),1,'a tell to the asker answers it')
  O.add(3,{key='m50',seq=50,tick=game.tick,from='astra',text='@sol ready?'})
  eq(O.ack(3,50),1)
  game=nil
  print('d17_batch14 B1 unanswered mentions: ok')
end

-- B2 (Sol): stacks on the ground in chunks our force sees now count, by 32-tile cell.
do
  local S=dofile('mod/agent-harness_0.1.0/stores.lua'){agents=function() return {} end}
  local function stack(name,n,x,y) return {stack={valid_for_read=true,name=name,count=n},position={x=x,y=y}} end
  local ents={stack('iron-gear-wheel',1,-27,118),stack('iron-gear-wheel',1,-26,119),stack('iron-plate',5,-27,118),stack('iron-gear-wheel',1,500,500)}
  local surface={find_entities_filtered=function() return ents end}
  local force={is_chunk_visible=function(_,c) return c.x<10 end}
  local g=S.on_ground(force,surface,'iron-gear-wheel')
  eq(g.count,2,'the unseen chunk left out'); eq(#g.cells,1); eq(g.cells[1].stacks,2)
  print('d17_batch14 B2 items on the ground: ok')
end
