package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,w) assert(s and s:find(w,1,true),tostring(s)..' lacks '..w) end
local function lacks(s,w) assert(not (s and s:find(w,1,true)),tostring(s)..' has '..w) end
game={tick=600}
defines={entity_status={waiting_for_source_items=32,working=1},inventory={chest=1},robot_order_type={pickup=1,deliver=2}}

-- A1 (Grok): why an inserter waits for source items.
prototypes={item={['rocket-fuel']={fuel_value=100e6},['yumako-seed']={fuel_value=4e6},['iron-plate']={fuel_value=0}}}
local D=require('details'){}
local function inv(list)
  return {get_contents=function() return list end}
end
local robots={}
local net={network_id=98,get_item_count=function(n) return n=='rocket-fuel' and 0 or 5 end}
local chest={valid=true,name='requester-chest',type='logistic-container',position={x=49.5,y=48.5},prototype={logistic_mode='requester'},
  logistic_network=net,get_output_inventory=function() return inv({{name='rocket-fuel',count=7},{name='spoilage',count=200}}) end,
  surface={find_entities_filtered=function() return robots end}}
local fuel=inv({{name='rocket-fuel',count=5}})
local tower={valid=true,name='heating-tower',type='reactor',position={x=46.5,y=48.5},get_fuel_inventory=function() return fuel end,
  can_insert=function() return true end,prototype={get_max_energy_usage=function() return 40e6/60 end}}
setmetatable(fuel,{__len=function() return 2 end})
local ins={type='inserter',name='fast-inserter',position={x=48.5,y=48.5},status=32,pickup_target=chest,drop_target=tower,
  use_filters=true,filter_slot_count=5,inserter_filter_mode='whitelist',get_filter=function(k) return k==1 and {name='rocket-fuel',quality='normal'} or nil end}
local w=D.pickup_wait(ins)
has(w,'requester-chest (49.5,48.5) holds rocket-fuel 7');lacks(w,'spoilage 200')
has(w,'its logistic network 98 holds rocket-fuel 0 outside requester chests')
has(w,'heating-tower (46.5,48.5) takes rocket-fuel; its 2 fuel slots hold rocket-fuel 5');has(w,'top fuel up only while it runs low')
has(w,'burns 24.0 rocket-fuel a minute')
-- the fuel slots taken by other fuels: the tower takes none
fuel.get_contents=function() return {{name='yumako-seed',count=10},{name='spoilage',count=10}} end
tower.can_insert=function() return false end
w=D.pickup_wait(ins);has(w,'takes no rocket-fuel now: its 2 fuel slots hold yumako-seed 10, spoilage 10')
-- nothing it may take in the chest; robots on their way to take from it
chest.get_output_inventory=function() return inv({{name='spoilage',count=200}}) end
robots={{robot_order_queue={{type=1,target=chest}}},{robot_order_queue={{type=2,target=chest}}}}
w=D.pickup_wait(ins);has(w,'holds none of rocket-fuel');has(w,'1 logistic robot near it on the way to take from it')
-- another status: no line
ins.status=1;eq(D.pickup_wait(ins),nil)
-- a machine drop target
ins.status=32;robots={}
chest.get_output_inventory=function() return inv({{name='iron-plate',count=40}}) end
ins.get_filter=function() return nil end
local asm={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=47,y=48},can_insert=function() return true end,
  get_item_count=function() return 12 end}
ins.drop_target=asm
w=D.pickup_wait(ins);has(w,'holds iron-plate 40');has(w,'assembling-machine-2 (47,48) takes iron-plate and holds 12 of it')
asm.can_insert=function() return false end;asm.get_recipe=function() return {name='gear'} end
w=D.pickup_wait(ins);has(w,'takes no iron-plate now (recipe gear)')

