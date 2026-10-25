-- Run from repository root: lua tests/d25_batch200b.lua
-- d25 batch200 QM2 (Astra #2313: queue dry_run took platform_defense {asteroids, seconds: 3600}; the job then refused
-- it, 10..1800): every queue step's numeric arguments are checked at submit and in dry_run against the ranges the action
-- takes when it runs (runtime.lua step_ranges), naming the step, the argument, the value and the range.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
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
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local astra,sol,luna,opus=as('astra'),as('sol'),as('luna'),as('opus')
local names={'astra','sol','luna','opus','kai','grok','mira'}
for _,n in ipairs(names) do runtime.operator.bot_create(n) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,'should be refused'); return tostring(err) end
local function not_ranged(fn) local ok,err=pcall(fn); assert(ok or not tostring(err):find('takes when it runs',1,true),tostring(err)) end
local function plan(steps,dry) return function() return astra('queue_submit',{dry_run=dry,steps=steps}) end end
-- Astra's step: refused in the dry run and at submit, the step named
local pd={action='platform_defense',label='asteroids',args={platform='Peregrine',asteroids=true,seconds=3600}}
local e=refused(plan({{action='wait_ticks',args={ticks=60}},pd},true))
has(e,'steps[2] (platform_defense, label "asteroids")'); has(e,'seconds 3600 is outside 10..1800 (a whole number), what platform_defense takes when it runs')
has(refused(plan({pd})),'seconds 3600 is outside 10..1800')
-- the range is the watch module's own (asteroidwatch.SECONDS), and applies with asteroids only
eq(runtime.asteroidwatch.SECONDS[1],10); eq(runtime.asteroidwatch.SECONDS[2],1800)
not_ranged(plan({{action='platform_defense',args={platform='Peregrine',asteroids=true,seconds=1800}}},true))
-- the other watches: a new watch's seconds; a read of one (no positions) is left as the action takes it
has(refused(plan({{action='uptime',args={positions={{x=0,y=0}},seconds=5000}}},true)),'seconds 5000 is outside 10..3600')
not_ranged(plan({{action='uptime',args={positions={{x=0,y=0}},seconds=3600}}},true))
not_ranged(plan({{action='uptime',args={seconds=5000}}},true))
has(refused(plan({{action='turret_tally',args={positions={{x=0,y=0}},seconds=4}}},true)),'seconds 4 is outside 5..3600')
has(refused(plan({{action='belt_flow',args={position={x=0,y=0},seconds=31}}},true)),'seconds 31 is outside 2..30')
has(refused(plan({{action='platform_supply',args={platform='Peregrine',collection=true,seconds=3601}}},true)),'seconds 3601 is outside 10..3600')
has(refused(plan({{action='signal_watch',args={position={x=0,y=0},seconds=9}}},true)),'seconds 9 is outside 10..3600')
-- action ranges: whole numbers, the widest of an action's modes, a mode's own key only with it
has(refused(plan({{action='feed',args={item='coal',count=1001}}},true)),'count 1001 is outside 1..1000')
has(refused(plan({{action='feed',args={item='coal',count=2.5}}},true)),'count 2.5 is outside 1..1000 (a whole number)')
has(refused(plan({{action='move_to',args={position={x=0,y=0},tolerance=11}}},true)),'tolerance 11 is outside 0.25..10, what move_to takes')
not_ranged(plan({{action='move_to',args={position={x=0,y=0},tolerance=0.3}}},true))
not_ranged(plan({{action='collect',args={ticks=72000}}},true))
has(refused(plan({{action='collect',args={ticks=72001}}},true)),'ticks 72001 is outside 1..72000')
not_ranged(plan({{action='rearm',args={retry_ticks=100}}},true))
has(refused(plan({{action='rearm',args={retry_when_clear=true,retry_ticks=100}}},true)),'retry_ticks 100 is outside 600..54000')
-- another type is the action's own to read (move_to combat: true)
not_ranged(plan({{action='move_to',args={position={x=0,y=0},combat=true}}},true))
-- every listed key is an argument its action takes
local acts=astra('describe',{}).actions
for action,list in pairs(runtime.step_ranges) do
  assert(acts[action],'step_ranges: no action '..action)
  for _,r in ipairs(list) do assert(acts[action][r[1]]~=nil,'step_ranges: '..action..' takes no '..r[1]) end
end
print('d25_batch200b QM2 queue step ranges: ok')
