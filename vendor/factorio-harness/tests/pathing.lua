-- Run from repository root: lua tests/pathing.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),tostring(text)..' lacks '..part) end
game={tick=100}
local paths={}
local P=dofile('mod/agent-harness_0.1.0/pathing.lua'){paths=function() return paths end}
local function path(points) local out={} for i,q in ipairs(points) do out[i]={position={x=q[1],y=q[2]}} end return out end
-- prefer: the belt-free path when it is at most 6 tiles or a quarter longer.
local straight=path{{0,0},{20,0}}                 -- 20 tiles
local around=path{{0,0},{0,4},{20,4},{20,0}}      -- 28 tiles
local far=path{{0,0},{0,10},{20,10},{20,0}}       -- 40 tiles
local p1,avoided=P.prefer(straight,around); eq(p1,straight); eq(avoided,false)
local short=path{{0,0},{0,2},{20,2},{20,0}}       -- 24 tiles
p1,avoided=P.prefer(straight,short); eq(p1,short); eq(avoided,true)
p1,avoided=P.prefer(nil,far); eq(p1,far); eq(avoided,true)
p1,avoided=P.prefer(straight,nil); eq(p1,straight); eq(avoided,false)
eq(P.prefer(nil,nil),nil)
eq(P.length(around),28)
-- The ladder's levels: padded tile grid with a belt-free twin, own box from a
-- tile centre, half-tile grid, quarter-tile grid with a wider goal.
eq(#P.LEVELS,4); eq(P.LEVELS[1].avoid,true); eq(P.LEVELS[1].pad,0.15); eq(P.LEVELS[2].centre,true); eq(P.LEVELS[3].res,1); eq(P.LEVELS[4].res,2); eq(P.LEVELS[4].wide,3)
eq(P.half({prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}}}}),0.2)
eq(P.half({prototype={}}),0.2)
-- A walled pocket whose only gap is 0.3 tiles wide (shift08: Haiku's pocket by
-- the boiler row, 0.22-tile gaps): closed for a 0.4-tile character, open for a 0.2-tile box.
local boxes={
  {name='steam-engine',box={0,0,1,10}},{name='steam-engine',box={5,0,6,10}},
  {name='boiler',box={1,0,2.85,1}},{name='pipe',box={3.15,0,5,1}},{name='assembling-machine-2',box={1,9,5,10}}}
