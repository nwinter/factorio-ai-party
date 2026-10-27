-- Run from repository root: lua tests/d26_batch253.lua
-- d26 batch253 FP (row freight-preflight, viewer Aurora site:4946: "Could finite-freight preflight declare full pickup
-- or partial visits, then compare departure waits? Warn on mismatches and leave schedules unchanged. #2365 exposed
-- differing expectations"): #2365, Kestrel IVb's 2000 uranium-rounds-magazine from Nauvis. Sol expected a hub >= 2000
-- departure gate (a full pickup); Luna ran it as partial visits ("continues subsequent visit if early departure"); the
-- Nauvis stop's nine waits had no uranium wait. shipment {platform, freight} compares a declared full pickup or
-- partial visits with each pickup stop's waits and the hub's requests from there, warns with the numbers, and writes
-- nothing.
local function eq(a,b,m) if a~=b and type(a)=='table' then a=table.concat(a,' | ') end; assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,e=pcall(f); assert(not ok,'should fail: '..x); has(e,x) end
local function frozen(t)  -- the read must write nothing: every table it reads refuses a write
  for _,v in pairs(t) do if type(v)=='table' and not getmetatable(v) then frozen(v) end end
  return setmetatable(t,{__newindex=function(_,k) error('wrote '..tostring(k)) end})
end
game={tick=1000}
prototypes={item={['uranium-rounds-magazine']={},['iron-plate']={}}}
local UM='uranium-rounds-magazine'
local function sig(name,q) return {type='item',name=name,quality=q} end
local function item_wait(n,cmp,how,q) return {type='item_count',compare_type=how or 'and',condition={first_signal=sig(UM,q),comparator=cmp or '≥',constant=n}} end
local function time_wait(s,how) return {type='time',compare_type=how or 'and',ticks=s*60} end
local function sections(list)  -- list: {{min, max?, from, quality?}}
  local filters={}
  for _,r in ipairs(list) do filters[#filters+1]={value={type='item',name=r.item or UM,quality=r.quality or 'normal',comparator='='},min=r.min,max=r.max,import_from=r.from} end
  local sec={active=true,filters=filters}
  return {sections_count=1,get_section=function() return sec end}
end
local function ship(waits_nauvis,reqs,extra)
  local recs={{station='gleba',wait_conditions={time_wait(30)}},{station='nauvis',wait_conditions=waits_nauvis},{station='aquilo',wait_conditions={time_wait(60)}}}
  local secs=sections(reqs)
  local pl={valid=true,name='Kestrel IVb',schedule={current=1,records=recs},hub={valid=true,get_logistic_sections=function() return secs end}}
  frozen(recs); frozen(secs)
  return {force={platforms={pl}}}
end
local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){integer=function(v,d,lo,hi,n) assert(type(v)=='number' and v>=lo and v<=hi and v==math.floor(v),n..' out of range'); return v end}
local function read(p,mode,amount,from,item) return S.read(p,{platform='Kestrel IVb',freight={item=item or UM,amount=amount or 2000,mode=mode,from=from}}) end
local NAUVIS={{min=2000,from='nauvis'}}

-- 1. #2365 as it was: a full 2000 pickup declared, the Nauvis stop's waits are time ones only
local r=read(ship({time_wait(120),time_wait(20,'or')},NAUVIS),'full')
eq(#r.stops,1); eq(r.stops[1].stop,2); eq(r.stops[1].planet,'nauvis'); eq(r.stops[1].waits_for,nil); eq(r.stops[1].requests_min,2000); eq(r.stops[1].requests_max,nil)
eq(#r.warnings,1); has(r.warnings[1],'stop 2 (nauvis): no wait on '..UM..' (waits: time 120 s, time 20 s): it leaves then, whatever is aboard')
has(r.line,'Kestrel IVb full 2000 '..UM..': 1 stops, 1 mismatches')
-- 2. Sol's expectation met: hub >= 2000 at Nauvis, requests 2000: no mismatch
r=read(ship({item_wait(2000)},NAUVIS),'full')
eq(r.warnings,nil); eq(r.stops[1].waits_for,2000)
-- 3. the gate Sol first read, 1600: it can leave with 1600 aboard
r=read(ship({item_wait(1600)},{{min=2000,from='nauvis'}}),'full'); has(r.warnings[1],'stop 2 (nauvis): waits for 1600 '..UM..', under the 2000 declared')
-- '>' 1999 counts as 2000; '<=' and '!=' are no pickup wait
eq(read(ship({item_wait(1999,'>')},NAUVIS),'full').warnings,nil)
has(read(ship({item_wait(2000,'≤')},NAUVIS),'full').warnings[1],'no wait on')
-- 4. the item wait joined by or with a time wait: the time can send it on first
r=read(ship({item_wait(2000),time_wait(600,'or')},NAUVIS),'full'); has(r.warnings[1],'its '..UM..' wait is joined by or (time 600 s): that can send it on first')
eq(r.stops[1].joined_by_or,true)
-- 5. partial visits (Luna's run) against an item wait of 2000 alone: it would wait there for good
r=read(ship({item_wait(2000)},NAUVIS),'partial'); has(r.warnings[1],'stop 2 (nauvis): partial visits, but it waits for 2000 '..UM..' with no or: it stays until they are aboard')
-- partial visits with time waits, or the item wait joined by or: no mismatch
eq(read(ship({time_wait(120)},NAUVIS),'partial').warnings,nil)
eq(read(ship({item_wait(2000),time_wait(600,'or')},NAUVIS),'partial').warnings,nil)
-- 6. requests: a max under the amount; a min under it for a full pickup; a wait above the max (as #2427's waits_unmet)
r=read(ship({item_wait(2000)},{{min=1000,max=1600,from='nauvis'}}),'full')
has(r.warnings[1],'stop 2 (nauvis): its requests keep at most 1600 '..UM..', under the 2000 declared')
has(r.warnings[2],'stop 2 (nauvis): it waits for 2000 '..UM..'; its requests keep at most 1600'); eq(r.stops[1].requests_max,1600)
r=read(ship({item_wait(2000)},{{min=1000,from='nauvis'}}),'full'); has(r.warnings[1],'its requests ask 1000 '..UM..', under the 2000 declared')
eq(read(ship({time_wait(120)},{{min=1000,from='nauvis'}}),'partial').warnings,nil)  -- partial visits: a smaller min is the visit
-- two sections of the same item and planet are summed (min and max)
r=read(ship({item_wait(2000)},{{min=1000,max=1200,from='nauvis'},{min=1000,max=1000,from='nauvis'}}),'full'); eq(r.warnings,nil); eq(r.stops[1].requests_max,2200)
-- 7. from names the stop; a stop there with no request of the item says so; no stop there says so
r=read(ship({item_wait(2000)},{{min=2000,from='nauvis'}}),'full',nil,'gleba'); eq(r.stops[1].planet,'gleba')
has(r.warnings[1],'stop 1 (gleba): no wait on '..UM); has(r.warnings[2],'stop 1 (gleba): the hub requests no '..UM..' from there')
r=read(ship({item_wait(2000)},NAUVIS),'full',nil,'vulcanus'); eq(#r.stops,0); has(r.warnings[1],'no stop at vulcanus, nor one its requests import '..UM..' from')
-- 8. quality: a rare wait and rare requests are not the normal item's
r=read(ship({item_wait(2000,'≥','and','rare')},{{min=2000,from='nauvis',quality='rare'}}),'full',nil,nil,UM..'@rare'); eq(r.warnings,nil)
has(read(ship({item_wait(2000,'≥','and','rare')},NAUVIS),'full').warnings[1],'no wait on')
-- 9. the arguments
local p=ship({item_wait(2000)},NAUVIS)
fails(function() S.read(p,{platform='Kestrel IVb',freight={item=UM,amount=2000,mode='all'}}) end,'freight is {item, amount, mode: full or partial, from?} with platform')
fails(function() S.read(p,{freight={item=UM,amount=2000,mode='full'}}) end,'with platform')
fails(function() S.read(p,{platform='Kestrel IVb',freight={item='nothing',amount=2000,mode='full'}}) end,'freight.item is an item name')
fails(function() S.read(p,{platform='Kestrel IVb',freight={item=UM,amount=0,mode='full'}}) end,'freight.amount out of range')
fails(function() S.read(p,{platform='Nowhere',freight={item=UM,amount=2000,mode='full'}}) end,'no platform of ours named Nowhere')
print('d26 batch253 freight preflight: ok')
