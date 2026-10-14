-- Run from repository root: lua tests/grids.lua
-- Equipment grids (grids.lua; operator 09:13, a viewer via Astra: equipment worked only on the armor's grid):
-- which grid a call acts on and how the character gets at it, and a grid as its GUI shows it.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local force={name='player',is_chunk_visible=function() return true end}
local other={name='enemy'}
local function piece(name,x,y,w,h,q) return {name=name,position={x=x,y=y},shape={width=w,height=h},quality={name=q or 'normal'}} end
-- A tank's medium grid (6x8, read on world n) with two shields and a battery.
local tank_grid={width=6,height=8,shield=60,max_shield=300,available_in_batteries=12e6,battery_capacity=20e6,
  equipment={piece('energy-shield-equipment',0,0,2,2),piece('energy-shield-equipment',2,0,2,2,'rare'),piece('battery-mk2-equipment',4,0,1,2)}}
local tank={valid=true,name='tank',type='car',position={x=10.3,y=5},unit_number=77,force=force,grid=tank_grid,surface={name='nauvis'}}
local car={valid=true,name='car',type='car',position={x=20,y=5},unit_number=78,force=force,surface={name='nauvis'}}
local theirs={valid=true,name='tank',type='car',position={x=30,y=5},unit_number=79,force=other,grid=tank_grid,surface={name='nauvis'}}
local world={tank,car,theirs}
game={get_entity_by_unit_number=function(n) for _,e in ipairs(world) do if e.unit_number==n then return e end end end}
local reach=true
local p={force=force,character={valid=true},surface={find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do if ((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5<=f.radius then out[#out+1]=e end end
  return out
end},can_reach_entity=function() return reach end}
local G=dofile('mod/agent-harness_0.1.0/grids.lua'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,
  out_of_reach=function(_,e) return 'entity is out of reach: '..e.name..' is 14.0 tiles away (to its edge), reach 10' end}
-- The view: size, equipment by name (most first), free cells, shield and battery; rows on request.
local v=G.view(tank_grid,true)
eq(v.grid,'6x8'); eq(v.equipment,'energy-shield-equipment*2 battery-mk2-equipment*1'); eq(v.free_cells,38)
eq(v.shield,'60/300'); eq(v.battery_mj,'12/20'); eq(#v.rows,3); eq(v.rows[2].quality,'rare'); eq(v.rows[1].quality,nil)
eq(G.view({width=10,height=6,equipment={}}).equipment,'empty')
-- Without vehicle: the armor's grid, or a refusal.
p.character.grid=nil
fails(function() G.target(p,{}) end,'equipped armor has no equipment grid')
local armor={width=4,height=4,equipment={}}
p.character.grid=armor
local grid,where=G.target(p,{}); eq(grid,armor); eq(where,'armor')
-- A vehicle by unit_number or a position on it: in reach.
grid,where=G.target(p,{vehicle=77}); eq(grid,tank_grid); eq(where,'tank (10.3,5), unit_number 77')
grid,where=G.target(p,{vehicle={x=10,y=5}}); eq(grid,tank_grid)
-- Seated in it.
p.character.vehicle=tank; reach=false
grid,where=G.target(p,{vehicle=77}); eq(where,'tank (10.3,5), unit_number 77 (seated)')
p.character.vehicle=nil
-- Out of reach: putting in and taking out refused, as the GUI refuses; a read by remote view in a chunk our force sees.
fails(function() G.target(p,{vehicle=77},false) end,'entity is out of reach: tank is 14.0 tiles away (to its edge), reach 10; equipment goes in and out in reach or seated')
grid,where=G.target(p,{vehicle=77},true); eq(where,'tank (10.3,5), unit_number 77 (by remote view)')
force.is_chunk_visible=function() return false end
fails(function() G.target(p,{vehicle=77},true) end,'tank (10.3,5) is in no chunk our force sees now')
force.is_chunk_visible=function() return true end
reach=true
-- No grid, not ours, nothing there.
fails(function() G.target(p,{vehicle=78}) end,'car (20,5) has no equipment grid (a tank and a spidertron have one; a car, locomotive or wagon does not)')
fails(function() G.target(p,{vehicle=79}) end,'tank (30,5) is not ours')
fails(function() G.target(p,{vehicle=5}) end,'no vehicle has unit_number 5')
fails(function() G.target(p,{vehicle={x=-50,y=-50}}) end,'no vehicle at (-50,-50)')
print('grids: ok')
