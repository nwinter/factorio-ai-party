-- Run from repository root: lua tests/craftrate.lua
-- Sol, 15:20: an egg breeder's output twice miscounted, the seed egg each craft returns being exempt from productivity.
-- A machine's crafts and output per minute at its speed and productivity now; the recipes read at a machine's speed.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
-- The egg recipe: 1 egg, 30 nutrients and 60 water make 5 eggs, 1 of them exempt from productivity; 15 s a craft.
local eggs={name='pentapod-egg',energy=15,prototype={maximum_productivity=3},
  ingredients={{type='item',name='pentapod-egg',amount=1},{type='item',name='nutrients',amount=30},{type='fluid',name='water',amount=60}},
  products={{type='item',name='pentapod-egg',amount=5,ignored_by_productivity=1}}}
local force={recipes={['pentapod-egg']={productivity_bonus=0}}}
local biochamber={name='biochamber',crafting_categories={organic=true},crafting_speed=2,get_crafting_speed=function() return 2 end,
  effect_receiver={base_effect={productivity=0.5}}}
prototypes={entity={biochamber=biochamber,['iron-chest']={}}}
local R=dofile('mod/agent-harness_0.1.0/craftrate.lua'){}
local e={valid=true,name='biochamber',prototype=biochamber,force=force,crafting_speed=2,get_recipe=function() return eggs end}
local r=R.machine(e)
eq(r.recipe,'pentapod-egg'); eq(r.crafts_per_min,8); eq(r.seconds_per_craft,7.5); eq(r.productivity,0.5)
-- 5 + (5-1) x 0.5 = 7 a craft, 56 a minute; 8 go back in: net 48.
eq(r.products[1].per_craft,7); eq(r.products[1].per_min,56); eq(r.products[1].net_per_min,48); eq(r.products[1].ignored_by_productivity,1)
eq(r.ingredients[2].name,'nutrients'); eq(r.ingredients[2].per_min,240)
eq(r.line,'8 crafts/min at speed 2 (15s a craft), productivity +50% (the machine\'s own +50%): pentapod-egg 56/min (net 48/min: 8/min goes back in), '
  ..'1 a craft exempt from productivity (at full speed all the time; status, input and output decide what it makes)')
-- The game's own figure counts: modules and research on top of the machine's base.
force.recipes['pentapod-egg'].productivity_bonus=0.1
e.productivity_bonus=0.8
r=R.machine(e)
eq(r.productivity,0.8); eq(r.products[1].per_craft,8.2)
assert(r.line:find('productivity +80% (the machine\'s own +50%, research +10%, modules and beacons +20%)',1,true),r.line)
-- Capped at the recipe's maximum.
e.productivity_bonus=5
eq(R.machine(e).productivity,3)
-- A product with a chance and a range: its average.
local scrap={name='scrap-recycling',energy=0.2,ingredients={{name='scrap',amount=1}},
  products={{name='iron-gear-wheel',amount=1,probability=0.2},{name='holmium-ore',amount_min=0,amount_max=2,probability=0.5}}}
r=R.rates(scrap,1,0)
eq(r.crafts_per_min,300); eq(r.products[1].per_min,60); eq(r.products[2].per_min,150)
-- An idle furnace: the recipe it ran last.
local plate={name='iron-plate',energy=3.2,ingredients={{name='iron-ore',amount=1}},products={{name='iron-plate',amount=1}}}
force.recipes['iron-plate']=plate
local furnace={valid=true,name='stone-furnace',prototype={},force=force,crafting_speed=1,get_recipe=function() return nil end,
  previous_recipe={name={name='iron-plate'},quality='normal'}}
eq(R.machine(furnace).crafts_per_min,18.8)
eq(R.machine({valid=true,name='assembling-machine-1',prototype={},force=force,get_recipe=function() return nil end}),nil,'no recipe: nothing')
-- The recipes read: at speed 1, or at a machine's speed with its own productivity.
force.recipes['pentapod-egg'].productivity_bonus=0
eq(R.recipe(force,eggs).crafts_per_min,4)
r=R.recipe(force,eggs,'biochamber')
eq(r.crafts_per_min,8); eq(r.products[1].net_per_min,48)
assert(r.line:find("biochamber's own +50%",1,true),r.line)
fails(function() R.recipe(force,eggs,'iron-chest') end,'machine must be a crafting machine name')
print('craftrate: ok')
