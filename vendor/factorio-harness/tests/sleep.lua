-- Run from repository root: lua tests/sleep.lua
-- sleep: what keeps going (while_asleep), wakes on the queue finishing or
-- stalling and on a condition (items, chests, research), via the runtime.
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


-- Fakes for conditions: items, research, a chest on tile (3,3).
prototypes=prototypes or {}
prototypes.item=prototypes.item or {}
prototypes.item['iron-plate']=prototypes.item['iron-plate'] or {name='iron-plate'}
local techs={automation={name='automation',researched=false},logistics={name='logistics',researched=false}}
force.technologies=techs
local chest_items={}
local chest={valid=true,name='wooden-chest',get_item_count=function(n) return chest_items[n] or 0 end}
local find=surface.find_entities_filtered
surface.find_entities_filtered=function(f)
  if f.position and f.radius==0.3 and f.position.x==3 and f.position.y==3 then return {chest} end
  return find(f)
end
local function check(who) return who('sleep_check',{peek=true}) end
-- The final read, then past the 10 s in which a new sleep repeats that wake.
local function wake(who) local r=who('sleep_check',{}); jump(601); return r end

-- The reply says first what keeps going: nothing.
local r=astra('sleep',{seconds=60})
eq(r.while_asleep,'no queue and no action: your character stands idle for up to 60 s')
assert(not r.wakes_on:find('queue',1,true))
-- A direct action keeps going, then the character stands idle.
astra('walk',{direction='east',ticks=600}); advance(1)
r=astra('sleep',{seconds=60})
assert(r.while_asleep:find('^your walk keeps going until tick %d+, then your character stands idle$'),r.while_asleep)
astra('stop')

-- A queue: the sleep ends when it finishes (queue_done), with the steps it ran.
sol('queue_submit',{steps={{action='wait_ticks',args={ticks=120}},{action='wait_ticks',args={ticks=60}}}}); advance(1)
r=sol('sleep',{seconds=600})
eq(r.while_asleep,'your queue keeps running (wait_ticks running, 1 steps pending); this sleep ends when it finishes or stalls')
assert(r.wakes_on:find('your queue finishing or stalling',1,true))
advance(100); eq(check(sol).woke,nil)
advance(100)
r=check(sol); eq(r.woke,'queue_done'); eq(r.queue,'finished'); eq(r.queue_steps,2)
assert(r.while_asleep:find('^your queue keeps running'),r.while_asleep) -- repeated in the wake reply
eq(wake(sol).woke,'queue_done')
-- A repeating plan never finishes; it does not end the sleep between cycles.
sol('queue_repeat',{steps={{action='wait_ticks',args={ticks=60}}},interval_ticks=60}); advance(1)
r=sol('sleep',{seconds=10})
assert(r.while_asleep:find('repeating',1,true),r.while_asleep)
advance(300); eq(check(sol).woke,nil)
advance(400); r=check(sol); eq(r.woke,'elapsed'); assert(r.queue_steps>=2,r.queue_steps)
sol('queue_cancel',{})

-- A failed step pauses the queue: queue_stalled, with the failure.
grok('queue_submit',{steps={{action='wait_ticks',args={ticks=30}},{action='board_update',args={id=999,note='x'}},{action='wait_ticks',args={ticks=30}}}}); advance(1)
grok('sleep',{seconds=600})
advance(40)
r=check(grok); eq(r.woke,'queue_stalled')
assert(r.queue:find('^board_update failed: no board item #999'),r.queue)
wake(grok)
-- Sleeping with that queue paused says so.
r=grok('sleep',{seconds=30})
eq(r.while_asleep,'no queue and no action: your character stands idle for up to 30 s (your queue is paused with 1 steps pending)')
grok('queue_cancel',{})

