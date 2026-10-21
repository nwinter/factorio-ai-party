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
-- The game's own figure counts modules on top of the machine's base; the recipe's research is added to it (d20 batch55
-- P7, Astra #1426: 2.0.77's productivity_bonus leaves the research out).
force.recipes['pentapod-egg'].productivity_bonus=0.1
e.productivity_bonus=0.7
r=R.machine(e)
eq(r.productivity,0.8); eq(r.products[1].per_craft,8.2)
assert(r.line:find('productivity +80% (the machine\'s own +50%, research +10%, modules and beacons +20%)',1,true),r.line)
-- The quality chance as the GUI shows it (d15 batch5 A8, Astra 05:43: five rare quality-module-1 read 0.8 from the
-- engine, 8% in the GUI; it printed 80%).
e.effects={quality=0.80000001192092896}
eq(R.machine(e).quality_chance,'8%')
e.effects={quality=0.16}
eq(R.machine(e).quality_chance,'1.6%')
e.effects=nil
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
-- feed (Sol, 19:50: a standard inserter capped green circuits at 37.5/min): the inserters into and out of a machine
-- against its recipe at full speed. Green circuits in an assembling-machine-2: 90 crafts/min take 360 items, make 90.
local circuit={name='electronic-circuit',energy=0.5,ingredients={{type='item',name='iron-plate',amount=1},{type='item',name='copper-cable',amount=3}},
  products={{type='item',name='electronic-circuit',amount=1}}}
force.recipes['electronic-circuit']={productivity_bonus=0}
force.inserter_stack_size_bonus=0; force.bulk_inserter_capacity_bonus=0
local am2={valid=true,name='assembling-machine-2',prototype={},force=force,crafting_speed=0.75,position={x=10.5,y=10.5},get_recipe=function() return circuit end}
local function ins(name,x,y,speed,f)
  local i={valid=true,name=name,position={x=x,y=y},force=force,prototype={get_inserter_rotation_speed=function() return speed end}}
  for k,v in pairs(f or {}) do i[k]=v end
  return i
end
local yellow,blue=ins('inserter',8.5,9.5,0.014),ins('fast-inserter',8.5,10.5,0.04)
local out=ins('inserter',12.5,10.5,0.014)
eq(R.inserter_rate(yellow),0.84); eq(R.inserter_rate(blue),2.4)
local fd=R.feed(am2,{yellow,blue},{out})
eq(fd.input.per_min,194.4); eq(fd.input.needs_per_min,360); eq(fd.output.per_min,50.4)
eq(fd.line,'assembling-machine-2 (10.5,10.5) (electronic-circuit): input: 2 inserters carry at most 194.4/min (inserter (8.5,9.5) 50.4/min, '
  ..'fast-inserter (8.5,10.5) 144/min); the recipe takes 360/min at full speed, so it runs at most 54% of full speed; it takes 3 inserters like '
  ..'fast-inserter (144/min each); output: 1 inserter carries at most 50.4/min (inserter (12.5,10.5) 50.4/min); it makes 90/min at full speed, '
  ..'so it runs at most 56% of full speed; it takes 2 inserters like inserter (50.4/min each)')
-- Stack bonuses count (a bulk inserter its own); an override caps the stack. Enough: nil.
force.bulk_inserter_capacity_bonus=3
local bulk=ins('bulk-inserter',8.5,11.5,0.04,{prototype={bulk=true,get_inserter_rotation_speed=function() return 0.04 end}})
eq(R.inserter_rate(bulk),9.6); bulk.inserter_stack_size_override=2; eq(R.inserter_rate(bulk),4.8); bulk.inserter_stack_size_override=nil
eq(R.feed(am2,{bulk},{bulk}),nil,'576/min each way: enough')
eq(R.feed(am2,{},{}),nil,'no inserters: nothing read')
print('craftrate: ok')
