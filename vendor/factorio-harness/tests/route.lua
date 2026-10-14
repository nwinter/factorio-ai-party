-- Run from repository root: lua tests/route.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn);assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={build_check_type={manual_ghost=1}}
prototypes={entity={
  ['transport-belt']={name='transport-belt',type='transport-belt',related_underground_belt={name='underground-belt',type='underground-belt',max_underground_distance=5}},
  ['underground-belt']={name='underground-belt',type='underground-belt',max_underground_distance=5}}}
local function key(x,y) return math.floor(x)..','..math.floor(y) end
local blocked,belts,uncharted={},{},nil
local mine={is_chunk_charted=function(_,c) return not (uncharted and c.x>=uncharted) end}
local surface={
  -- As in the game, a belt may be placed over another (rotate/fast-replace).
  can_place_entity=function(a) local b=belts[key(a.position.x,a.position.y)]; return not blocked[key(a.position.x,a.position.y)] and (not b or b.type=='transport-belt') end,
  find_entities_filtered=function(f)
    if f.ghost_type then return {} end
    local out={}
    for _,e in pairs(belts) do out[#out+1]=e end
    return out
  end}
local p={surface=surface,force=mine}
local R=dofile('mod/agent-harness_0.1.0/route.lua'){
  position=function(v) return {x=v.x,y=v.y} end,
  directions={north=0,east=4,south=8,west=12},
  chunk_of=function(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end}
local function belt(x,y,d,kind,ug)
  local e={valid=true,type=kind or 'transport-belt',name=kind or 'transport-belt',position={x=x+0.5,y=y+0.5},direction=d,belt_to_ground_type=ug}
  belts[key(x,y)]=e; return e
end
local function at(plan,x,y)
  for _,e in ipairs(plan.entities) do if e.position.x==x+0.5 and e.position.y==y+0.5 then return e end end
end
local function reset() blocked,belts,uncharted={},{},nil end

-- Open ground: a straight run ending on the free target tile.
local r=R.plan(p,{from={x=0.5,y=0.5},to={x=5.5,y=0.5}})
eq(r.route,'E6'); eq(r.tiles,6); eq(r.items['transport-belt'],6); eq(r.arrival.mode,'end'); eq(r.arrival.direction,'east')
r=R.plan(p,{from={x=0,y=0},to={x=3,y=3},to_direction='west'})
eq(r.tiles,7); eq(r.entities[7].direction,'west'); eq(r.belts,7)
-- A wall too long to walk around is hopped with an underground pair.
for y=-40,40 do blocked[key(3,y)]=true end
r=R.plan(p,{from={x=0,y=0},to={x=6,y=0}})
eq(r.undergrounds,1); eq(r.items['underground-belt'],2)
local entry
for _,e in ipairs(r.entities) do if e.type=='input' then entry=e end end
assert(entry and entry.position.x<3 and entry.direction=='east')
for _,e in ipairs(r.entities) do assert(e.position.x~=3.5,'nothing on the wall') end
assert(r.route:find('uE',1,true),r.route)
fails(function() R.plan(p,{from={x=0,y=0},to={x=6,y=0},undergrounds=false}) end,'no route')
-- An underground of the same kind on the hop's axis would steal the pairing.
belt(2,0,4,'underground-belt','output'); belt(4,0,4,'underground-belt','input')
for x=1,5 do blocked[key(x,1)]=true; blocked[key(x,-1)]=true end
r=R.plan(p,{from={x=0,y=0},to={x=6,y=0}})
for _,e in ipairs(r.entities) do assert(e.position.y~=0.5 or e.position.x<1 or e.position.x>5,'hopped over a foreign underground') end
reset()
-- Tiles an existing belt outputs into are never used: that belt would feed the route.
belt(2,-1,8)
r=R.plan(p,{from={x=0,y=0},to={x=5,y=0}})
eq(at(r,2,0),nil)
reset()
-- A tile holding one of our belts is taken even when nothing feeds it: a
-- belt planned over it would never be built and the route would pour into it.
belt(2,0,12)
r=R.plan(p,{from={x=0,y=0},to={x=5,y=0}})
eq(at(r,2,0),nil)
reset()
-- Side-load onto a chosen lane of a belt that has an input from behind.
belt(10,5,0); belt(10,6,0)
r=R.plan(p,{from={x=5,y=5},to={x=10,y=5},lane='left'})
eq(r.route,'E5'); eq(r.arrival.mode,'side_load'); eq(r.arrival.lane,'left'); eq(r.arrival.into.x,10.5)
eq(at(r,10,5),nil) -- the target itself is not rebuilt
r=R.plan(p,{from={x=5,y=5},to={x=10,y=5},lane='right'})
eq(r.arrival.lane,'right'); eq(at(r,11,5).direction,'west')
r=R.plan(p,{from={x=10,y=12},to={x=10,y=5}}) -- blocked from behind by the existing belt
belt(9,4,8) -- feeds the only tile a left-lane feed can come from
fails(function() R.plan(p,{from={x=5,y=5},to={x=10,y=5},lane='left'}) end,'no way into to: 9.5,5.5 is fed by another belt')
belts[key(9,4)]=nil
assert(r.arrival.mode=='side_load')
-- Without an input from behind, a side feed makes a curve; a lane cannot be chosen.
belts[key(10,6)]=nil
r=R.plan(p,{from={x=5,y=5},to={x=10,y=5}})
eq(r.arrival.mode,'curve')
fails(function() R.plan(p,{from={x=5,y=5},to={x=10,y=5},lane='left'}) end,'no input from behind')
r=R.plan(p,{from={x=10,y=12},to={x=10,y=5}})
eq(r.arrival.mode,'straight'); eq(at(r,10,6).direction,'north')
reset()
-- Extending an existing belt end starts on the tile it outputs into.
belt(0,0,4)
r=R.plan(p,{from={x=0,y=0},to={x=4,y=0}})
eq(r.extends.x,0.5); eq(r.route,'E4'); eq(at(r,0,0),nil); eq(at(r,1,0).direction,'east')
reset()
-- Only charted ground is used; bad inputs are refused.
uncharted=1
fails(function() R.plan(p,{from={x=0,y=0},to={x=40,y=0}}) end,'not charted')
uncharted=nil
fails(function() R.plan(p,{from={x=0,y=0},to={x=1300,y=0}}) end,'each leg (from, via points, to) is at most 1000 tiles')
fails(function() R.plan(p,{from={x=0,y=0},to={x=0,y=0}}) end,'same tile')
fails(function() R.plan(p,{from={x=0,y=0},to={x=5,y=0},lane='left'}) end,'needs an existing belt')
fails(function() R.plan(p,{from={x=0,y=0},to={x=5,y=0},belt='underground-belt'}) end,'transport belt')
-- Long routes (Sol, operator 07:52: a 600-tile Gleba seed return): trees, rocks and wild plants are passed over at a
-- cost (marked when placed), water only with landfill, via points in order, a return line beside, lava under no hop.
do
  local trees,water,lava={},{},{}
  local surface2={
    can_place_entity=function(a)
      local k=key(a.position.x,a.position.y)
      if blocked[k] then return false end
      if a.forced then return not lava[k] end
      return not trees[k] and not water[k] and not lava[k]
    end,
    find_entities_filtered=function(f) return {} end,
    get_tile=function(x,y)
      local k=key(x,y)
      local name=lava[k] and 'lava' or water[k] and 'water' or 'grass-1'
      return {name=name,prototype={collision_mask={layers=lava[k] and {lava_tile=true} or water[k] and {water_tile=true} or {}}}}
    end}
  local q={surface=surface2,force=mine}
  local R2=dofile('mod/agent-harness_0.1.0/route.lua'){
    position=function(v) return {x=v.x,y=v.y} end,
    directions={north=0,east=4,south=8,west=12},
    chunk_of=function(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end,
    tile_fixes=function(_,_,_,pos) return water[key(pos.x,pos.y)] and {{x=pos.x,y=pos.y,tile='water',item='landfill'}} or {} end,
    only_obstacles=function(_,_,pos) return trees[key(pos.x,pos.y)] or false end}
  -- 600 tiles of open ground: one straight run, within the budget.
  local r=R2.plan(q,{from={x=0,y=0},to={x=600,y=0}})
  eq(r.route,'E601'); eq(r.tiles,601); assert(r.cost.placement_checks<40000 and r.cost.expansions<5000,r.cost.expansions)
  -- A row of trees across the way: crossed (cheaper than going round or under), counted, nothing else changes.
  for y=-40,40 do trees[key(10,y)]=true end
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0}})
  eq(r.route,'E21'); eq(r.over_trees_or_plants,1)
  trees={}
  -- A lake: round it (or under it) without landfill; straight across with it, counting the tiles.
  for x=5,7 do for y=-40,40 do water[key(x,y)]=true end end
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0}})
  eq(r.landfill,nil); assert(r.undergrounds>=1,r.route)
  water={}
  for x=5,9 do for y=-40,40 do water[key(x,y)]=true end end
  fails(function() R2.plan(q,{from={x=0,y=0},to={x=20,y=0}}) end,'tiles there: grass-1, water')
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0},landfill=true,undergrounds=false})
  eq(r.route,'E21'); eq(r.landfill.landfill,5); eq(r.items.landfill,5)
  water={}
  -- Lava: no underground hops it.
  for x=5,7 do for y=-40,40 do lava[key(x,y)]=true end end
  fails(function() R2.plan(q,{from={x=0,y=0},to={x=20,y=0}}) end,'no route: no way through on the leg to (20.5,0.5)')
  lava={}
  -- Via points in order: the line passes each; legs are listed.
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0},via={{x=5,y=10},{x=15,y=10}}})
  local seen={}
  for _,e in ipairs(r.entities) do seen[key(e.position.x,e.position.y)]=true end
  assert(seen[key(5,10)] and seen[key(15,10)],'passes both via points'); eq(#r.legs,3)
  fails(function() R2.plan(q,{from={x=0,y=0},to={x=20,y=0},via={{x=5,y=1200}}}) end,'each leg (from, via points, to) is at most 1000 tiles')
  blocked[key(5,10)]=true
  fails(function() R2.plan(q,{from={x=0,y=0},to={x=20,y=0},via={{x=5,y=10}}}) end,'via point 1 (5.5,10.5) is blocked')
  blocked={}
  -- The return line: back beside it the other way, on the right by default; both lines' belts in the items.
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0},['return']=true})
  eq(r.route,'E21'); eq(r['return'].side,'right'); eq(r['return'].route,'W21'); eq(r['return'].from.y,1.5); eq(r['return'].to.x,0.5)
  eq(r.items['transport-belt'],42); eq(#r.entities,42)
  for _,e in ipairs(r.entities) do if e.line=='return' then eq(e.position.y,1.5); eq(e.direction,'west') end end
  -- The right side blocked at the start: the left side.
  blocked[key(20,1)]=true
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0},['return']=true}); eq(r['return'].side,'left'); eq(r['return'].from.y,-0.5)
  fails(function() R2.plan(q,{from={x=0,y=0},to={x=20,y=0},['return']=true,return_side='right'}) end,'no return line: right: its first tile (20.5,1.5) is blocked or taken')
  blocked={}
  -- A turning line: the return line follows it round (it stays beside it).
  r=R2.plan(q,{from={x=0,y=0},to={x=10,y=10},to_direction='south',['return']=true})
  local main={}
  for _,e in ipairs(r.entities) do if not e.line then main[key(e.position.x,e.position.y)]=true end end
  local off=0
  for _,e in ipairs(r.entities) do
    if e.line=='return' then
      local x,y=math.floor(e.position.x),math.floor(e.position.y)
      local by=false
      for dx=-1,1 do for dy=-1,1 do if main[key(x+dx,y+dy)] then by=true end end end
      if not by then off=off+1 end
    end
  end
  eq(off,0,'every return belt beside the line')
  -- A wall with no way through: the nearest tile reached and the search's reach are named.
  for y=-40,40 do blocked[key(10,y)]=true end
  local ok,err=pcall(R2.plan,q,{from={x=0,y=0},to={x=20,y=0},undergrounds=false})
  assert(not ok and err:find('the nearest tile reached is (9.5,',1,true) and err:find('within 24 tiles of each leg',1,true),err)
  blocked={}
end
print('route: ok')
