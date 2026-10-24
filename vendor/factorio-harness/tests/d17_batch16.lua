-- Run from the harness root: lua tests/d17_batch16.lua
-- d17 batch16 module contracts (the runtime ones are in tests/d17_batch16_rt.lua).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- A2 (Grok/Wren d17: rocket-turret "came aboard 0" while the hull went from 9 turrets to 14): turrets a rocket brings
-- that construction robots place from the hub within the second count as came aboard, and are said as built at once.
do
  defines={space_platform_state={on_the_path=3,waiting_at_station=6,no_schedule=5},inventory={hub_main=1,hub_trash=2,cargo_unit=4}}
  prototypes={item={['rocket-turret']={get_spoil_ticks=function() return 0 end,place_result={name='rocket-turret'}},
    ['space-platform-foundation']={get_spoil_ticks=function() return 0 end,place_as_tile_result={result={name='space-platform-foundation'}}},
    ['carbon-fiber']={get_spoil_ticks=function() return 0 end}},space_location={nauvis={}}}
  local main={}
  local function inv(t) return {get_contents=function() local out={}; for n,c in pairs(t) do out[#out+1]={name=n,count=c,quality='normal'} end; return out end} end
  local hub={valid=true,get_inventory=function(id) return id==1 and inv(main) or inv({}) end,
    get_logistic_sections=function() return {sections_count=0,get_section=function() end} end}
  local turrets,tiles,counted=9,700,0
  local surface={find_entities_filtered=function() return {} end,
    count_entities_filtered=function(f) counted=counted+1; eq(f.name,'rocket-turret'); return turrets end,
    count_tiles_filtered=function(f) eq(f.name,'space-platform-foundation'); return tiles end}
  local wren={valid=true,index=1,name='Wren',hub=hub,state=6,space_location={name='nauvis'},surface=surface,
    schedule={records={{station='nauvis'}},current=1}}
  local force={name='player',platforms={wren}}
  wren.force=force
  game={tick=0,forces={player=force},planets={nauvis={surface={find_entities_filtered=function() return {} end}}}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end,spoil=dofile('mod/agent-harness_0.1.0/spoil.lua'){state=function() return st end}}
  local function second(n) for _=1,n or 1 do game.tick=game.tick+60; F.tick(game.tick) end end
  main={['carbon-fiber']=10}
  second()
  -- a rocket with 5 turrets, 103 carbon fiber and 20 foundation: robots place the turrets and the tiles at once
  F.on_launch({rocket={attached_cargo_pod={cargo_pod_destination={station={surface={platform=wren}}},
    get_inventory=function() return inv({['rocket-turret']=5,['carbon-fiber']=103,['space-platform-foundation']=20}) end}}})
  second(10)
  main['carbon-fiber']=113; turrets=14; tiles=720
  second(5)
  local fr=F.read(wren)
  local line=fr[1].line
  has(line,'rocket-turret: came aboard 5, built at once 5 (construction robots placed it from the hub: 9 -> 14 on the platform)')
  has(line,'space-platform-foundation: came aboard 20, built at once 20 (construction robots placed it from the hub: 700 -> 720 on the platform)')
  has(line,'carbon-fiber')
  local row
  for _,r in ipairs(fr[1].items) do if r.item=='rocket-turret' then row=r end end
  eq(row.came,5); eq(row.built,5); eq(row.left,0)
  -- the stop ends: the count at its end is kept, a later build is not this stop's
  wren.state=3; wren.space_location=nil; wren.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; wren.distance=0.1
  wren.schedule={records={{station='gleba'}},current=1}
  prototypes.space_location.gleba={}
  second(2)
  turrets=16
  local done
  for _,s in ipairs(F.read(wren)) do if s.kind=='stop' then done=s end end
  has(done.line,'rocket-turret: came aboard 5, built at once 5 (construction robots placed it from the hub: 9 -> 14 on the platform)')
end
print('d17_batch16 A2 freight built at once: ok')

-- A3 (Astra on Wren, board #825): the floor audit said 0 needed while the built pair (-0.5,-17.5) -> (-0.5,-14.5)
-- (southward) stood over empty (-1,-16): an east-going underground at (-0.5,-16.5) crossing the span ended the walk
-- there. The exit is the next one of the name facing the same way; a crossing one is passed over. Pipes too.
do
  game={tick=0}
  prototypes={entity={['underground-belt']={max_underground_distance=5},
    ['pipe-to-ground']={fluidbox_prototypes={{pipe_connections={{},{max_underground_distance=10}}}}}}}
  local tiles={}
  for x=-4,4 do for y=-20,-10 do if not (x==-1 and y==-16) and not (x==3 and y==-15) then tiles[#tiles+1]={position={x=x,y=y}} end end end
  local function ub(x,y,dir,io,name)
    return {valid=true,type=name or 'underground-belt',name=name or 'underground-belt',position={x=x,y=y},direction=dir,belt_to_ground_type=io,
      bounding_box={left_top={x=x-.4,y=y-.4},right_bottom={x=x+.4,y=y+.4}}}
  end
  local built={ub(-0.5,-17.5,8,'input'),ub(-0.5,-14.5,8,'output'),        -- the southward pair
    ub(-0.5,-16.5,4,'input'),ub(1.5,-16.5,4,'output'),                      -- the crossing east-going pair
    ub(3.5,-17.5,0,nil,'pipe-to-ground'),ub(3.5,-12.5,8,nil,'pipe-to-ground'), -- a pipe tunnel south (each faces its pipe, outward)
    ub(3.5,-15.5,4,nil,'pipe-to-ground')}                                   -- a crossing pipe-to-ground in that tunnel
  local s={find_tiles_filtered=function() return tiles end,
    find_entities_filtered=function(f)
      if f.type=='entity-ghost' or f.type=='tile-ghost' then return {} end
      if type(f.type)=='table' and f.type[1]=='underground-belt' then return built end
      return {}
    end}
  local PP=dofile('mod/agent-harness_0.1.0/platplan.lua'){}
  local list,why=PP.floor(s,{},{position={x=0.5,y=-15.5}})
  local at={}
  for _,t in ipairs(list) do at[t.x..','..t.y]=t.kind end
  eq(at['-1,-16'],'tunnel','under the southward span past the crossing underground')
  eq(at['3,-15'],'tunnel','under the pipe tunnel past the crossing pipe-to-ground')
  eq(why.tunnel,2)
  -- a same-way entrance between: the first entrance has no exit (the game pairs nothing across it); nothing asked
  built={ub(-0.5,-17.5,8,'input'),ub(-0.5,-16.5,8,'input'),ub(-0.5,-14.5,8,'output')}
  list,why=PP.floor(s,{},{position={x=0.5,y=-15.5}})
  eq(why.tunnel,1,'only the second entrance\'s span (-1,-16)')
  -- the reply names a tile ghost the hub's foundation rules hold back (it counts as floor, and is never built)
  built={}
  local tg={valid=true,type='tile-ghost',ghost_name='space-platform-foundation',position={x=10.5,y=-30.5}}
  local floor={}
  for _,t in ipairs(tiles) do floor[t.position.x..','..t.position.y]=true end
  s.find_entities_filtered=function(f)
    if f.type=='tile-ghost' then return {tg} end
    return {}
  end
  s.get_tile=function(x,y) return {name=floor[x..','..y] and 'space-platform-foundation' or 'empty-space'} end
  local PP2=dofile('mod/agent-harness_0.1.0/platplan.lua'){platform=function() return {name='Wren',surface=s,force={},hub={valid=true,position={x=0.5,y=-15.5}}} end}
  PP2.SLICE=math.huge  -- (d24 batch166) the plan in its call
  local r=PP2.read({},{platform='Wren',floor=true})
  eq(#r.tile_ghosts_held,1)
  has(r.line,'1 tile ghost counted as floor the hub does not build (foundation rules): tile ghost (10.5,-30.5) space-platform-foundation: no foundation among the 8 tiles round it')
  prototypes=nil
end
print('d17_batch16 A3 floor under a span with a crossing underground: ok')

-- B3 (Sol: deficit wiring took dozens of inspect calls and comparing networks by hand): circuit_audit with area or
-- positions reads every red and green network those entities are on: its signals now and which of them are on it.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2}}
  local red={network_id=544,connected_circuit_count=9,signals={{signal={name='iron-plate'},count=480},{signal={name='firearm-magazine'},count=901},{signal={name='rocket'},count=-3}}}
  local green={network_id=12,signals={}}
  local function ent(name,x,y,nets) return {valid=true,name=name,type=name,position={x=x,y=y},unit_number=math.floor(x*100+y),
    get_circuit_network=function(w) return nets[w] end} end
  local hub=ent('space-platform-hub',0,0,{[1]=red})
  local i1=ent('fast-inserter',-3.5,4.5,{[1]=red})
  local i2=ent('fast-inserter',-9.5,5.5,{[1]=red,[2]=green})
  local belt=ent('transport-belt',2.5,2.5,{})
  local all={hub,i1,i2,belt}
  local s={find_entities_filtered=function(f)
    if f.area then return all end
    local out={}
    for _,e in ipairs(all) do if e.position.x==f.position[1] and e.position.y==f.position[2] then out[#out+1]=e end end
    return out
  end}
  local C=dofile('mod/agent-harness_0.1.0/circaudit.lua'){platform=function(_,name) return {name=name,surface=s,force='player'} end,
    circuit_short=function(e) return e==i1 and 'enabled when iron-plate < 1000 (true now)' or 'wired, default settings' end}
  local r=C.read({surface=s,force='player'},{platform='Meridian',area={left_top={x=-20,y=-5},right_bottom={x=5,y=10}}})
  eq(r.where,'platform Meridian'); eq(r.entities,3,'the belt is on no network')
  eq(#r.networks,2); eq(r.networks[1].id,12); eq(r.networks[2].id,544)
  eq(r.networks[2].signals[1].name,'firearm-magazine','largest first')
  has(r.lines[2],'red #544: signals firearm-magazine 901, iron-plate 480, rocket -3; of these, 3 on it (9 connected in all): '
    ..'space-platform-hub (0,0); fast-inserter (-3.5,4.5) (enabled when iron-plate < 1000 (true now)); fast-inserter (-9.5,5.5)')
  has(r.lines[1],'green #12: no signal now; of these, 1 on it: fast-inserter (-9.5,5.5)')
  -- positions: only those entities
  r=C.read({surface=s,force='player'},{positions={{x=-3.5,y=4.5}}})
  eq(r.where,'your surface'); eq(r.entities,1); eq(#r.networks,1)
  assert(not pcall(C.read,{surface=s,force='player'},{area={left_top={x=0,y=0},right_bottom={x=200,y=10}}}),'at most 128x128')
end
print('d17_batch16 B3 circuit networks across entities: ok')
