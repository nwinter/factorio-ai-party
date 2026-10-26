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
surface.find_entities_filtered=function(f)
  if f.name=='tile-ghost' then
    assert(f.force==force and f.limit,'our tile ghosts, a limited find')
    local out={}
    for _,g in pairs(ghosts) do if #out<f.limit then out[#out+1]=g end end
    return out
  end
  return {}
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
local phase=w.phase
-- an asteroid destroys 3 at 1030, over the old record's spot: destroyed, not placed (the record is of another ghost)
run(1030); strike({{10,-20},{11,-20},{12,-20}})
eq(G.owner(ghosts[key(10,-20)]),nil,'a record kept with another ghost\'s unit number is not this ghost\'s')
run(1100)
local f=w.fl
eq(f.destroyed,3,'three destroyed'); eq(f.placed,0,'none placed')
local first=f.first_destroyed
assert(first>1030 and first<=1090,'seen at the first sample after the strike: '..tostring(first))
eq(f.rows[1].what,'destroyed'); eq(f.rows[1].count,3); assert(f.rows[1].from_tick<1030,'from the sample before')
-- the hub builds one at 1101 (the event: its exact tick and quality); one destroyed and built between two samples at
-- 1140/1141; Astra's placed ghost at 1150 and built at 1152 between samples
run(1101); build(10,-20)
run(1140); strike({{13,-20}}); run(1141); build(13,-20,'rare')
run(1150); place('astra',-1,-26); run(1152); build(-1,-26)
run(1200)
eq(f.rebuilt,2,'two rebuilt'); eq(f.between,1,'one destroyed and rebuilt between samples'); eq(f.destroyed,4)
eq(f.placed_built,1,'the placed one built'); eq(f.taken.normal,2); eq(f.taken.rare,1)
local r=F.call(p,{id=a.id}).watch
local fd=r.foundation
eq(fd.destroyed,4); eq(fd.rebuilt,2); eq(fd.destroyed_between_samples,1); eq(fd.open,2,'two destroyed still ghosts'); eq(fd.open_placed,1)
eq(fd.taken_total,3); eq(fd.hub_foundation.start,148); eq(fd.hub_foundation['end'],145); eq(fd.builds_heard,true)
eq(fd.last_destroyed_tick,1141)
has(r.line,'; foundation: 4 tiles destroyed (ticks '..first..' to 1141), 2 rebuilt by the platform, 3 foundation taken from the hub by its tile builds (normal 2, rare 1), 2 destroyed not rebuilt yet; hub foundation 148 -> 145 (placed ghosts: 1 appeared, 1 built, 1 open)')
local rows={}
for _,x in ipairs(fd.rows) do rows[#rows+1]=x.what..'@'..x.tick end
has(table.concat(rows,' '),'rebuilt@1101 destroyed_and_rebuilt@1141 placed_built@1152')
-- a built tile's record is dropped: a later destroyed tile there has no placer
eq(G.owner_at('platform-41',FOUNDATION,{x=-0.5,y=-25.5},true),nil,'the built ghost\'s record dropped')
-- the platform read (space.lua's foundation_lost): the builds heard, the ghosts aboard now
local fr=F.floor_read(pl)
eq(fr.rebuilt,2); eq(fr.placed_built,1); eq(fr.open,2); eq(fr.open_placed,1); eq(fr.taken.rare,1); eq(fr.since_tick,1101)
has(fr.line,'foundation: 2 foundation ghosts no one placed (destroyed tiles not rebuilt yet) and 1 placed ones aboard now; since tick 1101 the platform built 2 foundation tiles on ghosts no one placed (destroyed tiles) and 1 on placed ghosts, taking 3 foundation from the hub (normal 2, rare 1)')
print('d25_batch216 QAA1 destroyed, rebuilt, placed, taken, the platform read: ok')

-- a mixed split at 1337 (mixed.lua): the part keeps its foundation; the next window counts from there, the ghosts
-- seen carried (one destroyed in the first part and rebuilt in the second is rebuilt there)
run(1337)
eq(X.edit({described=true,surface=9,name='gun-turret',type='ammo-turret',unit_number=99,position={x=3,y=3},box={2,2,4,4},force='player'},'built by sol'),1)
local part=w.mixed.parts[1]
eq(part.foundation.destroyed,4,'the part keeps its foundation'); eq(part.foundation.rebuilt,2)
eq(w.fl.destroyed,0,'the new window counts from the split')
run(1400); build(11,-20); run(1460)
eq(w.fl.rebuilt,1,'rebuilt in the second part'); eq(w.fl.destroyed,0)
eq(F.call(p,{id=a.id}).watch.foundation.hub_foundation.start,144+1,'the window\'s own start')
print('d25_batch216 QAA1 mixed parts: ok')

-- builds not heard (an old control.lua): a sample finds the ghost gone and foundation there (rebuilt), or empty space
-- (removed); the line says the builds were not heard
heard=false
run(1500); build(12,-20)
run(1520); ghosts[key(41,0)]=nil   -- the planned ghost cancelled
run(1600)
eq(w.fl.rebuilt,2,'a sample read the build'); eq(w.fl.removed,1,'the cancelled one removed')
local seenrow
for _,x in ipairs(w.fl.rows) do if x.what=='rebuilt' and x.tick>1500 then seenrow=x end end
assert(seenrow and seenrow.from_tick and seenrow.from_tick<=1500 and seenrow.tick>1500,'a sample\'s build carries the sample before')
has(F.call(p,{id=a.id}).watch.line,'(the platform\'s tile builds not heard: this server\'s control.lua forwards no on_space_platform_built_tile; builds read by the samples)')
has(F.floor_read(pl).line,'the platform\'s own tile builds are not heard here')
heard=true
-- over FLOOR_SCAN tile ghosts aboard: that sample reads none of them, and says so
for i=1,F.FLOOR_SCAN+1 do ghost(100+i,100) end
run(1700)
assert((w.fl.skipped or 0)>=1,'skipped'); has(F.call(p,{id=a.id}).watch.line,'samples found over 512 tile ghosts aboard and read none of them')
for i=1,F.FLOOR_SCAN+1 do ghosts[key(100+i,100)]=nil end
-- a tile that is not foundation, and another platform with no watch: its record only
F.on_built_tile{name=77,tick=game.tick,platform=pl,tile={name='concrete'},tiles={{position={x=0,y=0}}}}
local other={valid=true,index=7,name='Swiftlet',surface={name='platform-7'},force=force}
F.on_built_tile{name=77,tick=game.tick,platform=other,tile={name=FOUNDATION},quality={name='normal'},tiles={{position={x=1,y=1}},{position={x=2,y=1}}}}
eq(st.floorlog.p[7].rebuilt,2); eq(st.floorlog.p[41].rebuilt,3,'concrete not counted')
-- the watch ends: its open ghosts kept as counts
run(1720); pl.state,pl.space_connection,pl.space_location=2,nil,{name='aquilo'}; run(1800)
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
