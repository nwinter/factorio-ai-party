-- Run from repository root: lua tests/d17_batch23.lua
-- d17 batch23: the agents' 19:50 poll.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Sol): platform_defense cover by asteroid size, from each turret's priority list and minimum range.
do
  defines={inventory={turret_ammo=1}}
  local function turret(name,x,y,range,min,only)
    local list={}
    for _,n in ipairs(only or {}) do list[#list+1]={name=n} end
    return {valid=true,type='ammo-turret',name=name,position={x=x,y=y},bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}},
      get_inventory=function() return {get_contents=function() return {{name='rocket',count=20}} end} end,
      prototype={attack_parameters={range=range,min_range=min}},ignore_unprioritised_targets=only~=nil,
      get_priority_target=function(i) return list[i] end}
  end
  local rocket=turret('rocket-turret',0,-20,36,15,{'big-oxide-asteroid','big-carbonic-asteroid','big-metallic-asteroid'})
  local gun=turret('gun-turret',20,0,18,0,nil)
  local tiles={}
  for x=0,3 do tiles[#tiles+1]={position={x=x,y=0}} end
  local s={find_entities_filtered=function(f) if f.type=='asteroid-collector' or f.type=='inserter' then return {} end return {rocket,gun} end,
    find_tiles_filtered=function() return tiles end}
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Swiftlet',surface=s,force='f'} end}
  local r=D.read({},{platform='Swiftlet'})
  eq(r.turrets[1].engages,'only big-carbonic-asteroid, big-metallic-asteroid, big-oxide-asteroid (ignores the rest)')
  eq(r.turrets[1].min_range,15); eq(r.turrets[2].engages,'every asteroid')
  local north
  for _,row in ipairs(r.sides) do if row.side=='north' then north=row end end
  -- tiles 0 and 1 are past the gun's 18: only the rocket turret reaches them, and it engages big ones only
  eq(north.edge_tiles,4); eq(north.by_size.small.uncovered,2); eq(north.by_size.medium.uncovered,2); eq(north.by_size.huge.uncovered,2)
  eq(north.by_size.big.uncovered,0)
  local line
  for _,l in ipairs(r.lines) do if l:find('^north side') then line=l end end
  has(line,'north side: 4 edge tiles, 2 where a size is not covered; small 2 uncovered ((0,0)-(1,0) 2 tiles); medium 2 uncovered')
  has(line,'big all covered')
  local by
  for _,l in ipairs(r.lines) do if l:find('^by their priority lists') then by=l end end
  has(by,'rocket-turret (0,-20) engages only big-carbonic-asteroid, big-metallic-asteroid, big-oxide-asteroid (ignores the rest), not within 15 tiles')
  -- inside the minimum range the rocket turret reaches nothing
  rocket.position={x=0,y=-5}
  r=D.read({},{platform='Swiftlet'})
  for _,row in ipairs(r.sides) do if row.side=='north' then north=row end end
  eq(north.by_size.big.uncovered,2)
  defines=nil
end
print('d17_batch23 A1 platform_defense by asteroid size: ok')

-- A2 (Astra, Kestrel II): the belt back into the hub read stranded while the hub fed the turrets; a disabled old
-- loader was named beside the bulk inserter feeding the line; a long-handed bridge's belt end read stranded. Each
-- belt is read once; turrets on one line or loop share it.
do
  defines={inventory={turret_ammo=1,hub_main=2,chest=3},entity_status={disabled_by_control_behavior=99}}
  prototypes={item={['firearm-magazine']={type='ammo',ammo_category='bullet'},['iron-plate']={type='item'}}}
  local n=0
  local function contents(t) local out={} for name,c in pairs(t) do out[#out+1]={name=name,count=c} end return out end
  local function inv(t) return {get_contents=function() return contents(t) end} end
  local reads=0
  local function belt(x,y,items)
    n=n+1
    local b={valid=true,unit_number=n,type='transport-belt',name='fast-transport-belt',position={x=x,y=y},nb={inputs={},outputs={}}}
    setmetatable(b,{__index=function(t,k) if k=='belt_neighbours' then reads=reads+1 return t.nb end end})
    b.get_max_transport_line_index=function() return 2 end
    b.get_transport_line=function(i) local c=i==1 and contents(items or {}) or {} return setmetatable({get_contents=function() return c end},{__len=function() local s=0 for _,r in ipairs(c) do s=s+r.count end return s end}) end
    return b
  end
  local function link(a,b) a.nb.outputs[#a.nb.outputs+1]=b; b.nb.inputs[#b.nb.inputs+1]=a end
  local function ins(x,y,from,to,name) n=n+1; return {valid=true,unit_number=n,type='inserter',name=name or 'fast-inserter',position={x=x,y=y},pickup_target=from,drop_target=to} end
  local function turret(x,y)
    n=n+1
    local t={valid=true,unit_number=n,type='ammo-turret',name='gun-turret',position={x=x,y=y},prototype={attack_parameters={ammo_categories={'bullet'}}}}
    t.get_inventory=function() return inv({}) end
    return t
  end
  local hub={valid=true,unit_number=9000,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  hub.get_inventory=function() return inv({['firearm-magazine']=100}) end
  local function run(turrets,belts,inserters)
    local surface={find_entities_filtered=function(f)
      local t=type(f.type)=='table' and f.type[1] or f.type
      if t=='inserter' then return inserters end
      if t=='ammo-turret' then return turrets end
      if t=='transport-belt' then return belts end
      return {}
    end}
    return dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}.trace({surface=surface,force='player',hub=hub})
  end
  -- the line: bulk loader from the hub onto L1 -> L2 ... L6, L6 -> bulk inserter back into the hub; 2 magazines on
  -- each belt. Turret A takes from L2, turret B from L4. The old loader onto L1 is switched off.
  local L={}
  for i=1,6 do L[i]=belt(5.5,i,{['firearm-magazine']=2}) end
  for i=1,5 do link(L[i],L[i+1]) end
  local A,B=turret(8,2),turret(8,4)
  local loader=ins(4.5,1,hub,L[1],'bulk-inserter')
  local old=ins(4.5,0,hub,L[1])
  old.get_control_behavior=function() return {disabled=true} end
  local back=ins(4.5,6,L[6],hub,'bulk-inserter')
  local fa,fb=ins(6.5,2,L[2],A),ins(6.5,4,L[4],B)
  local belts={L[1],L[2],L[3],L[4],L[5],L[6]}
  local tr=run({B,A},belts,{loader,old,back,fa,fb})
  local ra,rb
  for _,row in ipairs(tr.rows) do if row.entity==A then ra=row else rb=row end end
  eq(ra.reaches,100+4,'A: the hub and L1-L2'); eq(rb.reaches,100+8,'B: the hub and L1-L4')
  eq(ra.belts,2); eq(rb.belts,4)
  eq(#ra.stops,0); eq(#rb.stops,0)
  has(rb.ways[1],'put on them by bulk-inserter (4.5,1) from space-platform-hub (0,0)')
  assert(not rb.ways[1]:find('(4.5,0)',1,true),'the switched-off old loader is not named while the bulk loader feeds the line: '..rb.ways[1])
  eq(tr.stranded,0,'L5 and L6 run back into the hub'); eq(tr.via_hub,4)
  local lines=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}.lines(tr,false,'Kestrel II',false)
  has(lines[1],'belts back into the hub 4'); has(lines[1],'stranded: 0')
  eq(reads,6,'each belt read once')
  -- (operator 23:47) a platform over SYNC_BELTS belts is read in the background, READ_PER_TICK belts a tick, the trace
  -- computed in the tick after the last: the same result
  do
    local st={}
    game={tick=100}
    local F=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){state=function() return st end}
    F.SYNC_BELTS,F.READ_PER_TICK=2,4
    local surface={index=7,find_entities_filtered=function(f)
      local t=type(f.type)=='table' and f.type[1] or f.type
      if t=='inserter' then return {loader,old,back,fa,fb} end
      if t=='ammo-turret' then return {B,A} end
      if t=='transport-belt' then return belts end
      return {}
    end,count_entities_filtered=function() return #belts end}
    local pl={index=3,name='Kestrel II',valid=true,surface=surface,force='player',hub=hub}
    reads=0
    local tr0,why=F.get(pl)
    eq(tr0,nil); has(why,'the ammunition trace of Kestrel II (6 belts) is read in the background over about 3 ticks (4 belts a tick, the 20 ms rule)')
    eq(reads,0,'nothing read in the call')
    for i=1,3 do game.tick=game.tick+1; F.step() end
    eq(reads,6,'each belt read once, over two ticks')
    local tr2=F.get(pl)
    eq(tr2.stranded,0); eq(tr2.via_hub,4)
    local r2a
    for _,row in ipairs(tr2.rows) do if row.entity==A then r2a=row end end
    eq(r2a.reaches,104)
    has(tr2.as_of,'read over 3 ticks in the background (6 belts, 4 a tick), 0s ago')
    -- fresh for FRESH ticks; then a new read begins and the last is given meanwhile
    game.tick=game.tick+F.FRESH
    local tr3=F.get(pl); eq(tr3,tr2); assert(st.ammofeed.jobs[3],'a new read began')
    game=nil
  end
  -- the bulk loader switched off too: nothing more comes, and both loaders are named as switched off
  loader.get_control_behavior=function() return {disabled=true} end
  tr=run({A},belts,{loader,old,back,fa})
  has(tr.rows[1].gated[1],'the inserters putting items on the belts upstream of')
  has(tr.rows[1].gated[1],'are gated closed now (')
  has(tr.rows[1].ways[1],'bulk-inserter (4.5,1) from space-platform-hub (0,0) (holds 100 of its ammo) (gated closed now: its circuit or logistic condition holds it off)')
  loader.get_control_behavior=nil
  -- a long-handed bridge: M1 -> M2 (picked) -> M3 (the belt's end, 8 on it); the bridge drops onto N1 -> N2 -> the turret
  local M1,M2,M3=belt(25.5,57.5,{['firearm-magazine']=1}),belt(25.5,58.5,{['firearm-magazine']=8}),belt(25.5,59.5,{['firearm-magazine']=8})
  link(M1,M2); link(M2,M3)
  local N1,N2=belt(25.5,62.5),belt(25.5,63.5)
  link(N1,N2)
  local C=turret(28,64)
  local bridge=ins(25.5,60.5,M2,N1,'long-handed-inserter')
  local fc=ins(26.5,63.5,N2,C)
  local mload=ins(24.5,57.5,hub,M1)
  tr=run({C},{M1,M2,M3,N1,N2},{bridge,fc,mload})
  eq(tr.rows[1].reaches,100+9,'the hub, M1 and M2 through the bridge'); eq(#tr.rows[1].stops,0)
  has(tr.rows[1].ways[1],'through long-handed-inserter (25.5,60.5) from fast-transport-belt (25.5,58.5)')
  eq(tr.stranded,0,'the belt end is not stranded'); eq(tr.at_end,8)
  has(tr.at_end_rows[1],'8 on 1 belt ending at (25.5,59.5), past fast-transport-belt (25.5,58.5)')
  lines=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}.lines(tr,false,'Kestrel II',false)
  local endline
  for _,l in ipairs(lines) do if l:find('^at belt ends') then endline=l end end
  has(endline,'at belt ends past a pickup on a turret\'s way (not counted as stranded; they move on when the belt beyond is joined): 8')
  -- a loop R1 -> R2 -> R3 -> R1 with two turrets: each reaches the whole loop
  local R={belt(40,0,{['firearm-magazine']=3}),belt(41,0,{['firearm-magazine']=3}),belt(42,0,{['firearm-magazine']=3})}
  link(R[1],R[2]); link(R[2],R[3]); link(R[3],R[1])
  local D,E=turret(40,2),turret(42,2)
  tr=run({D,E},R,{ins(40,1,R[1],D),ins(42,1,R[3],E),ins(41,-1,hub,R[2])})
  eq(tr.rows[1].reaches,100+9); eq(tr.rows[2].reaches,100+9); eq(tr.rows[1].belts,3)
  defines,prototypes=nil,nil
end
print('d17_batch23 A2 ammunition feed: hub return, switched-off loaders, belt ends, one read per belt: ok')

-- A3 (Sol: Swift dropped 250 tungsten plates at Nauvis and left within the second; the stop and its pod's receipt were
-- never recorded): a 0 s stop between a leg to X and a leg from X, the pod followed after it, and a landed receipt per
-- pod kept apart from the stops.
do
  defines={space_platform_state={on_the_path=3,waiting_at_station=6},inventory={hub_main=1,hub_trash=2,cargo_unit=4}}
  prototypes={item={['tungsten-plate']={get_spoil_ticks=function() return 0 end}},space_location={nauvis={},vulcanus={},fulgora={}}}
  local function inv(t) return {get_contents=function() local out={} for n,c in pairs(t) do out[#out+1]={name=n,count=c,quality='normal'} end return out end} end
  local main={['tungsten-plate']=250}
  local hub={valid=true,get_inventory=function(id) return id==1 and inv(main) or inv({}) end,get_logistic_sections=function() return {sections_count=0} end}
  local on_platform={}
  local plsurf={name='platform-2',find_entities_filtered=function(f) if f.type=='cargo-pod' then return on_platform end return {} end}
  local swift={valid=true,index=2,name='Swift',hub=hub,surface=plsurf,state=3,space_connection={from={name='vulcanus'},to={name='nauvis'},length=10000},distance=0.5,
    speed=1,schedule={records={{station='nauvis'},{station='fulgora'}},current=1},last_visited_space_location={name='vulcanus'}}
  local force={name='player',platforms={swift}}
  swift.force=force
  local nauvis_s={name='nauvis',find_entities_filtered=function() return {} end}
  game={tick=0,forces={player=force},planets={nauvis={surface=nauvis_s}},surfaces={nauvis=nauvis_s}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  local function second() game.tick=game.tick+60; F.tick(game.tick); F.pod_tick(game.tick) end
  second(); second()
  -- within the next second: at Nauvis, the pod sent, gone again toward Fulgora
  swift.space_connection={from={name='nauvis'},to={name='fulgora'},length=10000}; swift.distance=0.01; swift.schedule.current=2
  swift.last_visited_space_location={name='nauvis'}
  local pad={name='cargo-landing-pad',position={x=52,y=54},surface=nauvis_s,valid=true}
  local pod={valid=true,unit_number=5751033,surface=plsurf,position={x=0,y=-2},cargo_pod_origin=hub,cargo_pod_destination={station=pad}}
  pod.get_inventory=function() return inv({['tungsten-plate']=250}) end
  on_platform={pod}; main={}
  second()
  local fr=F.read(swift)
  eq(fr[1].kind,'leg'); eq(fr[1].from,'nauvis')
  has(fr[2].line,'stop at nauvis (0s, 0s ago; arrived and left between two looks a second apart)')
  has(fr[2].line,'in flight 1 (tungsten-plate*250): #5751033 to cargo-landing-pad leaving the platform')
  -- it lands in the pad
  on_platform={}; pod.surface=nauvis_s; second(); pod.valid=false; second()
  fr=F.read(swift)
  has(fr[2].line,'received by landing pads 1 (tungsten-plate*250) at cargo-landing-pad (52,54) on nauvis')
  local rc=F.receipts(swift)
  has(rc[1],'tungsten-plate*250 received by cargo-landing-pad (52,54) on nauvis, 0s ago (pod #5751033, left the hub 2s ago, from the stop at nauvis)')
  -- a turnaround in flight (a leg to X, then a leg from X without visiting it) is no stop
  local n=#st.freight[2].segs
  swift.space_connection={from={name='fulgora'},to={name='nauvis'},length=10000}; swift.schedule.current=1
  second()
  eq(st.freight[2].segs[#st.freight[2].segs].kind,'leg'); eq(#st.freight[2].segs,n+1)
  swift.space_connection={from={name='nauvis'},to={name='fulgora'},length=10000}; swift.schedule.current=2
  second()
  eq(#st.freight[2].segs,n+2,'fulgora was not visited: no stop')
  -- the stop scrolls off (KEEP segments); the receipt stays
  for i=1,10 do
    swift.space_connection={from={name=i%2==0 and 'nauvis' or 'fulgora'},to={name=i%2==0 and 'fulgora' or 'nauvis'},length=10000}
    swift.schedule.current=i%2==0 and 2 or 1; second()
  end
  for _,s in ipairs(st.freight[2].segs) do assert(not s.zero,'scrolled off') end
  has(F.receipts(swift)[1],'tungsten-plate*250 received by cargo-landing-pad (52,54) on nauvis')
  defines,prototypes,game=nil,nil,nil
end
print('d17_batch23 A3 freight: 0 s stops and landed receipts: ok')

-- A4 (Opus: robot_losses cancel failed with "LuaEntity API call when LuaEntity was invalid" at (-224,-30)): a job
-- whose target is gone between the read and the cancel is skipped and named.
do
  game={tick=1000}
  defines={robot_order_type={construct=1,deconstruct=2}}
  local st={}
  local R=dofile('mod/agent-harness_0.1.0/robotloss.lua'){state=function() return st end,integer=function(v,d) return v or d end,position=function(v) return v end}
  local worm={valid=true,name='medium-worm-turret',type='turret',position={x=-230,y=-30},force={name='enemy'}}
  local force={name='player'}
  -- an entity whose every read but valid raises once it is gone, as the game's does
  local function entity(t)
    local alive=true
    return setmetatable({},{__index=function(_,k)
      if k=='valid' then return alive end
      if k=='kill' then return function() alive=false end end
      if not alive then error('LuaEntity API call when LuaEntity was invalid.') end
      return t[k]
    end})
  end
  local built=entity({type='entity-ghost',name='entity-ghost',ghost_name='gun-turret',position={x=-224.5,y=-30.5},unit_number=21})
  local other=entity({type='entity-ghost',name='entity-ghost',ghost_name='wall',position={x=-226.5,y=-30.5},unit_number=22})
  rawset(other,'destroy',nil)
  local destroyed=false
  local o_meta=getmetatable(other).__index
  getmetatable(other).__index=function(t,k) if k=='destroy' then return function() destroyed=true; other.kill() end end return o_meta(t,k) end
  local function robot(target) return {valid=true,type='construction-robot',name='construction-robot',force=force,surface={name='nauvis'},position={x=-228,y=-30},
    robot_order_queue={{type=1,target=target}}} end
  R.note({entity=robot(built),cause=worm,tick=1000}); R.note({entity=robot(other),cause=worm,tick=1000})
  game.tick=1300
  local r=R.read({force=force,surface={name='nauvis'}},{})
  has(r.lines[1],'2 of those jobs stand')
  built.kill()  -- the turret ghost is built between the read and the cancel
  r=R.read({force=force,surface={name='nauvis'}},{})
  has(r.lines[1],'1 of those jobs stand')
  r=R.read({force=force,surface={name='nauvis'}},{cancel=true,near={x=-224,y=-30}})
  eq(destroyed,true); eq(#r.cancelled,1); eq(#r.ended,1)
  has(r.ended[1],'construct gun-turret ghost (-224.5,-30.5): ended before the cancel (built, removed or done), skipped')
  has(r.cancel_line,'1 job cancelled of the robots medium-worm-turret (-230,-30) killed (1 removed); 1 ended before the cancel, skipped')
  -- (d19 batch45, batch40 C2) the filter and what is left
  assert(r.cancel_filter:find('the group of medium-worm-turret (-230,-30)',1,true),r.cancel_filter); assert(r.left,'left')
  defines,game=nil,nil
end
print('d17_batch23 A4 robot_losses cancel after a job ended: ok')

-- B2 (Sonnet: 4000 copper cable read as ready twice; it sat in requester chests): stock splits a stock by what can be
-- taken: provider and storage chests, requester and buffer chests, plain chests, machines.
do
  game={tick=0}
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){spoil={hatch=function() return nil end,secs=function(t) return t..'t' end}}
  local function lc(mode,x,n) return {entity={valid=true,type='logistic-container',name=mode..'-chest',prototype={logistic_mode=mode}},name=mode..'-chest',position={x=x,y=0},count=n,distance=x} end
  local places={lc('requester',3,4000),lc('passive-provider',5,100),lc('storage',6,50),lc('buffer',7,20),
    {entity={valid=true,type='container',name='wooden-chest'},name='wooden-chest',position={x=8,y=0},count=7,distance=8}}
  local t=S.split(places)
  eq(t.free,150); eq(t.requested,4020); eq(t.chest,7); eq(t.machine,0)
  eq(t.text,'provider and storage chests 150 (robots can take it), requester and buffer chests 4020 (held for their requests), plain chests 7')
  local line=S.line({item='copper-cable',total=4177,places=places,groups={{name='requester-chest',count=4000,entities=1}}})
  has(line,'4177 copper-cable held by our factory (4000 in 1 requester-chest; provider and storage chests 150 (robots can take it), requester and buffer chests 4020 (held for their requests), plain chests 7)')
  game=nil
end
print('d17_batch23 B2 stock by holder: ok')

-- B3 (Gemini; Sonnet): per silo, rocket parts made and the rate; per request what the network's provider and storage
-- chests can give now and whether an automatic launch goes under min_payload or full; the next automatic launch.
do
  game={tick=36000}
  defines={inventory={hub_main=1}}
  prototypes={item={['low-density-structure']={weight=10000,stack_size=50},['processing-unit']={weight=3333,stack_size=100}},utility_constants={rocket_lift_weight=1000000}}
  local st={}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return st end}
  local silo={unit_number=77,products_finished=100}
  local r=S.sample_made(silo)
  eq(r.made,100); eq(r.per_min,nil)
  game.tick=game.tick+300; silo.products_finished=105
  eq(#st.silo_made[77],1,'not sampled again within 10 s'); eq(S.sample_made(silo).per_min,60)  -- 5 parts in 5 s
  game.tick=game.tick+3300; silo.products_finished=130
  r=S.sample_made(silo); eq(r.made,130); eq(r.per_min,30); eq(r.over_s,60); eq(#st.silo_made[77],2)
  -- the requests a platform above makes of this planet
  local net={network_id=5}
  net.get_item_count=function(name,member) local t={['low-density-structure']={providers=80,storage=40},['processing-unit']={providers=10,storage=0}} local x=t[name] or {providers=0,storage=0}
    if member then return x[member] end return x.providers+x.storage end
  local main={count_empty_stacks=function() return 20 end}
  local hub={valid=true,get_inventory=function() return main end,get_item_count=function() return 0 end,get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,
    filters={{value={name='low-density-structure'},min=100,import_from='nauvis',minimum_delivery_count=100},{value={name='processing-unit'},min=50,import_from='nauvis'}}} end} end}
  local force={platforms={{valid=true,name='Swiftlet',space_location={name='nauvis'},hub=hub}},logistic_networks={nauvis={net}}}
  local e={surface={name='nauvis',planet={name='nauvis'}},position={x=0,y=0}}
  local rows=S.request_rows(e,force,net)
  eq(#rows,2)
  eq(rows[1].item,'low-density-structure'); eq(rows[1].providers,80); eq(rows[1].storage,40); eq(rows[1].network_holds,120); eq(rows[1].next_launch,'min_payload 100'); eq(rows[1].flag,'matched')
  has(rows[1].line,'the silo\'s network can give 120 now (provider chests 80, storage chests 40, less what robots have reserved)')
  eq(rows[2].next_launch,'full 300'); eq(rows[2].flag,'below_min_payload')
  -- (d17 batch29 C3) another network holds the rest: the chest robots would take it from there, and load_silo args
  local far={network_id=9,cells={{owner={valid=true,position={x=200,y=40}}}},get_item_count=function(name) return name=='processing-unit' and 400 or 0 end}
  local chest={valid=true,name='storage-chest',position={x=210.5,y=44.5},get_item_count=function() return 400 end}
  far.select_pickup_point=function(a) eq(a.name,'processing-unit'); return {owner=chest} end
  net.select_pickup_point=function() return {owner={valid=true,name='passive-provider-chest',position={x=3.5,y=-2.5},get_item_count=function() return 10 end}} end
  force.logistic_networks.nauvis={net,far}
  e.use_transitional_requests=true
  rows=S.request_rows(e,force,net)
  eq(rows[2].flag,'split_networks')
  has(rows[2].line,'other networks on nauvis: network 9 (near 200,40) holds 400, most at hand in storage-chest (210.5,44.5) holding 400')
  has(rows[2].line,'by hand: load_silo {items {processing-unit: 50}, from those chests, walk, launch, platform Swiftlet, auto_requests "pause"}')
  local ls=rows[2].load_silo
  eq(ls.items['processing-unit'],50); eq(#ls.from,2); eq(ls.from[1].x,3.5); eq(ls.from[2].x,210.5); eq(ls.walk,true); eq(ls.launch,true)
  eq(ls.platform,'Swiftlet'); eq(ls.auto_requests,'pause'); eq(ls.position.x,0)
  eq(rows[1].load_silo,nil)
  defines,prototypes,game=nil,nil,nil
end
print('d17_batch23 B3 silo parts rate and requests: ok')

-- B4 (Astra: water's pipe needed one 374-tile pocket, not 41 tiles nor all 1935 ghosts): platform_plan ready names the
-- pocket of empty space under a ghost's footprint (4-neighbour, bounded by foundation), its tiles, those without a tile
-- ghost and the place_ghosts entries that stamp them.
do
  defines={inventory={hub_main=1}}
  -- foundation everywhere within 30 tiles, but a 6x4 hole at x 0..5, y 0..3; open space past 30
  local function empty(x,y) return math.abs(x)>30 or math.abs(y)>30 or (x>=0 and x<=5 and y>=0 and y<=3) end
  local ghosts={} -- tile ghosts on 3 tiles of the hole
  for _,c in ipairs({{0,0},{1,0},{2,1}}) do ghosts[#ghosts+1]={valid=true,type='tile-ghost',ghost_name='space-platform-foundation',position={x=c[1]+0.5,y=c[2]+0.5}} end
  local pipe={valid=true,type='entity-ghost',ghost_name='pipe',ghost_type='pipe',unit_number=11,position={x=2.5,y=1.5},bounding_box={left_top={x=2.2,y=1.2},right_bottom={x=2.8,y=1.8}},ghost_prototype={}}
  local far={valid=true,type='entity-ghost',ghost_name='pipe',ghost_type='pipe',unit_number=12,position={x=40.5,y=0.5},bounding_box={left_top={x=40.2,y=0.2},right_bottom={x=40.8,y=0.8}},ghost_prototype={}}
  local s={get_tile=function(x,y) return {name=empty(x,y) and 'empty-space' or 'space-platform-foundation'} end}
  s.find_entities_filtered=function(f)
    local out={}
    if f.type=='entity-ghost' then return {pipe,far} end
    if f.type=='tile-ghost' then
      for _,t in ipairs(ghosts) do
        local ok=true
        if f.area then ok=t.position.x>=f.area[1][1] and t.position.x<f.area[2][1] and t.position.y>=f.area[1][2] and t.position.y<f.area[2][2] end
        if f.position then ok=math.abs(t.position.x-f.position[1])<0.2 and math.abs(t.position.y-f.position[2])<0.2 end
        if ok then out[#out+1]=t end
      end
    end
    return out
  end
  local pl={name='Kestrel II',surface=s,force='player',hub={valid=true,get_inventory=function() return {get_item_count=function() return 0 end} end}}
  local PP=dofile('mod/agent-harness_0.1.0/platplan.lua'){platform=function() return pl end}
  local r=PP.ready({},pl,{area={left_top={x=-50,y=-50},right_bottom={x=50,y=50}}})
  eq(#r.pockets,2)
  local hole=r.pockets[1]
  eq(hole.tiles,24); eq(hole.without_ghost,21); eq(hole.open,nil); eq(hole.under[1],'pipe (2.5,1.5)')
  has(hole.line,'pocket 1: 24 empty tiles enclosed by foundation in (0,0)-(6,4) under pipe (2.5,1.5); 21 of them hold no tile ghost')
  eq(#r.pocket_entries,21); eq(r.pocket_entries[1].name,'space-platform-foundation')
  eq(r.pockets[2].open,true); has(r.pockets[2].line,'runs past 1024 tiles (open space beside the hull, or a pocket larger than that)')
  defines=nil
end
print('d17_batch23 B4 platform_plan ready pockets: ok')

-- C4 (Muse: item + position + forward tried in turn, each refused tersely): each argument refusal names what was wrong
-- and the shapes trace takes; fh help trace gives a call a mode (M.EXAMPLES.trace, run through check_args by runtime_test).
do
  package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
  prototypes={item={['iron-plate']={}}}
  local supply=require('supply'){status_name=function(e) return e.status end,position=function(v) return v end,integer=function(v,d) return v or d end}
  local T=require('trace'){supply=supply,position=function(v) return v end,integer=function(v,d) return v or d end}
  local p={surface={},force={}}
  fails(function() T.trace(p,{item='iron-plate',position={x=1,y=2},forward=true}) end,
    'item with position goes with upstream: true (that one ingredient back from the machine); item alone traces the item\'s routes; trace takes {position}')
  fails(function() T.trace(p,{}) end,'position or item is missing; trace takes {position} (a machine or lab, back to what it lacks; all: true for every ingredient) | {position, forward: true}')
  fails(function() T.trace(p,{item='iron-plate',forward=true}) end,'item traces the item\'s routes alone: forward and all go with position; trace takes')
  fails(function() T.trace(p,{position={x=1,y=2},forward=true,all=true}) end,'all goes with a backward trace (no forward); trace takes')
  fails(function() T.trace(p,{position={x=1,y=2},upstream=true,forward=true}) end,'upstream and forward go one way each: give one; trace takes')
  fails(function() T.trace(p,{item='no-such'}) end,'item must be an item name (chemical-science-pack, iron-gear-wheel, ...); trace takes')
  has(T.SHAPES,'{item} (every route of an item; near: {x,y}, radius, surface)')
  prototypes=nil
end
print('d17_batch23 C4 trace refusals: ok')
