-- d22 batch105 BO2 (Astra 20:24: "forecast rocket line counts 432 shots per huge and scales x8.85, but Asterion rocket
-- turrets target ONLY big asteroids; rails handle huge"): the forecast's shots count for each ammunition only the
-- asteroids its turrets target as built (priority list, ignore unprioritised targets); an asteroid no turret targets
-- counts for none, nor its fragments; per ammunition its turrets' settings, per asteroid the turrets that target it.
-- Run from the harness root: lua tests/d22_batch105b.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields}); return u end
local function direct(amount,kind) return {action={{type='direct',action_delivery={{type='instant',target_effects={{type='damage',damage={amount=amount,type=kind}}}}}}}} end
local function ammo(cat,at) return ud{type='ammo',ammo_category=ud{name=cat},magazine_size=10,get_ammo_type=function() return at end} end
local function asteroid(hp,child)
  return ud{type='asteroid',get_max_health=function() return hp end,resistances={},
    dying_trigger_effect=child and {{type='create-entity',entity_name=child,offsets={{0,0},{1,0},{0,1}}}} or {}}
end
defines={inventory={turret_ammo=1}}
prototypes={
  item={['firearm-magazine']=ammo('bullet',direct(100,'physical')),rocket=ammo('rocket',direct(1000,'explosion')),['railgun-ammo']=ammo('railgun',direct(10000,'physical'))},
  quality={normal=ud{default_multiplier=1}},
  entity={['huge-metallic-asteroid']=asteroid(5000,'big-metallic-asteroid'),['big-metallic-asteroid']=asteroid(2000,'medium-metallic-asteroid'),
    ['medium-metallic-asteroid']=asteroid(400,'small-metallic-asteroid'),['small-metallic-asteroid']=asteroid(100),['huge-oxide-asteroid']=asteroid(5000),
    ['gun-turret']=ud{attack_parameters={cooldown=10,ammo_categories={'bullet'}}},['rocket-turret']=ud{attack_parameters={cooldown=120,ammo_categories={'rocket'}}},
    ['railgun-turret']=ud{attack_parameters={cooldown=60,ammo_categories={'railgun'}}}},
  -- the route's connection spawns huge metallic and (less) huge oxide; the one flown, big metallic only
  space_connection={ae=ud{from=ud{name='aquilo'},to=ud{name='solar-system-edge'},length=100000,asteroid_spawn_definitions={
      {asteroid='huge-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.01},{distance=1,probability=0.01}}},
      {asteroid='huge-oxide-asteroid',type='entity',spawn_points={{distance=0,probability=0.005},{distance=1,probability=0.005}}}}},
    na=ud{from=ud{name='nauvis'},to=ud{name='aquilo'},length=50000,asteroid_spawn_definitions={
      {asteroid='big-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.01},{distance=1,probability=0.01}}}}}},
}
game={tick=60*3600}
local force=ud{get_ammo_damage_modifier=function() return 0 end,get_turret_attack_modifier=function() return 0 end,get_gun_speed_modifier=function() return 0 end}
local P=dofile('mod/agent-harness_0.1.0/platdefense.lua'){}
local AR=dofile('mod/agent-harness_0.1.0/ammorate.lua'){}
local segs={{kind='leg',from='nauvis',to='aquilo',start=game.tick-40*3600,['end']=game.tick-10*3600,km0=0,km1=50000}}
local R=dofile('mod/agent-harness_0.1.0/routeammo.lua'){segments=function() return segs end,ammorate=AR,damages=P.damages}
-- a turret as built: its ammunition, ignore unprioritised targets, its priority list (nil ignore: not read)
local function turret(name,item,ignore,list)
  local inv=ud{get_contents=function() return {{name=item,quality='normal',count=10}} end}
  local pt={}
  for i,n in ipairs(list or {}) do pt[i]=ud{name=n} end
  return ud{name=name,prototype=prototypes.entity[name],get_inventory=function() return inv end,ignore_unprioritised_targets=ignore,priority_targets=pt}
end
local list={turret('railgun-turret','railgun-ammo',true,{'huge-metallic-asteroid'}),
  turret('rocket-turret','rocket',true,{'big-metallic-asteroid'}),turret('rocket-turret','rocket',true,{'big-metallic-asteroid'}),
  turret('rocket-turret','rocket',true,{'big-metallic-asteroid','medium-metallic-asteroid'}),
  turret('gun-turret','firearm-magazine',true,{'medium-metallic-asteroid','small-metallic-asteroid'})}
local pl=ud{surface=ud{find_entities_filtered=function() return list end},force=force}
local rows={{name='rocket',stock=1000,phases={moving={used_per_min=10,made_per_min=0}}},{name='firearm-magazine',stock=1000,phases={moving={used_per_min=10,made_per_min=0}}},
  {name='railgun-ammo',stock=1000,phases={moving={used_per_min=1,made_per_min=0}}}}
local legs={{from='aquilo',to='solar-system-edge',km=100000,minutes=100}}
local lines,_,_,targets=R.forecast(pl,legs,rows,{})
local text=table.concat(lines,'\n')
-- rocket: a huge metallic is the railgun's (3 big each: 2 shots + 3 medium each, which one of its turrets targets: 1
-- shot; their small fragments not its): 15; huge oxide no turret targets: 0. Flown big metallic: 2 + 3 = 5. 0.15 / 0.05
has(text,'  rocket (rocket-turret): shots per asteroid huge-metallic-asteroid not its turrets\' target + 15 for its fragments, huge-oxide-asteroid: no turret aboard targets it; uncalibrated: 100% of this leg\'s shooting is at kinds the legs flown met none of (huge-metallic-asteroid); uses about 3000 (10/min on the legs flown x3.00 for these asteroids)')
-- gun: medium 4 + 3 small x 1 = 7, big 21, huge 63; flown 21: x3.00
has(text,'  firearm-magazine (gun-turret): shots per asteroid huge-metallic-asteroid not its turrets\' target + 63 for its fragments, huge-oxide-asteroid: no turret aboard targets it; uncalibrated: 100% of this leg\'s shooting is at kinds the legs flown met none of (huge-metallic-asteroid); uses about 3000 (10/min on the legs flown x3.00')
-- railgun: huge metallic 1, its fragments none of its; the leg flown spawned nothing it targets
has(text,'  railgun-ammo (railgun-turret): shots per asteroid huge-metallic-asteroid 1, huge-oxide-asteroid: no turret aboard targets it; the legs flown spawn none it shoots: no use estimate')
has(text,'turret targets as built (each turret\'s priority list, the turret GUI\'s: with ignore unprioritised targets on it fires at the listed asteroids only, off at any)')
has(text,'  rocket: 3 turrets fire it, mixed settings: 2 rocket-turret big-metallic only; 1 rocket-turret big-metallic, medium-metallic only')
has(text,'  railgun-ammo: 1 turret fires it: 1 railgun-turret huge-metallic only')
has(text,'  huge-oxide-asteroid: no turret aboard targets it: no ammunition counted for it or its fragments')
has(text,'  medium-metallic-asteroid: gun-turret 1 (firearm-magazine), rocket-turret 1 (rocket)')
has(text,'  huge-metallic-asteroid: railgun-turret 1 (railgun-ammo)')
eq(targets.ammo[1].ammo,'rocket'); eq(targets.ammo[1].turrets,3); eq(targets.ammo[1].mixed,true); eq(targets.ammo[1].settings[2].targets[2],'medium-metallic-asteroid')
local by={}
for _,a in ipairs(targets.asteroids) do by[a.asteroid]=a.turrets end
eq(#by['huge-oxide-asteroid'],0); eq(by['medium-metallic-asteroid'][2].turret,'rocket-turret'); eq(by['medium-metallic-asteroid'][2].ammo[1],'rocket')

-- a gun turret with ignore unprioritised targets off fires at any (huge oxide too: 50 shots); one not read is counted
-- as any and said so
list[5]=turret('gun-turret','firearm-magazine',false,{'small-metallic-asteroid'})
list[6]=turret('gun-turret','firearm-magazine',nil,{})
text=table.concat((R.forecast(pl,legs,rows,{})),'\n')
has(text,'  firearm-magazine: 2 turrets fire it, mixed settings: 1 gun-turret any asteroid (ignore unprioritised targets off); 1 gun-turret its targets not read (counted as any)')
has(text,'huge-oxide-asteroid 50')
has(text,'  huge-oxide-asteroid: gun-turret 2 (firearm-magazine)')
-- no turret aboard read: every asteroid counted for each ammunition, as before
list={}
text=table.concat((R.forecast(pl,legs,rows,{})),'\n')
has(text,'no turret aboard read: every asteroid counted for each ammunition')
has(text,'huge-metallic-asteroid 5 + 42 for its fragments')
print('d22_batch105b BO2 forecast by turret targets: ok')
