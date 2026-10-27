-- d27 batch278 AB (Astra #2589): assembler_batch on Aquilo for 10 fusion generators held the output and waited for 10 in
-- a cryogenic plant whose output holds one stack of 5 and whose inserters stop feeding it at 2; the plant was off by its
-- own logistic condition (fusion-generator < 2) and the plan never touched it. Measured on a copy (2.0.77): output held,
-- a cryogenic plant on fusion-generator stopped at 4 and an assembler 2 on gears at 6; products_finished counts crafts,
-- productivity bonus crafts too (an electromagnetic plant: 20 plates of cable, 30); a machine's logistic condition holds
-- it off with no logistic network round it; an unwired circuit condition is ignored. The plan now counts crafts on the
-- products-finished counter from the count it read (produced, counter_from), never holds the output, and switches the
-- machine's own conditions and the output inserter's off for the batch and back after; the input's own come back too.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end

defines={inventory={assembling_machine_input=2,assembling_machine_output=3,chest=1},wire_connector_id={circuit_red=1,circuit_green=2}}
prototypes={item={['fusion-generator']={stack_size=5}},quality={normal={}}}
local function inv(t) return {get_item_count=function(n) return t[type(n)=='table' and n.name or n] or 0 end} end
local function cb(t) return function() return t end end
local recipe={name='fusion-generator',energy=30,products={{type='item',name='fusion-generator',amount=1}},
  ingredients={{type='item',name='tungsten-plate',amount=100},{type='item',name='superconductor',amount=100},{type='item',name='quantum-processor',amount=50}}}
-- Astra's plant as world n had it at d27 12:10: speed 2, its input 2 crafts' worth (201, 201, 100), off by its own
-- logistic condition; the input inserter's own logistic "fusion-generator < 6"; the output into a passive provider.
local m_cb={connect_to_logistic_network=true,logistic_condition={first_signal={type='item',name='fusion-generator'},comparator='<',constant=2},circuit_enable_disable=false,disabled=true}
local m={valid=true,unit_number=1,name='cryogenic-plant',type='assembling-machine',position={x=42.5,y=-24.5},crafting_speed=2,products_finished=36,
  bounding_box={left_top={x=40,y=-27},right_bottom={x=45,y=-22}},get_recipe=function() return recipe,{name='normal'} end,
  get_control_behavior=cb(m_cb)}
local mi,mo=inv({['tungsten-plate']=201,superconductor=201,['quantum-processor']=100}),inv({})
m.get_inventory=function(i) return i==2 and mi or i==3 and mo or nil end
local req={valid=true,unit_number=2,name='requester-chest',position={x=41.5,y=-20.5},prototype={logistic_mode='requester'},
  get_item_count=function() return 0 end,get_requester_point=function() return {trash_not_requested=false} end}
local dest={valid=true,unit_number=5,name='passive-provider-chest',type='logistic-container',position={x=43.5,y=-20.5},
  get_inventory=function() return {get_insertable_count=function(n) eq(n,'fusion-generator'); return 233 end} end}
local i_cb={connect_to_logistic_network=true,logistic_condition={first_signal={type='item',name='fusion-generator'},comparator='<',constant=6},circuit_enable_disable=false}
local input={valid=true,unit_number=3,type='inserter',position={x=41.5,y=-21.5},pickup_target=req,drop_target=m,get_control_behavior=cb(i_cb)}
local output={valid=true,unit_number=4,type='inserter',position={x=43.5,y=-21.5},pickup_target=m,drop_target=dest}
m.surface={find_entities_filtered=function() return {input,output} end}
local B=dofile('mod/agent-harness_0.1.0/batch.lua'){position=function(q) return q end,integer=function(v) return v end,
  entity=function() return m end,submit=function() end}

do
  local r=B.run({},{position={x=42.5,y=-24.5},count=10,dry_run=true})
  local labels,by={},{}
  for i,st in ipairs(r.steps) do labels[i]=st.label; by[st.label]=st end
  eq(table.concat(labels,' / '),'machine condition off / input held / clear requester / stage / staged tungsten-plate / staged superconductor / staged quantum-processor / staged / input on / made / input condition back / machine condition back')
  -- nothing is waited for in the machine: 10 crafts on its counter, from the 36 read now
  eq(by.made.args['until'],'produced'); eq(by.made.args.counter_from,36); eq(by.made.args.at_least,10); eq(by.made.args.item,nil)
  eq(by.made.args.position.x,42.5)
  for _,st in ipairs(r.steps) do assert(not (st.action=='circuit_set' and st.args.position.x==43.5),'the output inserter is not held') end
  -- the machine's own condition off for the batch and back after
  eq(by['machine condition off'].args.logistic,false); eq(by['machine condition off'].args.position.x,42.5)
  eq(by['machine condition back'].args.logistic,'fusion-generator < 2')
  -- the input's own condition back after (in place of input off)
  eq(by['input held'].args.logistic,'tungsten-plate < -2147483648')
  eq(by['input condition back'].args.logistic,'fusion-generator < 6')
  eq(r.counter.now,36); eq(r.counter.done_at,46); eq(r.output_stack,5); eq(r.feeds_until,2)
  eq(r.destination,'passive-provider-chest (43.5,-20.5)'); eq(r.room,233)
  eq(r.machine_condition,'logistic "fusion-generator < 2", off by it now'); eq(r.input_condition,'logistic "fusion-generator < 6"'); eq(r.output_condition,nil)
  local text=table.concat(r.plan,'\n')
  has(text,'counted by its products-finished counter (its GUI\'s crafts, productivity bonus crafts too): 36 now, the batch done at 46; the products are not held in it (its output holds one stack, 5 fusion-generator, and inserters stop feeding it at 2 held): they go out through output inserter (43.5,-21.5) into passive-provider-chest (43.5,-20.5) (room for 233 fusion-generator there now)')
  has(text,'the machine\'s own condition (logistic "fusion-generator < 2", off by it now) is switched off for the batch and set back after')
  has(text,'its own condition (logistic "fusion-generator < 6") is set back after the batch')
  has(text,'tungsten-plate: 1000 for 10 crafts, the machine holds 201, the requester 0: 799 to come')
  has(text,'then: its requests cleared, the input on, wait for 10 crafts on its counter (46), the input\'s own condition set back')
  print('AB Astra\'s plant: counter, its own condition off and back: ok')
end

-- a chest with less room than the batch: said; the output inserter's own conditions (a wired circuit condition) off and
-- back; an unwired circuit condition is ignored (2.0.77 runs the entity whatever it says)
do
  dest.get_inventory=function() return {get_insertable_count=function() return 3 end} end
  local o_cb={connect_to_logistic_network=false,circuit_enable_disable=true,circuit_condition={first_signal={type='virtual',name='signal-A'},comparator='\226\137\165',second_signal={type='item',name='fusion-generator',quality='rare'}}}
  output.get_control_behavior=cb(o_cb)
  output.get_circuit_network=function(id) if id==1 then return {} end end
  m_cb.connect_to_logistic_network=false; m_cb.circuit_enable_disable=true   -- no wire on the machine: ignored
  i_cb.connect_to_logistic_network=false
  local r=B.run({},{position={x=42.5,y=-24.5},count=10,dry_run=true})
  local labels,by={},{}
  for i,st in ipairs(r.steps) do labels[i]=st.label; by[st.label]=st end
  eq(labels[1],'output condition off'); eq(by['output condition off'].args.remove_condition,true); eq(by['output condition off'].args.logistic,nil)
  eq(by['output condition back'].args.enable,'signal-A >= fusion-generator@rare')
  eq(by['machine condition off'],nil,'an unwired circuit condition is not the machine\'s'); eq(r.machine_condition,nil)
  eq(by['input off'].args.logistic,'tungsten-plate < -2147483648','no own condition: the input stays held after')
  eq(labels[#labels],'output condition back')
  has(table.concat(r.plan,'\n'),'passive-provider-chest (43.5,-20.5) has room for 3 of the 10: once it is full the rest stays in the machine (inserters stop feeding it at 2 held) and the batch waits until something takes from it')
  has(table.concat(r.plan,'\n'),'output inserter (43.5,-21.5): its own condition (circuit "signal-A >= fusion-generator@rare" (wired)) is switched off for the batch and set back after')
  print('AB room, the output\'s own wired condition, an unwired machine condition: ok')
end

-- a condition with no signal cannot be set back by circuit_set: switched off, said, not set back
do
  m_cb.connect_to_logistic_network=true; m_cb.logistic_condition={comparator='<',constant=0}; m_cb.circuit_enable_disable=false
  local r=B.run({},{position={x=42.5,y=-24.5},count=1,dry_run=true})
  local by={}
  for _,st in ipairs(r.steps) do by[st.label]=st end
  eq(by['machine condition off'].args.logistic,false); eq(by['machine condition back'],nil)
  has(table.concat(r.plan,'\n'),'the machine\'s own condition (logistic condition with no signal, off by it now) is switched off for the batch and stays off after (circuit_set cannot set a condition with no signal)')
  has(table.concat(r.plan,'\n'),'wait for 1 craft on its counter (37)')
  print('AB a condition with no signal: ok')
end

-- the staged waits wait in the requester: a batch whose ingredients do not fit its slots (with what else it holds, under
-- its bar) is refused, in the dry run said; a batch longer than the made wait's 900 s is said (fusion-generator: 30 s a
-- craft at speed 2)
do
  m_cb.connect_to_logistic_network=false
  prototypes.item['tungsten-plate']={stack_size=50}; prototypes.item.superconductor={stack_size=200}; prototypes.item['quantum-processor']={stack_size=100}
  prototypes.item['iron-plate']={stack_size=100}
  local held={}
  req.get_inventory=function() local t={get_bar=function() return 49 end,get_contents=function() return held end}; return setmetatable(t,{__len=function() return 48 end}) end
  local r=B.run({},{position={x=42.5,y=-24.5},count=10,dry_run=true})
  eq(r.refused,nil); eq(r.line,'dry run: nothing queued')
  -- 40 crafts: 4000 - 201 tungsten (80 slots) alone is more than 48
  r=B.run({},{position={x=42.5,y=-24.5},count=40,dry_run=true})
  has(r.refused,'the requester (41.5,-20.5) has 48 slots; the batch must hold 3799 tungsten-plate (76 slots), 3799 superconductor (19 slots), 1900 quantum-processor (19 slots) there at once: 114 slots. Refused')
  has(r.line,'dry run: refused, nothing would be queued: '); eq(r.steps,nil)
  assert(not table.concat(r.plan,'\n'):find('take about',1,true),'600 s is within the 900 s wait')
  local ok,err=pcall(B.run,{},{position={x=42.5,y=-24.5},count=40})
  assert(not ok); has(err,'Refused: a smaller count')
  -- 10 crafts need 24 slots (799 tungsten 16, 799 superconductor 4, 400 quantum 4); other items and a bar count
  held={{name='iron-plate',quality='normal',count=2500},{name='tungsten-plate',quality='normal',count=50}}
  r=B.run({},{position={x=42.5,y=-24.5},count=10,dry_run=true})
  has(r.refused,', and other items fill 25: 49 slots. Refused')
  req.get_inventory=function() local t={get_bar=function() return 25 end,get_contents=function() return {} end}; return setmetatable(t,{__len=function() return 48 end}) end
  r=B.run({},{position={x=42.5,y=-24.5},count=12,dry_run=true})
  has(r.refused,'the requester (41.5,-20.5) has 24 slots (its bar at 24 of 48)')
  -- 70 crafts: about 1050 s, more than the made wait's 900
  req.get_inventory=nil
  r=B.run({},{position={x=42.5,y=-24.5},count=70,dry_run=true})
  has(table.concat(r.plan,'\n'),'at its crafting speed 2 the 70 crafts take about 1050 s: the made wait times out at 900 s first')
  print('AB the requester\'s slots, the made wait\'s time: ok')
end

-- produced with counter_from counts from that count: crafts finished before the wait's first check count too
do
  game={get_surface=function() return nil end}
  prototypes={item={['fusion-generator']={}},recipe={['fusion-generator']={name='fusion-generator',products={{type='item',name='fusion-generator',amount=1}}}},space_location={}}
  local mach={valid=true,unit_number=9,type='assembling-machine',name='cryogenic-plant',position={x=42.5,y=-24.5},products_finished=40,get_recipe=function() return {name='fusion-generator'} end}
  local p={force={name='player'},surface={index=1,find_entities_filtered=function() return {mach} end}}
  local C=require('conditions'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,known=function() return true end}
  local c={['until']='produced',position={x=42.5,y=-24.5},counter_from=36,at_least=10}
  C.validate(c)
  local rec={}
  local met,saw=C.check(p,c,true,rec)
  eq(met,false); has(saw,'made 4 crafts in 1 machine since the wait began (at least 10)')
  mach.products_finished=46; eq((C.check(p,c,true,rec)),true)
  assert(not pcall(C.validate,{['until']='produced',positions={{1,1},{2,2}},counter_from=3,at_least=1}),'one machine')
  assert(not pcall(C.validate,{['until']='produced',position={1,1},counter_from=-1,at_least=1}),'a whole number')
  assert(not pcall(C.validate,{['until']='produced',position={1,1},counter_from=2.5,at_least=1}),'a whole number')
  game=nil
  print('AB produced counter_from: ok')
end
defines=nil; prototypes=nil
print('d27_batch278 AB: ok')
