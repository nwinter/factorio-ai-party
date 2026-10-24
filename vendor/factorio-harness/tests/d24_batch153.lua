-- d24 batch153 (the harness review's bugs 1, 2 and 6). Run from the harness root: lua tests/d24_batch153.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- Bug 1: platform_schedule on Petrel, paused at Nauvis, set stop 2's wait and answered ok:false ("it was paused before
-- this call after this call, so the call failed"); the game held the new wait. Now it answers ok, says the edit and
-- that the platform is still paused, and the change is marked. Bug 2: shipment (space.stops) read the stop it stands
-- at, paused, "flying to it".
do
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,paused=7},inventory={hub_main=1,hub_trash=2,cargo_landing_pad_main=1},
    wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={space_location={nauvis={},gleba={}},item={}}
  game={tick=1000}
  local recs={{station='nauvis',wait_conditions={{type='time',ticks=7200}}},{station='gleba',wait_conditions={{type='time',ticks=7200}}}}
  local cur=1
  local pl={valid=true,name='Petrel',index=5,state=7,paused=true,space_location={name='nauvis'},force={}}
  local sch={}
  setmetatable(sch,{__index=function(_,k) if k=='current' then return cur end end})
  sch.get_record_count=function() return #recs end
  sch.go_to_station=function(i) cur=i end
  sch.get_record=function(pos) return recs[pos.schedule_index] end
  sch.get_wait_condition_count=function(pos) return #(recs[pos.schedule_index].wait_conditions or {}) end
  sch.remove_wait_condition=function(pos,k) table.remove(recs[pos.schedule_index].wait_conditions,k) end
  sch.add_wait_condition=function(pos,k,t) local w=recs[pos.schedule_index].wait_conditions or {}; recs[pos.schedule_index].wait_conditions=w; table.insert(w,k,{type=t}) end
  sch.change_wait_condition=function(pos,k,c) recs[pos.schedule_index].wait_conditions[k]=c end
  pl.get_schedule=function() return sch end
  setmetatable(pl,{__index=function(_,k) if k=='schedule' then return {current=cur,records=recs} end end})
  local p={name='sol',force={platforms={pl}}}
  local marks={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,integer=function(v,d) return v==nil and d or v end,
    freight=F,made=function(t) marks[#marks+1]=t end}
  -- bug 2: stopped at its current stop, paused
  local stops=space.stops(pl)
  eq(stops[1],'1 nauvis (stopped here, paused: it goes nowhere until unpaused (paused: false)): time 2m00s','before: flying to it')
  eq(stops[2],'2 gleba (next): time 2m00s')
  -- bug 1: stop 2's wait set on the paused platform
  local ok,r=pcall(space.platform_schedule,p,{platform='Petrel',stop=2,wait={{type='time',ticks=3600}}})
  eq(ok,true,'before: '..tostring(r))
  eq(recs[2].wait_conditions[1].ticks,3600)
  eq(r.edited,'stop 2 (gleba): 1 wait condition set in place; the records and the current stop (1) kept; state paused (kept)')
  eq(r.still_paused,'Petrel was paused before this call and still is: the change is made, and it goes nowhere until unpaused (paused: false)')
  has(r.state_note,'state paused: the platform goes nowhere until unpaused (paused: false)')
  eq(marks[#marks],'Petrel stop 2: gleba: time 60s (was gleba: time 2m00s)','a wait edit with the stops kept is marked')
  -- stops on the paused platform: ok, said
  r=space.platform_schedule(p,{platform='Petrel',stops={{station='nauvis'},{station='gleba'}},current=1})
  has(r.still_paused,'Petrel was paused before this call and still is')
  recs=rawget(pl,'schedule').records; rawset(pl,'schedule',nil)   -- (the mock reads the records set)
  -- paused: true asked: no still_paused line (the call paused it)
  r=space.platform_schedule(p,{platform='Petrel',current=2,paused=true})
  eq(r.still_paused,nil,'paused: true given')
  cur=1
  pl.paused=false
  r=space.platform_schedule(p,{platform='Petrel',stop=2,wait={{type='time',ticks=1200}}})
  eq(r.still_paused,nil,'not paused')
  -- paused on a route: on the way to its current stop
  pl.paused=true; pl.space_connection={name='nauvis-gleba'}; cur=2
  stops=space.stops(pl)
  eq(stops[2],'2 gleba (flying to it, paused on the route: it goes nowhere until unpaused (paused: false)): time 20s')
  eq(stops[1],'1 nauvis: no wait condition','the stops call set it without waits')
  print('d24_batch153 bugs 1 and 2: paused platform schedule and stops: ok')
  game,defines,prototypes=nil,nil,nil
end

-- Bug 6: platform lanes outlived their platforms (7 in Sol's status), and a lane paused by a deploy read "paused (a
-- direct call that drives your character, stop, or a harness update)". A lane queue whose platform is no platform of
-- ours, with no step running, is closed after CLOSE_TICKS and its owner told once what it held; a pause names its
-- reason (pause_all's, a queue paused already keeps its own; carry.lua names the outgoing runtime's).
do
  game={tick=0,forces={player={platforms={{valid=true,name='Petrel'}}}}}
  local s={active={}}
  local p={index=7}
  local handlers={platform_schedule=function() end,platforms=function() return {} end}
  local base={state=function() return s end,player=function() return p end,handlers=handlers,busy=function() return false end,
    stop=function() end,stop_index=function() end,condition=function() return false,'not yet' end,validate_condition=function(c) assert(c['until']) end,
    outcome=function() return 'ok' end}
  local make=require('scheduler')
  local body=make(base)
  local told={}
  local L=require('queue_lanes'){scheduler=body,factory=make,base=base,is_read=function(n) return n=='platforms' end,
    deliver=function(index,t) told[#told+1]={index=index,t=t} end}
  local h=L.handlers
  local function tick(n) for _=1,n do game.tick=game.tick+1; L.tick() end end
  h.queue_submit(p,{lane='platform:Swift',steps={{action='platform_schedule',args={platform='Swift'}},{action='platforms',label='look'}},start=false})
  h.queue_submit(p,{lane='platform:Petrel',steps={{action='platforms'}},start=false})
  eq(L.lanes(7).platforms.Swift.paused,true)
  -- the deploy's pause: the reason on a queue it pauses; one paused already keeps its own
  s.queues={[7]={revision=0,sequence=0,pending={},history={},paused=false}}
  L.pause_all('paused by a harness update at tick 5')
  eq(s.queues[7].paused_why.line,'paused by a harness update at tick 5')
  has(L.lanes(7).platforms.Swift.paused_by,'staged by queue_submit start: false','a lane paused already keeps its reason')
  -- Swift is no platform of ours: closed CLOSE_TICKS after it was first read missing; Petrel's lane stays
  tick(L.CLOSE_EVERY)
  eq(L.lanes(7).platforms.Swift~=nil,true,'kept until CLOSE_TICKS')
  tick(L.CLOSE_TICKS)
  eq(L.lanes(7).platforms.Swift,nil,'before: the lane of a platform gone stays')
  eq(L.lanes(7).platforms.Petrel~=nil,true)
  eq(s.platform_lanes.Swift,nil); eq(s['lane_queues|Swift'],nil)
  eq(#told,1); eq(told[1].index,7)
  eq(told[1].t.text,'your platform lane platform:Swift is closed: no platform of ours is named Swift (read since tick 600). It held 2 pending steps: job-1 platform_schedule, job-2 platforms (look); paused, held: staged by queue_submit start: false: held until queue_resume; direct calls do not resume it.')
  tick(L.CLOSE_EVERY*2); eq(#told,1,'told once')
  -- a lane staged before its platform is made: kept while the platform comes within CLOSE_TICKS
  h.queue_submit(p,{lane='platform:Nova',steps={{action='platforms'}},start=false})
  tick(L.CLOSE_EVERY*2)
  table.insert(game.forces.player.platforms,{valid=true,name='Nova'})
  tick(L.CLOSE_TICKS)
  eq(L.lanes(7).platforms.Nova~=nil,true,'Nova came: its lane stays')
  eq(s.lane_missing.Nova,nil)
  print('d24_batch153 bug 6: lanes of platforms gone closed, pauses named: ok')
end

-- carry.lua: the outgoing runtime's reasonless pause in its last tick names the harness update
do
  game={tick=100}
  local st={queues={[1]={paused=true,pending={},history={},paused_why={tick=100,line='paused (a direct call that drives your character, stop, or a harness update)'}}},
    platform_lanes={Petrel=true},['lane_queues|Petrel']={[1]={paused=true,pending={},history={},paused_why={tick=40,line='paused (a direct call that drives your character, stop, or a harness update)'}}}}
  local C=require('carry'){state=function() return st end,update_pause=function(t) return 'paused by a harness update at tick '..t end}
  C.name_pause(st,100)
  eq(st.queues[1].paused_why.line,'paused by a harness update at tick 100')
  eq(st['lane_queues|Petrel'][1].paused_why.line,'paused (a direct call that drives your character, stop, or a harness update)','an older pause is not named')
  print('d24_batch153 carry names the deploy pause: ok')
  game=nil
end
