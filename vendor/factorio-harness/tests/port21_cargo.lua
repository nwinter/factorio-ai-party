package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
script={active_mods={base='2.1.24'}}
defines={inventory={rocket_silo_rocket=21},rocket_silo_status={rocket_ready=7}}
prototypes={item={},utility_constants={default_rocket_lift_weight=1000000},entity={}}
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local list={}
for i=1,26 do local name='item-'..i;prototypes.item[name]={weight=1000,stack_size=1};list[i]={name=name,count=1} end
prototypes.item.heavy={weight=1000001,stack_size=1};prototypes.item.zero={weight=0,stack_size=1}
local C=dofile('mod/agent-harness_0.1.0/cargo.lua'){}
local inv={get_contents=function() return {} end,count_empty_stacks=function() return 0 end}
local silo={name='rocket-silo',type='rocket-silo',position={x=0,y=0},prototype={lift_weight=1000000},
 get_inventory=function() return inv end}
local lift,slots=C.limits(silo);eq(slots,math.huge)
local w=C.weigh(list,lift,slots);eq(w.rockets,1);eq(w.fewest,1);eq(w.stacks,26);assert(w.weight_only)
local one=C.one_rocket(list,lift,slots);eq(#one.items,26);eq(one.room_slots,nil);assert(one.weight_only)
local q=C.weigh({{name='item-1',count=600},{name='item-1',quality='rare',count=600}},lift,slots)
eq(q.rockets,2);eq(q.total_kg,1200)
local ok,err=pcall(C.one_rocket,{{name='heavy',count=1}},lift,slots);assert(not ok and tostring(err):find('does not fit',1,true))
ok=pcall(C.one_rocket,list,lift,slots,'zero');assert(not ok)
local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){give_sources=function() return {} end,cargo=C}
eq(#R.items(list),26);eq(R.split(list,lift,slots),nil)
local plan=R.plan({force={platforms={}}},{items=list,chests=false},silo,lift,slots)
assert(plan.fits_one_rocket and plan.rocket.weight_only);eq(plan.rocket.slots,nil);eq(plan.rocket.free_slots,nil)
local function finite(t)
 for _,v in pairs(t) do if type(v)=='number' then assert(v==v and math.abs(v)<math.huge) elseif type(v)=='table' then finite(v) end end
end
finite(w);finite(one);finite(plan)
-- The legacy slot-bound result remains separate.
script.active_mods.base='2.0.77';prototypes.entity['rocket-silo']={get_inventory_size=function() return 20 end}
C=dofile('mod/agent-harness_0.1.0/cargo.lua'){};lift,slots=C.limits(silo);eq(slots,20);eq(C.weigh(list,lift,slots).rockets,2)
print('port21 cargo: dynamic zero-slot inventory, 26 kinds in one rocket, quality/weight splits, finite replies and 2.0 slot bound passed')
