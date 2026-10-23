-- Run from repository root: lua tests/conditions.lua
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
defines={inventory={turret_ammo=7}}
prototypes={item={['firearm-magazine']={}}}
local mine={name='player',technologies={turrets={researched=true}}}
local worm={valid=true,type='turret',position={x=10,y=0},fogged=false}
local nest={valid=true,type='unit-spawner',position={x=20,y=0},fogged=true}
local biter={valid=true,type='unit',position={x=5,y=0},hidden=true}
local function turret(ammo,target)
  return {valid=true,type='ammo-turret',position={x=0,y=0},shooting_target=target,
    get_inventory=function() return {get_item_count=function() return ammo end} end}
end
local ours={turret(20),turret(3,worm)}
-- standing orders' predicates: ghosts, damaged buildings, burners and their fuel
local ghosts={{valid=true,type='entity-ghost'},{valid=true,type='tile-ghost'},{valid=true,type='entity-ghost'}}
local function building(name,x,ratio)
  return {valid=true,name=name,type='assembling-machine',position={x=x,y=0},get_health_ratio=function() return ratio end}
end
local buildings={building('wall',3,0.4),building('gun-turret',-2,0.9),building('lab',1,1),{valid=true,name='character',type='character',position={x=0,y=0},get_health_ratio=function() return 0.1 end},
  {valid=true,name='ghost',type='entity-ghost',position={x=0,y=0},get_health_ratio=function() error('ghosts have no health') end}}
local function burner(name,x,fuel)
  return {valid=true,name=name,position={x=x,y=0},burner=fuel and {} or nil,get_fuel_inventory=function() return {get_item_count=function() return fuel end} end}
end
local burners={burner('stone-furnace',6,2),burner('burner-mining-drill',-4,0),burner('boiler',9,20),burner('electric-furnace',1,nil)}
local surface={find_entities_filtered=function(f)
  if f.force=='enemy' then
    local out={}
    for _,e in ipairs({worm,nest,biter}) do
      for _,t in ipairs(f.type) do if t==e.type then out[#out+1]=e end end
    end
    return out
  end
  if f.type==nil then return buildings end
  if f.type[1]=='entity-ghost' then return ghosts end
  if f.type[1]=='furnace' then return burners end
  return ours
end}
local main={get_item_count=function(name) return name=='firearm-magazine' and 12 or 0 end}
local p={position={x=0,y=0},surface=surface,force=mine,character={health=30,max_health=100},crafting_queue_size=2,
  get_main_inventory=function() return main end}
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,
  -- Charted structures are known under fog; units only when visible.
  known=function(_,e) return not e.hidden end}
