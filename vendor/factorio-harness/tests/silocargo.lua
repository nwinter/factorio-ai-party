-- Run from repository root: lua tests/silocargo.lua
-- A silo's rocket cargo comes out by hand without a launch (Luna, shift17 10:50: 447 spoilage in Gleba's rocket "and no
-- way to clear it"; transfer to_player with inventory rocket_silo_rocket did it at 11:46): silo.lua's inventory rows
-- give the take, spoilage first, and count the spoilage aboard.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={crafter_input=2,rocket_silo_rocket=14,rocket_silo_trash=15}}
local S=dofile('mod/agent-harness_0.1.0/silo.lua'){cargo={limits=function() return 1000 end,kg=function(x) return x end}}
local function inv(list) return {get_contents=function() local o={} for i,s in ipairs(list) do o[i]={name=s[1],count=s[2]} end return o end} end
local cargo=inv{{'agricultural-science-pack',400},{'spoilage',447}}
local silo={position={x=65.5,y=14.5},get_recipe=function() return {name='rocket-part',ingredients={{type='item',name='low-density-structure'}}} end,
  get_inventory=function(i) return i==14 and cargo or i==2 and inv{} or i==15 and inv{} or nil end}
local function encode(t)
  local keys={} for k in pairs(t) do keys[#keys+1]=k end table.sort(keys)
  local parts={} for _,k in ipairs(keys) do local v=t[k] parts[#parts+1]=k..'='..(type(v)=='table' and (v.x..','..v.y) or tostring(v)) end
  return table.concat(parts,';')
end
local rows=S.inventories(silo,encode)
local c=rows[2]
eq(c.inventory,'rocket_silo_rocket'); eq(c.spoilage,447)
assert(c.what:find('it comes out by hand without a launch',1,true),c.what)
eq(c.take_example,"fh call transfer --args 'direction=to_player;inventory=rocket_silo_rocket;item=spoilage;position=65.5,14.5'")
-- no spoilage: the first item it holds; an empty rocket: no take
cargo=inv{{'space-platform-foundation',10}}
c=S.inventories(silo,encode)[2]; eq(c.spoilage,nil); assert(c.take_example:find('item=space-platform-foundation',1,true),c.take_example)
cargo=inv{}
c=S.inventories(silo,encode)[2]; eq(c.take_example,nil)
print('silocargo: ok')
