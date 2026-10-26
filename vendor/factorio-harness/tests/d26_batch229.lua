-- Run from the harness root: lua tests/d26_batch229.lua. d26 batch229 SP (Sol, operator request 973): Sol made Loom
-- at Vulcanus and loaded a starter pack for it; the rocket launched it on its own to Aethera, made there at 89h and
-- waiting for a pack since. The pod ledger kept the pod as "vulcanus to nil, in flight" after it was gone (its pod
-- raised on_cargo_pod_delivered_cargo and no on_cargo_pod_finished_descending). A starter pack's pod now names the
-- platform it starts and closes on delivery or when the pod is gone; platform_create, a pack into a rocket, the silo,
-- launch and the platforms read name the platforms waiting at that planet in the game's order (the first made first),
-- with how long each has waited; a pack while a platform waits is not refused as trash for automatic requests.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(type(s)=='string' and s:find(x,1,true),tostring(s)..'\n  lacks: '..x) end
defines={inventory={cargo_unit=2,rocket_silo_rocket=5,rocket_silo_trash=6},
  events={on_cargo_pod_started_ascending=901,on_cargo_pod_finished_ascending=902,on_cargo_pod_finished_descending=903,on_cargo_pod_delivered_cargo=904},
  cargo_destination={invalid=0,station=1,space_platform=2,surface=3,orbit=5},
  space_platform_state={waiting_for_starter_pack=0,starter_pack_requested=1,starter_pack_on_the_way=2,on_the_path=3,paused=5,waiting_at_station=6}}
prototypes={item={['space-platform-starter-pack']={type='space-platform-starter-pack'},['repair-pack']={type='repair-tool'}}}
local W=defines.space_platform_state
local storage={}
-- 2.0.77: get_entity_by_unit_number finds no cargo pod
game={tick=66355476,forces={},get_player=function() return nil end,get_entity_by_unit_number=function(u) error('no lookup by unit number') end}
local force={name='player'}
game.forces.player=force
local vulcanus={name='vulcanus',planet={name='vulcanus'}}
local function platform(index,name,planet,state) return {valid=true,index=index,name=name,force=force,state=state,space_location={name=planet}} end
local aethera=platform(20,'Aethera','vulcanus',W.waiting_for_starter_pack)
local loom=platform(31,'Loom','vulcanus',W.waiting_for_starter_pack)
local kite=platform(25,'Kite','nauvis',W.waiting_for_starter_pack)
local anvil=platform(3,'Anvil','vulcanus',W.waiting_at_station)
force.platforms={[3]=anvil,[31]=loom,[20]=aethera,[25]=kite}
-- the chronicle still holds Kite's platform_created; Aethera's dropped out of its last 300 events
storage.chronicle={events={{kind='platform_created',platform='Kite',tick=66000000}}}
local SP=dofile('mod/agent-harness_0.1.0/starterpack.lua'){state=function() return storage end}

