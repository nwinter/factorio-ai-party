-- Run from the harness root: lua tests/d20_batch56.lua
-- d20 batch56 R5 (Sol #1409): platform_defense counts a railgun only within its firing arc.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

do
  defines={inventory={turret_ammo=1}}
  local function turret(name,x,y,range,turn,dir)
    return {valid=true,type='ammo-turret',name=name,position={x=x,y=y},direction=dir,bounding_box={left_top={x=x-2,y=y-2},right_bottom={x=x+2,y=y+2}},
      get_inventory=function() return {get_contents=function() return {{name='railgun-ammo',count=10}} end} end,
      prototype={attack_parameters={range=range,min_range=0,turn_range=turn}},ignore_unprioritised_targets=false}
  end
  local function collector(x,y) return {valid=true,type='asteroid-collector',name='asteroid-collector',position={x=x,y=y},direction=0,prototype={}} end
  -- Sol's case: a railgun at (22.5,10.5) facing east (72 degrees: 54..126 from north); a collector north of it, one east
  local rg=turret('railgun-turret',22.5,10.5,40,0.2,4)
  local north,east=collector(22.5,-10),collector(40,10.5)
  local turrets,collectors={rg},{north,east}
  local tiles={}
  for x=20,25 do tiles[#tiles+1]={position={x=x,y=-5}} end
  local s={find_entities_filtered=function(f)
      if f.type=='asteroid-collector' then return collectors end
      if f.type=='inserter' then return {} end
      return turrets end,
    find_tiles_filtered=function() return tiles end}
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Wayfarer',surface=s,force='f'} end}
  local r=D.read({},{platform='Wayfarer'})
  eq(r.turrets[1].facing,'east'); eq(r.turrets[1].arc_degrees,72)
  eq(r.collectors[1].covered_by,0); eq(r.collectors[2].covered_by,1)
  eq(r.collectors[1].outside_arc[1].off_degrees,54); eq(r.collectors[2].outside_arc,nil)
  has(r.lines[1],'asteroid-collector (22.5,-10), front (22.5,-10): NO turret reaches it; in range but outside the arc, not counted: railgun-turret (22.5,10.5) aims within 72 degrees centred east: 54 degrees outside it')
  has(r.lines[2],'asteroid-collector (40,10.5), front (40,10.5): 1 turret reach it')
  -- the hull's north edge above it: in range, outside the arc, uncovered
  local side
  for _,row in ipairs(r.sides) do if row.side=='north' then side=row end end
  eq(side.edge_tiles,6); eq(side.uncovered,6)
  -- a diagonal one facing northeast (direction 2): the point northeast counted, the one due north (45 degrees off) not
  local diag=turret('railgun-turret',0,0,40,0.2,2)
  turrets={diag}; collectors={collector(14,-14),collector(0,-20)}; tiles={}
  r=D.read({},{platform='Wayfarer'})
  eq(r.turrets[1].facing,'northeast'); eq(r.collectors[1].covered_by,1); eq(r.collectors[2].covered_by,0)
  eq(r.collectors[2].outside_arc[1].off_degrees,9)
  -- a turret that aims all round (a gun: turn_range 1) is as before
  turrets={turret('gun-turret',0,0,18,1,4)}; collectors={collector(0,-10)}
  r=D.read({},{platform='Wayfarer'})
  eq(r.collectors[1].covered_by,1); eq(r.turrets[1].facing,nil)
  defines=nil
end
print('d20_batch56 R5 railgun arc in platform_defense: ok')

-- d20 batch56 R7 (Luna #1434): who placed a ghost, through which request; what robots built from it; unknown with why.
do
  game={tick=1000}
  table_size=function(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
  local storage,via={},nil
  local G=dofile('mod/agent-harness_0.1.0/ghostlog.lua'){state=function() return storage end,via=function() return via end}
  local nauvis={name='nauvis'}
  local function ghost(name,x,y,user) return {valid=true,type='entity-ghost',ghost_name=name,name='entity-ghost',surface=nauvis,position={x=x,y=y},last_user=user} end
  local function built(name,x,y,user) return {valid=true,type='transport-belt',name=name,surface=nauvis,position={x=x,y=y},last_user=user} end
  -- Luna's belt_route call lays three belt ghosts; robots build them (no last user: a bot is no player)
  via={action='belt_route'}
  for x=407.5,409.5 do G.placed('luna',ghost('transport-belt',x,-277.5)) end
  via=nil
  game.tick=1000+60*90
  local g=G.read(ghost('transport-belt',408.5,-277.5))
  eq(g.by,'luna'); eq(g.tick,1000); eq(g.through,'belt_route, a call'); eq(g.last_user,nil)
  has(g.line,'ghost placed by luna 1m ago (tick 1000) through belt_route, a call')
  local b=G.read(built('transport-belt',407.5,-277.5))
  has(b.line,'its ghost placed by luna 1m ago (tick 1000) through belt_route, a call; built from it since (robots or a hand: the harness does not see which)')
  eq(G.short(built('transport-belt',409.5,-277.5)),'ghost by luna 1m ago (belt_route, a call)')
  -- another name on the spot: no record; the reason says what is unknown
  local u=G.read(built('fast-transport-belt',407.5,-277.5))
  eq(u.unknown,true); has(u.line,'unknown: no harness record of placing it or its ghost here (the record began 1m ago, at tick 1000, and keeps the last 8192 placements)')
  eq(G.short(built('fast-transport-belt',407.5,-277.5)),nil)
  -- a player's ghost: the game's last user
  local pu=G.read(ghost('stone-wall',1.5,1.5,{name='Foobator'}))
  eq(pu.last_user,'Foobator'); has(pu.line,'unknown: '); has(pu.line,'; the game\'s last user: Foobator')
  eq(G.short(ghost('stone-wall',1.5,1.5,{name='Foobator'})),'last user Foobator')
  -- a queue step and a standing order; a hand build of a recorded ghost keeps the planner and adds the builder
  via={action='place_ghosts',step='job-12',label='walls'}
  G.placed('sol',ghost('stone-wall',5.5,5.5))
  via={action='paste',step='job-3',order='rebuild'}
  G.placed('astra',ghost('gun-turret',8,8))
  via={action='construct'}
  G.placed('opus',built('stone-wall',5.5,5.5),true,true)
  via={action='build'}
  G.placed('opus',built('iron-chest',9.5,9.5),true)
  via=nil
  has(G.read(built('stone-wall',5.5,5.5)).line,'its ghost placed by sol 0s ago (tick 6400) through place_ghosts, queue step 12 "walls"; built by hand by opus 0s ago')
  eq(G.read(built('stone-wall',5.5,5.5)).built_by_hand,'opus')
  has(G.read(ghost('gun-turret',8,8)).line,'through paste, standing order "rebuild"')
  has(G.read(built('iron-chest',9.5,9.5)).line,'built by hand by opus 0s ago (tick 6400) through build, a call')
  -- removed: the record goes
  G.forget(built('iron-chest',9.5,9.5))
  eq(G.read(built('iron-chest',9.5,9.5)).unknown,true)
  -- bounded: the ring keeps the last 8192; the oldest go first
  for i=1,8192 do G.placed('grok',ghost('stone-wall',1000+i,0)) end
  eq(G.read(ghost('transport-belt',408.5,-277.5)).unknown,true)
  eq(G.read(ghost('stone-wall',1001,0)).by,'grok')
  eq(G.stats().kept,8192)
  -- a spot placed twice keeps the newer, and the older slot's turn does not drop it
  G.placed('haiku',ghost('stone-wall',1500,0))
  for i=1,8191 do G.placed('grok',ghost('pipe',2000+i,0)) end
  eq(G.read(ghost('stone-wall',1500,0)).by,'haiku'); eq(G.read(ghost('stone-wall',1600,0)).unknown,true)
  game=nil; table_size=nil
end
print('d20_batch56 R7 ghost placement record: ok')
