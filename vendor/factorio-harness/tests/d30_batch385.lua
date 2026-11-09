-- Sol #2825: paper target profiles price rail/bullet fragments without editing native turrets.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn); assert(not ok); has(e,x) end
local function snapshot(x)
  if type(x)~='table' then return tostring(x) end
  local keys={}; for k in pairs(x) do keys[#keys+1]=k end
  table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
  local out={}; for _,k in ipairs(keys) do out[#out+1]=tostring(k)..'='..snapshot(x[k]) end
  return '{'..table.concat(out,',')..'}'
end
defines={inventory={turret_ammo=1,hub_main=1}}
game={tick=600}
local huge,big,medium='huge-metallic-asteroid','big-metallic-asteroid','medium-metallic-asteroid'
local function ammo(cat,damage,mag)
  return {type='ammo',ammo_category={name=cat},magazine_size=mag or 1,get_ammo_type=function()
    return {action={{action_delivery={{type='instant',target_effects={{type='damage',damage={amount=damage,type='physical'}}}}}}}}
  end}
end
prototypes={item={['railgun-ammo']=ammo('railgun',100),['firearm-magazine']=ammo('bullet',5,10),rocket=ammo('rocket',50)},
  quality={normal={default_multiplier=1}},entity={},space_location={['solar-system-edge']={},['shattered-planet']={}},
  space_connection={a={from={name='solar-system-edge'},to={name='shattered-planet'},length=4000000,
    asteroid_spawn_definitions={{asteroid=huge,type='entity',spawn_points={{distance=0,probability=.01},{distance=1,probability=.01}}}}}}}
local function asteroid(name,hp,child)
  prototypes.entity[name]={type='asteroid',get_max_health=function() return hp end,resistances={},
    dying_trigger_effect=child and {{type='create-entity',entity_name=child,repeat_count=3}} or {}}
end
asteroid(huge,1000,big); asteroid(big,100,medium); asteroid(medium,20)
prototypes.entity['iron-chest']={type='container'}
local turrets={}
local function turret(name,cat,held,targets,ignore)
  local native={priority_targets=targets,ignore_unprioritised_targets=ignore}
  local t=setmetatable({name=name,prototype={attack_parameters={ammo_categories={cat}}},
    get_inventory=function() return {get_contents=function() return {{name=held,count=10}} end} end},
    {__index=native,__newindex=function(_,key) error('native turret write: '..key) end})
  prototypes.entity[name]={type='ammo-turret',attack_parameters={damage_modifier=1}}
  turrets[#turrets+1]=t
  return native
end
local rails={}
for i=1,41 do rails[i]=turret('railgun-turret','railgun','railgun-ammo',{{name=huge}},true) end
local gun=turret('gun-turret','bullet','firearm-magazine',{{name=medium}},true)
local rocket=turret('rocket-turret','rocket','rocket',{{name=big}},true)
local function profiles() return snapshot{rails=rails,gun=gun,rocket=rocket} end
local native_before=profiles()
local pl={index=1,name='Asterion',surface={find_entities_filtered=function() return turrets end},
  force={get_ammo_damage_modifier=function() return 0 end,get_turret_attack_modifier=function() return 0 end},
  space_location={name='solar-system-edge'}}
local E=require('endurance'){platform=function() return pl end}
local function read(targets,noammo)
  return E.read({},{platform='Asterion',forecast=true,route={'solar-system-edge','shattered-planet'},
    design={width=35,height=160,speed=40,ammo=not noammo and {'railgun-ammo','firearm-magazine'} or nil,
      stock=not noammo and {['railgun-ammo']=1000000,['firearm-magazine']=1000000} or nil,targets=targets}})
end
local function row(rows,name) for _,r in ipairs(rows) do if r.turret==name then return r end end; error(name) end
local plain=read(nil)
local only=read({['railgun-turret']={huge}})
local both=read({['railgun-turret']={huge,big}})
eq(only.target_source,'design.targets'); eq(plain.target_source,'platform')
eq(snapshot(plain.legs),snapshot(only.legs))
eq(only.legs[1].total,60400); eq(only.legs[1].km,4000000); eq(only.legs[1].minutes,1666.7)
eq(only.legs[1].shots['railgun-ammo'],604000); eq(only.legs[1].shots['firearm-magazine'],0)
eq(both.legs[1].shots['railgun-ammo'],785200); eq(both.legs[1].shots['firearm-magazine'],2174400)
eq(#both.effective_targets,2); eq(#both.current_targets,3)
eq(row(both.effective_targets,'railgun-turret').count,41)
eq(row(both.effective_targets,'railgun-turret').source,'design.targets')
eq(row(both.effective_targets,'gun-turret').source,'platform')
eq(#row(both.current_targets,'railgun-turret').targets,1)
eq(#row(both.effective_targets,'railgun-turret').targets,2)
eq(#row(both.ammo_details[2].targets,'railgun-turret').targets,2)
eq(profiles(),native_before)
eq(snapshot(read(nil).legs),snapshot(plain.legs),'override never leaks into a later read')
local none=read({['railgun-turret']={}})
eq(none.legs[1].shots['railgun-ammo'],0); eq(none.legs[1].shots['firearm-magazine'],0)
local any=read({['railgun-turret']='any'})
eq(row(any.effective_targets,'railgun-turret').targets,'any')
eq(any.legs[1].shots['railgun-ammo'],1328800)
eq(row(read({}).effective_targets,'railgun-turret').source,'platform')
-- Implicit loaded ammo also accepts target overrides; other turret profiles stay native.
local loaded=read({['railgun-turret']={huge,big}},true)
eq(loaded.ammo_details,nil); eq(#loaded.ammo,3); eq(#loaded.effective_targets,3)
-- Duplicate targets form a set without mutating the supplied list.
local targets={['railgun-turret']={huge,big,huge}}
local before=snapshot(targets)
eq(snapshot(read(targets).legs),snapshot(both.legs)); eq(snapshot(targets),before)
has(table.concat(both.estimated,'; '),'piercing'); has(table.concat(both.estimated,'; '),'interception order')
has(both.basis.shots,'effective_targets')
fails(function() read({['not-a-turret']='any'}) end,'accepted: gun-turret, railgun-turret')
fails(function() read({['rocket-turret']='any'}) end,'accepted: gun-turret, railgun-turret')
fails(function() read({['iron-chest']='any'}) end,'accepted: gun-turret, railgun-turret')
fails(function() read({['railgun-turret']={'not-an-asteroid'}}) end,'accepted: big-metallic-asteroid, huge-metallic-asteroid, medium-metallic-asteroid')
fails(function() read({['railgun-turret']={'iron-chest'}}) end,'accepted: big-metallic-asteroid, huge-metallic-asteroid, medium-metallic-asteroid')
for _,bad in ipairs{true,'huge',123,{bad=true},{[1]=huge,[3]=big},{false}} do
  fails(function() read({['railgun-turret']=bad}) end,'design.targets')
end
fails(function() read('any') end,'design.targets')
eq(profiles(),native_before)
print('d30_batch385: ok')
