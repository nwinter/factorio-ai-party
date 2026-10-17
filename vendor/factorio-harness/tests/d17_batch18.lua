package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,w) assert(s and s:find(w,1,true),tostring(s)..' lacks '..w) end
local function lacks(s,w) assert(not (s and s:find(w,1,true)),tostring(s)..' has '..w) end
game={tick=600}
defines={entity_status={waiting_for_source_items=32,working=1},inventory={chest=1},robot_order_type={pickup=1,deliver=2}}

-- A1 (Grok): why an inserter waits for source items.
prototypes={item={['rocket-fuel']={fuel_value=100e6},['yumako-seed']={fuel_value=4e6},['iron-plate']={fuel_value=0}}}
local D=require('details'){}
local function inv(list)
  return {get_contents=function() return list end}
end
local robots={}
local net={network_id=98,get_item_count=function(n) return n=='rocket-fuel' and 0 or 5 end}
local chest={valid=true,name='requester-chest',type='logistic-container',position={x=49.5,y=48.5},prototype={logistic_mode='requester'},
  logistic_network=net,get_output_inventory=function() return inv({{name='rocket-fuel',count=7},{name='spoilage',count=200}}) end,
  surface={find_entities_filtered=function() return robots end}}
local fuel=inv({{name='rocket-fuel',count=5}})
local tower={valid=true,name='heating-tower',type='reactor',position={x=46.5,y=48.5},get_fuel_inventory=function() return fuel end,
  can_insert=function() return true end,prototype={get_max_energy_usage=function() return 40e6/60 end}}
setmetatable(fuel,{__len=function() return 2 end})
local ins={type='inserter',name='fast-inserter',position={x=48.5,y=48.5},status=32,pickup_target=chest,drop_target=tower,
  use_filters=true,filter_slot_count=5,inserter_filter_mode='whitelist',get_filter=function(k) return k==1 and {name='rocket-fuel',quality='normal'} or nil end}
local w=D.pickup_wait(ins)
has(w,'requester-chest (49.5,48.5) holds rocket-fuel 7');lacks(w,'spoilage 200')
has(w,'its logistic network 98 holds rocket-fuel 0 outside requester chests')
has(w,'heating-tower (46.5,48.5) takes rocket-fuel; its 2 fuel slots hold rocket-fuel 5');has(w,'top fuel up only while it runs low')
has(w,'burns 24.0 rocket-fuel a minute')
-- the fuel slots taken by other fuels: the tower takes none
fuel.get_contents=function() return {{name='yumako-seed',count=10},{name='spoilage',count=10}} end
tower.can_insert=function() return false end
w=D.pickup_wait(ins);has(w,'takes no rocket-fuel now: its 2 fuel slots hold yumako-seed 10, spoilage 10')
-- nothing it may take in the chest; robots on their way to take from it
chest.get_output_inventory=function() return inv({{name='spoilage',count=200}}) end
robots={{robot_order_queue={{type=1,target=chest}}},{robot_order_queue={{type=2,target=chest}}}}
w=D.pickup_wait(ins);has(w,'holds none of rocket-fuel');has(w,'1 logistic robot near it on the way to take from it')
-- another status: no line
ins.status=1;eq(D.pickup_wait(ins),nil)
-- a machine drop target
ins.status=32;robots={}
chest.get_output_inventory=function() return inv({{name='iron-plate',count=40}}) end
ins.get_filter=function() return nil end
local asm={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=47,y=48},can_insert=function() return true end,
  get_item_count=function() return 12 end}
ins.drop_target=asm
w=D.pickup_wait(ins);has(w,'holds iron-plate 40');has(w,'assembling-machine-2 (47,48) takes iron-plate and holds 12 of it')
asm.can_insert=function() return false end;asm.get_recipe=function() return {name='gear'} end
w=D.pickup_wait(ins);has(w,'takes no iron-plate now (recipe gear)')

print('d17 batch18 ok')
