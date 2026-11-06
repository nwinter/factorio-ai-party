-- Storage observations, confirmed failures, and bounded deployed-robot coverage.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(s:find(t,1,true),s..' lacks '..t) end
defines={inventory={chest=1,robot_cargo=2}}
local L=dofile('mod/agent-harness_0.1.0/logaudit.lua'){}
local reads=0
local function robot(name,orders,quality)
  return {robot_order_queue=orders or {}, get_inventory=function()
    reads=reads+1
    return {is_empty=function() return not name end,
      get_contents=function() return name and {{name=name,quality=quality,count=4}} or {} end}
  end}
end
local function audit(ln) return L.storage({},{},{name='nauvis'},ln) end
local calls=0
local ln={network_id=12,storages={},logistic_robots={robot('iron-plate'),robot('copper-plate'),
  robot('steel-plate',{{target={valid=true,position={x=1,y=2}}}}),robot()},
  construction_robots={robot('iron-plate',nil,{name='rare'})},
  select_drop_point=function(a)
    calls=calls+1; eq(a.stack.count,1)
    if a.stack.name=='copper-plate' then return {} end
    -- Quality is part of the cache key; the normal item has no room, rare does.
    if a.stack.quality=='rare' then return {} end
  end}
local r=audit(ln)
eq(r.robots_read,5); eq(r.robots_total,5); eq(r.robot_scan_cap_hit,false)
eq(r.cargo_no_order,3); eq(r.cargo_with_orders,1); eq(r.no_storage,1); eq(calls,3)
eq(r.robots_stuck,1); eq(r.stuck_items[1],'iron-plate 4'); eq(#r.no_storage_items,1)
eq(r.cargo_no_order_items[3],'iron-plate@rare 4'); eq(r.cargo_with_orders_items[1],'steel-plate 4')
has(r.line,'3 hold cargo with no order (no destination)'); has(r.line,'1 hold cargo with orders: steel-plate 4')
has(r.line,'1 confirmed no-storage failures'); has(r.line,'robots scanned 5 of 5 deployed')
eq(r.storage_room_unconfirmed,0)

-- Both robot lists are read once; no robot past the shared cap is inspected. A stored
-- population count must not be used as the denominator of a deployed-robot scan.
local bots={}
for i=1,2050 do bots[i]=robot('iron-plate') end
local list_reads={logistic_robots=0,construction_robots=0}
local capped=setmetatable({network_id=1,storages={},all_logistic_robots=9999,
  select_drop_point=function() calls=calls+1 end},{__index=function(_,k)
    if list_reads[k] then list_reads[k]=list_reads[k]+1; return k=='logistic_robots' and bots or {robot('wood')} end
  end})
reads,calls=0,0
r=audit(capped)
eq(reads,2048); eq(calls,1); eq(list_reads.logistic_robots,1); eq(list_reads.construction_robots,1)
eq(r.coverage.scanned,2048); eq(r.coverage.total,2051); eq(r.robots_unscanned,3)
eq(r.robot_scan_cap,2048); eq(r.robot_scan_cap_hit,true); eq(r.no_storage,2048)
has(r.line,'robots scanned 2048 of 2051 deployed'); has(r.line,'scan cap 2048 hit'); has(r.line,'among scanned:')
-- The cap is shared across types, including when it falls inside the construction list.
ln.logistic_robots={robot('iron-plate')}; ln.construction_robots=bots
reads=0; r=audit(ln); eq(reads,2048); eq(r.robots_total,2051); eq(r.robots_unscanned,3)
ln.logistic_robots={}; ln.construction_robots={}
for i=1,2048 do ln.construction_robots[i]=robot() end
r=audit(ln); eq(r.robot_scan_cap_hit,true); eq(r.robots_unscanned,0); eq(r.no_storage,0)
ln.construction_robots={}; r=audit(ln)
eq(r.robots_read,0); eq(r.robots_total,0); eq(r.robot_scan_cap_hit,false)
eq(r.no_storage_items,nil); has(r.line,'robots scanned 0 of 0 deployed')

-- A room-lookup error is not a confirmed failure. Cache it too, so repeated cargo
-- does not consume the bounded engine-query budget repeatedly.
ln.logistic_robots={robot('iron-plate'),robot('iron-plate')}
ln.select_drop_point=function() calls=calls+1; error('unavailable') end
calls=0; r=audit(ln)
eq(calls,1); eq(r.no_storage,0); eq(r.no_storage_items,nil); eq(r.storage_room_unconfirmed,2)
has(r.line,'storage room unconfirmed for 2 cargo robots')
-- Excess distinct cargo is still reported, with incomplete room checks explicit.
ln.logistic_robots={}
for i=1,33 do ln.logistic_robots[i]=robot('item-'..i) end
ln.select_drop_point=function() calls=calls+1 end
calls=0; r=audit(ln)
eq(calls,32); eq(r.storage_room_checks,32); eq(r.storage_room_check_cap,32)
eq(r.cargo_no_order,33); eq(r.no_storage,32); eq(r.storage_room_unconfirmed,1)
eq(#r.cargo_no_order_items,33); eq(#r.no_storage_items,32)
-- Unreadable orders cannot be reclassified as no order or no storage.
local unreadable=robot('iron-plate'); unreadable.robot_order_queue=nil
setmetatable(unreadable,{__index=function() error('unreadable') end})
ln.logistic_robots={unreadable}; r=audit(ln)
eq(r.cargo_unknown_order,1); eq(r.cargo_no_order,0); eq(r.no_storage,0)
print('logaudit storage: cargo, confirmed failures, coverage and bounded work ok')
