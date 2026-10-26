-- d25 batch216 QAA1 (Astra 20:09: Asterion's hub foundation fell 154 -> 153 -> 148 on flight 205's return with no hits,
-- losses, ghosts or foundation made or used read). Run from the harness root: lua tests/d25_batch216.lua.
-- An asteroid destroys foundation tiles with no event and the game puts a foundation ghost on each; the hub builds them
-- from its foundation (on_space_platform_built_tile). flight_watch counts each window's tiles destroyed (new ghosts no
-- one placed) and rebuilt (that event, else a sample), with ticks and the foundation taken from the hub; a mixed part
-- keeps its own; the platform read's foundation_lost from the event; the ghost log's tile record names only its ghost.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(type(s)=='string' and s:find(x,1,true),tostring(s)..'\n  lacks: '..x) end
local function read(p) local f=assert(io.open(p)); local s=f:read('a'); f:close(); return s end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2},events={on_space_platform_built_tile=77}}
prototypes={item={['repair-pack']={type='repair-tool'}},
  quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5}}}
local FOUNDATION='space-platform-foundation'
local stats={get_output_count=function() return 0 end}
local force={name='player',get_item_production_statistics=function() return stats end}
-- the platform: its tiles (key x,y: foundation, else empty space), its tile ghosts, the hub's foundation
local tiles,ghosts,unit={},{},1000
local hub_n=148
local surface={index=9,name='platform-41'}
local function inside(a,x,y) return not a or (x>=a[1][1] and x<a[2][1] and y>=a[1][2] and y<a[2][2]) end
local finds=0
surface.find_entities_filtered=function(f)
  if f.name=='tile-ghost' then
    assert(f.force==force and f.limit,'our tile ghosts, a limited find')
    finds=finds+1
    local out={}
    for _,g in pairs(ghosts) do if #out<f.limit and inside(f.area,g.position.x,g.position.y) then out[#out+1]=g end end
    return out
  end
  return {}
end
-- the surface's chunks: 32x32 from (-64,-64) to (96,64); a tile count by area
surface.get_chunks=function()
  local list={}
  for cx=-2,2 do for cy=-2,1 do list[#list+1]={area={left_top={x=cx*32,y=cy*32},right_bottom={x=cx*32+32,y=cy*32+32}}} end end
  local i=0
  return function() i=i+1; return list[i] end
end
surface.count_tiles_filtered=function(f)
  local a=f.area
  for k in pairs(tiles) do
    local x,y=k:match('^(-?%d+),(-?%d+)$'); x,y=tonumber(x),tonumber(y)
    if x>=a.left_top.x and x<a.right_bottom.x and y>=a.left_top.y and y<a.right_bottom.y then return 1 end
  end
  return 0
end
surface.get_tile=function(x,y) return {name=tiles[x..','..y] and FOUNDATION or 'empty-space'} end
local pl={valid=true,index=41,name='Asterion',surface=surface,force=force}
pl.hub={get_inventory=function() return {get_contents=function() return {{name=FOUNDATION,count=hub_n,quality='normal'},{name='repair-pack',count=5,quality='normal'}} end} end}
pl.state,pl.space_connection=1,{from={name='solar-system-edge'},to={name='aquilo'}}
force.platforms={[41]=pl}
game={tick=1000,forces={player=force}}
local p={name='astra',force=force,index=1}
local st={}
local G=dofile('mod/agent-harness_0.1.0/ghostlog.lua'){state=function() return st end}
local heard=true
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function(q,name) assert(name=='Asterion','no platform '..tostring(name)); return pl end,
  hits=function() return {hits=0,damage=0,entities={},by={}} end,
  ghost_owner=function(g) return G.owner(g) end,ghost_owner_at=function(s,name,pos) return G.owner_at(s,name,pos,true) end,
  ghost_forget_tile=function(s,name,pos) return G.forget_tile(s,name,pos) end,built_tile_heard=function() return heard end}
local X=dofile('mod/agent-harness_0.1.0/mixed.lua'){state=function() return st end,flight_rebase=function(w,tick) return F.rebase(w,tick) end}
local function key(x,y) return x..','..y end
local function ghost(x,y)
  unit=unit+1
  local g={valid=true,type='tile-ghost',name='tile-ghost',ghost_name=FOUNDATION,position={x=x+0.5,y=y+0.5},unit_number=unit,quality={name='normal'},surface=surface}
  ghosts[key(x,y)]=g
  return g