local function check(c) C.validate(c); return C.check(p,c) end
local met,saw=check({['until']='no_enemy_structures',radius=30})
eq(met,false); eq(saw,'2 enemy structures')
eq(select(2,check({['until']='no_enemies'})),'2 enemies')
eq(check({['until']='turrets_idle'}),false)
ours[2].shooting_target=nil; eq(check({['until']='turrets_idle'}),true)
met,saw=check({['until']='ammo_below',count=5}); eq(met,true); eq(saw,'1 turrets below 5')
eq(check({['until']='ammo_below',count=2}),false)
met,saw=check({['until']='health_below',fraction=0.4}); eq(met,true); eq(saw,'health 30%')
eq(check({['until']='health_above',fraction=0.4}),false)
eq(check({['until']='item_count',item='firearm-magazine',at_least=10}),true)
eq(check({['until']='item_count',item='firearm-magazine',below=10}),false)
eq(check({['until']='crafting_done'}),false)
eq(check({['until']='researched',technology='turrets'}),true)
-- Bad arguments are rejected when the plan is submitted.
met,saw=check({['until']='ghosts_waiting'}); eq(met,true); eq(saw,'3 ghosts')
eq(check({['until']='ghosts_waiting',at_least=4}),false)
-- our buildings under the fraction (default: any damage), never characters or ghosts; the nearest named
met,saw=check({['until']='damaged'}); eq(met,true); eq(saw,'2 damaged (nearest gun-turret at -2,0)')
met,saw=check({['until']='damaged',fraction=0.5}); eq(met,true); eq(saw,'1 damaged (nearest wall at 3,0)')
eq(check({['until']='damaged',fraction=0.3}),false)
-- burners (not electric machines) holding under count fuel items
met,saw=check({['until']='fuel_below',count=5}); eq(met,true); eq(saw,'2 burners below 5 fuel (nearest burner-mining-drill at -4,0)')
eq(check({['until']='fuel_below',count=1}),true)
eq(select(2,check({['until']='fuel_below',count=1})),'1 burners below 1 fuel (nearest burner-mining-drill at -4,0)')
burners[2]=burner('burner-mining-drill',-4,3); eq(check({['until']='fuel_below',count=1}),false)
-- A rocket silo (Luna, shift10 06:20: an item_count wait for the item rocket stayed 0 at a ready silo):
-- rocket_ready at its position; item_count counts its rocket cargo (the game's own count) and saw names the rocket state.
defines.rocket_silo_status={building_rocket=0,rocket_rising=5,rocket_ready=7}
defines.inventory.rocket_silo_rocket=9
prototypes.item['agricultural-science-pack']={}; prototypes.item.rocket={}
local cargo={{name='agricultural-science-pack',count=45,quality='normal'}}
local silo={valid=true,type='rocket-silo',name='rocket-silo',position={x=65.5,y=14.5},rocket_silo_status=7,rocket_parts=0,prototype={rocket_parts_required=50},
  get_item_count=function(name) return name=='agricultural-science-pack' and 45 or 0 end,
  get_inventory=function(id) if id==9 then return {get_contents=function() return cargo end} end end}
local find=surface.find_entities_filtered
surface.find_entities_filtered=function(f)
  -- the footprint by area (61..70, 10..19); by position and radius the centre's entities only: the silo and its rocket
  if f.type=='rocket-silo' then assert(f.area,'by area'); return (f.area[1][1]>=61 and f.area[2][1]<=70 and f.area[1][2]>=10 and f.area[2][2]<=19) and {silo} or {} end
  if f.radius==0.3 and f.type==nil then return (math.abs(f.position.x-65.5)<0.3 and math.abs(f.position.y-14.5)<0.3) and {silo,{valid=true,type='rocket-silo-rocket',get_item_count=function() return 0 end}} or {} end
  return find(f)
end
met,saw=check({['until']='rocket_ready',position={x=68,y=12}})
-- (Astra 10:50: a built rocket said plainly; its 0/50 parts were read as launched or as a missing kit)
eq(met,true); eq(saw,"rocket-silo (65.5,14.5): rocket built (50/50 parts) and ready to launch, not launched, cargo agricultural-science-pack*45; parts for the rocket after it 0/50")
silo.rocket_silo_status=5; silo.rocket_parts=12; cargo={}
met,saw=check({['until']='rocket_ready',position={x=65.5,y=14.5}})
eq(met,false); eq(saw,'rocket-silo (65.5,14.5): rocket_rising, parts 12/50, cargo none')
local ok,err=pcall(check,{['until']='rocket_ready',position={x=0,y=0}}); eq(ok,false); assert(tostring(err):find('no rocket silo of ours at (0,0)',1,true),err)
assert(not pcall(C.validate,{['until']='rocket_ready'}))
silo.rocket_silo_status=7; silo.rocket_parts=0; cargo={{name='agricultural-science-pack',count=45,quality='normal'}}
met,saw=check({['until']='item_count',item='agricultural-science-pack',at_least=45,positions={{x=65.5,y=14.5}}})
eq(met,true); eq(saw,"agricultural-science-pack 45 in 1 entities; rocket-silo (65.5,14.5): rocket built (50/50 parts) and ready to launch, not launched, cargo agricultural-science-pack*45; parts for the rocket after it 0/50")
met,saw=check({['until']='item_count',item='rocket',at_least=1,positions={{x=65.5,y=14.5}}})
eq(met,false); eq(saw,"rocket 0 in 1 entities; rocket-silo (65.5,14.5): rocket built (50/50 parts) and ready to launch, not launched, cargo agricultural-science-pack*45; parts for the rocket after it 0/50")
-- The silo goes on with the next rocket's parts while one is ready (round1650d: Grok read "parts consumed (13/50)"
-- beside a ready rocket as one still being built): those are named as the next rocket's.
silo.rocket_parts=13
met,saw=check({['until']='rocket_ready',position={x=65.5,y=14.5}})
eq(met,true); eq(saw,"rocket-silo (65.5,14.5): rocket built (50/50 parts) and ready to launch, not launched, cargo agricultural-science-pack*45; parts for the rocket after it 13/50")
silo.rocket_parts=0
-- rocket_parts (Sonnet, shift14 22:50): the rocket being built has at least N parts; a built one (rising or ready)
-- has all of them.
silo.rocket_silo_status=0; silo.rocket_parts=35
met,saw=check({['until']='rocket_parts',at_least=40,position={x=65.5,y=14.5}})
eq(met,false); eq(saw,'rocket parts 35/50 (at least 40); rocket-silo (65.5,14.5): building_rocket, parts 35/50, cargo agricultural-science-pack*45')
silo.rocket_parts=40
eq((check({['until']='rocket_parts',at_least=40,position={x=65.5,y=14.5}})),true)
silo.rocket_silo_status=5; silo.rocket_parts=0
met,saw=check({['until']='rocket_parts',at_least=50,position={x=65.5,y=14.5}})
eq(met,true); assert(saw:find('^rocket parts 50/50 %(at least 50%)'),saw)
silo.rocket_silo_status=7; silo.rocket_parts=6
eq((check({['until']='rocket_parts',at_least=50,position={x=65.5,y=14.5}})),true,'a ready rocket has all its parts')
silo.rocket_parts=0
-- no at_least: every part of the rocket (d16 batch10 A1)
C.validate({['until']='rocket_parts',position={x=1,y=1}})
silo.rocket_silo_status=1; silo.rocket_parts=49
met,saw=check({['until']='rocket_parts',position={x=65.5,y=14.5}})
eq(met,false); assert(saw:find('^rocket parts 49/50 %(at least 50%)'),saw)
silo.rocket_parts=0
assert(not pcall(C.validate,{['until']='rocket_parts',at_least=40}))
assert(not pcall(C.validate,{['until']='rocket_parts',at_least=0,position={x=1,y=1}}))
C.validate({['until']='rocket_parts',at_least=40,position={x=1,y=1}})
-- One position is the same as positions with it (Haiku, 12:20: a level fallen under at one chest).
met,saw=check({['until']='item_count',item='agricultural-science-pack',below=50,position={x=65.5,y=14.5}})
eq(met,true); assert(saw:find('agricultural-science-pack 45 in 1 entities',1,true),saw)
surface.find_entities_filtered=find
assert(not pcall(C.validate,{['until']='fuel_below'}))
assert(not pcall(C.validate,{['until']='damaged',fraction=0}))
assert(not pcall(C.validate,{['until']='ghosts_waiting',at_least=0}))
assert(not pcall(C.validate,{['until']='bogus'}))
assert(not pcall(C.validate,{['until']='health_below'}))
assert(not pcall(C.validate,{['until']='item_count',item='firearm-magazine'}))
assert(not pcall(C.validate,{['until']='ammo_below',count=0}))
assert(not pcall(C.validate,{['until']='no_enemies',radius=500}))
-- platform_arrived (Gemini, shift10): a platform of ours stopped at a space location, or at the one named. 2.0.77:
-- a platform leaving a stop has no space_location within 4 ticks and flies a space_connection.
prototypes.space_location={nauvis={},gleba={},vulcanus={}}
local sunward={valid=true,name='Sunward',space_location={name='nauvis'}}
mine.platforms={sunward}
local met,saw=C.check(p,C.validate({['until']='platform_arrived',platform='Sunward'}))
eq(met,true); eq(saw,'Sunward at nauvis')
eq(C.check(p,{['until']='platform_arrived',platform='Sunward',location='nauvis'}),true)
met,saw=C.check(p,{['until']='platform_arrived',platform='Sunward',location='gleba'})
eq(met,false); eq(saw,'Sunward at nauvis')
sunward.space_location=nil; sunward.space_connection={from={name='nauvis'},to={name='gleba'}}; sunward.distance=0.25
met,saw=C.check(p,{['until']='platform_arrived',platform='Sunward'})
eq(met,false); eq(saw,'Sunward flying nauvis->gleba 25%')
sunward.space_connection=nil; sunward.space_location={name='gleba'}
eq(C.check(p,{['until']='platform_arrived',platform='Sunward',location='gleba'}),true)
local ok,err=pcall(C.check,p,{['until']='platform_arrived',platform='Nope'})
eq(ok,false); eq(err,'no platform of ours named Nope')
assert(not pcall(C.validate,{['until']='platform_arrived'}),'needs platform')
assert(not pcall(C.validate,{['until']='platform_arrived',platform='Sunward',location='mars'}),'a known location')
-- Named hub counts landed main-inventory stock only, from another planet or without a body.
defines.inventory.hub_main=42
local landed=0
sunward.hub={valid=true,get_inventory=function(id)
  eq(id,42)
  return {get_item_count=function(item) eq(item,'agricultural-science-pack'); return landed end}
end}
local hubwait={['until']='item_count',platform='Sunward',item='agricultural-science-pack',at_least=1000}
local nobody=setmetatable({force=mine},{__index=function() error('no body or surface access') end})
C.validate(hubwait)
met,saw=C.check(nobody,hubwait); eq(met,false)
eq(saw,'agricultural-science-pack 0 in Sunward hub (landed stock; excludes incoming cargo and hub trash)')
landed=999; eq(C.check(nobody,hubwait),false)
landed=1000; eq(C.check(nobody,hubwait),true)
eq(C.check(nobody,{['until']='item_count',platform='Sunward',item='agricultural-science-pack',below=1000}),false)
for _,fields in ipairs({{platform=''}, {platform=42}, {platform='Sunward',position={x=0,y=0}},
  {platform='Sunward',positions={{x=0,y=0}}}, {platform='Sunward',surface='nauvis'}}) do
  local c={['until']='item_count',item='agricultural-science-pack',at_least=1}
  for k,v in pairs(fields) do c[k]=v end
  assert(not pcall(C.validate,c))
