-- Run from repository root: lua tests/deploykeep.lua
-- A hot runtime install carries waits, queues and standing orders over
-- (carry.lua): control.lua has the outgoing runtime stop_all, the incoming one
-- puts back what ran; a step or direct action that moves or builds starts again.
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
local names={'astra','sol','grok','muse','luna','haiku','opus','sonnet','gemini','walker','mover','oldmover','sleeper','done'}
local bot={}
for _,name in ipairs(names) do runtime.operator.bot_create(name); bot[name]=as(name) end
local function index(name) return runtime.bots.index_of(name) end
-- As control.lua's install_source: compile the new runtime (game present), the old one stops everything, swap.
local function install(loading)
  local saved=game
  if loading then game=nil end -- on_load: no game while the chunk runs
  local candidate=dofile(RUNTIME)
  game=saved
  assert(pcall(runtime.stop_all))
  runtime=candidate
end
local function brief(name) return bot[name]('status',{brief=true,peek=true}) end
local function notes(name) local r=bot[name]('status',{brief=true}); return r.team and r.team.harness_updated end

-- gemini: a standing order (a courier routine), running once the character has been free for its hold.
bot.gemini('order_set',{name='courier',steps={{action='wait_ticks',args={ticks=6000}},{action='wait_ticks',args={ticks=60}}}})
advance(1320)
local q=bot.gemini('queue_status')
eq(q.order and q.order.name,'courier','gemini order'); eq(q.active.action,'wait_ticks')
local gemini_until=q.active.until_tick

-- Queues: astra a wait_until on a chest; sol a wait_ticks; grok a move_to (moves) with a step after it;
-- muse a walk step; opus a repeating courier loop in its move_to; sonnet a repeating plan resting between cycles.
-- Direct: luna a wait_until (her research waits), haiku a wait_ticks 9000 (his --wait cycle), walker a walk,
-- mover a move_to, oldmover a move_to an older runtime started (no call kept), sleeper an fh sleep over its queue;
-- done a queue that finished before (left unpaused and empty).
chest_items['iron-plate']=10
bot.astra('queue_submit',{steps={{action='wait_until',args={['until']='item_count',item='iron-plate',at_least=100,positions={{x=3,y=3}},timeout=18000}},
  {action='wait_ticks',args={ticks=30}}}})
bot.sol('queue_submit',{steps={{action='wait_ticks',args={ticks=600}},{action='wait_ticks',args={ticks=60}}}})
bot.grok('queue_submit',{steps={{action='move_to',args={position={x=100,y=100}}},{action='wait_ticks',args={ticks=60}}}})
bot.muse('queue_submit',{steps={{action='walk',args={direction='east',ticks=600}},{action='wait_ticks',args={ticks=60}}}})
bot.opus('queue_repeat',{name='courier',interval_ticks=60,steps={{action='move_to',args={position={x=100,y=-100}}},{action='wait_ticks',args={ticks=60}}}})
bot.sonnet('queue_repeat',{interval_ticks=36000,steps={{action='wait_ticks',args={ticks=1}}}})
bot.luna('wait_until',{['until']='item_count',item='iron-plate',at_least=200,positions={{x=3,y=3}},timeout=18000})
bot.haiku('wait_ticks',{ticks=9000})
bot.walker('walk',{direction='east',ticks=600})
bot.mover('move_to',{position={x=-100,y=100}})
bot.oldmover('move_to',{position={x=-100,y=-100}})
storage.agent_harness.active[index('oldmover')].call=nil
bot.sleeper('queue_submit',{steps={{action='wait_ticks',args={ticks=600}}}})
bot.done('queue_submit',{steps={{action='wait_ticks',args={ticks=1}}}})
advance(5)
local sleep=bot.sleeper('sleep',{seconds=60})
assert(sleep.wakes_on:find('your queue finishing',1,true),sleep.wakes_on)
advance(5)
local before={}
for _,name in ipairs{'astra','sol','gemini'} do before[name]=bot[name]('queue_status',{peek=true}).active.until_tick end
for _,name in ipairs{'luna','haiku','walker'} do before[name]=brief(name).active.until_tick end
eq(before.gemini,gemini_until)
local opus_q=bot.opus('queue_status',{peek=true}); eq(opus_q.active.action,'move_to'); local opus_cycle=opus_q.cycle
local sonnet_q=bot.sonnet('queue_status',{peek=true}); eq(sonnet_q.active,false); assert(sonnet_q.next_cycle_tick,'sonnet resting')
eq(bot.grok('queue_status',{peek=true}).active.action,'move_to'); eq(bot.muse('queue_status',{peek=true}).active.action,'walk')
eq(brief('mover').active.kind,'move_to'); eq(brief('oldmover').active.kind,'move_to')
local at=tick

