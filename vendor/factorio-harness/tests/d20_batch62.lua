-- d20 batch62. Run from the harness root: lua tests/d20_batch62.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- The runtime against a fake engine (as tests/d17_batch35.lua sets it up), for the calls below.
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
local sol=as('sol')
runtime.operator.bot_create('sol')
local body=runtime.lookup(runtime.bots.index_of('sol')).character
-- The gun slots and the main inventory equip reads (a gun in the main inventory goes into an empty gun slot).
local function slot() local s={valid_for_read=false}; s.swap_stack=function(src) s.valid_for_read=true; s.name=src.name; return true end; return s end
local guns={slot(),slot(),slot()}
body.get_inventory=function(i) return guns end
local main={find_item_stack=function(n) return n=='submachine-gun' and {name=n,count=1} or nil end}
body.get_main_inventory=function() return main end
local function status(args) return sol('queue_status',args or {history=6,pending=2}) end
local function entry(q,id,reason)
  local found
  for _,e in ipairs(q.history) do if e.id==id and (reason==nil or (e.result and e.result.reason)==reason) then found=e end end
  return found
end
local function equip()
  for i=1,#guns do guns[i]=slot() end
  local ok,r=pcall(sol,'equip',{item='submachine-gun',slot='gun',index=1})
  return ok,r
end

-- X1 (viewer Aurora, operator inbox 23:40; Sol shift49 04:31:30, journal line 1314: queue_submit body wait_ticks 34458
-- then circuit_set; his equip submachine-gun at 04:39:13, line 2056, paused the queue and resume_after_direct ran it
-- again at once; the wait, a relative step, was not requeued, so the circuit_set ran at that tick, 25985 ticks into
-- the wait). Now the wait keeps its end tick and the step after it runs there.
do
  surface.find_entities_filtered=function() return {} end
  body.position={x=0,y=0}
  sol('queue_submit',{lane='body',mode='replace',resume_after_direct=true,
    steps={{action='wait_ticks',args={ticks=600}},{action='wait_ticks',args={ticks=1},label='after'}}})
  advance(2)
  local q=status()
  eq(q.active.action,'wait_ticks'); local ends=q.active.until_tick; local id=q.active.id
  advance(300)
  local ok,r=equip()
  assert(ok,tostring(r)); eq(r.equipped,'submachine-gun')
  eq(r.queue_resumed,'your queue, paused by this call, runs again now (queue_resume_after)')
  q=status()
  eq(q.paused,false)
  local cut=entry(q,id,'interrupted')
  assert(cut,'the interruption is in the history'); eq(cut.result.requeued,true)
  has(cut.result.resumed_from,'keeps its end tick '..ends)
  advance(2)
  q=status()
  eq(q.active.action,'wait_ticks'); eq(q.active.id,id); eq(q.active.until_tick,ends,'the same end tick')
  -- nothing after it runs before the end tick
  while game.tick<ends-1 do advance(1); q=status(); assert(q.active and q.active.id==id,'the wait runs to its end tick (tick '..game.tick..')') end
  advance(3)
  q=status()
  local done=nil
  for _,e in ipairs(q.history) do if e.id==id and e.ok then done=e end end
  assert(done,'the wait finished'); assert(done.finished_tick>=ends,'not before its end tick: '..tostring(done.finished_tick)..' < '..ends)
  has(done.result.kept,'wait_ticks was interrupted and kept its end tick '..ends..': it ended there')
  local after
  for _,e in ipairs(q.history) do if e.label=='after' then after=e end end
  assert(after,'the next step ran'); assert(after.started_tick>=ends,'the next step ran at or after the end tick')
  sol('queue_cancel',{})
end
print('d20_batch62 X1 a wait interrupted by a direct call keeps its end tick: ok')

-- A wait whose end tick passes while the queue is paused (no resume_after_direct): the steps after it are held; the
-- reply says so; queue_resume ends the wait at once and runs them.
do
  sol('queue_submit',{lane='body',mode='replace',resume_after_direct=false,
    steps={{action='wait_ticks',args={ticks=120}},{action='wait_ticks',args={ticks=1},label='after'}}})
  advance(2)
  local q=status(); local ends=q.active.until_tick; local id=q.active.id
  advance(10)
  local ok=equip(); assert(ok)
  q=status()
  eq(q.paused,true); eq(q.pending[1].action,'wait_ticks'); eq(q.pending[1].ends_tick,ends)
  has(q.kept_wait,'wait_ticks was interrupted and keeps its end tick '..ends)
  has(q.kept_wait,'once queue_resume runs the queue')
  advance(400)
  q=status()
  eq(q.paused,true); eq(q.pending[2].label,'after')
  has(q.kept_wait,'its end tick '..ends..' passed 4 s ago while your queue is paused: queue_resume runs the steps after it')
  local resumed=game.tick
  sol('queue_resume',{})
  advance(3)
  q=status()
  local done,after
  for _,e in ipairs(q.history) do if e.id==id and e.ok then done=e end; if e.label=='after' then after=e end end
  assert(done and after,'the wait ended and the next step ran after the resume')
  has(done.result.kept,'its end tick '..ends..' passed while your queue was paused')
  has(done.result.kept,'before the queue resumed at tick')
  assert(after.started_tick>resumed)
  sol('queue_cancel',{})
end
print('d20_batch62 X1 a wait that ends while its queue is paused holds the steps after it: ok')

-- queue_pause keeps it too (it said the running step is requeued as any interruption requeues it); queue_cancel with
-- clear false ends the wait and says the steps after it are held.
do
  sol('queue_submit',{lane='body',mode='replace',steps={{action='wait_ticks',args={ticks=300}},{action='wait_ticks',args={ticks=1},label='after'}}})
  advance(2)
  local ends=status().active.until_tick
  local r=sol('queue_pause',{})
  has(r.held,'wait_ticks stopped and requeued at the head')
  has(r.kept_wait,'keeps its end tick '..ends)
  advance(50); sol('queue_resume',{}); advance(2)
  eq(status().active.until_tick,ends)
  r=sol('queue_cancel',{clear=false})
  has(r.cancelled_wait,'wait_ticks cancelled 5 s before its end tick '..ends)
  has(r.cancelled_wait,'the steps after it are held: your queue is paused, and queue_resume runs them now')
  eq(r.paused,true); has(r.pending[1],'[after]')
  sol('queue_cancel',{})
end
print('d20_batch62 X1 queue_pause keeps a wait; queue_cancel ends it and says so: ok')