end
local ok,err=pcall(C.check,nobody,{['until']='item_count',platform='Nope',item='agricultural-science-pack',at_least=1})
assert(not ok and tostring(err):find('no platform of ours named Nope',1,true))
sunward.hub.valid=false
assert(not pcall(C.check,nobody,hubwait),'missing hub is an error, not a zero count')
-- batch27 A6 (Grok: the copper cultivator dies when copper ore stays over 300 longer than the bacteria last, ~40 s):
-- spoil_within on a machine's input, and item_count of one logistic network.
do
  game=game or {}
  game.tick=6000
  defines.inventory.assembling_machine_input=2; defines.inventory.furnace_source=2
  prototypes.item['copper-bacteria']={}; prototypes.item['pentapod-egg']={spoil_to_trigger_result={}}; prototypes.item['copper-ore']={}
  local stacks={{valid_for_read=true,name='copper-ore',spoil_tick=0},{valid_for_read=true,name='copper-bacteria',spoil_tick=6000+40*60}}
  local cult={valid=true,name='biochamber',type='assembling-machine',position={x=3.5,y=3.5},get_inventory=function() return stacks end}
  local surf={find_entities_filtered=function(f) return f.position and {cult} or {} end,
    find_logistic_network_by_position=function(pos) if pos.x==0 then return {get_item_count=function(n) return n=='copper-ore' and 340 or 0 end} end end}
  local q={surface=surf,force=mine}
  C.validate({['until']='spoil_within',position={x=3.5,y=3.5},seconds=60})
  local met,saw=C.check(q,{['until']='spoil_within',position={x=3.5,y=3.5},seconds=60})
  eq(met,true); eq(saw,"biochamber (3.5,3.5): its input's first copper-bacteria spoils in 40s")
  met=C.check(q,{['until']='spoil_within',position={x=3.5,y=3.5},seconds=30}); eq(met,false)
  met,saw=C.check(q,{['until']='spoil_within',position={x=3.5,y=3.5},seconds=60,item='copper-ore'}); eq(met,false)
  eq(saw,'biochamber (3.5,3.5): no copper-ore in its input spoils')
  stacks[3]={valid_for_read=true,name='pentapod-egg',spoil_tick=6000+600}
  met,saw=C.check(q,{['until']='spoil_within',position={x=3.5,y=3.5},seconds=20}); eq(met,true)
  eq(saw,"biochamber (3.5,3.5): its input's first pentapod-egg hatches in 10s")
  assert(not pcall(C.validate,{['until']='spoil_within',seconds=10}),'position required')
  assert(not pcall(C.validate,{['until']='spoil_within',position={x=0,y=0},seconds=0}),'seconds 1..3600')
  -- item_count network: one logistic network
  C.validate({['until']='item_count',item='copper-ore',network={x=0,y=0},below=300})
  met,saw=C.check(q,{['until']='item_count',item='copper-ore',network={x=0,y=0},below=300})
  eq(met,false); eq(saw,'copper-ore 340 in the logistic network at (0,0)')
  local ok2,err2=pcall(C.check,q,{['until']='item_count',item='copper-ore',network={x=50,y=0},below=300})
  assert(not ok2 and tostring(err2):find('no logistic network of ours covers (50,0)',1,true),tostring(err2))
  assert(not pcall(C.validate,{['until']='item_count',item='copper-ore',network={x=0,y=0},positions={{x=1,y=1}},below=3}),'network excludes positions')
