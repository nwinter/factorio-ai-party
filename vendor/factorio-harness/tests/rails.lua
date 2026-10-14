-- Run from repository root: lua tests/rails.lua
-- rails.lua (rail_route, train_stop) and the train readback (trains.lua) against a fake engine. The piece table
-- is the game's (LuaRailEnd.get_rail_extensions on 2.0.77); the fake surface blocks a piece whose turned box
-- covers a blocked tile, lets the forced check through trees and water (as the engine does for ghosts), and
-- counts water tiles for the tile check.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={build_check_type={manual_ghost=1},train_state={on_the_path=0,no_schedule=1,no_path=2,arrive_signal=3,wait_signal=4,
  arrive_station=5,wait_station=6,manual_control_stop=7,manual_control=8,destination_full=9},signal_state={open=0,closed=1,reserved=2}}
prototypes={entity={['straight-rail']={items_to_place_this={{name='rail',count=1}}},['half-diagonal-rail']={items_to_place_this={{name='rail',count=2}}},
  ['curved-rail-a']={items_to_place_this={{name='rail',count=3}}},['curved-rail-b']={items_to_place_this={{name='rail',count=3}}},
  locomotive={type='locomotive'},['cargo-wagon']={type='cargo-wagon'},['train-stop']={type='train-stop'}},item={}}
local dirs={north=0,northnortheast=1,northeast=2,eastnortheast=3,east=4,eastsoutheast=5,southeast=6,southsoutheast=7,south=8,
  southsouthwest=9,southwest=10,westsouthwest=11,west=12,westnorthwest=13,northwest=14,northnorthwest=15}
