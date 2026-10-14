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
-- Giving up closed in: why names the area and what closes it in; nearest reachable to the goal.
local p={index=7,position={x=3,y=5},surface=surface,character=me,force={}}
local nav={position={x=3,y=-5},tolerance=0.5}
P.give_up(p,nav)
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
eq(nav.path_state,'unreachable'); eq(nav.reachable.x,12); eq(nav.why,'no path for the character to (40,5) on the tile, half- or quarter-tile grid')
nav={position={x=40,y=5},tolerance=0.5}
P.give_up(p,nav); P.on_finished(p,nav,{id=52})
eq(nav.reachable,nil); eq(nav.why,'no path for the character to (40,5), nor to anywhere within 27 tiles of it')
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
print('pathing: ok')
