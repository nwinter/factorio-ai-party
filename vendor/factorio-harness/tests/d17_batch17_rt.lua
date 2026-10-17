-- Run from the harness root: lua tests/d17_batch17_rt.lua
-- d17 batch17 through the runtime against a fake engine (the scaffold of tests/d16_batch7_rt.lua).
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

-- A1 (Astra and Sol d17 10:50: a short rescue load turned the silo's automatic requests back on and the next scarce
-- rocket went up with one gun turret): a paused load that ends without its launch leaves them off, and says so.
do
  local index=runtime.bots.index_of('sol')
  local silo={valid=true,name='rocket-silo',type='rocket-silo',unit_number=4242,position={x=65.5,y=14.5},use_transitional_requests=false}
  runtime.silo_pauses()[4242]={by=index,who='sol',tick=game.tick,left=1,silo=silo,where='rocket-silo (65.5,14.5)'}
  storage.agent_harness.active[index]={kind='load_silo',op='load_silo',handler='load_silo',until_tick=game.tick+600,queued=false}
  runtime.stop_player(index,'failed')
  eq(silo.use_transitional_requests,false,'off stays off')
  eq(runtime.silo_pauses()[4242],nil,'the pause record ends')
  local last=storage.agent_harness.last[index]
  assert(last and last.auto_requests_kept_off and last.auto_requests_kept_off:find('automatic requests of rocket-silo (65.5,14.5) stay off (the load ended failed; configure {auto_requests: true} turns them on)',1,true),
    tostring(last and last.auto_requests_kept_off))
  eq(last.auto_requests_back,nil)
  -- a refused call (nothing loaded) still puts them back
  runtime.silo_pauses()[4242]={by=index,who='sol',tick=game.tick,left=1,silo=silo,where='rocket-silo (65.5,14.5)'}
  local line=runtime.silo_unpause(index,'the load was refused')
  eq(silo.use_transitional_requests,true); assert(line:find('back on (the load was refused)',1,true),line)
end
print('d17_batch17_rt A1 a short paused load leaves automatic requests off: ok')

-- A2 (Grok 2x on Gleba): when Swift stopped, the game launched the rocket itself (one item type a rocket: bioflux*40
-- went, the 500 packs stayed), and the launch wait read launch_started as launch_failed. It says what went and stayed.
do
  local index=runtime.bots.index_of('grok')
  defines.inventory=defines.inventory or {}; defines.inventory.rocket_silo_rocket=21
  local cargo={get_contents=function() return {{name='agricultural-science-pack',quality='normal',count=500}} end}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',unit_number=777,force=force,surface=surface,position={x=65.5,y=14.5},
    get_inventory=function(i) if i==21 then return cargo end end,bounding_box={left_top={x=61,y=10},right_bottom={x=70,y=19}}}
  local was=surface.find_entities_filtered
  surface.find_entities_filtered=function(f) return {silo} end
  jump(60)
  runtime.silo.record(silo,{cargo='bioflux*40',to='platform Swift',ordered=true})
  local g=runtime.game_launched(index,{then_launch={position={x=65.5,y=14.5},platform='Swift'},start_tick=game.tick-30})
  assert(g and g.by_game,'the game launched it')
  assert(g.line:find('with bioflux*40',1,true) and g.line:find('still in the silo for the next rocket: agricultural-science-pack*500',1,true),g.line)
  -- our own launch (by set) or one before the wait began is not the game's
  local h=runtime.game_launched(index,{then_launch={position={x=65.5,y=14.5}},start_tick=game.tick+10})
  eq(h,nil)
  surface.find_entities_filtered=was
end
print('d17_batch17_rt A2 a launch the game made first is said as such: ok')

-- A2/A3: load_silo {wait_platform} stages nothing in a ready rocket: it is the load with launch and platform, which
-- loads nothing while the platform is on its way and loads and launches in the tick it is in orbit.
do
  local seen
  local real=runtime.rocketload.load
  runtime.rocketload.load=function(p,a) seen=a; return {wait=true,platform=true,why='platform Swift is flying nauvis->gleba 26%, headed to gleba: nothing is loaded until it is in orbit there'} end
  local silo={valid=true,name='rocket-silo',type='rocket-silo',unit_number=778,force=force,surface=surface,position={x=65.5,y=14.5},
    bounding_box={left_top={x=61,y=10},right_bottom={x=70,y=19}},rocket_silo_status=defines.rocket_silo_status and defines.rocket_silo_status.rocket_ready}
  local was=surface.find_entities_filtered
  surface.find_entities_filtered=function(f) return {silo} end
  local gp=runtime.lookup(runtime.bots.index_of('grok'))
  gp.character.position={x=60,y=14}
  local ok,r=pcall(grok,'load_silo',{position={x=65.5,y=14.5},items={['agricultural-science-pack']=500,bioflux=40},launch=true,platform='Swift',wait_platform=true})
  surface.find_entities_filtered=was
  runtime.rocketload.load=real
  assert(seen,'the load ran: '..tostring(r))
  eq(seen.wait_platform,nil); eq(seen.launch,true); eq(seen.platform,'Swift')
  assert(ok and type(r)=='table',tostring(r))
  assert(r.wait_platform and r.wait_platform:find('nothing goes into the rocket until Swift is stopped in orbit here',1,true),tostring(r.wait_platform))
  grok('stop',{})
