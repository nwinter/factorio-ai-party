-- d24 batch183 QZ1 (Sol #2055): platform_endurance design {width, height | tiles, mass?, speed} and progress {from, to}:
-- asteroids by the spawn rule read on a copy of world n (a line 72 tiles ahead of the box across its width + 96; per km
-- flown K x (width + 96 + EXTRA) x the spawn chance), shots per leg, a 600 s window, the basis; the design form with the
-- platform's own width and speed gives the plain forecast's model.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m and m..': ' or '')..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function near(a,b,m) assert(math.abs(a-b)<1e-6,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={flow_precision_index={ten_minutes=2,one_minute=1,five_seconds=0},inventory={hub_main=1,turret_ammo=1,assembling_machine_input=2}}
-- one asteroid kind at a spawn chance of 0.01 all along nauvis->fulgora (15000 km); 100 hp; the gun does 10 a shot
local function ammo_type() return {category='bullet',action={{action_delivery={{type='instant',target_effects={{type='damage',damage={amount=10,type='physical'}}}}}}}} end
prototypes={
  item={['firearm-magazine']={type='ammo',ammo_category={name='bullet'},get_ammo_type=ammo_type},rocket={type='ammo',ammo_category={name='rocket'},get_ammo_type=ammo_type}},
  fluid={['thruster-fuel']={},['thruster-oxidizer']={}},
  quality={normal={default_multiplier=1}},
  entity={['medium-metallic-asteroid']={type='asteroid',get_max_health=function() return 100 end,resistances={},dying_trigger_effect={}},
    ['gun-turret']={attack_parameters={damage_modifier=1}}},
  space_location={nauvis={solar_power_in_space=100},fulgora={solar_power_in_space=120}},
  space_connection={a={from={name='nauvis'},to={name='fulgora'},length=15000,asteroid_spawn_definitions={
    {asteroid='medium-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.01},{distance=1,probability=0.01}}},
    {asteroid='metallic-asteroid-chunk',type='asteroid-chunk',spawn_points={{distance=0,probability=0.5},{distance=1,probability=0.5}}}}}},
  utility_constants={asteroid_spawning_offset={left_top={x=-48,y=-72},right_bottom={x=48,y=48}}}}
game={tick=10*3600}
local turret={name='gun-turret',prototype={attack_parameters={ammo_categories={'bullet'}}},ignore_unprioritised_targets=false,priority_targets={},
  get_inventory=function() return {get_contents=function() return {{name='firearm-magazine',count=200,quality='normal'}} end} end}
local function stats() return {get_flow_count=function() return 0 end} end
local hub=setmetatable({get_contents=function() return {{name='firearm-magazine',count=100}} end,count_empty_stacks=function() return 5 end},{__len=function() return 10 end})
local surface={find_entities_filtered=function(f)
  if type(f.type)=='table' then for _,t in ipairs(f.type) do if t=='ammo-turret' then return {turret} end end end
  if f.type=='ammo-turret' then return {turret} end
  return {} end,count_entities_filtered=function() return 0 end,count_tiles_filtered=function() return 0 end}
local force={get_item_production_statistics=stats,get_fluid_production_statistics=stats,get_ammo_damage_modifier=function() return 0 end,get_turret_attack_modifier=function() return 0 end}
-- at Nauvis, its schedule nauvis -> fulgora -> nauvis; the last leg flown at 1500 km a minute (25 km/s)
local pl={name='Swift',surface=surface,force=force,hub={get_inventory=function() return hub end},speed=0,
  space_location={name='nauvis'},schedule={current=1,records={{station='nauvis'},{station='fulgora'}}}}
local segs={{kind='leg',from='fulgora',to='nauvis',start=0,['end']=600,km0=0,km1=15000}}
local E=require('endurance'){platform=function() return pl end,leg=function() return nil end,segments=function() return segs end,
  ammo_counts=function() return {} end,geometry=function() return {width=104} end}
-- design: 104 wide at 50 km/s: per km 0.01 x (104 + 96 + 20) x 0.01; a leg of 15000 km meets 330, 10 shots each
local r=E.read({},{platform='Swift',design={width=104,height=40,speed=50,mass=4000000}})
eq(#r.legs,2); local L=r.legs[1]
eq(L.from,'nauvis'); eq(L.km,15000); eq(L.minutes,5); eq(L.total,330); eq(L.asteroids['medium-metallic-asteroid'],330)
eq(L.asteroids['metallic-asteroid-chunk'],nil,'chunks are not counted')
eq(L.total_per_600s,660); eq(L.shots['firearm-magazine'],3300)
has(L.line,'nauvis->fulgora 0-100%: 15000 km, 5m00s; asteroids about 330 (medium-metallic-asteroid 330; flying on a schedule 393-835 read), 660 a 600 s; shots firearm-magazine 3300')
eq(L.on_path[1],393); eq(L.on_path[2],835)
has(r.basis.spawn_line,'a line 72 tiles ahead of the platform\'s box, across its width + 96 (the game\'s asteroid_spawning_offset: x -48..48, y -72..48); the box\'s height does not count')
has(r.basis.count,'per km flown: 0.0100 x (width + 96 + 20) x the spawn chance there')
eq(r.basis.width,'104 tiles (the design\'s width)'); has(r.basis.height,'40 tiles (not used'); has(r.basis.mass,'4e+06 (not used')
eq(r.basis.speed,'50 km/s (the design\'s)'); has(r.basis.distance,'asteroids come by km flown, not by time')
assert(#r.estimated>=4); has(r.note,'read only: nothing built, placed or imported')
eq(r.resources,nil,'a light read: no rates or stock')
-- twice as fast: as many asteroids, in half the time, twice a 600 s
local r2=E.read({},{platform='Swift',design={width=104,speed=100}})
eq(r2.legs[1].total,330); eq(r2.legs[1].minutes,2.5); eq(r2.legs[1].total_per_600s,1320)
-- tiles give the same box; a wider box meets more
local rt=E.read({},{platform='Swift',design={tiles={'-52..51,0..9','0,39'},speed=50}})
eq(rt.design.width,104); eq(rt.design.height,40); eq(rt.legs[1].total,330); has(rt.basis.width,'the tiles\' box x -52..51, y 0..39')
local rw=E.read({},{platform='Swift',design={width=304,speed=50}})
eq(rw.legs[1].total,630)
-- progress: the first half of each leg
local rp=E.read({},{platform='Swift',design={width=104,speed=50},progress={from=0,to=0.5}})
eq(rp.legs[1].km,7500); eq(rp.legs[1].minutes,2.5); eq(rp.legs[1].total,165); eq(rp.legs[1].total_per_600s,660)
has(rp.basis.progress,'0-50% of each leg\'s connection')
-- the plain forecast: its basis, and its model with the platform's width and speed equals the design form's
local plain=E.read({},{platform='Swift',forecast=true})
has(plain.basis.asteroids,'a relative weight, not a count'); has(plain.basis.use,'used a minute while moving on the legs flown')
has(plain.basis.box,'forecast_model counts asteroids by the box')
local M=plain.forecast_model
eq(M.basis.width,'104 tiles (the platform\'s foundation, x extent)')
local same=E.read({},{platform='Swift',design={width=104,speed=plain.speed_km_per_min/60}})
for i,l in ipairs(M.legs) do
  local d=same.legs[i]
  eq(l.km,d.km); eq(l.minutes,d.minutes); eq(l.total,d.total); eq(l.total_per_600s,d.total_per_600s); eq(l.shots['firearm-magazine'],d.shots['firearm-magazine'])
end
-- refusals
fails(function() E.read({},{platform='Swift',design={width=104}}) end,'design.speed is km/s')
fails(function() E.read({},{platform='Swift',design={speed=50}}) end,'design.width is tiles')
fails(function() E.read({},{platform='Swift',design={width=10,tiles={'0,0'},speed=50}}) end,'give width (and height) or tiles, not both')
fails(function() E.read({},{platform='Swift',design={tiles={'a..b'},speed=50}}) end,'is not "x0..x1,y0..y1" or "x,y"')
fails(function() E.read({},{platform='Swift',design={width=10,speed=50,ammo={'iron-plate'}}}) end,'is not an ammunition')
fails(function() E.read({},{platform='Swift',progress={from=0,to=0.5}}) end,'progress goes with forecast: true or design')
fails(function() E.read({},{platform='Swift',forecast=true,progress={from=0.5,to=0.5}}) end,'0 <= from < to <= 1')
prototypes,defines,game=nil,nil,nil
print('d24_batch183: ok')
