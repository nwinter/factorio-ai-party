-- Run from repository root: lua tests/belt.lua
-- The on-belt note (belt.lua) against a fake engine: the character's tile is
-- searched once, a game without the Space Age belt types falls back to the
-- base ones, and a character in a vehicle or off belts gets no note.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={direction={north=0,east=4,south=8,west=12}}
local belt=require('belt')()
local searches={}
local found={valid=true,name='transport-belt',direction=4}
local surface={}
surface.find_entities_filtered=function(f)
  searches[#searches+1]=f
  for _,t in ipairs(f.type) do if t=='lane-splitter' and surface.base_only then error('unknown entity type lane-splitter') end end
  return surface.here and {surface.here} or {}
end
local p={valid=true,character={valid=true},position={x=-15.78,y=-17.64},surface=surface,driving=false}
surface.here=found
eq(belt.note(p),'standing on a transport-belt facing east: it carries you; step off to stay put')
eq(#searches,1); eq(searches[1].area[1][1],-16); eq(searches[1].area[1][2],-18); eq(searches[1].area[2][1],-15); eq(searches[1].limit,1)
surface.base_only=true
found.name='underground-belt'; found.direction=12
eq(belt.note(p),'standing on an underground-belt facing west: it carries you; step off to stay put')
eq(#searches,3); eq(#searches[3].type,3)
surface.base_only=false
p.driving=true; eq(belt.note(p),nil); p.driving=false
surface.here=nil; eq(belt.note(p),nil)
p.character=nil; eq(belt.note(p),nil)
print('belt: ok')
