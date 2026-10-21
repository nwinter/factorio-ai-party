-- d21 batch64 Z5 (#1635, Astra). Run from the harness root: lua tests/d21_batch64b.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- The runtime against a fake engine (as tests/d17_batch35.lua sets it up), for the calls below.
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1},entity_status={working=0,no_power=1,low_power=2,no_input_fluid=3,no_fuel=4}}
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
surface.things={}
local function typed(f,e)
  if f.type==nil then return true end
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if e.type==t then return true end end
  return false
end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(surface.poles) do if typed(f,e) then out[#out+1]=e end end
  for _,e in ipairs(surface.things) do if e.valid and typed(f,e) and (not f.force or e.force==f.force) then out[#out+1]=e end end
  return out
end
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

-- power on Nauvis at (7,-175) listed two working fusion generators making 56.974 MW with nameplate_kw 0: in 2.0.77 a
-- fusion generator's get_max_power_output is nil and its 50 MW (833333 J a tick) is get_max_energy_production.
prototypes.entity={['fusion-generator']={type='fusion-generator'},['steam-engine']={type='generator'},['solar-panel']={type='solar-panel'},
  accumulator={type='accumulator'},['lightning-collector']={type='lightning-attractor'},['fusion-reactor']={type='fusion-reactor'},
  ['heating-tower']={type='reactor'}}
local flows={['fusion-generator']=57e6/60,['solar-panel']=0.12e6/60,accumulator=0.3e6/60}
surface.poles[1].electric_network_statistics={input_counts={},output_counts={['fusion-generator']=1,['solar-panel']=1,accumulator=1},
  get_flow_count=function(t) if t.category=='output' then return flows[t.name] or 0 end return 0 end}
local q_mult={normal=1,legendary=2.5}
local function thing(name,typ,x,y,proto,extra)
  local e={valid=true,name=name,type=typ,position={x=x,y=y},force=force,surface=surface,electric_network_id=2,status=0,quality={name='normal'},prototype=proto}
  for k,v in pairs(extra or {}) do e[k]=v end
  surface.things[#surface.things+1]=e
  return e
end
local fusion={electric_energy_source_prototype={},get_max_power_output=function() return nil end,
  get_max_energy_production=function(q) return 833333.33333333*q_mult[q and q.name or 'normal'] end}
thing('fusion-generator','fusion-generator',3,-2,fusion)
thing('fusion-generator','fusion-generator',6,-2,fusion)
thing('fusion-generator','fusion-generator',9,-2,fusion,{quality={name='legendary'},status=3})
thing('steam-engine','generator',3,6,{electric_energy_source_prototype={},get_max_power_output=function() return 15000 end})
local panel={electric_energy_source_prototype={},get_max_energy_production=function() return 1000 end}
for i=1,3 do thing('solar-panel','solar-panel',-6,i*3,panel) end
local acc={electric_energy_source_prototype={get_output_flow_limit=function() return 5000 end},get_max_energy_production=function() return 5000 end}
thing('accumulator','accumulator',-3,-3,acc,{energy=2.5e6,electric_buffer_size=5e6})
thing('accumulator','accumulator',-3,-5,acc,{energy=0,electric_buffer_size=5e6})
thing('lightning-collector','lightning-attractor',-8,-8,{electric_energy_source_prototype={},get_max_energy_production=function() return 0 end},{energy=3e8})
thing('fusion-reactor','fusion-reactor',12,4,{electric_energy_source_prototype={}})
thing('heating-tower','reactor',12,-6,{},{status=4})

local r=sol('power',{position={x=0,y=0},radius=20})
local n=r.networks[1]
eq(n.id,2)
local g=n.generators
eq(g.count,4,'3 fusion generators and a steam engine')
eq(g.nameplate_kw,50000+50000+125000+900,'each at its most output, by quality')
eq(g.working_kw,100900,'the legendary one has no plasma')
eq(g.stopped_kw,125000)
eq(g.by_name[1].name,'fusion-generator'); eq(g.by_name[1].quality,'legendary'); eq(g.by_name[1].each_kw,125000); eq(g.by_name[1].working,0)
eq(g.by_name[2].name,'fusion-generator'); eq(g.by_name[2].quality,nil); eq(g.by_name[2].count,2); eq(g.by_name[2].each_kw,50000)
eq(g.by_name[2].max_kw,100000); eq(g.by_name[2].working,2); eq(g.by_name[2].network_output_kw,57000,'the network\'s output of that name, apart')
eq(g.by_name[3].name,'steam-engine'); eq(g.by_name[3].each_kw,900); eq(g.by_name[3].network_output_kw,nil)
has(n.supply_line,'generators in the area: 4 (fusion-generator (legendary) 1 x 125.0 MW = 125.0 MW, 0 working; fusion-generator 2 x 50.0 MW = 100.0 MW, 2 working; steam-engine 1 x 0.9 MW = 0.9 MW, 1 working), nameplate 225.9 MW; working now 100.9 MW')
has(n.supply_line,'stopped 125.0 MW (1 fusion-generator no_input_fluid)')
has(n.supply_line,'of it fusion-generator 57.0 MW')
eq(n.solar.count,3); eq(n.solar.full_sun_kw,180); eq(n.solar.network_output_kw,120)
has(n.solar_line,'solar panels in the area: 3, 0.2 MW at full sun here (solar power 100%); the network\'s panels produce 0.1 MW now')
eq(n.accumulators,2); eq(n.acc_holding,1); eq(n.acc_out_kw,300)
has(n.acc_line,'accumulators in the area: 2, 1 holding charge, giving up to 0.3 MW together; the network\'s accumulators give 0.3 MW now')
eq(n.attractors,1); eq(n.attr_mj,300)
has(n.attractor_line,'lightning attractors in the area: 1, holding 300.0 MJ')
has(r.reactors,'reactors in the area: 2 (1 fusion-reactor working, 1 heating-tower no_fuel); they make heat or plasma')
print('d21_batch64b Z5 power: ok')

-- The networks view is made again from when a generator is built: a harness build (networks.built) or one the force's
-- entity build statistics count (a player's or robot's), read every 300 ticks.
local N=runtime.networks
force.players={{}}   -- (networks reads forces with players)
local store=storage.agent_harness.networks
store.views.player={tick=game.tick,surfaces={}}
store.view_jobs=store.view_jobs or {}
store.view_jobs.player={start=game.tick,steps={{step='done'}},i=1,out={},ctx={},n=0,every=1}
eq(N.added_since(force,store.views.player),nil)
advance(10)
local built=thing('fusion-generator','fusion-generator',15,-2,fusion)
N.built(built)
has(N.added_since(force,store.views.player),'fusion-generator built 0s ago at (15,-2) on nauvis (up to 50.0 MW), after this view: a new view started then')
local at=game.tick
advance(1)
assert((store.view_jobs.player and store.view_jobs.player.start or store.views.player.tick)>at,'the job or view is newer than the build')
-- a robot's build: the statistics poll (a script's create_entity is not counted there in 2.0.77)
local built_count={['solar-panel']=639}
force.get_entity_build_count_statistics=function(s) return {get_input_count=function(name) return s==surface and built_count[name] or 0 end} end
advance(300 - game.tick % 300)
local before=store.gen_added.player.tick
advance(300)
eq(store.gen_added.player.tick,before,'the first poll only counts')
built_count['solar-panel']=641
advance(300)
eq(store.gen_added.player.name,'solar-panel'); eq(store.gen_added.player.count,2); eq(store.gen_added.player.tick,game.tick)
local v=store.views.player
has(N.added_since(force,v),'2 solar-panel built 0s ago on nauvis by a player or robot, after this view: a new view started then')
advance(1)
assert(store.view_jobs.player.start>store.gen_added.player.tick,'a view job begun after the robot build')
advance(3700)
eq(N.added_since(force,store.views.player),nil,'the new view counts it')
print('d21_batch64b Z5 view refresh: ok')
