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
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4},inventory={chest=1,character_ammo=4},
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
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,
    get_contents=function() return {} end}
  -- A repair pack held from the inventory and put back (repair's borrowed cursor).
  inv.find_item_stack=function(name)
    if (items[name] or 0)>0 then return {name=name,count=items[name],prototype={type=name=='repair-pack' and 'repair-tool' or 'item',speed=2}} end
  end
  inv.insert=function(st) items[st.name]=(items[st.name] or 0)+st.count; return st.count end
  local held={valid_for_read=false}
  held.swap_stack=function(st)
    items[st.name]=(items[st.name] or 0)-st.count
    held.valid_for_read=true; held.name=st.name; held.count=st.count; held.prototype=st.prototype; held.durability=1000
    return true
  end
  held.clear=function() held.valid_for_read=false; held.name=nil; held.count=nil; held.prototype=nil end
  held.drain_durability=function() end
  c.cursor_stack=held
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.can_insert=function() return true end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  -- An entity marked far is out of reach (a walk to it never gets a path here: request_path never answers).
  c.can_reach_entity=function(e) return not (e and e.far) end
  -- Hand mining one unit of ore.
  c.mine_entity=function(e) e.amount=e.amount-1; items[e.name]=(items[e.name] or 0)+1; return false end
  c.get_inventory=function(id) if id==defines.inventory.character_ammo then return {get_item_count=function() return 10 end} end end
  c.destroy=function() c.valid=false end
  c.prototype={collision_mask={layers={player=true}}}
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
prototypes={item={['iron-plate']={name='iron-plate'},['iron-gear-wheel']={name='iron-gear-wheel'}}}
local chest_items={}
local chest={valid=true,name='wooden-chest',get_item_count=function(n) return chest_items[n] or 0 end}
local machines={}
surface.find_entities_filtered=function(f)
  if f.position and f.radius==0.3 and f.position.x==3 and f.position.y==3 then return {chest} end
  if f.position and f.radius==0.2 then
    for _,m in ipairs(machines) do if m.position.x==f.position.x and m.position.y==f.position.y then return {m} end end
  end
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
local names={'astra','sol','grok','muse','luna','haiku','opus','sonnet','gemini','walker','mover','oldmover','sleeper','done',
  'collector','waiter','courier','qcollect','miner','picker','repairer','shooter','viawalker','broken','brokenend','dropper'}
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
-- sol's history is full (64 rows, the scheduler's cap): the update leaves every row of it.
local solq=storage.agent_harness.queues[index('sol')]
for k=1,64 do solq.history[k]={id='old-'..k,action='wait_ticks',ok=true,finished_tick=k} end
local sol_first=solq.history[1]
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
eq(#solq.history,64); eq(solq.history[1],sol_first); eq(solq.history[64].id,'old-64')
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
local carried={astra='queue',sol='queue',muse='queue',gemini='queue',sleeper='queue',luna='wait_until',haiku='wait_ticks',walker='walk'}
for name,what in pairs(carried) do
  local n=notes(name)
  eq(n and #n,1,name..' notes'); eq(n[1],'harness updated at tick '..at..' (your '..what..' carried over)',name)
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
q=bot.sol('queue_status'); eq(q.history[#q.history].ok,true); eq(q.history[#q.history].finished_tick,before.sol)
advance(before.walker-tick+1)
b=brief('walker'); eq(b.last.kind,'walk'); eq(b.last.outcome,'duration_elapsed')
advance(before.haiku-tick+1)
b=brief('haiku'); eq(b.last.kind,'wait_ticks'); eq(b.last.outcome,'duration_elapsed'); eq(b.last.tick,before.haiku+1)

-- A second install carries the restarted move_to again (it keeps its call).
bot.mover('move_to',{position={x=-50,y=50}}); advance(2); at=tick
install()
b=brief('mover'); eq(b.active.kind,'move_to'); eq(b.active.to.x,-50)
eq(notes('mover')[1],'harness updated at tick '..at..': your move_to was interrupted by a harness update; resumed')

-- Timed collect and gather, their walking tours, mine, pickup, repair and a shoot on foot carry over as they were (Sol
-- 12:46: a deploy restarted a timed collect and its --wait ended wait_timeout): until_tick, what was got so far and the
-- target count stay, and each ends when and as it would have. A direct move_to starts again by the deadline it had, from
-- the first via point it had not reached. Direct actions are set up as the runtime before the deploy left them, with
-- the call it kept (it restarted them from that).
local function far(name,x,y) return {valid=true,name=name,type='container',position={x=x,y=y},far=true,force=force,surface=surface} end
local function put(name,action) storage.agent_harness.active[index(name)]=action; return action end
local function call(action,args) return {action=action,args=args} end
local near={valid=true,name='iron-chest',type='container',position={x=3.5,y=3.5},force=force,surface=surface}
-- collect over a radius: 20 of 50 got at the first of two places, walking to the second.
local collect=put('collector',{kind='gather',item='iron-plate',want=50,got=20,visited=1,touched=1,
  targets={{entity=near,position=near.position},{entity=far('iron-chest',40.5,40.5),position={x=40.5,y=40.5}}},
  index=2,until_tick=tick+600,call=call('collect',{item='iron-plate',radius=48,count=50,ticks=600})})
-- collect wait_ticks at a machine: waiting there, 3 gears taken, the wait ends at wait_end.
local function machine(x,y)
  local m={valid=true,name='assembling-machine-1',type='assembling-machine',position={x=x,y=y},force=force,surface=surface,products_finished=12}
  local out={get_item_count=function() return 0 end,is_empty=function() return true end,get_contents=function() return {} end}
  m.get_output_inventory=function() return out end
  m.get_recipe=function() return {name='iron-gear-wheel',products={{type='item',name='iron-gear-wheel',amount=1}}} end
  machines[#machines+1]=m
  return m
end
local m1=machine(6.5,6.5)
local waiting=put('waiter',{kind='gather',wait=900,item='iron-gear-wheel',want=1000000,got=3,visited=1,items={['iron-gear-wheel']=3},
  targets={{entity=m1,position=m1.position}},index=1,until_tick=tick+1200,
  waiting={since=tick-100,finished=10,output={},per_craft={['iron-gear-wheel']=1}},wait_end=tick+300,
  call=call('collect',{position={x=6.5,y=6.5},item='iron-gear-wheel',wait_ticks=900})})
-- transfer walk=true: 5 taken at the first place, walking to the second.
local tour=put('courier',{kind='gather',op='transfer',transfer={direction='to_player',item='iron-plate'},item='iron-plate',rows={},items={},
  got=5,visited=1,want=math.huge,targets={{entity=near,position=near.position},{entity=far('wooden-chest',-40.5,40.5),position={x=-40.5,y=40.5}}},
  index=2,until_tick=tick+900,call=call('transfer',{positions={{x=3.5,y=3.5},{x=-40.5,y=40.5}},item='iron-plate',walk=true})})
-- A queued collect waiting at a machine (started by the queue's own handler), with a step after it.
local m2=machine(8.5,8.5)
bot.qcollect('queue_submit',{steps={{action='collect',args={position={x=8.5,y=8.5},item='iron-gear-wheel',wait_ticks=300}},{action='wait_ticks',args={ticks=30}}}})
advance(2)
local qa=storage.agent_harness.active[index('qcollect')]
eq(qa and qa.kind,'gather','queued collect running'); eq(qa.queued,true)
local qa_end=qa.wait_end
-- mine: 2 ore taken by hand, one every 30 ticks.
local ore={valid=true,name='iron-ore',type='resource',amount=1000,position={x=5.5,y=4.5},force=force,surface=surface}
local mine=put('miner',{kind='mine',entity=ore,until_tick=tick+200,products={'iron-ore'},started=tick-60,held_before={['iron-ore']=0},
  cycle=30,next_mine=tick+10,mined=2,call=call('mine',{position={x=5.5,y=4.5},ticks=260})})
index('miner')
-- pickup: 5 plates taken so far, none left in reach (it ends on its next look).
local pick=put('picker',{kind='pickup',reach=1,until_tick=tick+600,picked={['iron-plate']=5},next_pick=tick+2,call=call('pickup',{})})
-- repair: the tool borrowed from the inventory into the cursor, a wall 250 hp short, 1 hp a tick.
local repairer=runtime.lookup(index('repairer'))
repairer.character.items['repair-pack']=10
repairer.cursor_stack.swap_stack(repairer.get_main_inventory().find_item_stack('repair-pack'))
local wall={valid=true,name='stone-wall',type='wall',position={x=4.5,y=6.5},health=100,max_health=350,force=force,surface=surface,prototype={repair_speed_modifier=1}}
local repair=put('repairer',{kind='repair',entity=wall,borrowed_cursor=true,until_tick=tick+600,call=call('repair',{position={x=4.5,y=6.5},ticks=600})})
-- shoot at a position on foot.
storage.agent_harness.combat=storage.agent_harness.combat or {}
local shot={until_tick=tick+400,position={x=10,y=10},auto=false,radius=24,ammo_start=10}
storage.agent_harness.combat[index('shooter')]=shot
-- move_to through two via points, the first reached: its second leg under way.
bot.viawalker('move_to',{position={x=60.5,y=0.5},via={{x=20.5,y=0.5},{x=40.5,y=0.5}},ticks=900})
local walk=storage.agent_harness.active[index('viawalker')]
walk.via.index=2
advance(1)
eq(collect.nav and collect.nav.path_state,'pending','collector walking to its second place')
-- Two more, broken after the install below as a shape the new runtime does not expect would be: one's tick raises,
-- the other's end.
local broken=put('broken',{kind='gather',item='iron-plate',want=10,got=1,visited=1,index=1,until_tick=tick+600,
  targets={{entity=far('iron-chest',30.5,30.5),position={x=30.5,y=30.5}}},call=call('collect',{item='iron-plate',radius=48})})
local brokenend=put('brokenend',{kind='gather',all=true,items={},want=10,got=1,visited=1,targets={},index=1,until_tick=tick+600,
  call=call('collect',{radius=8})})
local qbefore=bot.qcollect('queue_status',{peek=true})
local walk_until=walk.until_tick
-- Their deadlines before the update.
local due={collector=collect.until_tick,waiter=waiting.wait_end,courier=tour.until_tick,miner=mine.until_tick,shooter=shot.until_tick}
at=tick
install()
broken.targets=nil; brokenend.items=nil
advance(1)
-- The same actions, with their deadlines and counts.
local A=storage.agent_harness.active
eq(A[index('collector')],collect); eq(collect.until_tick,due.collector); eq(collect.got,20); eq(collect.index,2); eq(collect.carried,at)
eq(A[index('waiter')],waiting); eq(waiting.wait_end,due.waiter); eq(waiting.got,3)
eq(A[index('courier')],tour); eq(tour.got,5); eq(tour.index,2)
eq(A[index('qcollect')],qa,'queued collect carried')
eq(A[index('miner')],mine); eq(mine.until_tick,due.miner)
eq(A[index('repairer')],repair)
eq(repairer.cursor_stack.valid_for_read,true,'the repair tool held again'); eq(repairer.cursor_stack.name,'repair-pack')
eq(storage.agent_harness.combat[index('shooter')],shot); eq(shot.until_tick,due.shooter)
-- Nothing of theirs reads interrupted.
for _,name in ipairs{'collector','waiter','courier','miner','repairer'} do
  local b=brief(name); assert(not (b.last and b.last.outcome=='interrupted'),name..' last')
end
local q=bot.qcollect('queue_status',{peek=true})
eq(q.paused,false); eq(q.active.action,'collect'); eq(q.active.id,qbefore.active.id); eq(#q.pending,1)
for _,h in ipairs(q.history) do assert(h.ok~=false,'qcollect history: '..tostring(h.action)) end
-- move_to started again by its deadline, from the second via point.
local again=A[index('viawalker')]
assert(again and again~=walk,'viawalker restarted'); eq(again.until_tick,walk_until,'restarted by the same deadline')
eq(#again.via.points,1); eq(again.via.points[1].x,40.5); eq(again.call.args.via[1].x,40.5)
-- The notes name what carried over.
local function note1(name) local n=notes(name); return n and n[1] end
eq(note1('collector'),'harness updated at tick '..at..' (your collect carried over)')
eq(note1('waiter'),'harness updated at tick '..at..' (your collect carried over)')
eq(note1('courier'),'harness updated at tick '..at..' (your transfer carried over)')
eq(note1('qcollect'),'harness updated at tick '..at..' (your queue carried over)')
eq(note1('miner'),'harness updated at tick '..at..' (your mine carried over)')
eq(note1('repairer'),'harness updated at tick '..at..' (your repair carried over)')
eq(note1('shooter'),'harness updated at tick '..at..' (your shoot carried over)')
eq(note1('viawalker'),'harness updated at tick '..at..': your move_to was interrupted by a harness update; resumed')
-- The broken ones end, and the harness tick goes on (no quarantine: advance raised nothing).
local b=brief('broken'); eq(b.active,false); eq(b.last.outcome,'failed')
assert(b.last.error:find('carried over a harness update; this runtime could not run it',1,true),b.last.error)
-- Its note follows the carried one.
local list=notes('broken')
eq(#list,2); eq(list[1],'harness updated at tick '..at..' (your collect carried over)')
assert(list[2]:find('harness updated at tick '..at..': your collect carried over, then stopped at tick '..(at+1)..': this runtime could not run it (',1,true),list[2])
b=brief('brokenend'); eq(b.active,false); eq(b.last.outcome,'collected')
assert(b.last.error:find('could not report how it ended',1,true),b.last.error)
list=notes('brokenend')
assert(has(list,'your collect carried over and ended collected at tick '..(at+1)..'; this runtime could not report the rest ('),table.concat(list,' | '))
-- pickup: nothing left in reach, it ends; the plates taken before the update are counted once in hand hauling.
b=brief('picker'); eq(b.last.kind,'pickup'); eq(b.last.outcome,'picked_up'); eq(b.last.picked['iron-plate'],5)
local hauled=storage.agent_harness.hauling[index('picker')]
eq(hauled.items,5,'pickup hauling counted once')
-- Each ends when and as it would have.
advance(due.miner-tick+1)
b=brief('miner'); eq(b.last.kind,'mine'); eq(b.last.outcome,'duration_elapsed'); eq(b.last.tick,due.miner+1); eq(b.last.mined,mine.mined)
assert(mine.mined>2,'mined on after the update')
advance(due.waiter-tick)
b=brief('waiter'); eq(b.last.kind,'gather'); eq(b.last.outcome,'collected'); eq(b.last.tick,due.waiter); eq(b.last.took,'iron-gear-wheel*3')
advance(due.shooter-tick+1)
local lc=storage.agent_harness.last_combat[index('shooter')]
eq(lc.outcome,'duration_elapsed'); eq(lc.tick,due.shooter+1)
b=brief('repairer'); eq(b.last.kind,'repair'); eq(b.last.outcome,'repair_completed'); eq(wall.health,350)
advance(due.collector-tick+1)
b=brief('collector'); eq(b.last.kind,'gather'); eq(b.last.outcome,'timed_out'); eq(b.last.tick,due.collector+1); eq(b.last.got,20); eq(b.last.want,50)
assert(b.last.tally:find('1 places not visited (timed_out)',1,true),b.last.tally)
advance(due.courier-tick+1)
b=brief('courier'); eq(b.last.kind,'gather'); eq(b.last.outcome,'timed_out'); eq(b.last.tick,due.courier+1); eq(b.last.transferred,5)
-- The queued collect ended at its own wait's end (the machine made nothing), no interruption in its history.
q=bot.qcollect('queue_status')
eq(#q.history,1); eq(q.history[1].action,'collect'); eq(q.history[1].result.outcome,'nothing_collected'); eq(q.history[1].finished_tick,qa_end)

-- A full drop's queue step goes on while its pods wait for a hatch (an install leaves their channel alone). Before, it
-- started again, the second drop was refused while the first still had pods waiting, and the queue paused on that.
bot.dropper('queue_submit',{steps={{action='wait_ticks',args={ticks=600}},{action='wait_ticks',args={ticks=30}}}})
advance(1)
-- Clear of the drop jobs' 10-tick look while the stand-in job is there.
while tick%10~=1 do advance(1) end
local dq=storage.agent_harness.queues[index('dropper')]
dq.current.action='drop'; dq.current.args={full=true}; dq.current.wait=true
storage.agent_harness.drop_jobs=storage.agent_harness.drop_jobs or {}
storage.agent_harness.drop_jobs[index('dropper')]={platform={valid=true,name='Sunward'},sent={},pods={{items={}}},until_tick=tick+1000}
advance(1)
local drop_id=dq.current.id
at=tick
install()
advance(1)
q=bot.dropper('queue_status',{peek=true})
eq(q.paused,false); eq(q.active.action,'drop'); eq(q.active.id,drop_id); eq(#q.pending,1); eq(#q.history,0)
eq(notes('dropper')[1],'harness updated at tick '..at..' (your queue carried over)')
-- The pods all sent: the step ends with the drop's own result.
storage.agent_harness.drop_jobs[index('dropper')]=nil
storage.agent_harness.last_drop={[index('dropper')]={kind='drop',outcome='dropped',tick=tick}}
advance(1)
q=bot.dropper('queue_status',{peek=true}); eq(q.history[1].action,'drop'); eq(q.history[1].ok,true)

-- A restart with a changed mod (on_configuration_changed: boot with game, then the new runtime's own stop_all)
-- carries the same way.
bot.astra('queue_submit',{steps={{action='wait_ticks',args={ticks=600}}}}); advance(2)
do
  local candidate=dofile(RUNTIME)
  runtime=candidate
  assert(pcall(runtime.stop_all))
end
advance(1)
q=bot.astra('queue_status'); eq(q.paused,false); eq(q.active.action,'wait_ticks')
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
