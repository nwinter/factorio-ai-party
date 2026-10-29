-- d29 batch345 BP (Astra #2753): assembler_batch in a foundry at +50% productivity on turbo underground belts asked
-- for 228 belts (114 crafts of 2) and staged 4560 tungsten plates and 228 express underground belts, the ingredients
-- of 114 crafts, where 76 base crafts and their productivity bar make the 114 completions its counter stops at. Now the
-- ingredients are staged for the fewest base crafts whose completions, base and bonus (the bar as it is, filled by the
-- productivity a craft), reach the batch's; the stop is unchanged. Mocks as tests/d27_batch284.lua.
-- Run from the harness root: lua tests/d29_batch345.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end

defines={inventory={assembling_machine_input=2,assembling_machine_output=3,chest=1},wire_connector_id={circuit_red=1,circuit_green=2}}
prototypes={item={['turbo-underground-belt']={stack_size=50},['tungsten-plate']={stack_size=50},['express-underground-belt']={stack_size=50}},
  quality={normal={}},recipe={['turbo-underground-belt']={maximum_productivity=3}}}
local function inv(t) return {get_item_count=function(n) return t[type(n)=='table' and n.name or n] or 0 end} end
local recipe={name='turbo-underground-belt',energy=2,products={{type='item',name='turbo-underground-belt',amount=2}},
  ingredients={{type='item',name='express-underground-belt',amount=2},{type='item',name='tungsten-plate',amount=40}}}
local force={recipes={['turbo-underground-belt']={productivity_bonus=0}}}
-- Astra's foundry at Vulcanus (26.5,47.5): +50% (its own), counter 229, 40 tungsten inside; the requester holds 38
local m={valid=true,unit_number=1,name='foundry',type='assembling-machine',position={x=26.5,y=47.5},crafting_speed=4,
  productivity_bonus=0.5,bonus_progress=0,products_finished=229,force=force,bounding_box={left_top={x=24,y=45},right_bottom={x=29,y=50}},
  get_recipe=function() return recipe,{name='normal'} end}
local inside={['tungsten-plate']=40}
local mi,mo=inv(inside),inv({})
m.get_inventory=function(i) return i==2 and mi or i==3 and mo or nil end
local held={['tungsten-plate']=38}
local rinv=setmetatable({get_bar=function() return 49 end,get_contents=function() return {} end},{__len=function() return 48 end})
local req={valid=true,unit_number=2,name='requester-chest',position={x=26.5,y=43.5},prototype={logistic_mode='requester'},
  get_item_count=function(n) return held[type(n)=='table' and n.name or n] or 0 end,get_inventory=function() return rinv end,
  get_requester_point=function() return {trash_not_requested=false} end}
local input={valid=true,unit_number=3,type='inserter',position={x=26.5,y=44.5},pickup_target=req,drop_target=m}
local dest={valid=true,unit_number=5,name='passive-provider-chest',type='logistic-container',position={x=30.5,y=47.5},
  get_inventory=function() return {get_insertable_count=function() return 2400 end} end}
local output={valid=true,unit_number=4,type='inserter',position={x=29.5,y=47.5},pickup_target=m,drop_target=dest}
m.surface={find_entities_filtered=function() return {input,output} end}
local submitted
local B=dofile('mod/agent-harness_0.1.0/batch.lua'){position=function(q) return q end,integer=function(v) return v end,
  entity=function() return m end,submit=function(_,a) submitted=a.steps; return {queued=#a.steps} end}
local function staged(steps)
  for _,st in ipairs(steps or {}) do if st.label=='stage' then
    local t={} for _,x in ipairs(st.args.set) do t[#t+1]=x.item..' '..x.min end; table.sort(t); return table.concat(t,', ') end end
end
local function stop(steps) for _,st in ipairs(steps or {}) do if st.label=='made' then return st.args.counter_from+st.args.at_least end end end

-- 1. Astra's 228: 114 completions at the stop, 76 base crafts staged (3040 tungsten, 152 express underground belts)
do
  local r=B.run({},{position={x=26.5,y=47.5},count=228,dry_run=true})
  eq(r.crafts,114); eq(r.base_crafts,76); eq(r.bonus_crafts,38); eq(r.counter.done_at,343)
  has(table.concat(r.plan,'\n'),'tungsten-plate: 3040 for 76 base crafts, the machine holds 40, the requester 38: 2962 to come')
  has(table.concat(r.plan,'\n'),'express-underground-belt: 152 for 76 base crafts, the machine holds 0, the requester 0: 152 to come')
  has(table.concat(r.plan,'\n'),'productivity +50%: ingredients for 76 base crafts; its productivity bar (0.00 full now, +0.5 a craft) adds 38 bonus completions; 114 completions in all, 228 turbo-underground-belt at the stop')
  -- the slots it must hold: 3000 tungsten (60) and 152 belts (4) against 48: still over, with the smaller figures
  eq(r.slots.required,64); has(r.refused,'152 express-underground-belt (4 slots), 3000 tungsten-plate (60 slots) there at once: 64 slots')
  -- a count that fits: 150 belts, 75 completions, 50 base crafts (2000 tungsten: 1922 to come, 40 slots; 100 belts, 2)
  r=B.run({},{position={x=26.5,y=47.5},count=150,dry_run=true})
  eq(r.refused,nil); eq(r.base_crafts,50); eq(r.crafts,75); eq(r.slots.required,42)
  eq(staged(r.steps),'express-underground-belt 100, tungsten-plate 1960'); eq(stop(r.steps),229+75)
  print('BP Astra\'s 228 turbo underground belts: 76 base crafts staged, 114 at the stop: ok')
end

-- 2. two adjacent batches: the bar carried over saves a base craft; never short at the stop
do
  inside['tungsten-plate']=0; held['tungsten-plate']=0
  local r=B.run({},{position={x=26.5,y=47.5},count=10,dry_run=true})   -- 5 completions: 4 base crafts with an empty bar
  eq(r.base_crafts,4); eq(r.bonus_crafts,2)
  m.bonus_progress=0.5                                                  -- the last batch left the bar half full
  r=B.run({},{position={x=26.5,y=47.5},count=10,dry_run=true})
  eq(r.base_crafts,3); eq(r.bonus_crafts,2); eq(stop(r.steps),229+5)
  -- every count and bar: the fewest base crafts whose completions reach the batch's
  for _,bar in ipairs({0,0.25,0.5,0.75,0.99}) do
    m.bonus_progress=bar
    for count=2,60,2 do
      local x=B.run({},{position={x=26.5,y=47.5},count=count,dry_run=true})
      local function done(b) return b+math.floor(bar+b*0.5+1e-9) end
      assert(done(x.base_crafts)>=count/2,'short: '..count..' bar '..bar)
      assert(x.base_crafts==0 or done(x.base_crafts-1)<count/2,'not the fewest: '..count..' bar '..bar)
    end
  end
  m.bonus_progress=0
  print('BP adjacent batches, the bar carried over; fewest base crafts, never short: ok')
end

-- 3. a machine with no productivity: as before (crafts staged in full, no base/bonus fields)
do
  m.productivity_bonus=0
  local r=B.run({},{position={x=26.5,y=47.5},count=10,dry_run=true})
  eq(r.crafts,5); eq(r.base_crafts,nil); eq(r.bonus_crafts,nil)
  eq(staged(r.steps),'express-underground-belt 10, tungsten-plate 200')
  has(table.concat(r.plan,'\n'),'tungsten-plate: 200 for 5 crafts, the machine holds 0')
  -- a product productivity leaves out (ignored_by_productivity): staged in full
  m.productivity_bonus=0.5; recipe.products[1].ignored_by_productivity=2
  r=B.run({},{position={x=26.5,y=47.5},count=10,dry_run=true})
  eq(staged(r.steps),'express-underground-belt 10, tungsten-plate 200')
  has(table.concat(r.plan,'\n'),'is left out of productivity, so the batch is staged for all 5 crafts')
  recipe.products[1].ignored_by_productivity=nil
  print('BP no productivity, or a product it leaves out: staged in full: ok')
end
