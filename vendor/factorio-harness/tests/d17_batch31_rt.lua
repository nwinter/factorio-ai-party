-- Run from the harness root: lua tests/d17_batch31_rt.lua
-- d17 batch31 through the runtime against a fake engine (the scaffold of tests/d16_batch7_rt.lua).
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

-- B7 (Gemini about 4 times: a silo's automatic requests loaded iron ore before foundation, collectors or ammo):
-- load_silo {position, platform, first}: those items at what the hub lacks, from the network's chests robots would
-- take from first, walked, launched, the automatic requests paused; a dry run pauses nothing.
do
  defines.inventory=defines.inventory or {}; defines.inventory.rocket_silo_rocket=21
  prototypes=prototypes or {}
  prototypes.item=prototypes.item or {}
  for _,n in ipairs({'space-platform-foundation','asteroid-collector','firearm-magazine','iron-ore'}) do prototypes.item[n]={name=n,weight=1000,stack_size=50} end
  local chest={valid=true,name='storage-chest',unit_number=31,position={x=70.5,y=20.5},get_item_count=function(n) return n=='space-platform-foundation' and 400 or 0 end}
  local net={select_pickup_point=function(f) if f.name=='space-platform-foundation' then return {owner=chest} end end}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',unit_number=779,force=force,surface=surface,position={x=65.5,y=14.5},use_transitional_requests=true,
    bounding_box={left_top={x=61,y=10},right_bottom={x=70,y=19}},get_inventory=function() return {get_contents=function() return {} end} end}
  local was,wasnet=surface.find_entities_filtered,surface.find_logistic_network_by_position
  surface.find_entities_filtered=function(f) return {silo} end
  surface.find_logistic_network_by_position=function() return net end
  local sec={active=true,filters={{value={name='space-platform-foundation'},min=100,import_from='nauvis'},{value={name='asteroid-collector'},min=2,import_from='nauvis'}}}
  local held={['space-platform-foundation']=20,['asteroid-collector']=2}
  local hub={valid=true,get_logistic_sections=function() return {sections_count=1,get_section=function() return sec end} end,get_item_count=function(n) return held[n] or 0 end}
  local swift={valid=true,name='Swift',index=3,hub=hub,state=6,space_location={name='nauvis'},surface={name='platform-3'},force=force}
  force.platforms={swift}
  local seen
  local real=runtime.rocketload.plan
  runtime.rocketload.plan=function(p,a) seen=a; return {dry_run=true,line='the plan'} end
  local gp=runtime.lookup(runtime.bots.index_of('grok'))
  gp.character.position={x=60,y=14}
  local ok,r=pcall(grok,'load_silo',{position={x=65.5,y=14.5},platform='Swift',first={'space-platform-foundation','asteroid-collector','firearm-magazine'},dry_run=true})
  runtime.rocketload.plan=real
  assert(ok,tostring(r))
  assert(seen,'the plan ran')
  eq(seen.items['space-platform-foundation'],80); eq(seen.items['asteroid-collector'],nil); eq(seen.walk,true); eq(seen.launch,true); eq(seen.platform,'Swift')
  eq(seen.from[1].x,70.5)
  eq(silo.use_transitional_requests,true,'a dry run pauses nothing')
  assert(r.first:find('rocket-silo first: space-platform-foundation 80 (what the hub lacks of its requests), launched to Swift with the silo\'s automatic requests paused (back on after the launch); from what you hold and the network\'s chests robots would take from first: storage-chest (70.5,20.5) holding 400 space-platform-foundation',1,true),r.first)
  eq(r.first_skipped[1],'asteroid-collector (the hub asks 2 and holds them)'); eq(r.first_skipped[2],'firearm-magazine (the hub does not request it)')
  assert(r.auto_requests and r.auto_requests:find('a dry run: nothing switched',1,true),tostring(r.auto_requests))
  -- counts given; refusals
  runtime.rocketload.plan=function(p,a) seen=a; return {dry_run=true} end
  grok('load_silo',{position={x=65.5,y=14.5},platform='Swift',first={['iron-ore']=50},dry_run=true})
  runtime.rocketload.plan=real
  eq(seen.items['iron-ore'],50)
  fails(function() grok('load_silo',{position={x=65.5,y=14.5},platform='Swift',first={'asteroid-collector'}}) end,'lacks none of them: asteroid-collector (the hub asks 2 and holds them)')
  fails(function() grok('load_silo',{position={x=65.5,y=14.5},platform='Swift',first={'iron-ore'},items={['iron-ore']=5}}) end,'first sets items, walk, launch and auto_requests itself')
  fails(function() grok('load_silo',{position={x=65.5,y=14.5},first={'iron-ore'}}) end,'first goes with platform')
  surface.find_entities_filtered,surface.find_logistic_network_by_position=was,wasnet
  force.platforms=nil