end
print('d17_batch17_rt A2/A3 wait_platform stages nothing ahead of the platform: ok')

-- A5: platform_schedule takes a condition as circuit_set does and gives the game its form; a circuit wait on a hub with
-- no wire says the hub has none.
do
  prototypes=prototypes or {}
  prototypes.item=prototypes.item or {}; prototypes.item['iron-plate']=prototypes.item['iron-plate'] or {name='iron-plate'}
  prototypes.fluid={['thruster-fuel']={name='thruster-fuel'}}
  prototypes.virtual_signal={['signal-A']={name='signal-A'}}
  prototypes.space_location={nauvis={},gleba={}}
  defines.wire_connector_id={circuit_red=1,circuit_green=2}
  local hub={valid=true,position={x=0,y=0},get_circuit_network=function() return nil end}
  local swift={valid=true,name='Swift',index=3,hub=hub,state=6,space_location={name='nauvis'},surface={name='platform-3'},force=force}
  force.platforms={swift}
  local ok,r=pcall(grok,'platform_schedule',{platform='Swift',stops={{station='nauvis',wait={{type='time',ticks=216000},
    {type='circuit',condition='thruster-fuel >= 10000',compare='and'}}},{station='gleba',wait={{type='item_count',condition={signal='iron-plate',comparator='>=',value=50}}}}}})
  assert(ok,tostring(r))
  local w=swift.schedule.records[1].wait_conditions[2]
  eq(w.type,'circuit'); eq(w.condition.first_signal.type,'fluid'); eq(w.condition.first_signal.name,'thruster-fuel')
  eq(w.condition.comparator,'>='); eq(w.condition.constant,10000)
  eq(swift.schedule.records[2].wait_conditions[1].condition.first_signal.type,'item')
  assert(r.circuit_note and r.circuit_note:find("the hub has none",1,true),tostring(r.circuit_note))
  -- item_count with a fluid signal: refused, naming the form
  fails(function() grok('platform_schedule',{platform='Swift',stops={{station='nauvis',wait={{type='item_count',condition='thruster-fuel >= 1'}}}}}) end,
    'item_count takes an item signal')
  force.platforms=nil
end
print('d17_batch17_rt A5 platform_schedule conditions: ok')

-- B3 (Opus on the far-east route: no_safe_route for a roaming group, a lone big biter and an attack where he stood;
-- he died standing where one such walk ended): a route given up only for enemies that move waits 5 s and plans again,
-- up to 6 times; a worm or spawner in the way ends it as before; a hit while it stands ends it.
do
  local gp=runtime.lookup(runtime.bots.index_of('grok'))
  local unit={attack=true,name='1 enemy unit (1 big-biter)',x=361,y=-209}
  local nav={foes={block={m=unit,bl={x=361,y=-209,members={unit}}}}}
  assert(runtime.avoid.moving_only(nav),'units only')
  eq(runtime.unit_wait(gp,nav),true); eq(nav.path_state,'waiting_units'); eq(nav.unit_waits,1)
  assert(nav.waited_for_units:find('stood and planned again 1 time, 5 s apart',1,true),nav.waited_for_units)
  for _=2,6 do runtime.unit_wait(gp,nav) end
  eq(nav.unit_waits,6); eq(runtime.unit_wait(gp,nav),false,'at most 6')
  local worm={name='big-worm-turret',x=312,y=-135,range=38}
  local nav2={foes={block={m=unit,bl={members={unit,worm}}}}}
  eq(runtime.avoid.moving_only(nav2),nil,'a worm in the group: as before')
  eq(runtime.unit_wait(gp,nav2),false)
end
print('d17_batch17_rt B3 a route blocked by moving enemies waits and plans again: ok')
