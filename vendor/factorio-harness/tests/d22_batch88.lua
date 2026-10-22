-- d22 batch88 AX1 (Astra #1876): platform_endurance's forecast reads 3 rockets a 400 hp medium asteroid and 89
-- magazines, where platform_defense ammo_use gives 1160 explosion and 51.2 physical a shot and a measured drill used 160
-- rockets for 160 kills. 2.0.77 keeps an ammunition's category on its item prototype (ammo_category); its ammo type has
-- none (read on a private copy of world n), so the forecast found no damage bonus and no turret. Fakes shaped as 2.0.77
-- gives them; the shot from ammorate.row with platdefense's damage reader, as ammo_use; the resistance arithmetic.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

local function trigger(child, n) return {{type='create-entity',entity_name=child,offsets=(function() local o={} for i=1,n do o[i]={0,0} end return o end)()}} end
local function asteroid(hp, res, child) return {type='asteroid',get_max_health=function() return hp end,resistances=res,dying_trigger_effect=child and trigger(child,3) or {}} end
-- the ammo types as 2.0.77 gives them: no category
local bullet={action={{type='direct',action_delivery={{type='instant',target_effects={{type='damage',damage={amount=5,type='physical'}}}}}}}}
local rocket_ammo={action={{type='direct',action_delivery={{type='projectile',projectile='rocket'}}}}}
defines={inventory={turret_ammo=1}}
prototypes={
  item={['firearm-magazine']={type='ammo',ammo_category={name='bullet'},magazine_size=10,get_ammo_type=function() return bullet end},
    rocket={type='ammo',ammo_category={name='rocket'},magazine_size=1,get_ammo_type=function() return rocket_ammo end}},
  quality={normal={default_multiplier=1},rare={default_multiplier=1.6}},
  entity={['big-metallic-asteroid']=asteroid(2000,{physical={decrease=2000,percent=0.1},explosion={decrease=0,percent=0.1}},'medium-metallic-asteroid'),
    ['medium-metallic-asteroid']=asteroid(400,{physical={decrease=0,percent=0.1},explosion={decrease=0,percent=0.3}},'small-metallic-asteroid'),
    ['medium-oxide-asteroid']=asteroid(400,{physical={decrease=0,percent=0.1},explosion={decrease=0,percent=0.3}},'small-oxide-asteroid'),
    ['small-metallic-asteroid']=asteroid(100,{explosion={decrease=0,percent=0.5}}),
    ['small-oxide-asteroid']=asteroid(100,{explosion={decrease=0,percent=0.5}}),
    rocket={type='projectile',attack_result={{action_delivery={{target_effects={{type='damage',damage={amount=200,type='explosion'}}}}}}}},
    ['gun-turret']={attack_parameters={cooldown=6,ammo_categories={'bullet'}}},
    ['rocket-turret']={attack_parameters={cooldown=120,ammo_categories={'rocket'}}}},
  space_connection={ga={from={name='gleba'},to={name='aquilo'},length=30000,asteroid_spawn_definitions={
    {asteroid='big-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.001},{distance=1,probability=0.001}}},
    {asteroid='medium-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.002},{distance=1,probability=0.002}}},
    {asteroid='medium-oxide-asteroid',type='entity',spawn_points={{distance=0,probability=0.001},{distance=1,probability=0.001}}}}}},
}
game={tick=8*3600}
-- Asterion's research (the copy): stronger explosives +480% rocket damage; physical projectile damage +220% bullet,
-- weapon damage +220% gun-turret attack
local force={get_ammo_damage_modifier=function(c) return ({rocket=4.8,bullet=2.2})[c] or 0 end,
  get_turret_attack_modifier=function(t) return t=='gun-turret' and 2.2 or 0 end,get_gun_speed_modifier=function() return 0 end}

do
  local P=dofile('mod/agent-harness_0.1.0/platdefense.lua'){}
  local AR=dofile('mod/agent-harness_0.1.0/ammorate.lua'){}
  local R=dofile('mod/agent-harness_0.1.0/routeammo.lua'){segments=function() return {} end,ammorate=AR,damages=P.damages}
  eq(R.category('rocket'),'rocket','the item prototype\'s ammo_category')
  -- the shot as ammo_use gives it
  local row=AR.row(force,{turret='rocket-turret',quality='normal',ammo='rocket',ammo_quality='normal'},{},P.damages)
  local h=R.hit('rocket','normal',force,'rocket-turret')
  eq(h.total,row.damage_per_shot,'the forecast\'s shot is ammo_use\'s'); eq(h.total,1160)
  eq(math.floor(R.hit('firearm-magazine','normal',force,'gun-turret').total*100+0.5)/100,51.2,'5 x 3.2 x 3.2')
  -- shots per asteroid after resistances: 1160 x 0.7 = 812 a medium (1), x 0.9 = 1044 a big (2); 51.2 x 0.9 = 46.08 (9)
  eq(R.shots('medium-metallic-asteroid','rocket',force,'rocket-turret'),1,'one rocket a medium (the drill: 160 for 160)')
  eq(R.shots('big-metallic-asteroid','rocket',force,'rocket-turret'),2)
  eq(R.shots('medium-metallic-asteroid','firearm-magazine',force,'gun-turret'),9)
  eq(R.shots('big-metallic-asteroid','firearm-magazine',force,'gun-turret'),false,'under the 2000 flat')
  -- quality: rare magazines x 1.6 (81.92 a shot, 73.7 a hit on a medium: 6)
  eq(R.shots('medium-metallic-asteroid','firearm-magazine',force,'gun-turret','rare'),6)
  -- the lines
  has(R.hit_line('rocket','normal',force,'rocket-turret'),'rocket (rocket-turret, normal): 1160 explosion a shot = 200 explosion x (1 +480% rocket damage) x (1 +0% rocket-turret attack)')
  has(R.hit_line('firearm-magazine','rare',force,'gun-turret'),'81.9 physical a shot = 5 physical x 1.6 quality x (1 +220% bullet damage) x (1 +220% gun-turret attack)')
  local line,r=R.vs_line('medium-metallic-asteroid','rocket','normal',force,'rocket-turret')
  eq(line,'medium-metallic-asteroid 400 hp: explosion (1160 - 0 flat) x (1 - 30%) = 812 a hit: 1 shot'); eq(r.shots,1)
  line=R.vs_line('big-metallic-asteroid','firearm-magazine','normal',force,'gun-turret')
  has(line,'physical 51.2 is not over the 2000 flat: 1 / (2 + 2000 - 51.2) x (1 - 10%) = 0.00046 a hit: under 1 a hit: cannot hurt it')

  -- the forecast: the turret found by ammo_category, the ammunition's quality from the turrets holding it; shots per
  -- asteroid from those; the damage block, asteroids alike sharing a line; forecast_damage rows
  local function turret(name, ammo, quality)
    local inv={get_contents=function() return {{name=ammo,quality=quality,count=10}} end}
    return {name=name,prototype=prototypes.entity[name],get_inventory=function() return inv end}
  end
  local pl={surface={find_entities_filtered=function() return {turret('gun-turret','firearm-magazine','normal'),turret('rocket-turret','rocket','normal')} end},force=force}
  local rows={{name='rocket',stock=500},{name='firearm-magazine',stock=1000}}
  local lines,drows=R.forecast(pl,{{from='gleba',to='aquilo',km=30000,minutes=36}},rows,{})
  local text=table.concat(lines,'\n')
  has(text,'rocket (rocket-turret): shots per asteroid medium-metallic-asteroid 1 + 3 for its fragments')
  has(text,'big-metallic-asteroid 2 + 12 for its fragments')  -- 3 medium x 1, 9 small x 1
  has(text,'firearm-magazine (gun-turret): shots per asteroid medium-metallic-asteroid 9 + 6 for its fragments')
  has(text,'damage a shot (as platform_defense ammo_use gives it) and a hit on each asteroid after its resistances')
  has(text,'\n  rocket (rocket-turret, normal): 1160 explosion a shot')
  has(text,'\n    medium-metallic/oxide-asteroid 400 hp: explosion (1160 - 0 flat) x (1 - 30%) = 812 a hit: 1 shot')
  has(text,'\n    small-metallic/oxide-asteroid 100 hp: explosion (1160 - 0 flat) x (1 - 50%) = 580 a hit: 1 shot')
  has(text,'\n    big-metallic-asteroid 2000 hp: explosion (1160 - 0 flat) x (1 - 10%) = 1044 a hit: 2 shots')
  local found
  for _, d in ipairs(drows) do if d.ammo=='rocket' and d.asteroid=='big-metallic-asteroid' then found=d end end
  eq(found.shots,2); eq(found.per_hit,1044); eq(found.turret,'rocket-turret'); eq(found.damage_per_shot,1160); eq(found.hp,2000)
  -- rare rockets in the turrets: x 1.6 (1856 a shot: a big one in 2 still, 1670.4 a hit)
  pl.surface.find_entities_filtered=function() return {turret('rocket-turret','rocket','rare')} end
  lines=R.forecast(pl,{{from='gleba',to='aquilo',km=30000,minutes=36}},{{name='rocket',stock=500}},{})
  has(table.concat(lines,'\n'),'rocket (rocket-turret, rare): 1856 explosion a shot = 200 explosion x 1.6 quality x (1 +480% rocket damage)')
  -- research since the last forecast: a new bonus is read (no stale shot kept)
  force.get_ammo_damage_modifier=function(c) return c=='rocket' and 0 or 0 end
  lines=R.forecast(pl,{{from='gleba',to='aquilo',km=30000,minutes=36}},{{name='rocket',stock=500}},{})
  has(table.concat(lines,'\n'),'rocket (rocket-turret, rare): 320 explosion a shot')
end
defines,prototypes,game=nil,nil,nil
print('d22_batch88 AX1 forecast damage as ammo_use: ok')
