-- Run from repository root: lua tests/circuits.lua
-- Circuit wires and settings (circuits.lua) and train stops and schedules
-- (trains.lua), through the runtime against a fake engine.
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


-- Fakes: signal prototypes, entities by position, control behaviours and wire connectors.
prototypes=prototypes or {}
prototypes.item=prototypes.item or {}
prototypes.item['iron-plate']=prototypes.item['iron-plate'] or {name='iron-plate',type='item'}
prototypes.fluid={water={name='water'}}
prototypes.virtual_signal={['signal-A']={name='signal-A'}}
defines.wire_connector_id={circuit_red=1,circuit_green=2,combinator_input_red=1,combinator_input_green=2,combinator_output_red=3,combinator_output_green=4,pole_copper=5}
local world={}
local function connectors(e)
  local made={}
  e.get_wire_connector=function(id,create)
    if e.no_wires then error('no circuit connection') end
    if not made[id] then
      local c={id=id,owner=e,links={}}
      c.is_connected_to=function(o) return c.links[o]==true end
      c.can_wire_reach=function(o) return math.abs(o.owner.position.x-e.position.x)<=9 end
      c.connect_to=function(o) c.links[o]=true; o.links[c]=true; return true end
      c.disconnect_from=function(o) local was=c.links[o]==true; c.links[o]=nil; o.links[c]=nil; return was end
      made[id]=c
    end
    return made[id]
  end
  return made
