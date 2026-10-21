-- Run from repository root: lua tests/railrun.lua
-- Elevated rails the game keeps (d20 batch69 AE1, Sol #1642) against a fake engine shaped by what 2.0.77 did on the
-- private copy: a rail support at (0,1) with elevated straight rails from x=-9 to 9 (2 tiles each, support_range 11)
-- leaves only -9 and 9 minable; the support reads not minable; a planner over the support marks it and the run.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
defines={rail_direction={front=0,back=1},rail_connection_direction={left=0,straight=1,right=2}}
local SUPPORT_PROTO={support_range=11}
local entities,by_x={},{}
local surface={}
local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local function new(t)
  t.valid=true; t.marked=false
  t.to_be_deconstructed=function() return t.marked end
  entities[#entities+1]=t
  return t
end
local unit=100
local function rail(x)
  unit=unit+1
  local r=new{name='elevated-straight-rail',type='elevated-straight-rail',position={x=x,y=1},unit_number=unit,surface=surface,minable_flag=true}
  r.get_connected_rail=function(a)
    if a.rail_connection_direction~=defines.rail_connection_direction.straight then return nil end
    return by_x[x+(a.rail_direction==defines.rail_direction.front and 2 or -2)]
  end
  by_x[x]=r
  return r
end
for x=-9,9,2 do rail(x) end
local support=new{name='rail-support',type='rail-support',position={x=0,y=1},unit_number=1,surface=surface,minable_flag=true,prototype=SUPPORT_PROTO,
  bounding_box={left_top={x=-1.39,y=-0.39},right_bottom={x=1.39,y=2.39}}}
-- the game's rule, as read on 2.0.77: only the ends of the run the support carries; the support while rails rest on it
local function settle()
  local xs={}
  for x,r in pairs(by_x) do if r.valid then xs[#xs+1]=x end end
  table.sort(xs)
  for x,r in pairs(by_x) do r.minable=(x==xs[1] or x==xs[#xs]) end
  support.minable=#xs==0
end
settle()
local function types(t) local o={} for _,v in ipairs(type(t)=='table' and t or {t}) do o[v]=true end return o end
function surface.find_entities_filtered(f)
  local out,want={},f.type and types(f.type)
  for _,e in ipairs(entities) do
    if e.valid and (not want or want[e.type]) and (not f.radius or dist(e.position,f.position)<=f.radius) then out[#out+1]=e end
  end
  return out
end
local planner_calls=0
function surface.deconstruct_area(a)
  planner_calls=planner_calls+1
  local f=a.item and a.item.entity_filters
  assert(f and f[1]=='rail-support','a planner filtered to the support')
  support.marked=true
  for _,r in pairs(by_x) do if r.valid then r.marked=true end end
end
game={create_inventory=function()
  local stack={}
  local inv={insert=function() return 1 end,destroy=function() end}
  return setmetatable(inv,{__index=function(_,k) if k==1 then return stack end end})
end}

local R=dofile('mod/agent-harness_0.1.0/railrun.lua'){}
-- a rail inside the run: why, the support carrying it, the nearest that can go now each way
local w=R.why(by_x[3])
has(w,'the game lets an elevated rail go only from an end of the run a rail support carries: rail-support (0,1) carries this one')
has(w,'the nearest that can go now along these rails: elevated-straight-rail (9,1), elevated-straight-rail (-9,1)')
has(w,'a deconstruction planner marks nothing over a rail inside a run, and over the support it marks the support and every rail it carries')
eq(R.why(by_x[9]),nil,'an end can go')
-- an end taken: the next one in frees
by_x[9].valid=false; settle()
eq(by_x[7].minable,true)
has(R.why(by_x[3]),'elevated-straight-rail (7,1), elevated-straight-rail (-9,1)')
-- the support
has(R.why(support),'a rail support goes only once no elevated rail rests on it: 9 within its reach (11 tiles); marking it for deconstruction marks them with it')
eq(#R.carried(support),9)
eq(#R.supports(by_x[3]),1)
-- its flag off (a script): said
local off={valid=true,name='stone-furnace',type='furnace',position={x=4,y=4},minable=false,minable_flag=false}
has(R.why(off),'its minable flag is off')
has(R.why({valid=true,name='x',type='furnace',position={x=0,y=0},minable=false,minable_flag=true}),'the game reads it not minable now (its minable flag is on)')
-- mark_support: as a planner, the support and the rails it carries
local by,err,n,units=R.mark_support({surface=surface,force={name='player'}},support,nil)
eq(err,nil); eq(planner_calls,1); eq(by['rail-support'],1); eq(by['elevated-straight-rail'],9); eq(n,9)
eq(units[support.unit_number],true); eq(units[by_x[3].unit_number],true)
print('railrun ok')
