-- Run from the harness root: lua tests/d21_batch72b.lua
-- d21 batch72 AH2 (Astra #1741): platform_defense planned: true counts our turret ghosts (their prototype's range,
-- minimum range, arc by facing and the priority list they carry) on the hull with our foundation tile ghosts, read in
-- the background; actual and planned cover apart; ghosts never armed.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function line(r,x) for _,l in ipairs(r.lines) do if l:find(x,1,true) then return l end end error('no line with '..x..'\n'..table.concat(r.lines,'\n')) end

defines={inventory={turret_ammo=1}}
game={tick=1000}
storage={}
local function ghost(name,gtype,x,y,dir,ap,list)
  return {valid=true,type='entity-ghost',ghost_type=gtype,ghost_name=name,position={x=x,y=y},direction=dir,
    ghost_prototype={attack_parameters=ap,tile_buildability_rules={}},ignore_unprioritised_targets=list~=nil,
    get_priority_target=function(i) return list and list[i] and {name=list[i]} or nil end}
end
-- a railgun ghost north of the hull facing south (huge only), a rocket ghost south of it (big only), a collector ghost
-- north of the railgun (outside its arc)
local rail=ghost('railgun-turret','ammo-turret',0,-30,8,{range=40,min_range=3.5,turn_range=0.2},
  {'huge-metallic-asteroid','huge-carbonic-asteroid','huge-oxide-asteroid'})
local rocket=ghost('rocket-turret','ammo-turret',0,30,0,{range=36,min_range=15},{'big-metallic-asteroid','big-carbonic-asteroid','big-oxide-asteroid'})
local cghost=ghost('asteroid-collector','asteroid-collector',0,-60,0,{})
-- built foundation x -5..4, y -2..1; foundation ghosts below it, y 2..5
local built,ghosts={},{}
for x=-5,4 do for y=-2,1 do built[#built+1]={position={x=x,y=y}} end for y=2,5 do ghosts[#ghosts+1]={position={x=x,y=y}} end end
local function within(list,area)
  if not area then return list end
  local out={}
  for _,t in ipairs(list) do local p=t.position
    if p.x>=area[1][1] and p.x<area[2][1] and p.y>=area[1][2] and p.y<area[2][2] then out[#out+1]=t end end
  return out
end
local s={find_entities_filtered=function(f)
    if f.type=='entity-ghost' then
      if f.ghost_type=='asteroid-collector' then return {cghost} end
      return {rail,rocket}
    end
    return {} end,
  find_tiles_filtered=function(f) if f.has_tile_ghost then return within(ghosts,f.area) end return within(built,f.area) end}
local force={name='player'}
local pl={name='Plan',index=7,valid=true,surface=s,force=force}
force.platforms={[7]=pl}
game.forces={player=force}
local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return pl end,state=function() return storage end}

-- the actual read is as before: the built hull, no turret
local r=D.read({},{platform='Plan'})
eq(r.planned,nil,'planned only when asked')
local north
for _,row in ipairs(r.sides) do if row.side=='north' then north=row end end
eq(north.edge_tiles,10); eq(north.by_size.small.uncovered,10); eq(north.by_size.big.uncovered,10)

-- planned: the ghosts at once, the hull's sides pending
r=D.read({},{platform='Plan',planned=true})
local p=r.planned
eq(p.turret_ghosts,2); eq(p.built_turrets,0); eq(p.ghosts_by_name['railgun-turret'],1)
has(p.note,'a ghost holds no ammunition and draws no power')
has(line(r,'planned: 0 built turrets and 2 turret ghosts'),'planned cover is reach alone')
has(line(r,'planned: railgun-turret ghost'),'railgun-turret ghost (0,-30) aims within 72 degrees centred south, range 40, not within 3.5, engages only huge-')
has(line(r,'rocket-turret ghosts'),'1 rocket-turret ghosts: range 36, not within 15, aim all round, engage only big-')
eq(#p.ghosts,1,'rows for the ghosts with an arc'); eq(p.ghosts[1].arc_degrees,72); eq(p.ghosts[1].unarmed,'a ghost: no ammunition')
assert(p.sides_pending and p.sides==nil,'sides pending')
-- the collector ghost north of the railgun: in range, outside its arc, uncovered
local c=p.collectors[1]
eq(c.ghost,true); eq(c.covered_by,0); eq(#c.uncovered,4); eq(c.outside_arc[1].name,'railgun-turret')
has(line(r,'planned: 1 collector'),'asteroid-collector ghost (0,-60) (front (0,-60)): NO built or planned turret reaches it')
has(line(r,'planned: 1 collector'),'outside the arc')

-- the job: a chunk at a time, then the edges, then the lines
for _=1,200 do game.tick=game.tick+1; D.tick(game.tick) end
assert(next(storage.platplan.jobs)==nil,'the job done')
r=D.read({},{platform='Plan',planned=true})
p=r.planned
eq(p.foundation_tiles,40); eq(p.foundation_ghosts,40); eq(p.sides_as_of,1000)
has(line(r,'planned: the hull read at tick 1000'),'40 foundation tiles and 40 foundation tile ghosts')
local ps={}
for _,row in ipairs(p.sides) do ps[row.side]=row end
-- north edge y=-2: small and medium none engages; big (rocket ghost) and huge (railgun ghost, inside its arc) by ghosts only
eq(ps.north.edge_tiles,10); eq(ps.north.by_size.small.uncovered,10); eq(ps.north.by_size.medium.uncovered,10)
eq(ps.north.by_size.big.uncovered,0); eq(ps.north.by_size.big.ghost_only,10); eq(ps.north.by_size.huge.ghost_only,10)
-- south edge y=5 (the ghost hull's): the rocket ghost 25 away reaches it, past its minimum range
eq(ps.south.edge_tiles,10); eq(ps.south.by_size.big.ghost_only,10)
-- east and west: the whole planned hull's height
eq(ps.east.edge_tiles,8); eq(ps.west.edge_tiles,8)
has(line(r,'planned: north side'),'big all covered, 10 more covered only by turret ghosts')
-- kept PLAN_KEEP ticks, then read again
game.tick=game.tick+D.PLAN_KEEP+1
r=D.read({},{platform='Plan',planned=true})
assert(r.planned.sides_pending,'read again after PLAN_KEEP')
defines,game,storage=nil,nil,nil
print('d21_batch72b AH2 planned platform defense: ok')
