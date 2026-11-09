package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function box(x0,y0,x1,y1) return {left_top={x=x0,y=y0},right_bottom={x=x1,y=y1}} end
prototypes={entity={
  ['railgun-turret']={type='ammo-turret',collision_box=box(-1.4,-2.4,1.4,2.4),attack_parameters={turn_range=.2,range=40,projectile_creation_distance=3.6,ammo_categories={'railgun'}}},
  belt={type='transport-belt',collision_box=box(-.5,-.5,.5,.5)},
  long={type='assembling-machine',collision_box=box(-.25,-2,.25,2)}},
  get_item_filtered=function() return {ammo={get_ammo_type=function() return {category='railgun',action={{type='line',range=50,width=1}}} end}} end}
local F=require('fireline'){}
local built={{position={x=0,y=0},direction=0,name='railgun-turret',type='ammo-turret',unit_number=1}}
local ghosts={{position={x=0,y=-40},direction=8,type='entity-ghost',unit_number=2}}
local calls=0
local surface={find_entities_filtered=function(a)
  calls=calls+1
  assert(a.force=='ours' and a.limit<=65)
  assert(a.name=='railgun-turret' or a.ghost_name=='railgun-turret')
  local src=a.name and built or ghosts
  local r={} for i=1,math.min(a.limit,#src) do r[i]=src[i] end return r
end}
local P=require('platdefense'){fireline=F,platform=function() return {name='Asterion',surface=surface,force='ours'} end}
local function prop(name,x,y,d) return {name=name,position={x=x,y=y},direction=d} end
local function read(entries) return P.read({}, {platform='Asterion',planned_entities=entries}) end
local r=read({prop('belt',0,-20),prop('belt',50,-20),prop('belt',0,-54.6),prop('belt',0,-54.601),prop('long',9,-10),prop('long',9,-10,'east')})
eq(calls,2); eq(r.platform,'Asterion'); eq(r.complete,true); eq(r.capped,false)
eq(#r.railguns,2); eq(r.railguns[2].ghost,true)
eq(#r.entities[1].railguns,2); eq(#r.entities[2].railguns,0)
eq(r.entities[3].railguns[1],1); eq(#r.entities[4].railguns,0) -- outer reach edge touch, then miss
eq(#r.entities[5].railguns,2); eq(#r.entities[6].railguns,2)
eq(r.entities[6].direction,4)
-- Rotation changes the intersection near the wedge edge (no ghost influence).
ghosts={}
r=read({prop('long',10,-10,0),prop('long',10,-10,4)})
eq(#r.entities[1].railguns,0); eq(#r.entities[2].railguns,1)
-- Shared predicate agrees with the existing-entity read for the same box, including misses.
for i, e in ipairs(r.entities) do
  local existing={name=e.name,position=e.position,bounding_box=i==1 and box(9.75,-12,10.25,-8) or box(8,-10.25,12,-9.75),type='assembling-machine',is_entity_with_health=true}
  local old=F.hits({find_entities_filtered=function() return {existing} end},'ours','railgun-turret',{x=0,y=0},0)
  eq(old.hit,#e.railguns)
end
-- Exactly full is complete; sentinel makes >64 incomplete on every row, even a miss.
for i=2,64 do built[i]=built[1] end
r=read({prop('belt',0,-20)}); eq(#r.entities[1].railguns,64); eq(r.complete,true)
ghosts={{position={x=0,y=-40},direction=8,type='entity-ghost'}}
r=read({prop('belt',0,-20),prop('belt',500,500)})
eq(#r.railguns,64); eq(r.capped,true); eq(r.complete,false)
eq(r.entities[2].complete,false); eq(r.entities[2].capped,true)
built[65]=built[1]; ghosts={}; calls=0
r=read({prop('belt',0,-20)}); eq(calls,1); eq(r.capped,true)
local entries={} for i=1,8 do entries[i]=prop('belt',0,-20) end
eq(#read(entries).entities,8)
local function bad(fn,pattern) local ok,e=pcall(fn); assert(not ok and tostring(e):find(pattern),tostring(e)) end
entries[9]=entries[1]; bad(function() read(entries) end,'1..8')
bad(function() read({}) end,'1..8')
bad(function() read({prop('missing',0,0)}) end,'prototype')
bad(function() read({prop('belt',0/0,0)}) end,'finite')
bad(function() read({prop('belt',0,0,16)}) end,'direction')
bad(function() P.read({}, {planned_entities={prop('belt',0,0)},planned=true}) end,'only with platform')
eq(P.schema.platform_defense.planned_entities:find('1..8',1,true)~=nil,true)
-- Broad rejection must preserve the shared predicate for every source facing and rotated footprint.
built={built[1]}; ghosts={}
for d=0,15 do
  built[1].direction=d
  for x=-60,60,10 do
    local batch={}
    for y=-60,60,20 do batch[#batch+1]=prop('long',x+.25,y+.75,(d+4)%16) end
    local out=read(batch)
    for _,row in ipairs(out.entities) do
      local a=row.direction*math.pi/8
      local hx=math.abs(.25*math.cos(a))+math.abs(2*math.sin(a))
      local hy=math.abs(.25*math.sin(a))+math.abs(2*math.cos(a))
      local q=row.position
      local hit=F.intersects(F.arc('railgun-turret'),built[1].position,d,'railgun-turret',row.name,q,box(q.x-hx,q.y-hy,q.x+hx,q.y+hy))
      eq(#row.railguns,hit and 1 or 0)
    end
  end
end
prototypes.entity.long.supports_direction=false
r=read({prop('long',10,-10,'east')}); eq(r.entities[1].direction,0)
bad(function() read({prop('belt',0,0,false)}) end,'direction')
built={}; r=read({prop('belt',0,0)}); eq(r.complete,true); eq(#r.railguns,0)
print('batch412: proposed corridors hit/miss/edge/rotation/caps/validation/read-only path ok')
