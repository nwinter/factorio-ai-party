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
