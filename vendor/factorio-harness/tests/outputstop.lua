-- Run from repository root: lua tests/outputstop.lua
-- Where a crafting machine's output stops it, per product (outputstop.lua; Sol, shift17 12:20: Aquilo science read
-- full_output at 45 packs and 135 hot fluoroketone while it lacked ice). Thresholds measured on 2.0.77.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,text,m) assert(type(s)=='string' and s:find(text,1,true),(m or 'missing')..': '..tostring(s)..' lacks '..text) end
defines={inventory={assembling_machine_input=2,furnace_source=2}}
prototypes={recipe={
  ['cryogenic-science-pack']={name='cryogenic-science-pack',energy=20,
    ingredients={{type='item',name='ice',amount=3},{type='item',name='lithium-plate',amount=1},{type='fluid',name='fluoroketone-cold',amount=6}},
    products={{type='item',name='cryogenic-science-pack',amount=1},{type='fluid',name='fluoroketone-hot',amount=3}}},
  ['iron-gear-wheel']={name='iron-gear-wheel',energy=0.5,ingredients={{type='item',name='iron-plate',amount=2}},
    products={{type='item',name='iron-gear-wheel',amount=1}}},
  ['iron-plate']={name='iron-plate',energy=3.2,ingredients={{type='item',name='iron-ore',amount=1}},products={{type='item',name='iron-plate',amount=1}}},
},item={['cryogenic-science-pack']={stack_size=200},['iron-gear-wheel']={stack_size=100},['iron-plate']={stack_size=100}}}
local O=dofile('mod/agent-harness_0.1.0/outputstop.lua'){}
local function plant(o)
  local boxes={{production_type='input',filter='fluoroketone-cold',cap=12,f=o.cold and {name='fluoroketone-cold',amount=o.cold}},
    {production_type='output',filter='fluoroketone-hot',cap=300,f=o.hot and {name='fluoroketone-hot',amount=o.hot}}}
  local fb=setmetatable({get_prototype=function(i) return {object_name='LuaFluidBoxPrototype',production_type=boxes[i].production_type} end,
    get_filter=function(i) return {name=boxes[i].filter} end,get_capacity=function(i) return boxes[i].cap end},
    {__len=function() return #boxes end,__index=function(_,i) return boxes[i] and boxes[i].f end})
  return {type='assembling-machine',crafting_speed=o.speed or 2,fluidbox=fb,
    get_recipe=function() return {name=o.recipe or 'cryogenic-science-pack'} end,
    get_output_inventory=function() return {get_item_count=function(n) return (o.out or {})[n] or 0 end} end,
    get_inventory=function() return {get_item_count=function(n) return (o.input or {})[n] or 0 end} end,
    get_fluid_contents=function() return {['fluoroketone-cold']=o.cold,['fluoroketone-hot']=o.hot} end}
end
-- Sol's plant: 45 packs, 135 hot, 2 ice: full_output with nothing at its limit; the shortage named.
local r=O.read(plant{out={['cryogenic-science-pack']=45},hot=135,cold=12,input={ice=2,['lithium-plate']=11}},'full_output')
eq(r.line,"full_output, no output at its limit: it is not crafting (crafting_progress 0) and holds 2 crafts' worth or more (cryogenic-science-pack 45, fluoroketone-hot 135); it lacks ice 2 (a craft takes 3): it crafts again when that arrives")
eq(r.lines[1],"cryogenic-science-pack 45 held: a finished craft goes out while it holds 199 or less (one stack 200, a craft adds 1), else waits finished in the machine (full_output)")
eq(r.lines[2],"fluoroketone-hot 135 of 300 in its output box: a finished craft goes out while it holds 297 or less (a craft adds 3), else waits finished in the machine (full_output); pipes joined to the box take from it as they have room")
has(r.idle_full_output,"once it holds 2 crafts' worth of a product (cryogenic-science-pack 2, fluoroketone-hot 6)")
eq(r.products[2].capacity,300); eq(r.products[2].delivers_up_to,297); eq(r.products[2].full,false); eq(r.products[1].idle_full_output_from,2); eq(r.blocking,'input')
-- 4 packs, no ice (19:20).
r=O.read(plant{out={['cryogenic-science-pack']=4},cold=12,input={['lithium-plate']=32}},'full_output')
has(r.line,'(cryogenic-science-pack 4); it lacks ice 0 (a craft takes 3)')
-- At the limit: 298 hot, a craft's 3 do not fit.
r=O.read(plant{out={['cryogenic-science-pack']=166},hot=298,cold=12,input={ice=30,['lithium-plate']=5}},'full_output')
eq(r.line,'full_output: a finished craft waits for room in its output, fluoroketone-hot 298 of 300 (goes out at 297 or less): it goes out when that is taken out'); eq(r.blocking,'output')
-- Working: no line, no idle note.
r=O.read(plant{out={},hot=3,cold=12,input={ice=30}},'working')
eq(r.line,nil); eq(r.idle_full_output,nil)
-- Gears in an assembler 3 (speed 1.25, 0.5 s): 1 + ceil(1.166 * 2.5) = 4 crafts.
r=O.read(plant{recipe='iron-gear-wheel',speed=1.25,out={['iron-gear-wheel']=100}},'full_output')
eq(r.line,'full_output: a finished craft waits for room in its output, iron-gear-wheel 100 of 100 (goes out at 99 or less): it goes out when that is taken out')
has(r.idle_full_output,"4 crafts' worth of a product (iron-gear-wheel 4)")
-- A furnace (its last recipe when idle): no idle full_output note.
r=O.read({type='furnace',crafting_speed=2,get_recipe=function() return nil end,previous_recipe={name={name='iron-plate'}},
  get_output_inventory=function() return {get_item_count=function() return 7 end} end},'no_ingredients')
eq(r.idle_full_output,nil); has(r.lines[1],'iron-plate 7 held')
-- No recipe: nil.
eq(O.read({type='assembling-machine',get_recipe=function() return nil end},'no_recipe'),nil)
print('outputstop: ok')
