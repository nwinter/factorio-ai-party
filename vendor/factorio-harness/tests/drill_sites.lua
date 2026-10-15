package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=100}
defines={entity_status={no_minable_resources=5},build_check_type={manual=1}}
prototypes={entity={coal={type='resource',resource_category='basic-solid'},stone={type='resource',resource_category='basic-solid'}}}
local force={name='player'}
local surface={name='vulcanus',index=3}
local e={valid=true,type='mining-drill',name='electric-mining-drill',unit_number=10,position={x=.5,y=.5},force=force,surface=surface,
  status=5,direction=0,quality={name='normal'},prototype={mining_drill_radius=2.49,tile_width=3,tile_height=3,resource_categories={['basic-solid']=true}}}
local p={surface=surface,force=force}
local s={push_drills={player={[10]='coal'}}}
local tiles={}
local reads,checks=0,0
local hidden=false
force.is_chunk_visible=function(_,chunk) return not hidden or chunk.x<=0 end
local drills={}
surface.find_entities_filtered=function(f)
  if type(f.type)=='table' then
    local out={}
    for _,d in ipairs(drills) do
      local h=d.half
      if d.position.x+h>f.area[1][1] and d.position.x-h<f.area[2][1] and d.position.y+h>f.area[1][2] and d.position.y-h<f.area[2][2] then out[#out+1]=d end
    end
    return out
  end
  reads=reads+1
  assert(f.type=='resource' and f.limit==1025)
  if hidden then assert(f.area[2][1]<=32,'hidden chunks must not affect the density limit') end
  local out={}
  for _,o in ipairs(tiles) do
    if o.name==f.name and o.position.x>=f.area[1][1] and o.position.x<f.area[2][1] and o.position.y>=f.area[1][2] and o.position.y<f.area[2][2] then
      out[#out+1]=o; if #out>=f.limit then break end
    end
  end
  return out
end
local blocked=false
surface.can_place_entity=function(a)
  checks=checks+1
  eq(a.name,e.name); eq(a.direction,e.direction); eq(a.quality,e.quality); eq(a.build_check_type,1)
  local dx,dy=math.abs(a.position.x-e.position.x),math.abs(a.position.y-e.position.y)
  return not blocked and (dx>=3 or dy>=3)
end
local D=require('drill_sites'){state=function() return s end,entity=function() return e end,
  on_surface=function(pp,name) eq(name,'vulcanus'); return p end,
  integer=function(v,d,lo,hi,k) v=v or d; assert(type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi,k); return v end}
local function tile(x,y,name,n) tiles[#tiles+1]={valid=true,position={x=x+.5,y=y+.5},name=name or 'coal',amount=n or 100} end
for x=4,12 do for y=-2,2 do tile(x,y) end end
tile(-4,0,'stone',9000)
local a={position=e.position,surface='vulcanus',radius=8,limit=8}
local r=D.read(p,a)
eq(r.resource,'coal'); eq(r.resource_source,'last observed mining target'); eq(r.footprint.width,3)
eq(#r.sites,8); eq(r.searched_radius,8); eq(r.sites[1].position.x,3.5); eq(r.sites[1].position.y,.5)
local last=-1
for _,c in ipairs(r.sites) do
  assert(c.distance>=last); last=c.distance
  local n,amount=0,0
  for _,o in ipairs(tiles) do
    if o.name=='coal' and math.abs(o.position.x-c.position.x)<=2.49 and math.abs(o.position.y-c.position.y)<=2.49 then n=n+1;amount=amount+o.amount end
  end
  eq(c.tiles,n); eq(c.amount,amount); assert(amount>0)
end
-- Empty and unknown resources stay factual; a conflicting memory is refused.
fails(function() D.read(p,{position=e.position,resource='stone'}) end,'last observed mining target')
s.push_drills=nil; reads=0
eq(D.read(p,{position=e.position}).line,'prior resource not recorded; no sites evaluated'); eq(reads,0)
eq(D.read(p,{position=e.position,resource='coal'}).resource_source,'supplied in this call')
tiles={}; eq(#D.read(p,{position=e.position,resource='coal'}).sites,0)
-- Dense scans shrink before traversing more than 1024 entities.
for x=-26,26 do for y=-26,26 do tile(x,y) end end
reads=0;checks=0
r=D.read(p,{position=e.position,resource='coal',radius=24})
eq(r.radius_reduced,true); assert(r.searched_radius<24); assert(reads<=24); assert(checks<=128)
-- Rejected placements cannot cause an unbounded number of engine calls.
blocked=true;checks=0
r=D.read(p,{position=e.position,resource='coal',radius=8})
eq(r.truncated,true); eq(r.checks,128); eq(checks,128); eq(#r.sites,0); blocked=false
-- Every mining area is visible, including the far edge across a chunk boundary.
e.position={x=30.5,y=.5}; tiles={}; hidden=true
for x=26,40 do for y=-3,3 do tile(x,y) end end
r=D.read(p,{position=e.position,resource='coal',radius=8,limit=8})
for _,c in ipairs(r.sites) do assert(c.position.x+2.49<32) end
hidden=false
-- Footprint and centre parity follow an even-sized rotated drill.
e.prototype.tile_width=2;e.prototype.tile_height=4;e.direction=4
r=D.read(p,{position=e.position,resource='coal',radius=8})
eq(r.footprint.width,4);eq(r.footprint.height,2)
for _,c in ipairs(r.sites) do eq(c.position.x%1,0);eq(c.position.y%1,0) end
e.status=0; fails(function() D.read(p,{position=e.position}) end,'no_minable_resources')
e.status=5;e.mining_target={valid=true};fails(function() D.read(p,{position=e.position}) end,'no mining target')
-- Group lookup reuses the same placement implementation once, then caches both
-- hits and misses; the selected ore cannot silently change to an adjacent one.
game.surfaces={vulcanus=surface};hidden=false;blocked=false;e.status=5;e.mining_target=nil
e.position={x=.5,y=.5};e.prototype.tile_width=3;e.prototype.tile_height=3;e.direction=0
tiles={};for x=4,8 do tile(x,0) end
s.push_drills={player={[10]='coal'}}
local group={key='out_of_ore.coal|vulcanus|0,0',surface='vulcanus',ore='coal',drill={position=e.position,name=e.name,unit_number=10}}
e.bounding_box={left_top={x=-.9,y=-.9},right_bottom={x=1.9,y=1.9}}
checks=0
local g=D.group(force,group);eq(g.site.position.x,3.5);eq(g.radius,24);eq(checks,1)
local nreads=reads;eq(D.group(force,group).site.position.x,3.5);eq(reads,nreads)
game.tick=game.tick+3600;blocked=true
g=D.group(force,group);eq(g.site,nil);nreads=reads
D.group(force,group);eq(reads,nreads)
-- A spot a working drill (or a drill ghost) covers is left out and named, though the engine check passes it (Astra,
-- d15 15:11, Fulgora).
game.tick=game.tick+3600;blocked=false
tiles={};for x=4,12 do for y=-2,2 do tile(x,y) end end
drills={{valid=true,type='mining-drill',name='electric-mining-drill',position={x=3.5,y=.5},half=1.5},
  {valid=true,type='entity-ghost',ghost_type='mining-drill',ghost_name='electric-mining-drill',position={x=3.5,y=3.5},half=1.5}}
r=D.read(p,{position=e.position,resource='coal',radius=8,limit=3})
for _,c in ipairs(r.sites) do
  assert(math.abs(c.position.x-3.5)>=3 or math.abs(c.position.y-.5)>=3,'no site over the working drill')
  assert(math.abs(c.position.x-3.5)>=3 or math.abs(c.position.y-3.5)>=3,'no site over the ghost')
end
assert(r.occupied>=2,tostring(r.occupied))
assert(r.line:find('nearer spots left out: a drill stands there',1,true),r.line)
assert(r.occupied_by[1]:find('electric-mining-drill (3.5,0.5)',1,true),r.occupied_by[1])
drills={}
print('drill sites: ok')
