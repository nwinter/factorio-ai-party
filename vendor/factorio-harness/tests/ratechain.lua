-- Run with lua tests/ratechain.lua: bottleneck {item, per_min} (ratechain.lua; Sonnet, shift13 18:20: the rate each
-- step needs for a target, rebuilt by hand over about 20 supply calls). Per step: the rate it needs, what it makes now,
-- the makers' recipe, speed and productivity, the machines that rate takes and what the makers there make at full speed.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function recipe(name,energy,ingredients,products)
  local ings={}
  for k,v in pairs(ingredients) do ings[#ings+1]={type='item',name=k,amount=v} end
  table.sort(ings,function(x,y) return x.name<y.name end)
  return {name=name,energy=energy,ingredients=ings,products=products}
end
local R={
  ['electronic-circuit']=recipe('electronic-circuit',0.5,{['iron-plate']=1,['copper-cable']=3},{{type='item',name='electronic-circuit',amount=1}}),
  ['copper-cable']=recipe('copper-cable',0.5,{['copper-plate']=1},{{type='item',name='copper-cable',amount=2}}),
  ['iron-plate']=recipe('iron-plate',3.2,{['iron-ore']=1},{{type='item',name='iron-plate',amount=1}}),
  ['copper-plate']=recipe('copper-plate',3.2,{['copper-ore']=1},{{type='item',name='copper-plate',amount=1}}),
  ['iron-gear-wheel']=recipe('iron-gear-wheel',0.5,{['iron-plate']=2},{{type='item',name='iron-gear-wheel',amount=1}}),
  inserter=recipe('inserter',0.5,{['electronic-circuit']=1,['iron-gear-wheel']=1,['iron-plate']=1},{{type='item',name='inserter',amount=1}}),
  -- a product the recipe marks ignored_by_productivity (2 of 3 seeds come back: only 1 gets the bonus)
  ['egg-ish']=recipe('egg-ish',10,{['iron-plate']=1},{{type='item',name='egg-ish',amount=3,ignored_by_productivity=2}}),
}
prototypes={recipe=R}
local force={recipes={['electronic-circuit']={productivity_bonus=0},['iron-plate']={productivity_bonus=0.1}}}
local function machine(name,speed,prod) return {name=name,type='assembling-machine',crafting_speed=speed,productivity_bonus=prod or 0} end
local function maker(e,r) return {e=e,recipe=R[r]} end
local by={
  ['electronic-circuit']={maker(machine('assembling-machine-2',0.75),'electronic-circuit'),maker(machine('assembling-machine-2',0.75),'electronic-circuit'),
    maker(machine('assembling-machine-2',0.75),'electronic-circuit'),maker(machine('assembling-machine-2',0.75),'electronic-circuit')},
  ['copper-cable']={maker(machine('assembling-machine-2',0.75),'copper-cable'),maker(machine('assembling-machine-2',0.75),'copper-cable')},
  ['iron-plate']={maker({name='stone-furnace',type='furnace',crafting_speed=1,productivity_bonus=0},'iron-plate'),
    maker({name='stone-furnace',type='furnace',crafting_speed=1,productivity_bonus=0},'iron-plate')},
  ['iron-ore']={{e={name='electric-mining-drill',type='mining-drill',prototype={mining_speed=0.5},speed_bonus=0,productivity_bonus=0,
    mining_target={prototype={mineable_properties={mining_time=1,products={{name='iron-ore',amount=1}}}}}},miner=true}},
}
local made={['electronic-circuit']=22,['copper-cable']=70,['iron-plate']=40,['iron-ore']=41}
local C=dofile('mod/agent-harness_0.1.0/ratechain.lua'){}
local t=C.plan(by,'electronic-circuit',60,force,function(n) return made[n] end)
local s={}
for _,row in ipairs(t.steps) do s[row.item]=row end
-- circuits: 60/min; 4 assembling-machine-2 at 0.75: 90 crafts/min each, 90/min each: 0.7 for 60, 360 at full speed
local ec=s['electronic-circuit']
eq(ec.need_per_min,60); eq(ec.made_per_min,22); eq(ec.makers,4); eq(ec.machine,'assembling-machine-2'); eq(ec.recipe,'electronic-circuit')
eq(ec.crafts_per_min_each,90); eq(ec.per_min_each,90); eq(ec.machines_for_target,0.7); eq(ec.full_speed_per_min,360); eq(ec.depth,0)
eq(ec.line,'electronic-circuit: need 60/min, made 22/min; 4 assembling-machine-2 on electronic-circuit, 90/min each: 0.7 for the target, 360/min at full speed')
-- cable: 3 a circuit: 180/min; 2 a craft: 90 crafts, 180/min each: 1 machine
eq(s['copper-cable'].need_per_min,180); eq(s['copper-cable'].per_min_each,180); eq(s['copper-cable'].machines_for_target,1)
-- iron plates: 60/min; stone furnaces at 1 on a 3.2 s recipe: 18.75 crafts/min, +10% from the recipe research: 20.6/min each
local ip=s['iron-plate']
eq(ip.need_per_min,60); eq(ip.productivity_pct,10); eq(ip.per_min_each,20.6); eq(ip.machines_for_target,2.9)
assert(ip.line:find('(+10% productivity)',1,true),ip.line)
-- the ore for 60 plates with +10%: 54.5/min; a drill at 0.5 on a 1 s resource: 30/min each: 1.8 for the target
eq(s['iron-ore'].need_per_min,54.5); eq(s['iron-ore'].miners,1); eq(s['iron-ore'].per_min_each,30); eq(s['iron-ore'].machines_for_target,1.8)
-- copper plates: no maker on the surface: followed by the recipe of that name; copper ore after it, no maker either
eq(s['copper-plate'].makers,0); eq(s['copper-plate'].need_per_min,90); eq(s['copper-plate'].recipe,'copper-plate')
eq(s['copper-plate'].line,'copper-plate: need 90/min, made 0/min; no maker on the surface (recipe copper-plate)')
eq(s['copper-ore'].need_per_min,90)
assert(t.line:find('^for 60 electronic%-circuit a minute: electronic%-circuit: need 60/min'),t.line)
-- An item two steps need adds up: inserters at 30/min take iron plates directly (30), in gears (60) and in circuits (30).
t=C.plan(by,'inserter',30,force,function(n) return made[n] end)
s={}
for _,row in ipairs(t.steps) do s[row.item]=row end
eq(s['iron-plate'].need_per_min,120); eq(s['iron-gear-wheel'].need_per_min,30); eq(s['electronic-circuit'].need_per_min,30)
eq(s.inserter.makers,0,'no inserter maker on the surface')
-- Productivity on the part not ignored: 3 a craft, 2 ignored, +50%: 3.5 a craft.
by['egg-ish']={maker(machine('biochamber',2,0.5),'egg-ish')}
t=C.plan(by,'egg-ish',35,force)
eq(t.steps[1].crafts_per_min_each,12); eq(t.steps[1].per_min_each,42); eq(t.steps[1].machines_for_target,0.8)
eq(t.steps[2].item,'iron-plate'); eq(t.steps[2].need_per_min,10,'10 crafts a minute')
print('ratechain ok')
