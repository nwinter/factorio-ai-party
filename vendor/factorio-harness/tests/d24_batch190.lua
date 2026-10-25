-- Run from the harness root: lua tests/d24_batch190.lua
-- d24 batch190 QAF1 (operator 19:56): reminders {id: 151} read as Sol by reader "operator" without peek took 28.2 ms on
-- world n, the same read as a peek 0.84 ms: a reader request ran the agent's whole reply wrapper (its team block, whose
-- platform alerts took 15 of 24 ms on a copy after a deploy), reset the agent's call clock and took the agent's tells,
-- alerts and news. A reader's read is now a peek: the agent's team block, clock and chat stay its own.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
prototypes={item={['submachine-gun']={type='gun',attack_parameters={ammo_categories={'bullet'},range=18}},
  ['rocket-launcher']={type='gun',attack_parameters={ammo_categories={'rocket'},range=36}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}},
  ['iron-plate']={type='item'}}}
local drawn={}
rendering={draw_text=function() local obj={valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,
  is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},selected_gun_index=1}
  c.insert=function(s) return s.count end
  c.get_item_count=function() return 0 end
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
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    if req.bot then pcall(runtime.stop_player,runtime.bots.index_of(req.bot)) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local seq=0
local function req(name,action,args,extra)
  seq=seq+1
  local r={id='req-'..seq,action=action,args=args or {},bot=name}
  for k,v in pairs(extra or {}) do r[k]=v end
  return request(r)
end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol')
local function clock() return (storage.agent_harness.clocks or {})[runtime.bots.index_of('astra')] end
req('astra','status',{}); advance(60)
local before=clock().call_tick
local id=req('sol','reminder_add',{message='check the east wall',every_ticks=36000,recipients='astra'}).added
req('sol','tell',{to='astra',text='the east wall needs walls'})
advance(60)
-- the operator's read as astra (reader, no peek): the reminders, none of astra's team block, her clock left alone
local r=req('astra','reminders',{},{reader='operator'})
eq(r.count,1); eq(r.team,nil,'astra\'s tells and alerts stay hers'); eq(r.operator,nil)
eq(clock().call_tick,before,'a reader\'s read is not astra\'s call')
r=req('astra','reminders',{id=id},{reader='stream'})
eq(r.reminders[1].id,id); has(r.lines[1],'check the east wall'); eq(r.team,nil)
eq(clock().call_tick,before)
-- astra's own read: the tell is hers to read
r=req('astra','reminders',{id=id})
has(table.concat(r.team and r.team.tells or {},' | '),'the east wall needs walls')
assert(clock().call_tick>before)
print('d24_batch190 QAF1 a reader\'s read is a peek: the agent\'s team block, clock and tells stay its own: ok')
