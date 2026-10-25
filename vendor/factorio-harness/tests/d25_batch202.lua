-- Run from repository root: lua tests/d25_batch202.lua
-- d25 batch202. QO1 (Sol #2326: platform_defense's ammo_use had no rows for laser and other electric turrets, and the
-- force's laser damage bonus could not be read): electric turret rows (ammorate.electric), the force's research bonuses
-- (platform_defense bonuses), electric turrets in the route's damage. QO2 (viewer Aurora site:4874: Lark's part-used
-- magazines blurred supply checks): rounds left beside magazines (vehicles.inventory_rounds) in platform_defense's
-- turret rows and ammo_use, and the vehicle read's guns. The numbers are a copy of world n's d25 07:26 save (2.0.77):
-- a laser turret's hits there, 94 laser every 12.5 ticks at laser-weapons-damage 1-8 and laser-shooting-speed 1-7.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,m) assert(math.abs(a-b)<1e-6,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end

local function hit(amount,kind) return {{type='direct',action_delivery={{type='instant',target_effects={{type='damage',damage={amount=amount,type=kind}}}}}}} end
local QM={normal=1,uncommon=1.3,rare=1.6,epic=1.9,legendary=2.5}
local function setup()
  defines={inventory={turret_ammo=7,hub_main=1}}
  local techs={}
  local function tech(name,level,effects,max) techs[name]={name=name,level=level,max_level=max or level,effects=effects} end
  for i,v in ipairs({0.2,0.2,0.3,0.4,0.5,0.7}) do tech('laser-weapons-damage-'..i,i,{{type='ammo-damage',ammo_category='laser',modifier=v}}) end
  tech('laser-weapons-damage-7',7,{{type='ammo-damage',ammo_category='laser',modifier=0.7}},4294967295)
  for i,v in ipairs({0.1,0.2,0.2,0.3,0.4,0.5,0.5}) do tech('laser-shooting-speed-'..i,i,{{type='gun-speed',ammo_category='laser',modifier=v}}) end
  for i=1,4 do tech('electric-weapons-damage-'..i,i,{{type='ammo-damage',ammo_category='tesla',modifier=0.7},{type='ammo-damage',ammo_category='electric',modifier=0.7}}) end
  for i,v in ipairs({0.1,0.1,0.2,0.2,0.2,0.2}) do tech('physical-projectile-damage-'..i,i,{{type='ammo-damage',ammo_category='bullet',modifier=v},{type='turret-attack',turret_id='gun-turret',modifier=v}}) end
  local function source(drain,buffer,inflow) return {drain=drain,buffer_capacity=buffer,get_input_flow_limit=function(q) return inflow*QM[q] end} end
  prototypes={technology=techs,
    entity={['laser-turret']={type='electric-turret',attack_parameters={cooldown=40,damage_modifier=2,ammo_categories={'laser'},range=24,min_range=0,
        ammo_type={energy_consumption=800000,action={{type='direct',action_delivery={{type='beam',beam='laser-beam',duration=40}}}}}},
        electric_energy_source_prototype=source(400,801000,160000),get_max_health=function(q) return 1000*QM[q] end},
      ['laser-beam']={type='beam',attack_result=hit(10,'laser')},
      ['tesla-turret']={type='electric-turret',attack_parameters={cooldown=120,damage_modifier=1,ammo_categories={'tesla'},range=30,min_range=0,
        ammo_type={energy_consumption=12000000,action={{type='direct',action_delivery={{type='instant',target_effects={
          {action={{type='direct',action_delivery={{type='chain',chain='chain-tesla-turret-chain'}}}}},
          {action={{type='direct',action_delivery={{type='beam',beam='chain-tesla-turret-beam-start'}}}}}}}}}}}},
        electric_energy_source_prototype=source(16666.666666667,15000000,116666.66666667),get_max_health=function(q) return 1000*QM[q] end},
      ['chain-tesla-turret-beam-start']={type='beam',attack_result=hit(120,'electric')},
      ['gun-turret']={type='ammo-turret',attack_parameters={cooldown=6,ammo_consumption_modifier=1,damage_modifier=1,ammo_categories={'bullet'},range=18,min_range=0}},
      ['small-metallic-asteroid']={type='asteroid',get_max_health=function() return 100 end,resistances={laser={decrease=0,percent=0.2},physical={decrease=0,percent=0.1}}}},
    item={['firearm-magazine']={type='ammo',magazine_size=10,ammo_category={name='bullet'},get_ammo_type=function() return {cooldown_modifier=1,consumption_modifier=false,action=hit(5,'physical')} end},
      ['rocket']={type='ammo',magazine_size=1,ammo_category={name='rocket'}}},
    quality={},active_trigger={['chain-tesla-turret-chain']={max_jumps=10,max_range_per_jump=12}},
    space_connection={['nauvis-vulcanus']={name='nauvis-vulcanus',from={name='nauvis'},to={name='vulcanus'},asteroid_spawn_definitions={{type='entity',asteroid='small-metallic-asteroid'}}}}}
  for q,m in pairs(QM) do prototypes.quality[q]={default_multiplier=m} end
  prototypes.get_entity_filtered=function(f) local o={} for k,v in pairs(prototypes.entity) do if v.type==f[1].type then o[k]=v end end return o end
  prototypes.get_item_filtered=function(f) local o={} for k,v in pairs(prototypes.item) do if v.type==f[1].type then o[k]=v end end return o end
  local ft={}
  for name,pt in pairs(techs) do ft[name]={prototype=pt,researched=true,level=pt.level} end
  ft['laser-weapons-damage-7'].researched=false; ft['laser-weapons-damage-7'].level=9
  ft['electric-weapons-damage-4'].researched=false
  local speed={laser=2.2,bullet=0}
  local dmg={laser=3.7,tesla=2.1,electric=2.1,bullet=1.4}
  return {name='player',technologies=ft,get_gun_speed_modifier=function(c) return speed[c] or 0 end,get_ammo_damage_modifier=function(c) return dmg[c] or 0 end,
    get_turret_attack_modifier=function(t) return t=='gun-turret' and 1.4 or 0 end,speed=speed}
