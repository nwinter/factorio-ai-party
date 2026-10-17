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
print('d17 batch18 ok')
