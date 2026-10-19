-- d18 batch37. Run from the harness root: lua tests/d18_batch37.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1-A3 (Opus about 10 times with a 16-call grid script; Astra 4+; Haiku: which shell maker lacked what): every maker of
-- an item on the surface, nearest first, with status and why, rate, inputs against one craft, and what it feeds.
do
  defines={inventory={assembling_machine_input=2,assembling_machine_output=3,furnace_source=4,furnace_result=5},entity_status={disabled_by_control_behavior=9}}
  local shell={name='artillery-shell',energy=15,products={{type='item',name='artillery-shell',amount=1}},
    ingredients={{type='item',name='explosive-cannon-shell',amount=4},{type='item',name='radar',amount=1},{type='item',name='explosives',amount=8}}}
  prototypes={item={['artillery-shell']={}},recipe={['artillery-shell']=shell,['iron-plate']={products={{name='iron-plate',amount=1}}}}}
  local surface={name='nauvis'}
  local force={}
  local function machine(id,x,y,status,inputs,out)
    local e={valid=true,unit_number=id,name='assembling-machine-2',type='assembling-machine',force=force,surface=surface,position={x=x,y=y},
      bounding_box={left_top={x=x-1.5,y=y-1.5},right_bottom={x=x+1.5,y=y+1.5}},crafting_speed=0.75,productivity_bonus=0,status=status}
    e.get_inventory=function(i) local t=i==2 and inputs or {['artillery-shell']=out or 0}; return {get_item_count=function(n) return t[n] or 0 end} end
    return e
  end
  local m1=machine(1,10,0,'working',{['explosive-cannon-shell']=8,radar=2,explosives=16},2)
  local m2=machine(2,40,0,'item_ingredient_shortage',{['explosive-cannon-shell']=1,radar=1,explosives=8},0)
  local m3=machine(3,-80,0,'disabled_by_control_behavior',{},0)
  local chest={valid=true,name='requester-chest',position={x=10,y=3}}
  local out_ins={valid=true,name='inserter',position={x=10,y=2},pickup_target=m1,drop_target=chest,status=1}
  local in_ins={valid=true,name='inserter',position={x=40,y=-2},drop_target=m2,status=9}
  surface.find_entities_filtered=function(f) if f.area[1][1]<12 and f.area[1][1]>5 then return {out_ins} elseif f.area[1][1]>30 then return {in_ins} end return {} end
  local M=dofile('mod/agent-harness_0.1.0/makersall.lua'){status_name=function(e) return e.status end,
    state_text=function(e) return e==m3 and 'off by its logistic condition explosives > 100 (network holds 40)' or 'off by its circuit condition signal-A > 0 (signal-A 0 on its wires)' end,
    census_makers=function() return {craft={['artillery-shell']={m2,m3,m1}}} end}
  eq(M.recipes_of('artillery-shell')[1],'artillery-shell')
  local r=M.read({surface=surface,position={x=0,y=0},force=force},'artillery-shell',surface,{makers='all'})
  eq(r.makers,3); eq(r.rows[1].position.x,10,'nearest first')
  eq(r.lines[1],'assembling-machine-2 (10,0) artillery-shell: working; 3 a minute; inputs explosive-cannon-shell 8/4, radar 2/1, explosives 16/8; output holds 2 artillery-shell; feeds requester-chest (10,3) (by inserter (10,2))')
  has(r.lines[2],'assembling-machine-2 (40,0) artillery-shell: item ingredient shortage (input inserter (40,-2) off by its circuit condition signal-A > 0 (signal-A 0 on its wires)); 0 a minute; inputs explosive-cannon-shell 1/4')
  has(r.lines[3],'disabled by control behavior (off by its logistic condition explosives > 100 (network holds 40))')
  eq(r.rows[2].short[1],'explosive-cannon-shell')
  has(r.line,'3 machines on nauvis make artillery-shell (3 artillery-shell): 1 disabled_by_control_behavior, 1 item_ingredient_shortage, 1 working')
  -- paged
  M.PAGE=2
  r=M.read({surface=surface,position={x=0,y=0},force=force},'artillery-shell',surface,{makers='all'})
  eq(#r.rows,2); eq(r.next_from,3)
  r=M.read({surface=surface,position={x=0,y=0},force=force},'artillery-shell',surface,{makers='all',from=3})
  eq(#r.rows,1); eq(r.next_from,nil)
  fails(function() M.read({surface=surface,force=force},'artillery-shell',surface,{makers=true}) end,'makers is "all"')
  defines,prototypes=nil,nil
end
print('d18_batch37 A1-A3 every maker of an item: ok')

-- A2 (Opus): makers_worst names a machine's own enable condition when it is disabled_by_control_behavior; it ranks with
-- the gated ones, so three short machines no longer hide it.
do
  defines={inventory={assembling_machine_input=2,assembling_machine_output=3,furnace_source=4,furnace_result=5},entity_status={disabled_by_control_behavior='disabled_by_control_behavior'}}
  local recipe={name='low-density-structure',ingredients={{type='item',name='steel-plate',amount=2}}}
  local function m(x,status) return {valid=true,unit_number=x,name='assembling-machine-2',position={x=x,y=0},status=status,
    get_inventory=function() return {get_item_count=function() return 0 end} end} end
  local list={}
  for i=1,3 do list[#list+1]={e=m(i,'item_ingredient_shortage'),recipe=recipe} end
  list[#list+1]={e=m(9,'disabled_by_control_behavior'),recipe=recipe}
  local S=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return e.status end,
    state_text=function() return 'off by its logistic condition low-density-structure < 400 (network holds 900)' end}
  local _,worst=S.machines({item='low-density-structure',spots={}},list,'makers',{},nil)
  has(worst[1],'(9,0) assembling-machine-2 disabled_by_control_behavior (off by its logistic condition low-density-structure < 400 (network holds 900))')
  defines=nil
end
print('d18_batch37 A2 a machine off by its own condition among the worst: ok')

-- B1 (Sonnet: calcite in chests the silo's network could not give; Grok: 16,000 copper ore in plain chests on Gleba):
-- where a surface holds an item no network gives, from the census lists.
do
  game={tick=100}
  local function chest(id,x,y,typ,mode,n,ln)
    return {valid=true,unit_number=id,name=typ=='container' and 'steel-chest' or mode..'-chest',type=typ,position={x=x,y=y},
      prototype={logistic_mode=mode},logistic_network=ln,get_item_count=function() return n end}
  end
  local net5,net7={network_id=5},{network_id=7}
  local chests={chest(1,30,0,'container',nil,5200),chest(2,10,0,'container',nil,4000),chest(3,5,0,'logistic-container','requester',98),
    chest(4,50,0,'logistic-container','passive-provider',300,net7),chest(5,60,0,'logistic-container','passive-provider',20,net5),
    chest(6,70,0,'logistic-container','passive-provider',7,nil)}
  local furnace={valid=true,name='stone-furnace',position={x=2,y=2},get_output_inventory=function() return {get_item_count=function() return 12 end} end}
  local E=dofile('mod/agent-harness_0.1.0/elsewhere.lua'){chests=function() return chests end,crafters=function() return {furnace} end}
  local surface={index=3,name='gleba'}
  local line,total=E.line({name='player'},surface,'copper-ore',nil,{x=0,y=0})
  eq(total,9317)
  eq(line,'gleba holds 9317 copper-ore outside the logistic networks\' providers and storage: plain chests 9207 in 3 (no network gives them; nearest steel-chest (10,0) 4000, steel-chest (30,0) 5200, passive-provider-chest (70,0) 7); requester and buffer chests 98 in 1 (theirs; nearest requester-chest (5,0) 98); machine outputs 12 in 1 (nearest stone-furnace (2,2) 12)')
  -- from network 5 (a silo's): network 7's providers count, network 5's do not
  game.tick=5000
  line=E.line({name='player'},surface,'copper-ore',net5,{x=0,y=0})
  has(line,'that network 5 cannot give'); has(line,'network 7\'s provider and storage chests 300 in 1'); assert(not line:find('network 5\'s',1,true),line)
  has(E.line({name='player'},surface,'copper-ore',net5,{x=0,y=0},true),'plain chests 9207')
  assert(not E.line({name='player'},surface,'copper-ore',net5,{x=0,y=0},true):find('network 7',1,true))
  game=nil
end
print('d18_batch37 B1 where a surface holds what no network gives: ok')
