-- Run from repository root: lua tests/d28_batch327.lua
-- d28 batch327 AG (Sol #2719: "Resolute bow railgun emptied for271ticks despite global rail>1600. Independent ~0.64s
-- inspect polls show feeder WAITING_SOURCE with empty hand and no rail on pickup, but miss short arrivals; native
-- flight_watch only samples turrets1s"). signal_watch {triples, seconds}: an ammo gap watch reads, every tick, each
-- turret's ammo, its inserter's hand and status and the pickup's count of the ammo.
-- The stand-in: from k=600 to 899 the pickup is empty but for one rail arriving at k=700 (one tick, taken at once);
-- the inserter holds it k=701..720; the turret is empty k=650..920 (271 ticks).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={wire_connector_id={circuit_red=1,circuit_green=2},inventory={turret_ammo=1,chest=2,hub_main=3},
  entity_status={working=1,waiting_for_source_items=7,disabled_by_control_behavior=55}}
prototypes={item={['railgun-ammo']={type='ammo',stack_size=10,ammo_category='railgun'},['firearm-magazine']={type='ammo',stack_size=100,ammo_category='bullet'},
  ['piercing-rounds-magazine']={type='ammo',stack_size=100,ammo_category='bullet'},['iron-plate']={type='item',stack_size=100}},fluid={},recipe={},entity={}}
local T0=100000
game={tick=T0,surfaces={}}
local surface={valid=true,index=22,name='platform-22',platform={name='Resolute'}}
game.surfaces[22]=surface
local reads={}
local function k() return game.tick-T0 end
local function ammo(t) return (t>=650 and t<921) and 0 or 5 end
local function held(t) return (t>=701 and t<=720) and 1 or 0 end
local function at_pickup(t) if t==700 then return 1 end return (t>=600 and t<900) and 0 or 10 end
local function count(what) reads[what]=(reads[what] or 0)+1 end
local inv={get_item_count=function() count('ammo'); return ammo(k()) end,
  get_contents=function() return ammo(k())>0 and {{name='railgun-ammo',count=ammo(k()),quality='normal'}} or {} end}
inv.__len=nil
setmetatable(inv,{__len=function() return 1 end})
local turret={valid=true,name='railgun-turret',type='ammo-turret',position={x=0,y=-40},surface=surface,unit_number=1,
  prototype={attack_parameters={ammo_categories={'railgun'}},automated_ammo_count=10},get_inventory=function(id) eq(id,1); return inv end}
local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},surface=surface,unit_number=3,
  get_item_count=function(item) count('pickup'); eq(item,'railgun-ammo'); return at_pickup(k()) end,
  get_inventory=function(id) if id==3 then return setmetatable({},{__len=function() return 65 end}) end end}
local inserter={valid=true,name='bulk-inserter',type='inserter',position={x=0,y=-38},surface=surface,unit_number=2,pickup_target=hub,inserter_stack_size_override=0}
setmetatable(inserter,{__index=function(_,key)
  if key=='held_stack' then count('hand'); local h=held(k()); return {valid_for_read=h>0,count=h} end
  if key=='status' then count('status'); return (k()>=600 and k()<900 and held(k())==0) and defines.entity_status.waiting_for_source_items or defines.entity_status.working end end})
local gun2={valid=true,name='gun-turret',type='ammo-turret',position={x=9,y=9},surface=surface,unit_number=4,
  prototype={attack_parameters={ammo_categories={'bullet'}}},get_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end}
local S={}
local W=dofile('mod/agent-harness_0.1.0/signalwatch.lua'){state=function() return S end,reason=function(v) return v end,
  on_platform=function(p,name) eq(name,'Resolute'); return p end,on_surface=function(p) return p end,
  remote_entity=function(q,a) local x,y=a.position.x,a.position.y
    if x==0 and y==-40 then return turret elseif x==0 and y==-38 then return inserter elseif x==0 and y==0 then return hub elseif x==9 then return gun2 end
    error('no entity of ours there') end}
local p={index=4}
local function run(to) while game.tick<to do game.tick=game.tick+1; W.tick(game.tick) end end

-- bounds
local tri={turret={x=0,y=-40},inserter={x=0,y=-38}}
fails(function() W.handler(p,{triples={tri},platform='Resolute',seconds=121}) end,'seconds: 10..120 with triples')
fails(function() W.handler(p,{triples={tri},platform='Resolute',seconds=9}) end,'seconds: 10..120 with triples')
fails(function() W.handler(p,{triples={tri,tri,tri,tri,tri},platform='Resolute',seconds=30}) end,'triples: 1..4')
fails(function() W.handler(p,{triples={{turret={x=0,y=-40},inserter={x=0,y=0}}},platform='Resolute',seconds=30}) end,'is not an inserter')
fails(function() W.handler(p,{triples={{turret={x=9,y=9},inserter={x=0,y=-38}}},platform='Resolute',seconds=30}) end,
  'ammo: gun-turret is empty and takes firearm-magazine, piercing-rounds-magazine: name the ammo')
