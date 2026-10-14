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
print('conditions: ok')
