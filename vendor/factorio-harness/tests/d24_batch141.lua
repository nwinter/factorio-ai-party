-- d24 batch141 PM1 (Sol #2125): requests {platform: "Meridian-V", set: [{item: "bioflux", min: 20, max: 30, from: "gleba",
-- min_payload: 10}]} set the slot, then answered "bad argument #5 ... to 'format' (number expected, got nil)": sends_down
-- named the landing pads' ask at gleba for an item they do not ask for (batch137's finite max sends all above it, asked
-- or not). Fixed there; and a mutating action whose reply fails after its change answers the change and the error.
-- Run from the harness root: lua tests/d24_batch141.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

game={tick=55693611}
defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
prototypes={item={bioflux={weight=1000}},space_location={nauvis={},gleba={}},quality={normal={}},utility_constants={rocket_lift_weight=1000000}}
local slots={}
local sec={index=1,is_manual=true,group='',active=true,filters_count=0}
local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
sec.get_slot=function(i) return slots[i] or {} end
sec.set_slot=function(i,f) slots[i]=f; recount() end
sec.clear_slot=function(i) slots[i]=nil; recount() end
setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
  __newindex=function(t,k,v) if k=='filters' then slots={}; for i,f in ipairs(v) do slots[i]=f end; recount() else rawset(t,k,v) end end})
local secs=setmetatable({get_section=function(i) return i==1 and sec or nil end,add_section=function() return sec end},{__index=function(_,k) if k=='sections_count' then return 1 end end})
local held={bioflux=180}
local main={get_item_count=function(n) return held[type(n)=='table' and n.name or n] or 0 end,get_contents=function() return {} end}
local platform={valid=true,name='Meridian-V',index=4,force='player',schedule={current=1,records={{station='gleba'},{station='nauvis'}}},
  hub={valid=true,unit_number=91,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end,
    get_item_count=function(n) return held[n] or 0 end}}
local p={index=1,name='sol',force={platforms={platform}}}
local st={}
-- the landing pads at gleba and nauvis ask no bioflux
local pads={gleba={ask={},hold={}},nauvis={ask={bioflux=10},hold={}}}
local pads_fail=false
local marks={}
-- as at Sol's call: flying from gleba to nauvis, its next stop
local where={}
platform.schedule.current=2
local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,made=function(t) marks[#marks+1]=t end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
  freight={where=function() return where end,pads=function(planet) if pads_fail then error('pads unread',0) end return pads[planet].ask,pads[planet].hold end}}
-- the slot as Sol had it: bioflux 180 from gleba (no max)
slots[1]={value={type='item',name='bioflux',quality='normal',comparator='='},min=180,import_from='gleba'}; recount()

