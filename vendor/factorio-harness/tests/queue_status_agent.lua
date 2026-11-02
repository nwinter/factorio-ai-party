-- Run from the harness root: lua tests/queue_status_agent.lua
-- Queue ownership through real dispatch, with the d17_batch16_rt fake-engine scaffold.
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
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
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

local function same(a,b,path)
  path=path or 'reply'
  if path=='reply.clock' then return end -- Request telemetry describes the caller, not the queue owner.
  eq(type(a),type(b),path)
  if type(a)~='table' then eq(a,b,path); return end
  for k,v in pairs(a) do same(v,b[k],path..'.'..tostring(k)) end
  for k in pairs(b) do assert(a[k]~=nil,path..': extra '..tostring(k)) end
end
local function copy(t)
  if type(t)~='table' then return t end
  local out={}; for k,v in pairs(t) do out[k]=copy(v) end; return out
end
local state=storage.agent_harness
local si=runtime.bots.index_of('sol')
for _,lane in ipairs{'body','remote','platform:Asterion'} do
  sol('queue_submit',{lane=lane,start=false,steps={{action='wait_ticks',args={ticks=600},label='return'}},
    guards={{when={['until']='tick_at_least',tick=100000},steps={{action='wait_ticks',args={ticks=60}}}}}})
  local key=lane=='body' and 'queues' or lane=='remote' and 'remote_queues' or 'lane_queues|Asterion'
  local q=state[key][si]
  q.guards[1].saw='deadline still ahead'
  q.guards[1].when.evidence={read_tick=game.tick,reason='deadline not reached'}
  q.guards[1].read_error={text='previous read failed',tick=0,last_tick=0,checks=1,cleared_tick=1}
  local before=copy(q)
  local own=sol('queue_status',{lane=lane,pending='all',history='all',args=true})
  local other=astra('queue_status',{agent='Sol',lane=lane,pending='all',history='all',args=true})
  same(own,other); same(q,before)
  eq(other.owner,'sol'); eq(other.state,'paused, held'); eq(other.pending[1].label,'return')
  eq(other.guards[1].saw,'deadline still ahead')
  eq(other.guards[1].when.evidence.reason,'deadline not reached')
  assert(other.guards[1].baseline:find('deadline tick 100000',1,true))
  eq(other.guards[1].read_error.error,'previous read failed')
  assert(other.access:find('owner-scoped',1,true))
  same(other,astra('queue_status',{agent='Sunny',lane=lane,pending='all',history='all',args=true}))
  same(own,sol('queue_status',{agent='sol',lane=lane,pending='all',history='all',args=true}))
  for _,action in ipairs{'queue_cancel','queue_pause','queue_resume','queue_edit','queue_submit','queue_repeat'} do
    fails(function() astra(action,{agent='sol',lane=lane}) end,'unknown argument agent')
    same(q,before)
  end
end
sol('queue_resume',{lane='remote'}); advance(1)
sol('queue_submit',{lane='remote',steps={{action='wait_ticks',args={ticks=120},label='after return'}}})
local live=astra('queue_status',{agent='sol',lane='remote'})
eq(live.state,'running'); eq(live.active.action,'wait_ticks'); eq(live.pending[1].label,'after return')
same(live,sol('queue_status',{lane='remote'}))
sol('queue_cancel',{lane='remote'})
local stopped=astra('queue_status',{agent='sol',lane='remote',orders=true,history='all'})
same(stopped,sol('queue_status',{lane='remote',orders=true,history='all'}))
assert(stopped.last_failure and stopped.last_failure.result.reason)
sol('queue_submit',{lane='remote',steps={{action='wait_ticks',args={ticks=1}}}}); advance(3)
local done=astra('queue_status',{agent='sol',lane='remote'})
eq(done.state,'completed'); assert(done.plan.done>0); assert(#done.history>0)
same(done,sol('queue_status',{lane='remote'}))
local before=copy(state.queues)
fails(function() astra('queue_status',{agent='not-an-agent'}) end,'unknown agent')
fails(function() astra('queue_status',{agent=42}) end,'agent must be')
same(state.queues,before)
for _,lane in ipairs{'body','remote','platform:Never-created'} do
  local key=lane=='body' and 'queues' or lane=='remote' and 'remote_queues' or 'lane_queues|Never-created'
  local old=copy(state[key])
  local empty=astra('queue_status',{agent='grok',lane=lane})
  eq(empty.owner,'grok'); eq(empty.state,'empty'); eq(empty.active,false); eq(empty.pending_count,0)
  same(state[key],old)
end
assert(not state.platform_lanes['Never-created'])
sol('queue_submit',{lane='platform:Never-created',start=false,steps={{action='wait_ticks',args={ticks=1}}}})
assert(state.platform_lanes['Never-created'])
local q=state.remote_queues[si]
q.pending={}; q.history={}; q.current=nil
for i=1,128 do q.pending[i]={id='job-'..i,action='wait_ticks',args={ticks=1},plan=q.plan.id} end
for i=1,64 do q.history[i]={id='old-'..i,action='wait_ticks',ok=true,plan=q.plan.id,finished_tick=i} end
for _,call in ipairs{sol,astra} do
  local full=call('queue_status',{agent='sol',lane='remote',pending='all',history='all'})
  eq(#full.pending,128); eq(#full.history,64)
  local default=call('queue_status',{agent='sol',lane='remote'})
  eq(#default.pending,1); eq(#default.history,16)
  for _,args in ipairs{{pending=129},{history=65},{history=-1}} do
    args.agent='sol'; args.lane='remote'
    fails(function() call('queue_status',args) end,'is a count')
  end
end
q.guards={{when={['until']='platform_loss',platform='Asterion',loss_since=123},saw='0 lost'}}
local before=copy(q)
local legacy=astra('queue_status',{agent='sol',lane='remote'})
eq(legacy.guards[1].since_tick,123); assert(legacy.guards[1].id); same(q,before)
-- Batch415 merge: another agent sees both the speed evidence and batch416's baseline, without changing duration state.
force.platforms={{valid=true,name='Asterion',speed=40.3/60}}
for _,lane in ipairs{'body','remote','platform:Asterion'} do
  local key=lane=='body' and 'queues' or lane=='remote' and 'remote_queues' or 'lane_queues|Asterion'
  local queue=state[key][si]
  local guards=queue.guards
  local condition={['until']='platform_speed_above',platform='Asterion',above=35,for_s=2}
  local met,saw=runtime.scheduler_api.condition(runtime.scheduler_api.player(si,true),condition)
  eq(met,false)
  queue.guards={{when=condition,saw=saw}}
  local before=copy(queue)
  local own=sol('queue_status',{lane=lane})
  local other=astra('queue_status',{agent='sol',lane=lane})
  same(own,other); same(queue,before)
  eq(other.guards[1].evidence.speed_kms,40.3); eq(other.guards[1].evidence.tick,game.tick)
  assert(other.guards[1].baseline:find('live speed of Asterion > 35 km/s for 2 s',1,true))
  eq(other.guards[1].when.speed_since,game.tick)
  queue.guards=guards
end
print('queue_status agent: owner parity, evidence, read-only state, writes refused, caps: ok')
