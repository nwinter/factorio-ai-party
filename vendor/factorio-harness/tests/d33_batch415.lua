-- Run from vendor/factorio-harness: lua tests/d33_batch415.lua
-- QS: schedule waits validated atomically; live platform speed waits and guards.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
  on_built_entity=15,on_player_mined_entity=16,on_robot_mined_entity=17,on_player_fast_transferred=18,on_gui_opened=19,on_gui_closed=20},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surfaces={}
local function character(surface,pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+#surfaces,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
local function new_surface(name,index,extra)
  local s={name=name,index=index,valid=true}
  for k,v in pairs(extra) do s[k]=v end
  s.find_non_colliding_position=function(_,origin) return origin end
  s.create_entity=function(args) if args.name=='character' then return character(s,args.position) end return {valid=true,name=args.name,position=args.position} end
  s.can_place_entity=function() return true end
  s.find_entities_filtered=function() return {} end
  s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
  surfaces[name]=s; surfaces[index]=s
  return s
end
local nauvis=new_surface('nauvis',1,{planet={name='nauvis'}})
local vulcanus=new_surface('vulcanus',2,{planet={name='vulcanus'}})
new_surface('platform-1',3,{platform={name='Peregrine'}})
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=nauvis,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character(nauvis,{x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=nauvis,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')

prototypes={item={['iron-plate']={}},fluid={['thruster-fuel']={}},quality={normal={}},space_location={nauvis={},fulgora={}},virtual_signal={['signal-T']={}}}
local pl={valid=true,name='Asterion',speed=20/60,index=1,force=force}
force.platforms={pl}
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function refused(fn,...)
  local ok,err=pcall(fn); assert(not ok,'expected refusal')
  for _,x in ipairs({...}) do has(err,x) end
  return tostring(err):gsub('^[^:]*:%d+: ','')
end
local function call(action,args) return runtime.dispatch{action=action,args=args,player=1} end
local function schedule(w) return {platform='Asterion',stops={{station='nauvis',wait={{type='time',ticks=60}}},{station='fulgora',wait=w}}} end
local bad=schedule({{type='item_count',comparator='>=',item='iron-plate',count=10}})
local step={action='platform_schedule',label='depart',args=bad}
local direct=refused(function() runtime.scheduler_api.handlers.platform_schedule(nick,bad) end,'stops[2].wait[1]','comparator','condition')
for _,dry in ipairs({true,false}) do
  for _,lane in ipairs({'body','remote','platform:Asterion'}) do
    local a={dry_run=dry,steps={{action='wait_ticks',args={ticks=60}},step}}
    if lane~='body' then a.lane=lane end
    refused(function() call('queue_submit',a) end,'steps[2] (platform_schedule, label "depart"): args:',direct)
    a.steps={{action='wait_ticks',args={ticks=60}}}
    a.guards={{when={['until']='tick_at_least',tick=100},steps={step}}}
    refused(function() call('queue_submit',a) end,'guards[1]: steps[1] (platform_schedule',direct)
  end
end
local valid={
  {{type='item_count',condition='iron-plate >= 10'}},
  {{type='item_count',condition={signal='iron-plate',comparator='>=',value=10}}},
  {{type='fluid_count',fluid='thruster-fuel',count=100,harness=true}},
  {{type='time',seconds=2}},
  {any_of={{type='time',ticks=60},{all_of={{type='item_count',item='iron-plate',count=10},{type='time',ticks=120}}}}},
}
for _,w in ipairs(valid) do runtime.scheduler_api.check_args('platform_schedule',schedule(w)) end
for _,w in ipairs({{{type='time',ticks=-1}},{{type='time',ticks=1.5}},{{type='garbage'}},{{type='time',ticks=60,compare='xor'}},{{type='item_count'}},{type='time',ticks=60},{[1]={type='time',ticks=60},[3]={type='item_count',comparator='>'}},{{type='item_count',condition='thruster-fuel >= 1'}},'wrong'}) do
  refused(function() runtime.scheduler_api.check_args('platform_schedule',schedule(w)) end,'stops[2].wait')
end
refused(function() runtime.scheduler_api.check_args('platform_schedule',{platform='Asterion',stop=2,wait={{type='item_count',comparator='>'}}}) end,'wait[1]','condition')
-- A valid early save_as followed by an invalid stop changes neither saved waits nor queue.
local saved=storage.agent_harness.saved_waits
local a=schedule({{type='item_count',comparator='>'}}); a.stops[1].save_as='batch415'
refused(function() runtime.scheduler_api.check_args('platform_schedule',a) end)
eq(storage.agent_harness.saved_waits,saved)
local b=schedule(nil); b.stops[1].save_as='batch415'; b.stops[2].wait_from='batch415'
runtime.scheduler_api.check_args('platform_schedule',b)
eq(storage.agent_harness.saved_waits,saved)
for _,q in pairs(storage.agent_harness.queues or {}) do eq(#q.pending,0); eq(q.current,nil); eq(#q.history,0) end

local C=require('conditions'){state=function() return storage.agent_harness end}
local function speed(extra) local c={['until']='platform_speed_above',platform='Asterion',above=20}; for k,v in pairs(extra or {}) do c[k]=v end; C.validate(c,nick); return c end
for _,badvalue in ipairs({-1,'20',math.huge,0/0}) do refused(function() speed{above=badvalue} end,'above') end
refused(function() speed{for_s=-1} end,'for_s')
refused(function() speed{max_age=0} end,'max_age')
local c=speed(); eq(C.check(nick,c),false)
pl.speed=40.3/60; eq(C.check(nick,c),true); eq(c.evidence.speed_kms,40.3); eq(c.evidence.tick,game.tick)
c=speed{for_s=1}; eq(C.check(nick,c),false)
for i=1,5 do game.tick=i*10; eq(C.check(nick,c),false) end
game.tick=60; eq(C.check(nick,c),true)
pl.speed=20/60; game.tick=70; eq(C.check(nick,c),false); eq(c.speed_since,nil)
pl.speed=40.3/60; game.tick=80; eq(C.check(nick,c),false)
game.tick=150; eq(C.check(nick,c),false); eq(c.speed_since,150,'stale gap resets duration')
pl.valid=false; refused(function() C.check(nick,c) end,'platform unavailable'); eq(c.evidence,nil); eq(c.speed_since,nil)
pl.valid=true; game.tick=160; eq(C.check(nick,c),false)
local record={}; game.tick=170; C.check(nick,speed{for_s=1},false,record); eq(record.evidence.tick,170)
-- State is stored on the condition/record, surviving a module reload.
C=require('conditions'){state=function() return storage.agent_harness end}
game.tick=220; eq(C.check(nick,c),true)
for _,kind in ipairs({'all','any'}) do local group={['until']=kind,conditions={speed()}}; C.validate(group,nick); eq(C.check(nick,group),true) end
-- Real runtime argument allowlist accepts the direct wait and all lane guard paths.
runtime.scheduler_api.check_args('wait_until',speed{for_s=1,max_age=1})
for _,lane in ipairs({'body','remote','platform:Asterion'}) do
  local a={dry_run=true,steps={{action='wait_until',args=speed{for_s=1}}},guards={{when=speed(),steps={{action='wait_ticks',args={ticks=10}}}}}}
  if lane~='body' then a.lane=lane end
  eq(call('queue_submit',a).dry_run,true)
end
-- A guard fires once, runs recovery, exposes its measured value/tick, and leaves the route and watch intact.
local route={records={}}; pl.schedule=route
local watch={status='watching'}; storage.agent_harness.flightwatch={batch415=watch}
local configured=0
local api={}; for k,v in pairs(runtime.scheduler_api) do api[k]=v end
api.queue_key='batch415_queue'; api.handlers={configure=function(_,args) eq(args.description,'T60'); configured=configured+1; return {configured=true} end}
api.stop=function() end
local Q=require('scheduler')(api)
Q.handlers.queue_submit(nick,{steps={{action='wait_ticks',args={ticks=600}}},guards={{when=speed{for_s=1},steps={{action='configure',args={platform='Asterion',position={x=0,y=0},description='T60'}}}}}})
for t=230,280,10 do game.tick=t; Q.tick() end
local status=Q.handlers.queue_status(nick,{})
eq(status.guards[1].evidence.speed_kms,40.3); eq(status.guards[1].evidence.tick,280)
-- #2870: a zero/starved reading leaves the guard armed, without a guard_error, and restarts duration.
pl.speed=0; game.tick=290; Q.tick(); eq(configured,0)
status=Q.handlers.queue_status(nick,{})
eq(status.guards[1].evidence.speed_kms,0); eq(status.guards[1].evidence.source,'LuaSpacePlatform.speed')
eq(status.guards[1].read_error,nil)
pl.speed=-0.003368769996856992; game.tick=300; Q.tick(); eq(configured,0)
eq(Q.handlers.queue_status(nick,{}).guards[1].read_error,nil)
pl.speed=40.3/60
for t=310,360,10 do game.tick=t; Q.tick(); eq(configured,0) end
game.tick=370; Q.tick(); eq(configured,1)
eq(pl.schedule,route); eq(storage.agent_harness.flightwatch.batch415,watch)
local found=false
for _,h in ipairs(Q.handlers.queue_status(nick,{recent=64}).history) do
  assert(h.action~='guard_error')
  if h.action=='guard' then eq(h.result.evidence.speed_kms,40.3); eq(h.result.evidence.since_tick,310); found=true end
end
assert(found)
print('d33_batch415: shared schedule wait validation, recovery atomicity, speed duration/freshness/evidence and recovery: ok')
