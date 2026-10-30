-- Sol #2820: design.ammo is exclusive, uses compatible built turrets and selected stock.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn); assert(not ok); has(e,x) end
defines={inventory={turret_ammo=1,hub_main=1}}
game={tick=600}
local function ammo(cat,damage,mag)
  return {type='ammo',ammo_category={name=cat},magazine_size=mag or 1,get_ammo_type=function()
    return {action={{action_delivery={{type='instant',target_effects={{type='damage',damage={amount=damage,type='physical'}}}}}}}}
  end}
end
local huge,big='huge-metallic-asteroid','big-metallic-asteroid'
prototypes={item={['firearm-magazine']=ammo('bullet',10,10),['uranium-rounds-magazine']=ammo('bullet',20,10),
  ['railgun-ammo']=ammo('railgun',100),rocket=ammo('rocket',20),['shotgun-shell']=ammo('shotgun',10),
  ['unsupported-rocket']={type='ammo',ammo_category={name='rocket'},get_ammo_type=function() return {} end}},
  quality={normal={default_multiplier=1}},entity={},space_location={['solar-system-edge']={},['shattered-planet']={}},
  space_connection={a={from={name='solar-system-edge'},to={name='shattered-planet'},length=4000000,
    asteroid_spawn_definitions={{asteroid=huge,type='entity',spawn_points={{distance=0,probability=.01},{distance=1,probability=.01}}}}}}}
prototypes.entity[huge]={type='asteroid',get_max_health=function() return 100 end,resistances={},
  dying_trigger_effect={{type='create-entity',entity_name=big,repeat_count=3}}}
prototypes.entity[big]={type='asteroid',get_max_health=function() return 40 end,resistances={},dying_trigger_effect={}}
local turrets={}
local function turret(name,cat,held,targets)
  local t={name=name,prototype={attack_parameters={ammo_categories={cat}}},ignore_unprioritised_targets=true,
    priority_targets=targets,get_inventory=function() return {get_contents=function() return {{name=held,count=10}} end} end}
  prototypes.entity[name]={attack_parameters={damage_modifier=1}}
  turrets[#turrets+1]=t
  return t
end
local rail=turret('railgun-turret','railgun','railgun-ammo',{{name=huge}})
turret('rocket-turret','rocket','rocket',{{name=big}})
turret('gun-turret','bullet','firearm-magazine',{{name=big}})
turret('gun-turret','bullet','uranium-rounds-magazine',{{name=big}})
local pl={index=1,name='Asterion',surface={find_entities_filtered=function() return turrets end},
  force={get_ammo_damage_modifier=function() return 1 end,get_turret_attack_modifier=function() return 0 end},
  space_location={name='solar-system-edge'},hub={}}
local stock_reads=0
local E=require('endurance'){platform=function() return pl end,stock_places=function(_,want)
  stock_reads=stock_reads+1
  eq(want.rocket,nil)
  return {total={['railgun-ammo']=50,['firearm-magazine']=1000},hub={['railgun-ammo']=40},turrets={['railgun-ammo']=10},
    belts={},hands={},machines={},as_of=590}
end}
local function read(am,extra)
  local d={width=35,height=160,speed=40,ammo=am}
  for k,v in pairs(extra or {}) do d[k]=v end
  return E.read({},{platform='Asterion',design=d,forecast=true,route={'solar-system-edge','shattered-planet'},progress={from=.75,to=1}})
end
local r=read({'railgun-ammo'})
eq(#r.ammo,1); eq(r.ammo[1],'railgun-ammo'); eq(r.ammo_source,'design.ammo')
eq(r.legs[1].shots.rocket,nil); eq(r.legs[1].shots['firearm-magazine'],nil)
eq(r.legs[1].shots['railgun-ammo'],15100)
eq(r.ammo_details[1].damage_per_shot,200); eq(r.ammo_details[1].stock,50)
eq(r.ammo_details[1].stock_source,'platform'); eq(r.ammo_details[1].items_required,15100)
eq(r.ammo_details[1].stock_after,-15050); eq(r.stock_read.as_of,590)
eq(#r.current_targets,3); eq(r.ammo_details[1].targets[1].targets[1],huge)
local override=read({'railgun-ammo','railgun-ammo'},{stock={['railgun-ammo']=20000}})
eq(#override.ammo,1); eq(override.ammo_details[1].stock_source,'design.stock')
eq(override.ammo_details[1].stock_after,4900); eq(stock_reads,1)
-- Unselected rails no longer generate fragments for the selected rockets.
local rockets=read({'rocket'},{stock={rocket=10}})
eq(rockets.legs[1].shots.rocket,0)
local both=read({'railgun-ammo','rocket'},{stock={['railgun-ammo']=10,rocket=10}})
eq(both.legs[1].shots.rocket,45300)
-- Target settings remain current, rather than changing to aim at all asteroids.
rail.priority_targets={}; eq(read({'railgun-ammo'}).legs[1].shots['railgun-ammo'],0)
rail.ignore_unprioritised_targets=false
eq(read({'railgun-ammo'}).legs[1].shots['railgun-ammo'],60400)
local magazines=read({'firearm-magazine','railgun-ammo'},{stock={['firearm-magazine']=20000,['railgun-ammo']=0}})
eq(magazines.ammo_details[1].shots_per_item,10); eq(magazines.ammo_details[1].items_required,9060)
-- No override retains the four loaded names and the light read (no stock).
local before=stock_reads
local plain=read(nil); eq(#plain.ammo,4); eq(plain.ammo_details,nil); eq(stock_reads,before)
for _,name in ipairs{'bad-name','shotgun-shell','unsupported-rocket','iron-plate'} do
  fails(function() read({name}) end,'accepted: firearm-magazine, railgun-ammo, rocket, uranium-rounds-magazine')
end
fails(function() read({}) end,'1..8')
fails(function() read({rocket=10}) end,'1..8')
fails(function() read({'rocket',bad=true}) end,'list')
fails(function() read({[1]='rocket',[3]='railgun-ammo'}) end,'list')
fails(function() read({'rocket'},{stock={['railgun-ammo']=1}}) end,'selected')
fails(function() read({'rocket'},{stock={rocket=-1}}) end,'stock')
fails(function() read(nil,{stock={rocket=10}}) end,'requires design.ammo')
fails(function() read(nil,{turrets={}}) end,'unsupported design field')
fails(function() read(nil,{width=35.5}) end,'design.width')
fails(function() read(nil,{height=0}) end,'design.height')
fails(function() read(nil,{height=math.huge}) end,'design.height')
fails(function() read(nil,{mass=math.huge}) end,'design.mass')
fails(function() read(nil,{speed=0}) end,'design.speed')
fails(function() read(nil,{width=false,tiles={'0,0'}}) end,'not both')
fails(function() E.read({},{platform='Asterion',design={tiles={'0,0'},height=160,speed=40}}) end,'not both')
print('d30_batch384: ok')