end
-- batch28 B1 (Luna: polled silo, shipment and where_is for each pod): pod_landed counts freight's receipts since the
-- wait began: pods, or with item how many of it.
do
  game.tick=9000
  prototypes.item['rocket-fuel']={}
  local receipts={}
  local C2=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
    receipts=function(pl,since) local out={} for _,r in ipairs(receipts) do if r.tick>since then out[#out+1]=r end end return out end}
  local k2={valid=true,name='K2'}
  local q={force={platforms={k2}}}
  local rec={}
  receipts[1]={tick=8000,kind='received',where='old pad',cargo={['rocket-fuel']=200}}
  C2.validate({['until']='pod_landed',platform='K2',item='rocket-fuel',at_least=400})
  local met,saw=C2.check(q,{['until']='pod_landed',platform='K2',item='rocket-fuel',at_least=400},nil,rec)
  eq(met,false); eq(saw,'0 pods from K2 landed since the wait began with 0 rocket-fuel')
  receipts[2]={tick=9100,kind='received',where='cargo-landing-pad (5.5,3.5) on nauvis',cargo={['rocket-fuel']=200}}
  receipts[3]={tick=9200,kind='gone',where='gone before leaving the platform',cargo={['rocket-fuel']=200}}
  receipts[4]={tick=9300,kind='landed',where='cargo-pod-container (40.5,2.5) on nauvis',cargo={['rocket-fuel']=200}}
  game.tick=9400
  met,saw=C2.check(q,{['until']='pod_landed',platform='K2',item='rocket-fuel',at_least=400},nil,rec)
  eq(met,true); eq(saw,'2 pods from K2 landed since the wait began with 400 rocket-fuel (the last cargo-pod-container (40.5,2.5) on nauvis)')
  eq(C2.check(q,{['until']='pod_landed',platform='K2'},nil,rec),true,'one pod at least')
  assert(not pcall(C2.validate,{['until']='pod_landed'}),'platform required')
end
-- (d17 batch33 A2, Astra 09:33: Petrel's wait with quality rare / uncommon read 0 while the hub held 5 rare and 10
-- uncommon quality-module-3) item_count reads quality; "any" sums them; no other condition takes it.
do
  prototypes.item['quality-module-3']={}
  prototypes.quality={normal={},uncommon={},rare={},epic={},legendary={},['quality-unknown']={}}
  defines.inventory.hub_main=1
  local held={['quality-module-3@rare']=5,['quality-module-3@uncommon']=10,['quality-module-3@normal']=2}
  local inv={get_item_count=function(id) if type(id)=='string' then return held[id..'@normal'] or 0 end return held[id.name..'@'..(id.quality or 'normal')] or 0 end}
  local pl={valid=true,name='Petrel',hub={valid=true,get_inventory=function() return inv end}}
  local q={position={x=0,y=0},surface=surface,force={name='player',platforms={pl}},get_main_inventory=function() return main end}
  local function qc(c) C.validate(c); return C.check(q,c) end
  local met,saw=qc({['until']='item_count',platform='Petrel',item='quality-module-3',quality='rare',at_least=5})
  eq(met,true); eq(saw,'quality-module-3 (rare quality) 5 in Petrel hub (landed stock; excludes incoming cargo and hub trash)')
  eq(qc({['until']='item_count',platform='Petrel',item='quality-module-3',quality='uncommon',at_least=10}),true)
  eq(select(2,qc({['until']='item_count',platform='Petrel',item='quality-module-3',at_least=1})):match('^quality%-module%-3 (%d+)'),'2','the name alone: normal quality')
  eq(select(2,qc({['until']='item_count',platform='Petrel',item='quality-module-3',quality='any',at_least=1})):match('(%d+) in Petrel'),'17')
  assert(not pcall(C.validate,{['until']='item_count',platform='Petrel',item='quality-module-3',quality='shiny',at_least=1}),'unknown quality refused')
  local ok,err=pcall(C.validate,{['until']='ammo_below',count=5,quality='rare'})
  assert(not ok and tostring(err):find('quality applies to item_count and platform_ammo_below only',1,true),tostring(err))
end
print('conditions: ok')