-- A3 (Sol): an entry's settings go to the entity or ghost of the entry's name at its position (a tree or chimney there
-- took them before); a dry run checks each setting by the runtime's own checks (api.dry) and counts the refusals.
local calls={}
local ES=require('entryset'){check=function() end,position=function(p) return p end,reason=function(e) return tostring(e) end,
  call=function(action,_,args) calls[#calls+1]={action,args.name}; return {} end,
  dry=function(_,entry,kind,args) if kind=='requests' and args.set and #args.set==0 then error('set requires an array of {item,min,max?,quality?,from?}',0) end end}
local entries={{name='fast-inserter',position={x=0.5,y=160.5},circuit={logistic='gun-turret < 10'}},
  {name='requester-chest',position={x=5.5,y=160.5},requests={set={['iron-plate']=200}}}}
local rows,line=ES.apply({},entries,{},{})
eq(calls[1][1],'circuit_set');eq(calls[1][2],'fast-inserter');eq(calls[2][2],'requester-chest');has(line,'2 set')
local drows,dline,n=ES.dry({},entries)
eq(n,1);eq(drows[1].circuit,'ok');has(drows[2].requests,'set requires an array');has(dline,'1 would be set, 1 refused: entry 2 requests')
-- A4 (Sonnet): transfer's entity_position is position, mode take is the direction.
local A=dofile('mod/agent-harness_0.1.0/aliases.lua')({})
local takes=function(action,key) return ({position=true,direction=true,item=true,count=true,positions=true,radius=true,set=true})[key]==true end
local act,args,fixed=A.fix('transfer',{entity_position={x=22.5,y=136.5},mode='take',item='iron-plate',count=1},takes)
eq(args.position.x,22.5);eq(args.entity_position,nil);eq(args.direction,'to_player');eq(args.mode,nil)
has(table.concat(fixed.notes,'; '),'entity_position is position');has(table.concat(fixed.notes,'; '),'mode take is direction="to_player"')
act,args=A.fix('transfer',{position={x=1,y=1},entity_position={x=2,y=2},item='coal'},takes);eq(args.entity_position.x,2) -- two places: not guessed
-- A3: an entry's settings are read as the action's own call reads them (a requests set given as a map).
local ES2=require('entryset'){check=function() end,position=function(p) return p end,reason=tostring,
  fix=function(action,a) return A.fix(action,a,takes) end}
local list={{name='requester-chest',position={x=5.5,y=160.5},requests={set={['iron-plate']=200,['copper-plate']=100}}}}
local notes=ES2.check(list,{})
eq(list[1].requests.set[1].item,'copper-plate');eq(list[1].requests.set[2].min,200);has(notes[1],'entry 1 requests: set as a map')
-- B1 (Sol): a short maker whose input inserter is off by its condition, or whose requester asks for less than one
-- craft, reads as that before its shortage, ranked ahead of plain shortages.
defines.entity_status.disabled_by_control_behavior=55
defines.inventory.assembling_machine_input=2
local function machine(x,id) return {valid=true,unit_number=id,name='assembling-machine-2',type='assembling-machine',position={x=x,y=0},
  get_inventory=function() return {get_item_count=function() return 0 end} end} end
local chest={valid=true,unit_number=90,name='wooden-chest',type='container',position={x=1,y=3},get_item_count=function(n) return n=='tungsten-plate' and 40 or 0 end}
local req={valid=true,unit_number=91,name='requester-chest',type='logistic-container',position={x=9,y=3},prototype={logistic_mode='requester'},
  get_item_count=function() return 0 end,get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,
  filters={{value={name='tungsten-plate'},min=5}}} end} end}
local m1,m2,m3=machine(0,81),machine(8,82),machine(20,83)
local arm1={valid=true,unit_number=71,name='fast-inserter',position={x=1,y=2},status=55,pickup_target=chest}
local arm2={valid=true,unit_number=72,name='fast-inserter',position={x=9,y=2},status=32,pickup_target=req}
local recipe={name='artillery-shell',ingredients={{name='tungsten-plate',amount=10}}}
local SU=require('supply'){status_name=function() return 'item_ingredient_shortage' end,state_text=function(i) return 'off by its logistic condition artillery-shell < 20' end}
local t={item='artillery-shell',request_of={},spots={}}
local line,worst=SU.machines(t,{{e=m3,recipe=recipe,into={}},{e=m1,recipe=recipe,into={arm1}},{e=m2,recipe=recipe,into={arm2}}},'makers',{},{})
has(worst[1],'(0,0) assembling-machine-2 input fast-inserter (1,2) off by its logistic condition artillery-shell < 20; its source wooden-chest (1,3) holds 40 tungsten-plate; so item_ingredient_shortage (missing tungsten-plate)')
has(worst[2],'its requester requester-chest (9,3) asks for 5 tungsten-plate, one craft takes 10; it holds 0; so item_ingredient_shortage')
has(worst[3],'(20,0) assembling-machine-2 item_ingredient_shortage');has(line,'2 of the short held back by an input inserter')
-- B3 (Astra): a ghost's robot (an order on it anywhere in the queue) and what holds it; a robot with no charge in no
-- roboport's queue is held up; construction_robots lists the ghosts waiting on held-up robots.
defines.inventory.robot_cargo=9;defines.robot_order_type.construct=3
local RB=dofile('mod/agent-harness_0.1.0/robots.lua'){position=function(v) return v end}
local function cargo(list) return {get_contents=function() return list end} end
local function bot(x,energy,items,queue) return {valid=true,name='construction-robot',position={x=x,y=0},energy=energy,prototype={max_energy=3000000},
  robot_order_queue=queue,get_inventory=function() return cargo(items) end} end
