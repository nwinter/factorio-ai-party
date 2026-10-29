-- Run from repository root: lua tests/d29_batch344.lua
-- d29 batch344 GS (Sol, board #2750: "Trial31 guard477 fired 81734480 railgun (19.5,-75.5) at 4 ammo; by next readonly
-- inspect gun recovered 10, so cannot distinguish sparse belt, pickup batch latency, control or power"). When an
-- ammo_below guard on a platform is met, the lowest turret and the inserters feeding it are read on that tick
-- (turretsnap.lua) and named in its evidence; queue_status {snapshots} pages them, {snapshot: id} reads one in full.
-- 1. a railgun at 4 with two feeders: one waiting on a belt whose lanes hold 0 and 3 rails, one disabled by its circuit:
--    the snapshot has the turret's ammo and rounds, each feeder's status, hand, settings, pickup lanes, power and
--    circuit, and the leg and speed; the condition's evidence and saw name it.
-- 2. pages of 8, newest first, a full read by id, another force's not shown; the newest KEEP kept.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
defines={inventory={turret_ammo=1},entity_status={working=1,waiting_for_source_items=7,disabled_by_control_behavior=55}}
prototypes={item={['railgun-ammo']={type='ammo',magazine_size=1},['firearm-magazine']={type='ammo',magazine_size=10}}}
game={tick=81734480}
local force={name='player'}
local store={}
local function stack(name,count,ammo) return {valid_for_read=count>0,name=name,count=count,ammo=ammo,quality={name='normal'}} end
local function lineobj(n,all) return setmetatable({get_item_count=function(item) return item=='railgun-ammo' and n or 0 end},{__len=function() return all end}) end
local belt={valid=true,type='transport-belt',name='fast-transport-belt',position={x=19.5,y=-72.5},unit_number=900,
  get_max_transport_line_index=function() return 2 end,get_transport_line=function(i) return i==1 and lineobj(0,0) or lineobj(3,5) end}
local turret={valid=true,type='ammo-turret',name='railgun-turret',position={x=19.5,y=-75.5},unit_number=477,force=force,
  prototype={collision_box={left_top={x=-1.5,y=-1.5},right_bottom={x=1.5,y=1.5}}}}
local ammo={stack('railgun-ammo',4,1)}
setmetatable(ammo,{__len=function() return 1 end})
turret.get_inventory=function() return ammo end
local function ins(x,y,status,held,pick,cb,filters)
  local i={valid=true,type='inserter',name='bulk-inserter',position={x=x,y=y},unit_number=1000+x,status=status,
    held_stack=held and stack('railgun-ammo',held) or {valid_for_read=false},inserter_stack_size_override=0,inserter_filter_mode='whitelist',
    filter_slot_count=filters and 1 or 0,pickup_target=pick,drop_target=turret,energy=12000,is_connected_to_electric_network=function() return true end}
  i.get_filter=function() return filters end
  i.get_control_behavior=function() return cb end
  return i
end
local f1=ins(19.5,-73.5,defines.entity_status.waiting_for_source_items,nil,belt,nil,'railgun-ammo')
local f2=ins(17.5,-75.5,defines.entity_status.disabled_by_control_behavior,2,nil,{disabled=true,circuit_enable_disable=true,
  circuit_condition={first_signal={name='railgun-ammo'},comparator='<',constant=10}})
local other={valid=true,type='inserter',name='inserter',position={x=22.5,y=-75.5},drop_target={}}
local surface={find_entities_filtered=function(f) eq(f.type,'inserter'); return {f1,other,f2} end}
turret.surface=surface
local pl={name='Resolute',speed=1.4,space_location=nil}
local T=dofile('mod/agent-harness_0.1.0/turretsnap.lua'){state=function() return store end,
  leg=function() return {from='aquilo',to='solar-system-edge',length=100000,left_km=71000} end}
do
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){turret_snapshot=function(p,t,why) return T.take(p,t,why) end}
  C.platform_named=function() return {name='Resolute',surface=surface,speed=1.4} end
  -- the ammo_below check's own turret list: platform_turrets is internal; read the snapshot directly as the check does
  local ev=T.take(pl,turret,'1 turrets below 10')
  local s=store.guard_snapshots.list[1]
  eq(ev.snapshot,1); eq(s.tick,81734480); eq(s.turret.unit_number,477); eq(s.turret.items,4); eq(s.turret.rounds,4)
  eq(s.turret.ammo[1].name,'railgun-ammo'); eq(#s.feeders,2,'the inserter dropping elsewhere left out')
  local a,b=s.feeders[1],s.feeders[2]
  eq(a.status,'waiting_for_source_items'); eq(a.held,nil); eq(a.pickup.name,'fast-transport-belt'); eq(a.filters[1],'railgun-ammo')
  eq(a.pickup_lanes[1].item,0); eq(a.pickup_lanes[2].item,3); eq(a.pickup_lanes[2].all,5); eq(a.powered,true); eq(a.energy,12000)
  eq(b.status,'disabled_by_control_behavior'); eq(b.held.count,2); eq(b.circuit.disabled,true); eq(b.circuit.condition.constant,10)
  eq(s.leg.from,'aquilo'); eq(s.leg.flown_km,29000); eq(s.speed_km_s,84)
  has(ev.line,'snapshot #1 at tick 81734480: railgun-turret (19.5,-75.5) on Resolute holds 4 ammo items (4 rounds) of railgun-ammo; 2 feeding inserters')
  has(ev.line,'waiting_for_source_items, holds nothing from fast-transport-belt [line 1: 0, line 2: 3]')
  has(ev.line,'disabled_by_control_behavior, holds 2 railgun-ammo from nothing, disabled by its circuit')
  has(ev.line,'flying aquilo->solar-system-edge, 29000 km flown, 71000 left, 84 km/s')
  -- a magazine's rounds: the first stack's ammo left plus a full magazine for each other item
  ammo[1]=stack('firearm-magazine',3,4)
  eq(store.guard_snapshots.list[#store.guard_snapshots.list].id,1)
  T.take(pl,turret,'x'); eq(store.guard_snapshots.list[2].turret.rounds,4+2*10)
  print('d29_batch344 1. a snapshot on the tick: the turret\'s ammo and rounds, each feeder (status, hand, settings, pickup lanes, power, circuit), leg and speed: ok')
end
do
  -- 2. pages, a full read, the cap
  for k=1,40 do game.tick=game.tick+60; T.take(pl,turret,'x') end
  local p={force=force}
  local page=T.read(p,{snapshots=true})
  eq(#page.snapshots,8); eq(page.total,T.KEEP); eq(page.next_from,9); eq(page.snapshots[1].id,42,'newest first')
  local last=T.read(p,{snapshots=true,from=25}); eq(#last.snapshots,8); eq(last.next_from,nil)
  eq(T.read(p,{snapshot=42}).id,42)
  local ok,err=pcall(T.read,p,{snapshot=1}); assert(not ok and tostring(err):find('no snapshot #1 kept'),tostring(err))
  eq(#T.read({force={name='enemy'}},{snapshots=true}).snapshots,0)
  print('d29_batch344 2. pages of 8 newest first, a full read by id, the newest 32 kept, another force\'s not shown: ok')
end
