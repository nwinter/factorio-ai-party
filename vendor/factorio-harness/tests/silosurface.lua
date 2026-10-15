-- Run from repository root: lua tests/silosurface.lua
-- A silo on another planet by remote view (Astra 01:41, board #374: Sunward at Vulcanus, the silo at (14.5,140.5)
-- there ready with automatic requests off, "launch surface rejects"): launch, configure and silo take surface (a
-- planet) and position and act where our force sees the chunk; a chunk not seen is refused with that reason; the
-- reply reads the silo's switches back. Fake engine as tests/remotepassive.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,assembling_machine_input=21,assembling_machine_output=22,assembling_machine_modules=23,rocket_silo_rocket=11,rocket_silo_trash=12},build_mode={normal=1},build_check_type={manual=1},
  flow_precision_index={five_seconds=0,one_minute=1},rocket_silo_status={building_rocket=0,create_rocket=1,rocket_ready=7,launch_started=14},
  cargo_destination={invalid=0,orbit=1,station=2,surface=3,space_platform=4},space_platform_state={waiting_for_starter_pack=0,on_the_path=4,waiting_at_station=5}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={['calcite']={name='calcite',weight=2000}},utility_constants={rocket_lift_weight=1000000},entity={}}
-- Our force sees Vulcanus's chunk with the silo (a radar there), not the one at (400,400).
local force={name='player',chart=function() end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end,
  rockets_launched=3}
force.is_chunk_visible=function(s,c) return s.name=='nauvis' or not (c.x==12 and c.y==12) end
local surface={name='nauvis',index=1}
local vulcanus={name='vulcanus',index=3,valid=true,planet={name='vulcanus'}}
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=501,health=250,max_health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  c.can_reach_entity=function(e) return e.surface==c.surface end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
-- The silo on Vulcanus: 9x9 at (14.5,140.5), rocket ready, automatic requests off; one far away out of sight.
local function inventory(list)
  local t={valid=true}
  t.get_contents=function() local out={} for i,s in ipairs(list) do out[i]={name=s[1],count=s[2],quality='normal'} end return out end
  t.get_item_count=function() return 0 end
  t.is_empty=function() return #list==0 end
  return t
end
local cargo,trash={},{}
local launched
local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=14.5,y=140.5},force=force,surface=vulcanus,unit_number=77,
  use_transitional_requests=false,send_to_orbit_automatically=false,rocket_silo_status=7,rocket_parts=50,
  prototype={rocket_parts_required=50},status=1}
