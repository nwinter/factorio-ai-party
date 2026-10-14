-- Run from repository root: lua tests/platformpower.lua
-- Astra, 13:10: networks with surface Starling returned only a note, power took no platform, and inspect on solar
-- panels and machines showed no maximum. A platform's electric network gets the planet line with its solar power
-- (the location's, or between the two ends of its connection); networks takes platform or a platform's name;
-- inspect's power gives the maximum and the network's now. Fake engine.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),'missing "'..part..'" in: '..tostring(text)) end
defines={flow_precision_index={five_seconds=0,one_hour=3},entity_status={no_power=1,low_power=2,working=0},logistic_member_index={logistic_container=0}}
prototypes={item={},surface_property={['solar-power']={default_value=100}}}
storage={}
local force={name='player',players={{}},logistic_networks={}}
local list={}
local nauvis={name='nauvis',index=1,solar_power_multiplier=1,get_property=function() return 100 end,
  find_entities_filtered=function() return {} end,count_entities_filtered=function() return 0 end}
-- Starling: its surface platform-3; at nauvis (solar power in space 300), then flying to gleba (200).
local nauvis_loc={name='nauvis',solar_power_in_space=300}
local gleba_loc={name='gleba',solar_power_in_space=200}
local starling={valid=true,name='Starling',index=3,force=force,space_location=nauvis_loc}
local surf={name='platform-3',index=4,platform=starling,solar_power_multiplier=1,get_property=function() return 100 end,count_entities_filtered=function() return 0 end}
starling.surface=surf
force.platforms={starling}
local function add(e) e.valid=true; e.force=force; e.surface=surf; list[#list+1]=e; return e end
surf.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(list) do
    local ok=true
    if f.type then
      ok=false
      for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if e.type==t then ok=true end end
    end
    if ok then out[#out+1]=e end
  end
  return out
end
game={tick=0,forces={player=force},surfaces={nauvis,surf},get_surface=function(n) if n=='nauvis' or n==1 then return nauvis end if n=='platform-3' or n==4 then return surf end end}
-- Network 280: 6 substations; 20 solar panels (60 kW each), 1 accumulator half full; 8 machines, 2 on low power.
local flows={output={['solar-panel']=2.4e6/60},input={['assembling-machine-2']=1.2e6/60,['electric-furnace']=0.9e6/60}}
local stats={output_counts={['solar-panel']=1},input_counts={['assembling-machine-2']=1,['electric-furnace']=1},
  get_flow_count=function(t) return (flows[t.category] or {})[t.name] or 0 end}
for i=1,6 do add{type='electric-pole',name='substation',position={x=i*8-24,y=0},electric_network_id=280,electric_network_statistics=stats} end
local panel_proto={get_max_energy_production=function() return 60000/60 end}
local panels={}
for i=1,20 do panels[i]=add{type='solar-panel',name='solar-panel',prototype=panel_proto,position={x=i*3-30,y=-12},electric_network_id=280} end
local acc=add{type='accumulator',name='accumulator',position={x=0,y=12},electric_network_id=280,energy=2.5e6,electric_buffer_size=5e6,
  prototype={electric_energy_source_prototype={input_flow_limit=300000/60,output_flow_limit=300000/60}}}
local am_proto={get_max_energy_usage=function() return 150000/60 end,electric_energy_source_prototype={drain=5000/60}}
local machines={}
for i=1,8 do machines[i]=add{type='assembling-machine',name='assembling-machine-2',prototype=am_proto,position={x=i*4-16,y=6},electric_network_id=280,status=i<=2 and 2 or 0} end
machines[1].consumption_bonus=-0.6
local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end}
local function run(sec) for _=1,sec*60 do game.tick=game.tick+1; N.tick(game.tick) end end
run(300)
storage.networks.views={}

-- 1. The solar power: a planet's property; a platform's at its location, then between the ends.
eq(N.solar(nauvis).text,'solar power 100%')
local s=N.solar(surf)
eq(s.percent,300); eq(s.text,'solar power 300% at nauvis'); eq(s.platform,'Starling')

-- 2. The line, as a planet's, named by the platform; its panels at the solar power here count in its capacity.
local lines=N.lines(force,'platform-3',8)
eq(lines[1],'Starling (platform) electric #280 (6 poles near (4,0)): draw 2.4 MW avg over 5 min (now 2.4 MW) of 3.6 MW capacity (67%); '
  ..'solar 20 panels, 2.4 MW now, 3.6 MW at this solar power (solar power 300% at nauvis); accumulators 1 at 50% (2.5 MJ of 5.0 MJ); '
  ..'machines 8: 2 low power, 0 no power')

-- 3. networks takes platform (name or index) and a platform's name as surface (Astra: surface Starling).
for _,args in ipairs({{platform='Starling'},{platform=3},{surface='Starling'},{surface='platform-3'}}) do
  local r=N.read({force=force},args)
  eq(#r.surfaces,1); eq(r.surfaces[1].surface,'platform-3'); eq(r.surfaces[1].platform,'Starling'); eq(r.none,nil)
  local e=r.surfaces[1].electric[1]
  eq(e.id,280); eq(e.capacity_kw,3600); eq(e.solar_peak_kw,3600); eq(e.solar_power,300); eq(e.solar_power_text,'solar power 300% at nauvis')
end
local ok,err=pcall(N.read,{force=force},{platform='Nope'})
eq(ok,false); eq(err,'no platform of ours named Nope; platforms: Starling; planets and surfaces: nauvis')
ok,err=pcall(N.read,{force=force},{surface='mars'})
eq(ok,false); eq(err,'no surface or platform named mars; platforms: Starling; planets and surfaces: nauvis')
ok,err=pcall(N.read,{force=force},{surface='nauvis',platform='Starling'})
eq(ok,false); has(err,'give platform or surface, not both')
-- A surface named with nothing on it says so.
local r=N.read({force=force},{surface='nauvis'})
eq(#r.surfaces,0); eq(r.none,'no electric network over 2 poles or with a generator, no logistic network and no turret of ours on nauvis as of 0s ago')

-- 4. Flying: between the ends by how far along it is (distance from the connection's first end).
starling.space_location=nil; starling.space_connection={from=nauvis_loc,to=gleba_loc}; starling.distance=0.4
s=N.solar(surf)
eq(s.percent,260); eq(s.text,'solar power 260% between nauvis (300%) and gleba (200%), 40% of the way from nauvis')
surf.solar_power_multiplier=0.5
eq(N.solar(surf).percent,130,'a script multiplier scales it')
surf.solar_power_multiplier=1
storage.networks.views={}; game.tick=game.tick+1   -- (the panels' scale is kept for the tick)
has(N.lines(force,'platform-3',8)[1],'solar 20 panels, 2.4 MW now, 3.1 MW at this solar power (solar power 260% between nauvis (300%) and gleba (200%), 40% of the way from nauvis)')

-- 5. inspect's power: a solar panel at 100% and where it is; a machine with its modules' bonus and drain; an
-- accumulator; and now from the network (by prototype).
local p1=N.entity_power(panels[1])
eq(p1.max_kw,60); eq(p1.at_solar_power_kw,156); has(p1.solar_power,'solar power 260%')
eq(p1.now,'all solar-panel on electric network #280 make 2.4 MW now (5 s average); the game counts power by prototype, not per entity')
eq(p1.now_kw_all_of_name,2400)
local m1=N.entity_power(machines[1])
eq(m1.max_kw,60); eq(m1.consumption_bonus,'-60%'); eq(m1.drain_kw,5)
eq(m1.now,'all assembling-machine-2 on electric network #280 draw 1.2 MW now (5 s average); the game counts power by prototype, not per entity')
eq(N.entity_power(machines[2]).max_kw,150); eq(N.entity_power(machines[2]).consumption_bonus,nil)
local a1=N.entity_power(acc)
eq(a1.stored_mj,2.5); eq(a1.capacity_mj,5); eq(a1.charge_kw,300); eq(a1.discharge_kw,300)
local lone=add{type='assembling-machine',name='assembling-machine-2',prototype=am_proto,position={x=40,y=40}}
eq(N.entity_power(lone).now,'no electric network: no pole reaches it')
eq(N.entity_power(add{type='container',name='iron-chest',prototype={},position={x=1,y=1}}),nil,'no electric part')
-- A planet's panel: solar power from the surface property.
local np={valid=true,type='solar-panel',name='solar-panel',prototype=panel_proto,surface=nauvis}
eq(N.entity_power(np).at_solar_power_kw,60)
-- 6. Astra, 14:05: Starling's network 475 (5 solar panels, assemblers on low power) was not found. A platform's
-- poles are found at once each view, so the pole map's missing them does not matter; and a network with no pole of
-- ours gets a line from its panels and machines, without draw figures.
local lonely={valid=true,name='Lonely',index=5,force=force,space_location=nauvis_loc}
local lsurf={name='platform-5',index=6,platform=lonely,solar_power_multiplier=1,get_property=function() return 100 end,count_entities_filtered=function() return 0 end}
lonely.surface=lsurf
local llist={}
lsurf.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(llist) do
    local ok=true
    if f.type then ok=false; for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if e.type==t then ok=true end end end
    if ok then out[#out+1]=e end
  end
  return out
end
local function ladd(e) e.valid=true; e.force=force; e.surface=lsurf; llist[#llist+1]=e; return e end
for i=1,5 do ladd{type='solar-panel',name='solar-panel',prototype=panel_proto,position={x=i*3,y=-6},electric_network_id=475} end
local lm={}
for i=1,3 do lm[i]=ladd{type='assembling-machine',name='assembling-machine-2',prototype=am_proto,position={x=i*4,y=4},electric_network_id=475,status=i<=2 and 2 or 0} end
force.platforms={starling,lonely}
game.surfaces={nauvis,surf,lsurf}
-- Starling's poles drop out of the pole map (as when its walk missed them): the view finds them again.
for id,m in pairs(storage.networks.map) do if m.surface=='platform-3' then storage.networks.map[id]=nil end end
starling.space_connection=nil; starling.space_location=nauvis_loc
storage.networks.views={}; game.tick=game.tick+1
r=N.read({force=force},{platform='Starling'})
eq(r.surfaces[1].electric[1].id,280,'Starling found again'); eq(r.surfaces[1].electric[1].poles,6)
assert(storage.networks.map[280],'its poles are in the pole map again')
r=N.read({force=force},{platform='Lonely'})
eq(#r.surfaces,1); local le=r.surfaces[1].electric[1]
eq(le.id,475); eq(le.poles,0); eq(le.machines,3); eq(le.low,2); eq(le.solar,5)
eq(le.line,'Lonely (platform) electric #475 (no pole of ours found near (3,-6)): capacity 900 kW; no draw figures (the game gives a network\'s statistics through its poles); '
  ..'solar 5 panels, 0 kW now, 900 kW at this solar power (solar power 300% at nauvis); machines 3: 2 low power, 0 no power')
-- inspect: a machine whose network is not in the pole map finds a pole of it within 64 tiles; with none, says so.
storage.networks.map[280]=nil
eq(N.entity_power(machines[3]).now_kw_all_of_name,1200,'a pole of network 280 nearby')
eq(N.entity_power(lm[1]).now,'electric network #475: no pole of ours in it within 64 tiles, and the game gives a network\'s statistics through its poles')
print('platformpower: ok')