install()
-- The first request after the install already sees everything as it was.
q=bot.astra('queue_status',{peek=true})
eq(q.paused,false); eq(q.active.action,'wait_until'); eq(q.active.until_tick,before.astra); eq(#q.pending,1)
for _,h in ipairs(q.history) do assert(h.ok~=false,'astra history: '..tostring(h.action)) end
local b=brief('luna')
eq(b.active.kind,'wait_until','luna'); eq(b.active.until_tick,before.luna); assert(not (b.last and b.last.outcome=='interrupted'),'luna last')
b=brief('haiku')
eq(b.active.kind,'wait_ticks','haiku'); eq(b.active.until_tick,before.haiku); eq(b.last,false)
advance(1)
-- Waits keep their own clocks.
q=bot.sol('queue_status',{peek=true}); eq(q.paused,false); eq(q.active.action,'wait_ticks'); eq(q.active.until_tick,before.sol)
b=brief('walker'); eq(b.active.kind,'walk'); eq(b.active.until_tick,before.walker)
q=bot.muse('queue_status',{peek=true}); eq(q.paused,false); eq(q.active.action,'walk'); eq(#q.pending,1)
-- The standing order runs on, the same run.
q=bot.gemini('queue_status',{peek=true}); eq(q.paused,false); eq(q.order and q.order.name,'courier'); eq(q.active.until_tick,gemini_until)
-- The repeating plans: opus's cycle starts its move_to again, sonnet's rest is untouched.
q=bot.opus('queue_status',{peek=true}); eq(q.paused,false); eq(q.repeating,true); eq(q.cycle,opus_cycle); eq(q.active.action,'move_to')
q=bot.sonnet('queue_status',{peek=true}); eq(q.paused,false); eq(q.next_cycle_tick,sonnet_q.next_cycle_tick)
-- grok's move_to starts again from the head of the queue.
q=bot.grok('queue_status',{peek=true}); eq(q.paused,false); eq(q.active.action,'move_to'); eq(q.active.id,'job-1'); eq(#q.pending,1)
-- mover's direct move_to started again from its call; oldmover's could not be.
b=brief('mover'); eq(b.active.kind,'move_to'); eq(b.active.to.x,-100)
eq(brief('oldmover').active,false)
-- The sleep over sleeper's queue goes on.
eq(bot.sleeper('sleep_check',{peek=true}).woke,nil)

-- One line each in the next reply (a peek leaves it there).
eq(bot.astra('status',{brief=true,peek=true}).team,nil)
local carried='harness updated at tick '..at..' (your wait/queue carried over)'
for _,name in ipairs{'astra','sol','muse','gemini','luna','haiku','walker','sleeper'} do
  local n=notes(name)
  eq(n and #n,1,name..' notes'); eq(n[1],carried,name)
end
eq(notes('astra'),nil)
eq(notes('sonnet'),nil) -- nothing of its was running
eq(notes('done'),nil)
q=bot.done('queue_status',{peek=true}); eq(q.paused,false); eq(#q.history,1)
eq(notes('grok')[1],'harness updated at tick '..at..': your queue step move_to (job-1) was interrupted by a harness update; resumed')
eq(notes('opus')[1],'harness updated at tick '..at..': your queue step move_to (job-'..opus_q.active.id:match('%d+')..') was interrupted by a harness update; resumed')
eq(notes('mover')[1],'harness updated at tick '..at..': your move_to was interrupted by a harness update; resumed')
eq(notes('oldmover')[1],'harness updated at tick '..at..': your move_to was interrupted by a harness update; start it again if it is still needed')
eq(brief('oldmover').last.outcome,'interrupted')

-- The carried waits finish as they would have.
chest_items['iron-plate']=100
advance(11)
q=bot.astra('queue_status'); eq(q.history[#q.history].action,'wait_until'); eq(q.history[#q.history].ok,true)
chest_items['iron-plate']=200
advance(11)
b=brief('luna'); eq(b.active,false); eq(b.last.kind,'wait_until'); eq(b.last.outcome,'met')
advance(before.sol-tick)
q=bot.sol('queue_status'); eq(q.history[1].ok,true); eq(q.history[1].finished_tick,before.sol)
advance(before.walker-tick+1)
b=brief('walker'); eq(b.last.kind,'walk'); eq(b.last.outcome,'duration_elapsed')
advance(before.haiku-tick+1)
b=brief('haiku'); eq(b.last.kind,'wait_ticks'); eq(b.last.outcome,'duration_elapsed'); eq(b.last.tick,before.haiku+1)

-- A second install carries the restarted move_to again (it keeps its call).
bot.mover('move_to',{position={x=-50,y=50}}); advance(2); at=tick
install()
b=brief('mover'); eq(b.active.kind,'move_to'); eq(b.active.to.x,-50)
eq(notes('mover')[1],'harness updated at tick '..at..': your move_to was interrupted by a harness update; resumed')

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
