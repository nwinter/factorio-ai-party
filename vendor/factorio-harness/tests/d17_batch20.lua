-- d17 batch20 (operator 15:25: the agents' 15:20 poll). Run from the harness root: lua tests/d17_batch20.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A4 (Sol): a hub's custom minimum payloads outlive requests {clear_all} and {clear}; min_payload runs in the remote lane.
do
  game={tick=0}
  defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
  prototypes={item={['plastic-bar']={},concrete={},coal={}},space_location={nauvis={},vulcanus={}},quality={normal={}}}
  local slots={}
  local sec={index=1,is_manual=true,group='',active=true,filters_count=0}
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) slots[i]=f; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; for i,f in ipairs(v) do slots[i]=f end; recount() else rawset(t,k,v) end end})
  local secs=setmetatable({get_section=function(i) return i==1 and sec or nil end,add_section=function() return sec end},{__index=function(_,k) if k=='sections_count' then return 1 end end})
  local main={get_item_count=function() return 0 end,get_contents=function() return {} end}
  local platform={valid=true,name='Swiftlet',index=1,space_connection={},
    hub={valid=true,unit_number=77,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end}}
  local p={index=1,force={platforms={platform}}}
  local st={}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,freight={where=function() return {} end}}
  space.requests(p,{platform='Swiftlet',set={{item='plastic-bar',min=1500,from='vulcanus',min_payload=1500},{item='concrete',min=80,from='nauvis',min_payload=80}}})
  eq(slots[1].minimum_delivery_count,1500); eq(slots[2].minimum_delivery_count,80)
  -- clear_all and set in one call: each item's min payload comes back
  local r=space.requests(p,{platform='Swiftlet',clear_all=true,set={{item='plastic-bar',min=500,from='vulcanus'}}})
  eq(slots[1].minimum_delivery_count,1500); has(r.stored[1],'(min payload 1500 kept from the request cleared before)')
  -- a later call too
  r=space.requests(p,{platform='Swiftlet',set={{item='concrete',min=40,from='nauvis'}}})
  eq(slots[2].minimum_delivery_count,80); has(r.stored[1],'concrete 40..inf from nauvis min payload 80 (min payload 80 kept from the request cleared before)')
  -- clear by name keeps it too; min_payload false forgets it
  space.requests(p,{platform='Swiftlet',clear={'concrete'}})
  r=space.requests(p,{platform='Swiftlet',set={{item='concrete',min=40,from='nauvis',min_payload=false}}})
  eq(slots[2].minimum_delivery_count,nil)
  space.requests(p,{platform='Swiftlet',clear={'concrete'}})
  r=space.requests(p,{platform='Swiftlet',set={{item='concrete',min=40,from='nauvis'}}})
  eq(slots[2].minimum_delivery_count,nil)
  -- the remote lane takes min_payload
  local remote
  dofile('mod/agent-harness_0.1.0/queue_lanes.lua'){scheduler={handlers={},schema={queue_submit={},queue_status={returns=''}}},base={},
    factory=function(r_) remote=r_; return {handlers={}} end,is_read=function() return false end}
  remote.check_step('min_payload',{platforms='Swiftlet',set={['plastic-bar']=1500}})
  fails(function() remote.check_step('craft',{recipe='x'}) end,'not supported in the remote lane')
end
print('d17_batch20 A4 min payload: ok')

-- A5 (Gemini): conflicts names the footprint tiles the entity cannot stand on and the tile item that makes them buildable.
do
  local fixes
  local C=dofile('mod/agent-harness_0.1.0/conflicts.lua'){compass={},tile_fixes=function() return fixes end,tile_rules=function() return nil end}
  local surface={find_entities_filtered=function() return {} end}
  local p={surface=surface,force={name='player'}}
  local proto={name='steam-turbine',collision_mask={layers={object=true}}}
  local target={proto=proto,pos={x=-54.5,y=112.5},dir=0,box={left_top={x=-56,y=110},right_bottom={x=-53,y=115}}}
  fixes={}
  for i=1,12 do fixes[i]={tile='oil-ocean-shallow',locked='foundation (not researched)'} end
  for i=13,15 do fixes[i]={tile='oil-ocean-deep',locked='foundation (not researched)'} end
  local r=C.read(p,{},target)
  eq(r.line,'nothing stands in its way; steam-turbine cannot stand on 15 tiles of its footprint: oil-ocean-shallow 12 (foundation laid on it makes it buildable; foundation is not researched), oil-ocean-deep 3 (foundation laid on it makes it buildable; foundation is not researched)')
  eq(r.tiles[1].count,12); eq(r.tiles[1].needs,'foundation'); eq(r.tiles[1].researched,false)
  fixes={{tile='water',item='landfill'},{tile='out-of-map'}}
  r=C.read(p,{},target)
  eq(r.tiles_line,'steam-turbine cannot stand on 2 tiles of its footprint: water 1 (landfill laid on it makes it buildable), out-of-map 1 (no tile item makes it buildable)')
  eq(r.tiles[1].researched,true)
  fixes=nil
  r=C.read(p,{},target)
  eq(r.line,'nothing stands in its way'); eq(r.tiles,nil)
