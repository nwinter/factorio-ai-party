-- Actual 2.0.77 action shapes, including nested results without a type field.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local raw=dofile('tests/fixtures/ammo-effects-2.0.77.lua')
local reads=0
prototypes={item={},entity={},quality={normal={default_multiplier=1},legendary={default_multiplier=2.5}}}
for name,at in pairs(raw.ammo) do
  prototypes.item[name]={get_ammo_type=function() reads=reads+1; return at end}
end
for name,p in pairs(raw.entities) do
  prototypes.entity[name]=setmetatable({},{__index=function(_,k)
    reads=reads+1
    return k=='attack_result' and p.attack or k=='final_attack_result' and p.final or nil
  end})
end
local D=require('ammodetail')
local rocket=D.read('rocket').prototype
eq(rocket.direct_damage.explosion,200); eq(#rocket.area_damage,0)
local explosive=D.read('explosive-rocket').prototype
eq(explosive.direct_damage.explosion,50); eq(#explosive.area_damage,1)
eq(explosive.area_damage[1].damage.explosion,100); eq(explosive.area_damage[1].radius,6.5)
eq(explosive.area_damage[1].friendly_fire,'yes')
local atomic=D.read('atomic-bomb').prototype
eq(atomic.direct_damage.explosion,400); eq(#atomic.area_damage,2); eq(atomic.truncated,nil)
local ground=atomic.projectiles['atomic-bomb-ground-zero-projectile'].attack[1]
eq(ground.radius,3); eq(ground.friendly_fire,'yes')
eq(ground.action_delivery[1].target_effects[1].damage.amount,100)
local wave=atomic.projectiles['atomic-bomb-wave'].attack[1]
eq(wave.radius,3); eq(wave.action_delivery[1].target_effects[1].damage.amount,400)
eq(wave.action_delivery[1].target_effects[1].upper_distance_threshold,35)
local nested=atomic.projectiles['atomic-rocket'].attack[1].action_delivery[1].target_effects
eq(nested[15].type,'nested-action'); eq(nested[15].action[1].repeat_count,1000)
eq(nested[15].action[1].radius,7); eq(nested[16].action[1].radius,35)
-- Warm reads and quality changes never reread the large trigger prototypes.
local count=reads
eq(D.read('atomic-bomb').prototype,atomic)
local legendary=D.read('explosive-rocket','legendary')
eq(legendary.prototype,explosive); eq(legendary.quality_multiplier,2.5)
eq(legendary.prototype.area_damage[1].damage.explosion,100); eq(reads,count)
-- Preserve the existing scalar: explosive's direct + area once, atomic's direct only.
local P=dofile('mod/agent-harness_0.1.0/platdefense.lua'){}
for name,want in pairs({rocket=200,['explosive-rocket']=150,['atomic-bomb']=400}) do
  local list={}; P.damages(raw.ammo[name].action,list,{})
  local sum=0; for _,v in ipairs(list) do sum=sum+v.amount end
  eq(sum,want)
end
-- Friendly-fire exclusions are explicit strings, including in compact output.
prototypes.item.filtered={get_ammo_type=function() return {action={{type='area',radius=2,force='enemy',
  action_delivery={{target_effects={{type='damage',damage={type='physical',amount=3}}}}}}}} end}
eq(D.read('filtered').prototype.area_damage[1].friendly_fire,'no')
-- Cyclic projectile references terminate; incomplete large graphs are marked.
prototypes.item.cycle={get_ammo_type=function() return {action={{projectile='cycle'}}} end}
prototypes.entity.cycle={attack_result={{projectile='cycle'}}}
eq(D.read('cycle').prototype.truncated,nil)
local many={}; for i=1,600 do many[i]={type='direct'} end
prototypes.item.large={get_ammo_type=function() return {action=many} end}
eq(D.read('large').prototype.truncated,true)
print('d32_batch411: ok')
