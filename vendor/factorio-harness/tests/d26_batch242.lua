-- Run from repository root: lua tests/d26_batch242.lua
-- d26 batch242 HP (Astra #2454): an Aquilo beacon retrofit crossed a dense heat trunk; deconstruct named 815 cut-off
-- parts only after marking, and moving a heating tower took the only heater of the water pipe at (3.5,1.5).
-- heat_budget {remove | remove_area, build}: what proposed removals and builds do to the heat networks, nothing
-- removed or built: components before and after, the ones cut from every heat source with their heat users, the
-- entities that freeze (the game's heating rule), free-tile heat-pipe paths back to a heated component, and each
-- entity's heat connection points against its heating border. A small Aquilo layout with the game's connections.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={direction={north=0,east=4,south=8,west=12}}
local function hb(conns) local c={} for _,x in ipairs(conns) do c[#c+1]={position={x=x[1],y=x[2]},direction=x[3]} end return {connections=c,specific_heat=1e6,max_temperature=1000} end
local function sq(r) return {left_top={x=-r,y=-r},right_bottom={x=r,y=r}} end
prototypes={entity={
  ['heat-pipe']={name='heat-pipe',type='heat-pipe',collision_box=sq(0.4),collision_mask={layers={object=true}},heat_buffer_prototype=hb({{0,0,0},{0,0,4},{0,0,8},{0,0,12}})},
  -- the game's heating tower: a heat connection at the middle tile of each side only
  ['heating-tower']={name='heating-tower',type='reactor',collision_box=sq(1.4),collision_mask={layers={object=true}},heat_buffer_prototype=hb({{0,-1,0},{1,0,4},{0,1,8},{-1,0,12}})},
  ['heat-exchanger']={name='heat-exchanger',type='boiler',collision_box={left_top={x=-1.4,y=-0.9},right_bottom={x=1.4,y=0.9}},collision_mask={layers={object=true}},
    heat_energy_source_prototype=hb({{0,0.5,8}})},
  pipe={name='pipe',type='pipe',collision_box=sq(0.4),collision_mask={layers={object=true}},heating_energy=1000/60},
  inserter={name='inserter',type='inserter',collision_box=sq(0.15),collision_mask={layers={object=true}},heating_energy=30000/60},
  beacon={name='beacon',type='beacon',collision_box=sq(1.2),collision_mask={layers={object=true}},heating_energy=400000/60}}}
local D=dofile('mod/agent-harness_0.1.0/dryrun.lua'){placewhy={box_at=function(b,pos) return {left_top={x=pos.x+b.left_top.x,y=pos.y+b.left_top.y},right_bottom={x=pos.x+b.right_bottom.x,y=pos.y+b.right_bottom.y}} end}}
local force={name='player',is_chunk_visible=function() return true end}
local function surface(name,heating)
  local s={name=name,planet={prototype={entities_require_heating=heating}},world={}}
  local function within(e,f)
    local p=e.position
    if f.position then return math.abs(p.x-f.position.x)<0.01 and math.abs(p.y-f.position.y)<0.01 end
    if f.area then
      local a=f.area; local lt,rb=a[1] or a.left_top,a[2] or a.right_bottom
      local b=e.bounding_box
      return b.right_bottom.x>(lt.x or lt[1]) and b.left_top.x<(rb.x or rb[1]) and b.right_bottom.y>(lt.y or lt[2]) and b.left_top.y<(rb.y or rb[2])
    end
    return true
  end
  local function match(v,x) if v==nil then return true end if type(v)=='table' then for _,y in ipairs(v) do if y==x then return true end end return false end return v==x end
  s.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(s.world) do if e.valid and within(e,f) and match(f.type,e.type) and match(f.name,e.name) then out[#out+1]=e end end
    return out
  end
  s.get_tile=function(x,y) return {name='ice-platform',valid=true,collides_with=function() return false end} end
  return s
end
local aq=surface('aquilo',true)
local unit=0
local function put(s,name,x,y,dir,temp)
  local proto=prototypes.entity[name]
  unit=unit+1
  local cb=proto.collision_box
  local e={valid=true,unit_number=unit,name=name,type=proto.type,position={x=x,y=y},direction=dir or 0,prototype=proto,temperature=temp,surface=s,frozen=false}
  e.bounding_box={left_top={x=x+cb.left_top.x,y=y+cb.left_top.y},right_bottom={x=x+cb.right_bottom.x,y=y+cb.right_bottom.y}}
  s.world[#s.world+1]=e
  return e
end
-- heat links as the engine makes them: a connection point facing a tile where the other has one facing back
local function link(s)
  local at={}
  for _,e in ipairs(s.world) do
    if e.valid and (e.prototype.heat_buffer_prototype or e.prototype.heat_energy_source_prototype) then
      for _,c in ipairs(D.heat_points(e.prototype,e.position,e.direction)) do local k=c.x..','..c.y; at[k]=at[k] or {}; table.insert(at[k],{e=e,c=c}) end
    end
  end
  for _,e in ipairs(s.world) do
    e.heat_neighbours={}
    if e.prototype.heat_buffer_prototype or e.prototype.heat_energy_source_prototype then
      for _,c in ipairs(D.heat_points(e.prototype,e.position,e.direction)) do
        for _,o in ipairs(at[c.tx..','..c.ty] or {}) do if o.e~=e and o.c.tx==c.x and o.c.ty==c.y then e.heat_neighbours[#e.heat_neighbours+1]=o.e end end
      end
    end
  end
end
-- the layout: a heating tower at (3.5,3.5); heat pipes east from its east connection, then south to a heat exchanger
-- facing up; a water pipe on the tower's north side (Astra's (3.5,1.5)), another at its corner, an inserter beside a
-- heat pipe
local tower=put(aq,'heating-tower',3.5,3.5,0,675)
for x=5,9 do put(aq,'heat-pipe',x+0.5,3.5,0,650) end
for y=4,9 do put(aq,'heat-pipe',9.5,y+0.5,0,640) end
local hx=put(aq,'heat-exchanger',9.5,11,8,500)
local water=put(aq,'pipe',3.5,1.5)
local corner=put(aq,'pipe',1.5,1.5)
local ins=put(aq,'inserter',6.5,4.5)
link(aq)
eq(#hx.heat_neighbours,1,'the heat exchanger joins the pipe above it')
eq(#tower.heat_neighbours,1,'the tower joins the pipe at its east side only')
local H=dofile('mod/agent-harness_0.1.0/heating.lua'){footprint=D.footprint or function(proto,pos,dir)
    local b=proto.collision_box; return {left_top={x=pos.x+b.left_top.x,y=pos.y+b.left_top.y},right_bottom={x=pos.x+b.right_bottom.x,y=pos.y+b.right_bottom.y}} end,
  heat_points=D.heat_points,position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,
  direction=function(v) return type(v)=='number' and v or defines.direction[v] end}
local p={force=force,surface=aq}

-- 1. Astra's move: the tower away, a beacon in its place, a tower built far off
local r=H.preview(p,aq,{remove={{x=3.5,y=3.5}},build={{name='beacon',position={x=3.5,y=3.5}},{name='heating-tower',position={x=20.5,y=3.5}}}})
eq(r.removed,1); eq(r.planned,2)
eq(#r.before,1); has(r.before[1],'13 parts (1 heat-exchanger, 1 heating-tower, 11 heat-pipe), 1 heat source')
eq(#r.after,2)
has(r.after[1],'12 parts (1 heat-exchanger, 11 heat-pipe), no heat source'); has(r.after[2],'1 parts (1 heating-tower), 1 heat source, a part at (20.5,3.5)')
eq(#r.unheated,1); eq(r.unheated[1].consumers_count,1); eq(r.unheated[1].consumers[1],'heat-exchanger (9.5,11)')
-- freezing: the water pipe on the tower's side, the one at its corner, and the inserter beside a cut-off pipe
eq(r.freeze_count,3)
local fz=table.concat(r.freeze,' | ')
has(fz,'pipe (3.5,1.5): heated now by heating-tower (3.5,3.5) (675 C); after: no heater at 30 C or more in a component with a heat source touches it')
has(fz,'pipe (1.5,1.5): heated now by heating-tower (3.5,3.5)')
has(fz,'inserter (6.5,4.5): heated now by heat-pipe')
has(r.freeze_rule,'aquilo requires heating'); has(r.freeze_rule,'inserter 30 kW, pipe 1 kW')
-- the free-tile path from the cut-off pipes to the new tower's west connection (18.5,3.5): 9 heat pipes
eq(#r.paths,1); has(r.paths[1].paths[1],'9 heat pipes from (10.5,3.5) to (18.5,3.5): (10.5,3.5) (11.5,3.5)')
-- connection points: the tower's mid-side tiles against the border it warms, corners included
has(r.connections[1],'heating-tower (3.5,3.5): joins heat entities with a connection back on (3.5,1.5) (5.5,3.5) (3.5,5.5) (1.5,3.5); warms entities touching (1,1)-(5,5), its border, corners included')
has(r.connections[2],'heating-tower (20.5,3.5) (planned): joins heat entities with a connection back on (20.5,1.5) (22.5,3.5) (20.5,5.5) (18.5,3.5)')
has(r.note,'a read: nothing removed or built')
-- nothing changed
assert(tower.valid and #aq.world==16,'nothing removed or built')

-- 2. a bypass that keeps the heat: one pipe out, three round it; nothing loses its source, nothing freezes
r=H.preview(p,aq,{remove={{x=7.5,y=3.5}},build={{name='heat-pipe',position={x=6.5,y=2.5}},{name='heat-pipe',position={x=7.5,y=2.5}},{name='heat-pipe',position={x=8.5,y=2.5}}}})
eq(#r.after,1); has(r.after[1],'15 parts'); has(r.after[1],'1 heat source')
eq(r.unheated,nil); eq(r.none,'no part of a heat network loses its last heat source'); eq(r.freeze_count,nil); eq(r.paths,nil)
-- the same cut without the bypass: the pipes east of it lose the source; the path search finds the gap round it
r=H.preview(p,aq,{remove_area={left_top={x=7,y=3},right_bottom={x=8,y=4}},remove_names={'heat-pipe'}})
eq(r.removed,1); eq(#r.unheated,1); has(r.unheated[1].component,'9 parts (1 heat-exchanger, 8 heat-pipe), no heat source')
-- (the removed tile is not free: the shortest way round it is 3 pipes)
has(r.paths[1].paths[1],'3 heat pipes')

-- 3. refusals
fails(function() H.preview(p,aq,{}) end,'remove, remove_area or build names what changes')
fails(function() H.preview(p,aq,{remove={{x=50.5,y=50.5}}}) end,'remove[1]: no entity of ours at (50.5,50.5)')
fails(function() H.preview(p,aq,{build={{name='heat-pipe',position={x=1,y=1},direction='up'}}}) end,'build[1]: direction must be a compass name or 0..15')
fails(function() H.preview(p,aq,{build={{name='nope',position={x=1,y=1}}}}) end,'build[1]: name must be an entity name')
local hidden={force={name='player',is_chunk_visible=function() return false end},surface=aq}
fails(function() H.preview(hidden,aq,{remove={{x=3.5,y=3.5}}}) end,'in no chunk our force sees now')

-- 4. a surface that needs no heating: components and paths, no freezing
local nv=surface('nauvis',false)
put(nv,'heating-tower',3.5,3.5,0,500); put(nv,'heat-pipe',5.5,3.5,0,400); put(nv,'pipe',3.5,1.5)
link(nv)
r=H.preview({force=force,surface=nv},nv,{remove={{x=3.5,y=3.5}}})
eq(#r.unheated,1); eq(r.freeze_count,nil); eq(r.freeze_rule,nil)
print('d26_batch242 HP heat preview: ok')
