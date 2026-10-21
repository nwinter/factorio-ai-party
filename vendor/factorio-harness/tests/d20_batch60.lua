-- Run from repository root: lua tests/d20_batch60.lua
-- d20 batch60 V1 (Sol #1470: an outer-ship supply design needed rounds a minute and damage a shot for each weapon at the
-- research done; platform_defense gave damage a second only). ammorate.lua per turret and ammunition: shots a minute
-- (cooldown over 1 + shooting speed), rounds a shot and a magazine, items a minute, damage a shot (quality, damage and
-- turret attack bonuses), the technologies each bonus comes from; in platform_defense. The numbers are the private
-- copy's (2.0.77, its force's research), where they matched a turret firing at one target kept in reach.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,m) assert(math.abs(a-b)<1e-6,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end

local function hit(amount,kind) return {{type='direct',action_delivery={{type='instant',target_effects={{type='damage',damage={amount=amount,type=kind}}}}}}} end
local function ammo(cat,mag,action) return {type='ammo',magazine_size=mag,ammo_category={name=cat},get_ammo_type=function(src) assert(src=='turret'); return {category=nil,cooldown_modifier=1,consumption_modifier=false,action=action} end} end
local function techset()
  local list={}
  local function tech(name,level,effects,max) list[name]={name=name,level=level,max_level=max or level,effects=effects} end
  local speed={{0.1},{0.2},{0.2},{0.3,0.5},{0.3,0.9},{0.4,1.3}}
  speed[4]={0.3,0.7}
  for i,v in ipairs(speed) do
    local e={{type='gun-speed',ammo_category='bullet',modifier=v[1]}}
    if v[2] then e[2]={type='gun-speed',ammo_category='rocket',modifier=v[2]} end
    tech('weapon-shooting-speed-'..i,i,e)
  end
  speed[3]={0.2,0.5}
  list['weapon-shooting-speed-3'].effects[2]={type='gun-speed',ammo_category='rocket',modifier=0.5}
  local dmg={0.1,0.1,0.2,0.2,0.2,0.2}
  for i,v in ipairs(dmg) do tech('physical-projectile-damage-'..i,i,{{type='ammo-damage',ammo_category='bullet',modifier=v},{type='turret-attack',turret_id='gun-turret',modifier=v}}) end
  tech('physical-projectile-damage-7',7,{{type='ammo-damage',ammo_category='bullet',modifier=0.2},{type='turret-attack',turret_id='gun-turret',modifier=0.2}},4294967295)
  for i,v in ipairs({0.3,0.4,0.5,0.6}) do tech('stronger-explosives-'..(i+2),i+2,{{type='ammo-damage',ammo_category='rocket',modifier=v}}) end
  tech('stronger-explosives-7',7,{{type='ammo-damage',ammo_category='rocket',modifier=0.5}},4294967295)
  tech('laser-shooting-speed-1',1,{{type='gun-speed',ammo_category='laser',modifier=0.1}})
  tech('automation',1,{{type='unlock-recipe',recipe='assembling-machine-1'}})
  return list
end
local function setup()
  defines={inventory={turret_ammo=7,hub_main=1}}
  local techs=techset()
  prototypes={technology=techs,
    entity={['gun-turret']={type='ammo-turret',attack_parameters={cooldown=6,ammo_consumption_modifier=1,damage_modifier=1,ammo_categories={'bullet'},range=18,min_range=0}},
      ['rocket-turret']={type='ammo-turret',attack_parameters={cooldown=120,ammo_consumption_modifier=1,damage_modifier=1,ammo_categories={'rocket'},range=36,min_range=15}},
      ['railgun-turret']={type='ammo-turret',attack_parameters={cooldown=170,ammo_consumption_modifier=1,damage_modifier=1,ammo_categories={'railgun'},range=40,min_range=3.5,turn_range=0.2}},
      ['rocket']={type='projectile',attack_result=hit(200,'explosion')}},
    item={['firearm-magazine']=ammo('bullet',10,hit(5,'physical')),['rocket']=ammo('rocket',1,{{type='direct',action_delivery={{type='projectile',projectile='rocket'}}}}),
      ['railgun-ammo']=ammo('railgun',1,hit(10000,'physical')),['iron-plate']={type='item'}},
    quality={normal={default_multiplier=1},uncommon={default_multiplier=1.3},legendary={default_multiplier=2.5}}}
  prototypes.get_entity_filtered=function() local o={} for k,v in pairs(prototypes.entity) do if v.type=='ammo-turret' then o[k]=v end end return o end
  prototypes.get_item_filtered=function() local o={} for k,v in pairs(prototypes.item) do if v.type=='ammo' then o[k]=v end end return o end
  local ft={}
  for name,pt in pairs(techs) do ft[name]={prototype=pt,researched=true,level=pt.level} end
  ft['physical-projectile-damage-7'].researched=false; ft['physical-projectile-damage-7'].level=9
  ft['stronger-explosives-7'].researched=false; ft['stronger-explosives-7'].level=9
  ft['laser-shooting-speed-1'].researched=false
  local speed={bullet=1.5,rocket=3.4,railgun=0}
  local dmg={bullet=1.4,rocket=2.8,railgun=0.25}
  return {name='player',technologies=ft,get_gun_speed_modifier=function(c) return speed[c] or 0 end,get_ammo_damage_modifier=function(c) return dmg[c] or 0 end,
    get_turret_attack_modifier=function(t) return t=='gun-turret' and 1.4 or 0 end}
end

-- the bonuses' sources, an infinite technology's levels
do
  local force=setup()
  local A=dofile('mod/agent-harness_0.1.0/ammorate.lua'){}
  eq(A.levels({researched=false,level=9},{level=7,max_level=4294967295}),2,'levels 7 and 8 done, 9 under way')
  eq(A.levels({researched=true,level=9},{level=7,max_level=4294967295}),3)
  eq(A.levels({researched=false,level=7},{level=7,max_level=4294967295}),0)
  eq(A.levels({researched=true,level=3},{level=3,max_level=3}),1)
  local src=A.sources(force)
  near(src['gun-speed:bullet'].sum,1.5); near(src['gun-speed:rocket'].sum,3.4); near(src['ammo-damage:bullet'].sum,1.4); near(src['turret-attack:gun-turret'].sum,1.4)
  near(src['ammo-damage:rocket'].sum,2.8); eq(src['gun-speed:laser'],nil,'not researched')
  eq(A.source_text(src,'gun-speed:bullet',1.5),'weapon-shooting-speed 1-6 (+150%)')
  eq(A.source_text(src,'ammo-damage:bullet',1.4),'physical-projectile-damage 1-8 (+140%)')
  eq(A.source_text(src,'ammo-damage:rocket',2.8),'stronger-explosives 3-8 (+280%)')
  eq(A.source_text(src,'ammo-damage:railgun',0.25),'+25% not from research')
  eq(A.source_text(src,'gun-speed:railgun',0),'none researched')
  eq(A.source_text(src,'gun-speed:bullet',1.6),'weapon-shooting-speed 1-6 (+150%), +10% not from research')
  defines,prototypes=nil,nil
end
print('d20_batch60 V1 bonus sources: ok')

-- platform_defense ammo_use: two gun turrets (normal and legendary) with normal magazines, one with legendary ones too,
-- a rocket turret, a railgun turret with nothing (the hub's railgun ammunition counted for it), a bare one of no kind
do
  local force=setup()
  local function turret(name,q,x,held)
    local e={valid=true,type='ammo-turret',name=name,quality={name=q},position={x=x,y=0},bounding_box={left_top={x=x-1,y=-1},right_bottom={x=x+1,y=1}},
      prototype=prototypes.entity[name],ignore_unprioritised_targets=false,get_priority_target=function() return nil end,direction=0}
    e.get_inventory=function() return {get_contents=function() return held end} end
    return e
  end
  local list={turret('gun-turret','normal',0,{{name='firearm-magazine',count=20,quality='normal'},{name='firearm-magazine',count=5,quality='legendary'}}),
    turret('gun-turret','normal',4,{{name='firearm-magazine',count=20,quality='normal'}}),
    turret('gun-turret','legendary',8,{{name='firearm-magazine',count=20,quality='normal'}}),
    turret('rocket-turret','normal',20,{{name='rocket',count=40,quality='normal'}}),
    turret('railgun-turret','normal',40,{})}
  local hub={get_inventory=function() return {get_contents=function() return {{name='railgun-ammo',count=12,quality='normal'},{name='iron-plate',count=100,quality='normal'}} end} end}
  local s={find_entities_filtered=function(f) if f.type=='asteroid-collector' or f.type=='inserter' then return {} end return list end,find_tiles_filtered=function() return {} end}
  local A=dofile('mod/agent-harness_0.1.0/ammorate.lua'){}
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Edge8',surface=s,force=force,hub=hub} end,ammorate=A}
  game={tick=100}
  local r=D.read({},{platform='Edge8'})
  local rows=r.ammo_use
  eq(#rows,5)
  local by={}
  for _,x in ipairs(rows) do by[x.turret..'|'..x.quality..'|'..x.ammo..'|'..x.ammo_quality]=x end
  local g=by['gun-turret|normal|firearm-magazine|normal']
  eq(g.turrets,2); eq(g.where,'held'); near(g.cooldown_ticks,2.4); eq(g.shots_per_min,1500); eq(g.rounds_per_shot,1); eq(g.magazine_size,10); near(g.items_per_shot,0.1)
  eq(g.items_per_min,150); eq(g.items_per_min_all,300); near(g.damage_per_shot,28.8); near(g.damage.physical,28.8); eq(g.quality_multiplier,1)
  eq(g.sources.shooting_speed,'weapon-shooting-speed 1-6 (+150%)'); eq(g.sources.damage,'physical-projectile-damage 1-8 (+140%)'); eq(g.sources.turret_attack,'physical-projectile-damage 1-8 (+140%)')
  eq(g.line,'gun-turret (normal) x2 with firearm-magazine (normal): a shot every 2.4 ticks (6 over 1 +150% shooting speed), 1500 shots/min; 1 round a shot, 10 rounds an item: 150 items/min each, 300/min for the 2; 28.8 physical a shot (5 base x (1 +140% damage) x (1 +140% gun-turret attack)); shooting speed: weapon-shooting-speed 1-6 (+150%); damage: physical-projectile-damage 1-8 (+140%); gun-turret attack: physical-projectile-damage 1-8 (+140%)')
  -- legendary magazines: the damage x 2.5 (the copy: 61.9 a shot on a behemoth worm, 72 less its 10 flat), the rate as before
  local l=by['gun-turret|normal|firearm-magazine|legendary']
  eq(l.turrets,1); near(l.damage_per_shot,72); eq(l.quality_multiplier,2.5); eq(l.shots_per_min,1500)
  has(l.line,'72 physical a shot (5 base x 2.5 quality x (1 +140% damage) x (1 +140% gun-turret attack))')
  -- a legendary turret: the same shots and damage (the copy: normal and legendary used the same 718 rounds in 1722 ticks)
  local q=by['gun-turret|legendary|firearm-magazine|normal']
  eq(q.shots_per_min,1500); near(q.damage_per_shot,28.8)
  local rk=by['rocket-turret|normal|rocket|normal']
  near(rk.cooldown_ticks,27.273); eq(rk.shots_per_min,132); eq(rk.items_per_min,132); near(rk.damage_per_shot,760); near(rk.damage.explosion,760)
  eq(rk.sources.damage,'stronger-explosives 3-8 (+280%)'); eq(rk.sources.shooting_speed,'weapon-shooting-speed 3-6 (+340%)'); eq(rk.sources.turret_attack,'none researched')
  has(rk.line,'a shot every 27.3 ticks (120 over 1 +340% shooting speed), 132 shots/min; 1 round a shot, 1 round an item: 132 items/min each')
  local rg=by['railgun-turret|normal|railgun-ammo|normal']
  eq(rg.where,'hub'); eq(rg.turrets,1); eq(rg.shots_per_min,21.2); near(rg.items_per_min,21.18); near(rg.damage_per_shot,12500)
  eq(rg.sources.damage,'+25% not from research'); eq(rg.sources.shooting_speed,'none researched')
  has(rg.line,'railgun-turret (normal) x1 with railgun-ammo (normal) (in the hub, not in these turrets): a shot every 170 ticks')
  local head
  for i,line in ipairs(r.lines) do if line:find('^ammunition use at full fire') then head=i end end
  assert(head,'the heading')
  has(r.lines[head],'turret\'s quality changes neither (measured)')
  -- false: none; "all": every ammo turret with every ammunition of its categories
  eq(D.read({},{platform='Edge8',ammo_use=false}).ammo_use,nil)
  local all=D.read({},{platform='Edge8',ammo_use='all'}).ammo_use
  eq(#all,5,'every ammo turret and ammunition here already has its row')
  local ok,err=pcall(D.read,{},{platform='Edge8',ammo_use='yes'})
  assert(not ok and tostring(err):find('ammo_use is true, false or "all"',1,true),tostring(err))
  -- a turret with no ammunition and none in the hub
  list={turret('rocket-turret','uncommon',20,{})}
  hub.get_inventory=function() return {get_contents=function() return {} end} end
  r=D.read({},{platform='Edge8'})
  eq(r.ammo_use,nil)
  local bare
  for _,line in ipairs(r.lines) do if line:find('no ammunition held') then bare=line end end
  eq(bare,'  rocket-turret (uncommon) x1: no ammunition held or in the hub')
  all=D.read({},{platform='Edge8',ammo_use='all'}).ammo_use
  eq(#all,3); eq(all[1].turret,'gun-turret'); eq(all[1].where,'any'); eq(all[2].turret,'railgun-turret'); eq(all[3].ammo,'rocket'); eq(all[3].quality,'normal')
  game,defines,prototypes=nil,nil,nil
end
print('d20_batch60 V1 platform_defense ammo_use: ok')

-- V2 (Sol #1499: IVc's collector ghosts at (-8.5,-14.5) and (-4.5,-14.5) read "no foundation under 3 of its tiles" and
-- the hub built them with their front row over empty space). The floor as the game checks it: the prototypes' tile
-- rules as 2.0.77 gives them (the private copy), the box past them by the collision mask; the game's placement check
-- last. The cases are the copy's test platform, where a revive of each ghost agreed.
do
  local ES={doodad=true,empty_space=true,floor=true,ground_tile=true,item=true,object=true,player=true,resource=true,water_tile=true}
  local FOUND={ground_tile=true}
  local found={}
  for x=-30,29 do for y=-5,4 do found[x..','..y]=true end end
  local tghost={}
  local function tile(x,y) local f=found[x..','..y]; return {name=f and 'space-platform-foundation' or 'empty-space',prototype={collision_mask={layers=f and FOUND or ES}}} end
  local function inside(ar,x,y) return x>=ar[1][1] and x<ar[2][1] and y>=ar[1][2] and y<ar[2][2] end
  local place={}
  local s={get_tile=tile,
    count_entities_filtered=function(f) local n=0 for k in pairs(tghost) do local x,y=k:match('(-?%d+),(-?%d+)'); if inside(f.area,tonumber(x),tonumber(y)) then n=n+1 end end return n end,
    count_tiles_filtered=function(f) assert(f.name=='empty-space' and f.invert) local n=0 for x=f.area[1][1],f.area[2][1]-1 do for y=f.area[1][2],f.area[2][2]-1 do if found[x..','..y] then n=n+1 end end end return n end,
    can_place_entity=function(a) place[#place+1]=a; return a.position.x==-777 end}
  defines={build_check_type={ghost_revive=3}}
  local collector={collision_mask={layers={is_lower_object=true,is_object=true,transport_belt=true}},tile_buildability_rules={
    {area={left_top={x=-1.39844,y=-0.398438},right_bottom={x=1.39844,y=1.39844}},required_tiles={layers={ground_tile=true}},colliding_tiles={layers={empty_space=true}},remove_on_collision=true},
    {area={left_top={x=-1.39844,y=-4.39844},right_bottom={x=1.39844,y=-0.597656}},required_tiles={layers={empty_space=true}},remove_on_collision=true}}}
  local thruster={collision_mask={layers={is_lower_object=true,is_object=true,item=true,object=true,train=true}},tile_buildability_rules={
    {area={left_top={x=-1.79688,y=-2.29688},right_bottom={x=1.79688,y=2.29688}},required_tiles={layers={ground_tile=true}},colliding_tiles={layers={empty_space=true}},remove_on_collision=true},
    {area={left_top={x=-1.79688,y=2.69922},right_bottom={x=1.79688,y=90.2969}},required_tiles={layers={empty_space=true}},remove_on_collision=true}}}
  local belt={collision_mask={layers={floor=true,meltable=true,object=true,transport_belt=true,water_tile=true}},tile_buildability_rules={}}
  local BOX={['asteroid-collector']={1.19922,1.19922},thruster={1.69922,2.19922},['transport-belt']={0.4,0.4}}
  local PROTO={['asteroid-collector']=collector,thruster=thruster,['transport-belt']=belt}
  local function ghost(name,x,y,dir)
    local w,h=BOX[name][1],BOX[name][2]
    if dir==4 then w,h=h,w end
    return {type='entity-ghost',ghost_name=name,ghost_prototype=PROTO[name],position={x=x,y=y},direction=dir or 0,force='player',
      bounding_box={left_top={x=x-w,y=y-h},right_bottom={x=x+w,y=y+h}}}
  end
  local GL=dofile('mod/agent-harness_0.1.0/ghostlist.lua'){}
  local function floor(name,x,y,dir) return GL.floor(s,ghost(name,x,y,dir)) end
  -- A: the front row over empty space, the rear rows on foundation (the IVc case): nothing short
  local f=floor('asteroid-collector',-20.5,-4.5)
  eq(f.bare,0); eq(f.not_empty,0); eq(f.overhang,3); eq(f.rules,true); eq(f.placeable,nil,'no placement check when nothing reads short')
  -- H: facing east at the east edge, its front column over space
  f=floor('asteroid-collector',29.5,0.5,4); eq(f.bare,0); eq(f.overhang,3); eq(f.not_empty,0)
  -- B: a rear row over space: those 3 need foundation (the old count said 6)
  f=floor('asteroid-collector',-15.5,-5.5); eq(f.bare,3); eq(f.placeable,false)
  -- C: the front row on foundation: refused for that
  f=floor('asteroid-collector',-10.5,-3.5); eq(f.bare,0); eq(f.not_empty,3); eq(f.placeable,false)
  -- D, E: a thruster with space behind it; with foundation in its exhaust row
  f=floor('thruster',10,2.5); eq(f.bare,0); eq(f.not_empty,0)
  f=floor('thruster',20,1.5); eq(f.bare,0); eq(f.not_empty,4)
  -- F, G: a belt (no rules: its mask meets empty space's object layer) over space and on foundation
  f=floor('transport-belt',25.5,-6.5); eq(f.bare,1); eq(f.rules,nil)
  f=floor('transport-belt',25.5,-4.5); eq(f.bare,0)
  -- a foundation ghost under the rear row: waits for it
  tghost['-17,-6']=true; tghost['-16,-6']=true; tghost['-15,-6']=true
  f=floor('asteroid-collector',-15.5,-5.5); eq(f.bare,0); eq(f.ghosted,3)
  tghost={}
  eq(place[1].build_check_type,3); eq(place[1].name,'asteroid-collector'); eq(place[1].direction,0)
  -- the verdicts: the IVc case names no foundation; the rear-row case and the front-on-foundation case name theirs
  local pl={hub={valid=true,get_item_count=function() return 1 end}}
  s.platform=pl
  local v,info=GL.platform_blocker(s,ghost('asteroid-collector',-20.5,-4.5),'asteroid-collector',1)
  eq(v,'the hub holds 1 asteroid-collector'); eq(info.no_foundation,nil); eq(info.over_empty_space,3)
  v,info=GL.platform_blocker(s,ghost('asteroid-collector',-15.5,-5.5),'asteroid-collector',1)
  eq(v,'no foundation under 3 of the tiles its tile rules need foundation on and no foundation ghost there: the hub does not build it until foundation is placed; the hub holds 1 asteroid-collector'); eq(info.no_foundation,3)
  v,info=GL.platform_blocker(s,ghost('asteroid-collector',-10.5,-3.5),'asteroid-collector',1)
  eq(v,'foundation (3 tiles) where its tile rules need empty space: the game does not place it there; the hub holds 1 asteroid-collector'); eq(info.not_empty,3)
  v=GL.platform_blocker(s,ghost('transport-belt',25.5,-6.5),'transport-belt',1)
  has(v,'no foundation under 1 of its tiles and no foundation ghost there')
  -- the game's placement check has the last word: a ghost it takes is not held by its floor
  v,info=GL.platform_blocker(s,ghost('transport-belt',-777,-6.5),'transport-belt',1)
  has(v,'its floor as the game checks it (the placement check for reviving this ghost) takes it'); eq(info.floor_ok,true); eq(info.no_foundation,nil)
  defines=nil
end
print('d20_batch60 V2 ghosts floor by the tile rules: ok')
