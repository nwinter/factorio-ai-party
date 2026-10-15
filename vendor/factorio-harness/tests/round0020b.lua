-- Bounded platform schematics and crop-tower death memory, without a character.
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,part) local ok,e=pcall(fn); assert(not ok and tostring(e):find(part,1,true),tostring(e)) end
local force={name='us',is_chunk_visible=function() return true end}
local surface={name='gleba',index=3}
local p={force=force,surface=surface}
game={tick=100,get_surface=function(name) if name=='gleba' then return surface end end}
defines={entity_status={working=1},inventory={agricultural_tower_input=1}}
local state={};local entities={};local as_of
local C=dofile('mod/agent-harness_0.1.0/agriculture.lua'){
  state=function() return state end,towers=function(f,s) eq(f,force); eq(s,surface); return entities,as_of end}
eq(C.read(p,{}).pending,true)
local tower={valid=true,type='agricultural-tower',name='agricultural-tower',force=force,surface=surface,
  position={x=120.5,y=-60.5},status=1,get_inventory=function() return {get_contents=function() return {{name='jellynut-seed',count=7}} end} end}
entities={tower};as_of=80
local r=C.read(p,{surface='gleba'});eq(r.pending,nil);eq(r.towers[1].state,'built');eq(r.towers[1].seeds[1].name,'jellynut-seed')
C.died(tower,'big-stomper-pentapod');tower.valid=false
r=C.read(p,{});eq(#r.towers,1);eq(r.towers[1].state,'destroyed');eq(r.towers[1].lost_tick,100);eq(r.towers[1].position.x,120.5)
local ghost={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='agricultural-tower',force=force,surface=surface,position=tower.position}
entities={ghost};r=C.read(p,{});eq(#r.towers,1);eq(r.towers[1].state,'ghost');eq(r.towers[1].cause,'big-stomper-pentapod')
force.is_chunk_visible=function() return false end
r=C.read(p,{});eq(r.towers[1].state,'destroyed','only remembered facts outside sight')
force.is_chunk_visible=function() return true end
tower.valid=true;entities={tower};r=C.read(p,{});eq(#r.towers,1);eq(r.towers[1].state,'built');eq(r.towers[1].lost_tick,nil)
entities={};r=C.read(p,{});eq(#r.towers,0,'rebuild clears stale death')
fails(function() C.read(p,{surface='missing'}) end,'unknown surface')
-- Memory is force-specific and bounded, even when towers die many times.
for i=1,260 do tower.position={x=i,y=0};game.tick=100+i;C.died(tower) end
eq(#C.read(p,{}).towers,256)
local other={name='other',is_chunk_visible=force.is_chunk_visible}
local O=dofile('mod/agent-harness_0.1.0/agriculture.lua'){state=function() return state end,towers=function() return {},80 end}
eq(#O.read({surface=surface,force=other},{}).towers,0)

local s={valid=true,name='space-platform-1'}
local hub={position={x=0,y=0}}
local platform={name='Sunward',surface=s,hub=hub}
local V=dofile('mod/agent-harness_0.1.0/platformview.lua'){platform=function(_,name) assert(name=='Sunward','unknown platform');return platform end}
local count=1
s.find_entities_filtered=function(q)
  assert(q.area and q.limit==513 and q.force==force,'bounded owned entities')
  local out={}
  for i=1,count do out[i]={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=2,y=2},direction=4,
    bounding_box={left_top={x=.5,y=.5},right_bottom={x=3.5,y=3.5}}} end
  return out
end
s.find_tiles_filtered=function(q)
  assert(q.area and q.limit==4226,'bounded tiles')
  eq(q.area[1][1],-24);eq(q.area[2][1],25)
  eq(q.name,'space-platform-foundation')
  return {{name='space-platform-foundation',position={x=1,y=0}},{name='space-platform-foundation',position={x=0,y=0}}}
end
local r=V.read(p,{platform='Sunward'})
eq(r.player,nil);eq(r.platform,'Sunward');eq(r.position.x,0);eq(r.tile_count,2);eq(#r.tile_runs,1);eq(r.tile_runs[1].x,0);eq(r.tile_runs[1].count,2);eq(r.entities[1].box.left_top.x,.5);eq(r.entities[1].direction,4)
count=513;r=V.read(p,{platform='Sunward',tiles=false});eq(#r.entities,512);eq(r.truncated,true)
fails(function() V.read(p,{platform='Sunward',radius=33}) end,'radius')
fails(function() V.read(p,{platform='Sunward',surface='gleba'}) end,'give platform or surface')
fails(function() V.read(p,{platform='Sunward',position={x=0/0,y=0}}) end,'finite')
print('round0020b views: ok')
