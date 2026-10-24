-- d24 batch152 PX1 (Astra #2182): Asterion's 20 rare laser turrets drew 5.8 MW while power listed no laser row and
-- inspect on one read all laser-turret drawing 0 kW; its rare fusion generator's output was left out of production. In
-- 2.0.77 a flow statistics read by name counts normal quality only ({name, quality} counts that quality; input_counts
-- and output_counts give every quality's total). Power, platform power and inspect read every quality, a row for
-- each; a low_power laser turret is told apart: recharging after shots, or its network short.
-- Run from the harness root: lua tests/d24_batch152.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- The runtime against a fake engine (as tests/d21_batch64b.lua sets it up).
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1,ten_minutes=2},entity_status={working=0,no_power=1,low_power=2,no_input_fluid=3,no_fuel=4}}
prototypes={item={['iron-plate']={type='item'}},
  quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5},['quality-unknown']={level=0,hidden=true}}}
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
-- Flow statistics kept by quality as 2.0.77 keeps them: flows {name: {quality: J a tick}}; a name alone reads normal,
-- {name, quality} that quality, input_counts/output_counts every quality's total (a count is 1000 x the flow here).
local reads=0
local function qstats(inp,out)
  local st={input_counts={},output_counts={}}
  for side,t in pairs({input_counts=inp,output_counts=out}) do
    for name,qs in pairs(t) do local n=0; for _,v in pairs(qs) do n=n+v*1000 end; st[side][name]=n end
  end
  local function split(id) if type(id)=='table' then return id.name,id.quality end return id,'normal' end
  st.get_flow_count=function(a) reads=reads+1; local n,q=split(a.name); local t=(a.category=='input' and inp or out)[n]; return t and t[q] or 0 end
  st.get_input_count=function(id) local n,q=split(id); return inp[n] and (inp[n][q] or 0)*1000 or 0 end
  st.get_output_count=function(id) local n,q=split(id); return out[n] and (out[n][q] or 0)*1000 or 0 end
  return st
end
local stats=qstats({['laser-turret']={rare=96000},['assembling-machine-3']={normal=5000}},{['fusion-generator']={normal=100000,rare=40000}})
local function pole(s,id,pos)
  return {valid=true,name='small-electric-pole',type='electric-pole',position=pos,force=force,surface=s,electric_network_id=id,prototype={},electric_network_statistics=stats}
end
surface.poles={pole(surface,2,{x=0.5,y=0.5})}
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local players={}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(name) if name==nil or name=='nauvis' or name==1 then return surface end return nil end,
  surfaces={nauvis=surface},print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    if req.bot then pcall(runtime.stop_player,runtime.bots.index_of(req.bot)) end
    error(result,0)
  end
  return result
end
local function astra(action,args) return request{action=action,args=args or {},bot='astra'} end
runtime.operator.bot_create('astra')

