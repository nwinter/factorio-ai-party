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
local surface={find_entities_filtered=function(f)
  if f.force=='enemy' then
    local out={}
    for _,e in ipairs({worm,nest,biter}) do
      for _,t in ipairs(f.type) do if t==e.type then out[#out+1]=e end end
    end
    return out
  end
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
assert(not pcall(C.validate,{['until']='bogus'}))
assert(not pcall(C.validate,{['until']='health_below'}))
assert(not pcall(C.validate,{['until']='item_count',item='firearm-magazine'}))
assert(not pcall(C.validate,{['until']='ammo_below',count=0}))
assert(not pcall(C.validate,{['until']='no_enemies',radius=500}))
print('conditions: ok')
