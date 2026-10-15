-- Run from repository root: lua tests/circuits.lua
-- Circuit settings, wires and their readback (circuits.lua: circuit_set, wire,
-- inspect's circuit block; reach and remote view, a platform or a planet by
-- name, a bot aboard a platform) and train stops and schedules (trains.lua),
-- through the runtime against a fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
-- As control.lua does: a failed request stops its player unless the runtime
-- marked it passive.
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.player or (req.bot==nil and 1 or nil)
    if req.bot then who=runtime.bots.index_of(req.bot) end
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local astra,sol,grok=as('astra'),as('sol'),as('grok')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sunny',glyph='S',color='#ffcb45'})


-- Fakes: signal prototypes, entities by position, control behaviours and
-- wire connectors (connections, colors, networks with their signals).
prototypes=prototypes or {}
prototypes.item=prototypes.item or {}
for _,n in ipairs({'iron-plate','ice','carbon','firearm-magazine'}) do prototypes.item[n]=prototypes.item[n] or {name=n,type='item'} end
prototypes.fluid={water={name='water'}}
prototypes.virtual_signal={['signal-A']={name='signal-A'},['signal-B']={name='signal-B'},['signal-S']={name='signal-S'}}
prototypes.recipe={['iron-plate']={name='iron-plate'}}
prototypes.quality={normal={name='normal'},rare={name='rare'}}
defines.wire_connector_id={circuit_red=1,circuit_green=2,combinator_input_red=1,combinator_input_green=2,combinator_output_red=3,combinator_output_green=4,
  pole_copper=5,power_switch_left_copper=5,power_switch_right_copper=6}
defines.wire_type={red=1,green=2,copper=3}
defines.wire_origin={player=0,radars=1,script=2}
defines.control_behavior={type={inserter=1,constant_combinator=2,arithmetic_combinator=3,decider_combinator=4,space_platform_hub=5,lamp=6,wall=7,container=8,generic_on_off=9},
  inserter={hand_read_mode={hold=0,pulse=1}}}
local CB=defines.control_behavior.type
-- A character reaches 15 tiles here, on its own surface.
for _,b in ipairs(runtime.bots.list()) do
  local c=b.character
  c.can_reach_entity=function(e) return e.surface==c.surface and math.abs(e.position.x-c.position.x)<=15 and math.abs(e.position.y-c.position.y)<=15 end