-- Sol's call: the reply, with sends_down saying the 150 above the max go down at gleba though its pads ask none
local r=space.requests(p,{platform='Meridian-V',section=1,set={{item='bioflux',min=20,max=30,from='gleba',min_payload=10}}})
eq(slots[1].min,20); eq(slots[1].max,30); eq(slots[1].minimum_delivery_count,10)
has(r.stored[1],'bioflux 20..30 from gleba min payload 10')
-- (the copy of world n: 150 in the trash within 4 s, all 150 down to Nauvis's pad at the stop, 30 aboard on to gleba)
eq(r.sends_down[1],'bioflux: the hub holds 180; its requests would keep 30 at gleba (kept all at gleba): 150 over its max 30 go to the hub\'s trash now and down to nauvis at its next stop, asked or not; 30 stay aboard')
has(r.over_max[1],'bioflux: the hub holds 180, 150 over the max 30')
eq(r.reply_failed,nil)
has(marks[1],'bioflux 20..30 from gleba min payload 10')
-- stopped at gleba, whose pads ask none: the 150 go down there; nauvis's pads ask 10 of the 30 left at its next stop
where={stopped=true,at='gleba'}
slots[1]={value={type='item',name='bioflux',quality='normal',comparator='='},min=180,import_from='gleba'}; recount()
r=space.requests(p,{platform='Meridian-V',set={{item='bioflux',min=20,max=30,from='gleba'}},dry_run=true})
eq(r.sends_down[1],'bioflux: the hub holds 180; its requests would keep 30 at gleba (kept all at gleba): 150 over its max 30 go to the hub\'s trash now and down to gleba (here), asked or not, 10 down to nauvis (its landing pads ask 10, hold 0); 20 stay aboard')

-- maxes at two planets (20..30 from gleba, 0..100 from nauvis; the hub's max 130): past the trash, batch137's rule at a
-- stop whose requests keep less than is left names a pad that asks none as asking 0
where={}
slots[1]={value={type='item',name='bioflux',quality='normal',comparator='='},min=180,import_from='gleba'}
slots[2]={value={type='item',name='bioflux',quality='normal',comparator='='},min=0,max=100,import_from='nauvis'}; recount()
r=space.requests(p,{platform='Meridian-V',section=1,set={{item='bioflux',min=20,max=30,from='gleba'}},dry_run=true})
has(r.sends_down[1],'50 over its max 130 go to the hub\'s trash now and down to nauvis at its next stop, asked or not')
has(r.sends_down[1],'down to gleba (its landing pads ask 0, hold 0; its requests from gleba keep 30)')
slots[2]=nil; recount()

-- a part of the reply that fails after the change: the change stands, the reply says it and names the part
slots[1]={value={type='item',name='bioflux',quality='normal',comparator='='},min=180,import_from='gleba'}; recount()
pads_fail=true; marks={}
r=space.requests(p,{platform='Meridian-V',set={{item='bioflux',min=20,max=30,from='gleba'}}})
eq(slots[1].max,30)
has(r.stored[1],'bioflux 20..30 from gleba')
eq(r.reply_failed[1],'sends_down: pads unread')
has(r.reply_failed_note,'the change was made (stored, changed_section)')
eq(r.changed_section,1); assert(r.sections and r.over_max,'the other parts of the reply are there')
eq(#marks,1)
-- a dry run whose reply part fails: what it set is put back, and nothing was changed
slots[1]={value={type='item',name='bioflux',quality='normal',comparator='='},min=180,import_from='gleba'}; recount()
marks={}
r=space.requests(p,{platform='Meridian-V',set={{item='bioflux',min=20,max=30,from='gleba'}},dry_run=true})
eq(slots[1].min,180); eq(slots[1].max,nil)
eq(r.reply_failed[1],'sends_down: pads unread')
has(r.reply_failed_note,'nothing was changed (dry run)')
eq(#marks,0)
-- a dry run that fails before its reply: put back too
local add=sec.set_slot
local n=0
sec.set_slot=function(i,f) n=n+1; if n==2 then error('slot refused',0) end add(i,f) end
local ok,err=pcall(space.requests,p,{platform='Meridian-V',set={{item='bioflux',min=20,max=30,from='gleba'},{item='bioflux',min=5,quality='normal'}},dry_run=true})
assert(not ok,'the second set fails')
eq(slots[1].min,180,'put back after the failure: '..tostring(err))
sec.set_slot=add
pads_fail=false
print('d24_batch141 PM1 requests sends_down nil ask, reply after the change: ok')

-- made.lua: a wrapped action that fails after it marked a change answers the change and the error; one that fails before
-- any mark fails as before
local function reason(e) local t,n=tostring(e),1; while n>0 do t,n=t:gsub('^[^:]*:%d+: ','') end; return t end
local made=dofile('mod/agent-harness_0.1.0/made.lua'){reason=reason}
local handlers={}
handlers.requests=function(_,a)
  if a.refuse then error('refused before any change',0) end
  made.mark('bioflux 20..30 from gleba (was bioflux 180 from gleba)')
  if a.inner then handlers.inner(nil,{}) end
  error('space.lua:435: bad argument #5 to \'format\' (number expected, got nil)')
end
handlers.inner=function() made.mark('section 2 added'); error('inner reply failed',0) end
made.wrap(handlers,{'requests','inner'})
ok,err=pcall(handlers.requests,nil,{refuse=true})
assert(not ok and err=='refused before any change',tostring(err))
r=handlers.requests(nil,{})
eq(r.change_made[1],'bioflux 20..30 from gleba (was bioflux 180 from gleba)')
eq(r.reply_failed,'bad argument #5 to \'format\' (number expected, got nil)')
has(r.reply_failed_note,'the change in change_made was made')
-- a wrapped action called inside another: its change is the outer one's too
r=handlers.requests(nil,{inner=true})
eq(#r.change_made,2); eq(r.change_made[2],'section 2 added')
-- marks outside a wrapped call go nowhere
made.mark('stray'); r=handlers.requests(nil,{}); eq(#r.change_made,1)
print('d24_batch141 PM1 made.lua: ok')
-- platform_schedule and min_payload mark their changes: a failure after the write still names it
do
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,paused=7},inventory={hub_main=1,hub_trash=2}}
  prototypes={space_location={nauvis={},gleba={}},item={bioflux={weight=1000}},utility_constants={rocket_lift_weight=1000000}}
  local pl={valid=true,name='Meridian-V',index=4,state=4,space_location={name='gleba'},paused=false}
  local sch={get_record_count=function() return pl.schedule and #pl.schedule.records or 0 end,go_to_station=function(i) pl.schedule.current=i end}
  pl.get_schedule=function() return sch end
  local q={force={platforms={pl}}}
  local marks2={}
  local space2=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,made=function(t) marks2[#marks2+1]=t end,
    integer=function(v,d) return v==nil and d or v end,freight={where=function() return {} end,leg=function() return nil end},
    platwait=function() return {set=function() end,clear=function() end,get=function() end,line=function() error('platwait line unread',0) end} end}
  local ok2,err2=pcall(space2.platform_schedule,q,{platform='Meridian-V',stops={{station='gleba'},{station='nauvis'}},current=1})
  assert(not ok2 and tostring(err2):find('platwait line unread',1,true),tostring(err2))
  eq(pl.schedule.records[2].station,'nauvis')
  eq(marks2[1],'Meridian-V schedule: 1 gleba, 2 nauvis, current 1 (was no stops, current none)')
  -- min_payload
  marks2={}
  local slot={value={type='item',name='bioflux',quality='normal'},min=20,max=30,import_from='gleba',minimum_delivery_count=10}
  local msec={is_manual=true,group='',filters={slot},get_slot=function() return slot end,set_slot=function(_,f) slot=f end}
  pl.hub={valid=true,get_logistic_sections=function() return {sections_count=1,get_section=function() return msec end} end,get_item_count=function() return 180 end}
  local MP=dofile('mod/agent-harness_0.1.0/minpayload.lua'){made=function(t) marks2[#marks2+1]=t end}
  MP.handler(q,{platforms='Meridian-V',set={bioflux=25}})
  eq(slot.minimum_delivery_count,25)
  eq(marks2[1],'Meridian-V: bioflux custom minimum payload 25 (was 10)')
end
print('d24_batch141 PM1 platform_schedule and min_payload marks: ok')