prototypes.entity={['laser-turret']={type='electric-turret'},['assembling-machine-3']={type='assembling-machine'},['fusion-generator']={type='fusion-generator'}}
local function thing(name,typ,x,y,extra)
  local e={valid=true,name=name,type=typ,position={x=x,y=y},force=force,surface=surface,electric_network_id=2,status=0,quality={name='normal'},
    prototype={electric_energy_source_prototype={}}}
  for k,v in pairs(extra or {}) do e[k]=v end
  surface.things[#surface.things+1]=e
  return e
end
local lasers={}
for i=1,3 do lasers[i]=thing('laser-turret','electric-turret',i*3,-4,{quality={name='rare'},electric_buffer_size=801000,energy=801000}) end
local am1=thing('assembling-machine-3','assembling-machine',-4,2)
thing('assembling-machine-3','assembling-machine',-8,2)

-- power: the rare lasers' row, the rare generator's output with normal's, the qualities found
local r=astra('power',{position={x=0,y=0},radius=20})
local n=r.networks[1]
eq(n.id,2)
eq(n.consumers[1].name,'laser-turret','before: no laser-turret row (a read by name counts normal only)')
eq(n.consumers[1].quality,'rare'); eq(n.consumers[1].kw,5760)
eq(n.consumers[2].name,'assembling-machine-3'); eq(n.consumers[2].quality,nil); eq(n.consumers[2].kw,300)
eq(n.consumption_kw,6060)
eq(n.production_kw,8400,'normal 6000 and rare 2400')
eq(n.producers[1].name,'fusion-generator'); eq(n.producers[1].quality,nil); eq(n.producers[1].kw,6000)
eq(n.producers[2].name,'fusion-generator'); eq(n.producers[2].quality,'rare'); eq(n.producers[2].kw,2400)
eq(#n.qualities,1); eq(n.qualities[1],'rare')
has(n.draw_line,'electric #2 draws 6.1 MW: electric-turret 5.8 MW (laser-turret (rare))')
eq(#r.unpowered,0)
-- a laser on low power after shots, every other machine supplied: recharging
lasers[2].status,lasers[2].energy=2,300000
r=astra('power',{position={x=0,y=0},radius=20})
n=r.networks[1]
eq(#r.unpowered,1); eq(r.unpowered[1].name,'laser-turret'); eq(r.unpowered[1].status,'low_power')
eq(r.unpowered[1].cause,'recharging after shots: its buffer refills at its input limit; the 2 other machines of electric #2 in the area are supplied')
eq(n.turrets_recharging,1); eq(n.turrets_short,nil); eq(n.others,nil,'the working counts are not in the reply')
-- an assembler on low power too: the network short
am1.status=2
r=astra('power',{position={x=0,y=0},radius=20})
n=r.networks[1]
eq(r.unpowered[1].cause,'electric #2 short of supply: 1 of its 2 other machines in the area on low or no power')
eq(n.turrets_short,1); eq(n.turrets_recharging,nil)
am1.status=0; lasers[2].status,lasers[2].energy=0,801000
print('d24_batch152 PX1 power by quality, turrets recharging or short: ok')

-- a platform's own network (networks.platform_power) and inspect's electricity (networks.entity_power)
local plat_stats=qstats({['laser-turret']={rare=96000},['assembling-machine-3']={normal=5000}},{['fusion-generator']={normal=100000,rare=40000}})
local list={}
local plat_surface={name='platform-16',has_global_electric_network=true,global_electric_network_statistics=plat_stats,
  platform={name='Asterion',space_location={name='aquilo',solar_power_in_space=60}},find_entities_filtered=function() return list end}
prototypes.surface_property={['solar-power']={default_value=100}}
local src={get_input_flow_limit=function(q) return q and q.name=='rare' and 256000 or 160000 end,drain=400}
local function pent(name,typ,x,extra)
  local e={valid=true,name=name,type=typ,position={x=x,y=0},electric_network_id=900,surface=plat_surface,status=0,quality={name='normal'},
    prototype={electric_energy_source_prototype=src,get_max_energy_usage=function() return 20000 end,get_max_energy_production=function() return 0 end}}
  for k,v in pairs(extra or {}) do e[k]=v end
  list[#list+1]=e
  return e
end
local l1=pent('laser-turret','electric-turret',1,{quality={name='rare'},electric_buffer_size=801000,energy=801000})
local l2=pent('laser-turret','electric-turret',2,{quality={name='rare'},electric_buffer_size=801000,energy=400500,status=2})
local a1=pent('assembling-machine-3','assembling-machine',3,{electric_buffer_size=10000,energy=10000})
pent('assembling-machine-3','assembling-machine',4,{electric_buffer_size=10000,energy=10000})
local NW=require('networks'){state=function() return {} end}
local pp=NW.platform_power(plat_surface,{name='player'})
eq(pp.draw_kw,6060); eq(pp.production_kw,8400)
eq(pp.consumers[1].name,'laser-turret'); eq(pp.consumers[1].quality,'rare'); eq(pp.consumers[1].kw,5760)
eq(pp.producers[2].quality,'rare'); eq(pp.producers[2].kw,2400)
eq(pp.qualities[1],'rare')
has(pp.line,'draw 6.1 MW now, production 8.4 MW (the last 5 s, every quality: rows of rare apart)')
eq(pp.satisfaction.machines,2,'turrets apart from machines'); eq(pp.satisfaction.low_power,0)
local t=pp.satisfaction.turrets
eq(t.count,2); eq(t.low_power,1); eq(t.power_bars_pct,75); eq(t.recharging,1); eq(t.network_short,nil)
-- (d24 batch160 QC1: turrets firing from a buffer, railguns and tesla turrets too)
has(pp.line,'turrets firing from a buffer (laser, railgun, tesla) 2: 1 low power, 0 no power, their buffers 75% full on average (the 1 on low power recharging after shots: no machine on low or no power)')
a1.status=2
pp=NW.platform_power(plat_surface,{name='player'})
eq(pp.satisfaction.turrets.network_short,1); eq(pp.satisfaction.turrets.recharging,nil)
has(pp.line,'(the network short: 1 machine on low or no power)')
a1.status=0
-- inspect on a rare laser: its quality's draw (all of laser-turret here is rare), its buffer and input limit
local ep=NW.entity_power(l2)
eq(ep.now_kw_its_quality,5760); eq(ep.now_kw_all_of_name,5760); eq(ep.quality,'rare')
eq(ep.buffer_kj,401); eq(ep.buffer_max_kj,801); eq(ep.buffer_pct,50); eq(ep.input_limit_kw,15360)
eq(ep.now,'all rare laser-turret on electric network #900 (the platform\'s own network) draw 5.8 MW now (5 s average); the game counts power by prototype and quality, not per entity')
-- a normal laser among them: its own quality's 0, the name's every quality said
local l3=pent('laser-turret','electric-turret',5,{electric_buffer_size=801000,energy=801000})
ep=NW.entity_power(l3)
eq(ep.now_kw_its_quality,0); eq(ep.now_kw_all_of_name,5760); eq(ep.now_by_quality,'rare 5.8 MW')
has(ep.now,'all laser-turret on electric network #900 (the platform\'s own network) draw 0 kW now (5 s average); laser-turret of every quality draw 5.8 MW (rare 5.8 MW)')
print('d24_batch152 PX1 platform power and inspect by quality: ok')

-- qflow: a name only ever counted at normal is read once; else every visible quality, by level
local Q=require('qflow')
eq(table.concat(Q.qualities(),','),'normal,uncommon,rare,epic,legendary')
local s2=qstats({['iron-plate']={normal=10,rare=3,legendary=1},['copper-plate']={normal=7}},{})
reads=0
eq(Q.flow(s2,'copper-plate','input',2,true,s2.input_counts['copper-plate']),7); eq(reads,1,'normal only: one read')
reads=0
local total,by=Q.flow_by(s2,'iron-plate','input',2,true,s2.input_counts['iron-plate'])
eq(total,14); eq(reads,5); eq(Q.label(by),'normal 10, rare 3, legendary 1'); eq(table.concat(Q.names(by),','),'normal,rare,legendary')
eq(Q.flow(s2,'iron-plate','input',2,true),14,'no total given: every quality read')
eq(Q.count(s2,'iron-plate','input'),14000)
local c,cb=Q.count_by(s2,'copper-plate','input'); eq(c,7000); eq(cb,nil)
print('d24_batch152 PX1 qflow: ok')
game,defines,prototypes,storage=nil,nil,nil,nil
