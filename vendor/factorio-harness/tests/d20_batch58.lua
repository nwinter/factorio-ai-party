-- Run from repository root: lua tests/d20_batch58.lua
-- d20 batch58: uptime and quality. T1 (Sol #1453): a recipe's item ingredients counted at its quality.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

-- An inventory as 2.0.77 counts it: by name, normal quality only; {name, quality} that quality.
local function inventory(stacks)
  return {get_item_count=function(id)
    local name,q=id,'normal'
    if type(id)=='table' then name,q=id.name,id.quality or 'normal' end
    local n=0
    for _,st in ipairs(stacks) do if st.name==name and st.quality==q then n=n+st.count end end
    return n
  end,get_contents=function() return stacks end}
end

-- T1: Sol's EM plant (28,166) on rare quality-module-3, holding rare advanced circuits 12, processing units 10,
-- superconductors 4 and rare quality-module-2 3 of the 4 a craft: only the module is short, named rare.
do
  game={tick=1000}
  defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3}}
  local recipe={name='quality-module-3',ingredients={{type='item',name='advanced-circuit',amount=5},{type='item',name='processing-unit',amount=5},
    {type='item',name='superconductor',amount=1},{type='item',name='quality-module-2',amount=4}}}
  local held={{name='advanced-circuit',quality='rare',count=12},{name='processing-unit',quality='rare',count=10},{name='superconductor',quality='rare',count=4},
    {name='quality-module-2',quality='rare',count=3}}
  local m={valid=true,name='electromagnetic-plant',type='assembling-machine',position={x=28,y=166},products_finished=50,status='item_ingredient_shortage',
    get_recipe=function() return recipe,{name='rare'} end,get_inventory=function(i) return inventory(i==2 and held or {}) end}
  local st={}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() return m end,
    status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=1.5,productivity=0.5} end}
  local start=U.handler({index=1},{position={x=28,y=166},seconds=10})
  eq(start.baseline[1],'electromagnetic-plant (28,166) quality-module-3 (rare): 50 completions so far (the game\'s count, productivity\'s included)')
  for t=1001,1600 do game.tick=t; U.tick(t) end
  local row=U.handler({index=1},{}).machines[1]
  eq(row.recipe,'quality-module-3'); eq(row.recipe_quality,'rare')
  eq(#row.short,1); eq(row.short[1],'quality-module-2 (rare) short in 11 samples (least 3 of 4 a craft)')
  assert(row.line:find('electromagnetic-plant (28,166) quality-module-3 (rare): ',1,true),row.line)
  -- a normal recipe reads as before, its quality normal, and a fluid ingredient has no quality
  recipe.ingredients[#recipe.ingredients+1]={type='fluid',name='electrolyte',amount=10}
  m.get_fluid_count=function() return 4 end
  held={{name='advanced-circuit',quality='normal',count=12}}
  m.get_recipe=function() return recipe end
  U.handler({index=1},{position={x=28,y=166},seconds=10})
  for t=1601,2200 do game.tick=t; U.tick(t) end
  row=U.handler({index=1},{}).machines[1]
  eq(row.recipe_quality,'normal'); assert(row.line:find('electromagnetic-plant (28,166) quality-module-3: ',1,true),row.line)
  local shorts=table.concat(row.short,'; ')
  assert(not shorts:find('advanced-circuit',1,true),shorts)
  assert(shorts:find('electrolyte short in 11 samples (least 4 of 10 a craft)',1,true) and shorts:find('processing-unit short',1,true),shorts)
  -- the recipe's quality changing during the watch reads as a recipe change
  U.handler({index=1},{position={x=28,y=166},seconds=10})
  for t=2201,2800 do game.tick=t; if t==2500 then m.get_recipe=function() return recipe,{name='epic'} end end; U.tick(t) end
  eq(U.handler({index=1},{}).machines[1].recipe_changed,'quality-module-3 -> quality-module-3 (epic)')
  defines=nil
end
print('d20_batch58 T1 ingredient shortages at the recipe\'s quality: ok')