end
-- an ammunition stack: count items, the top one holding ammo rounds
local function stack(name,count,ammo,q) return {valid_for_read=true,name=name,count=count,ammo=ammo,quality={name=q or 'normal'}} end
local EMPTY={valid_for_read=false}
local function inventory(stacks)
  local inv={}
  for i,s in ipairs(stacks) do inv[i]=s end
  inv.is_empty=function() for i=1,#stacks do if stacks[i].valid_for_read then return false end end return true end
  inv.get_contents=function()
    local out,by={},{}
    for i=1,#stacks do local s=stacks[i] if s.valid_for_read then local k=s.name..s.quality.name if not by[k] then by[k]={name=s.name,count=0,quality=s.quality.name}; out[#out+1]=by[k] end by[k].count=by[k].count+s.count end end
    return out
  end
  return setmetatable(inv,{__len=function() return #stacks end})
end

-- QO1: a laser turret's row as the copy measured it; quality changes health and recharge only
do
  local force=setup()
  local A=dofile('mod/agent-harness_0.1.0/ammorate.lua'){}
  local src=A.sources(force)
  eq(A.source_text(src,'ammo-damage:laser',3.7),'laser-weapons-damage 1-8 (+370%)')
  eq(A.source_text(src,'gun-speed:laser',2.2),'laser-shooting-speed 1-7 (+220%)')
  local r=A.electric(force,{turret='laser-turret',quality='rare',turrets=22,where='built'},src)
  eq(r.kind,'electric'); eq(r.category,'laser'); near(r.cooldown_ticks,12.5); eq(r.base_cooldown_ticks,40); eq(r.shots_per_min,288)
  near(r.damage_per_shot,94); near(r.damage.laser,94); eq(r.base_damage,10); eq(r.damage_modifier,2); near(r.damage_per_second,451.2); near(r.damage_per_second_all,9926.4)
  eq(r.energy_per_shot_kj,800); eq(r.buffer_kj,801); eq(r.drain_kw,24); eq(r.recharge_kw,15360); eq(r.power_kw,3864); eq(r.recharge_limited,nil)
  eq(r.quality_effect.max_health,1600); eq(r.quality_effect.multiplier,1.6)
  eq(r.sources.damage,'laser-weapons-damage 1-8 (+370%)'); eq(r.sources.turret_attack,'none researched')
  eq(r.line,'laser-turret (rare) x22, electric (laser): a shot every 12.5 ticks (40 over 1 +220% shooting speed), 288 shots/min; 94 laser a shot (10 base x 2 turret x (1 +370% damage) x (1 +0% laser-turret attack)), 451/s each, 9926/s for the 22; 800 kJ a shot from its 801 kJ buffer, recharge 15360 kW at rare, drain 24 kW: 3864 kW at full fire; quality rare: max health 1600 and recharge x1.6, damage and rate unchanged; shooting speed: laser-shooting-speed 1-7 (+220%); damage: laser-weapons-damage 1-8 (+370%); laser-turret attack: none researched')
  -- normal and legendary: the same shot (measured on the copy), the health and recharge apart
  local n=A.electric(force,{turret='laser-turret',quality='normal',turrets=1},src)
  local l=A.electric(force,{turret='laser-turret',quality='legendary',turrets=1},src)
  near(n.damage_per_shot,94); near(l.damage_per_shot,94); eq(n.shots_per_min,288); eq(l.shots_per_min,288)
  eq(n.recharge_kw,9600); eq(l.recharge_kw,24000); eq(n.quality_effect.max_health,1000); eq(l.quality_effect.max_health,2500)
  -- the shooting speed bonus at 0 (the copy: one hit in 40 ticks)
  force.speed.laser=0
  eq(A.electric(force,{turret='laser-turret',quality='normal'},A.read_sources(force)).shots_per_min,90)
  -- a tesla turret: 372 electric on its target (120 x 3.1), its chain named; with shooting speed past what its recharge
  -- refills, the recharge sets the rate
  local t=A.electric(force,{turret='tesla-turret',quality='normal'},src)
  near(t.damage_per_shot,372); eq(t.shots_per_min,30); eq(t.chain.max_jumps,10); eq(t.chain.range_per_jump,12); eq(t.recharge_limited,nil)
  has(t.line,'372 electric a shot (120 base x 1 turret x (1 +210% damage) x (1 +0% tesla-turret attack)), then a chain of up to 10 jumps, 12 tiles each, to more targets, 186/s each')
  force.speed.tesla=0.5
  t=A.electric(force,{turret='tesla-turret',quality='normal'},src)
  eq(t.shots_per_min,45); eq(t.recharge_limited,true); near(t.shots_per_min_powered,35); near(t.damage_per_second,217)
  has(t.line,'45 shots/min (its recharge allows 35)')
  -- the force's bonuses for the categories aboard, the turrets' attack bonuses
  force.speed.laser=2.2
  local rows,lines=A.bonuses(force,{laser={'laser-turret'},bullet={'gun-turret'}},{'laser-turret','gun-turret'})
  eq(#rows.categories,2); eq(rows.categories[1].category,'bullet'); eq(rows.categories[2].category,'laser')
  near(rows.categories[2].damage_bonus,3.7); near(rows.categories[2].shooting_speed_bonus,2.2)
  eq(rows.categories[2].damage_sources,'laser-weapons-damage 1-8 (+370%)')
  eq(#rows.turret_attack,1); eq(rows.turret_attack[1].turret,'gun-turret'); eq(rows.turret_attack[1].sources,'physical-projectile-damage 1-6 (+100%), +40% not from research')
  eq(lines[2],'laser (laser-turret): damage +370% (laser-weapons-damage 1-8 (+370%)), shooting speed +220% (laser-shooting-speed 1-7 (+220%))')
  defines,prototypes=nil,nil
end
print('d25_batch202 QO1 electric turret rows and bonuses: ok')

-- QO2: rounds left in an ammunition inventory, and in the vehicle read's guns
do
  setup()
  local V=dofile('mod/agent-harness_0.1.0/vehicles.lua'){}
  -- 3 stacks: 10 full magazines, 5 with the top one at 3 rounds, legendary 2 with 7; rockets (one round an item)
  local inv=inventory({stack('firearm-magazine',10,10),EMPTY,stack('firearm-magazine',5,3),stack('firearm-magazine',2,7,'legendary'),stack('rocket',4,1)})
  local rows=V.inventory_rounds(inv,{})
  eq(#rows,3)
  eq(rows[1].name,'firearm-magazine'); eq(rows[1].count,15); eq(rows[1].rounds,143); eq(rows[1].magazine_size,10); eq(rows[1].partial,1)
  eq(rows[2].quality,'legendary'); eq(rows[2].count,2); eq(rows[2].rounds,17); eq(rows[2].partial,1)
  eq(rows[3].name,'rocket'); eq(rows[3].rounds,4); eq(rows[3].partial,nil)
  eq(V.rounds_text(rows),'firearm-magazine*15 (143 rounds) firearm-magazine@legendary*2 (17 rounds) rocket*4')
  eq(V.rounds_text(V.inventory_rounds(inventory({EMPTY}))),nil)
  eq(#V.inventory_rounds(nil),0)
  -- the vehicle read's guns: magazines and rounds left
  local guns={{name='tank-machine-gun',attack_parameters={ammo_categories={'bullet'},range=20}},{name='tank-cannon',attack_parameters={ammo_categories={'cannon-shell'},range=30}}}
  local ammo=inventory({stack('firearm-magazine',20,4),EMPTY})
  local tank={type='car',prototype={indexed_guns=guns},get_inventory=function() return ammo end}
  defines.inventory.car_ammo=3
  local g=V.guns(tank)
  eq(g[1].count,20); eq(g[1].rounds,194); eq(g[1].magazine_size,10); eq(g[2].rounds,0)
  eq(V.gun_lines(g,1)[1],'1 tank-machine-gun: 20 firearm-magazine (194 rounds) (range 20) selected')
  eq(V.gun_lines(g,1)[2],'2 tank-cannon: no ammo (range 30)')
  eq(V.rounds(tank,1),194)
  defines,prototypes=nil,nil
end
print('d25_batch202 QO2 rounds left: ok')

-- platform_defense: laser turrets' rows beside the ammo turrets', the bonuses, rounds in the turret rows, the route's
-- damage with the lasers (a small metallic asteroid resists laser 20%: 75.2 a hit)
do
  local force=setup()
  local function turret(name,q,x,stacks)
    local e={valid=true,type=prototypes.entity[name].type,name=name,quality={name=q},position={x=x,y=0},bounding_box={left_top={x=x-1,y=-1},right_bottom={x=x+1,y=1}},
      prototype=prototypes.entity[name],ignore_unprioritised_targets=false,get_priority_target=function() return nil end,direction=0,energy=801000}
    if stacks then local inv=inventory(stacks); e.get_inventory=function() return inv end end
    return e
  end
  local list={turret('laser-turret','rare',0),turret('laser-turret','rare',4),turret('gun-turret','normal',8,{stack('firearm-magazine',10,6)}),
    turret('gun-turret','normal',12,{stack('firearm-magazine',4,10)})}
  local hub={get_inventory=function() return inventory({EMPTY}) end}
  local s={find_entities_filtered=function(f) if f.type=='asteroid-collector' or f.type=='inserter' then return {} end return list end,find_tiles_filtered=function() return {} end}
  local A=dofile('mod/agent-harness_0.1.0/ammorate.lua'){}
  local V=dofile('mod/agent-harness_0.1.0/vehicles.lua'){}
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Asterion',surface=s,force=force,hub=hub} end,ammorate=A,
    inventory_rounds=V.inventory_rounds,rounds_text=V.rounds_text}
  game={tick=100}
  local r=D.read({},{platform='Asterion',route='nauvis->vulcanus'})
  -- the turret rows: magazines and rounds
  eq(r.turrets[3].ammo,'firearm-magazine*10 (96 rounds)'); eq(r.turrets[3].rounds,96); eq(r.turrets[4].rounds,40); eq(r.turrets[1].rounds,nil)
  eq(r.turrets[1].ammo,'electric')
  -- ammo_use: the gun turrets' row with what they hold, the lasers' row
  eq(#r.ammo_use,2)
  local g,l=r.ammo_use[1],r.ammo_use[2]
  eq(g.turret,'gun-turret'); eq(g.turrets,2); eq(g.items_held,14); eq(g.rounds_held,136); has(g.line,'; held: 14 items, 136 rounds left')
  near(g.damage_per_second,288)
  eq(l.turret,'laser-turret'); eq(l.kind,'electric'); eq(l.turrets,2); eq(l.where,'built'); near(l.damage_per_shot,94)
  -- the bonuses field and its line
  eq(r.bonuses.categories[1].category,'bullet'); eq(r.bonuses.categories[2].category,'laser'); eq(r.bonuses.categories[2].turrets[1],'laser-turret')
  local bl
  for _,line in ipairs(r.lines) do if line:find('^research bonuses') then bl=line end end
  has(bl,'laser (laser-turret): damage +370% (laser-weapons-damage 1-8 (+370%)), shooting speed +220% (laser-shooting-speed 1-7 (+220%))')
  -- the route: each laser turret 75.2 a hit after the asteroid's 20%, 4.8 hits a second
  local dl
  for _,line in ipairs(r.lines) do if line:find('small-metallic-asteroid',1,true) then dl=line end end
  has(dl,'2 laser-turret with power: 361/s each (80.0% of its listed 451/s)')
  -- with the gun turrets' 25.92 a shot after its 10%, 10 shots a second
  near(r.damage[1].dps,2*75.2*4.8+2*25.92*10)
  -- "all": every electric turret prototype too
  local all=D.read({},{platform='Asterion',ammo_use='all'}).ammo_use
  local kinds={}
  for _,x in ipairs(all) do if x.kind=='electric' then kinds[#kinds+1]=x.turret..'|'..x.quality..'|'..x.where end end
  eq(table.concat(kinds,' '),'laser-turret|normal|any laser-turret|rare|built tesla-turret|normal|any')
  game,defines,prototypes=nil,nil,nil
end
print('d25_batch202 platform_defense electric rows, bonuses and rounds: ok')
