package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local checks=0
local function eq(a,b) checks=checks+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
defines={inventory={hub_main=1,turret_ammo=2,artillery_turret_ammo=3},space_platform_state={on_the_path=1}}
prototypes={item={rocket={type='ammo'},['repair-pack']={type='repair-tool'}},entity={}}
for _,size in ipairs({'small','medium','big','huge'}) do prototypes.entity[size..'-metallic-asteroid']={} end
game={tick=1000,tick_paused=false,speed=1}
local held={{name='rocket',count=100,quality='normal'},{name='rocket',count=20,quality='uncommon'},
  {name='repair-pack',count=5,quality='rare'}}
local hub={valid=true,get_inventory=function(id) eq(id,1); return {get_contents=function() return held end} end}
local guns={
  {name='rocket-turret',type='ammo-turret',unit_number=10,shooting_target={valid=true},
   get_inventory=function(id) eq(id,2); return {get_contents=function() return {{name='rocket',count=3}} end} end},
  {name='rocket-turret',type='ammo-turret',unit_number=11,
   get_inventory=function() return {get_contents=function() return {} end} end},
  {name='laser-turret',type='electric-turret',unit_number=12}}
for _,e in ipairs(guns) do e.kills=e.unit_number; e.damage_dealt=e.unit_number*10 end
local tanks={{get_fluid_count=function(name) return name=='thruster-fuel' and 1500 or 2000 end}}
local surface={name='platform-test',valid=true}
surface.find_entities_filtered=function(a)
  if a.type[1]=='thruster' then eq(a.limit,129); return tanks end
  eq(a.limit,257); return guns
end
surface.count_entities_filtered=function(a) eq(a.limit,4097); eq(#a.name,1); return a.name[1]:find('huge') and 0 or 3 end
local force={name='player',get_item_production_statistics=function(s)
  eq(s,surface); return {input_counts={rocket=210},output_counts={rocket=90}}
end}
local pl={name='Resolute',surface=surface,hub=hub,force=force,speed=2,space_connection={name='deep'}}
local leg={from='edge',to='shattered',back=false,length=4000,left_km=3000,flown=.25}
local seg={kind='leg',from='edge',to='shattered',start=500}
local stored={}; local hits={hits=10,damage=50}
local m=require('platformmetrics'){
  state=function() return stored end,platform=function(name) eq(name,'Resolute'); return pl end,
  leg=function() return leg end,segments=function() return {seg} end,hits=function() return hits end,
  losses=function(f,s,t) eq(f,'player'); eq(s,'platform-test'); eq(t,500); return {},2 end}
local a={platform='Resolute',area={{-50,-50},{50,50}}}
local r=m.read(a)
eq(r.leg.pct,25); eq(r.leg.left_km,3000); eq(r.leg.start_tick,500); eq(r.speed_kms,120)
eq(r.losses_leg,2); eq(r.hits_total,10); eq(r.damage_total,50)
eq(r.turrets['rocket-turret'].count,2); eq(r.turrets['rocket-turret'].empty,1)
eq(r.turrets['rocket-turret'].targeting,1); eq(r.turrets['laser-turret'].empty,nil)
eq(r.ammo[1].hub,120); eq(r.ammo[1].turrets,3); eq(r.ammo[1].made,210); eq(r.ammo[1].used,90)
eq(r.repair_packs,5); eq(r.fuel['thruster-fuel'],1500); eq(r.asteroids.huge,0)
eq(r.tallies.kills,33); eq(r.tallies.damage,330); eq(r.tallies.units[1],10)
seg.partial=true; eq(m.read(a).losses_leg,nil); seg.partial=nil
stored.lost_log={next=1,rows={{t=600}}}; eq(m.read(a).losses_leg,nil); stored={}
seg.to='other'; eq(m.read(a).leg.start_tick,nil); seg.to='shattered'
leg=nil; pl.space_connection=nil; pl.space_location={name='edge'}
r=m.read{platform='Resolute'}; eq(r.leg,nil); eq(r.losses_leg,nil); eq(r.at,'edge'); eq(r.asteroids,nil)
hits=nil; r=m.read{platform='Resolute'}; eq(r.hits_total,0); eq(r.damage_total,0)
local previous=guns; guns={}; for i=1,257 do guns[i]=previous[1] end
r=m.read(a); eq(r.turrets,nil); eq(r.tallies,nil); eq(r.ammo[1].turrets,nil); eq(r.ammo[1].hub,120)
guns=previous; local get=guns[1].get_inventory; guns[1].get_inventory=function() error('missing inventory') end
r=m.read(a); eq(r.turrets['rocket-turret'].empty,nil); eq(r.ammo[1].turrets,nil); guns[1].get_inventory=get
local ok=pcall(m.read,{platform='Resolute',area={{0,0},{1000,1000}}}); eq(ok,false)
print('platform metrics: '..checks..' assertions passed')
