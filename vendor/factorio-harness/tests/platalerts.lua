-- Run from repository root: lua tests/platalerts.lua
-- Platform health alerts (platalerts.lua) in team.alerts: hits, turret ammo,
-- repair packs, hub health, hits per minute rising; to the platform's
-- creator, its last workers and riders; rate-limited (all four lost
-- platforms died to asteroids).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(list,text) for _,l in ipairs(list or {}) do if l:find(text,1,true) then return l end end end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,hub_main=21,turret_ammo=31},build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1},
  space_platform_state={waiting_for_starter_pack=1,waiting_at_station=6,paused=7}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={['repair-pack']={type='repair-tool'},['firearm-magazine']={type='ammo'},['space-platform-starter-pack']={type='space-platform-starter-pack'}},entity={},recipe={}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,recipes={}}
local enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}
local surfaces={}
local function new_surface(name,index)
  local s={name=name,index=index,valid=true,planet=nil}
  s.find_non_colliding_position=function(_,origin) return origin end
  s.can_place_entity=function() return true end
  s.find_entities_filtered=function() return {} end
  s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
  surfaces[name]=s; surfaces[index]=s
  return s
end
local nauvis=new_surface('nauvis',1); nauvis.planet={name='nauvis'}
local function character(surface,pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=900,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end; c.get_main_inventory=function() return inv end; c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end; c.destroy=function() c.valid=false end
  return c
end
nauvis.create_entity=function(args) if args.name=='character' then return character(nauvis,args.position) end end
-- The platform Starling: a hub (1000 health, repair packs) and two gun turrets.
local psurf=new_surface('platform-1',2)
local packs=5
local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},force=force,surface=psurf,health=1000,max_health=1000}
hub.get_logistic_sections=function() return nil end
hub.get_inventory=function(i) if i==21 then return {get_contents=function() return packs>0 and {{name='repair-pack',count=packs,quality='normal'}} or {} end} end end
local function turret(x,rounds)
  local t={valid=true,name='gun-turret',type='ammo-turret',position={x=x,y=-5},force=force,surface=psurf,rounds=rounds,health=400,max_health=400}
  t.get_inventory=function(i) if i==31 then return {get_item_count=function() return t.rounds end} end end
  return t
end
local t1,t2=turret(-3,50),turret(3,50)
hub.get_fluid_contents=function() return {} end
hub.bounding_box={left_top={x=-2,y=-2},right_bottom={x=2,y=2}}
psurf.find_entities_filtered=function(f)
  if f.type=='ammo-turret' then return {t1,t2} end
  if f.position and not f.type and f.position.x==0 and f.position.y==0 then return {hub} end
  return {}
end
local platform={valid=true,name='Starling',index=1,force=force,hub=hub,state=6,space_location={name='nauvis'}}
force.platforms={}
force.create_space_platform=function(a) platform.name=a.name or platform.name; force.platforms={platform}; platform.surface=psurf; psurf.platform=platform; return platform end
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy=enemy},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,planets={},
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local astra,sol,luna,opus=as('astra'),as('sol'),as('luna'),as('opus')
for _,n in ipairs{'astra','sol','luna','opus'} do runtime.operator.bot_create(n) end
local function alerts(who) local r=who('status',{brief=true}); return r.team and r.team.alerts or {} end
for _,f in ipairs{astra,sol,luna,opus} do alerts(f) end  -- each agent's first look

-- Astra creates the platform; Sol works on it (a request naming platform=);
-- Luna rides aboard. Opus has nothing to do with it.
astra('platform_create',{name='Starling'})
jump(60)
sol('platforms',{platform='Starling'})  -- the platforms read is no work on it
local r=runtime.platalerts and storage.agent_harness.platform_alerts.by[1]
eq(r.creator,'astra'); eq(r.workers.sol,nil)
pcall(sol,'inspect',{platform='Starling',position={x=0,y=0}})
eq(r.workers.sol,tick)
local lb=runtime.bots.record(runtime.bots.index_of('luna')); lb.travel={state='aboard',platform='Starling'}

