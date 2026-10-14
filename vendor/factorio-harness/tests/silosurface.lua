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
  inventory={chest=1,rocket_silo_rocket=11,rocket_silo_trash=12},build_mode={normal=1},build_check_type={manual=1},
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
vulcanus.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs({silo,far}) do
    local dx,dy=math.abs(e.position.x-(f.position and f.position.x or e.position.x)),math.abs(e.position.y-(f.position and f.position.y or e.position.y))
    local inside=f.position==nil or (f.radius and dx*dx+dy*dy<=f.radius*f.radius) or (not f.radius and dx<4.5 and dy<4.5)
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
eq(r.settings.silo,'rocket-silo at (14.5,140.5) on vulcanus'); eq(r.settings.rocket,'rocket_ready'); eq(r.settings.parts,'50/50'); eq(r.remote,true)
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
r=astra('launch',{surface='vulcanus',position={x=14.5,y=140.5},platform='Sunward'})
eq(r.launched,true); eq(r.to,'platform Sunward'); eq(launched.station,hub); eq(r.settings.silo,'rocket-silo at (14.5,140.5) on vulcanus')
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
print('silosurface: ok')