local R=dofile('mod/agent-harness_0.1.0/rails.lua'){position=function(v) return {x=v.x,y=v.y} end,directions=dirs,
  chunk_of=function(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end}

-- The world: blocked tiles (a building), trees, water, rails and signals of ours, uncharted chunks east of x=uncharted.
local hard,trees,water,rails,signals,uncharted,checks={},{},{},{},{},nil,0
local function key(x,y) return x*1000003+y end
local function reset() hard,trees,water,rails,signals,uncharted={},{},{},{},{},nil end
local function rect(set,x0,y0,x1,y1) for x=x0,x1 do for y=y0,y1 do set[key(x,y)]=true end end end
local function covers(set,ob)
  for x=math.floor(ob.left_top.x),math.ceil(ob.right_bottom.x)-1 do
    for y=math.floor(ob.left_top.y),math.ceil(ob.right_bottom.y)-1 do
      if set[key(x,y)] and R.overlaps(ob,x,y,x+1,y+1) then return true end
    end
  end
  return false
end
local surface={platform=nil}
function surface.can_place_entity(a)
  checks=checks+1
  local ob=R.box(a.name,a.position,a.direction)
  if covers(hard,ob) then return false end
  if covers(trees,ob) or covers(water,ob) then return a.forced==true end
  return true
end
function surface.count_tiles_filtered(f)
  local n=0
  for x=math.floor(f.area.left_top.x),math.ceil(f.area.right_bottom.x)-1 do
    for y=math.floor(f.area.left_top.y),math.ceil(f.area.right_bottom.y)-1 do if water[key(x,y)] then n=n+1 end end
  end
  return n
end
function surface.find_tiles_filtered(f)
  local out={}
  for x=math.floor(f.area.left_top.x),math.ceil(f.area.right_bottom.x)-1 do
    for y=math.floor(f.area.left_top.y),math.ceil(f.area.right_bottom.y)-1 do
      if water[key(x,y)] then out[#out+1]={name='water',position={x=x,y=y},prototype={collision_mask={layers={water_tile=true}}}} end
    end
  end
  return out
end
local function inside(e,area) return e.position.x>=area.left_top.x and e.position.x<=area.right_bottom.x and e.position.y>=area.left_top.y and e.position.y<=area.right_bottom.y end
function surface.find_entities_filtered(f)
  local out={}
  if f.type and type(f.type)=='table' and f.type[1]=='straight-rail' or f.name=='straight-rail' then
    for _,e in ipairs(rails) do if not e.ghost and inside(e,f.area) and (not f.name or e.name==f.name) then out[#out+1]=e end end
  elseif f.ghost_type and f.ghost_type[1]=='straight-rail' or f.ghost_name=='straight-rail' then
    for _,e in ipairs(rails) do if e.ghost and inside(e,f.area) and (not f.ghost_name or e.ghost_name==f.ghost_name) then out[#out+1]=e end end
  elseif f.type and type(f.type)=='table' and f.type[1]=='rail-signal' then
    for _,e in ipairs(signals) do if inside(e,f.area) then out[#out+1]=e end end
  elseif f.ghost_type then
  elseif f.area and not f.type then
    -- What blocks a piece: a building on a hard tile.
    for x=math.floor(f.area.left_top.x),math.ceil(f.area.right_bottom.x)-1 do
      for y=math.floor(f.area.left_top.y),math.ceil(f.area.right_bottom.y)-1 do
        if hard[key(x,y)] and #out<3 then
          out[#out+1]={valid=true,type='assembling-machine',name='assembling-machine-2',position={x=x+0.5,y=y+0.5},force=nil,
            bounding_box={left_top={x=x,y=y},right_bottom={x=x+1,y=y+1}}}
        end
      end
    end
  end
  return out
end
local force={is_chunk_charted=function(_,c) return not (uncharted and c.x*32>=uncharted) end}
local p={surface=surface,force=force}
local function rail(name,x,y,d,ghost)
  local e={valid=true,name=ghost and 'entity-ghost' or name,ghost_name=ghost and name or nil,type=ghost and 'entity-ghost' or name,
    position={x=x,y=y},direction=d,ghost=ghost}
  rails[#rails+1]=e; return e
end
local function plan(a) checks=0; return R.plan(p,a) end

-- The piece table: every extension's piece has the end it was laid from (heading back) and the new end.
for d=0,15 do
  for _,m in ipairs(R.EXT[d]) do
    local ends=R.ends_of(m[1],{x=m[3],y=m[4]},m[2])
    local back,new=false,false
    for _,en in ipairs(ends) do
      if en.x==0 and en.y==0 and en.d==R.opposite(d) then back=true end
      if en.x==m[5] and en.y==m[6] and en.d==m[7] then new=true end
    end
    assert(back and new,m[1]..' '..m[2]..' from heading '..d..' does not join its ends')
    -- Ends of a heading sit on that heading's grid (here relative to an end at 0,0 of heading d).
    local pd,pg=R.PARITY[d],R.PARITY[m[7]]
    eq((m[5]+pd[1])%2,pg[1],'x parity of heading '..m[7]); eq((m[6]+pd[2])%2,pg[2],'y parity of heading '..m[7])
  end
end
-- Signals sit on the right of trains leaving an end: east of a northbound line, south of an eastbound one.
eq(R.SIGNAL[0][1],1.5); eq(R.SIGNAL[4][2],1.5); eq(R.SIGNAL[8][1],-1.5); eq(R.SIGNAL[12][2],-1.5)

-- Open ground straight north: one run of straight pieces, two tiles each.
reset()
local r=plan({from={x=0,y=0},to={x=0,y=-100}})
eq(r.out.route,'N100'); eq(r.out.pieces['straight-rail'],50); eq(r.out.items.rail,50); eq(r.out.length,100)
eq(r.out.start.heading,'north'); eq(r.out['end'].heading,'north'); eq(#r.entities,50)
eq(r.entities[1].name,'straight-rail'); eq(r.entities[1].direction,'north')
assert(r.out.cost.placement_checks<400,'open ground stays cheap: '..r.out.cost.placement_checks)
-- A diagonal target: curves and half-diagonals, and the rail count is the pieces' own (curves 3, half-diagonals 2).
r=plan({from={x=0,y=0},to={x=100,y=-100}})
local rails_n=(r.out.pieces['straight-rail'] or 0)+2*(r.out.pieces['half-diagonal-rail'] or 0)+3*((r.out.pieces['curved-rail-a'] or 0)+(r.out.pieces['curved-rail-b'] or 0))
eq(r.out.items.rail,rails_n)
assert(((r.out['end'].position.x-100)^2+(r.out['end'].position.y+100)^2)^0.5<=2,'ends within 2 tiles of to')
-- Each piece joins the one before it: walk the ends.
local function joined(entities)
  local prev
  for _,e in ipairs(entities) do
    if e.name~='rail-signal' then
      local ends=R.ends_of(e.name,e.position,dirs[e.direction])
      if prev then
        local ok=false
        for _,a in ipairs(prev) do for _,b in ipairs(ends) do
          if a.x==b.x and a.y==b.y and a.d==R.opposite(b.d) then ok=true end
        end end
        assert(ok,'piece '..e.name..' at '..e.position.x..','..e.position.y..' does not join the one before')
      end
      prev=ends
    end
  end
end
joined(r.entities)
-- from_direction fixes the first heading.
r=plan({from={x=0,y=0},to={x=0,y=-60},from_direction='north'})
eq(r.out.start.heading,'north')

-- A building in the way is routed around; the route never covers it.
reset(); rect(hard,-20,-60,20,-40)
r=plan({from={x=0,y=0},to={x=0,y=-100}})
joined(r.entities)
for _,e in ipairs(r.entities) do assert(not covers(hard,R.box(e.name,e.position,dirs[e.direction])),'over the building') end
assert(r.out.pieces['curved-rail-a'] or r.out.pieces['curved-rail-b'],'curves around it')
-- Trees: a ghost goes over them (marked for removal), counted.
reset(); rect(trees,-10,-50,10,-45)
r=plan({from={x=0,y=0},to={x=0,y=-100}})
assert((r.out.over_trees_or_rocks or 0)>0,'over trees')
-- Water lets the forced check through, but the route keeps off it.
reset(); rect(water,-40,-55,40,-45)
r=plan({from={x=-60,y=0},to={x=-60,y=-100}})
for _,e in ipairs(r.entities) do assert(not covers(water,R.box(e.name,e.position,dirs[e.direction])),'over water') end
eq(r.out.over_trees_or_rocks,nil)

-- A target in the water fails at once, saying what is there.
reset(); rect(water,-5,-105,5,-95)
fails(function() plan({from={x=0,y=0},to={x=0,y=-100}}) end,'no rail route: to (0,-100): blocked by water')
assert(checks<100,'the endpoint check is cheap: '..checks)
-- An uncharted target.
reset(); uncharted=64
fails(function() plan({from={x=0,y=0},to={x=100,y=0}}) end,'to (100,0): it is not charted')
-- A wall with its gap out of the search area: the budget runs out and the reply says where it got to and why.
reset(); rect(hard,-200,-52,200,-50)
local ok,err=pcall(plan,{from={x=0,y=0},to={x=0,y=-100}})
assert(not ok); has(err,'no rail route'); has(err,'the nearest end reached is'); has(err,'blocked there by assembling-machine-2')
has(err,'the search keeps within 32 tiles')
-- Limits.
reset()
fails(function() plan({from={x=0,y=0},to={x=1,y=-1}}) end,'from (0,0) is already within 2 tiles of to: no piece to lay')
fails(function() plan({from={x=0,y=0},to={x=0,y=-600}}) end,'each leg (from, via points, to) is at most 500 tiles')
fails(function() plan({from={x=0,y=0},to={x=0,y=-60},signals=2}) end,'signals is the spacing in tiles')
fails(function() plan({from={x=0,y=0},to={x=0,y=-60},from_direction='up'}) end,'from_direction must be a compass name')
fails(function() R.plan({surface={platform={}},force=force},{from={x=0,y=0},to={x=0,y=-60}}) end,'space platform')

-- Signals every 20 tiles at piece joints, on the right (east of a northbound line), facing back (south).
reset()
r=plan({from={x=0,y=0},to={x=0,y=-100},signals='every 20 tiles'})
eq(r.out.signals.count,4); eq(r.out.items['rail-signal'],4); has(r.out.signals.side,'on the right of trains heading from start to end')
local sigs={}
for _,e in ipairs(r.entities) do if e.name=='rail-signal' then sigs[#sigs+1]=e end end
eq(#sigs,4)
local line_x=r.entities[1].position.x
for _,sg in ipairs(sigs) do eq(sg.position.x,line_x+1.5); eq(sg.direction,'south') end
eq(sigs[1].position.y,r.out.start.position.y-20+0.5)

-- Via points: one leg each, the route passes each.
r=plan({from={x=0,y=0},via={{x=60,y=-60}},to={x=0,y=-120}})
eq(r.out.legs,2); joined(r.entities)
local near=false
for _,e in ipairs(r.entities) do if ((e.position.x-60)^2+(e.position.y+60)^2)^0.5<4 then near=true end end
assert(near,'passes the via point')

-- An existing free end near from: the line continues from it, heading on.
reset(); rail('straight-rail',1,1,0); rail('straight-rail',1,3,0)
r=plan({from={x=1,y=0},to={x=1,y=-40}})
eq(r.out.extends.mode,'continues the line'); eq(r.out.start.position.x,1); eq(r.out.start.position.y,0); eq(r.out.start.heading,'north')
eq(r.out.route,'N38') -- the end within 2 tiles of to
-- A rail ghost's end counts too, and to near a free end joins it head on.
reset(); rail('straight-rail',1,-41,0,true)
r=plan({from={x=1,y=0},to={x=1,y=-40}})
eq(r.out.joins.mode,'joins the end of a line'); eq(r.out.joins.ghost,true)
eq(r.out['end'].position.y,-40); eq(r.out['end'].heading,'north')
-- from in the middle of a line: it branches where two rails meet (no straight piece over the existing one).
reset(); for y=-19,19,2 do rail('straight-rail',1,y,0) end
local ends=R.ends_near(p,{x=1,y=0},2.5)
eq(ends[1].free,false)

-- train_stop spots: beside a straight north-south rail, east for trains heading north, west for south.
reset(); for y=-9,9,2 do rail('straight-rail',1,y,0) end
local c=R.stop_spot(p,{position={x=3,y=1}})
eq(c[1].heading,0); eq(c[1].spot.x,3); eq(c[1].spot.y,1)
c=R.stop_spot(p,{position={x=-1,y=-3}})
eq(c[1].heading,8); eq(c[1].spot.x,-1); eq(c[1].spot.y,-3)
c=R.stop_spot(p,{position={x=3,y=1},direction='south'})
eq(c[1].heading,8); eq(c[1].spot.x,-1)
-- East-west: south of the rail for trains heading east, north for west.
reset(); for x=21,39,2 do rail('straight-rail',x,1,4) end
c=R.stop_spot(p,{position={x=25,y=3}})
eq(c[1].heading,4); eq(c[1].spot.x,25); eq(c[1].spot.y,3)
c=R.stop_spot(p,{position={x=25,y=-1}})
eq(c[1].heading,12); eq(c[1].spot.y,-1)
fails(function() R.stop_spot(p,{position={x=25,y=3},direction='north'}) end,'no straight north-south or east-west rail')
fails(function() R.stop_spot(p,{position={x=25,y=3},direction='northeast'}) end,'direction (the way trains stopping there travel)')
-- A diagonal rail takes no stop; nothing near says so too.
reset(); rail('straight-rail',0,0,2)
fails(function() R.stop_spot(p,{position={x=1,y=1}}) end,'the rail near (1,1) is a diagonal straight-rail at (0,0)')
reset()
fails(function() R.stop_spot(p,{position={x=1,y=1}}) end,'no straight north-south or east-west rail or rail ghost of yours within 6 tiles')
-- A line signalled on one side only runs one way: the refusal says which signals.
reset(); for y=-9,9,2 do rail('straight-rail',1,y,0) end
signals[1]={valid=true,name='rail-signal',position={x=2.5,y=-5.5}}
c=R.stop_spot(p,{position={x=-1,y=1}})
has(R.line_signals(p,c[1]),'the rail signals of this line ((2.5,-5.5)) serve only trains heading north, so it runs one way and the game refuses a stop for trains heading south')
eq(R.line_signals(p,R.stop_spot(p,{position={x=3,y=1}})[1]),nil)
-- A built rail asks the engine: its segment's signals at either end, in and out.
defines.rail_direction={front=0,back=1}
local seg={valid=true,position={x=1,y=1},direction=0,
  get_rail_end=function(d) return {location={direction=d==0 and 0 or 8}} end,
  get_rail_segment_signal=function(d,in_else_out)
    -- One signal: the out signal at the north end (trains heading north leave there).
    if d==0 and in_else_out==false then return {position={x=2.5,y=-19.5}} end
  end}
has(R.line_signals(p,{heading=8,rail={e=seg}}),'the rail signals of this line ((2.5,-19.5)) serve only trains heading north')
eq(R.line_signals(p,{heading=0,rail={e=seg}}),nil)

-- The train readback: state names and why it waits.
local T=dofile('mod/agent-harness_0.1.0/trains.lua'){}
local function train(t)
  local loco={position={x=1,y=-5},get_fuel_inventory=function() return {get_contents=function() return t.fuel or {} end} end,
    burner={remaining_burning_fuel=t.burning or 0},surface=surface,force='player'}
  t.manual_mode=t.manual_mode or false
  t.speed=t.speed or 0
  t.locomotives={front_movers={loco},back_movers=t.back or {}}
  t.carriages=t.carriages or {loco,{}}
  t.front_stock=loco
  t.get_contents=function() return t.items or {} end
  t.get_fluid_contents=function() return {} end
  return t
end
local sch={current=2,records={{station='Iron',wait_conditions={{type='full'}}},{station='Base',wait_conditions={{type='time',ticks=600},
  {type='item_count',compare_type='or',condition={first_signal={name='iron-ore'},comparator='>',constant=100}}}}}}
local stop={valid=true,backer_name='Base',position={x=3,y=-5}}
local v=T.train_view(train({state=6,schedule=sch,station=stop,fuel={{name='coal',count=5}},items={{name='iron-ore',count=40}}}))
eq(v.state,'wait_station'); eq(v.why,'at stop Base (3,-5): waits for time 10s or item_count iron-ore > 100')
eq(v.schedule[1],'Iron: full'); eq(v.current,2); eq(v.at_stop.stop,'Base'); eq(v.cargo,'iron-ore 40'); eq(v.carriages,'1 locomotive, 1 wagon')
eq(v.fuel[1],'(1,-5): coal 5')
local sig={valid=true,name='rail-signal',position={x=2.5,y=-20.5},signal_state=1}
v=T.train_view(train({state=4,schedule=sch,signal=sig,fuel={{name='coal',count=5}}}))
eq(v.why,'stopped at rail-signal (2.5,-20.5) (closed)')
-- No path, or every stop of that name full: the stops named, with limits and trains.
game={train_manager={get_train_stops=function(f)
  if f.station_name=='Base' then return {{position={x=3,y=-5},trains_count=1,trains_limit=1,connected_rail={}},{position={x=50,y=-5},trains_count=0,trains_limit=4294967295}} end
  return {}
end}}
v=T.train_view(train({state=9,schedule=sch,fuel={{name='coal',count=5}}}))
eq(v.why,'every stop named Base is at its train limit (2: (3,-5) 1 train, limit 1; (50,-5) 0 trains, no limit, no rail beside it)')
v=T.train_view(train({state=2,schedule=sch,fuel={{name='coal',count=5}}}))
has(v.why,'no path to any stop named Base (2: '); has(v.why,'its locomotives all face its front, so it drives forward only')
v=T.train_view(train({state=2,schedule={current=1,records={{station='Nowhere'}}},fuel={{name='coal',count=5}}}))
eq(v.why,'no train stop is named Nowhere')
-- On its way with no fuel left: it stands still.
v=T.train_view(train({state=0,schedule=sch,speed=0}))
eq(v.why,'stands still: no fuel in its locomotives'); eq(v.fuel[1],'(1,-5): no fuel')
v=T.train_view(train({state=8}))
eq(v.state,'manual_control'); eq(v.why,'manual mode')

-- A turned rail ghost marks the trees its own box meets (construction.lua), not every tree in the box around it.
local C=dofile('mod/agent-harness_0.1.0/construction.lua'){real=function(q) return q end,directions=dirs}
local function tree(x,y)
  local t={valid=true,minable=true,type='tree',name='tree-01',position={x=x,y=y},marked=false,
    bounding_box={left_top={x=x-0.4,y=y-0.4},right_bottom={x=x+0.4,y=y+0.4}}}
  t.to_be_deconstructed=function() return t.marked end
  t.order_deconstruction=function() t.marked=true; return true end
  return t
end
-- On the diagonal near its end (outside the square box the old check used), and beside it.
local on,off=tree(1.2,-1.2),tree(1.2,1.2)
local cp={force='player',surface={find_entities_filtered=function() return {on,off} end}}
local g={valid=true,position={x=0,y=0},direction=2,ghost_prototype={collision_box={left_top={x=-0.7,y=-0.99},right_bottom={x=0.7,y=0.99}}},
  bounding_box={left_top={x=-0.7,y=-1.35},right_bottom={x=0.7,y=1.35},orientation=0.125}}
local found,newly=C.mark_obstacles(cp,g)
eq(newly,1); eq(on.marked,true); eq(off.marked,false)
-- A cliff under a ghost gets the mark too, as a player's placement gives it once cliff explosives are researched
-- (Sol 12:20: belts over cliffs that nothing would clear); it comes back as the third value, not counted with trees.
do
  local cliff={valid=true,type='cliff',name='cliff',position={x=0.5,y=1},marked=false,
    bounding_box={left_top={x=-1.5,y=0.6},right_bottom={x=2.5,y=1.4}}}
  cliff.to_be_deconstructed=function() return cliff.marked end
  cliff.order_deconstruction=function() cliff.marked=true; return true end
  local tech={researched=false}
  local cp2={force={technologies={['cliff-explosives']=tech}},surface={find_entities_filtered=function(f) return f.type=='cliff' and {cliff} or {} end}}
  local belt={valid=true,position={x=0.5,y=0.5},direction=0,ghost_prototype={collision_box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}},
    bounding_box={left_top={x=0.1,y=0.1},right_bottom={x=0.9,y=0.9}}}
  local _,n,cliffs=C.mark_obstacles(cp2,belt)
  eq(n,0); eq(#cliffs,0); eq(cliff.marked,false,'not researched: no mark')
  tech.researched=true
  _,n,cliffs=C.mark_obstacles(cp2,belt)
  eq(n,0); eq(#cliffs,1); eq(cliff.marked,true)
end
print('rails ok')