-- 1. The game's order: the lowest index (the first made) first; Loom made now, Aethera before this runtime kept ticks.
game.tick=66287441
SP.made(loom,66287441)
eq(storage.starterpack.since,66287441); eq(storage.starterpack.made[25],66000000,'Kite from the chronicle')
local list=SP.waiting(force,'vulcanus')
eq(#list,2); eq(list[1],aethera); eq(list[2],loom)
game.tick=66352254
eq(SP.queue_line(force,'vulcanus',2),"2 platforms of ours wait for a starter pack at vulcanus: Aethera (waiting over 18m00s, made before tick 66287441), Loom (waiting 18m00s); a rocket there holding a starter pack launches on its own once ready, whatever the silo's switches, to the first made of ours waiting: Aethera")
eq(SP.queue_line(force,'nauvis',2),nil,'one waiting at nauvis: no queue line for platform_create')
eq(SP.goes_to_line(force,'vulcanus','space-platform-starter-pack*1'),"space-platform-starter-pack*1, which launches on its own once the rocket is ready, whatever the silo's switches, to Aethera (waiting over 18m00s, made before tick 66287441), the first made of ours waiting for one at vulcanus; also waiting: Loom (waiting 18m00s); a launch in the tick it goes in (load_silo launch: true) goes to the platform it names")
eq(SP.row_line(loom),"waiting for its starter pack at vulcanus, waiting 18m00s; a rocket there holding a starter pack launches on its own once ready, whatever the silo's switches, to the first made of ours waiting: Aethera (waiting over 18m00s, made before tick 66287441); Loom is 2 of 2")
eq(SP.row_line(aethera),"waiting for its starter pack at vulcanus, waiting over 18m00s, made before tick 66287441; a rocket there holding a starter pack launches on its own once ready, whatever the silo's switches, to the first made of ours waiting: this one (of 2)")
eq(SP.row_line(kite),"waiting for its starter pack at nauvis, waiting 1h37m; a rocket there holding a starter pack launches on its own once ready, whatever the silo's switches, to the first made of ours waiting: this one")
eq(SP.goes_to_line(force,'gleba'),'a starter pack; no platform of ours waits for a starter pack at gleba: it stays aboard (automatic requests on: the trash slots)')

-- 2. The silo: a pack in the rocket names where it goes (settings, the silo read, transfer).
local rocket={list={{name='space-platform-starter-pack',count=1,quality='normal'}}}
rocket.get_contents=function() return rocket.list end
local silo={valid=true,type='rocket-silo',name='rocket-silo',force=force,surface=vulcanus,position={x=14.5,y=140.5},unit_number=38930}
silo.get_inventory=function(i) if i==defines.inventory.rocket_silo_rocket then return rocket end end
local Z=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return storage end,starterpack=function() return SP end}
eq(Z.starter_line(silo),"the rocket holds space-platform-starter-pack*1, which launches on its own once the rocket is ready, whatever the silo's switches, to Aethera (waiting over 18m00s, made before tick 66287441), the first made of ours waiting for one at vulcanus; also waiting: Loom (waiting 18m00s); a launch in the tick it goes in (load_silo launch: true) goes to the platform it names")
-- Step 3 (Sol at 66352254: auto_requests refused, the pack said to go to the trash): with a platform of ours waiting
-- here the pack stays aboard and launches to it; with none, the trash slots
local risk=Z.trash_risk(silo,force)
eq(risk.lost,nil,'a pack while Aethera waits is not lost'); eq(risk.starter_pack,Z.starter_line(silo))
has(risk.line,'the rocket holds space-platform-starter-pack*1, which launches on its own once the rocket is ready')
rocket.list={{name='space-platform-starter-pack',count=1,quality='normal'},{name='repair-pack',count=100,quality='normal'}}
risk=Z.trash_risk(silo,force)
eq(risk.lost,'repair-pack*100'); has(risk.line,"repair-pack*100 that no platform stopped above asks this planet for"); has(risk.line,'; and space-platform-starter-pack*1, which launches')
aethera.state,loom.state=W.on_the_path,W.on_the_path
rocket.list={{name='space-platform-starter-pack',count=1,quality='normal'}}
risk=Z.trash_risk(silo,force)
eq(risk.lost,'space-platform-starter-pack*1','none waiting: the pack goes to the trash slots'); eq(risk.starter_pack,nil)
has(Z.starter_line(silo),'no platform of ours waits for a starter pack at vulcanus: it stays aboard')
aethera.state,loom.state=W.waiting_for_starter_pack,W.waiting_for_starter_pack
rocket.list={{name='repair-pack',count=100,quality='normal'}}
eq(Z.starter_line(silo),nil,'no pack aboard: no line')

-- 3. The pod ledger (the copy's event order, 2.0.77): a starter pack's pod raises on_rocket_launch_ordered naming the
-- platform, on_cargo_pod_finished_ascending ~1650 ticks later, and in that tick on_cargo_pod_delivered_cargo (the
-- platform starts, its hub built); no on_cargo_pod_finished_descending; the pod is gone the next tick. A pod sent to
-- orbit is gone after its ascent with no delivery.
local P=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return storage end}
local units=46268166
local function pod(dest,items)
  units=units+1
  local cargo={list=items}; cargo.get_contents=function() return cargo.list end
  local p={valid=true,unit_number=units,cargo_pod_origin=silo,cargo_pod_destination=dest,surface=vulcanus,position={x=0,y=0}}
  p.get_inventory=function() return cargo end
  return p
