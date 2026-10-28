-- d27 batch294 TQ (Sol #2645): a thruster's burn and thrust at its own quality in platforms' after_pumps and
-- thruster_burn, the platforms row, platform_endurance's full_thrust and its ship check. Measured on the iMac copy
-- (2.0.77, a copy of Resolute flying): 4 legendary thrusters burned 5 fuel and 5 oxidizer a tick each at 80% or more
-- (the game's fluid statistics), 0.25 at the floor (under 10% of the emptier tank); normal, normal, legendary, rare
-- burned 12.2 a tick of each (2+2+5+3.2); at speed 1.5 the speed gained a tick less the drag was 1.3, 1.6, 1.9 and 2.5
-- times normal's for uncommon to legendary: the quality's default_multiplier scales the burn and the thrust alike.
-- Run from the harness root: lua tests/d27_batch294.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function G(x) return string.format('%g',x) end
local function has(text,part) assert(type(text)=='string' and text:find(part,1,true),tostring(text)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={entity_status={working=1}}
local Q={normal={name='normal',level=0,default_multiplier=1},rare={name='rare',level=2,default_multiplier=1.6},
  legendary={name='legendary',level=5,default_multiplier=2.5}}
local n=0
local function ent(name,type_,x,y) n=n+1; return {valid=true,name=name,type=type_,position={x=x,y=y},unit_number=n,status=1} end
-- the pipes between the pumps and the thrusters: one box per fluid, shared by every thruster (Resolute: 8500 fuel, 8200 oxidizer)
local pipe_f,pipe_o=ent('pipe','pipe',0,300),ent('pipe','pipe',1,300)
local pump=ent('pump','pump',-14.5,160)
local function pipebox(e,name,amount)
  local b={owner=e,[1]={name=name,amount=amount}}
  setmetatable(b,{__len=function() return 1 end})
  b.get_pipe_connections=function() return {{flow_direction='input-output',target={owner=pump},target_fluidbox_index=1}} end
  return b
end
pipe_f.fluidbox,pipe_o.fluidbox=pipebox(pipe_f,'thruster-fuel',8500),pipebox(pipe_o,'thruster-oxidizer',8200)
local function thruster(x,quality)
  local t=ent('thruster','thruster',x,370.5)
  t.quality=Q[quality]
  t.prototype={fluidbox_prototypes={{volume=1000},{volume=1000}}}
  local b={owner=t,[1]={name='thruster-fuel',amount=1000},[2]={name='thruster-oxidizer',amount=1000}}
  setmetatable(b,{__len=function() return 2 end})
  b.get_capacity=function() return 1000 end
  b.get_pipe_connections=function(i) return {{flow_direction='input-output',target=i==1 and pipe_f.fluidbox or pipe_o.fluidbox,target_fluidbox_index=1}} end
  t.fluidbox=b
  return t
end
local list={thruster(-14,'legendary'),thruster(-5,'legendary'),thruster(5,'legendary'),thruster(14,'legendary')}
local surface={index=1,find_entities_filtered=function(f) if f.type=='thruster' then return list end return {} end}
local pl={valid=true,name='Resolute',force={name='player'},surface=surface}
game={tick=1}
local T=dofile('mod/agent-harness_0.1.0/thrust.lua'){}

-- the burn from full tanks with no supply, at a quality's multiplier: the normal times over 2.5 (the rule's figures)
do
  local b=T.burn(1000,nil,2.5)
  eq(b.full_s,0.7); eq(b.to_10_s,8); eq(b.equiv_s,4.1); eq(b.empty_s,14.7)
  local b1=T.burn(1000)
  eq(b1.full_s,1.7); eq(b1.to_10_s,20.1); eq(b1.equiv_s,10.3)
  has(T.RULE,'From full tanks with no supply a normal thruster gives 1.7 s at full thrust, 20.1 s until 10%, about 10.3 s of full thrust in all (a legendary one 0.7 s, 8 s, 4.1 s)')
  has(T.RULE,'quality multiplies the burn and the thrust alike (uncommon 1.3, rare 1.6, epic 1.9, legendary 2.5')
  print('TQ the burn at a quality: ok')
end

-- Resolute's 4 legendary thrusters and the 8500 between them and the pumps: 3125 a thruster at 5 a tick
do
  local q=T.qualities(pl)
  eq(q.count,4); eq(q.per_tick,20); eq(q.per_s,1200); eq(q.per_min,72000); eq(q.mult_sum,10)
  eq(q.line,'4 thrusters, legendary x2.5: at full thrust (the emptier tank 80% full or more) they burn 20 fuel and 20 oxidizer a tick in all '
    ..'(1200 a second, 72000 a minute of each; 5 a tick a thruster), thrust 10 times one normal thruster\'s (the engine\'s figures for their quality, not measured use)')
  local ap=T.after_pumps(pl)
  local r=T.burn(3125,nil,2.5)
  eq(ap.lines[1],'thruster-fuel: if its pumps stop, 4 thrusters (legendary x2.5) hold 4000 and the pipes and tanks between them and the pumps 8500 (3125 a thruster): '
    ..'at full thrust 20 a tick in all (5 a thruster): about '..G(r.equiv_s)..' s of full thrust, '..G(r.to_10_s)..' s until 10%, then 1 a tick in all until empty at '..G(r.empty_s)..' s; pump (-14.5,160): '
    ..ap.lines[1]:match('pump %(%-14%.5,160%): (.*)$'))
  -- the normal rule gave about 28 s here (Sol's preflight); at their quality it is under half of that
  local normal=T.burn(3125)
  assert(r.equiv_s<normal.equiv_s/2,r.equiv_s..' vs '..normal.equiv_s)
  -- the oxidizer is the emptier: it sets the thrust for both
  eq(ap.lines[3],'both fluids burn alike at the rate the emptier tank sets: the thrust lasts as thruster-oxidizer does (about '
    ..G(T.burn(3050,nil,2.5).equiv_s)..' s of full thrust, '..G(T.burn(3050,nil,2.5).to_10_s)..' s until 10%)')
  has(ap.rule,'4 thrusters, legendary x2.5: at full thrust'); has(ap.rule,'; a thruster burns fuel and oxidizer alike')
  eq(ap.thrusters.per_tick,20)
  print('TQ Resolute: 4 legendary thrusters at 5 a tick each: ok')
end

-- mixed qualities, as measured: normal, normal, legendary, rare burn 12.2 a tick of each in all
do
  list={thruster(-14,'normal'),thruster(-5,'normal'),thruster(5,'legendary'),thruster(14,'rare')}
  game.tick=2
  local q=T.qualities(pl)
  eq(q.per_tick,12.2); eq(q.per_s,732); eq(q.per_min,43920)
  has(q.line,'4 thrusters, 2 normal, 1 rare x1.6, 1 legendary x2.5: at full thrust (the emptier tank 80% full or more) they burn 12.2 fuel and 12.2 oxidizer a tick in all '
    ..'(732 a second, 43920 a minute of each; 2 normal, 3.2 rare, 5 legendary a tick a thruster), thrust 6.1 times one normal thruster\'s')
  local ap=T.after_pumps(pl)
  has(ap.lines[1],'4 thrusters (2 normal, 1 rare x1.6, 1 legendary x2.5) hold 4000')
  has(ap.lines[1],'at full thrust 12.2 a tick in all (2 normal, 3.2 rare, 5 legendary a thruster)')
  has(ap.lines[1],'then 0.61 a tick in all until empty')
  has(ap.lines[1],'(mixed qualities: one pool kept level by the pipes, at their mean x1.53)')
  local r=T.burn(3125,nil,12.2/8)
  has(ap.lines[1],'about '..G(r.equiv_s)..' s of full thrust, '..G(r.to_10_s)..' s until 10%')
  -- the groups the platforms row says
  local gr,sum,text=T.groups(list)
  eq(#gr,3); eq(sum,6.1); eq(text,'2 normal, 1 rare x1.6, 1 legendary x2.5')
  eq(select(3,T.groups({list[1]})),'normal')
  print('TQ mixed qualities: 12.2 a tick, as measured: ok')
end

-- freight's geometry: the thrust in normal thrusters'; endurance's ship check names a change of quality
do
  local s={find_entities_filtered=function(f) eq(f.type,'thruster'); return {{quality=Q.normal},{quality=Q.normal},{quality=Q.legendary}} end,
    count_tiles_filtered=function() return 0 end}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local g=F.geometry({surface=s,force={name='player'}})
  eq(g.thrusters,3); eq(g.thrust,4.5)
  print('TQ geometry: thrust in normal thrusters\': ok')
end

do
  defines={entity_status={working=1},flow_precision_index={ten_minutes=2,five_seconds=0,one_minute=1},inventory={hub_main=1,turret_ammo=1,assembling_machine_input=2}}
  prototypes={item={},fluid={},space_location={nauvis={solar_power_in_space=100},vulcanus={solar_power_in_space=400}},
    space_connection={a={from={name='nauvis'},to={name='vulcanus'},length=15000}}}
  local hub=setmetatable({get_contents=function() return {} end,count_empty_stacks=function() return 5 end},{__len=function() return 10 end})
  local surf={find_entities_filtered=function() return {} end}
  local force={get_item_production_statistics=function() return {get_flow_count=function() return 0 end} end,get_fluid_production_statistics=function() return {get_flow_count=function() return 0 end} end}
  local p2={name='Resolute',surface=surf,force=force,hub={get_inventory=function() return hub end},space_location={name='nauvis'},speed=0,
    schedule={current=1,records={{station='nauvis'},{station='vulcanus'}}}}
  local segs={{kind='leg',from='vulcanus',to='nauvis',start=94240,['end']=100000,km0=0,km1=15000,thrusters=4,thrust=4,width=40}}
  local geo={thrusters=4,thrust=10,width=40}
  game={tick=100001}
  local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){platform=function() return p2 end,leg=function() return nil end,segments=function() return segs end,
    geometry=function() return geo end,thrusters=function() return {line='4 thrusters, legendary x2.5: at full thrust ...',per_min=72000} end}
  local r=E.read({},{platform='Resolute',route={'nauvis','vulcanus'}})
  has(r.speed_from,'(measured on another ship: thrusters worth 4 normal ones then, 10 now (their quality); times from it are from the old geometry)')
  eq(r.full_thrust,'4 thrusters, legendary x2.5: at full thrust ...')
  local fo=E.fuel_outlook(p2)
  eq(fo.full_thrust_per_min,72000)
  has(fo.line,'thruster-fuel 0 held, made 0/min, used 0/min')
  geo.thrust=4
  assert(not E.read({},{platform='Resolute',route={'nauvis','vulcanus'}}).speed_from:find('another ship',1,true))
  print('TQ endurance: full_thrust apart from measured use; a quality change named: ok')
end
game=nil; defines=nil; prototypes=nil
print('d27_batch294 TQ: ok')
