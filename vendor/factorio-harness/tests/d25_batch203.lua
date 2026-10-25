-- Run from repository root: lua tests/d25_batch203.lua
-- d25 batch203 QP1 (Sol #2331: Weaver's native rockets could not be told apart by silo): a rocket's pod journey keeps
-- the silo the game names (the launch event's rocket_silo, else the pod's cargo_pod_origin), shown in the ledger's pod
-- rows and filtered by silo; rockets sent before the ledger kept silos say unknown; no silo is taken from nearby
-- entities. Each silo keeps its latest launch with its pod and counts its launches.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,e=pcall(f); assert(not ok,'should fail: '..x); has(e,x) end
defines={inventory={cargo_unit=2},events={on_cargo_pod_started_ascending=901,on_cargo_pod_finished_ascending=902,on_cargo_pod_finished_descending=903,
  on_cargo_pod_delivered_cargo=904},rocket_silo_status={building_rocket=0,rocket_ready=7,launch_started=9}}
storage={}
game={tick=1000,surfaces={nauvis={}},get_player=function() return nil end}
prototypes={item={['advanced-circuit']={},['uranium-rounds-magazine']={}}}
local function inv(list) local x={list=list}; x.get_contents=function() return x.list end; x.get_item_count=function() return 0 end; return x end
local nauvis={name='nauvis'}
local weaver={name='Weaver',valid=true,space_location={name='nauvis'}}
local hub={valid=true,type='space-platform-hub',surface={name='platform-19',platform=weaver},position={x=0,y=0}}
local function silo(unit,x,y)
  -- a silo is never searched for: any find on its surface fails the test
  return {valid=true,type='rocket-silo',name='rocket-silo',unit_number=unit,surface=nauvis,position={x=x,y=y},rocket_silo_status=0,rocket_parts=3,
    prototype={rocket_parts_required=50}}
end
nauvis.find_entities_filtered=function() error('no silo is taken from nearby entities') end
local main,cell=silo(4955995,55.5,94.5),silo(40352083,-186.5,148.5)
local units=40000000
local function pod(origin,items)
  units=units+1
  local cargo=inv(items)
  local p={valid=true,unit_number=units,cargo_pod_origin=origin,cargo_pod_destination={station=hub,type=1},surface=nauvis,position={x=0,y=0}}
  p.get_inventory=function() return cargo end
  return p
end
local AM={{name='advanced-circuit',quality='normal',count=100}}
local P=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return storage end}

-- a rocket recorded before this runtime kept silos (an older journey, no silo field)
storage.podlog={seq=1,open={},open_n=0,by={nauvis={{id=1,unit=39999000,up=true,platform='Weaver',stop='nauvis',sent=900,items={['advanced-circuit']=100},kind='rocket'}}}}
-- 1. a native launch (no player): on_rocket_launch_ordered names the silo
game.tick=1000
local p1=pod(main,AM)
P.on_launch{rocket={attached_cargo_pod=p1},rocket_silo=main,tick=1000}
-- 2. a launch seen first at the pod's ascent (on_cargo_pod_finished_ascending): the pod's origin is the silo
game.tick=1200
local p2=pod(cell,AM)
P.on_event{name=902,tick=1200,cargo_pod=p2}
local rows,total=P.read{surfaces={nauvis=true},up=true,limit=32}
eq(total,3)
eq(rows[1].silo,'unknown'); has(rows[1].line,'rocket silo unknown (sent before the ledger kept silos)')
eq(rows[2].silo.unit_number,4955995); eq(rows[2].silo.surface,'nauvis'); eq(rows[2].silo.position.x,55.5); eq(rows[2].silo.position.y,94.5)
has(rows[2].line,'nauvis to Weaver, advanced-circuit*100, rocket from silo 4955995 (55.5,94.5); ')
eq(rows[3].silo.unit_number,40352083); has(rows[3].line,'rocket from silo 40352083 (-186.5,148.5)')
eq(storage.podlog.silo_since,1000)
-- the later pod event adds nothing over the launch's silo
P.on_event{name=902,tick=2650,cargo_pod=p1}
eq(P.read{silo=4955995,limit=32}[1].silo.unit_number,4955995)
-- filtered by silo: that silo's rockets only
local f,ft=P.read{silo=40352083,limit=32}
eq(ft,1); eq(f[1].pod,p2.unit_number)
eq(select(2,P.read{silo=1,limit=32}),0)

-- shipment {ledger, silo}: the filter reaches the pod ledger; down with silo is refused
local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){integer=function(v,d,lo,hi,n) assert(type(v)=='number' and v>=lo and v<=hi and v==math.floor(v),n..' out of range'); return v end,
  podlog=function(f) return P.read(f) end}
local me={surface={name='nauvis'}}
local out=S.read(me,{ledger=true,silo=40352083})
eq(out.pods_total,1); has(out.pods_line,'launched by silo 40352083'); has(out.note,'never taken from nearby entities')
fails(function() S.read(me,{ledger=true,silo=40352083,direction='down'}) end,'silo goes with rockets (direction up)')
fails(function() S.read(me,{ledger=true,silo='cell'}) end,'silo (a silo\'s unit number)')

-- the silo's own record: its latest launch with the pod, and every launch counted (native ones too)
local Z=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return storage end}
local function launch(s,p,t) game.tick=t; Z.on_launch_ordered{rocket_silo=s,rocket={attached_cargo_pod=p},tick=t} end
launch(main,p1,3000)
launch(main,pod(main,AM),4000)
launch(cell,p2,4100)
local rk=Z.rocket(main)
eq(rk.launch_count,2); eq(rk.launch_count_since,3000); eq(rk.last_launch.tick,4000); eq(rk.last_launch.pod,units)
has(rk.last,'; 2 launches recorded since tick 3000')
eq(Z.rocket(cell).launch_count,1); has(Z.rocket(cell).last,'pod '..p2.unit_number)
-- a launch call and the game's event of the same launch count once
game.tick=5000
Z.record(cell,{called=true,by='sol'})
game.tick=5003
Z.on_launch_ordered{rocket_silo=cell,rocket={attached_cargo_pod=pod(cell,AM)},tick=5003}
eq(Z.rocket(cell).launch_count,2)
-- a silo with no launch since the harness was deployed
eq(Z.rocket(silo(77,1,1)).launch_count,nil); has(Z.rocket(silo(77,1,1)).last,'no launch seen')
defines,storage,game,prototypes=nil,nil,nil,nil
print('d25_batch203 QP1 silo in the rocket ledger: ok')
