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