local me={valid=true,type='character',name='character',position={x=3,y=5},prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}}}}
local surface={find_entities_filtered=function(f)
  local out={}
  if f.collision_mask=='player' then
    local a=f.area
    for _,b in ipairs(boxes) do
      local x0,y0,x1,y1=b.box[1],b.box[2],b.box[3],b.box[4]
      if x1>a[1][1] and x0<a[2][1] and y1>a[1][2] and y0<a[2][2] then
        out[#out+1]={valid=true,name=b.name,type='x',bounding_box={left_top={x=x0,y=y0},right_bottom={x=x1,y=y1}}}
      end
    end
    out[#out+1]=me
  end
  return out
end,find_tiles_filtered=function() return {} end}
local r=P.region(surface,{x=3,y=5},0.2,{ignore=me,goal={x=3,y=-5}})
eq(r.closed,true); eq(r.nearest.x,3); eq(r.nearest.y,1.25); eq(r.x0,1.25); eq(r.y1,8.75); eq(r.tiles,29)
eq(r.by[1],'steam-engine')
local open=P.region(surface,{x=3,y=5},0.1,{ignore=me})
eq(open.closed,false)
-- The trap checks (Gemini, shift09: a placement trapped the character). A
-- fake surface of entity boxes {name, box, type?, force?, unit?}.
local function fake(list)
  return {find_tiles_filtered=function() return {} end,find_entities_filtered=function(f)
    local out={}
    if f.collision_mask=='player' then
      local a=f.area
      for _,b in ipairs(list) do
        local x0,y0,x1,y1=b.box[1],b.box[2],b.box[3],b.box[4]
        if x1>a[1][1] and x0<a[2][1] and y1>a[1][2] and y0<a[2][2] then
          out[#out+1]={valid=true,name=b.name,type=b.type or 'wall',force=b.force,unit_number=b.unit,bounding_box={left_top={x=x0,y=y0},right_bottom={x=x1,y=y1}}}
        end
      end
    end
    return out
  end}
end
-- A pocket 4 tiles wide: walls left, right and below; the top open.
local pocket={{name='stone-wall',box={0,0,1,8}},{name='stone-wall',box={5,0,6,8}},{name='stone-wall',box={0,8,6,9}}}
local ps=fake(pocket)
eq(P.region(ps,{x=3,y=5},0.2,{window=16}).closed,false,'open at the top')
-- Planned: a lid on top closes it; it alone fills the last gap. A box elsewhere is not around it.
local lid={1,-0.2,5,0.2,'stone-wall','lid',base=true}
local far={20,20,21,21,'stone-wall','far',base=true}
local res=P.closes_in(ps,{x=3,y=5},0.2,{lid,far},{})
eq(#res.gaps,1); eq(res.gaps[1],lid); eq(#res.around,1); eq(res.region.closed,true); eq(res.region.tiles,28)
eq(P.area_text(res.region,0.2),'the area (1.3,0.5)-(4.8,7.8) (about 28 tiles) has no gap the character (0.4 tiles wide) fits through; around it: stone-wall')
-- Two lid halves 0.42 apart (two lone pipes): a 0.4 character slips through; joined (a piece between
-- them that stands only while both do) they close it, and without either the gap is back.
local a={1,-0.29,3.29,0.29,'pipe','a',base=true}
local b={3.71,-0.29,5,0.29,'pipe','b',base=true}
eq(P.closes_in(ps,{x=3,y=5},0.2,{a,b},{}),nil,'0.42 apart: open')
local seam={3.29,-0.29,3.71,0.29,'pipe','a',ids={'a','b'}}
res=P.closes_in(ps,{x=3,y=5},0.2,{a,b,seam},{})
eq(#res.gaps,2,'without either one a gap out stays')
-- Closed in already: said so, nothing blamed on the plan.
local shut=fake({{name='stone-wall',box={0,0,1,8}},{name='stone-wall',box={5,0,6,8}},{name='stone-wall',box={0,8,6,9}},{name='stone-wall',box={1,-1,5,0}}})
res=P.closes_in(shut,{x=3,y=5},0.2,{far},{}); eq(res.already,true)
-- Our gate opens for the character: no wall; another force's gate is one.
local gated=fake({{name='stone-wall',box={0,0,1,8}},{name='stone-wall',box={5,0,6,8}},{name='stone-wall',box={0,8,6,9}},
  {name='stone-wall',box={1,-1,2.7,0}},{name='stone-wall',box={3.3,-1,5,0}},{name='gate',type='gate',force='us',box={2.7,-1,3.3,0}}})
eq(P.region(gated,{x=3,y=5},0.2,{force='us',window=16}).closed,false); eq(P.region(gated,{x=3,y=5},0.2,{force='them',window=16}).closed,true)
-- After a build: closed now, open without what was just built; that one filled the last gap.
local built={valid=true,unit_number=9,name='stone-wall',position={x=3,y=-0.5}}
local after=fake({{name='stone-wall',box={0,0,1,8}},{name='stone-wall',box={5,0,6,8}},{name='stone-wall',box={0,8,6,9}},{name='stone-wall',box={1,-1,5,0},unit=9}})
res=P.closed_by(after,{x=3,y=5},0.2,{built},{})
eq(#res.gaps,1); eq(res.gaps[1],built); eq(res.region.closed,true)
eq(P.closed_by(after,{x=3,y=5},0.2,{{valid=true,unit_number=4,name='pipe',position={x=20,y=20}}},{}),nil,'closed before that build too')
eq(P.closed_by(ps,{x=3,y=5},0.2,{built},{}),nil,'still open')
-- Farthest step first: the open pocket ends at the window edge, the closed one is flooded whole.
eq(P.region(ps,{x=3,y=5},0.2,{window=16}).tiles<28,true)

-- Giving up closed in: why names the area and what closes it in; nearest reachable to the goal.
local p={index=7,position={x=3,y=5},surface=surface,character=me,force={}}
local nav={position={x=3,y=-5},tolerance=0.5}
P.give_up(p,nav)
eq(nav.path_state,'digging'); P.dig_step(p,nav) -- nothing here the character can mine: why stays
eq(nav.path_state,'unreachable'); eq(nav.reachable.y,1.25)
eq(nav.why,'closed in: the character (0.4 tiles wide) fits through no gap out of the area (1.3,1.3)-(4.8,8.8) (about 29 tiles); around it: steam-engine, assembling-machine-2, boiler, pipe')
-- The goal inside the area it can reach: steer (the grids missed a route there).
nav={position={x=4,y=8},tolerance=0.5}
P.give_up(p,nav)
eq(nav.path_state,'failed'); has(nav.blind,'inside the area it can reach')
-- Not closed in: one wide request; its end is the nearest reachable point.
boxes={}
local asked={}
surface.request_path=function(a) asked[#asked+1]=a; return 50+#asked end
surface.find_non_colliding_position=function(_,pos) return pos end
nav={position={x=40,y=5},tolerance=0.5}
P.give_up(p,nav)
eq(nav.path_state,'probing'); eq(asked[1].radius,27.75); eq(paths[51],7)
P.on_finished(p,nav,{id=51,path=path{{3,5},{12,5}}})
eq(nav.reachable.x,12); eq(nav.why,'no path for the character to (40,5) on the tile, half- or quarter-tile grid')
-- Its end is 28 tiles off (Grok, shift10 06:20): a spot within build reach (10) is asked for, first a
-- box with room to turn on the tile grid, then the character's own box on the quarter-tile grid.
eq(nav.path_state,'probing'); eq(asked[2].radius,9); eq(asked[2].bounding_box[1][1],-0.35); eq(asked[2].path_resolution_modifier,nil)
P.on_finished(p,nav,{id=52})
eq(nav.path_state,'probing'); eq(asked[3].radius,9); eq(asked[3].bounding_box[1][1],-0.2); eq(asked[3].path_resolution_modifier,2)
P.on_finished(p,nav,{id=53,path=path{{3,5},{31,5}}})
eq(nav.path_state,'unreachable'); eq(nav.spot.pos.x,31); eq(nav.spot.room,true); eq(nav.spot.reach,10)
eq(nav.reachable.x,31,'the spot is nearer than the first probe\'s end')
-- In a gap 0.66 tiles wide (the character's 0.4 box fits, a 0.7 one with room to turn does not), room only out of build reach: named with what hems it in.
boxes={{name='pipe',box={30,-6,30.67,16}},{name='offshore-pump',box={31.33,-6,32,16}}}
asked={}
nav={position={x=40,y=5},tolerance=0.5}
P.give_up(p,nav); P.on_finished(p,nav,{id=50+#asked}); P.on_finished(p,nav,{id=50+#asked}); P.on_finished(p,nav,{id=50+#asked,path=path{{3,5},{31,5}}})
eq(nav.path_state,'unreachable'); eq(nav.spot.room,nil); eq(nav.spot.pos.x,31); eq(nav.spot.width,0.7)
eq(nav.spot.by[1],'pipe (30.3,5)'); eq(nav.spot.by[2],'offshore-pump (31.7,5)')
-- Room joined to the gap within build reach: that spot instead.
boxes={{name='pipe',box={30,4,30.67,6}},{name='offshore-pump',box={31.33,4,32,6}}}
asked={}
nav={position={x=40,y=5},tolerance=0.5}
P.give_up(p,nav); P.on_finished(p,nav,{id=50+#asked}); P.on_finished(p,nav,{id=50+#asked}); P.on_finished(p,nav,{id=50+#asked,path=path{{3,5},{31,5}}})
eq(nav.spot.room,true); assert(nav.spot.pos.y<4 or nav.spot.pos.y>6,'out of the gap: '..nav.spot.pos.y); assert(((nav.spot.pos.x-40)^2+(nav.spot.pos.y-5)^2)^0.5<=9.75)
boxes={}
-- The first probe's end within build reach and with room: named at once.
asked={}
nav={position={x=14,y=5},tolerance=0.5}
P.give_up(p,nav); P.on_finished(p,nav,{id=50+#asked,path=path{{3,5},{8,5}}})
eq(nav.path_state,'unreachable'); eq(#asked,1); eq(nav.spot.pos.x,8); eq(nav.spot.room,true)
-- No path request finds a way, and the target is too far for the character's own steps (a 64-tile box): none.
asked={}
nav={position={x=60,y=5},tolerance=0.5}
P.give_up(p,nav); P.on_finished(p,nav,{id=50+#asked})
eq(nav.reachable,nil); eq(nav.why,'no path request found a way for the character to (60,5), nor to anywhere within 42 tiles of it')
P.on_finished(p,nav,{id=50+#asked}); P.on_finished(p,nav,{id=50+#asked})
eq(nav.path_state,'unreachable'); eq(nav.spot.none,true); eq(nav.spot.goal.x,60)
-- Within the box, ground the requests missed (a target in water fails them all): the character's own steps find a
-- spot with room, at most 9.25 tiles off (build reach less the arrival radius and a quarter tile).
asked={}
nav={position={x=40,y=5},tolerance=0.5}
P.give_up(p,nav); for _=1,3 do P.on_finished(p,nav,{id=50+#asked}) end
eq(nav.path_state,'searching')
while nav.path_state=='searching' do P.search_tick(p,nav) end
eq(nav.spot.searched,true); eq(nav.spot.room,true); assert(((nav.spot.pos.x-40)^2+(nav.spot.pos.y-5)^2)^0.5<=9.25,'within 9.25')
-- The copy of world n's slit (round0620c): a lake round (60.5,140.5), a pier from the south ending 8.5 tiles from it,
-- two assembling machines across the pier's end leaving a 0.6-tile slit. No path request ends in the slit (read on
-- the copy); the character's own steps do: the only spots within build reach of the lake's centre lie in it.
boxes={{name='deepwater',box={46,126,57,155}},{name='deepwater',box={63,126,75,155}},{name='deepwater',box={57,126,63,149}},
  {name='assembling-machine-1',box={57.3,149.3,59.7,151.7}},{name='assembling-machine-1',box={60.3,149.3,62.7,151.7}}}
local found=P.reach_search(surface,{x=60.5,y=160.5},0.2,{x=60.5,y=140.5},9.75,{ignore=me})
eq(found.room,false); eq(found.spot.x,60); assert(found.spot.y<=150.25 and found.spot.y>=149.2,'in the slit: '..found.spot.y)
eq(found.trail[1].x,60.5); eq(found.trail[#found.trail].y,found.spot.y)
for i=2,#found.trail do local q=found.trail[i]; assert(q.y>=found.spot.y,'the trail comes down the pier') end
-- Too far apart for the 64-tile box: none.
eq(P.reach_search(surface,{x=0,y=200},0.2,{x=60.5,y=140.5},9.75,{ignore=me}),nil)
-- The unreachable walk names it, through the probes that find nothing (none ends in the slit).
p.position={x=60.5,y=160.5}
asked={}
nav={position={x=60.5,y=140.5},tolerance=0.5}
P.give_up(p,nav); P.on_finished(p,nav,{id=50+#asked}); P.on_finished(p,nav,{id=50+#asked}); P.on_finished(p,nav,{id=50+#asked})
-- The search runs a slice a tick (path_state searching) while the character stands.
eq(nav.path_state,'searching'); local slices=0
while nav.path_state=='searching' do P.search_tick(p,nav); slices=slices+1 end
assert(slices>=2,'more than one slice: '..slices)
eq(nav.path_state,'unreachable'); eq(nav.spot.searched,true); eq(nav.spot.room,nil); eq(nav.spot.pos.x,60); eq(nav.spot.via,nil)
local by=table.concat(nav.spot.by,'; ')
has(by,'assembling-machine-1 (58.5,150.5)'); has(by,'assembling-machine-1 (61.5,150.5)')
assert(((nav.spot.pos.x-60.5)^2+(nav.spot.pos.y-140.5)^2)^0.5<=9.25,'within 9.25')
-- squeeze=true walks it: the search's trail, waypoint by waypoint, when no path request found a route.
asked={}
nav={position={x=60,y=150},tolerance=0.5,squeeze=true}
P.give_up(p,nav)
eq(nav.path_state,'searching'); eq(nav.squeeze_tried,true)
while nav.path_state=='searching' do P.search_tick(p,nav) end
eq(nav.path_state,'trail'); eq(nav.reach,0.12); eq(nav.squeezed.from.y,160.5); assert(#nav.waypoints>=2,'a trail')
local last_wp=nav.waypoints[#nav.waypoints].position
assert(((last_wp.x-60)^2+(last_wp.y-150)^2)^0.5<=0.5,'the trail ends within the arrival radius')
eq(#asked,0,'no probe asked')
-- A squeeze search that finds nothing goes on as a give-up does: the probes.
asked={}
nav={position={x=60.5,y=140.5},tolerance=0.5,squeeze=true}
P.give_up(p,nav); eq(nav.path_state,'searching')
while nav.path_state=='searching' do P.search_tick(p,nav) end
eq(nav.path_state,'probing'); eq(#asked,1)
boxes={}
p.position={x=3,y=5}
-- Ungenerated ground: blind steering as before.
surface.is_chunk_generated=function() return false end
nav={position={x=400,y=5},tolerance=0.5}
P.give_up(p,nav); eq(nav.path_state,'failed'); eq(nav.blind,'ungenerated')
surface.is_chunk_generated=nil
-- The ladder: first level asks twice; both answers decide; failures climb.
p.surface.request_path=function(a) asked[#asked+1]=a; return 100+#asked end
asked={}
nav={position={x=20,y=0},tolerance=0.5}
P.request(p,nav)
eq(#asked,2); eq(asked[1].bounding_box[1][1],-0.35); eq(asked[2].collision_mask.layers.transport_belt,true); eq(nav.path_state,'pending')
P.on_finished(p,nav,{id=nav.path_id,path=straight}); eq(nav.path_state,'pending')
P.on_finished(p,nav,{id=nav.avoid_id,path=short}); eq(nav.path_state,'found'); eq(nav.waypoints,short); eq(nav.avoided,true); eq(nav.path_length,24)
-- The twin late: after 30 ticks the walk's own path is used.
asked={}
nav={position={x=20,y=0},tolerance=0.5}
P.request(p,nav)
P.on_finished(p,nav,{id=nav.path_id,path=straight})
game.tick=120; P.grace(p,nav); eq(nav.path_state,'pending')
game.tick=131; P.grace(p,nav); eq(nav.path_state,'found'); eq(nav.waypoints,straight); eq(nav.avoided,nil)
-- Both fail: climb to the character's own box from a free tile centre.
asked={}
game.tick=200
nav={position={x=20,y=0},tolerance=0.5}
P.request(p,nav)
P.on_finished(p,nav,{id=nav.path_id}); P.on_finished(p,nav,{id=nav.avoid_id})
eq(nav.path_level,1); eq(#asked,3); eq(asked[3].bounding_box[1][1],-0.2); eq(nav.paths_failed,1)
-- A path that ends where it started, the start inside a wide goal radius
-- (world n: Haiku's pocket 4.45 tiles from the goal, radius 4.5), is no route.
nav.asked_from={x=8.99,y=42.59}
eq(P.useless({position={x=6.5,y=38.9},tolerance=0.5,asked_from={x=8.99,y=42.59}},path{{8.99,42.59}}),true)
eq(P.useless({position={x=6.5,y=38.9},tolerance=0.5,asked_from={x=30,y=70}},path{{30,70},{7,39}}),false)
-- beside a goal boxed in by entities: kept
eq(P.useless({position={x=5,y=5},tolerance=0.5,asked_from={x=4,y=4}},path{{4,4}}),false)
-- Busy: try again later.
P.on_finished(p,nav,{id=nav.path_id,try_again_later=true}); eq(nav.path_state,'busy')
-- Off-belt arrival: belts on (9,0) and (10,0); the nearest free tile without one.
local belts={['9:0']=true,['10:0']=true}
local blocked={['9:-1']=true}
surface.find_entities_filtered=function(f)
  local x,y=math.floor(f.area[1][1]+0.01),math.floor(f.area[1][2]+0.01)
  if f.type then return belts[x..':'..y] and {{valid=true,name='transport-belt'}} or {} end
  if f.collision_mask=='player' then
    local cx,cy=math.floor((f.area[1][1]+f.area[2][1])/2),math.floor((f.area[1][2]+f.area[2][2])/2)
    return blocked[cx..':'..cy] and {{valid=true,name='stone-furnace',type='furnace'}} or {}
  end
  return {}
end
surface.count_tiles_filtered=function() return 0 end
p.position={x=9.8,y=0.5}
local spot,within=P.off_belt_spot(p,{x=10,y=0.5},2)
eq(spot.x,9.5); eq(spot.y,1.5); eq(within,true)
-- none within the arrival radius: the nearest one within 3 tiles of the character
spot,within=P.off_belt_spot(p,{x=10,y=0.5},0.5)
eq(spot.x,9.5); eq(spot.y,1.5); eq(within,false)
eq(P.belt_at(surface,{x=9.8,y=0.5}).name,'transport-belt'); eq(P.belt_at(surface,{x=8.5,y=0.5}),nil)
-- Sol (shift09 03:12): on Gleba two assembling machines 0.6 tiles apart under
-- a pipe row (the boxes as world n reports them, 2.0 pipes reaching their
-- neighbours). The walk to (55,21) ended in that gap and no path led out.
local function box_surface(list)
  return {find_entities_filtered=function(f)
    local out={}
    if f.collision_mask=='player' then
      local a=f.area
      for _,b in ipairs(list) do
        if b[3]>a[1][1] and b[1]<a[2][1] and b[4]>a[1][2] and b[2]<a[2][2] then
          out[#out+1]={valid=true,name=b[5],type=b[6] or 'x',minable=true,force='ours',position={x=(b[1]+b[3])/2,y=(b[2]+b[4])/2},
            bounding_box={left_top={x=b[1],y=b[2]},right_bottom={x=b[3],y=b[4]}}}
        end
      end
    end
    return out
  end,find_tiles_filtered=function() return {} end}
end
local gleba={
  {52.3008,21.3008,54.6992,23.6992,'assembling-machine-2'},{55.3008,21.3008,57.6992,23.6992,'assembling-machine-2'},
  {53.2109,20.2109,53.9883,20.9883,'pipe'},{54.0117,20.2109,54.9883,20.7891,'pipe'},{55.0117,20.0117,55.9883,20.7891,'pipe'},{56.0117,20.2109,56.7891,20.9883,'pipe'},
  {53.3516,24.3516,53.6484,24.6484,'inserter'},{55.3516,24.3516,55.6484,24.6484,'small-electric-pole'}}
local gs=box_surface(gleba)
-- (55,21) with the arrival radius 0.5: the character's box fits there, a box with room to turn nowhere near.
local sq=P.in_gap(gs,{x=55,y=21},0.2,0.5)
assert(sq,'the goal is in a gap')
has(table.concat(sq.by,', '),'assembling-machine-2 (53.5,22.5)'); has(table.concat(sq.by,', '),'assembling-machine-2 (56.5,22.5)')
-- Room near the goal, or a goal inside an entity (a chest, a machine's centre): not a gap.
eq(P.in_gap(gs,{x=60,y=30},0.2,0.5),nil)
eq(P.in_gap(gs,{x=55,y=25.5},0.2,0.5),nil)
eq(P.in_gap(box_surface({{9.65,9.65,10.35,10.35,'wooden-chest'}}),{x=10,y=10},0.2,0.5),nil)
eq(P.in_gap(gs,{x=53.5,y=22.5},0.2,0.5),nil)
-- Squeezed where Sol stood (54.19,20.99): the flood's trail leads along the
-- slot and down the gap to the nearest spot with room to turn.
local r2=P.region(gs,{x=54.19,y=20.99},0.2,{open_pad=0.15})
assert(r2.open and r2.open.y>=24,'room to turn below the machines')
eq(r2.trail[1].x,54.25); eq(r2.trail[1].y,21)
for i=2,#r2.trail do
  local a,b=r2.trail[i-1],r2.trail[i]
  for k=0,20 do
    local x,y=a.x+(b.x-a.x)*k/20,a.y+(b.y-a.y)*k/20
    for _,bx in ipairs(gleba) do assert(not (x+0.2>bx[1] and x-0.2<bx[3] and y+0.2>bx[2] and y-0.2<bx[4]),'trail clear at '..x..','..y) end
  end
end
-- escape: the walk follows that trail first, then asks for its path again.
local sol={index=9,position={x=54.19,y=20.99},surface=gs,force={},
  character={valid=true,name='character',type='character',prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}}}}}
nav={position={x=61,y=20},tolerance=0.5}
eq(P.escape(sol,nav),true); eq(nav.path_state,'escape'); eq(nav.escapes,1); eq(nav.reach,0.12)
eq(nav.waypoints[#nav.waypoints].position.y,r2.open.y); eq(nav.escape_first.x,54.19)
asked={}; gs.request_path=function(a) asked[#asked+1]=a; return 300+#asked end
P.escaped(sol,nav); eq(nav.path_state,'pending'); eq(nav.path_level,0); eq(nav.escaped_to.y,r2.open.y); eq(nav.reach,nil); eq(#asked,2)
-- Room to turn where it stands: nothing to escape from.
sol.position={x=60,y=30}
eq(P.escape(sol,{position={x=61,y=20},tolerance=0.5}),false)
-- The tile-centre start: the nearest free centre past the pipes (53.5,19.5) is
-- not taken (every path from there stalled at the pipes); one in reach is.
sol.position={x=54.19,y=20.99}
gs.find_non_colliding_position=function() return {x=53.5,y=19.5} end
local st=P.start_centre(sol); eq(st.x,54.19); eq(st.y,20.99)
gs.find_non_colliding_position=function() return {x=54.5,y=21.0} end
eq(P.start_centre(sol).x,54.5)
-- Closed in by our pipes: give_up names the pipe whose mining opens a way out.
local pen={{0,0,4,0.8,'pipe'},{0,3.2,4,4,'pipe'},{0,0.8,0.8,3.2,'pipe'},{3.2,0.8,4,3.2,'pipe'}}
local ps=box_surface(pen)
local closed=P.region(ps,{x=2,y=2},0.2)
eq(closed.closed,true)
local dug=P.dig(ps,{x=2,y=2},0.2,{force='ours'})
assert(dug and #dug.mine==1 and dug.mine[1].name=='pipe','one pipe to mine')
local penned={index=9,position={x=2,y=2},surface=ps,force='ours',character=sol.character}
ps.is_chunk_generated=function() return true end
nav={position={x=20,y=2},tolerance=0.5}
P.give_up(penned,nav)
eq(nav.path_state,'digging'); has(nav.why,'closed in: ') -- the dig runs the next tick
P.dig_step(penned,nav)
eq(nav.path_state,'unreachable'); has(nav.why,'; mining pipe ('); has(nav.why,') opens a way out to ('); eq(nav.dig.mine[1].name,'pipe'); eq(nav.region.seen,nil); eq(nav.dig_area,nil)
-- Cliffs all round: no way out by mining.
local cliffs={{0,0,4,0.8,'cliff','cliff'},{0,3.2,4,4,'cliff','cliff'},{0,0.8,0.8,3.2,'cliff','cliff'},{3.2,0.8,4,3.2,'cliff','cliff'}}
local cs=box_surface(cliffs)
eq(P.dig(cs,{x=2,y=2},0.2,{force='ours'}),nil)
print('pathing: ok')
