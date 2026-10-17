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
-- A side input follows the receiving belt to its open output.
belt(1,0,8)
r=R.plan(p,{from={x=0,y=0},to={x=4,y=0}})
eq(#r.existing,2); eq(at(r,0,0),nil); eq(at(r,1,0),nil); assert(at(r,1,1))
-- Opposing outputs do not carry items into one another.
belt(1,0,12)
fails(function() R.plan(p,{from={x=0,y=0},to={x=4,y=0}}) end,'from chain blocked at (1.5,0.5)')
reset()
for x=0,4 do belt(x,0,4) end
r=R.plan(p,{from={x=0,y=0},to={x=8,y=0}})
eq(#r.existing,5); eq(r.tiles,4); eq(at(r,4,0),nil); eq(at(r,5,0).direction,'east')
r=R.plan(p,{from={x=0,y=0},to={x=4,y=0}})
eq(r.connected,true); eq(r.tiles,0); eq(#r.entities,0)
reset()
belt(0,0,4); belt(1,0,8); belt(1,1,12); belt(0,1,0)
fails(function() R.plan(p,{from={x=0,y=0},to={x=8,y=0}}) end,'from chain loops at (0.5,0.5)')
reset()
local entry=belt(0,0,4,'underground-belt','input')
fails(function() R.plan(p,{from={x=0,y=0},to={x=8,y=0}}) end,'underground entrance has no paired exit')
local exit=belt(4,0,4,'underground-belt','output'); exit.force=mine; entry.neighbours=exit
r=R.plan(p,{from={x=0,y=0},to={x=8,y=0}})
eq(#r.existing,2); eq(r.route,'E4')
reset()
-- A re-run over a line with gaps (d17 batch20 A2, Sonnet): via points on the from chain are passed, one on a standing
-- line makes the route feed its head and go on from its open end; to on a standing line ends the route at its head.
for x=0,20 do if x~=3 and x~=12 then belt(x,0,4) end end
r=R.plan(p,{from={x=0,y=0},via={{x=2,y=0},{x=5,y=0},{x=10,y=0},{x=15,y=0}},to={x=20,y=0}})
eq(#r.entities,2); eq(at(r,3,0).direction,'east'); eq(at(r,12,0).direction,'east'); eq(r.arrival.mode,'straight')
eq(r.via_passed[1],'via 1 (2.5,0.5): on the line from from, laid already')
eq(r.via_passed[2],'via 3 (10.5,0.5): on the standing line joined at via 2')
eq(r.joined[1],'via 2 (5.5,0.5): our standing line from (4.5,0.5) to (11.5,0.5) (8 tiles) is kept; the route feeds its head (4.5,0.5) and goes on from its open end (12.5,0.5)')
eq(r.joined[2],'via 4 (15.5,0.5): our standing line from (13.5,0.5) to (20.5,0.5) (8 tiles) is kept; the route feeds its head (13.5,0.5) and the line runs on to to')
fails(function() R.plan(p,{from={x=0,y=0},via={{x=5,y=0}},to={x=20,y=0},['return']=true}) end,'lay the return line in a call of its own')
-- Whole: connected, the via points passed.
belt(3,0,4); belt(12,0,4)
r=R.plan(p,{from={x=0,y=0},via={{x=5,y=0}},to={x=20,y=0}})
eq(r.connected,true); eq(r.via_passed[1],'via 1 (5.5,0.5): on the line, laid already')
reset()
-- A standing line entered by a curve: its head is the first tile of the curve's feed.
belt(6,-2,8); belt(6,-1,8); belt(6,0,4); belt(7,0,4); belt(8,0,4)
r=R.plan(p,{from={x=0,y=-6},via={{x=7,y=0}},to={x=14,y=0}})
assert(r.joined[1]:find('from (6.5,-1.5) to (8.5,0.5) (5 tiles)',1,true),r.joined[1])
eq(at(r,6,-2),nil); eq(at(r,6,-3).direction,'south'); eq(at(r,9,0).direction,'east'); assert(at(r,14,0))
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
    tile_info=function(_,_,name) return name=='water' and {collides=true,item='landfill'} or name=='lava' and {collides=true} or {collides=false} end,
    tiles={stands_fn=function() return function(x,y) return not water[key(x,y)] and not lava[key(x,y)] end end},
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
  -- An end on water says so (and how landfill helps).
  water[key(30,0)]=true
  fails(function() R2.plan(q,{from={x=30,y=0},to={x=40,y=0}}) end,'the start tile (30.5,0.5) is water (landfill=true lays tile ghosts under the belts)')
  fails(function() R2.plan(q,{from={x=20,y=0},to={x=30,y=0}}) end,'to (30.5,0.5) is water (landfill=true lays tile ghosts under the belts)')
  water={}
  -- One call lays at most 2048 belts and undergrounds.
  fails(function() R2.plan(q,{from={x=0,y=0},to={x=1000,y=1050},via={{x=1000,y=0},{x=1000,y=500}}}) end,'the line needs 2051 belts and undergrounds; one call lays at most 2048')
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
  -- Asked for the right side, it starts on the free tile nearest the blocked one (within 2).
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0},['return']=true,return_side='right'}); eq(r['return'].side,'right'); eq(r['return'].from.x,19.5); eq(r['return'].from.y,1.5)
  for x=18,22 do for y=1,3 do blocked[key(x,y)]=true end end
  fails(function() R2.plan(q,{from={x=0,y=0},to={x=20,y=0},['return']=true,return_side='right'}) end,'no return line: right: its first tile (20.5,1.5) and the tiles within 2 of it are blocked or taken')
  blocked={}
  -- Its last tile walled in beside the first belt: it ends on a free tile within 2 of it.
  for _,c in ipairs({{-1,1},{-1,2},{0,2},{1,2},{1,1}}) do blocked[key(c[1],c[2])]=true end
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0},['return']=true,return_side='right'})
  local lastr
  for _,e in ipairs(r.entities) do if e.line=='return' then lastr=e end end
  assert(math.abs(lastr.position.x-0.5)<=2 and math.abs(lastr.position.y-1.5)<=2,'ends within 2 of (0.5,1.5)')
  eq(r['return'].to.x,lastr.position.x); eq(r['return'].to.y,lastr.position.y)
  blocked={}
  -- Its end walled in for good (thicker than a hop): the line ends at the nearest tile reached, short_of says so.
  for x=-10,10 do for y=-12,12 do
    if not ((y==0 and x>=0) or (x>=-2 and x<=2 and y>=1 and y<=3)) then blocked[key(x,y)]=true end
  end end
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0},['return']=true,return_side='right'})
  assert(r['return'].short_of and r['return'].short_of:find('tiles from its last tile (0.5,1.5) (no way nearer within the budget)',1,true),r['return'].short_of)
  tiles_={}
  for _,e in ipairs(r.entities) do
    local k=key(e.position.x,e.position.y)
    assert(not tiles_[k],'two entities on '..k); tiles_[k]=true
  end
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
  -- A goal closed in is named as such once the search has gone on a while (no full budget spent).
  for _,d in ipairs({{-1,0},{1,0},{0,-1},{0,1}}) do blocked[key(20+d[1],d[2])]=true end
  ok,err=pcall(R2.plan,q,{from={x=0,y=0},to={x=20,y=0}})
  assert(not ok and err:find('to (20.5,0.5) is closed in: no tile next to it can take the belt that would feed it',1,true),err)
  assert(err:find('1000 expansions',1,true),err)
  blocked={}
  -- ... or a few tiles around it that a thick ring closes in (no hop crosses it).
  for x=10,30 do for y=-10,10 do if math.abs(x-20)>2 or math.abs(y)>2 then if math.abs(x-20)<=8 and math.abs(y)<=8 then blocked[key(x,y)]=true end end end end
  ok,err=pcall(R2.plan,q,{from={x=0,y=0},to={x=20,y=0}})
  assert(not ok and err:find('is closed in: a line can reach it from only 24 tiles around it',1,true),err)
  blocked={}
  -- Via legs keep off the tiles of the legs before them (here the third leg crosses the first under ground).
  r=R2.plan(q,{from={x=0,y=0},to={x=6,y=-4},via={{x=12,y=0},{x=6,y=4}}})
  local tiles_={}
  for _,e in ipairs(r.entities) do
    local k=key(e.position.x,e.position.y)
    assert(not tiles_[k],'two entities on '..k); tiles_[k]=true
  end
  -- The return line crosses under the first where its side is blocked further than it can go round or hop
  -- (an underground is entered straight, so it steps a row out to turn into each crossing: apart counts those).
  for x=8,12 do for y=1,40 do blocked[key(x,y)]=true end end
  r=R2.plan(q,{from={x=0,y=0},to={x=20,y=0},['return']=true,return_side='right'})
  eq(r.route,'E21'); eq(r['return'].side,'right'); eq(r['return'].crossings,2); eq(r['return'].route,'W6 S1 W1 N1 uN2 W7 S1 uS2 W1 N1 W6')
  eq(r['return'].apart,12)
  tiles_={}
  for _,e in ipairs(r.entities) do
    local k=key(e.position.x,e.position.y)
    assert(not tiles_[k],'two entities on '..k); tiles_[k]=true
  end
  blocked={}
  -- A new underground pair never lands where another of its kind on the axis would pair with it:
  -- an unpaired entrance at (2,0) heading east keeps the hop over the wall at x=6 off row 0.
  local ug={}
  local surface3={
    can_place_entity=function(a) local k=key(a.position.x,a.position.y); return not blocked[k] and not ug[k] end,
    find_entities_filtered=function(f)
      if f.ghost_type then return {} end
      local out={}
      for _,e in pairs(ug) do out[#out+1]=e end
      return out
    end,
    get_tile=surface2.get_tile}
  local q3={surface=surface3,force=mine}
  ug[key(2,0)]={valid=true,type='underground-belt',name='underground-belt',position={x=2.5,y=0.5},direction=4,belt_to_ground_type='input',unit_number=7}
  for y=-40,40 do blocked[key(6,y)]=true end
  r=R2.plan(q3,{from={x=3,y=0},to={x=12,y=0}})
  for _,e in ipairs(r.entities) do if e.type then assert(e.position.y~=0.5,'an underground on row 0 at '..e.position.x) end end
  assert(r.undergrounds==1,r.route)
  -- Without it, the hop stays on row 0.
  ug={}
  r=R2.plan(q3,{from={x=3,y=0},to={x=12,y=0}})
  eq(r.route,'E2 uE5 E2')
  blocked={}
end
-- Opt-in hazard tiles are barriers, including every underground span and a return line.
reset()
local probes=0
local safe=dofile('mod/agent-harness_0.1.0/route.lua'){
  position=function(v) return v end,directions={north=0,east=4,south=8,west=12},
  chunk_of=function(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end,
  route_guard=function(_,value)
    if value==nil or value==false then return nil end
    return function(x,y)
      probes=probes+1
      if (x-40)^2+y*y<30^2 then return 'spawner clearance' end
    end,'test clearance',60,{chunks=1}
  end}
local function clear_plan(plan)
  local entrance
  for _,e in ipairs(plan.entities) do
    local x,y=e.position.x-0.5,e.position.y-0.5
    assert((x-40)^2+y*y>=30^2,'belt inside hazard')
    if e.type=='input' then entrance=e
    elseif e.type=='output' then
      assert(entrance)
      local dx,dy=e.position.x-entrance.position.x,e.position.y-entrance.position.y
      local n=math.abs(dx)+math.abs(dy)
      for i=1,n-1 do
        local xx,yy=entrance.position.x-0.5+dx*i/n,entrance.position.y-0.5+dy*i/n
        assert((xx-40)^2+yy*yy>=30^2,'underground crosses hazard')
      end
    end
  end
end
local guarded=safe.plan(p,{from={x=0,y=0},to={x=80,y=0},avoid_enemies=8,['return']=true})
clear_plan(guarded); eq(guarded.avoid_enemies,'test clearance'); eq(guarded.cost.hazard_chunks,1)
assert(guarded.tiles>80,'detour leaves the original 24-tile search margin')
fails(function() safe.plan(p,{from={x=40,y=0},to={x=80,y=0},avoid_enemies=8}) end,'from')
fails(function() safe.plan(p,{from={x=0,y=0},to={x=40,y=0},avoid_enemies=8}) end,'inside enemy clearance')
fails(function() safe.plan(p,{from={x=0,y=0},to={x=80,y=0},via={{x=40,y=0}},avoid_enemies=8}) end,'via 1')
local before=probes
local direct=safe.plan(p,{from={x=0,y=0},to={x=80,y=0},avoid_enemies=false})
eq(direct.tiles,81); eq(probes,before,'disabled guard does no hazard reads')
-- The real avoidance guide splits a 480-tile line around a spawner within the existing A* budget.
reset()
local old_find=surface.find_entities_filtered
surface.index=1; mine.name='player'
local enemy={name='enemy'}
game={tick=1,forces={mine,enemy}}
local hazards={{valid=true,name='biter-spawner',type='unit-spawner',position={x=240.5,y=0.5},force=enemy}}
local reads=0
surface.find_entities_filtered=function(f)
  if type(f.force)=='table' and f.force[1]=='enemy' then reads=reads+1; return hazards end
  return old_find(f)
end
local memory={}
local avoid=require('avoid'){state=function() return memory end,charted=function() return true end}
local guided=dofile('mod/agent-harness_0.1.0/route.lua'){
  position=function(v) return v end,directions={north=0,east=4,south=8,west=12},
  chunk_of=function(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end,route_guard=avoid.route_guard}
local long=guided.plan(p,{from={x=0,y=0},to={x=480,y=0},avoid_enemies=8})
assert(long.avoidance_waypoints>0); assert(long.cost.expansions<=8000); assert(reads<400,'chunk-local hazard reads')
for _,e in ipairs(long.entities) do assert((e.position.x-240.5)^2+(e.position.y-0.5)^2>=48^2) end
-- The chart check is before the engine query: hidden enemies do not affect the guide.
local hidden=require('avoid'){state=function() return {} end,charted=function() return false end}
local block,_,_,_,guide=hidden.route_guard(p,8)
local n=reads; eq(block(240,0),nil); eq(#guide({x=0,y=0},{x=480,y=0}),0); eq(reads,n)
surface.find_entities_filtered=old_find
print('route: ok')