silo.get_inventory=function(i) if i==11 then return inventory(cargo) end if i==12 then return inventory(trash) end end
silo.launch_rocket=function(d) launched=d; return true end
local far={valid=true,name='rocket-silo',type='rocket-silo',position={x=400.5,y=400.5},force=force,surface=vulcanus,unit_number=78,prototype={rocket_parts_required=50}}
-- Astra 02:20 (board #377): a requester chest at (5.5,135.5) on Vulcanus feeding the assembler at (2.5,135.5).
local slots={}
local section={index=1,is_manual=true,group='',active=true}
section.filters_count=0
section.get_slot=function(i) return slots[i] end
section.set_slot=function(i,v) slots[i]=v; section.filters_count=math.max(section.filters_count,i) end
section.clear_slot=function(i) slots[i]=nil end
setmetatable(section,{__index=function(_,k) if k=='filters' then local out={} for i=1,section.filters_count do if slots[i] then out[#out+1]=slots[i] end end return out end end})
local requester={valid=true,name='requester-chest',type='logistic-container',position={x=5.5,y=135.5},force=force,surface=vulcanus,unit_number=81,half=0.5}
requester.get_logistic_sections=function() return {sections_count=1,get_section=function(i) return i==1 and section or nil end,add_section=function() return section end} end
local recipe_now
local assembler={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=2.5,y=135.5},force=force,surface=vulcanus,unit_number=82,half=1.5,
  prototype={crafting_categories={crafting=true}},fluidbox={},crafting_progress=0}
assembler.get_recipe=function() return recipe_now and {name=recipe_now} or nil end
assembler.set_recipe=function(name) recipe_now=name; return {} end
force.recipes={['rocket-fuel']={name='rocket-fuel',enabled=true,category='crafting'}}
prototypes.item['solid-fuel']={name='solid-fuel'}; prototypes.item['light-oil']=nil
vulcanus.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs({silo,far,requester,assembler}) do
    local dx,dy=math.abs(e.position.x-(f.position and f.position.x or e.position.x)),math.abs(e.position.y-(f.position and f.position.y or e.position.y))
    local h=e.half or 4.5
    local inside=f.position==nil or (f.radius and dx*dx+dy*dy<=f.radius*f.radius) or (not f.radius and dx<h and dy<h)
    if inside and (not f.type or f.type==e.type) and (not f.name or f.name==e.name) then out[#out+1]=e end
  end
  return out
end
local hub={valid=true,name='space-platform-hub'}
local sunward={valid=true,name='Sunward',index=1,force=force,space_location={name='vulcanus'},state=5,hub=hub,surface={name='platform-1',valid=true}}
force.platforms={sunward}
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local players={nick}
for _,pl in ipairs(players) do pl.print=function() end end
local surfaces={nauvis=surface,vulcanus=vulcanus}
game={tick=0,players=players,surfaces=surfaces,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] or (n==1 and surface) or nil end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then error(result,0) end
  return result
end
runtime.operator.bot_create('astra')
local function astra(action,args) return request{action=action,args=args or {},bot='astra'} end
local body=runtime.bots.lookup(runtime.bots.index_of('astra')).character
body.can_reach_entity=function(e) return e.surface==body.surface end

-- configure: automatic requests on, by remote view on Vulcanus; the reply reads the switches back. The silo is
-- picked by any tile of it, as the cursor picks it.
local r=astra('configure',{surface='vulcanus',position={x=12,y=138},auto_requests=true})
eq(silo.use_transitional_requests,true); eq(r.settings.auto_requests,true); eq(r.settings.send_to_orbit_automatically,false)
eq(r.settings.silo,'rocket-silo at (14.5,140.5) on vulcanus'); eq(r.settings.state,'rocket_ready'); eq(r.settings.next_parts,'50/50'); eq(r.remote,true)
eq(r.settings.rocket_ready,true); eq(r.settings.rocket,"rocket built (50/50 parts) and ready to launch, not launched; parts for the rocket after it 50/50; no launch seen")
-- Send to orbit automatically, and automatic requests off again (auto_launch and planet run as those names).
r=astra('configure',{planet='vulcanus',position={x=14.5,y=140.5},auto_launch=true,auto_requests=false})
eq(silo.send_to_orbit_automatically,true); eq(silo.use_transitional_requests,false)
eq(r.settings.send_to_orbit_automatically,true); eq(r.settings.auto_requests,false)
assert(r.corrected:find('auto_launch is send_to_orbit_automatically',1,true) and r.corrected:find('planet is surface',1,true),r.corrected)
-- Switched on with cargo loaded by hand: the game moves it to trash; the note says so (launch's own rule).
cargo[1]={'calcite',500}
r=astra('configure',{surface='vulcanus',position={x=14.5,y=140.5},auto_requests=true})
eq(r.cargo_to_trash,'calcite*500'); assert(r.note:find('trash slots',1,true),r.note)
cargo[1]=nil; astra('configure',{surface='vulcanus',position={x=14.5,y=140.5},auto_requests=false})
-- A silo takes only its switches.
fails(function() astra('configure',{surface='vulcanus',position={x=14.5,y=140.5}}) end,'a rocket silo takes auto_requests and send_to_orbit_automatically')
fails(function() astra('configure',{surface='vulcanus',position={x=14.5,y=140.5},recipe='rocket-part'}) end,'its recipe is fixed')
-- A chunk our force does not see: refused with the reason.
fails(function() astra('configure',{surface='vulcanus',position={x=400.5,y=400.5},auto_requests=true}) end,
  'target must be in a visible chunk (remote view): (400.5,400.5) on vulcanus is not visible to our force now')
fails(function() astra('configure',{surface='vulcanus',position={x=60,y=60},auto_requests=true}) end,'no entity of ours at (60,60) on vulcanus')
fails(function() astra('launch',{surface='mars',position={x=14.5,y=140.5},orbit=true}) end,'no surface named mars')

-- launch: the switch alone, then to Sunward above Vulcanus (platform stays the destination); settings come back.
r=astra('launch',{surface='vulcanus',position={x=14.5,y=140.5},auto_requests=true})
eq(r.auto_requests,true); eq(r.settings.auto_requests,true)
astra('launch',{surface='vulcanus',position={x=14.5,y=140.5},auto_requests=false})
cargo[1]={'calcite',50}   -- (an empty rocket is refused unless allow_empty)
r=astra('launch',{surface='vulcanus',position={x=14.5,y=140.5},platform='Sunward'})
eq(r.launched,true); eq(r.to,'platform Sunward'); eq(launched.station,hub); eq(r.settings.silo,'rocket-silo at (14.5,140.5) on vulcanus')
cargo[1]=nil
fails(function() astra('launch',{surface='vulcanus',position={x=400.5,y=400.5},orbit=true}) end,'not visible to our force now')

-- silo: the read there, with both switches.
local s=astra('silo',{surface='vulcanus',position={x=14.5,y=140.5}})
eq(s.surface,'vulcanus'); eq(s.silos[1].auto_requests,false); eq(s.silos[1].send_to_orbit_automatically,true)

-- These calls by remote view leave the character's work alone (runtime.remote: surface= another surface).
local me=runtime.lookup(runtime.bots.index_of('astra'))
eq(runtime.remote(me,'launch',{surface='vulcanus'}),true); eq(runtime.remote(me,'configure',{surface='vulcanus'}),true)
-- describe lists surface for each.
local d=astra('describe').actions
assert(d.launch.surface and d.configure.surface and d.silo.surface and d.configure.send_to_orbit_automatically,'describe lists them')

-- requests by remote view on Vulcanus (Astra 02:20, board #377): set the requester's requests and read them back.
local rq=astra('requests',{surface='vulcanus',position={x=5.5,y=135.5},set={{item='solid-fuel',min=50}}})
eq(rq.target,'requester-chest at (5.5,135.5) on vulcanus'); eq(rq.sections[1].requests[1],'solid-fuel 50..inf'); eq(rq.changed_section,1)
eq(slots[1].value.name,'solid-fuel'); eq(slots[1].min,50)
-- A read alone (planet runs as surface), and clear.
rq=astra('requests',{planet='vulcanus',position={x=5.5,y=135.5}})
eq(rq.sections[1].requests[1],'solid-fuel 50..inf'); assert(rq.corrected:find('planet is surface',1,true),rq.corrected)
rq=astra('requests',{surface='vulcanus',position={x=5.5,y=135.5},clear={'solid-fuel'}})
eq(#rq.sections[1].requests,0)
-- Never the character's own requests on another surface; an unseen chunk is refused as for the silo.
fails(function() astra('requests',{surface='vulcanus',set={{item='solid-fuel',min=5}}}) end,'requests with surface needs position')
fails(function() astra('requests',{surface='vulcanus',position={x=400.5,y=400.5}}) end,'not visible to our force now')
assert(astra('describe').actions.requests.surface,'describe lists requests surface')
-- configure's recipe on the assembler there, by remote view: an empty idle machine takes it; the reply says remote.
local cf=astra('configure',{surface='vulcanus',position={x=2.5,y=135.5},recipe='rocket-fuel'})
eq(cf.recipe,'rocket-fuel'); eq(cf.remote,true); eq(recipe_now,'rocket-fuel')
eq(astra('configure',{surface='vulcanus',position={x=2.5,y=135.5},recipe='rocket-fuel'}).unchanged,true)
-- Mid-craft it is refused, as any remote recipe change.
recipe_now=nil; assembler.crafting_progress=0.4
fails(function() astra('configure',{surface='vulcanus',position={x=2.5,y=135.5},recipe='rocket-fuel'}) end,'remote recipe change')
assembler.crafting_progress=0
-- friction6: position traces select the named surface, including while aboard.
do
  local b=runtime.bots.record(runtime.bots.index_of('astra'))
  local saved=b.character
  prototypes.entity.character={name='character',type='character'}
  prototypes.space_location={vulcanus={}}
  b.character=nil; b.surface='platform-1'; b.position={x=0,y=0}; surfaces['platform-1']=sunward.surface
  b.travel={state='aboard',platform='Sunward',platform_index=1}
  sunward.surface.platform=sunward; hub.position={x=0,y=0}; hub.surface=sunward.surface
  sunward.surface.find_entities_filtered=function() return {} end
  local r=astra('observe',{radius=1,limit=1,exclude_resources=true,entity_types={'character'},peek=true})
  eq(r.player.body,'none'); eq(r.player.surface,'platform-1'); eq(r.player.inventory,nil); eq(r.player.health,nil)
  local plan=astra('queue_submit',{start=false,steps={{action='wait_until',args={['until']='platform_arrived',platform='Sunward',location='vulcanus'}},
    {action='drop',args={platform='Sunward',items={['solid-fuel']=1}}}}})
  eq(plan.pending_count,2)
  fails(function() astra('queue_submit',{steps={{action='craft',args={recipe='rocket-fuel'}}}}) end,'steps[1] (craft)')
  eq(astra('queue_status',{}).pending_count,2)
  astra('queue_cancel',{})
  -- A remote configure genuinely reaches its handler (a planet and a platform).
  r=astra('configure',{surface='vulcanus',position=silo.position,auto_requests=true})
  eq(r.settings.auto_requests,true)
  local find=sunward.surface.find_entities_filtered
  sunward.surface.find_entities_filtered=function() return {assembler} end
  recipe_now=nil
  r=astra('configure',{platform='Sunward',position=assembler.position,recipe='rocket-fuel'})
  eq(r.recipe,'rocket-fuel')
  sunward.surface.find_entities_filtered=find
  -- Trace's handler sees a proxy on the target surface; no body required.
  local trace=runtime.trace.trace
  local called=0
  runtime.trace.trace=function(p,a) called=called+1; eq(p.surface,vulcanus); eq(a.surface,nil); return {surface=p.surface.name} end
  r=astra('trace',{surface='vulcanus',position=assembler.position}); eq(r.surface,'vulcanus'); eq(called,1)
  fails(function() astra('trace',{surface='vulcanus',platform='Sunward',position=assembler.position}) end,'give platform or surface, not both')
  runtime.trace.trace=trace
  b.character=saved; b.travel=nil
end

print('silosurface: ok')
-- Explicit remote calls never ask character reach across surfaces or enter autowalk.
do
  local b=runtime.bots.record(runtime.bots.index_of('astra'))
  local saved=b.character
  local old_reach,old_insert=saved.can_reach_entity,saved.insert
  saved.can_reach_entity=function(e) assert(e.surface==saved.surface,'LuaEntity belongs to another surface'); return old_reach(e) end
  saved.insert=function() error('remote recipe touched the body inventory') end
  local old_find=sunward.surface.find_entities_filtered
  sunward.surface.find_entities_filtered=function() return {assembler} end
  local old_surface,old_pos=assembler.surface,assembler.position
  assembler.surface=sunward.surface; assembler.position={x=4.5,y=6.5}
  local active={kind='walk',direction=4,until_tick=game.tick+500}
  storage.agent_harness.active[b.index]=active
  recipe_now=nil
  local r=astra('configure',{platform='Sunward',position=assembler.position,recipe='rocket-fuel',walk=true})
  eq(r.remote,true); eq(r.recipe,'rocket-fuel'); eq(storage.agent_harness.active[b.index],active)
  recipe_now=nil; assembler.crafting_progress=0.4
  fails(function() astra('configure',{platform='Sunward',position=assembler.position,recipe='rocket-fuel',walk=true}) end,'crafting progress is 0.4')
  eq(storage.agent_harness.active[b.index],active); eq(recipe_now,nil)
  assembler.crafting_progress=0
  local items=true
  local modules=false
  assembler.get_inventory=function(i) return {valid=true,is_empty=function() return not (i==23 and modules or i~=23 and items) end} end
  fails(function() astra('configure',{platform='Sunward',position=assembler.position,recipe='rocket-fuel'}) end,'assembling_machine_input holds items')
  eq(storage.agent_harness.active[b.index],active); items=false; modules=true
  -- Modules the new recipe allows stay (Astra, shift17 10:50: an idle crusher with efficiency modules was refused; a
  -- private 2.0.77 server: set_recipe keeps them): the remote change goes through.
  local slots={{valid_for_read=true,name='efficiency-module'},{valid_for_read=false}}
  assembler.get_module_inventory=function() return slots end
  local saved_items,saved_recipe=prototypes.item,prototypes.recipe
  prototypes.item=setmetatable({['efficiency-module']={category='efficiency',module_effects={consumption=-0.3}},
    ['productivity-module']={category='productivity',module_effects={productivity=0.04,consumption=0.4,speed=-0.05}}},{__index=saved_items})
  prototypes.recipe=setmetatable({['rocket-fuel']={allowed_effects={consumption=true,speed=true,productivity=false,quality=true,pollution=true}}},{__index=saved_recipe})
  r=astra('configure',{platform='Sunward',position=assembler.position,recipe='rocket-fuel'})
  eq(r.remote,true); eq(recipe_now,'rocket-fuel'); recipe_now=nil
  -- One the recipe forbids would come out: refused, naming it, its slot and the slot change that empties it.
  slots[2]={valid_for_read=true,name='productivity-module'}
  fails(function() astra('configure',{platform='Sunward',position=assembler.position,recipe='rocket-fuel'}) end,
    'productivity-module in module slot 2 (productivity is not allowed with rocket-fuel)')
  fails(function() astra('configure',{platform='Sunward',position=assembler.position,recipe='rocket-fuel'}) end,'configure modules {"2":"empty"}')
  eq(recipe_now,nil); modules=false
  assembler.get_module_inventory=nil; prototypes.item,prototypes.recipe=saved_items,saved_recipe
  b.character=nil; b.surface='platform-1'; b.position={x=0,y=0}
  b.travel={state='aboard',platform='Sunward',platform_index=1}
  r=astra('configure',{position=assembler.position,recipe='rocket-fuel'})
  eq(r.remote,true); eq(recipe_now,'rocket-fuel')
  recipe_now=nil; assembler.surface=old_surface; assembler.position=old_pos
  r=astra('configure',{surface='vulcanus',position=assembler.position,recipe='rocket-fuel'})
  eq(r.remote,true); eq(recipe_now,'rocket-fuel')
  recipe_now=nil; items=true
  fails(function() astra('configure',{surface='vulcanus',position=assembler.position,recipe='rocket-fuel',walk=true}) end,'assembling_machine_input holds items')
  b.character=saved; b.travel=nil; b.surface='nauvis'
  saved.can_reach_entity=old_reach; saved.insert=old_insert
  assembler.get_inventory=nil; sunward.surface.find_entities_filtered=old_find
  storage.agent_harness.active[b.index]=nil
end

-- Preflight's platform is the destination even with a remote planet; no-position discovery uses the census index.
local old_find=vulcanus.find_entities_filtered
vulcanus.find_entities_filtered=function(f) assert(f.position, 'preflight never scans a whole surface'); return old_find(f) end
r=astra('preflight',{surface='vulcanus',platform='Sunward',position=silo.position})
eq(r.platform.name,'Sunward'); eq(r.platform.arrived,true); eq(r.built_parts,'50/50'); eq(r.position.x,14.5)
storage.agent_harness.census={done={start=99,silos={[3]={far,silo}}}}
r=astra('preflight',{surface='vulcanus',platform='Sunward'})
eq(#r.silos,1,'hidden silo omitted'); eq(r.silos[1].position.x,14.5); eq(r.silos_as_of,99)
fails(function() astra('preflight',{surface='vulcanus',platform='Sunward',position=far.position}) end,'not visible')
vulcanus.find_entities_filtered=old_find
print('preflight remote surface: ok')

-- The runtime adapters carry round2250b diagnostics alongside dispatch ETA and discovery, with surface+platform.
local old_ammo,old_incoming=runtime.freight.ammo,runtime.freight.incoming
runtime.freight.ammo=function(pl) eq(pl,sunward); return {'ammo reserve'} end
runtime.freight.incoming=function(pl) eq(pl,sunward); return {rockets=1,cargo='calcite*20',lines={'incoming calcite'}} end
defines.inventory.hub_main=13
hub.get_inventory=function(id)
  if id==13 then return {{valid_for_read=true,name='metallic-asteroid-chunk'},get_contents=function() return {} end} end
end
r=astra('preflight',{surface='vulcanus',platform='Sunward'})
eq(r.silos[1].platform.eta_s,0); eq(r.silos[1].platform.incoming_cargo,'1 rocket on the way: calcite*20')
eq(r.silos[1].platform.ammo_rates[1],'ammo reserve')
eq(r.silos[1].platform.hub_chunks,'asteroid chunks take 1 of 1 slots (metallic 1)')
assert(r.line:find('arrived',1,true) and r.line:find('1 rocket on the way',1,true),r.line)
runtime.freight.ammo,runtime.freight.incoming=old_ammo,old_incoming
print('preflight merged destination diagnostics: ok')
