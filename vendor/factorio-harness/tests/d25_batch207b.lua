-- d25 batch207b. Run from the harness root: lua tests/d25_batch207b.lua
-- QT3 (Sol #2351: plan 768's build steps with wait: true and clear_obstacles: true were marked ok at then_runs, the next
-- step ran while the clearing was pending, and the plan ended done with 4 of 132 entities built): a queued build waits
-- for its clear_obstacles job and its run again, fails when the job ends without it, and a pause requeues it.
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
  if not ok then error(result,0) end
  return result
end
local sol=function(action,args) return request{action=action,args=args or {},bot='sol'} end
runtime.operator.bot_create('sol')
local index=runtime.bots.index_of('sol')
local function status() return sol('queue_status',{history=8}) end
local function entry(q,label)
  local found
  for _,e in ipairs(q.history) do if e.label==label then found=e end end
  return found
end
-- two rocks in the footprints, out of reach (left to the robots); the placement itself stubbed (build_now)
local rocks={}
local function rock(x)
  local e={valid=true,name='big-rock',type='simple-entity',position={x=x,y=0},bounding_box={left_top={x=x-1,y=-1},right_bottom={x=x+1,y=1}}}
  e.order_deconstruction=function() e.marked=true end
  rocks[#rocks+1]=e
  return e
end
runtime.clearobs.obstacles=function() local out={} for _,e in ipairs(rocks) do if e.valid then out[#out+1]=e end end return out end
local built={}
runtime.build_now=function(p,a) built[#built+1]=a; return {built=#(a.builds or {a}),placed=#(a.builds or {a})} end
local args={item='stone-furnace',builds={{position={x=5,y=0}},{position={x=9,y=0}}},clear_obstacles=true}
local function plan() return {lane='body',mode='replace',steps={{action='build',args=args,label='rocky build'},{action='wait_ticks',args={ticks=1},label='after'}}} end

do
  rock(5); rock(9)
  sol('queue_submit',plan())
  advance(5)
  local q=status()
  eq(entry(q,'rocky build'),nil,'not ok at then_runs')
  eq(entry(q,'after'),nil,'the next step waits')
  eq(q.active and q.active.label,'rocky build')
  has(q.active.result.then_runs,'build runs again once all 2 are gone')
  has(q.active.continuation,'clear_obstacles: 2 of 2 trees and rocks in the footprints still stand')
  eq(#built,0)
  -- one gone: still waiting; both gone: the build runs again (clearobs every second) and the step ends with it
  rocks[1].valid=false; advance(60)
  eq(entry(status(),'rocky build'),nil,'one rock left')
  rocks[2].valid=false; advance(60)
  q=status()
  eq(#built,1); eq(built[1].clear_obstacles,nil)
  local e=entry(q,'rocky build')
  eq(e.ok,true); has(e.result.cleared,'build ran again after the trees and rocks were gone')
  eq(e.result.outcome,'completed'); eq(e.result.completion.built,2,'the run again\'s reply is the completion')
  advance(3)
  eq(entry(status(),'after').ok,true,'then the next step')
end
print('d25_batch207b QT3 a queued build waits for its clear_obstacles run again: ok')

-- the watch runs out: the step fails with why, the next step does not run
do
  rocks={}; built={}
  rock(5)
  sol('queue_submit',plan())
  advance(5)
  storage.agent_harness.clear_jobs[index].until_tick=tick
  advance(60)
  local q=status()
  local e=entry(q,'rocky build')
  eq(e.ok,false); has(e.result.reason,'1 of 1 trees and rocks still stand after 10 min: build not run again')
  eq(entry(q,'after'),nil); eq(#built,0)
end
print('d25_batch207b QT3 the clear watch runs out: the step fails: ok')

-- a pause while the job is pending: the job dropped, the step requeued as it was; no run again later
do
  rocks={}; built={}
  rock(5)
  sol('queue_submit',plan())
  advance(5)
  sol('queue_pause',{})
  local q=status()
  local e=entry(q,'rocky build')
  eq(e.ok,false); eq(e.result.requeued,true); has(e.result.resumed_from,'its clear_obstacles continuation was pending')
  eq(storage.agent_harness.clear_jobs,nil)
  eq(q.pending[1].label,'rocky build')
  rocks[1].valid=false; advance(120)
  eq(#built,0,'no run again after the pause')
  sol('queue_resume',{})
  advance(5)
  eq(#built,1,'resumed: nothing in the way, built at once')
  eq(entry(status(),'after').ok,true)
end
print('d25_batch207b QT3 a pause drops the pending clear and requeues the build: ok')

-- a direct call: the run again never starts over another action running then
do
  rocks={}; built={}
  rock(5)
  sol('build',args)
  sol('wait_ticks',{ticks=600})
  rocks[1].valid=false; advance(60)
  eq(#built,0)
  has(storage.agent_harness.clear_end[index].text,'build not run again: your wait_ticks runs (started after the clear)')
  eq(storage.agent_harness.active[index].kind,'wait_ticks','the wait goes on')
end
print('d25_batch207b QT3 the run again never interrupts another action: ok')
