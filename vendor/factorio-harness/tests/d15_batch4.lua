-- d15 batch4 (operator 21:25, shifts 19-20 requests). Run from the harness root: lua tests/d15_batch4.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- 1 (Sol): requests checks every argument before it changes anything; max "inf" on a hub. --------------------------
do
  defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
  prototypes={item={['firearm-magazine']={},coal={}},space_location={nauvis={},vulcanus={}},quality={normal={},rare={}}}
  local function section(manual)
    local slots={}
    local sec={index=1,is_manual=manual,group='',active=true,filters_count=0}
    local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
    sec.get_slot=function(i) return slots[i] or {} end
    sec.set_slot=function(i,f) slots[i]=f; recount() end
    sec.clear_slot=function(i) slots[i]=nil; recount() end
    setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end})
    return sec
  end
  local list={section(true)}
  local secs=setmetatable({get_section=function(i) return list[i] end,add_section=function() local s=section(true); s.index=#list+1; list[#list+1]=s; return s end},
    {__index=function(_,k) if k=='sections_count' then return #list end end})
  local held=450
  local main={get_item_count=function() return held end,get_contents=function() return {{name='firearm-magazine',count=held}} end}
  local trash={get_contents=function() return {} end}
  local platform={valid=true,name='Starling',index=1,space_location=nil,space_connection={},
    hub={valid=true,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,
      get_inventory=function(i) return i==1 and main or trash end}}
  local p={index=1,force={platforms={platform}}}
  local switched=0
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    keep=function() return {set_construction=function(_,on) switched=switched+1; return on end,construction=function() return nil end} end,
    freight={where=function() return {} end}}
  local r=space.requests(p,{platform='Starling',set={{item='firearm-magazine',min=400,max='inf',from='vulcanus'}}})
  eq(r.stored[1],'firearm-magazine 400..inf from vulcanus')
  eq(r.over_max,nil,'no max, nothing over it')
  r=space.requests(p,{platform='Starling',set={{item='firearm-magazine',min=400,max=420}}})
  eq(r.over_max[1],'firearm-magazine: the hub holds 450, 30 over the max 420')
  -- A bad second entry: nothing changes, not even the construction switch or the first entry.
  fails(function() space.requests(p,{platform='Starling',construction_requests=true,set={{item='coal',min=5},{item='firearm-magazine',min=10,max='lots'}}}) end,
    'or "inf" for none: "lots" is not')
  eq(switched,0,'construction switch untouched'); eq(#list[1].filters,1,'coal not set')
  fails(function() space.requests(p,{platform='Starling',clear={'firearm-magazine','nope'}}) end,'unknown item: nope')
  eq(list[1].filters[1].max,420,'the clear changed nothing')
  fails(function() space.requests(p,{platform='Starling',set={{item='coal',min=5,from='mars'}}}) end,'mars is not one')
  fails(function() space.requests(p,{platform='Starling',set={{item='coal',min=5,quality='legendary'}}}) end,'unknown quality: legendary')
  fails(function() space.requests(p,{platform='Starling',section=4,set={{item='coal',min=5}}}) end,'section 4 does not exist')
  eq(#list[1].filters,1)
  r=space.requests(p,{platform='Starling',set={{item='coal',min=5,max='Infinity'}}})
  eq(r.stored[1],'coal 5..inf')
end
print('d15_batch4 1 requests: ok')
