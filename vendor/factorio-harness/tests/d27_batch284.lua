-- d27 batch284 AT (Sol #2619): assembler_batch for 100 accumulators in an assembler 2 at crafting speed 1.05 estimated
-- about 952 s and timed out at its made wait's 900 s (a wait's timeout is 54000 ticks at most). Measured on a copy
-- (2.0.77): a machine's products-finished counter rises speed / energy x (1 + productivity) a second, crafting_speed
-- with its modules and beacons, productivity its own (modules, an electromagnetic plant's 50%) plus the force's recipe
-- productivity research. The made step is now as many produced waits on the counter as the crafts need, each up to
-- 900 s; past 8 the batch is refused with the count that fits. The dry run's steps are the ones a live call queues.
-- Run from the harness root: lua tests/d27_batch284.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end

defines={inventory={assembling_machine_input=2,assembling_machine_output=3,chest=1},wire_connector_id={circuit_red=1,circuit_green=2}}
prototypes={item={accumulator={stack_size=50}},quality={normal={}},recipe={accumulator={maximum_productivity=3}}}
local function inv(t) return {get_item_count=function(n) return t[type(n)=='table' and n.name or n] or 0 end} end
local recipe={name='accumulator',energy=10,products={{type='item',name='accumulator',amount=1}},
  ingredients={{type='item',name='iron-plate',amount=2},{type='item',name='battery',amount=5}}}
local force={recipes={accumulator={productivity_bonus=0}}}
-- Sol's assembler 2: crafting speed 1.05, its counter at 6
local m={valid=true,unit_number=1,name='assembling-machine-2',type='assembling-machine',position={x=10.5,y=20.5},crafting_speed=1.05,
  productivity_bonus=0,products_finished=6,force=force,bounding_box={left_top={x=9,y=19},right_bottom={x=12,y=22}},
  get_recipe=function() return recipe,{name='normal'} end}
local mi,mo=inv({}),inv({})
m.get_inventory=function(i) return i==2 and mi or i==3 and mo or nil end
local req={valid=true,unit_number=2,name='requester-chest',position={x=10.5,y=17.5},prototype={logistic_mode='requester'},
  get_item_count=function() return 0 end,get_requester_point=function() return {trash_not_requested=false} end}
local input={valid=true,unit_number=3,type='inserter',position={x=10.5,y=18.5},pickup_target=req,drop_target=m}
local dest={valid=true,unit_number=5,name='steel-chest',type='container',position={x=10.5,y=23.5},
  get_inventory=function() return {get_insertable_count=function() return 2400 end} end}
local output={valid=true,unit_number=4,type='inserter',position={x=10.5,y=22.5},pickup_target=m,drop_target=dest}
m.surface={find_entities_filtered=function() return {input,output} end}
local submitted
local B=dofile('mod/agent-harness_0.1.0/batch.lua'){position=function(q) return q end,integer=function(v) return v end,
  entity=function() return m end,submit=function(_,a) submitted=a.steps; return {queued=#a.steps} end}
local function made(steps)
  local out={}
  for _,st in ipairs(steps) do
    if st.args['until']=='produced' then out[#out+1]=string.format('%s: from %d at least %d, timeout %d',st.label,st.args.counter_from,st.args.at_least,st.args.timeout) end
  end
  return table.concat(out,' / ')
end

-- Sol's batch: about 952 s, two made waits on the counter (73 crafts fit one: 695 s, with a quarter and 30 s to spare)
do
  local r=B.run({},{position={x=10.5,y=20.5},count=100,dry_run=true})
  eq(r.estimate_s,952); eq(r.made_waits,2); eq(r.refused,nil)
  eq(made(r.steps),'made 73 of 100: from 6 at least 73, timeout 54000 / made: from 6 at least 100, timeout 54000')
  has(table.concat(r.plan,'\n'),'at its crafting speed 1.05 the 100 crafts take about 952 s, more than one wait holds (900 s): the made step is 2 waits on its counter, met at 79, 106, each up to 900 s')
  -- the live call queues the dry run's steps
  local live=B.run({},{position={x=10.5,y=20.5},count=100})
  eq(live.queued,#r.steps)
  for i,st in ipairs(r.steps) do
    eq(submitted[i].label,st.label,'step '..i); eq(submitted[i].action,st.action,'step '..i)
    for k,v in pairs(st.args) do if type(v)~='table' then eq(submitted[i].args[k],v,'step '..i..' '..k) end end
  end
  print('AT Sol\'s 100 accumulators at speed 1.05: 952 s, 2 made waits, dry run and live alike: ok')
end

-- productivity counts: modules (+50%) bring it to about 635 s, one wait; research on the recipe adds to the entity's
do
  m.productivity_bonus=0.5
  local r=B.run({},{position={x=10.5,y=20.5},count=100,dry_run=true})
  eq(r.estimate_s,635); eq(r.made_waits,1); eq(r.productivity,0.5)
  eq(made(r.steps),'made: from 6 at least 100, timeout 54000')
  m.productivity_bonus=0; force.recipes.accumulator.productivity_bonus=0.5
  r=B.run({},{position={x=10.5,y=20.5},count=100,dry_run=true})
  eq(r.estimate_s,635); eq(r.made_waits,1)
  -- over the recipe's maximum_productivity: the maximum
  force.recipes.accumulator.productivity_bonus=5
  r=B.run({},{position={x=10.5,y=20.5},count=100,dry_run=true})
  eq(r.productivity,3); eq(r.estimate_s,238)
  force.recipes.accumulator.productivity_bonus=0
  print('AT productivity (its own, recipe research, the maximum): ok')
end

-- past 8 made waits (584 crafts at speed 1.05): refused with the count that fits; the dry run says it and gives no steps
do
  local r=B.run({},{position={x=10.5,y=20.5},count=600,dry_run=true})
  has(r.refused,'at its crafting speed 1.05 the 600 crafts take about 5714 s: more than 8 made waits of 900 s hold (73 crafts each). Refused: count 584 or less (584 crafts), or batches one after another')
  eq(r.steps,nil); has(r.line,'dry run: refused, nothing would be queued')
  local ok,err=pcall(B.run,{},{position={x=10.5,y=20.5},count=600})
  assert(not ok); has(tostring(err),'Refused: count 584 or less')
  r=B.run({},{position={x=10.5,y=20.5},count=584,dry_run=true})
  eq(r.refused,nil); eq(r.made_waits,8)
  print('AT past 8 made waits: refused with the count that fits: ok')
end

-- a short batch: one made wait, as before
do
  local r=B.run({},{position={x=10.5,y=20.5},count=10,dry_run=true})
  eq(r.estimate_s,95); eq(r.made_waits,1); eq(made(r.steps),'made: from 6 at least 10, timeout 54000')
  assert(not table.concat(r.plan,'\n'):find('more than one wait',1,true))
  print('AT a short batch: one made wait: ok')
end
defines=nil; prototypes=nil
print('d27_batch284 AT: ok')
