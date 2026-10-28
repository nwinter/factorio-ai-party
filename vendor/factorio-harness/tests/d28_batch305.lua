-- Run from repository root: lua tests/d28_batch305.lua
-- (d28 batch305 NR, Updates row nav-shared-routes, viewer Aurora; design in batch243's report item 5) cp1: the store of
-- found routes (sharedroutes.lua): fingerprints and corridor counts kept per leg, read again on a check (a changed
-- tile, a changed count, a chunk marked since: that leg stale; asked over MAX_AGE ago: stale in full), bounded storage
-- (MAX_ROUTES used longest ago first, MAX_LEGS, marks DIRTY_MAX), kept from spiderpath's and the drive's found paths.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
storage={}
local function state() return storage end
defines={events={on_built_entity=6,on_robot_built_entity=14,on_player_mined_entity=66,on_robot_mined_entity=67,on_entity_died=4,
  script_raised_built=90,script_raised_destroy=91,script_raised_revive=92,on_biter_base_built=93,on_player_built_tile=94,
  on_robot_built_tile=95,on_player_mined_tile=96,on_robot_mined_tile=97,script_raised_set_tiles=98}}
local player={name='player'}
game={tick=1000,forces={player=player}}
-- the map: tiles by "x,y" (default grass-1); entities with layers and a type
local tiles={}
local function paint(name,x1,y1,x2,y2) for x=x1,x2 do for y=y1,y2 do tiles[x..','..y]=name end end end
local reads=0
local surface={name='nauvis',index=1}
surface.get_tile=function(x,y)
  reads=reads+1
  local name=tiles[math.floor(x)..','..math.floor(y)] or 'grass-1'
  local w=name=='water' or name=='deepwater'
  return {valid=true,name=name,collides_with=function(l) return w and (l=='water_tile' or l=='player' or l=='doodad') or false end}
end
local ents={}
local function inside(q,area) return q.x>=area[1][1] and q.x<=area[2][1] and q.y>=area[1][2] and q.y<=area[2][2] end
local function meets(layers,mask) for _,l in ipairs(mask) do if layers[l] then return true end end return false end
local counts=0
surface.count_entities_filtered=function(f)
  counts=counts+1
  local types
  if f.type then types={} for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end end
  local n=0
  for _,e in ipairs(ents) do
    if e.valid and inside(e.position,f.area) and meets(e.layers,f.collision_mask) and (not types or types[e.type]) then n=n+1 end
  end
  return n
end
surface.count_tiles_filtered=function(f)
  local n=0
  for k,name in pairs(tiles) do
    local x,y=k:match('(-?%d+),(-?%d+)')
    local q={x=tonumber(x)+0.5,y=tonumber(y)+0.5}
    if (name=='water' or name=='deepwater') and inside(q,f.area) and meets({water_tile=true},f.collision_mask) then n=n+1 end
  end
  return n
end
surface.find_entities_filtered=function() return {} end
local S=dofile('mod/agent-harness_0.1.0/sharedroutes.lua'){state=state}
local CAR={'is_object','player','train','water_tile'}
local function ent(x,y,t,layers) local e={valid=true,position={x=x,y=y},type=t or 'wall',layers=layers or {player=true,is_object=true},surface=surface} ents[#ents+1]=e; return e end

-- 1. a spidertron route: kept, read again unchanged; a changed tile names its leg, where, what it was and is now
local pts={{x=0.5,y=0.5},{x=12.5,y=0.5},{x=24.5,y=6.5},{x=36.5,y=6.5}}
local r=S.save('spider',surface,pts,{by='sol'})
eq(r.id,1); eq(#r.legs,3); eq(r.len,37); eq(r.by,'sol'); eq(r.asked,1000)
eq(storage.sharedroutes.count,1); eq(storage.sharedroutes.on[1],1)
game.tick=1600
local res=S.check(r,surface)
eq(res.n,0); eq(res.legs,3)
eq(S.line(r,res),'reused route 1 (checked at tick 1600): asked by sol at tick 1000 (10s ago); its 3 legs unchanged')
paint('water',30,6,30,6)
res=S.check(r,surface)
eq(res.n,1); eq(res.first,3); eq(res.last,3)
eq(res.stale[3],'the tile at (30.5,6.5) was grass-1, now water')
eq(S.line(r,res),'route 1 (checked at tick 1600): asked by sol at tick 1000 (10s ago); of its 3 legs, legs 1-2 reused, leg 3 asked again (leg 3: the tile at (30.5,6.5) was grass-1, now water)')
-- every tile segment() reads is in it: a 2-tile change between points 4 tiles apart is seen (two runs of water join)
tiles={}
paint('water',2,0,7,0); paint('water',10,0,11,0)
r=S.save('spider',surface,{{x=0.5,y=0.5},{x=12.5,y=0.5}},{by='sol'})
eq(storage.sharedroutes.count,2)
local r2=S.save('spider',surface,{{x=12.5,y=0.5},{x=0.5,y=0.5}},{by='luna'})
eq(storage.sharedroutes.count,2,'the same ends (either way): replaced'); eq(S.get(r.id),nil); r=r2
paint('water',8,0,9,0)
res=S.check(r,surface)
eq(res.stale[1],'the tile at (9.5,0.5) was grass-1, now water','read from its start (12.5,0.5)')
-- a spidertron's legs step over entities: built ones do not make it stale
tiles={}
r=S.save('spider',surface,{{x=0.5,y=0.5},{x=12.5,y=0.5}},{by='sol'})
ent(6.5,0.5)
eq(S.check(r,surface).n,0)
ents={}

-- 2. a drive route: corridor counts (movers left out) and marks; a swap with equal counts is caught by the mark
tiles={}; storage.sharedroutes=nil
local d=S.save('drive',surface,{{x=0.5,y=0.5},{x=40.5,y=0.5},{x=40.5,y=30.5}},{by='astra',h=2.6,layers=CAR})
eq(#d.legs,5,'40 tiles in 3 legs of 16 or less, 30 in 2'); eq(d.sig,'is_object,player,train,water_tile'); eq(d.legs[1].n,0)
game.tick=2000
eq(S.check(d,surface).n,0)
ent(10.5,1.5,'unit'); ent(12.5,0.5,'character'); ent(20.5,-1.5,'car')
eq(S.check(d,surface).n,0,'units, characters and cars move: not counted')
local wall=ent(20.5,2.5)
res=S.check(d,surface)
eq(res.n,1); eq(res.first,2); eq(res.stale[2],'1 entities it collides with in its corridor, 0 when read')
-- read with the wall there, then the wall mined and another built: equal counts, the mark makes it stale
d=S.save('drive',surface,{{x=0.5,y=0.5},{x=40.5,y=0.5},{x=40.5,y=30.5}},{by='astra',h=2.6,layers=CAR})
eq(d.legs[2].n,1)
game.tick=2100
wall.valid=false
S.mark({name=66,tick=2100,entity={valid=true,type='wall',position={x=20.5,y=2.5},surface=surface}})
ent(22.5,-1.5)
res=S.check(d,surface)
eq(res.stale[2],'chunk (0,0) near it had something built, mined or destroyed, or a tile changed, at tick 2100')
eq(res.n,5,'marks are by chunk: every leg within its box plus MARK_MARGIN of chunk (0,0)')
-- a unit dying marks nothing; a surface with no route is not marked
local marks=storage.sharedroutes.ndirty
S.mark({name=4,tick=2101,entity={valid=true,type='unit',position={x=100,y=100},surface=surface}})
S.mark({name=6,tick=2101,entity={valid=true,type='wall',position={x=1,y=1},surface={index=7}}})
eq(storage.sharedroutes.ndirty,marks)
-- tiles: the landfill event marks each tile's chunk; the tile count in the corridor changes too
tiles={}; ents={}; storage.sharedroutes=nil
paint('water',60,-1,62,2)
d=S.save('drive',surface,{{x=40.5,y=0.5},{x=80.5,y=0.5}},{by='astra',h=2.6,layers=CAR})
res=S.check(d,surface)
eq(res.n,0)
game.tick=2200
tiles['59,2']='water'
S.mark({name=98,tick=2200,surface_index=1,tiles={{position={x=59,y=2}}}})
res=S.check(d,surface)
eq(res.stale[2],'13 tiles it cannot drive on in its corridor, 12 when read')
eq(res.stale[1],'chunk (1,0) near it had something built, mined or destroyed, or a tile changed, at tick 2200'); eq(res.n,3)
-- a box: a route asked for a bigger box serves a smaller one, not the reverse; the layers must match
eq(S.find('drive',surface,{x=41,y=1},{x=80,y=0},{h=2.0,sig=d.sig}),d)
eq(S.find('drive',surface,{x=41,y=1},{x=80,y=0},{h=3.0,sig=d.sig}),nil)
eq(S.find('drive',surface,{x=41,y=1},{x=80,y=0},{h=2.0,sig='player'}),nil)
eq(S.find('spider',surface,{x=41,y=1},{x=80,y=0},{}),nil)

-- 3. age: asked over MAX_AGE ago, stale in full
game.tick=2200+S.MAX_AGE+1000
res=S.check(d,surface)
eq(res.old,'route 1 was asked 2h00m ago, over the 2h00m a route is kept without asking again')
eq(S.line(d,res),'route 1 was asked 2h00m ago, over the 2h00m a route is kept without asking again: asked again in full')

-- 4. find: either way, nearest ends, within NEAR; by id with why not
storage.sharedroutes=nil; tiles={}; game.tick=5000
local a1=S.save('spider',surface,{{x=0.5,y=0.5},{x=12.5,y=0.5},{x=24.5,y=0.5}},{by='sol'})
local a2=S.save('spider',surface,{{x=100.5,y=0.5},{x=124.5,y=0.5}},{by='luna'})
local f,rev=S.find('spider',surface,{x=3,y=0},{x=22,y=2},{})
eq(f,a1); eq(rev,false)
f,rev=S.find('spider',surface,{x=22,y=2},{x=3,y=0},{})
eq(f,a1); eq(rev,true)
eq(S.find('spider',surface,{x=10,y=0},{x=22,y=2},{}),nil,'starts 9.5 from its first point: over NEAR')
local p=S.points(a1,true); eq(p[1].x,24.5); eq(p[3].x,0.5)
local none,why=S.find('spider',surface,{x=0,y=0},{x=50,y=0},{id=a2.id})
eq(none,nil); eq(why,'route 2 runs (100.5,0.5) -> (124.5,0.5): it does not start within 8 tiles of (0,0) or end within 8 of (50,0) (either way)')
none,why=S.find('spider',surface,{x=0,y=0},{x=50,y=0},{id=9})
eq(why,'no stored route 9 (kept: 2; vehicle {routes: true} lists them)')

-- 5. splice: legs 2-3 replaced, the others kept as read
storage.sharedroutes=nil
r=S.save('spider',surface,{{x=0.5,y=0.5},{x=12.5,y=0.5},{x=24.5,y=0.5},{x=36.5,y=0.5},{x=48.5,y=0.5}},{by='sol'})
local keep1,keep4=r.legs[1],r.legs[4]
game.tick=6000
S.splice(r,surface,2,3,{{x=12.5,y=0.5},{x=18.5,y=8.5},{x=30.5,y=8.5},{x=36.5,y=0.5}})
eq(#r.pts,6); eq(#r.legs,5); eq(r.legs[1],keep1); eq(r.legs[5],keep4); eq(r.legs[2].t,6000); eq(r.respliced,1)
eq(r.pts[3].y,8.5); eq(r.pts[6].x,48.5)
eq(S.check(r,surface).n,0)

-- 6. bounds: MAX_ROUTES (the one used longest ago evicted), MAX_LEGS, marks DIRTY_MAX
storage.sharedroutes=nil
S.MAX_ROUTES=3
local ids={}
for i=1,3 do game.tick=7000+i; ids[i]=S.save('spider',surface,{{x=i*100+0.5,y=0.5},{x=i*100+20.5,y=0.5}},{by='sol'}).id end
S.used(S.get(ids[1]))
game.tick=7100
S.save('spider',surface,{{x=900.5,y=0.5},{x=920.5,y=0.5}},{by='sol'})
eq(storage.sharedroutes.count,3); eq(S.get(ids[2]),nil,'used longest ago: evicted'); assert(S.get(ids[1]) and S.get(ids[3]))
eq(storage.sharedroutes.evicted,1)
S.MAX_ROUTES=100
local long={}
for i=0,S.MAX_LEGS+1 do long[#long+1]={x=i*10+0.5,y=0.5} end
local no,why2=S.save('spider',surface,long,{by='sol'})
eq(no,nil); eq(why2,'241 legs, over 240')
no,why2=S.save('spider',surface,{{x=0.5,y=0.5},{x=1500.5,y=0.5},{x=1500.5,y=1600.5}},{by='sol'})
eq(no,nil); eq(why2,'3100 tiles, over 3000')
storage.sharedroutes=nil
game.tick=8000
d=S.save('drive',surface,{{x=0.5,y=0.5},{x=10.5,y=0.5}},{by='astra',h=2.6,layers=CAR})
S.DIRTY_MAX=4
for i=1,4 do S.mark({name=6,tick=8000+i,entity={valid=true,type='wall',position={x=i*32+5,y=5},surface=surface}}) end
eq(storage.sharedroutes.ndirty,4)
game.tick=8010
S.mark({name=6,tick=8010,entity={valid=true,type='wall',position={x=500,y=5},surface=surface}})
eq(storage.sharedroutes.ndirty,0,'over: the surface counts as marked in full'); eq(storage.sharedroutes.all[1],8010)
res=S.check(d,surface)
eq(res.stale[1],'more chunks on this surface were marked than are kept (at tick 8010)')
S.DIRTY_MAX=4096

-- 7. kept from spiderpath's found path (the plan's start, the thinned path, the goal) and from a drive's first plan
storage={}; tiles={}; game.tick=9000
paint('water',10,-50,40,50)
local requests={}
surface.request_path=function(rq) requests[#requests+1]=rq; return 900+#requests end
local units={}
game.get_entity_by_unit_number=function(u) return units[u] end
local sp={valid=true,name='spidertron',unit_number=8101,position={x=0.5,y=0.5},surface=surface,force=player}
units[8101]=sp
local P=dofile('mod/agent-harness_0.1.0/spiderpath.lua'){state=state,routes=S}
local lines=P.plan(sp,{{x=60.5,y=0.5}},{owner='route',by='sol'})
assert(lines and #requests==1)
local path={}
for i=0,20 do path[#path+1]={position={x=i*3+0.5,y=-60.5+(i==0 and 61 or 0)}} end
local got
P.on_path({id=901,path={{position={x=0.5,y=0.5}},{position={x=0.5,y=-55.5}},{position={x=30.5,y=-55.5}},{position={x=60.5,y=-55.5}},{position={x=60.5,y=0.5}}}},
  function(rec,plan,s2,pts,notes) got=pts end)
assert(got,'the plan completed')
local kept=storage.sharedroutes.routes[1]
assert(kept,'kept'); eq(kept.kind,'spider'); eq(kept.by,'sol'); eq(kept.pts[1].x,0.5); eq(kept.pts[#kept.pts].x,60.5); eq(kept.pts[#kept.pts].y,0.5)
eq(S.check(kept,surface).n,0)
-- the drive: M.use with the first plan keeps it (the vehicle's layers and turning room)
local V=dofile('mod/agent-harness_0.1.0/vehicles.lua'){routes=S,distance=function(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end,
  who=function(q) return q.name end}
local car={valid=true,name='car',position={x=0.5,y=60.5},surface=surface,
  prototype={collision_box={left_top={x=-0.7,y=-1},right_bottom={x=0.7,y=1}},collision_mask={layers={player=true,train=true,is_object=true,water_tile=true}}}}
local nav={position={x=40.5,y=60.5},tolerance=3,vehicle=true,vehicle_entity=car}
V.use({name='astra'},nav,{{position={x=0.5,y=60.5}},{position={x=20.5,y=60.5}},{position={x=40.5,y=60.5}}})
eq(nav.path_state,'found')
local dk=storage.sharedroutes.routes[nav.kept]
assert(dk,'the drive path kept'); eq(dk.kind,'drive'); eq(dk.by,'astra'); eq(dk.sig,'is_object,player,train,water_tile')
eq(#dk.legs,3,'one straight 40-tile leg: its corners are its ends, cut to 16 or less'); assert(math.abs(dk.h-(1.0^2+0.7^2)^0.5-0.5)<1e-9)
-- a later plan (the near or narrow ones) is not kept
nav={position={x=40.5,y=70.5},tolerance=3,vehicle=true,vehicle_entity=car,path_level=1}
V.use({name='astra'},nav,{{position={x=0.5,y=70.5}},{position={x=40.5,y=70.5}}})
eq(nav.kept,nil)

-- 8. storage holds plain data only (numbers, strings, booleans, tables): it stays in the save and a later runtime reads it
local function plain(t,seen)
  seen=seen or {}
  if seen[t] then return end
  seen[t]=true
  for k,v in pairs(t) do
    assert(type(k)=='number' or type(k)=='string',type(k))
    local tv=type(v)
    assert(tv=='number' or tv=='string' or tv=='boolean' or tv=='table','a '..tv..' in storage at '..tostring(k))
    if tv=='table' then plain(v,seen) end
  end
end
plain(storage.sharedroutes)
local S2=dofile('mod/agent-harness_0.1.0/sharedroutes.lua'){state=state}
eq(S2.get(kept.id),kept); eq(S2.check(kept,surface).n,0,'a new runtime reads the kept routes')
print('d28_batch305: ok')
