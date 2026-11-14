package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function near(a,b) assert(math.abs(a-b)<1e-7,tostring(a)..' ~= '..tostring(b)) end
local function strict(t,removed)
 return setmetatable(t,{__index=function(_,k) assert(not removed[k],'removed API '..k) end})
end
local function product(name,lo,hi,amount,extra)
 return strict({type='item',name=name,amount=amount or 1,extra_count_fraction=extra,
  independent_probability=1,shared_probability={min=lo,max=hi}},{probability=true})
end
local calls=0
local proto=strict({name='uranium-processing',energy=12,categories={'centrifuging'},ingredients={},maximum_productivity=3,
 products={product('uranium-235',0,.007),product('uranium-238',.007,1)},
 get_product_amount=function(i,p) calls=calls+1; return ({.007,.993})[i]*(1+p) end},{prototype=true,category=true,additional_categories=true})
local recipe={name=proto.name,prototype=proto,energy=12,categories=proto.categories,ingredients={},products=proto.products,productivity_bonus=0}
prototypes={recipe={[proto.name]=proto},item={},entity={},technology={},quality={}}
defines={events={},inventory={}}
local force={recipes={[proto.name]=recipe}}
local C=dofile('mod/agent-harness_0.1.0/craftrate.lua'){}
near(C.rates(proto,1,0).products[1].per_craft,.007)
near(C.rates(recipe,1,1).products[2].per_craft,1.986)
local e={valid=true,type='assembling-machine',name='centrifuge',force=force,prototype={},crafting_speed=1,
 productivity_bonus=0,effects={quality=.08},get_recipe=function() return recipe,{name='normal'} end}
assert(C.machine(e).quality_chance=='8%')
local A=dofile('mod/agent-harness_0.1.0/ammomodel.lua'){}
near(A.products(proto)['uranium-235'],.007)
local E=dofile('mod/agent-harness_0.1.0/efficiency.lua'){}
near(E.products(proto.name).n,1)
local flows={}; force.name='test'; force.get_item_production_statistics=function() return {on_flow=function(n,a) flows[n]=(flows[n] or 0)+a end} end
local state={}
local H=dofile('mod/agent-harness_0.1.0/crafting.lua'){state=function() return state end}
H.record({force=force},proto.name,1000); near(flows['uranium-235'],7); near(flows['uranium-238'],993)
-- The engine method is authoritative even where a hand-written estimate would disagree.
proto.get_product_amount=function(i,p) calls=calls+1; return i==1 and 0 or 7+p end
near(C.rates(recipe,1,0).products[1].per_craft,0)
near(C.rates(recipe,1,.5).products[2].per_craft,7.5)
assert(calls>=9)
-- A legacy recipe still uses its 2.0 product fields; fractional recycling remains fractional.
near(C.rates({energy=1,products={{name='plate',amount=0,extra_count_fraction=.5}}},1,0).products[1].per_craft,.5)
print('port21 products: strict API, native prototype/force recipe means, zero, productivity, statistics and quality passed')

-- Core 2.1 util.product_amount rolls the fractional remainder with the whole count.
local fractional=product('native-fraction',.2,.6,4,.5); fractional.independent_probability=.2
near(C.rates({energy=1,products={fractional}},1,0).products[1].per_craft,.36)
near(A.products({name='native-fraction-recipe',products={fractional}})['native-fraction'],.36)
fractional.independent_probability=nil
near(C.rates({energy=1,products={fractional}},1,0).products[1].per_craft,1.8)
near(C.rates({energy=1,products={{name='legacy-fraction',amount=4,probability=.2,extra_count_fraction=.5}}},1,0).products[1].per_craft,1.3)