end
local hidden={}
force.is_chunk_visible=function(s,c) return not hidden[s.name..' '..c.x..','..c.y] end
local function connectors(e)
  local made={}
  local function make(id)
    local c={id=id,owner=e,links={},wire_connector_id=id}
    c.is_connected_to=function(o) return c.links[o]~=nil end
    c.can_wire_reach=function(o) return math.abs(o.owner.position.x-e.position.x)<=9 and math.abs(o.owner.position.y-e.position.y)<=9 end
    c.connect_to=function(o,reach,origin)
      if e.refuse or o.owner.refuse then return false end
      c.links[o]=origin or 0; o.links[c]=origin or 0; return true
    end
    c.disconnect_from=function(o) local was=c.links[o]~=nil; c.links[o]=nil; o.links[c]=nil; return was end
    return setmetatable(c,{__index=function(_,k)
      if k=='connections' then local out={}; for o,origin in pairs(c.links) do out[#out+1]={target=o,origin=origin} end; return out end
      if k=='wire_type' then if id>=5 then return 3 end; return (id==1 or id==3) and 1 or 2 end
      if k=='network_id' then return next(c.links) and 100+id or 0 end
    end})
  end
  e.get_wire_connector=function(id,create)
    if e.no_wires then error('no circuit connection') end
    if not made[id] and create then made[id]=make(id) end
    return made[id]
  end
  e.get_wire_connectors=function() return made end
  e.get_circuit_network=function(id)
    local c=made[id]
    if c and next(c.links) then return {network_id=100+id,signals=e.signals_now and e.signals_now[id]} end
  end
  return made
end
local world,on_platform,on_vulcanus={},{},{}
local psurf={name='platform-1',index=2,valid=true}
local vsurf={name='vulcanus',index=3,valid=true}
surface.valid=true
local function thing(name,type_,x,cb,y,surf)
  surf=surf or surface
  local e={valid=true,name=name,type=type_,position={x=x,y=y or 0},force=force,surface=surf,quality={name='normal'},direction=0,
    bounding_box={left_top={x=x-0.5,y=(y or 0)-0.5},right_bottom={x=x+0.5,y=(y or 0)+0.5}}}
  e.prototype={get_max_circuit_wire_distance=function() return e.no_wires and 0 or 9 end,get_max_wire_distance=function() return 7.5 end}
  e.wires=connectors(e)
  e.get_or_create_control_behavior=function() return cb end
  e.get_control_behavior=function() return cb end
  e.get_fluid_contents=function() return {} end
  e.get_inventory=function() return nil end
  if type_=='inserter' then e.pickup_position={x=x,y=(y or 0)-1}; e.drop_position={x=x,y=(y or 0)+1} end
  local list=surf==psurf and on_platform or surf==vsurf and on_vulcanus or world
  list[#list+1]=e
  return e
end
local NAMES={['iron-chest']=1,inserter=1,['constant-combinator']=1,['arithmetic-combinator']=1,['decider-combinator']=1,['train-stop']=1,locomotive=1,
  ['small-lamp']=1,['small-electric-pole']=1,['power-switch']=1,['space-platform-hub']=1,['fast-inserter']=1,thruster=1,gate=1}
local roboports={}
local function finder(list)
  return function(f)
    if f.type=='roboport' then return roboports end
    local out={}
    -- As the engine: a name filter must be an entity prototype (live check: a stop's name passed as `name` failed).
    if f.name then assert(NAMES[f.name],'Unknown entity name: '..f.name) end
    if f.position then for _,e in ipairs(list) do if e.valid and (not f.name or e.name==f.name) and math.abs(e.position.x-f.position.x)<0.3 and math.abs(e.position.y-f.position.y)<0.3 then out[#out+1]=e end end end
    return out
  end
end
surface.find_entities_filtered=finder(world)
psurf.find_entities_filtered=finder(on_platform)
vsurf.find_entities_filtered=finder(on_vulcanus)
local sunward={valid=true,name='Sunward',index=1,force=force,surface=psurf}
psurf.platform=sunward
force.platforms={sunward}
game.surfaces={nauvis=surface,['platform-1']=psurf,vulcanus=vsurf}
game.get_surface=function(n) if n==nil or n==1 or n=='nauvis' then return surface end return game.surfaces[n] end

local function cb_of(kind,fields)
  local cb={type=CB[kind]}
  for k,v in pairs(fields or {}) do cb[k]=v end
  return cb
end
local inserter_cb=cb_of('inserter',{circuit_enable_disable=false,connect_to_logistic_network=false,circuit_read_hand_contents=false,
  circuit_set_filters=false,circuit_set_stack_size=false,circuit_hand_read_mode=0})
local inserter=thing('inserter','inserter',2,inserter_cb)
local section={filters={}}
local const_cb=cb_of('constant_combinator',{enabled=true,sections_count=0})
const_cb.add_section=function() const_cb.sections_count=1; const_cb.sections={section}; return section end
const_cb.get_section=function(i) assert(i==1); return section end
local const=thing('constant-combinator','constant-combinator',4,const_cb)
local arith_cb=cb_of('arithmetic_combinator',{signals_last_tick={{signal={type='virtual',name='signal-A'},count=7}}})
local arith=thing('arithmetic-combinator','arithmetic-combinator',6,arith_cb)
local decider_cb=cb_of('decider_combinator')
local decider=thing('decider-combinator','decider-combinator',8,decider_cb)
local chest=thing('iron-chest','container',10,cb_of('container',{read_contents=false}))

-- An enable condition on an inserter, as text and as a table, a logistic
-- condition, then off again; the reply reads back what the game holds.
local r=astra('circuit_set',{position={x=2,y=0},enable='iron-plate < 100'})
eq(inserter_cb.circuit_enable_disable,true); eq(inserter_cb.circuit_condition.first_signal.name,'iron-plate')
eq(inserter_cb.circuit_condition.first_signal.type,'item'); eq(inserter_cb.circuit_condition.constant,100)
eq(r.circuit.enable,'iron-plate < 100'); eq(r.by,'reach'); eq(r.entity,'inserter')
r=astra('circuit_set',{position={x=2,y=0},enable={signal='iron-plate',comparator='<',value=100}})
eq(r.circuit.enable,'iron-plate < 100')
r=astra('circuit_set',{position={x=2,y=0},logistic={signal='water',comparator='>=',signal2='signal-A'}})
eq(inserter_cb.connect_to_logistic_network,true); eq(inserter_cb.logistic_condition.first_signal.type,'fluid')
eq(inserter_cb.logistic_condition.second_signal.type,'virtual'); eq(r.circuit.logistic,'water >= signal-A')
-- The network a logistic condition reads: the one whose logistic area holds the entity's centre, with its count
-- (Astra 10:27, world n: two foundries stayed off under "iron-plate < 3000" while their inserter 3 tiles south read
-- network 8, whose iron count was -3 after reserved deliveries).
do
  local net8={network_id=8,get_item_count=function(it) eq(it.name,'iron-plate'); eq(it.quality,'normal'); return -3 end}
  force.find_logistic_network_by_position=function(pos,surf) eq(surf,surface); if pos.y>=-8 then return net8 end end
  local rr=astra('circuit_set',{position={x=2,y=0},logistic='iron-plate < 3000'})
  eq(rr.circuit.logistic_reads,'network 8 (its logistic area holds the centre): iron-plate -3 (the count less what deliveries have reserved)')
  local foundry_cb=cb_of('assembling_machine',{circuit_enable_disable=false,connect_to_logistic_network=false})
  local foundry=thing('foundry','assembling-machine',12,foundry_cb,-9.5)
  roboports[1]={position={x=20,y=16},logistic_cell={logistic_radius=25,logistic_network={network_id=8}}}
  rr=astra('circuit_set',{position={x=12,y=-9.5},logistic='iron-plate < 3000'})
  eq(foundry_cb.connect_to_logistic_network,true)
  eq(rr.circuit.logistic_reads,'none: no logistic area holds its centre (12,-9.5), so the condition reads no network and is not met; the nearest, roboport (20,16) of network 8, ends 0.5 tiles from it')
  rr=astra('circuit_set',{position={x=12,y=-9.5},logistic=false}); eq(rr.circuit.logistic,false); eq(rr.circuit.logistic_reads,nil)
  foundry.valid=false; roboports[1]=nil; force.find_logistic_network_by_position=nil
  astra('circuit_set',{position={x=2,y=0},logistic={signal='water',comparator='>=',signal2='signal-A'}})
end
-- After a write, a condition that is not met keeps the entity off (friction2: Opus set "production-science-pack < 1000"
-- on an inserter whose logistic condition "< 100" read 101, told Astra it ran, and it stayed off 10.8 min): stays_disabled
-- names it, with what it reads, and whether this call set it. On 2.0.77 a condition's fulfilled is current the tick it is
-- written while the behavior's disabled lags a tick, so disabled comes from the conditions.
do
  local net8={network_id=8,get_item_count=function() return 101 end}
  force.find_logistic_network_by_position=function() return net8 end
  astra('circuit_set',{position={x=2,y=0},logistic='iron-plate < 100'})
  inserter_cb.logistic_condition.fulfilled=false
  inserter_cb.disabled=false
  local rr=astra('circuit_set',{position={x=2,y=0},enable='iron-plate < 1000'})
  eq(rr.circuit.disabled,true)
  eq(rr.stays_disabled,'inserter (2,0): its logistic condition iron-plate < 100 is not met (network 8 (its logistic area holds the centre): iron-plate 101) (not set by this call)')
  -- the circuit condition, read on its wires: only with a red or green wire (Astra 21:00: a fast inserter on Fulgora with
  -- enable EM < 0 and no wire read disabled and kept working; the game ignores a circuit condition without a wire)
  inserter.get_signal=function(sig,red,green) eq(sig.name,'iron-plate'); return 1500 end
  inserter_cb.circuit_condition.fulfilled=false
  inserter_cb.logistic_condition.fulfilled=true
  rr=astra('circuit_set',{position={x=2,y=0},logistic='iron-plate < 1000'})
  eq(rr.stays_disabled,nil); eq(rr.circuit.disabled,nil)
  eq(rr.circuit.enable_ignored,'no red or green wire connects it: the game ignores this condition')
  eq(rr.condition_ignored,'inserter (2,0): its circuit condition iron-plate < 1000 is ignored: no red or green wire connects it, and the game counts a circuit condition only with a circuit connection')
  local W=defines.wire_connector_id
  local red=inserter.get_wire_connector(W.circuit_red,true)
  red.connect_to(chest.get_wire_connector(W.circuit_red,true))
  rr=astra('circuit_set',{position={x=2,y=0},logistic='iron-plate < 1000'})
  eq(rr.stays_disabled,'inserter (2,0): its circuit condition iron-plate < 1000 is not met (iron-plate reads 1500 on its wires) (not set by this call)')
  eq(rr.circuit.enable_ignored,nil); eq(rr.condition_ignored,nil); eq(rr.circuit.disabled,true)
  -- both met, or not known: no note
  inserter_cb.circuit_condition.fulfilled=true
  inserter_cb.disabled=true
  rr=astra('circuit_set',{position={x=2,y=0},logistic='iron-plate < 1000'})
  eq(rr.stays_disabled,nil); eq(rr.circuit.disabled,nil)
  red.disconnect_from(chest.get_wire_connector(W.circuit_red,true))
  inserter.get_signal=nil; force.find_logistic_network_by_position=nil
  inserter_cb.disabled=nil
  astra('circuit_set',{position={x=2,y=0},logistic={signal='water',comparator='>=',signal2='signal-A'}})
end
-- The game writes >= back as ≥: read back in ASCII.
inserter_cb.logistic_condition.comparator='≥'
eq(astra('circuit_set',{position={x=2,y=0}}).circuit.logistic,'water >= signal-A')
r=astra('circuit_set',{position={x=2,y=0},enable='signal-A != signal-B'})
eq(inserter_cb.circuit_condition.second_signal.name,'signal-B'); eq(r.circuit.enable,'signal-A != signal-B')
astra('circuit_set',{position={x=2,y=0},enable=false}); eq(inserter_cb.circuit_enable_disable,false)
fails(function() astra('circuit_set',{position={x=2,y=0},enable={signal='unobtainium',value=1}}) end,'unknown signal unobtainium')
fails(function() astra('circuit_set',{position={x=2,y=0},enable={signal='iron-plate',comparator='~',value=1}}) end,'comparator is one of')
fails(function() astra('circuit_set',{position={x=2,y=0},enable={signal='iron-plate'}}) end,'value (a number) or signal2 is required')
fails(function() astra('circuit_set',{position={x=2,y=0},enable='iron-plate<5'}) end,'spaces around the comparator')
-- Nothing applies when one argument is wrong (checked before any change).
inserter_cb.circuit_enable_disable=false
fails(function() astra('circuit_set',{position={x=2,y=0},enable='iron-plate < 5',settings={circuit_hand_read_mode='sideways'}}) end,'is one of hold, pulse')
eq(inserter_cb.circuit_enable_disable,false)
fails(function() astra('circuit_set',{position={x=10,y=0},enable={signal='iron-plate',value=1}}) end,'iron-chest has no enable condition (its circuit settings: read_contents)')
fails(function() astra('circuit_set',{position={x=2,y=0},signals={}}) end,'signals: inserter is no constant combinator')
-- The old name runs as circuit_set and says so.
r=astra('circuit',{position={x=2,y=0},enable='iron-plate < 7'})
eq(inserter_cb.circuit_condition.constant,7); assert(r.corrected:find('circuit is circuit_set',1,true),r.corrected)
-- Read switches: short names, the entity's own names; settings by name.
r=astra('circuit_set',{position={x=2,y=0},read={hand=true}})
eq(inserter_cb.circuit_read_hand_contents,true); eq(r.read.hand,true); eq(r.circuit.settings.circuit_read_hand_contents,true)
fails(function() astra('circuit_set',{position={x=2,y=0},read={contents=true}}) end,'read: contents is not a switch of inserter (circuit_read_hand_contents, circuit_set_filters, circuit_set_stack_size, hand)')
fails(function() astra('circuit_set',{position={x=4,y=0},read={hand=true}}) end,'has no read switches')
r=astra('circuit_set',{position={x=10,y=0},read={contents=true}})
eq(chest.get_control_behavior().read_contents,true); eq(r.circuit.settings.read_contents,true)
r=astra('circuit_set',{position={x=2,y=0},settings={circuit_hand_read_mode='pulse',circuit_set_stack_size=true,circuit_stack_control_signal='signal-S'}})
eq(inserter_cb.circuit_hand_read_mode,1); eq(inserter_cb.circuit_set_stack_size,true); eq(inserter_cb.circuit_stack_control_signal.name,'signal-S')
eq(r.circuit.settings.circuit_hand_read_mode,'pulse'); eq(r.circuit.settings.circuit_stack_control_signal,'signal-S')
eq(r.circuit.off[1],'circuit_set_filters')
fails(function() astra('circuit_set',{position={x=2,y=0},settings={read_contents=true}}) end,
  'settings: read_contents is not a circuit setting of inserter (its settings: enable, logistic, circuit_hand_read_mode, circuit_read_hand_contents')
fails(function() astra('circuit_set',{position={x=2,y=0},settings={circuit_set_filters='yes'}}) end,'settings.circuit_set_filters must be boolean')
-- A constant combinator's signals (a quality, another kind of signal) and switch.
r=astra('circuit_set',{position={x=4,y=0},signals={{signal='iron-plate@rare',count=50},{signal='signal-A',count=1},{signal='recipe:iron-plate',count=2}},on=false})
eq(#section.filters,3); eq(section.filters[1].value.name,'iron-plate'); eq(section.filters[1].value.quality,'rare'); eq(section.filters[1].min,50)
eq(section.filters[2].value.type,'virtual'); eq(section.filters[3].value.type,'recipe')
eq(const_cb.enabled,false); eq(r.circuit.on,false)
eq(r.circuit.signals[1].name,'iron-plate@rare'); eq(r.circuit.signals[1].count,50); eq(r.circuit.signals[3].name,'recipe:iron-plate')
fails(function() astra('circuit_set',{position={x=4,y=0},signals={{signal='iron-plate@shiny',count=1}}}) end,'unknown quality shiny')
fails(function() astra('circuit_set',{position={x=4,y=0},signals={{signal='planet:nauvis',count=1}}}) end,'signal type planet is not one of')
-- Arithmetic and decider parameters; what a combinator outputs.
r=astra('circuit_set',{position={x=6,y=0},arithmetic={first='iron-plate',operation='/',constant=10,output='signal-A'}})
eq(arith_cb.parameters.operation,'/'); eq(arith_cb.parameters.second_constant,10); eq(arith_cb.parameters.output_signal.name,'signal-A')
eq(r.circuit.arithmetic.text,'iron-plate / 10 -> signal-A'); eq(r.circuit.output[1].name,'signal-A'); eq(r.circuit.output[1].count,7)
r=astra('circuit_set',{position={x=6,y=0},arithmetic={first=3,operation='+',second='signal-B',output='signal-A',second_networks='green'}})
eq(arith_cb.parameters.first_constant,3); eq(arith_cb.parameters.second_signal.name,'signal-B'); eq(arith_cb.parameters.second_signal_networks.red,false)
eq(r.circuit.arithmetic.text,'3 + signal-B -> signal-A'); eq(r.circuit.arithmetic.second_networks,'green')
fails(function() astra('circuit_set',{position={x=6,y=0},arithmetic={first='iron-plate',operation='sqrt',constant=1,output='signal-A'}}) end,'operation is one of')
astra('circuit_set',{position={x=8,y=0},decider={first='signal-A',comparator='>',constant=5,output='iron-plate',copy_input=true}})
eq(decider_cb.parameters.conditions[1].comparator,'>'); eq(decider_cb.parameters.conditions[1].constant,5)
eq(decider_cb.parameters.outputs[1].signal.name,'iron-plate'); eq(decider_cb.parameters.outputs[1].copy_count_from_input,true)
r=astra('circuit_set',{position={x=8,y=0},decider={conditions={'signal-A > 5',{signal='ice',comparator='<',value=9,compare='and',first_networks='red'}},
  outputs={'iron-plate',{signal='signal-B',constant=3}}}})
eq(#decider_cb.parameters.conditions,2); eq(decider_cb.parameters.conditions[2].compare_type,'and'); eq(decider_cb.parameters.conditions[2].first_signal_networks.green,false)
eq(decider_cb.parameters.outputs[1].copy_count_from_input,true); eq(decider_cb.parameters.outputs[2].copy_count_from_input,false); eq(decider_cb.parameters.outputs[2].constant,3)
eq(r.circuit.decider.conditions[1],'signal-A > 5'); eq(r.circuit.decider.conditions[2],'and ice < 9 [red,both]')
eq(r.circuit.decider.outputs[1],'iron-plate = input'); eq(r.circuit.decider.outputs[2],'signal-B = 3')
-- A refusal from the game comes back as a plain error and names what applied before it.
setmetatable(arith_cb,{__newindex=function() error('invalid parameters') end}); arith_cb.parameters=nil
fails(function() astra('circuit_set',{position={x=6,y=0},arithmetic={first='iron-plate',constant=2,output='signal-A'}}) end,'arithmetic: the game refused it: invalid parameters')
setmetatable(arith_cb,nil)
arith_cb.parameters={first_signal={name='iron-plate'},operation='*',second_constant=2,output_signal={type='virtual',name='signal-A'}}

-- Red and green wires: combinator sides default output -> input.
r=astra('wire',{from={x=4,y=0},to={x=6,y=0},color='red'})
eq(r.connected,true); eq(r.color,'red'); eq(r.by,'reach')
local out_c=const.wires[defines.wire_connector_id.circuit_red]; local in_c=arith.wires[defines.wire_connector_id.combinator_input_red]
assert(out_c.links[in_c]~=nil)
eq(r.from.entity,'constant-combinator'); eq(r.to.side,'input'); eq(r.from.wires[1].entity,'arithmetic-combinator'); eq(r.from.wires[1].side,'input')
eq(astra('wire',{from={x=4,y=0},to={x=6,y=0},color='red'}).already,true)
astra('wire',{from={x=6,y=0},to={x=8,y=0},color='green',from_side='output',to_side='input'})
assert(arith.wires[defines.wire_connector_id.combinator_output_green].links[decider.wires[defines.wire_connector_id.combinator_input_green]]~=nil)
-- A combinator's output back into its own input (a clock): two connectors of one entity.
r=astra('wire',{from={x=6,y=0},to={x=6,y=0},color='red',from_side='output',to_side='input'})
eq(r.connected,true)
fails(function() astra('wire',{from={x=6,y=0},to={x=6,y=0},color='red',from_side='input',to_side='input'}) end,'same connector')
-- inspect reads it all back: wires per connector with their far ends, the networks and their signals now.
arith.signals_now={[1]={{signal={name='iron-plate'},count=12},{signal={type='virtual',name='signal-A'},count=-40},{signal={name='ice'},count=0}}}
local ins=astra('inspect',{position={x=6,y=0}})
eq(#ins.circuit.wires.red_input,2); eq(ins.circuit.wires.red_input[1].entity,'constant-combinator'); eq(ins.circuit.wires.red_input[2].side,'output')
eq(ins.circuit.wires.green_output[1].entity,'decider-combinator'); eq(ins.circuit.wires.green_output[1].side,'input')
eq(ins.circuit.networks.red_input.id,101); eq(#ins.circuit.networks.red_input.signals,2)
eq(ins.circuit.networks.red_input.signals[1].name,'signal-A'); eq(ins.circuit.networks.red_input.signals[1].count,-40)
eq(ins.circuit.arithmetic.output,'signal-A')
-- A wire only the game draws (radars) is no wire a player sees.
local radar_end=thing('small-lamp','lamp',3,cb_of('lamp'),3)
local rc=radar_end.get_wire_connector(1,true); rc.links[out_c]=1; out_c.links[rc]=1
eq(#astra('inspect',{position={x=4,y=0}}).circuit.wires.red,1)
eq(astra('wire',{from={x=4,y=0},to={x=6,y=0},color='red',disconnect=true}).disconnected,true)
eq(astra('inspect',{position={x=4,y=0}}).circuit.wires,nil)
fails(function() astra('wire',{from={x=2,y=0},to={x=4,y=0},color='blue'}) end,'color is red or green')
fails(function() astra('wire',{from={x=2,y=0},to={x=4,y=0},color='red',from_side='input'}) end,'from_side applies to combinators only')
chest.no_wires=true
fails(function() astra('wire',{from={x=2,y=0},to={x=10,y=0},color='red'}) end,'iron-chest takes no red circuit wire')
local far=thing('small-lamp','lamp',30,cb_of('lamp',{circuit_enable_disable=false}))
fails(function() astra('wire',{from={x=2,y=0},to={x=30,y=0},color='green'}) end,'a green wire does not reach between inserter (2,0) and small-lamp (30,0): 28.0 tiles apart, the wire reaches 9')
-- An entity without a circuit connection: refused with the reason.
local pump=thing('thruster','thruster',11,nil,3)
pump.no_wires=true
fails(function() astra('circuit_set',{position={x=11,y=3},enable='ice < 5'}) end,'thruster has no circuit connection')

-- Remote view: out of reach in a visible chunk works (by says so); not visible is refused.
r=astra('circuit_set',{position={x=30,y=0},enable='signal-A > 0'})
eq(r.by,'remote view'); eq(far.get_control_behavior().circuit_enable_disable,true)
local yonder=thing('small-lamp','lamp',100,cb_of('lamp',{circuit_enable_disable=false}),5)
r=astra('circuit_set',{position={x=100,y=5},enable='signal-A > 1'})
eq(r.by,'remote view')
hidden['nauvis 3,0']=true
fails(function() astra('circuit_set',{position={x=100,y=5},enable='signal-A > 2'}) end,'visible chunk')
hidden['nauvis 3,0']=nil

-- Copper: pole to pole, a power switch's sides.
local pole1=thing('small-electric-pole','electric-pole',2,nil,6); pole1.electric_network_id=7
local pole2=thing('small-electric-pole','electric-pole',8,nil,6); pole2.electric_network_id=7
local switch=thing('power-switch','power-switch',5,cb_of('generic_on_off'),9)
r=astra('wire',{from={x=2,y=6},to={x=8,y=6}})
eq(r.connected,true); eq(r.color,'copper'); eq(r.network,7); eq(r.to.wires[1].entity,'small-electric-pole')
fails(function() astra('wire',{from={x=2,y=6},to={x=5,y=9}}) end,'to_side is left or right on a power switch')
r=astra('wire',{from={x=2,y=6},to={x=5,y=9},to_side='left'})
eq(r.connected,true); eq(r.to.side,'left')
eq(astra('inspect',{position={x=5,y=9}}).circuit.wires.copper_left[1].entity,'small-electric-pole')
fails(function() astra('wire',{from={x=2,y=6},to={x=2,y=0}}) end,'inserter takes no copper wire')
r=astra('wire',{from={x=2,y=6},to={x=8,y=6},disconnect=true})
eq(r.disconnected,true); eq(r.split,false)
pole2.refuse=true
fails(function() astra('wire',{from={x=2,y=6},to={x=8,y=6}}) end,'the game refused the copper wire')
-- The power switch's own enable condition; a kind the table lacks but with the enable switch takes it too.
r=astra('circuit_set',{position={x=5,y=9},enable='signal-A > 0'})
eq(r.circuit.enable,'signal-A > 0'); eq(r.circuit.wires.copper_left[1].entity,'small-electric-pole')
local odd_cb={type=99,circuit_enable_disable=false,connect_to_logistic_network=false}
thing('offshore-pump','offshore-pump',13,odd_cb,3)
r=astra('circuit_set',{position={x=13,y=3},enable='water > 10'})
eq(odd_cb.circuit_enable_disable,true); eq(odd_cb.circuit_condition.first_signal.type,'fluid'); eq(r.circuit.enable,'water > 10')

-- A platform by name: all of it in remote view, from the planet.
local hub_cb=cb_of('space_platform_hub',{read_contents=false,send_to_platform=false,read_moving_from=false,read_moving_to=false,read_speed=false,read_damage_taken=false})
local hub=thing('space-platform-hub','space-platform-hub',0,hub_cb,0,psurf)
local fast_cb=cb_of('inserter',{circuit_enable_disable=false,connect_to_logistic_network=false,circuit_read_hand_contents=false})
local fast=thing('fast-inserter','inserter',-2.5,fast_cb,-4.5,psurf)
local far_fast=thing('fast-inserter','inserter',-12.5,cb_of('inserter'),-2.5,psurf)
local thruster=thing('thruster','thruster',0,nil,20,psurf); thruster.no_wires=true
r=astra('circuit_set',{platform='Sunward',position={x=-2.5,y=-4.5},enable='ice < 300'})
eq(r.by,'remote view'); eq(fast_cb.circuit_enable_disable,true); eq(fast_cb.circuit_condition.constant,300); eq(r.circuit.enable,'ice < 300')
r=astra('wire',{platform='Sunward',from={x=0,y=0},to={x=-2.5,y=-4.5},color='red'})
eq(r.connected,true); eq(r.by,'remote view'); eq(r.from.entity,'space-platform-hub')
fails(function() astra('wire',{platform='Sunward',from={x=0,y=0},to={x=-12.5,y=-2.5},color='red'}) end,'12.7 tiles apart, the wire reaches 9')
r=astra('circuit_set',{platform='Sunward',position={x=0,y=0},read={contents=true},settings={send_to_platform=true,speed_signal='signal-S'}})
eq(hub_cb.read_contents,true); eq(hub_cb.send_to_platform,true); eq(hub_cb.speed_signal.name,'signal-S')
eq(r.circuit.settings.read_contents,true); eq(r.circuit.settings.speed_signal,'signal-S'); eq(r.circuit.wires.red[1].entity,'fast-inserter')
fails(function() astra('circuit_set',{platform='Sunward',position={x=0,y=0},enable='ice < 1'}) end,
  'enable: space-platform-hub has no enable condition (its circuit settings: damage_taken_signal, read_contents, read_damage_taken, read_moving_from')
fails(function() astra('circuit_set',{platform='Sunward',position={x=0,y=0},settings={open_gate=true}}) end,'open_gate is not a circuit setting of space-platform-hub')
fails(function() astra('circuit_set',{platform='Sunward',position={x=0,y=20},enable='ice < 1'}) end,'thruster has no circuit connection')
fails(function() astra('wire',{platform='Sunward',from={x=0,y=0},to={x=0,y=20},color='green'}) end,'thruster takes no green circuit wire')
-- inspect on the platform: the condition, whether it holds, the hub at the far end, the hub's contents on the network.
fast_cb.circuit_condition.fulfilled=true; fast_cb.disabled=false
fast.signals_now={[1]={{signal={name='ice'},count=250},{signal={name='carbon'},count=40}}}
ins=astra('inspect',{platform='Sunward',position={x=-2.5,y=-4.5}})
eq(ins.circuit.enable,'ice < 300'); eq(ins.circuit.enable_met,true); eq(ins.circuit.wires.red[1].entity,'space-platform-hub')
eq(ins.circuit.wires.red[1].position.x,0); eq(ins.circuit.networks.red.signals[1].name,'ice'); eq(ins.circuit.networks.red.signals[2].count,40)
-- The same platform by surface name; a planet by name (remote view, visible chunks); an unknown name.
eq(astra('inspect',{surface='platform-1',position={x=-2.5,y=-4.5}}).circuit.enable,'ice < 300')
eq(astra('inspect',{surface='Sunward',position={x=-2.5,y=-4.5}}).name,'fast-inserter')
local vins_cb=cb_of('inserter',{circuit_enable_disable=false})
thing('inserter','inserter',1,vins_cb,1,vsurf)
r=astra('circuit_set',{surface='vulcanus',position={x=1,y=1},enable='iron-plate < 5'})
eq(r.by,'remote view'); eq(vins_cb.circuit_condition.constant,5)
-- A read on another surface is by remote view too.
eq(astra('inspect',{surface='vulcanus',position={x=1,y=1}}).by,'remote view')
hidden['vulcanus 0,0']=true
fails(function() astra('circuit_set',{surface='vulcanus',position={x=1,y=1},enable='iron-plate < 6'}) end,'not in a visible chunk')
eq(astra('inspect',{surface='vulcanus',position={x=1,y=1}}).by,'last seen memory')
eq(astra('inspect',{surface='vulcanus',position={x=1,y=1}}).by,'last seen memory')
hidden['vulcanus 0,0']=nil
fails(function() astra('circuit_set',{surface='mars',position={x=1,y=1},enable='iron-plate < 6'}) end,'no surface named mars; planets and surfaces: nauvis, vulcanus')
fails(function() astra('circuit_set',{surface='vulcanus',platform='Sunward',position={x=1,y=1}}) end,'give platform or surface, not both')

-- A bot aboard the platform (no body, remote view only): inspect, circuit_set and wire with platform=.
local b=runtime.bots.record(runtime.bots.index_of('sol'))
local body=b.character
b.character=nil; b.travel={state='aboard',platform='Sunward',since=0}; b.surface='platform-1'
r=sol('circuit_set',{platform='Sunward',position={x=-2.5,y=-4.5},enable='ice < 250'})
eq(r.by,'remote view'); eq(fast_cb.circuit_condition.constant,250)
eq(sol('inspect',{platform='Sunward',position={x=-2.5,y=-4.5}}).in_reach,false)
eq(sol('wire',{platform='Sunward',from={x=0,y=0},to={x=-2.5,y=-4.5},color='red'}).already,true)
fails(function() sol('circuit_set',{position={x=-2.5,y=-4.5},enable='ice < 1'}) end,'aboard platform Sunward with no body')
b.character=body; b.travel=nil; b.surface='nauvis'

-- Trains: a stop's name and limit; a train's schedule and automatic mode.
local stop=thing('train-stop','train-stop',12,nil); stop.backer_name='Unnamed'; stop.trains_count=0
r=astra('train',{position={x=12,y=0},station='Iron pickup',limit=2})
eq(stop.backer_name,'Iron pickup'); eq(stop.trains_limit,2); eq(r.stop,'Iron pickup'); eq(r.limit,2)
-- `name` is no stop name (every target reads it as an entity name): refused.
fails(function() astra('train',{position={x=12,y=0},name='LC-East'}) end,'unknown argument name')
eq(stop.backer_name,'Iron pickup')
local train={valid=true,manual_mode=true,state=0}
local loco=thing('locomotive','locomotive',14,nil); loco.train=train
r=astra('train',{position={x=14,y=0},schedule={{station='Iron pickup',wait={{type='full'}}},{station='Smelting drop',wait={{type='empty'},{type='time',ticks=600,compare='or'}}}},automatic=true})
eq(train.manual_mode,false); eq(#train.schedule.records,2); eq(train.schedule.current,1)
eq(train.schedule.records[2].wait_conditions[2].compare_type,'or'); eq(train.schedule.records[2].wait_conditions[2].ticks,600)
eq(r.automatic,true); eq(r.schedule[1],'Iron pickup: full'); eq(r.schedule[2],'Smelting drop: empty or time 10s') -- and/or as the GUI shows them
r=astra('train',{position={x=14,y=0},schedule={}}); eq(train.schedule,nil); eq(#r.schedule,0)
fails(function() astra('train',{position={x=14,y=0},schedule={{station='X',wait={{type='forever'}}}}}) end,'type is time')
fails(function() astra('train',{position={x=14,y=0},station='x'}) end,'station and limit are for a train stop')
fails(function() astra('train',{position={x=12,y=0},automatic=true}) end,'are for a train')
fails(function() astra('train',{position={x=2,y=0},automatic=true}) end,'neither a train stop nor part of a train')
-- A game whose train takes only LuaSchedule edits: the fallback path.
local recs={}
local sched={}
sched.get_record_count=function() return #recs end
sched.remove_record=function() table.remove(recs,1) end
sched.add_record=function(r2) recs[#recs+1]=r2 end
sched.go_to_station=function(i) sched.at=i end
local train2=setmetatable({valid=true,manual_mode=true,get_schedule=function() return sched end},
  {__newindex=function(t,k,v) if k=='schedule' then error('read only') end rawset(t,k,v) end})
local loco2=thing('locomotive','locomotive',16,nil); loco2.train=train2
astra('train',{position={x=16,y=0},schedule={{station='A'},{station='B'}},current=2})
eq(#recs,2); eq(recs[2].station,'B'); eq(sched.at,2)
print('circuits and trains: ok')