fails(function() W.handler(p,{triples={tri},entities={{x=1,y=1}},platform='Resolute',seconds=30}) end,'triples starts an ammo gap watch')

-- 30 s: the pickup is the inserter's pickup_target (the hub), the ammo what the turret holds
local r=W.handler(p,{triples={tri},platform='Resolute',seconds=30})
eq(r.ammo_gaps,true); eq(r.every_ticks,1); eq(r.end_tick,T0+1799)
has(r.now,'railgun-turret: ammo 5, hand 0, pickup 10')
reads={}
run(T0+1799)
r=W.handler(p,{})
eq(r.done,true); eq(r.samples,1800)
for _,what in ipairs({'ammo','hand','status','pickup'}) do eq(reads[what],1799,what..' read once a tick') end
local t=r.triples[1]
eq(t.ammo,'railgun-ammo'); eq(t.pickup.name,'space-platform-hub')
-- the 271-tick empty run, with its start
eq(t.turret_empty.ticks,271); eq(t.turret_empty.longest.ticks,271); eq(t.turret_empty.longest.from_tick,T0+650); eq(t.turret_empty.longest.to_tick,T0+920)
eq(t.turret_empty.transitions,2); eq(t.turret_empty.first_transitions[1].tick,T0+650); eq(t.turret_empty.first_transitions[2].tick,T0+921)
-- no source: waiting with an empty hand, cut by the one rail held k=701..720
eq(t.no_source.ticks,101+179); eq(t.no_source.longest.ticks,179); eq(t.no_source.longest.from_tick,T0+721)
eq(#t.no_source.runs,2); eq(t.no_source.runs[1].ticks,101); eq(t.no_source.runs[2].ticks,179)
-- the pickup: none k=600..899 but for the one-tick arrival at k=700 (an inspect every 0.64 s misses it)
eq(t.pickup_none.ticks,299); eq(t.pickup_none.longest.ticks,199); eq(t.pickup_none.longest.from_tick,T0+701)
eq(t.pickup_none.runs[1].ticks,100); eq(t.pickup_none.runs[2].ticks,199)
eq(t.at_pickup.min.count,0); eq(t.at_pickup.min.tick,T0+600); eq(t.at_pickup.max.count,10)
eq(t.hand.max.count,1); eq(t.hand.max.tick,T0+701); eq(t.turret_ammo.min.count,0); eq(t.turret_ammo.min.tick,T0+650)
eq(t.inserter_status.waiting_for_source_items,280); eq(t.inserter_status.working,1800-280)
eq(t.context.turret_ammo_slots,1); eq(t.context.ammo_stack_size,10); eq(t.context.automated_ammo_count,10)
eq(t.context.pickup_kind,'space-platform-hub'); eq(t.context.pickup_slots,65); eq(t.context.inserter_stack_size_override,nil)
has(t.line,'railgun-turret (0,-40) <- bulk-inserter (0,-38) <- space-platform-hub (0,0): 1800 ticks')
has(t.line,'turret empty 271 ticks; longest 271 from tick '..(T0+650))
has(t.line,'inserter no source 280 ticks; longest 179 from tick '..(T0+721)..'; runs (ticks x times) 101 x1, 179 x1')
has(t.line,'pickup none at the pickup 299 ticks; longest 199 from tick '..(T0+701))
has(r.line,'every tick from tick '..T0..' to tick '..(T0+1799))
-- freed at its end: no entity kept
eq(S.signal_watch[4].triples[1].turret,nil); eq(S.signal_watch[4].triples[1].inv,nil)
print('d28_batch327 1. every tick: a 271-tick empty turret, the no-source runs and a one-tick arrival at the pickup, with their start ticks: ok')

-- a run open at either end: began_before / still; a gone entity ends the watch
game.tick=T0+800
r=W.handler(p,{triples={{turret={x=0,y=-40},inserter={x=0,y=-38},pickup={x=0,y=0},ammo='railgun-ammo'}},platform='Resolute',seconds=10})
has(r.replaced,'was replaced')
run(T0+850)
r=W.handler(p,{})
eq(r.watching,true); t=r.triples[1]
eq(t.turret_empty.longest.began_before,true); eq(t.turret_empty.longest.still,true); eq(t.turret_empty.longest.ticks,51)
turret.valid=false
run(T0+852)
r=W.handler(p,{})
eq(r.done,true); has(r.ended.why,'every triple is gone'); eq(r.triples[1].gone_tick,T0+851)
turret.valid=true
print('d28_batch327 2. runs cut by the watch\'s start or end (began_before, still); a gone turret ends it: ok')
