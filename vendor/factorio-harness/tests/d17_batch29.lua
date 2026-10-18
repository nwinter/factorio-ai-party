-- d17 batch29. Run from the harness root: lua tests/d17_batch29.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- C4 (Astra, twice: clearing a hub section made the ammo it held surplus, and the game sent it down): requests on a hub
-- names what it would then send down per item (dry_run too), and keep holds those requested at the count held.
do
  game={tick=0}
  defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
  prototypes={item={['firearm-magazine']={},['rocket-fuel']={},coal={}},space_location={nauvis={},vulcanus={}},quality={normal={}}}
  local slots={}
  local sec={index=1,is_manual=true,group='',active=true,filters_count=0}
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) slots[i]=f; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; for i,f in ipairs(v) do slots[i]=f end; recount() else rawset(t,k,v) end end})
  local secs=setmetatable({get_section=function(i) return i==1 and sec or nil end,add_section=function() return sec end},{__index=function(_,k) if k=='sections_count' then return 1 end end})
  local held={['firearm-magazine']=400,['rocket-fuel']=50}
  local main={get_item_count=function(n) return held[n] or 0 end,get_contents=function() return {} end}
  local platform={valid=true,name='Swiftlet',index=1,space_connection={},force='player',schedule={current=2,records={{station='vulcanus'},{station='nauvis'}}},
    hub={valid=true,unit_number=77,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end,
      get_item_count=function(n) return held[n] or 0 end}}
  local p={index=1,force={platforms={platform}}}
  local st={}
  local pads={nauvis={ask={['firearm-magazine']=1461},hold={['firearm-magazine']=61}},vulcanus={ask={['firearm-magazine']=200,['rocket-fuel']=0},hold={}}}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
    freight={where=function() return {stopped=true,at='nauvis'} end,pads=function(planet) return pads[planet].ask,pads[planet].hold end}}
  space.requests(p,{platform='Swiftlet',set={{item='firearm-magazine',min=400,from='nauvis',min_payload=100},{item='rocket-fuel',min=100,from='vulcanus'}}})
  -- a dry run of a clear: what goes down where, nothing changed
  local r=space.requests(p,{platform='Swiftlet',clear={'firearm-magazine'},dry_run=true})
  eq(r.dry_run,true); has(r.dry_note,'nothing was changed')
  eq(#r.sends_down,1)
  eq(r.sends_down[1],'firearm-magazine: the hub holds 400 and would keep 0 of it (kept 400): 400 surplus; 400 down to nauvis (here) (its landing pads ask 1461, hold 61)')
  eq(#r.sections[1].requests,1,'the reply shows the section as it would be')
  eq(slots[1].value.name,'firearm-magazine'); eq(slots[1].min,400); eq(slots[2].value.name,'rocket-fuel')
  eq(st.hub_min_payload[77]['firearm-magazine|normal'],nil,'the kept min payload is put back too')
  -- held past the first stop's ask: the rest goes to the next stop's pads, then stays aboard
  pads.nauvis.hold['firearm-magazine']=1361
  r=space.requests(p,{platform='Swiftlet',clear_all=true,dry_run=true})
  eq(r.sends_down[1],'firearm-magazine: the hub holds 400 and would keep 0 of it (kept 400): 400 surplus; 100 down to nauvis (here) (its landing pads ask 1461, hold 1361), 200 down to vulcanus (its landing pads ask 200, hold 0); 100 stay aboard')
  eq(r.sends_down[2],'rocket-fuel: the hub holds 50 and would keep 0 of it (kept 50): 50 surplus; no landing pad on its stops asks for it: it stays aboard')
  eq(slots[1].min,400)
  -- keep: clear_all, the magazines stay requested at the count held (import planet and min payload of the dropped one)
  r=space.requests(p,{platform='Swiftlet',clear_all=true,keep={'firearm-magazine','coal'}})
  eq(r.dry_run,nil)
  eq(slots[1].value.name,'firearm-magazine'); eq(slots[1].min,400); eq(slots[1].import_from,'nauvis'); eq(slots[1].minimum_delivery_count,100); eq(slots[2],nil)
  has(r.stored[1],'firearm-magazine: kept at the 400 the hub holds (firearm-magazine 400')
  eq(r.stored[2],'coal: kept already (the hub holds 0, its requests keep 0)')
  eq(#r.sends_down,1); has(r.sends_down[1],'rocket-fuel: the hub holds 50 and would keep 0')
  -- refusals
  fails(function() space.requests(p,{platform='Swiftlet',keep={'coal'}}) end,'keep goes with a change')
  fails(function() space.requests(p,{platform='Swiftlet',clear={'coal'},dry_run=true,trash_unrequested=true}) end,'dry_run reads set')
  defines,prototypes,game=nil,nil,nil
end
print('d17_batch29 C4 hub surplus sent down: ok')
