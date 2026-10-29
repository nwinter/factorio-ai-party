-- Run from repository root: lua tests/d29_batch342.lua
-- d29 batch342 HI (Opus, board #2748: "Priming a new fusion core on a platform needs cold fluoroketone; deliver refuses
-- barrels into the barrel-emptying AM3 (only fuel/ammo/modules)"). On a private 2.0.77 copy a blueprint pasted over the
-- machine with an item request into its input inventory keeps it, and the platform hub fills it from its inventory
-- (within 10 ticks, as many as it holds); a request for an item the recipe does not take is dropped by the game.
-- deliver now makes that request for a platform machine's recipe ingredients: the input slot of that ingredient,
-- bounded by its room, the hub's stock in the note; refusals name what the game allows (not an ingredient, no recipe,
-- off a platform, a fluid); fuel and ammunition as before.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,part) local ok,err=pcall(fn); assert(not ok and tostring(err):find(part,1,true),tostring(err)) end
defines={inventory={crafter_input=2,turret_ammo=3,hub_main=1}}
prototypes={item={['fluoroketone-cold-barrel']={type='item',stack_size=10,fuel_value=0},['iron-plate']={type='item',stack_size=100,fuel_value=0},
  ['copper-cable']={type='item',stack_size=200,fuel_value=0},['solid-fuel']={type='item',stack_size=50,fuel_value=12e6}},
  fluid={['fluoroketone-cold']={}}}
local function inv(n) local t={} for i=1,n do t[i]={valid_for_read=false} end return t end
local proxies={}
local hub={get_item_count=function(name) return name=='fluoroketone-cold-barrel' and 8 or 0 end}
local platform={name='Kestrel IVc',hub={get_inventory=function() return hub end}}
local function surface(plat)
  return {platform=plat,create_entity=function(t) local px={valid=true,insert_plan=t.modules,target=t.target}; proxies[#proxies+1]=px; return px end}
end
local function machine(recipe, plat, slots)
  local e={valid=true,type='assembling-machine',name='assembling-machine-3',position={x=0.5,y=21.5},surface=surface(plat),force='player'}
  local input=inv(slots or 1)
  e.get_inventory=function(i) if i==2 then return input end end
  e.get_fuel_inventory=function() return nil end
  e.get_recipe=function() return recipe end
  e.input=input
  return e
end
local D=require('deliver'){carrier=function() return 'robots' end}
local EMPTY={name='empty-fluoroketone-cold-barrel',ingredients={{type='item',name='fluoroketone-cold-barrel',amount=1}}}

-- 1. a platform machine's ingredient: one plan into its input slot, the hub's stock said
local e=machine(EMPTY,platform)
local row=D.deliver_one({force='player'},e,{['fluoroketone-cold-barrel']=10})
eq(row.requested,'fluoroketone-cold-barrel*10'); has(row.note,'the hub of Kestrel IVc holds fluoroketone-cold-barrel 8')
has(row.pending,'the platform hub fills from its inventory')
local plan=proxies[#proxies].insert_plan
eq(#plan,1); eq(plan[1].id.name,'fluoroketone-cold-barrel'); eq(plan[1].items.in_inventory[1].inventory,2); eq(plan[1].items.in_inventory[1].stack,0)
eq(plan[1].items.in_inventory[1].count,10)
-- bounded by the slot's room: 25 asked, a stack (10) requested, the rest said
row=D.deliver_one({force='player'},machine(EMPTY,platform),{['fluoroketone-cold-barrel']=25})
eq(row.requested,'fluoroketone-cold-barrel*10'); has(row.refused[1],'room for 10 of the 25')
-- the second ingredient goes to its own slot (the recipe's item ingredients in order)
local TWO={name='electronic-circuit',ingredients={{type='item',name='iron-plate',amount=1},{type='item',name='copper-cable',amount=3}}}
D.deliver_one({force='player'},machine(TWO,platform,2),{['copper-cable']=50})
eq(proxies[#proxies].insert_plan[1].items.in_inventory[1].stack,1,'copper cable into the second input slot')
print('d29_batch342 1. a platform machine\'s recipe ingredient: an insert plan into its input slot, bounded, the hub\'s stock said: ok')

-- 2. refusals that name what the game allows
row=D.deliver_one({force='player'},machine(EMPTY,platform),{['iron-plate']=5})
eq(row.requested,nil); has(row.refused[1],'iron-plate is not an ingredient of assembling-machine-3\'s recipe empty-fluoroketone-cold-barrel: the game drops such a request')
row=D.deliver_one({force='player'},machine(nil,platform),{['fluoroketone-cold-barrel']=5})
has(row.refused[1],'has no recipe: an ingredient request needs one')
row=D.deliver_one({force='player'},machine(EMPTY,nil),{['fluoroketone-cold-barrel']=5})
has(row.refused[1],'by item request only on a platform (its hub fills it)')
fails(function() D.handler({force='player'},{position={x=0,y=0},items={['fluoroketone-cold']=100}}) end,
  'fluoroketone-cold is a fluid: an item request carries items only; a fluid comes as its barrel')
print('d29_batch342 2. refusals: not an ingredient (the game drops it), no recipe, off a platform, a fluid (the barrel or a pump): ok')