end
-- an asteroid: the tiles go and the game's ghosts come, with no event
local function strike(list) for _,t in ipairs(list) do tiles[key(t[1],t[2])]=nil; ghost(t[1],t[2]) end end
-- an agent's ghost (the harness records its placer)
local function place(who,x,y) local g=ghost(x,y); G.placed(who,g); return g end
-- the hub builds one: the ghost goes, the tile comes, one foundation less, the event when heard
local function build(x,y,q)
  assert(ghosts[key(x,y)],'a ghost at '..key(x,y))
  ghosts[key(x,y)]=nil; tiles[key(x,y)]=true; hub_n=hub_n-1
  if heard then F.on_built_tile{name=77,tick=game.tick,platform=pl,tile={name=FOUNDATION},item={name=FOUNDATION},quality={name=q or 'normal'},
    tiles={{old_tile={name='empty-space'},position={x=x,y=y}}}} end
end
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end end
for x=-5,40 do for y=-25,5 do tiles[key(x,y)]=true end end

-- the hull's tiles were pasted long ago: the ghost log still holds a record at (10,-20), of a ghost built since
game.tick=100
local old=ghost(10,-20); G.placed('sol',old); ghosts[key(10,-20)]=nil; tiles[key(10,-20)]=true
eq(G.owner(old),'sol','the old ghost\'s own record')
-- an agent's planned tile already open when the watch begins
game.tick=900
place('sol',41,0)
game.tick=1000
local a=F.call(p,{platform='Asterion',minutes=60}).watch
eq(a.foundation.open_placed,1,'the planned ghost aboard at the start'); eq(a.foundation.destroyed,0); eq(a.foundation.hub_foundation.start,148)
local w=st.flightwatch.list[1]
-- the hull's chunks found once: tiles x -5..40, y -25..5 lie in chunks x -32..64, y -32..32
eq(table.concat(w.fl_box,','),'-32,-32,64,32','the hull\'s chunk box')
-- an asteroid destroys 3 at 1030, over the old record's spot: destroyed, not placed (the record is of another ghost)
run(1030); strike({{10,-20},{11,-20},{12,-20}})
eq(G.owner(ghosts[key(10,-20)]),nil,'a record kept with another ghost\'s unit number is not this ghost\'s')
-- the platform's builds are heard: the ghosts are found every FLOOR_TICKS (300), not each sample
local finds0=finds
run(1400)
eq(finds-finds0,1,'one find in 400 ticks while builds are heard')
local f=w.fl
eq(f.destroyed,3,'three destroyed'); eq(f.placed,0,'none placed')
local first=f.first_destroyed
assert(first>1030 and first<=1030+F.FLOOR_TICKS,'seen at the first find after the strike: '..tostring(first))
eq(f.rows[1].what,'destroyed'); eq(f.rows[1].count,3); assert(f.rows[1].from_tick<1030,'from the sample before')
-- the hub builds one at 1401 (the event: its exact tick and quality); one destroyed and built between two finds at
-- 1440/1441; Astra's placed ghost at 1450 and built at 1452 between finds
run(1401); build(10,-20)
run(1440); strike({{13,-20}}); run(1441); build(13,-20,'rare')
run(1450); place('astra',-1,-26); run(1452); build(-1,-26)
run(1500)
eq(f.rebuilt,2,'two rebuilt'); eq(f.between,1,'one destroyed and rebuilt between samples'); eq(f.destroyed,4)
eq(f.placed_built,1,'the placed one built'); eq(f.taken.normal,2); eq(f.taken.rare,1)
eq(w.fl_box[2],-32,'a build inside the box leaves it')
-- a ghost outside the box (an expansion at y -40): no sample finds it; its build widens the box and counts placed
run(1510); place('astra',5,-40); run(1700)
eq(f.placed,1,'not found outside the box'); build(5,-40); eq(w.fl_box[2],-40,'widened by the build'); eq(f.placed,2); eq(f.placed_built,2)
tiles[key(5,-40)]=true
local r=F.call(p,{id=a.id}).watch
local fd=r.foundation
eq(fd.destroyed,4); eq(fd.rebuilt,2); eq(fd.destroyed_between_finds,1); eq(fd.open,2,'two destroyed still ghosts'); eq(fd.open_placed,1)
eq(fd.taken_total,4); eq(fd.hub_foundation.start,148); eq(fd.hub_foundation['end'],144); eq(fd.builds_heard,true)
eq(fd.last_destroyed_tick,1441)
has(r.line,'; foundation: 4 tiles destroyed (ticks '..first..' to 1441), 2 rebuilt by the platform, 4 foundation taken from the hub by its tile builds (normal 3, rare 1), 2 destroyed not rebuilt yet; hub foundation 148 -> 144 (placed ghosts: 2 appeared, 2 built, 1 open)')
local rows={}
for _,x in ipairs(fd.rows) do rows[#rows+1]=x.what..'@'..x.tick end
has(table.concat(rows,' '),'rebuilt@1401 destroyed_and_rebuilt@1441 placed_built@1452')
-- a built tile's record is dropped: a later destroyed tile there has no placer
eq(G.owner_at('platform-41',FOUNDATION,{x=-0.5,y=-25.5},true),nil,'the built ghost\'s record dropped')
-- the platform read (space.lua's foundation_lost): the builds heard, the ghosts aboard now
local fr=F.floor_read(pl)
eq(fr.rebuilt,2); eq(fr.placed_built,2); eq(fr.open,2); eq(fr.open_placed,1); eq(fr.taken.rare,1); eq(fr.since_tick,1401)
has(fr.line,'foundation: 2 foundation ghosts no one placed (destroyed tiles not rebuilt yet) and 1 placed ones aboard now; since tick 1401 the platform built 2 foundation tiles on ghosts no one placed (destroyed tiles) and 2 on placed ghosts, taking 4 foundation from the hub (normal 3, rare 1)')
print('d25_batch216 QAA1 destroyed, rebuilt, placed, taken, the platform read: ok')

-- a mixed split at 1737 (mixed.lua): the part keeps its foundation; the next window counts from there, the ghosts
-- seen carried (one destroyed in the first part and rebuilt in the second is rebuilt there)
run(1737)
eq(X.edit({described=true,surface=9,name='gun-turret',type='ammo-turret',unit_number=99,position={x=3,y=3},box={2,2,4,4},force='player'},'built by sol'),1)
local part=w.mixed.parts[1]
eq(part.foundation.destroyed,4,'the part keeps its foundation'); eq(part.foundation.rebuilt,2)
eq(w.fl.destroyed,0,'the new window counts from the split')
run(1800); build(11,-20); run(1860)
eq(w.fl.rebuilt,1,'rebuilt in the second part'); eq(w.fl.destroyed,0)
eq(F.call(p,{id=a.id}).watch.foundation.hub_foundation.start,144,'the window\'s own start')
print('d25_batch216 QAA1 mixed parts: ok')

-- builds not heard (an old control.lua): a sample finds the ghost gone and foundation there (rebuilt), or empty space
-- (removed); the line says the builds were not heard
heard=false
run(1900); build(12,-20)
run(1920); ghosts[key(41,0)]=nil   -- the planned ghost cancelled
local finds1=finds
run(2000)
assert(finds-finds1>=1 and finds-finds1<=2,'each sample finds while builds are not heard: '..(finds-finds1))
eq(w.fl.rebuilt,2,'a sample read the build'); eq(w.fl.removed,1,'the cancelled one removed')
local seenrow
for _,x in ipairs(w.fl.rows) do if x.what=='rebuilt' and x.tick>1900 then seenrow=x end end
assert(seenrow and seenrow.from_tick and seenrow.from_tick<=1900 and seenrow.tick>1900,'a sample\'s build carries the sample before')
has(F.call(p,{id=a.id}).watch.line,'(the platform\'s tile builds not heard: this server\'s control.lua forwards no on_space_platform_built_tile; builds read by the finds, each sample)')
has(F.floor_read(pl).line,'the platform\'s own tile builds are not heard here')
heard=true
-- over FLOOR_SCAN tile ghosts aboard: that sample reads none of them, and says so
for i=0,F.FLOOR_SCAN do ghost(-30+i%90,6+math.floor(i/90)) end
run(2400)
assert((w.fl.skipped or 0)>=1,'skipped'); has(F.call(p,{id=a.id}).watch.line,'finds met over 512 tile ghosts aboard and read none of them')
for i=0,F.FLOOR_SCAN do ghosts[key(-30+i%90,6+math.floor(i/90))]=nil end
-- a tile that is not foundation, and another platform with no watch: its record only
F.on_built_tile{name=77,tick=game.tick,platform=pl,tile={name='concrete'},tiles={{position={x=0,y=0}}}}
local other={valid=true,index=7,name='Swiftlet',surface={name='platform-7'},force=force}
F.on_built_tile{name=77,tick=game.tick,platform=other,tile={name=FOUNDATION},quality={name='normal'},tiles={{position={x=1,y=1}},{position={x=2,y=1}}}}
eq(st.floorlog.p[7].rebuilt,2); eq(st.floorlog.p[41].rebuilt,3,'concrete not counted')
-- the watch ends: its open ghosts kept as counts
run(2420); pl.state,pl.space_connection,pl.space_location=2,nil,{name='aquilo'}; run(2500)
eq(w.state,'done'); eq(w.fl_seen,nil,'the seen ghosts dropped at the end')
local done=F.call(p,{id=a.id}).watch.foundation
eq(done.open,0,'all four rebuilt'); eq(done.open_placed,0,'the planned one cancelled'); eq(done.hub_foundation['end'],hub_n)
-- a watch begun before this change: named, nothing counted
local w2={id=99,platform='Asterion',index=41,force='player',setter='astra',state='done',start=10,ended=20,why='x',samples=1,turrets={},hits0={hits=0,damage=0,entities={},by={}},packs0=0}
has(F.row(w2,true).line,'; foundation not read (this watch began before foundation was read)')
print('d25_batch216 QAA1 not heard, removed, skipped, ended: ok')

-- wiring: control.lua forwards the event; the runtime routes it and wires the ghost log; the platform read and its
-- describe text; a mixed part's foundation
local control=read('mod/agent-harness_0.1.0/control.lua')
has(control,"'on_space_platform_built_tile'} do")
local rt=read('mod/agent-harness_0.1.0/runtime.lua')
has(rt,"pcall(M.timed,'flightwatch.built_tile',M.flightwatch.on_built_tile,event)")
has(rt,'ghost_forget_tile=function(s,name,pos) return M.ghostlog.forget_tile(s,name,pos) end')
has(rt,'floor_read=function(pl) return M.flightwatch.floor_read(pl) end')
local sp=read('mod/agent-harness_0.1.0/space.lua')
has(sp,"row.foundation_lost=W('foundation_lost') and api.floor_read")
has(sp,'foundation_lost (asteroids destroy foundation tiles with no event')
has(read('mod/agent-harness_0.1.0/mixed.lua'),'foundation=fw.foundation')
has(F.NOTE,'foundation: an asteroid that enters the foundation destroys the tiles under it with no event')
print('d25_batch216 QAA1 wiring: ok')

-- QAA2 (Astra 20:59): ghosts {name} takes a tile name: the tile ghosts found by type and kept by name (the game's
-- ghost_name filter knows entity names only: "Unknown entity name: space-platform-foundation" on a copy of world n)
do
  prototypes.entity={['gun-turret']={}}
  prototypes.tile={[FOUNDATION]={items_to_place_this={{name=FOUNDATION,count=1}}},concrete={items_to_place_this={{name='concrete',count=1}}}}
  local L=dofile('mod/agent-harness_0.1.0/ghostlist.lua'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,
    integer=function(v,d) return v==nil and d or v end,distance=function(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end}
  local gs={
    {valid=true,type='tile-ghost',ghost_name=FOUNDATION,position={x=47.5,y=-59.5}},
    {valid=true,type='tile-ghost',ghost_name='concrete',position={x=40.5,y=-59.5}},
    {valid=true,type='entity-ghost',ghost_name='gun-turret',position={x=44,y=-58},ghost_prototype={items_to_place_this={{name='gun-turret',count=1}}}}}
  local filters={}
  local s2={name='platform-16',find_entities_filtered=function(f)
    filters[#filters+1]=f
    if f.ghost_name then assert(prototypes.entity[f.ghost_name],'Unknown entity name: '..f.ghost_name) end
    local out={}
    for _,g in ipairs(gs) do
      local ty=type(f.type)=='table' and f.type or {f.type}
      local ok=false
      for _,t in ipairs(ty) do if t==g.type then ok=true end end
      if ok and (not f.ghost_name or f.ghost_name==g.ghost_name) then out[#out+1]=g end
    end
    return out
  end}
  local me={surface=s2,position={x=47,y=-59},force=force,get_main_inventory=function() return nil end}
  local all=L.read(me,{radius=16})
  eq(#all.ghosts,3,'unfiltered: the tile ghosts and the entity ghost')
  local r=L.read(me,{radius=16,name=FOUNDATION})
  eq(#r.ghosts,1,'the foundation ghost only'); eq(r.ghosts[1].name,FOUNDATION); eq(r.ghosts[1].tile,true)
  eq(filters[#filters].type,'tile-ghost','found by type'); eq(filters[#filters].ghost_name,nil,'no entity-name filter')
  local e=L.read(me,{radius=16,name='gun-turret'})
  eq(#e.ghosts,1); eq(filters[#filters].ghost_name,'gun-turret','an entity name as before')
  local ok,err=pcall(L.read,me,{radius=16,name='no-such-thing'})
  assert(not ok and tostring(err):find('name: no entity or tile is named no-such-thing',1,true),tostring(err))
  print('d25_batch216 QAA2 ghosts name: a tile name: ok')
end
