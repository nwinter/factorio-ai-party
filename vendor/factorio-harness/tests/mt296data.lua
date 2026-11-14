package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function clone(v) if type(v)~='table' then return v end local r={} for k,x in pairs(v) do r[k]=clone(x) end return r end
table.deepcopy=clone
mods={recycler='2.1.24'}
data={raw={container={['steel-chest']={type='container',inventory_size=48,minable={result='steel-chest'}}},
 unit={['small-biter']={type='unit',attack_parameters={ammo_type={action={}}}}}},prototypes={}}
function data:extend(list) for _,p in ipairs(list) do assert(not self.prototypes[p.name]);self.prototypes[p.name]=p end end
dofile('mod/agent-harness_0.1.0/data.lua')
local p=data.prototypes
assert(p['mt-coinage'].enabled==false and p['mt-coinage'].visible_when_disabled==false)
assert(p['mt-coinage'].unit.ingredients[1][1]=='automation-science-pack')
assert(p['mt-trading-post'].hidden and not p['mt-trading-post'].minable)
assert(p['mt-coin'].hidden and p['mt-coin'].stack_size==1000)
assert(p['mt-coin'].auto_recycle==false)
local r=p['mt-coin-recycling'];assert(r.categories[1]=='recycling' and r.enabled)
assert(r.ingredients[1].name=='mt-coin' and r.ingredients[1].amount==1)
assert(r.results[1].name=='mt-coin' and r.results[1].amount==1 and not r.results[1].independent_probability)
assert(r.auto_recycle==false and r.allow_productivity==false and r.allow_quality==false)
for name,v in pairs(p) do assert(v.type~='recipe' or name=='mt-coin-recycling','no coin minting/withdrawal recipe') end
assert(data.raw.container['steel-chest'].minable.result=='steel-chest','base prototype unchanged')
assert(p['mt-shipment'].radar_range==0 and not p['mt-shipment'].minable and not p['mt-shipment'].loot)
assert(p['mt-shipment'].ai_settings.allow_destroy_when_commands_fail==false)
print('mt296 data: contact-hidden red science, Post and uncraftable coin: ok')
