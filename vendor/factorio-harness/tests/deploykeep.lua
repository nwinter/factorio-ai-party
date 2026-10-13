-- Run from repository root: lua tests/deploykeep.lua
-- A hot runtime install carries running queues over (carry.lua): control.lua
-- has the outgoing runtime stop_all, the incoming one undoes the pause.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4},inventory={chest=1},
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
  c.prototype={collision_mask={layers={player=true}}}
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
prototypes={item={['iron-plate']={name='iron-plate'}}}
local chest_items={}
local chest={valid=true,name='wooden-chest',get_item_count=function(n) return chest_items[n] or 0 end}
surface.find_entities_filtered=function(f)
  if f.position and f.radius==0.3 and f.position.x==3 and f.position.y==3 then return {chest} end
  return {}
end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local players={nick}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local RUNTIME='mod/agent-harness_0.1.0/runtime.lua'
local runtime=dofile(RUNTIME)
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
-- As control.lua does: a failed request stops its player unless the runtime marked it passive.
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.bot and runtime.bots.index_of(req.bot) or req.player
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local names={'astra','sol','grok','muse','luna'}
local bot={}
for _,name in ipairs(names) do runtime.operator.bot_create(name); bot[name]=as(name) end
-- As control.lua's install_source: compile the new runtime (game present), the old one stops everything, swap.
local function install(loading)
  local saved=game
  if loading then game=nil end -- on_load: no game while the chunk runs
  local candidate=dofile(RUNTIME)
  game=saved
  assert(pcall(runtime.stop_all))
  runtime=candidate
end

-- astra: a queue waiting on a chest; sol: a wait_ticks step; grok: a move_to
-- step (restartable) with a step after it; muse: a walk step (not restartable);
-- luna: a direct walk, no queue.
chest_items['iron-plate']=10
bot.astra('queue_submit',{steps={{action='wait_until',args={['until']='item_count',item='iron-plate',at_least=100,positions={{x=3,y=3}},timeout=18000}},
  {action='wait_ticks',args={ticks=30}}}})
bot.sol('queue_submit',{steps={{action='wait_ticks',args={ticks=600}},{action='wait_ticks',args={ticks=60}}}})
bot.grok('queue_submit',{steps={{action='move_to',args={position={x=100,y=100}}},{action='wait_ticks',args={ticks=60}}}})
bot.muse('queue_submit',{steps={{action='walk',args={direction='east',ticks=600}},{action='wait_ticks',args={ticks=60}}}})
bot.luna('walk',{direction='east',ticks=600})
advance(5)
local astra_until=bot.astra('queue_status').active.until_tick
local sol_until=bot.sol('queue_status').active.until_tick
eq(bot.grok('queue_status').active.action,'move_to'); eq(bot.muse('queue_status').active.action,'walk')

install()
eq(bot.astra('queue_status',{peek=true}).paused,false) -- carried by the first request
advance(1)
-- The waits keep their own clocks, with no interruption in the history.
local q=bot.astra('queue_status')
eq(q.paused,false); eq(q.active.action,'wait_until'); eq(q.active.until_tick,astra_until); eq(#q.pending,1)
for _,h in ipairs(q.history) do assert(h.ok~=false,'astra history: '..tostring(h.action)) end
q=bot.sol('queue_status')
eq(q.paused,false); eq(q.active.action,'wait_ticks'); eq(q.active.until_tick,sol_until)
-- Nothing of theirs was cut: no note.
local r=bot.astra('status',{brief=true})
eq(r.team and r.team.harness_updated,nil)
-- grok's move_to starts again; it is told once.
q=bot.grok('queue_status',{peek=true})
eq(q.paused,false); eq(q.active.action,'move_to'); eq(#q.pending,1)
r=bot.grok('status',{brief=true,peek=true})
eq(r.team,nil) -- a peek leaves the note for the reply the agent sees
r=bot.grok('status',{brief=true})
assert(has(r.team.harness_updated,'your queue step move_to (job-1) was interrupted and starts again'),r.team.harness_updated[1])
r=bot.grok('status',{brief=true})
eq(r.team and r.team.harness_updated,nil)
-- muse's walk does not restart: the queue waits, and says how to go on.
q=bot.muse('queue_status',{peek=true})
eq(q.paused,true); eq(#q.pending,1)
r=bot.muse('status',{brief=true})
assert(has(r.team.harness_updated,'paused with 1 steps pending: fh queue resume continues with the next one'),r.team.harness_updated[1])
-- luna's direct walk was cut.
r=bot.luna('status',{brief=true})
assert(has(r.team.harness_updated,'your walk was interrupted'),r.team.harness_updated[1])
-- The carried steps finish as they would have.
chest_items['iron-plate']=100
advance(11)
q=bot.astra('queue_status'); eq(q.history[#q.history].action,'wait_until'); eq(q.history[#q.history].ok,true)
advance(sol_until-tick)
q=bot.sol('queue_status'); eq(q.history[1].ok,true); eq(q.history[1].finished_tick,sol_until)

-- A load from a save (on_load: no game while the runtime loads) carries nothing.
bot.astra('queue_submit',{steps={{action='wait_ticks',args={ticks=600}}}}); advance(2)
install(true)
advance(1)
eq(bot.astra('queue_status').paused,true)
bot.astra('queue_resume',{}); advance(2)
-- A stop without a new runtime (a tick fault) pauses as before.
assert(pcall(runtime.stop_all)); advance(1)
eq(bot.astra('queue_status').paused,true)
print('deploykeep: ok')