end
local function thing(name,type_,x,cb)
  local e={valid=true,name=name,type=type_,position={x=x,y=0},force=force}
  e.wires=connectors(e)
  e.get_or_create_control_behavior=function() return cb end
  world[#world+1]=e
  return e
end
surface.find_entities_filtered=function(f)
  local out={}
  if f.position then for _,e in ipairs(world) do if e.valid and math.abs(e.position.x-f.position.x)<0.3 and math.abs(e.position.y-f.position.y)<0.3 then out[#out+1]=e end end end
  return out
end
local inserter_cb={}
local inserter=thing('inserter','inserter',2,inserter_cb)
local section={filters={}}
local const_cb={enabled=true,sections_count=0}
const_cb.add_section=function() const_cb.sections_count=1; return section end
const_cb.get_section=function(i) assert(i==1); return section end
local const=thing('constant-combinator','constant-combinator',4,const_cb)
local arith_cb={}
local arith=thing('arithmetic-combinator','arithmetic-combinator',6,arith_cb)
local decider_cb={}
local decider=thing('decider-combinator','decider-combinator',8,decider_cb)
local chest=thing('iron-chest','container',10,nil)

-- An enable condition on an inserter, a logistic condition, then off again.
local r=astra('circuit',{position={x=2,y=0},enable={signal='iron-plate',comparator='<',value=100}})
eq(inserter_cb.circuit_enable_disable,true); eq(inserter_cb.circuit_condition.first_signal.name,'iron-plate')
eq(inserter_cb.circuit_condition.first_signal.type,'item'); eq(inserter_cb.circuit_condition.constant,100); eq(r.enable,'iron-plate < 100')
r=astra('circuit',{position={x=2,y=0},logistic={signal='water',comparator='>=',signal2='signal-A'}})
eq(inserter_cb.connect_to_logistic_network,true); eq(inserter_cb.logistic_condition.first_signal.type,'fluid')
eq(inserter_cb.logistic_condition.second_signal.type,'virtual'); eq(r.logistic,'water >= signal-A')
astra('circuit',{position={x=2,y=0},enable=false}); eq(inserter_cb.circuit_enable_disable,false)
fails(function() astra('circuit',{position={x=2,y=0},enable={signal='unobtainium',value=1}}) end,'unknown signal unobtainium')
fails(function() astra('circuit',{position={x=2,y=0},enable={signal='iron-plate',comparator='~',value=1}}) end,'comparator is one of')
fails(function() astra('circuit',{position={x=2,y=0},enable={signal='iron-plate'}}) end,'value (a number) or signal2 is required')
fails(function() astra('circuit',{position={x=10,y=0},enable={signal='iron-plate',value=1}}) end,'iron-chest has no circuit connection')
fails(function() astra('circuit',{position={x=2,y=0},signals={}}) end,'for a constant combinator')
-- A constant combinator's signals and switch.
r=astra('circuit',{position={x=4,y=0},signals={{signal='iron-plate',count=50},{signal='signal-A',count=1}},on=false})
eq(#section.filters,2); eq(section.filters[1].value.name,'iron-plate'); eq(section.filters[1].min,50); eq(section.filters[2].value.type,'virtual')
eq(const_cb.enabled,false); eq(r.on,false); eq(r.signals[1].signal,'iron-plate'); eq(r.signals[1].count,50)
-- Arithmetic and decider parameters.
astra('circuit',{position={x=6,y=0},arithmetic={first='iron-plate',operation='/',constant=10,output='signal-A'}})
eq(arith_cb.parameters.operation,'/'); eq(arith_cb.parameters.second_constant,10); eq(arith_cb.parameters.output_signal.name,'signal-A')
fails(function() astra('circuit',{position={x=6,y=0},arithmetic={first='iron-plate',operation='sqrt',constant=1,output='signal-A'}}) end,'operation is one of')
astra('circuit',{position={x=8,y=0},decider={first='signal-A',comparator='>',constant=5,output='iron-plate',copy_input=true}})
eq(decider_cb.parameters.conditions[1].comparator,'>'); eq(decider_cb.parameters.conditions[1].constant,5)
eq(decider_cb.parameters.outputs[1].signal.name,'iron-plate'); eq(decider_cb.parameters.outputs[1].copy_count_from_input,true)
-- Read switches by entity type.
r=astra('circuit',{position={x=2,y=0},read={hand=true}})
eq(inserter_cb.circuit_read_hand_contents,true); eq(r.read.hand,true)
fails(function() astra('circuit',{position={x=2,y=0},read={contents=true}}) end,'read: contents is not a switch of inserter (hand)')
fails(function() astra('circuit',{position={x=4,y=0},read={hand=true}}) end,'has no read switches here')
-- A refusal from the game comes back as a plain error.
setmetatable(arith_cb,{__newindex=function() error('invalid parameters') end}); arith_cb.parameters=nil
fails(function() astra('circuit',{position={x=6,y=0},arithmetic={first='iron-plate',constant=2,output='signal-A'}}) end,'arithmetic: ')

-- Red and green wires: combinator sides default output -> input.
r=astra('wire',{from={x=4,y=0},to={x=6,y=0},color='red'})
eq(r.connected,true); eq(r.color,'red')
local out_c=const.wires[defines.wire_connector_id.circuit_red]; local in_c=arith.wires[defines.wire_connector_id.combinator_input_red]
eq(out_c.links[in_c],true)
eq(astra('wire',{from={x=4,y=0},to={x=6,y=0},color='red'}).already,true)
astra('wire',{from={x=6,y=0},to={x=8,y=0},color='green',from_side='output',to_side='input'})
eq(arith.wires[defines.wire_connector_id.combinator_output_green].links[decider.wires[defines.wire_connector_id.combinator_input_green]],true)
eq(astra('wire',{from={x=4,y=0},to={x=6,y=0},color='red',disconnect=true}).disconnected,true)
fails(function() astra('wire',{from={x=2,y=0},to={x=4,y=0},color='blue'}) end,'color is red or green')
fails(function() astra('wire',{from={x=2,y=0},to={x=4,y=0},color='red',from_side='input'}) end,'from_side applies to combinators only')
chest.no_wires=true
fails(function() astra('wire',{from={x=2,y=0},to={x=10,y=0},color='red'}) end,'iron-chest takes no red circuit wire')
local far=thing('small-lamp','lamp',30,{})
fails(function() astra('wire',{from={x=2,y=0},to={x=30,y=0},color='green'}) end,'does not reach')

-- Trains: a stop's name and limit; a train's schedule and automatic mode.
local stop=thing('train-stop','train-stop',12,nil); stop.backer_name='Unnamed'; stop.trains_count=0
r=astra('train',{position={x=12,y=0},name='Iron pickup',limit=2})
eq(stop.backer_name,'Iron pickup'); eq(stop.trains_limit,2); eq(r.stop,'Iron pickup'); eq(r.limit,2)
local train={valid=true,manual_mode=true,state=0}
local loco=thing('locomotive','locomotive',14,nil); loco.train=train
r=astra('train',{position={x=14,y=0},schedule={{station='Iron pickup',wait={{type='full'}}},{station='Smelting drop',wait={{type='empty'},{type='time',ticks=600,compare='or'}}}},automatic=true})
eq(train.manual_mode,false); eq(#train.schedule.records,2); eq(train.schedule.current,1)
eq(train.schedule.records[2].wait_conditions[2].compare_type,'or'); eq(train.schedule.records[2].wait_conditions[2].ticks,600)
eq(r.automatic,true); eq(r.schedule[1],'Iron pickup: full'); eq(r.schedule[2],'Smelting drop: empty, time 10s')
r=astra('train',{position={x=14,y=0},schedule={}}); eq(train.schedule,nil); eq(#r.schedule,0)
fails(function() astra('train',{position={x=14,y=0},schedule={{station='X',wait={{type='forever'}}}}}) end,'type is time')
fails(function() astra('train',{position={x=14,y=0},name='x'}) end,'name and limit are for a train stop')
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
