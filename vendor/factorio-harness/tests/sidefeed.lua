-- Run from repository root: lua tests/sidefeed.lua
-- Native 2.0.77 transport-line observations: batch462 (all directions and ends).
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
-- Belts side-loading an entrance: the upstream lane goes in.
eq(F.belt('transport-belt', {x=7.5, y=84.5}, 12, north),
  'transport-belt (7.5,84.5) side-loads underground-belt (6.5,84.5), an entrance flowing north, from its east side: only the belt\'s south (left) lane goes in; its north (right) lane stops at the entrance')
eq(F.belt('transport-belt', {x=5.5, y=84.5}, 4, north),
  'transport-belt (5.5,84.5) side-loads underground-belt (6.5,84.5), an entrance flowing north, from its west side: only the belt\'s south (right) lane goes in; its north (left) lane stops at the entrance')
local east = {name='underground-belt', position={x=9.5, y=72.5}, direction=4, kind='input'}
eq(F.belt('transport-belt', {x=9.5, y=71.5}, 8, east):match('only the belt\'s west %(right%) lane goes in; its east %(left%) lane stops') ~= nil, true)
-- In line or pointing elsewhere: nothing. An exit passes the opposite lane.
eq(F.belt('transport-belt', {x=6.5, y=85.5}, 0, north), nil, 'straight in')
eq(F.belt('transport-belt', {x=7.5, y=84.5}, 0, north), nil, 'runs past it')
eq(F.belt('transport-belt', {x=7.5, y=84.5}, 12, {name='underground-belt', position={x=6.5, y=84.5}, direction=0, kind='output'}):match('north %(right%) lane goes in') ~= nil, true)
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
eq(#F.built(ug), 1, 'an exit reports the belt, not the inserter')

-- Recorded native transport-line results, 120 ticks, one iron on line 1 and
-- one copper on line 2: four flows, both ends, both perpendicular approaches.
local cases = {
  {0, 'input', 4, 'south', 'right', 'north', 'left'},
  {0, 'input', 12, 'south', 'left', 'north', 'right'},
  {0, 'output', 4, 'north', 'left', 'south', 'right'},
  {0, 'output', 12, 'north', 'right', 'south', 'left'},
  {4, 'input', 8, 'west', 'right', 'east', 'left'},
  {4, 'input', 0, 'west', 'left', 'east', 'right'},
  {4, 'output', 8, 'east', 'left', 'west', 'right'},
  {4, 'output', 0, 'east', 'right', 'west', 'left'},
  {8, 'input', 12, 'north', 'right', 'south', 'left'},
  {8, 'input', 4, 'north', 'left', 'south', 'right'},
  {8, 'output', 12, 'south', 'left', 'north', 'right'},
  {8, 'output', 4, 'south', 'right', 'north', 'left'},
  {12, 'input', 0, 'east', 'right', 'west', 'left'},
  {12, 'input', 8, 'east', 'left', 'west', 'right'},
  {12, 'output', 0, 'west', 'left', 'east', 'right'},
  {12, 'output', 8, 'west', 'right', 'east', 'left'},
}
local steps = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
for _, q in ipairs(cases) do
  local d = steps[q[3]]
  local expected = "only the belt's "..q[4]..' ('..q[5]..') lane goes in; its '..q[6]..' ('..q[7]..') lane stops at the '..(q[2]=='input' and 'entrance' or 'exit')
  local line = F.belt('transport-belt', {x=6.5-d[1],y=84.5-d[2]}, q[3], {name='underground-belt',position={x=6.5,y=84.5},direction=q[1],kind=q[2]})
  eq(line:find(expected, 1, true) ~= nil, true, q[1]..' '..q[2]..' feeder '..q[3])
end
print('sidefeed: ok')