-- Asteroids hit a turret and the hub.
local rock={valid=true,name='medium-metallic-asteroid',type='asteroid',force=enemy}
local function hit(e,d) runtime.on_event{name=defines.events.on_entity_damaged,tick=tick,entity=e,force=enemy,cause=rock,final_damage_amount=d} end
hit(t1,150); hit(t1,150); hit(hub,80)
-- Our turret shooting an asteroid is no hit on us; nor does a platform hit
-- become a planet attack (threat.lua's incidents).
runtime.on_event{name=defines.events.on_entity_damaged,tick=tick,entity=rock,force=force,cause=t1,final_damage_amount=10}
eq(next(storage.agent_harness.damage or {}),nil)
jump(60)
local a=alerts(astra)
eq(has(a,'platform Starling hit'),'platform Starling hit 3 times, 380 damage, last 1s ago: gun-turret 300, space-platform-hub 80; by medium-metallic-asteroid 3')
assert(has(alerts(sol),'platform Starling hit 3 times'))
assert(has(alerts(luna),'platform Starling hit 3 times'))
eq(has(alerts(opus),'Starling'),nil,'opus has nothing to do with Starling')
-- Told once; new hits within the minute wait; after it, only what is new since.
hit(t2,40); jump(600)
eq(has(alerts(astra),'hit'),nil)
jump(3600); hit(t2,40); jump(60)
eq(has(alerts(astra),'platform Starling hit'),'platform Starling hit 2 times, 80 damage, last 1s ago: gun-turret 80; by medium-metallic-asteroid 2')

-- Turrets empty or low; told again only when worse or after 5 minutes.
t1.rounds=0; t2.rounds=4; jump(601)
eq(has(alerts(sol),'turrets empty'),'platform Starling: 1 of 2 gun-turrets empty, 1 low (under 10 rounds)')
jump(601); eq(has(alerts(sol),'turrets empty'),nil)
t2.rounds=0; jump(601)
eq(has(alerts(sol),'turrets empty'),'platform Starling: 2 of 2 gun-turrets empty')
jump(5*3600); eq(has(alerts(sol),'turrets empty'),'platform Starling: 2 of 2 gun-turrets empty')
t1.rounds,t2.rounds=50,50

-- No repair packs while it takes hits.
packs=0; hit(hub,10); jump(601)
eq(has(alerts(luna),'repair packs'),'platform Starling: no repair packs in the hub (the game repairs platform entities only with hub repair packs), and it was hit 10s ago')
jump(601); eq(has(alerts(luna),'repair packs'),nil)
packs=5

-- The hub's health falling.
opus('status',{brief=true}); jump(601); alerts(astra)  -- a sample at 1000
hub.health=900; jump(601)
eq(has(alerts(astra),'hub health'),'platform Starling hub health 900/1000, down 100 in 40s')
hub.health=880; jump(601); eq(has(alerts(astra),'hub health'),nil,'within the minute')
jump(3000); hub.health=850; jump(601)
eq(has(alerts(astra),'hub health'),'platform Starling hub health 850/1000, down 50 in 1m10s')
-- Repaired, then falling again: told from the new high.
hub.health=990; jump(601); alerts(astra)
hub.health=950; jump(3601)
eq(has(alerts(astra),'hub health'),'platform Starling hub health 950/1000, down 40 in 1m00s')
hub.health=1000

-- Hits per minute rising: 2 a minute for 5 minutes, then 30 in one.
jump(7200)
for _=1,5 do jump(3600); hit(t1,1); hit(t1,1) end
jump(3600-(tick%3600))
for _=1,30 do hit(t1,1) end
jump(3600)
assert(has(alerts(astra),'hits per minute rising, 30 in the last minute, 2 a minute over the 5 before'))

-- An old platform with no creator, worker or rider known: everyone hears.
storage.agent_harness.platform_alerts.by[1].creator=nil
storage.agent_harness.platform_alerts.by[1].workers={}
lb.travel=nil
t1.rounds=0; jump(601)
assert(has(alerts(opus),'turrets empty'),'everyone hears an unattended platform')
-- describe/usage: a fault in the alerts never fails a reply.
local saved=runtime.platalerts.lines
runtime.platalerts.lines=function() error('boom') end
assert(opus('status',{brief=true}).tick)
runtime.platalerts.lines=saved
print('platalerts: ok')