end
local PACK={{name='space-platform-starter-pack',quality='normal',count=1}}
game.tick=66355476
local p1=pod({type=defines.cargo_destination.space_platform,space_platform=aethera},PACK)
P.on_launch{rocket={attached_cargo_pod=p1},rocket_silo=silo,tick=game.tick}
local p2=pod({type=defines.cargo_destination.orbit},{{name='repair-pack',quality='normal',count=10}})
P.on_launch{rocket={attached_cargo_pod=p2},rocket_silo=silo,tick=game.tick}
-- a journey opened before this runtime kept pods (no pod in its open entry)
storage.podlog.by.vulcanus[#storage.podlog.by.vulcanus+1]={id=99,unit=46000000,up=true,sent=66350000,items={['repair-pack']=5}}
storage.podlog.open[46000000]={planet='vulcanus',id=99,tick=66350000}
-- Sol's row #20903 as world n keeps it: delivered, no landing (read "in flight" before)
storage.podlog.by.vulcanus[#storage.podlog.by.vulcanus+1]={id=20903,unit=46268000,up=true,sent=66355476,delivered=66357126,kind='rocket',items={['space-platform-starter-pack']=1}}
local rows=P.read{surfaces={vulcanus=true},limit=8}
local function row(u) for _,r in ipairs(rows) do if r.pod==u then return r end end end
has(row(p1.unit_number).line,'vulcanus to Aethera (its starter pack), space-platform-starter-pack*1')
has(row(p1.unit_number).line,'; in flight'); eq(row(p1.unit_number).platform,'Aethera'); eq(row(p1.unit_number).starter_pack,true)
has(row(p2.unit_number).line,'vulcanus to orbit, repair-pack*10')
has(row(46000000).line,'vulcanus to a destination not read')
has(row(46268000).line,'landed (where not read) after 27s'); eq(row(46268000).landed_tick,66357126)
-- the ascent: the pack's pod delivers (Aethera starts) and the orbit pod reaches orbit; the old journey's pod is seen
game.tick=66357126
local old=pod({type=defines.cargo_destination.orbit},{{name='repair-pack',quality='normal',count=5}}); old.unit_number=46000000
P.on_event{name=902,tick=game.tick,cargo_pod=old}
aethera.hub={valid=true}; aethera.state=W.paused
P.on_event{name=902,tick=game.tick,cargo_pod=p1}
P.on_event{name=904,tick=game.tick,cargo_pod=p1}
-- the next tick every pod is gone
game.tick=66357127
p1.valid,p2.valid,old.valid=false,false,false
P.tick(game.tick)
rows=P.read{surfaces={vulcanus=true},limit=8}
has(row(p1.unit_number).line,'landed in platform Aethera (its starter pack: the platform starts, its hub built) after 27s')
eq(row(p1.unit_number).landed_tick,66357126)
has(row(p2.unit_number).line,'; in flight','the sweep runs on the second')
game.tick=66357180; P.tick(game.tick)
rows=P.read{surfaces={vulcanus=true},limit=8}
has(row(p2.unit_number).line,'pod gone by tick 66357180, 28s after it was sent, no landing recorded (a pod sent to orbit is removed there with its cargo)')
eq(row(p2.unit_number).gone_tick,66357180)
has(row(46000000).line,'pod gone by tick 66357180, 119s after it was sent, no landing recorded')
eq(next(storage.podlog.open),nil,'every journey closed')
eq(row(p1.unit_number).landed_tick,66357126); eq(storage.podlog.by.vulcanus[#storage.podlog.by.vulcanus-3].delivered,66357127)
-- a pack's pod gone with no event while its platform has no hub: gone, with the platform's state
local p3=pod({type=defines.cargo_destination.space_platform,space_platform=loom},PACK)
P.on_launch{rocket={attached_cargo_pod=p3},rocket_silo=silo,tick=game.tick}
p3.valid=false
game.tick=66357240; P.tick(game.tick)
has(P.read{surfaces={vulcanus=true},limit=1}[1].line,'vulcanus to Loom (its starter pack), space-platform-starter-pack*1, rocket from silo 38930 (14.5,140.5); pod gone by tick 66357240, 1s after it was sent, no landing recorded; Loom reads waiting_for_starter_pack')
-- an old journey whose pod never raises another event: in flight until OPEN_TICKS, as before (no lookup)
storage.podlog.by.vulcanus[#storage.podlog.by.vulcanus+1]={id=100,unit=45000000,up=true,sent=66357200,items={['repair-pack']=5}}
storage.podlog.open[45000000]={planet='vulcanus',id=100,tick=66357200}
game.tick=66357300; P.tick(game.tick)
has(P.read{surfaces={vulcanus=true},limit=1}[1].line,'; in flight')
print('d26_batch229 SP: ok')
