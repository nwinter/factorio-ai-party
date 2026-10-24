-- d24 batch160 QC1 (Astra #2208: on Asterion, batteries full and draw equal to production, a laser on low power read
-- "short of supply" because a railgun refilling after shots counted as another machine on low power). Every turret
-- that fires from an electric buffer (laser, railgun, tesla) is a turret in power and platform_power, never another
-- machine; the network is short only when a machine on it is on low or no power, or its accumulators are empty while
-- it draws all it produces (which, said); a railgun's buffer read as a laser's. Run: lua tests/d24_batch160.lua
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

prototypes.entity={['laser-turret']={type='electric-turret'},['railgun-turret']={type='ammo-turret'},['assembling-machine-3']={type='assembling-machine'},
  accumulator={type='accumulator'},['fusion-generator']={type='fusion-generator'}}
local function thing(name,typ,x,y,extra)
  local e={valid=true,name=name,type=typ,position={x=x,y=y},force=force,surface=surface,electric_network_id=2,status=0,quality={name='normal'},
    prototype={electric_energy_source_prototype={}}}
  for k,v in pairs(extra or {}) do e[k]=v end
  surface.things[#surface.things+1]=e
  return e
end
local laser=thing('laser-turret','electric-turret',3,-4,{quality={name='rare'},electric_buffer_size=801000,energy=801000})
local rail=thing('railgun-turret','ammo-turret',6,-4,{electric_buffer_size=10000000,energy=10000000})
local acc=thing('accumulator','accumulator',-6,-6,{electric_buffer_size=5000000,energy=5000000})
-- Astra's case: the railgun and the laser on low power after shots, accumulators full, no other machine short
laser.status,laser.energy=2,256600
rail.status,rail.energy=2,4000000
local r=astra('power',{position={x=0,y=0},radius=20})
local n=r.networks[1]
eq(#r.unpowered,2)
for _,u in ipairs(r.unpowered) do
  eq(u.cause,'recharging after shots: its buffer refills at its input limit; its 1 accumulator in the area holds 5.0 of 5.0 MJ',u.name)
end
eq(n.turrets_recharging,2); eq(n.turrets_short,nil)
-- with a machine in the area, supplied: named too
local am=thing('assembling-machine-3','assembling-machine',-4,2)
r=astra('power',{position={x=0,y=0},radius=20})
eq(r.unpowered[1].cause,'recharging after shots: its buffer refills at its input limit; the 1 other machines of electric #2 in the area are supplied; its 1 accumulator in the area holds 5.0 of 5.0 MJ')
-- a machine on low power: short, by machines
am.status=2
r=astra('power',{position={x=0,y=0},radius=20})
n=r.networks[1]
for _,u in ipairs(r.unpowered) do if u.name~='assembling-machine-3' then eq(u.cause,'electric #2 short of supply: 1 of its 1 other machines in the area on low or no power') end end
eq(n.turrets_short,2); eq(n.turrets_short_by,'machines')
am.status=0
-- accumulators empty while the network draws all it produces: short, by accumulators
acc.energy=0
surface.poles[1].electric_network_statistics=qstats({['laser-turret']={rare=100000}},{['fusion-generator']={normal=100000}})
r=astra('power',{position={x=0,y=0},radius=20})
n=r.networks[1]
eq(n.turrets_short_by,'accumulators')
has(r.unpowered[1].cause,'electric #2 short of supply: its 1 accumulator in the area holds 0.0 of 5.0 MJ, and it draws 6.0 MW of the 6.0 MW it produces')
-- empty accumulators while production exceeds the draw (they charge): recharging
surface.poles[1].electric_network_statistics=stats
r=astra('power',{position={x=0,y=0},radius=20})
eq(r.networks[1].turrets_recharging,2)
print('d24_batch160 QC1 power: ok')

-- platform_power: the railgun among the turrets, not the machines; short by accumulators said
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
pent('laser-turret','electric-turret',1,{quality={name='rare'},electric_buffer_size=801000,energy=256600,status=2})
local rg=pent('railgun-turret','ammo-turret',2,{electric_buffer_size=10000000,energy=4000000,status=2})
pent('assembling-machine-3','assembling-machine',3,{electric_buffer_size=10000,energy=10000})
local pacc=pent('accumulator','accumulator',4,{electric_buffer_size=5000000,energy=5000000})
local NW=require('networks'){state=function() return {} end}
local pp=NW.platform_power(plat_surface,{name='player'})
eq(pp.satisfaction.machines,1,'the railgun is no machine'); eq(pp.satisfaction.low_power,0)
local t=pp.satisfaction.turrets
eq(t.count,2); eq(t.low_power,2); eq(t.recharging,2); eq(t.network_short,nil)
has(pp.line,'turrets firing from a buffer (laser, railgun, tesla) 2: 2 low power, 0 no power, their buffers 36% full on average (the 2 on low power recharging after shots: no machine on low or no power, accumulators 100% full)')
pacc.energy=0
plat_surface.global_electric_network_statistics=qstats({['laser-turret']={rare=100000}},{['fusion-generator']={normal=100000}})
pp=NW.platform_power(plat_surface,{name='player'})
eq(pp.satisfaction.turrets.network_short,2); eq(pp.satisfaction.turrets.short_by,'accumulators')
has(pp.line,'(the network short: its accumulators empty, 0.0 of 5.0 MJ, and it draws 6.0 MW of the 6.0 MW it produces)')
-- inspect on the railgun: its buffer and input limit, as a laser's
local ep=NW.entity_power(rg)
eq(ep.buffer_kj,4000); eq(ep.buffer_max_kj,10000); eq(ep.buffer_pct,40); eq(ep.input_limit_kw,9600)
print('d24_batch160 QC1 platform_power and the railgun buffer: ok')