end
print('d17_batch31_rt B7 load_silo first: ok')

-- C1 (Sol: 10 rockets stranded among 214 belts on Kestrel III): scan with a belt type aggregates the belts' contents by
-- item, all of them before limit; with item it lists the belts holding it.
do
  prototypes.item.rocket={name='rocket'}; prototypes.item['iron-ore']=prototypes.item['iron-ore'] or {name='iron-ore'}
  local belts={}
  for i=1,30 do
    local held=i%10==0 and {{name='rocket',count=i//10}} or {{name='iron-ore',count=2}}
    belts[i]={valid=true,name='transport-belt',type='transport-belt',force=force,surface=surface,position={x=i+0.5,y=3.5},
      get_max_transport_line_index=function() return 2 end,
      get_transport_line=function(li) return {get_contents=function() return li==1 and held or {} end} end}
  end
  local was=surface.find_entities_filtered
  surface.find_entities_filtered=function(f) return belts end
  local r=grok('scan',{area={left_top={x=0,y=0},right_bottom={x=40,y=8}},type='transport-belt',item='rocket',limit=5})
  surface.find_entities_filtered=was
  eq(r.belt_items,'30 belts carry iron-ore*54 rocket*6')
  eq(r.belt_item.count,6); eq(r.belt_item.belts,3); eq(r.belt_item.positions[1].x,10.5)
  eq(r.belt_item.line,'6 rocket on 3 of 30 belts: (10.5,3.5) 1, (20.5,3.5) 2, (30.5,3.5) 3')
  eq(#r.entities,5,'the rows keep their limit; the aggregate counts all')
  fails(function() grok('scan',{area={left_top={x=0,y=0},right_bottom={x=40,y=8}},item='rockets'}) end,'item is an item name')
end
print('d17_batch31_rt C1 scan belts by item: ok')

-- C2 (Opus twice: a request cleared before its items arrived): a direct wait or a sleep that ends early lists the
-- personal requests still unfilled, with what is on the way.
do
  defines.logistic_member_index=defines.logistic_member_index or {character_requester=1}
  local index=runtime.bots.index_of('sol')
  local sp=runtime.lookup(index)
  local c=sp.character
  local net={network_id=7,all_logistic_robots=40,available_logistic_robots=12,get_item_count=function() return 300 end}
  c.get_logistic_point=function() return {filters={{name='repair-pack',count=100}},targeted_items_deliver={{name='repair-pack',count=40}},logistic_network=net,enabled=true} end
  c.items['repair-pack']=10
  storage.agent_harness.active[index]={kind='wait_ticks',until_tick=game.tick+600,start_tick=game.tick,queued=false}
  runtime.stop_player(index,'told')
  local last=storage.agent_harness.last[index]
  eq(last.outcome,'told')
  eq(last.personal_requests[1],'repair-pack: hold 10 of 100 (40 on the way); robots are bringing 40; network 7 holds 300 more')
  -- elapsed: none
  storage.agent_harness.active[index]={kind='wait_ticks',until_tick=game.tick+600,start_tick=game.tick,queued=false}
  runtime.stop_player(index,'duration_elapsed')
  eq(storage.agent_harness.last[index].personal_requests,nil)
  -- a sleep (waits.lua): woke told, read once
  local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return {sleeps={[index]={start_tick=game.tick,until_tick=game.tick+600,woke='told',out={woke='told',slept_s=3}}}} end,
    personal_unfilled=function(p) return runtime.personal_unfilled_lines(p) end}
  local r=W.handlers.sleep_check(sp,{})
  eq(r.personal_requests[1],'repair-pack: hold 10 of 100 (40 on the way); robots are bringing 40; network 7 holds 300 more')
  c.get_logistic_point=nil
end
print('d17_batch31_rt C2 an early wake lists unfilled personal requests: ok')
