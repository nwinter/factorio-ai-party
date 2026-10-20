-- d19 batch48. Run from the harness root: lua tests/d19_batch48.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- 1 and 2 (Sol 17:29, Kestrel IV at Aquilo): platform_schedule {current} alone goes to that stop (or is refused when it
-- changes nothing); the departure a call causes is recorded, and a platform_left wait begun just after counts it.
-- The platform mocks are d19_batch41.lua B1's.
do
  game={tick=1000}
  defines={space_platform_state={paused=7,waiting_at_station=4,on_the_path=3,no_schedule=1},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={},
    wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={item={['firearm-magazine']={},['iron-plate']={}},space_location={nauvis={},fulgora={},gleba={}},quality={normal={}},fluid={['thruster-fuel']={}}}
  local slots={}
  local sec={index=1,is_manual=true,group='',active=true,filters_count=0}
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) local c={} for k,v in pairs(f) do c[k]=v end; c.import_from=c.import_from or 'nauvis'; slots[i]=c; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; for i,f in ipairs(v) do slots[i]=f end; recount() else rawset(t,k,v) end end})
  local secs=setmetatable({get_section=function(i) return i==1 and sec or nil end,add_section=function() return sec end},{__index=function(_,k) if k=='sections_count' then return 1 end end})
  local main={get_item_count=function() return 0 end,get_contents=function() return {} end}
  local pl={valid=true,name='Swiftlet',index=1,state=4,space_location={name='nauvis'},force='player',paused=false,
    schedule={current=1,records={{station='nauvis'},{station='fulgora'}}},
    hub={valid=true,unit_number=78,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end,
      get_item_count=function() return 0 end,get_circuit_network=function() return nil end}}
  local sch=setmetatable({},{__index=function(_,k) if k=='current' then return pl.schedule and pl.schedule.current end end})
  sch.get_record_count=function() return #pl.schedule.records end
  sch.go_to_station=function(i) pl.schedule.current=i end
  pl.get_schedule=function() return sch end
  local force={platforms={pl}}
  local sol,astra={index=11,name='sol',force=force},{index=12,name='astra',force=force}
  local st,told={},{}
  local E=dofile('mod/agent-harness_0.1.0/editlog.lua'){state=function() return st end,deliver=function(i,t) told[#told+1]={i=i,t=t} end,
    index_of=function(n) return ({sol=11,astra=12})[n] end}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,editlog=E,
    integer=function(v,d,lo,hi) v=v==nil and d or v; return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
    circuit_condition=function(c) return c end,
    freight={where=function() return {stopped=true,at='nauvis'} end,pads=function() return {},{} end,leg=function() return nil end}}
  -- going to a stop: the platform leaves its station (the game's go_to_station)
  sch.go_to_station=function(i) pl.schedule.current=i; if pl.state==4 then pl.state=3; pl.space_location=nil end end
  pl.schedule.records={{station='nauvis'},{station='fulgora'},{station='gleba'},{station='aquilo'}}
  pl.schedule.current=1
  -- current on the stop it waits at: refused, saying what changes it
  fails(function() space.platform_schedule(sol,{platform='Swiftlet',current=1}) end,'nothing changed: stop 1 (nauvis) is already the current stop (it waits there); current 2 sends it to stop 2 now')
  eq(pl.state,4,'still waiting')
  -- current 4 alone: go to station 4, the records kept, the departure recorded
  game.tick=5000
  local r=space.platform_schedule(sol,{platform='Swiftlet',current=4})
  eq(pl.schedule.current,4); eq(#pl.schedule.records,4,'records kept')
  has(r.sent_to,'from stop 1 (nauvis) to stop 4 (aquilo): go to station called (it was waiting at nauvis), the records and their waits kept')
  has(r.departed,'left nauvis at tick 5000')
  eq(st.schedule_departures.Swiftlet.from,'nauvis'); eq(st.schedule_departures.Swiftlet.by,'sol')
  -- in flight to stop 4, current 4 again changes nothing
  fails(function() space.platform_schedule(sol,{platform='Swiftlet',current=4}) end,'(it flies there)')
  -- a schedule edit that leaves it where it is records no departure
  pl.state=4; pl.space_location={name='aquilo'}; pl.schedule.current=4
  st.schedule_departures=nil
  space.platform_schedule(sol,{platform='Swiftlet',paused=false})
  eq(st.schedule_departures,nil,'no departure')

  -- the wait: freight.where carries the departure; platform_left begun in the same tick, or up to 60 ticks after, counts it
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){platform_where=function(x) return F.where(x) end,position=function(v) return v end}
  pl.state=3; pl.space_location=nil
  st.schedule_departures={Swiftlet={from='aquilo',tick=7000,by='sol'}}
  local force={platforms={pl}}
  local who={force=force}
  for _,case in ipairs({{7000,true},{7060,true},{7061,false}}) do
    game.tick=case[1]
    local met,line=C.check(who,{['until']='platform_left',platform='Swiftlet',location='aquilo'},nil,{})
    eq(met,case[2],'began at '..case[1]..': '..tostring(line))
    if met then has(line,'Swiftlet left aquilo at tick 7000 (platform_schedule by sol, '..(case[1]-7000)..' ticks before this wait began)') end
  end
  -- another location's departure does not count
  game.tick=7000
  local met=C.check(who,{['until']='platform_left',platform='Swiftlet',location='nauvis'},nil,{})
  eq(met,false)
  -- a wait begun while it waits there is met when it leaves, as before
  pl.state=4; pl.space_location={name='aquilo'}; st.schedule_departures=nil
  local rec={}
  eq((C.check(who,{['until']='platform_left',platform='Swiftlet'},nil,rec)),false)
  pl.state=3; pl.space_location=nil
  eq((C.check(who,{['until']='platform_left',platform='Swiftlet'},nil,rec)),true)

  -- cp2 (Sol 18:01): no_schedule while rockets launched to it are on the way: the recheck waits for them (up to 3600)
  local coming={rockets=1,rows={{tick=8000,eta_ticks=1500}},lines={'a rocket from nauvis launched 10s ago (tick 8000): bulk-inserter*1 (rising over nauvis)'},cargo='bulk-inserter*1'}
  local incoming=coming
  local space3=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,editlog=E,
    integer=function(v,d,lo,hi) v=v==nil and d or v; return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
    circuit_condition=function(c) return c end,
    freight={where=function() return {stopped=true,at='nauvis'} end,pads=function() return {},{} end,leg=function() return nil end,incoming=function() return incoming end}}
  game.tick=8600
  sol.force.name='player'; game.forces={player=sol.force}
  pl.state=4; pl.space_location={name='nauvis'}; pl.paused=false
  sch.go_to_station=function(i) pl.schedule.current=i; pl.state=1 end  -- the game reads no_schedule while it holds
  local r2=space3.platform_schedule(sol,{platform='Swiftlet',stops={{station='nauvis'},{station='fulgora'}},current=2})
  eq(r2.state,'no_schedule')
  local rc=r2.recheck
  eq(rc.ends_tick,8600+1500+180,'waits to the rocket\'s arrival and 3 s')
  has(rc.line,'1 rocket launched to it is still on the way (a rocket from nauvis launched 10s ago')
  has(rc.line,'the game keeps a platform at its station until the rockets launched to it arrive')
  game.tick=8600+300
  eq(space3.recheck_read(rc),nil,'past 300 ticks it still waits')
  -- the rocket arrived, the platform left
  incoming=nil; pl.state=3; pl.space_location=nil
  game.tick=10100
  local ok=space3.recheck_read(rc)
  eq(ok.ok,true); has(ok.line,'and on_the_path 1500 ticks later'); has(ok.line,'(it waited for the rockets launched to it)')
  -- still no_schedule past the longest hold: failed, saying so
  incoming=coming; pl.state=1
  rc=space3.platform_schedule(sol,{platform='Swiftlet',stops={{station='nauvis'},{station='fulgora'}},current=2}).recheck
  game.tick=rc.tick+3600
  local bad=space3.recheck_read(rc)
  eq(bad.ok,false); has(bad.line,'(waited the longest it waits, 3600 ticks)')
  -- no rocket on the way: the 300 ticks as before
  incoming=nil; pl.state=4; pl.space_location={name='nauvis'}
  game.tick=20000
  rc=space3.platform_schedule(sol,{platform='Swiftlet',stops={{station='nauvis'},{station='fulgora'}},current=2}).recheck
  eq(rc.ends_tick,20300); eq(rc.rockets,nil)
  game,defines,prototypes=nil,nil,nil
end
print('d19_batch48 platform_schedule current alone, platform_left counting the departure the step before it caused, the recheck waiting for rockets on the way: ok')
