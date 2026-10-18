-- Run from repository root: lua tests/d17_batch23.lua
-- d17 batch23: the agents' 19:50 poll.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Sol): platform_defense cover by asteroid size, from each turret's priority list and minimum range.
do
  defines={inventory={turret_ammo=1}}
  local function turret(name,x,y,range,min,only)
    local list={}
    for _,n in ipairs(only or {}) do list[#list+1]={name=n} end
    return {valid=true,type='ammo-turret',name=name,position={x=x,y=y},bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}},
      get_inventory=function() return {get_contents=function() return {{name='rocket',count=20}} end} end,
      prototype={attack_parameters={range=range,min_range=min}},ignore_unprioritised_targets=only~=nil,
      get_priority_target=function(i) return list[i] end}
  end
  local rocket=turret('rocket-turret',0,-20,36,15,{'big-oxide-asteroid','big-carbonic-asteroid','big-metallic-asteroid'})
  local gun=turret('gun-turret',20,0,18,0,nil)
  local tiles={}
  for x=0,3 do tiles[#tiles+1]={position={x=x,y=0}} end
  local s={find_entities_filtered=function(f) if f.type=='asteroid-collector' or f.type=='inserter' then return {} end return {rocket,gun} end,
    find_tiles_filtered=function() return tiles end}
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Swiftlet',surface=s,force='f'} end}
  local r=D.read({},{platform='Swiftlet'})
  eq(r.turrets[1].engages,'only big-carbonic-asteroid, big-metallic-asteroid, big-oxide-asteroid (ignores the rest)')
  eq(r.turrets[1].min_range,15); eq(r.turrets[2].engages,'every asteroid')
  local north
  for _,row in ipairs(r.sides) do if row.side=='north' then north=row end end
  -- tiles 0 and 1 are past the gun's 18: only the rocket turret reaches them, and it engages big ones only
  eq(north.edge_tiles,4); eq(north.by_size.small.uncovered,2); eq(north.by_size.medium.uncovered,2); eq(north.by_size.huge.uncovered,2)
  eq(north.by_size.big.uncovered,0)
  local line
  for _,l in ipairs(r.lines) do if l:find('^north side') then line=l end end
  has(line,'north side: 4 edge tiles, 2 where a size is not covered; small 2 uncovered ((0,0)-(1,0) 2 tiles); medium 2 uncovered')
  has(line,'big all covered')
  local by
  for _,l in ipairs(r.lines) do if l:find('^by their priority lists') then by=l end end
  has(by,'rocket-turret (0,-20) engages only big-carbonic-asteroid, big-metallic-asteroid, big-oxide-asteroid (ignores the rest), not within 15 tiles')
  -- inside the minimum range the rocket turret reaches nothing
  rocket.position={x=0,y=-5}
  r=D.read({},{platform='Swiftlet'})
  for _,row in ipairs(r.sides) do if row.side=='north' then north=row end end
  eq(north.by_size.big.uncovered,2)
  defines=nil
end
print('d17_batch23 A1 platform_defense by asteroid size: ok')
