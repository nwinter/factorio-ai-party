-- d22 batch105 BO1 (Astra #1927): the endurance forecast took a leg flown only in part (Asterion: the first 13-15% of
-- aquilo->solar-system-edge, then back) as the whole connection, and scaled the outer legs "x1.00". Now each leg flown
-- counts the game's spawn chance over the part of its connection flown (freight's km0, km1), the leg flown now counts too
-- (the moving rate does), and each route leg says how much of it the legs flown cover.
-- Run from the harness root: lua tests/d22_batch105.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,m) assert(math.abs(a-b)<1e-9,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields}); return u end
local rocket_ammo={action={{type='direct',action_delivery={{type='projectile',projectile='rocket'}}}}}
defines={inventory={turret_ammo=1}}
prototypes={
  item={rocket=ud{type='ammo',ammo_category=ud{name='rocket'},magazine_size=1,get_ammo_type=function() return rocket_ammo end}},
  quality={normal=ud{default_multiplier=1}},
  entity={['medium-metallic-asteroid']=ud{type='asteroid',get_max_health=function() return 400 end,resistances={explosion={decrease=0,percent=0.3}},dying_trigger_effect={}},
    rocket=ud{type='projectile',attack_result={{action_delivery={{target_effects={{type='damage',damage={amount=200,type='explosion'}}}}}}}},
    ['rocket-turret']=ud{attack_parameters={cooldown=120,ammo_categories={'rocket'}}}},
  -- the spawn chance rises along the connection from aquilo: 0 at its start, 0.01 halfway, 0.02 at the edge
  space_connection={ae=ud{from=ud{name='aquilo'},to=ud{name='solar-system-edge'},length=100000,asteroid_spawn_definitions={
      {asteroid='medium-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0},{distance=0.5,probability=0.01},{distance=1,probability=0.02}}}}},
    na=ud{from=ud{name='nauvis'},to=ud{name='aquilo'},length=50000,asteroid_spawn_definitions={
      {asteroid='medium-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.005},{distance=1,probability=0.005}}}}}},
}
game={tick=60*3600}
local force=ud{get_ammo_damage_modifier=function() return 0 end,get_turret_attack_modifier=function() return 0 end,get_gun_speed_modifier=function() return 0 end}
local P=dofile('mod/agent-harness_0.1.0/platdefense.lua'){}
local AR=dofile('mod/agent-harness_0.1.0/ammorate.lua'){}
local segs={}
local R=dofile('mod/agent-harness_0.1.0/routeammo.lua'){segments=function() return segs end,ammorate=AR,damages=P.damages}

-- the mean over a part of the leg, the way it is flown: [0, 0.25] of the curve is 0 -> 0.005, its mean 0.0025; the
-- whole leg's 0.01; the same part flown back (75-100% of edge->aquilo) the same
near(R.density_range('aquilo','solar-system-edge',0,0.25)['medium-metallic-asteroid'],0.0025)
near(R.density_range('solar-system-edge','aquilo',0.75,1)['medium-metallic-asteroid'],0.0025)
near(R.density_range('aquilo','solar-system-edge',0,1)['medium-metallic-asteroid'],R.density('aquilo','solar-system-edge')['medium-metallic-asteroid'])
near(R.density('aquilo','solar-system-edge')['medium-metallic-asteroid'],0.01)
near(R.density_range('aquilo','solar-system-edge',0.5,0.5)['medium-metallic-asteroid'],0.01,'a point: the curve there')

-- Asterion's flights: out to 25% and back (15 + 6 minutes), and out again now, 10% after 10 minutes
segs={
  {kind='leg',from='aquilo',to='solar-system-edge',start=game.tick-60*3600,['end']=game.tick-45*3600,km0=0,km1=25000},
  {kind='leg',from='solar-system-edge',to='aquilo',start=game.tick-45*3600,['end']=game.tick-39*3600,km0=75000,km1=100000},
  {kind='leg',from='aquilo',to='solar-system-edge',start=game.tick-10*3600,km0=0,km1=10000}}
local function turret()
  local inv=ud{get_contents=function() return {{name='rocket',quality='normal',count=10}} end}
  return ud{name='rocket-turret',prototype=prototypes.entity['rocket-turret'],get_inventory=function() return inv end}
end
local pl=ud{surface=ud{find_entities_filtered=function() return {turret()} end},force=force}
local rows={{name='rocket',stock=1000,phases={moving={used_per_min=10,made_per_min=0}}}}
local legs={{from='aquilo',to='solar-system-edge',km=100000,minutes=100},{from='nauvis',to='aquilo',km=50000,minutes=50}}
local lines,_,coverage=R.forecast(pl,legs,rows,{})
local text=table.concat(lines,'\n')
has(text,'scaled from the legs flown in the last 2 hours (each the part of its connection flown, and minutes): aquilo->solar-system-edge 0-25% 15m00s, solar-system-edge->aquilo 75-100% 6m00s, aquilo->solar-system-edge 0-10% (flying now) 10m00s (31m00s)')
has(text,'their asteroids are the game\'s spawn chance over the part flown')
has(text,'aquilo->solar-system-edge 100000 km, 1h40m: asteroids (spawn chance, mean over the leg): medium-metallic-asteroid 0.0100 (flown 0.0020); the legs flown cover 25% of it (0-25%); the other 75% is the game\'s spawn definition, not measured')
-- flown: (0.0025 x 15 + 0.0025 x 6 + 0.001 x 10) / 31 = 0.002016; the leg's 0.01 over it: x4.96
has(text,'uses about 4960 (10/min on the legs flown x4.96 for these asteroids)')
has(text,'nauvis->aquilo 50000 km, 50m00s: asteroids (spawn chance, mean over the leg): medium-metallic-asteroid 0.0050 (flown 0.0020); the legs flown include none of this connection: all of it is the game\'s spawn definition, scaled by the rate measured elsewhere')
eq(#coverage,2); eq(coverage[1].leg,'aquilo->solar-system-edge'); eq(coverage[1].flown,'0-25%'); eq(coverage[1].flights,3); eq(coverage[1].covered,0.25)
eq(coverage[2].flown,nil); eq(coverage[2].covered,0)

-- a leg recorded before km0 and km1 were kept, flown whole, counts as the whole connection; one opened mid-flight with
-- none is said so
segs={{kind='leg',from='aquilo',to='solar-system-edge',start=game.tick-60*3600,['end']=game.tick-10*3600}}
text=table.concat((R.forecast(pl,legs,rows,{})),'\n')
has(text,'aquilo->solar-system-edge 0-100% 50m00s'); has(text,'the legs flown cover all of it (0-100%)')
segs={{kind='leg',from='aquilo',to='solar-system-edge',start=game.tick-60*3600,['end']=game.tick-10*3600,partial=true}}
text=table.concat((R.forecast(pl,legs,rows,{})),'\n')
has(text,'aquilo->solar-system-edge (the part flown not recorded: the whole connection taken) 50m00s')
print('d22_batch105 BO1 forecast over the part flown: ok')