local pole={valid=true,type='entity-ghost',ghost_name='medium-electric-pole',name='entity-ghost',position={x=86.5,y=156.5},unit_number=501}
local panel={valid=true,type='entity-ghost',ghost_name='solar-panel',name='entity-ghost',position={x=84.5,y=157.5},unit_number=502}
local pchest={valid=true,type='logistic-container',name='passive-provider-chest',position={x=-34.5,y=-60.5}}
local flat=bot(-2.5,0,{{name='wood',count=4,quality='normal'}},{{type=1,target=pchest},{type=3,target=pole}})
local hover=bot(30,1500000,{{name='wood',count=3,quality='normal'}},{})
local rcell={owner={valid=true,name='roboport',position={x=0,y=0},unit_number=9},charging_robots={},to_charge_robots={},is_in_construction_range=function() return true end}
local rnet={valid=true,network_id=243,construction_robots={flat,hover},all_construction_robots=2,available_construction_robots=0,cells={rcell},storages={},
  find_cell_closest_to=function() return rcell end,select_drop_point=function() return nil end,
  get_item_count=function(n) return n=='medium-electric-pole' and 100 or 2582 end}
local rforce={logistic_networks={nauvis={rnet}},find_logistic_network_by_position=function() return rnet end}
local out=RB.read({surface={name='nauvis'},position={x=0,y=0},force=rforce},{})
has(out.summary,'2 in the air, 2 held up')
eq(out.ghosts_waiting[1],'medium-electric-pole ghost (86.5,156.5) waits on construction-robot (-2.5,0) (its order 2 of 2): no charge (energy 0%)')
has(out.robots[2],'nowhere to put wood*3')
prototypes.entity={}
for _,g in ipairs({pole,panel}) do g.force=rforce; g.ghost_prototype={items_to_place_this={{name=g.ghost_name,count=1}}} end
local surf={name='nauvis',find_entities_filtered=function() return {pole,panel} end,find_logistic_networks_by_construction_area=function() return {rnet} end}
local GL=dofile('mod/agent-harness_0.1.0/ghostlist.lua'){position=function(v) return v end,integer=function(v,d) return v or d end,
  distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end,robot_row=function(r,net,c) return RB.row(r,net,c) end}
local gr=GL.read({surface=surf,position={x=86,y=158},force=rforce,get_main_inventory=function() return nil end},{})
has(gr.lines[1],'robot: construction-robot (-2.5,0): energy 0%; holds wood*4; orders: pickup passive-provider-chest at (-34.5,-60.5); then construct medium-electric-pole ghost at (86.5,156.5); no charge (energy 0%) (its order 2 in the queue)')
has(gr.lines[2],'robot: no robot has an order on it')
has(gr.summary,'1 whose robot is held up; 2 of the 2 construction robots of network 243 in the air are held up: 1 no charge (energy 0%); 1 nowhere to put wood: no storage chest in network 243 has room for it (0 storage chests in it)')
-- B4 (Haiku): an out-of-fuel line names the nearest fuel its most common burner takes (chest first, else belt) and
-- refuel over the burners' area taking it from the nearest.
do
  prototypes.item={coal={fuel_category='chemical',fuel_value=4e6},nutrients={fuel_category='nutrients',fuel_value=2e6},['iron-plate']={fuel_value=0}}
  prototypes.entity={['stone-furnace']={burner_prototype={fuel_categories={chemical=true}}},biochamber={burner_prototype={fuel_categories={nutrients=true}}}}
  defines.inventory.chest=1
  local function holder(name,x,y,list) return {valid=true,name=name,position={x=x,y=y},get_inventory=function() return {get_contents=function() return list end} end} end
  local near,far=holder('iron-chest',100,-20,{{name='coal',count=120,quality='normal'}}),holder('wooden-chest',140,-20,{{name='coal',count=500,quality='normal'}})
  local fsurf={find_entities_filtered=function(f) if f.type[1]=='container' then return {far,near,holder('iron-chest',97,-22,{{name='iron-plate',count=50}})} end return {} end}
  game.get_surface=function(n) return n=='nauvis' and fsurf or nil end
  local PA=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return {board={items={}}} end,agents=function() return {} end,who=function(p) return p.name end}
  local g={kind='no_fuel',key='no_fuel|nauvis|1,-1',surface='nauvis',n=3,names={['stone-furnace']=2,biochamber=1},by={},center={x=96,y=-26},
    at={{x=96,y=-14},{x=96,y=-38},{x=95,y=-26}},status_entities={{position={x=96,y=-14}},{position={x=96,y=-38}},{position={x=95,y=-26}}}}
  local line=PA.text(g,'nauvis')
  has(line,'nearest fuel: coal 120 in iron-chest (100,-20), 7 tiles from (96,-26); refuel {area: [[93,-40],[98,-12]], from: "nearest", fuel: "coal"}')
  lacks(line,'refuel {alert')
  lacks(PA.text(g,'nauvis',nil,true),'nearest fuel')
  game.get_surface=nil
end
print('d17 batch18 ok')
