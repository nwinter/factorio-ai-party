-- d20 batch62 X2. Run from the harness root: lua tests/d20_batch62b.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- The runtime against a fake engine (as tests/d17_batch35.lua sets it up), for the calls below.
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1},entity_status={no_power=1,low_power=2}}
prototypes={item={['submachine-gun']={type='gun',attack_parameters={ammo_categories={'bullet'},range=18}},
  ['rocket-launcher']={type='gun',attack_parameters={ammo_categories={'rocket'},range=36}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}},
  ['iron-plate']={type='item'}}}
local drawn={}
rendering={draw_text=function() local obj={valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',platforms={},get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,
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
surface.find_entities_filtered=function(f) return (f.type==nil or f.type=='electric-pole') and surface.poles or {} end
-- Fulgora, where Sol's network 301 is; Nauvis has network 2 (Sol #1529: Haiku's power {surface: fulgora} read Nauvis 2).
local fulgora={name='fulgora',index=4,valid=true,planet={name='fulgora'}}
fulgora.find_entities_filtered=function(f) return (f.type==nil or f.type=='electric-pole') and fulgora.poles or {} end
local function pole(s,id,pos)
  return {valid=true,name='small-electric-pole',type='electric-pole',position=pos,force=force,surface=s,electric_network_id=id,
    prototype={},electric_network_statistics={input_counts={},output_counts={},get_flow_count=function() return 0 end}}
end
surface.poles={pole(surface,2,{x=0.5,y=0.5})}
fulgora.poles={pole(fulgora,301,{x=-65.5,y=72.5})}
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(name) if name==nil or name=='nauvis' or name==1 then return surface end return name=='fulgora' and fulgora or nil end,
  surfaces={nauvis=surface,fulgora=fulgora},print=function() end,connected_players=players,
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

local function refused(action,args,text)
  local ok,err=pcall(sol,action,args)
  assert(not ok,action..' was not refused')
  has(err,text)
end

-- power reads the surface it is given, by remote view, round a place there; never the caller's silently.
local r=sol('power',{surface='fulgora',position={x=-65,y=72}})
eq(r.surface,'fulgora','power surface'); eq(#r.networks,1,'one network there'); eq(r.networks[1].id,301,'Fulgora network')
r=sol('power',{position={x=0,y=0}})
eq(r.surface,'nauvis','own surface'); eq(r.networks[1].id,2,'Nauvis network')
r=sol('power',{surface='nauvis',position={x=0,y=0}})
eq(r.networks[1].id,2,'own surface by name')
refused('power',{surface='fulgora'},'power with surface needs position or area there')
refused('power',{surface='nowhere',position={x=0,y=0}},'no surface named nowhere')

-- wait_until: surface and platform only on the conditions that read them.
refused('wait_until',{['until']='no_enemies',surface='fulgora',timeout=1},'surface applies to item_count, rocket_ready, rocket_parts, spoil_within, produced, ammo_below, fuel_below and fluid_count; no_enemies reads no other surface')
refused('wait_until',{['until']='crafting_done',platform='Swift',timeout=1},'crafting_done reads no platform')
refused('wait_until',{['until']='all',surface='fulgora',conditions={{['until']='crafting_done'}},timeout=1},'all reads no other surface')

-- A surface name that is no surface is refused, never read as yours or as an empty one.
refused('pods',{surface='nowhere'},'no surface named nowhere')
refused('demolishers',{surface='nowhere'},'no surface named nowhere')
refused('dependency',{item='iron-plate',surface='nowhere'},'no surface named nowhere')
refused('robot_losses',{surface='nowhere'},'no surface named nowhere')
refused('eggs',{surface='nowhere'},'no surface named nowhere')
refused('alerts_digest',{surface='nowhere'},'no surface named nowhere')
refused('game_alerts',{surface='nowhere'},'no surface named nowhere')

-- An argument that goes with another one is refused without it.
refused('shipment',{item='iron-plate',surface='nauvis'},'surface goes with ledger: true')
refused('board_review',{surface='nauvis'},'surface goes with ownership: true')
refused('uptime',{surface='fulgora'},'surface and platform go with positions, position, area or items')
refused('belt_flow',{platform='Swift'},'platform goes with position')

-- A platform name that is none of ours.
refused('platforms',{platform='Nowhere'},'no platform of ours named Nowhere; platforms: none')
refused('platform',{name='Nowhere'},'no platform of ours named Nowhere')
print('d20_batch62b ok')
