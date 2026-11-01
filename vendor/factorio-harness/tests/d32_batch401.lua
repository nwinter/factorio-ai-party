-- Run from vendor/factorio-harness: lua tests/d32_batch401.lua
-- Sol #2856: queued uptime item prototypes are checked before any step runs.
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

prototypes={item={['iron-ore']={}},fluid={water={}},quality={normal={}}}
local stats={get_input_count=function() return 0 end,get_output_count=function() return 0 end,get_flow_count=function() return 0 end}
force.get_item_production_statistics=function() return stats end
defines.flow_precision_index.ten_minutes=2
game.surfaces=surfaces
prototypes.item.coal={}
prototypes.quality.rare={}
local function has(s,part) assert(tostring(s):find(part,1,true),tostring(s)..' lacks '..part) end
local function refused(fn,...)
  local ok,err=pcall(fn)
  assert(not ok,'expected refusal')
  for _,part in ipairs({...}) do has(err,part) end
  return tostring(err)
end
local function call(action,args) return runtime.dispatch{action=action,args=args,player=1} end
local function plan(items,dry)
  return call('queue_submit',{dry_run=dry,steps={{action='uptime',args={items=items,seconds=300}}}})
end
local U=runtime.uptime
local reads=0
force.get_item_production_statistics=function() reads=reads+1; return stats end
local function invalid(items,entry,reason)
  for _,dry in ipairs({true,false}) do
    refused(function() plan(items,dry) end,'steps[1] (uptime): args: items['..entry..']',reason)
  end
  -- Execution and queue validation use the same refusal, before reading statistics or replacing a watch.
  local before=storage.agent_harness.uptime and storage.agent_harness.uptime[1]
  local before_reads=reads
  local direct=refused(function() U.handler(nick,{items=items,seconds=300}) end,'items['..entry..']',reason)
  local queued=refused(function() plan(items,true) end)
  has(queued,direct:gsub('^[^:]*:%d+: ',''))
  eq(reads,before_reads)
  eq(storage.agent_harness.uptime and storage.agent_harness.uptime[1],before)
end
invalid({'water'},1,'water is not an item (fluid prototype)')
invalid({'batch401-missing-item'},1,'batch401-missing-item is not an item (unknown item name)')
invalid({'iron-ore','water','coal'},2,'fluid prototype')
invalid({'iron-ore',{name='water',quality='normal'}},2,'fluid prototype')
invalid({'iron-ore',{name='batch401-missing-item'}},2,'unknown item name')
invalid({{name='iron-ore',quality='batch401-missing-quality'}},1,'.quality: batch401-missing-quality is not a quality')
invalid({{quality='normal'}},1,'nil is not an item')
invalid({false},1,'false is not an item')
for _,items in ipairs({{'iron-ore'},{{name='iron-ore',quality='rare'}},{'iron-ore',{name='coal',quality='normal'}}}) do
  local before_reads=reads
  runtime.scheduler_api.check_args('uptime',{items=items,seconds=300})
  eq(reads,before_reads,'validation reads no statistics')
  local dry=plan(items,true)
  eq(dry.dry_run,true); eq(dry.queued,false); eq(dry.steps,1)
  local watch=U.handler(nick,{items=items,seconds=300})
  eq(watch.watching,true)
end
-- Invalid mixed lists leave the existing watch intact too.
invalid({'coal','water'},2,'fluid prototype')
refused(function() plan({},true) end,'items: 1..8 items')
refused(function() plan('iron-ore',true) end,'items: 1..8 items')
local eight={}; for i=1,8 do eight[i]='iron-ore' end
eq(plan(eight,true).steps,1)
eight[9]='iron-ore'
refused(function() plan(eight,true) end,'items: 1..8 items')
eq(call('queue_submit',{dry_run=true,steps={{action='uptime',args={}},{action='uptime',args={read=true}}}}).steps,2)
refused(function() call('queue_submit',{dry_run=true,steps={{action='uptime',args={read=true,items={'water'}}}}}) end,'items goes with a new watch')

-- A 28-step plan: no earlier step runs or replaces the current watch when step 17 is invalid.
local steps={}
for i=1,28 do steps[i]={action='uptime',args={items={'iron-ore'},seconds=300}} end
steps[17]={action='uptime',label='baseline',args={items={'iron-ore','water'},seconds=300}}
local calls=0
local handler=U.handler
U.handler=function(...) calls=calls+1; return handler(...) end
local scheduler=require('scheduler')(runtime.scheduler_api)
local before=storage.agent_harness.uptime[1]
for _,dry in ipairs({true,false}) do
  refused(function() call('queue_submit',{dry_run=dry,mode='replace',steps=steps}) end,
    'steps[17] (uptime, label "baseline"): args: items[2]: water is not an item (fluid prototype)')
  for i=1,3 do game.tick=game.tick+1; scheduler.tick() end
  eq(calls,0); eq(storage.agent_harness.uptime[1],before)
  local q=storage.agent_harness.queues[1]
  eq(#q.pending,0); eq(q.current,nil); eq(#q.history,0)
end
-- Platform lanes use the same validation, including nested guard steps.
force.platforms={{valid=true,name='Asterion'}}
for _,step in ipairs(steps) do step.args.platform='Asterion' end
for _,dry in ipairs({true,false}) do
  refused(function() call('queue_submit',{lane='platform:Asterion',dry_run=dry,steps=steps}) end,
    'steps[17]','items[2]','fluid prototype')
end
refused(function() call('queue_submit',{dry_run=true,steps={{action='wait_ticks',args={ticks=60}}},
  guards={{when={['until']='tick_at_least',tick=600},steps={steps[17]}}}}) end,
  'guards[1]: steps[1]','items[2]','fluid prototype')
-- Corrected 28-step plan validates; a valid submitted body step actually executes in the same scheduler.
steps[17].args.items={'iron-ore'}
eq(call('queue_submit',{lane='platform:Asterion',dry_run=true,steps=steps}).steps,28)
plan({'iron-ore'},false)
game.tick=game.tick+1; scheduler.tick()
eq(calls,1)
print('d32_batch401: shared uptime item/quality validation, step 17 atomic refusal, platform and guard paths: ok')
