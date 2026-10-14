-- Run from repository root: lua tests/sidefeed.lua
-- Underground entrances fed from the side (sidefeed.lua; Sol, shift10). The
-- lanes come from a private 2.0.77 server, burner inserters and belts into
-- underground pairs, 12 s each: an inserter east of an entrance flowing north
-- filled its line 1 (left, west) only; a belt flowing west into its east side
-- passed its right (north) lane and stopped its left (south) one; a belt
-- flowing east into its west side passed its left (north) lane; a belt flowing
-- south into the north side of an entrance flowing east passed its left
-- (east) lane.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
local F = dofile('mod/agent-harness_0.1.0/sidefeed.lua'){try=function(fn) local ok, v = pcall(fn); if ok then return v end end}
local north = {name='underground-belt', position={x=6.5, y=84.5}, direction=0, kind='input'}
-- Inserters beside it: the far lane only.
eq(F.inserter('burner-inserter', {x=7.5, y=84.5}, {x=6.30078125, y=84.5}, north),
  'burner-inserter (7.5,84.5) drops onto underground-belt (6.5,84.5), an entrance flowing north, from its east side: only its west (left) lane gets these items; its east (right) lane gets none from it')
eq(F.inserter('inserter', {x=5.5, y=84.5}, {x=6.69921875, y=84.5}, north),
  'inserter (5.5,84.5) drops onto underground-belt (6.5,84.5), an entrance flowing north, from its west side: only its east (right) lane gets these items; its west (left) lane gets none from it')
-- Behind it or in front of it: not from a side; an exit; a drop on another tile.
eq(F.inserter('inserter', {x=6.5, y=85.5}, {x=6.5, y=84.3}, north), nil, 'from behind')
eq(F.inserter('inserter', {x=6.5, y=83.5}, {x=6.5, y=84.7}, north), nil, 'in front')
eq(F.inserter('inserter', {x=7.5, y=84.5}, {x=6.3, y=84.5}, {name='underground-belt', position={x=6.5, y=84.5}, direction=0, kind='output'}), nil, 'an exit')
eq(F.inserter('inserter', {x=7.5, y=84.5}, {x=5.3, y=84.5}, north), nil, 'drops past it')
-- A long-handed inserter two tiles off still drops from that side.
eq(F.inserter('long-handed-inserter', {x=8.5, y=84.5}, {x=6.3, y=84.5}, north):match('from its east side') ~= nil, true)
-- Belts side-loading it: the lane on its downstream side goes in.
eq(F.belt('transport-belt', {x=7.5, y=84.5}, 12, north),
  'transport-belt (7.5,84.5) side-loads underground-belt (6.5,84.5), an entrance flowing north, from its east side: only the belt\'s north (right) lane goes in; its south (left) lane stops at the entrance')
eq(F.belt('transport-belt', {x=5.5, y=84.5}, 4, north),
  'transport-belt (5.5,84.5) side-loads underground-belt (6.5,84.5), an entrance flowing north, from its west side: only the belt\'s north (left) lane goes in; its south (right) lane stops at the entrance')
local east = {name='underground-belt', position={x=9.5, y=72.5}, direction=4, kind='input'}
eq(F.belt('transport-belt', {x=9.5, y=71.5}, 8, east):match('only the belt\'s east %(left%) lane goes in; its west %(right%) lane stops') ~= nil, true)
-- In line (feeding it straight), pointing elsewhere, or into an exit: nothing.
eq(F.belt('transport-belt', {x=6.5, y=85.5}, 0, north), nil, 'straight in')
eq(F.belt('transport-belt', {x=7.5, y=84.5}, 0, north), nil, 'runs past it')
eq(F.belt('transport-belt', {x=7.5, y=84.5}, 12, {name='underground-belt', position={x=6.5, y=84.5}, direction=0, kind='output'}), nil)
-- Built entities: an inserter onto an entrance, a belt into one, an entrance beside both.
local ug = {valid=true, type='underground-belt', name='underground-belt', position={x=6.5, y=84.5}, direction=0, belt_to_ground_type='input', force='us'}
local ins = {valid=true, type='inserter', name='inserter', position={x=7.5, y=84.5}, drop_position={x=6.3, y=84.5}, direction=4, force='us'}
local belt = {valid=true, type='transport-belt', name='transport-belt', position={x=5.5, y=84.5}, direction=4, force='us'}
local surface = {find_entities_filtered=function(f)
  if f.type == 'underground-belt' and f.position then
    return (math.floor(f.position.x) == 6 and math.floor(f.position.y) == 84) and {ug} or {}
  end
  if f.type == 'transport-belt' and f.position then
    return (math.floor(f.position.x) == 5 and math.floor(f.position.y) == 84) and {belt} or {}
  end
  if f.type == 'inserter' and f.area then return {ins} end
  return {}
end}
ug.surface, ins.surface, belt.surface = surface, surface, surface
local lines = F.built(ins)
eq(#lines, 1); eq(lines[1]:match('^inserter %(7.5,84.5%) drops onto') ~= nil, true)
lines = F.built(belt)
eq(#lines, 1); eq(lines[1]:match('^transport%-belt %(5.5,84.5%) side%-loads') ~= nil, true)
lines = F.built(ug)
eq(#lines, 2, 'the inserter and the belt beside it')
ug.belt_to_ground_type = 'output'
eq(#F.built(ug), 0, 'an exit')
print('sidefeed: ok')