-- A walking step that has not moved the character for 30 s has stalled
-- (here a path request that never comes back, as Muse's stuck move job).
runtime.lookup(runtime.bots.index_of('astra')).character.prototype={collision_mask={layers={player=true}}}
astra('queue_submit',{steps={{action='move_to',args={position={x=100,y=100}}}}}); advance(1)
r=astra('sleep',{seconds=600}); assert(r.while_asleep:find('move_to running',1,true),r.while_asleep)
eq(check(astra).woke,nil) -- first look at the position
advance(1700); eq(check(astra).woke,nil)
advance(110); r=check(astra); eq(r.woke,'queue_stalled')
assert(r.queue:find('^move_to has not moved your character for 30 s'),r.queue)
wake(astra); astra('queue_cancel',{})

-- --until: an item count in the character's inventory.
r=astra('sleep',{seconds=60,condition={['until']='item_count',item='iron-plate',at_least=20}})
eq(r.condition,'item_count iron-plate'); eq(r.saw,'iron-plate 8') -- a new bot's kit
assert(r.wakes_on:find('the condition',1,true))
advance(10); eq(check(astra).woke,nil)
local body=runtime.lookup(runtime.bots.index_of('astra')).character
body.insert{name='iron-plate',count=12}
r=check(astra); eq(r.woke,'condition'); eq(r.saw,'iron-plate 20')
wake(astra)
-- Over a list of chests (also in wait_until).
r=astra('sleep',{seconds=60,condition={['until']='item_count',item='iron-plate',at_least=50,positions={{x=3,y=3},{x=9,y=9}}}})
eq(r.saw,'iron-plate 0 in 1 entities')
chest_items['iron-plate']=50
r=check(astra); eq(r.woke,'condition'); eq(r.saw,'iron-plate 50 in 1 entities')
wake(astra)
fails(function() astra('sleep',{seconds=60,condition={['until']='item_count',item='iron-plate',at_least=1,positions={}}}) end,'positions takes 1..64')
r=astra('queue_submit',{steps={{action='wait_until',args={['until']='item_count',item='iron-plate',at_least=50,positions={{x=3,y=3}}}}}})
eq(#r.pending,1); advance(3); eq(#astra('queue_status').history>=1,true)
-- Met already: the first check ends it.
r=astra('sleep',{seconds=60,condition={['until']='item_count',item='iron-plate',at_least=5}})
eq(r.already_met,true); r=check(astra); eq(r.woke,'condition'); eq(r.slept_s,0)
wake(astra)

-- researched: a named technology, or without one the research running now.
fails(function() astra('sleep',{seconds=60,condition={['until']='researched'}}) end,'no research is running')
force.current_research=techs.logistics
r=astra('sleep',{seconds=60,condition={['until']='researched'}}); eq(r.condition,'researched logistics')
-- A mention still ends a condition sleep first.
sol('say',{text='@astra the gears are in'})
eq(check(astra).woke,'mentioned')
wake(astra)
r=astra('sleep',{seconds=60,condition={['until']='researched',technology='logistics'}})
techs.logistics.researched=true
r=check(astra); eq(r.woke,'condition'); eq(r.saw,'logistics researched')
wake(astra)
fails(function() astra('sleep',{seconds=60,condition='researched'}) end,'condition is a wait_until condition')

-- A queue's wait_until runs on through a sleep's end, with and without --until,
-- and through failed reads made meanwhile (shift04: a failed placements read
-- during Sol's sleep paused the queue and ended its wait_until interrupted).
chest_items['iron-plate']=10
sol('queue_submit',{steps={{action='wait_until',args={['until']='item_count',item='iron-plate',at_least=100,positions={{x=3,y=3}},timeout=18000}},
  {action='wait_ticks',args={ticks=30}}}}); advance(2)
local function running()
  local q=sol('queue_status')
  eq(q.paused,false); eq(q.active and q.active.action,'wait_until'); eq(#q.pending,1)
  for _,h in ipairs(q.history) do assert(not (h.action=='wait_until' and h.ok==false),'wait_until failed: '..tostring(h.result and h.result.reason)) end
end
running()
r=sol('sleep',{seconds=5}); assert(r.while_asleep:find('wait_until running',1,true),r.while_asleep)
advance(100); eq(check(sol).woke,nil)
advance(250); eq(check(sol).woke,'elapsed'); eq(wake(sol).woke,'elapsed')
running()
r=sol('sleep',{seconds=60,condition={['until']='item_count',item='iron-plate',at_least=20,positions={{x=3,y=3}}}})
advance(10); eq(check(sol).woke,nil)
chest_items['iron-plate']=30
advance(1); eq(check(sol).woke,'condition'); wake(sol)
running()
-- Failed reads: a placements check out of sight, an unknown observe argument, inspect of nothing.
sol('sleep',{seconds=30})
fails(function() sol('placements',{name='offshore-pump',position={x=900,y=900}}) end,'')
fails(function() sol('observe',{scope='scan',bogus=true}) end,'unknown argument bogus')
fails(function() sol('inspect',{position={x=700,y=700}}) end,'')
advance(1); eq(check(sol).woke,nil); wake(sol)
running()
-- A failed action still stops the character and pauses the queue, as before.
fails(function() sol('move_to',{}) end,'')
local q=sol('queue_status'); eq(q.paused,true)
eq(q.history[#q.history].action,'wait_until'); eq(q.history[#q.history].result.reason,'interrupted')
sol('queue_cancel',{})
fails(function() astra('sleep',{seconds=60,condition={['until']='bogus'}}) end,'until must be one of')
print('sleep: ok')
