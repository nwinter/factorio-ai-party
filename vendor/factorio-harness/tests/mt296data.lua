package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function clone(v) if type(v)~='table' then return v end local r={} for k,x in pairs(v) do r[k]=clone(x) end return r end
table.deepcopy=clone
data={raw={container={['steel-chest']={type='container',inventory_size=48,minable={result='steel-chest'}}}},prototypes={}}
function data:extend(list) for _,p in ipairs(list) do assert(not self.prototypes[p.name]);self.prototypes[p.name]=p end end
dofile('mod/agent-harness_0.1.0/data.lua')
local p=data.prototypes
assert(p['mt-coinage'].enabled==false and p['mt-coinage'].visible_when_disabled==false)
assert(p['mt-coinage'].unit.ingredients[1][1]=='automation-science-pack')
assert(p['mt-trading-post'].hidden and not p['mt-trading-post'].minable)
assert(p['mt-coin'].hidden and p['mt-coin'].stack_size==1000)
for _,v in pairs(p) do assert(v.type~='recipe','no coin minting/withdrawal recipe') end
assert(data.raw.container['steel-chest'].minable.result=='steel-chest','base prototype unchanged')
print('mt296 data: contact-hidden red science, Post and uncraftable coin: ok')