end
print('d17_batch20 A5 conflicts tiles: ok')

-- B3 (Sonnet): belt_gaps {line}: the whole line through one belt, its gaps with what stands on each missing tile.
do
  local L=dofile('mod/agent-harness_0.1.0/linecut.lua'){state=function() return {} end}
  local force={name='player',is_chunk_visible=function() return true end}
  local grid={}
  local function belt(x,y,d) local e={valid=true,name='transport-belt',type='transport-belt',position={x=x+0.5,y=y+0.5},direction=d or 4,force=force,unit_number=1000+x*7+y}; grid[x..','..y]=e; return e end
  for x=0,40 do if x~=10 and x~=11 and x~=20 then belt(x,0) end end
  local pole={valid=true,name='medium-electric-pole',type='electric-pole',position={x=20.5,y=0.5},force=force}
  for _,e in pairs(grid) do
    local x,y=math.floor(e.position.x),math.floor(e.position.y)
    e.belt_neighbours=setmetatable({},{__index=function(_,k)
      local o=k=='outputs' and grid[(x+1)..','..y] or k=='inputs' and grid[(x-1)..','..y] or nil
      return {o}
    end})
  end
  local surface={find_entities_filtered=function(f)
    local x,y=math.floor(f.area[1][1]),math.floor(f.area[1][2])
    local out={grid[x..','..y]}
    if x==20 and y==0 then out[#out+1]=pole end
    return out
  end}
  local r=L.line({surface=surface,force=force,position={x=30,y=0}},grid['30,0'])
  eq(r.tiles,38)
  eq(r.line,'the line through (30.5,0.5): 38 belt tiles from (0.5,0.5) to (40.5,0.5); 2 gaps: 1 tile missing between (19.5,0.5) and (21.5,0.5): medium-electric-pole (20.5,0.5) stands on (20.5,0.5) | 2 tiles missing between (9.5,0.5) and (12.5,0.5): (10.5,0.5) empty; (11.5,0.5) empty')
  eq(r['end'],'(40.5,0.5): no belt of ours ahead of it in its direction within 16 tiles')
  eq(r.head,'(0.5,0.5): no belt of ours behind it in its direction within 16 tiles')
end
print('d17_batch20 B3 belt line: ok')

-- B4 (Sol): fleet: one line a platform from the gate, the hub, shipment's rows, rockets on the way and fuel.
do
  local pl={valid=true,name='Swiftlet',hub={valid=true}}
  local F=dofile('mod/agent-harness_0.1.0/fleet.lua'){
    gate=function(_,a) return {lines={a.platform..': at station gleba; stop 2 of 3: gleba (wait: carbon-fiber >= 400: holds 120, 280 to go)'}} end,
    hub_counts=function() return {['carbon-fiber']=120,['tungsten-carbide']=50,['plastic-bar']=900} end,
    shipment_platform=function() return {},{
      {direction='up',state='delivered',item='plastic-bar',planet='nauvis'},
      {direction='up',state='loading',item='carbon-fiber',planet='gleba'},
      {direction='up',state='waiting',item='bioflux',planet='gleba',min=200,hub=0,gate='the silo\'s request flag: below_min_payload (holds 150 of 200)'},
      {direction='down',state='aboard for vulcanus',item='plastic-bar',planet='vulcanus',count=500}} end,
    incoming=function() return {rockets=1,cargo='carbon-fiber*80'} end,
    where=function() return {stopped=true,at='gleba'} end,
    fuel_text=function() return 'thruster fuel 4000 units (+12/min over 10 min)' end}
  local r=F.read({force={platforms={pl}}},{})
  eq(r.lines[1],'Swiftlet: at station gleba; stop 2 of 3: gleba (wait: carbon-fiber >= 400: holds 120, 280 to go); hub holds plastic-bar*900 carbon-fiber*120 tungsten-carbide*50; requests: 1 delivered, 1 loading, 1 waiting (loading carbon-fiber from gleba); aboard for vulcanus\'s pads: plastic-bar*500; 1 rocket on the way: carbon-fiber*80; thruster fuel 4000 units (+12/min over 10 min); waits on bioflux 200 from gleba (the hub holds 0): the silo\'s request flag: below_min_payload (holds 150 of 200)')
  fails(function() F.read({force={platforms={pl}}},{platform='Kestrel'}) end,'no platform of ours named Kestrel')
end
print('d17_batch20 B4 fleet: ok')

-- C1 (Grok): circuit_gate: a decider from your inventory with every test, the roboport's items in, the entity's
-- circuit condition on its output, by the actions an agent calls.
do
  defines.direction={north=0}; defines.build_check_type={manual=1}
  prototypes.entity=prototypes.entity or {}
  prototypes.entity['decider-combinator']={get_max_circuit_wire_distance=function() return 9 end}
  local robo={valid=true,name='roboport',type='roboport',position={x=10,y=0},prototype={get_max_circuit_wire_distance=function() return 9 end}}
  local placed
  local surface={find_logistic_network_by_position=function() return {cells={{owner=robo}}} end,
    can_place_entity=function(a) return not (a.position.x==5.5 and (a.position.y==0 or a.position.y==1)) end,
    find_entities_filtered=function() return {placed} end}
  local cbi={connect_to_logistic_network=true}
  local ins={valid=true,name='fast-inserter',type='inserter',position={x=5.5,y=0.5},force='f',prototype={get_max_circuit_wire_distance=function() return 9 end},
    get_control_behavior=function() return cbi end}
  local held=1
  local p={surface=surface,force='f',position={x=6,y=2},build_distance=10,get_main_inventory=function() return {get_item_count=function() return held end} end}
  local calls={}
  local fail_at
  local function rec(kind) return function(_,a) calls[#calls+1]={kind,a}; if fail_at==#calls then error('wire does not reach',0) end
    if kind=='build' then placed={valid=true,name='decider-combinator',position=a.position} end return {} end end
  local G=dofile('mod/agent-harness_0.1.0/circgate.lua'){entity=function() return ins end,position=function(v) return {x=v.x,y=v.y} end,reason=function(e) return tostring(e) end,
    build=rec('build'),wire=rec('wire'),circuit_set=rec('circuit_set'),circuit_line=function() return 'fast-inserter (5.5,0.5): enabled when signal-check > 0' end}
  local r=G.handler(p,{position={x=5.5,y=0.5},all={'bioflux > 200','agricultural-science-pack < 500'}})
  eq(#calls,6); eq(calls[1][1],'build'); eq(calls[1][2].item,'decider-combinator'); eq(calls[1][2].position.x,4.5); eq(calls[1][2].position.y,0)
  eq(calls[2][2].read.logistic_network_contents,true); eq(calls[3][2].color,'red'); eq(calls[3][2].to_side,'input')
  eq(calls[4][2].decider.conditions[2],'and agricultural-science-pack < 500'); eq(calls[4][2].decider.outputs[1].signal,'signal-check')
  eq(calls[5][2].color,'green'); eq(calls[6][2].enable,'signal-check > 0'); eq(calls[6][2].logistic,false)
  eq(r.line,'fast-inserter (5.5,0.5) runs only while bioflux > 200 and agricultural-science-pack < 500 (decider (4.5,0) reading roboport (10,0))')
  has(r.done[6],'its logistic condition turned off')
  -- a step that fails: what was done and the calls left
  calls={}; fail_at=3
  fails(function() G.handler(p,{position={x=5.5,y=0.5},all={'bioflux > 200','agricultural-science-pack < 500'}}) end,
    'step 3 failed: wire does not reach; done: built decider-combinator at (4.5,0) from your inventory; roboport (10,0) reads its network\'s items; left: wire {from: (10,0), to: (4.5,0), color: red, to_side: input}')
  -- none held: refused before anything, with the calls
  calls={}; fail_at=nil; held=0
  fails(function() G.handler(p,{position={x=5.5,y=0.5},all={'bioflux > 200'}}) end,'you hold no decider-combinator (the gate takes one from your inventory); the calls once you hold one: build {"item":"decider-combinator","position":{"x":4.5,"y":0},"direction":"north"}')
  eq(#calls,0)
end
print('d17_batch20 C1 circuit_gate: ok')
