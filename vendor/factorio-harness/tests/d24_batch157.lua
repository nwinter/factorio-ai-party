-- d24 batch157 QA1 (Astra #2205: logistics_audit storage said 156 free slots after a 48-slot chest with bar 10 and one
-- slot used joined network 348, 47 more than before where 9 are usable): free slots are those under each inventory's
-- bar (LuaInventory.count_empty_stacks(true, false)); the physical count apart. Run: lua tests/d24_batch157.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={inventory={chest=1,robot_cargo=2,hub_main=3,cargo_landing_pad_main=4}}
game={tick=57239009}
-- An inventory as 2.0.77 counts it: count_empty_stacks(include_filtered, include_bar) (both default true); with
-- include_bar false only slots 1..bar-1 count (read on a copy of world n: 32 slots, bar 11, 1 used: 31 and 9).
local function inventory(size,used,bar)
  local inv=setmetatable({},{__len=function() return size end})
  inv.get_bar=function() return bar or size+1 end
  inv.supports_bar=function() return true end
  inv.count_empty_stacks=function(_,include_bar)
    local last=include_bar==false and math.min(size,(bar or size+1)-1) or size
    return math.max(0,last-math.min(used,last))
  end
  inv.get_contents=function() return {} end
  inv.is_empty=function() return used==0 end
  return inv
end
local function chest(x,y,inv,filter)
  return {valid=true,type='logistic-container',name='storage-chest',position={x=x,y=y},storage_filter=filter,
    get_inventory=function() return inv end}
end
local list={}
-- 109 free slots before: 48 + 21 + 40 free, and one full chest
list[#list+1]=chest(0.5,0.5,inventory(48,0))
list[#list+1]=chest(1.5,0.5,inventory(48,27))
list[#list+1]=chest(2.5,0.5,inventory(48,8))
list[#list+1]=chest(3.5,0.5,inventory(48,48))
local ln={network_id=348,storages=list,logistic_robots={},construction_robots={}}
local surface={name='aquilo'}
local L=dofile('mod/agent-harness_0.1.0/logaudit.lua'){state=function() return {} end}
local before=L.storage({},{},surface,ln)
eq(before.free_slots,109)
-- Astra's chest: 48 slots, prometheum filter, 48 held in 1 slot, bar 10 (configure bar 10: set_bar(11))
list[#list+1]=chest(20.5,4.5,inventory(48,1,11),{name='promethium-asteroid-chunk'})
local r=L.storage({},{},surface,ln)
eq(r.free_slots,118,'free slots stop at the bar'); eq(r.usable_free_slots,118); eq(r.physical_free_slots,156); eq(r.chests_with_bar,1)
has(r.line,'118 free slots under their bars (156 empty slots in all: 38 past the bars of 1 chest, which robots do not fill)')
-- a chest whose bar leaves no free slot counts full
list[#list]=chest(20.5,4.5,inventory(48,10,11))
r=L.storage({},{},surface,ln)
eq(r.free_slots,109); eq(r.full_chests,2); eq(r.physical_free_slots,147)
-- fullchest's slots_of: free under the bar too
local F=dofile('mod/agent-harness_0.1.0/fullchest.lua')
F=type(F)=='function' and F({}) or F
if F.slots_of then
  local s=F.slots_of({valid=true,type='container',name='iron-chest',get_inventory=function() return inventory(32,1,11) end})
  eq(s.free,9,'fullchest free under the bar'); eq(s.used,1); eq(s.usable,10)
  eq(F.free_note({valid=true,type='container',name='iron-chest',get_inventory=function() return inventory(32,1,11) end}),', 9 of 10 usable slots free (bar; 32 slots)')
end
print('d24_batch157 QA1 free slots under the bar: ok')
