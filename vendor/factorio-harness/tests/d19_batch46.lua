-- d19 batch46. Run from the harness root: lua tests/d19_batch46.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- 3 (viewer Aurora, d18 23:24): a silo's and a platform's settings agents change keep who, when, before and after
-- (editlog.lua M.setting), the latest of each shown by M.lines (silo and platform reads); the earlier editor is told.
-- The mocks are d19_batch41.lua B1's.
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
  space.remote_entity=nil
  -- the platform's stops and paused: sol sets them, astra changes both; sol is told; the lines read the latest of each
  space.platform_schedule(sol,{platform='Swiftlet',stops={{station='fulgora'},{station='nauvis'}}})
  has(E.lines('plat:Swiftlet')[1],'schedule stops: 1 nauvis, 2 fulgora -> 1 fulgora, 2 nauvis, by sol')
  game.tick=216000
  space.platform_schedule(astra,{platform='Swiftlet',stops={{station='nauvis'},{station='fulgora'},{station='gleba'}}})
  eq(told[#told].i,11,'sol told of the stops'); eq(#told,1,'one tell: the gate edit names the stops')
  space.platform_schedule(astra,{platform='Swiftlet',paused=true})
  local lines=E.lines('plat:Swiftlet')
  eq(#lines,2,'stops and paused')
  -- (one tick: by setting name)
  has(lines[1],'paused: not paused -> paused, by astra at game time 1h00m')
  eq(lines[2],'schedule stops: 1 fulgora, 2 nauvis -> 1 nauvis, 2 fulgora, 3 gleba, by astra at game time 1h00m (tick 216000, 0s ago)')
  -- no change, no record; the same editor again tells nobody
  eq(E.setting('plat:Swiftlet','paused','astra','paused','paused'),nil)
  -- a silo: sol switches automatic requests on, astra off: sol told; the silo's lines say it
  game.tick=219600
  E.setting('silo:77','automatic requests','sol','off','on')
  game.tick=223200
  local t=E.setting('silo:77','automatic requests','astra','on','off')
  eq(t[1],'sol','sol told')
  has(told[#told].t.text,'changed what you set last: automatic requests: on -> off')
  E.setting('silo:77','send to orbit automatically','astra','off','on')
  lines=E.lines('silo:77')
  eq(#lines,2)
  eq(lines[1],'automatic requests: on -> off, by astra at game time 1h02m (tick 223200, 0s ago)')
  eq(E.lines('silo:78'),nil,'a silo nobody changed has none')
  -- space.launch {auto_requests} records the switch on the silo it changes
  local silo={valid=true,type='rocket-silo',unit_number=90,use_transitional_requests=false,get_inventory=function() return main end}
  local space2=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,editlog=E,remote_entity=function() return silo end,
    integer=function(v,d) return v==nil and d or v end}
  defines.inventory.rocket_silo_rocket=5
  space2.launch(sol,{position={x=0,y=0},auto_requests=true})
  eq(silo.use_transitional_requests,true)
  has(E.lines('silo:90')[1],'automatic requests: off -> on, by sol')
  game,defines,prototypes=nil,nil,nil
end
print('d19_batch46 3 silo and platform setting edits: who, when, before and after; the latest of each in the reads: ok')
