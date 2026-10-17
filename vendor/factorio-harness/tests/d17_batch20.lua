-- d17 batch20 (operator 15:25: the agents' 15:20 poll). Run from the harness root: lua tests/d17_batch20.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A4 (Sol): a hub's custom minimum payloads outlive requests {clear_all} and {clear}; min_payload runs in the remote lane.
do
  game={tick=0}
  defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
  prototypes={item={['plastic-bar']={},concrete={},coal={}},space_location={nauvis={},vulcanus={}},quality={normal={}}}
  local slots={}
  local sec={index=1,is_manual=true,group='',active=true,filters_count=0}
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) slots[i]=f; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; for i,f in ipairs(v) do slots[i]=f end; recount() else rawset(t,k,v) end end})
  local secs=setmetatable({get_section=function(i) return i==1 and sec or nil end,add_section=function() return sec end},{__index=function(_,k) if k=='sections_count' then return 1 end end})
  local main={get_item_count=function() return 0 end,get_contents=function() return {} end}
  local platform={valid=true,name='Swiftlet',index=1,space_connection={},
    hub={valid=true,unit_number=77,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end}}
  local p={index=1,force={platforms={platform}}}
  local st={}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,freight={where=function() return {} end}}
  space.requests(p,{platform='Swiftlet',set={{item='plastic-bar',min=1500,from='vulcanus',min_payload=1500},{item='concrete',min=80,from='nauvis',min_payload=80}}})
  eq(slots[1].minimum_delivery_count,1500); eq(slots[2].minimum_delivery_count,80)
  -- clear_all and set in one call: each item's min payload comes back
  local r=space.requests(p,{platform='Swiftlet',clear_all=true,set={{item='plastic-bar',min=500,from='vulcanus'}}})
  eq(slots[1].minimum_delivery_count,1500); has(r.stored[1],'(min payload 1500 kept from the request cleared before)')
  -- a later call too
  r=space.requests(p,{platform='Swiftlet',set={{item='concrete',min=40,from='nauvis'}}})
  eq(slots[2].minimum_delivery_count,80); has(r.stored[1],'concrete 40..inf from nauvis min payload 80 (min payload 80 kept from the request cleared before)')
  -- clear by name keeps it too; min_payload false forgets it
  space.requests(p,{platform='Swiftlet',clear={'concrete'}})
  r=space.requests(p,{platform='Swiftlet',set={{item='concrete',min=40,from='nauvis',min_payload=false}}})
  eq(slots[2].minimum_delivery_count,nil)
  space.requests(p,{platform='Swiftlet',clear={'concrete'}})
  r=space.requests(p,{platform='Swiftlet',set={{item='concrete',min=40,from='nauvis'}}})
  eq(slots[2].minimum_delivery_count,nil)
  -- the remote lane takes min_payload
  local remote
  dofile('mod/agent-harness_0.1.0/queue_lanes.lua'){scheduler={handlers={},schema={queue_submit={},queue_status={returns=''}}},base={},
    factory=function(r_) remote=r_; return {handlers={}} end,is_read=function() return false end}
  remote.check_step('min_payload',{platforms='Swiftlet',set={['plastic-bar']=1500}})
  fails(function() remote.check_step('craft',{recipe='x'}) end,'not supported in the remote lane')
end
print('d17_batch20 A4 min payload: ok')
