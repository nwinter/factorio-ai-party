-- d29 batch351 RA (Astra #2762): Resolute's 36th deep turn (tick 82449670) charged railgun ammunition its net 35/min over
-- the 100000 km back from solar-system-edge to Aquilo (1666.7), while its whole Aquilo return had made 2522 and used
-- 2432. A turnaround's return_allowance is the caller's own count of an item over legs back after the connection's
-- start, in place of net x time there; the harness takes it as given, labels it, and keeps the read without it beside.
-- Run from the harness root: lua tests/d29_batch351.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,tol,m) assert(math.abs(a-b)<=(tol or 1),(m or 'not near')..': '..tostring(a)..' vs '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,part) local ok,err=pcall(fn); assert(not ok and tostring(err):find(part,1,true),tostring(err)) end
game={tick=82500000}
prototypes={item={['railgun-ammo']={type='ammo'},rocket={type='ammo'}},space_location={['solar-system-edge']={},['shattered-planet']={},aquilo={}}}
defines={flow_precision_index={ten_minutes=4,five_minutes=3,one_minute=2}}
local E=require('endurance'){}
local v=35*60  -- km a minute at the 35 km/s floor

-- 1. Astra's numbers: rail 3127 aboard, 1500 kept, margin 20%, net 35/min; 10000 km out, 11646 flown, 100000 km on to Aquilo
local items={{name='railgun-ammo',stock=3127,made=0,used=35,made10=0,used10=35},{name='rocket',stock=2813,made=0,used=0.5,made10=0,used10=0.5}}
local o={v=v,flown_km=11646,back_km=100000,out_km=10000,margin=0.2,reserve={['railgun-ammo']=1500,rocket=2000}}
local usable=(3127-1500)/1.2
do
  local out,b,b0=E.return_budget(items,o)
  local r=out[1]
  near(r.out_km_max,(usable/35*v-11646-100000)/2,1,'unadjusted, as the read gave'); eq(r.allowance,nil); eq(r.unadjusted,nil); eq(r.costs,nil); eq(b0,nil)
  eq(b.name,'railgun-ammo')
  -- with the caller's 0 over the Aquilo leg: that leg's 1666.7 at the net rate is replaced; the turn keeps the net rate
  local oa={}; for k,x in pairs(o) do oa[k]=x end
  oa.allowance={items={['railgun-ammo']=0},km=100000}
  out,b,b0=E.return_budget(items,oa)
  r=out[1]
  near(r.out_km_max,(usable/35*v-11646)/2,1); eq(r.allowance,0); eq(r.allowance_replaces,1667)
  near(r.unadjusted.out_km_max,(usable/35*v-11646-100000)/2,1)
  eq(r.costs.turn,math.floor(35*(2*10000+11646)/v+0.5)); eq(r.costs.legs_at_net,0); eq(r.costs.allowance,0)
  near(r.left_at_return,3127-35*(2*10000+11646)/v,1)
  eq(b.name,'railgun-ammo'); near(b.out_km_max,r.out_km_max,1,'binds at the adjusted figure'); eq(b0.name,'railgun-ammo'); near(b0.out_km_max,r.unadjusted.out_km_max,1)
  assert(b.spare_km>0 and b0.spare_km<0,'the planned 10000 km fits with the allowance, not without')
  eq(out[2].allowance,nil,'an item the caller did not name keeps the net rate everywhere')
  -- with 300: the 300 comes off what is usable
  oa.allowance={items={['railgun-ammo']=300},km=100000}
  out=E.return_budget(items,oa)
  near(out[1].out_km_max,((usable-300)/35*v-11646)/2,1); near(out[1].left_at_return,3127-35*(2*10000+11646)/v-300,1)
  -- an item made faster than used, with an allowance over its usable stock: said
  local o2=E.return_budget({{name='rocket',stock=100,made=5,used=1,made10=5,used10=1}},{v=v,flown_km=0,back_km=1000,out_km=0,margin=0,allowance={items={rocket=500},km=1000}})
  eq(o2[1].not_used,true); eq(o2[1].allowance,500); eq(o2[1].allowance_over_usable,true)
  print('d29_batch351 1. Astra\'s rail: the Aquilo leg\'s 1667 at the net rate replaced by the caller\'s count, the turn kept at the net rate, unadjusted beside: ok')
end

-- 2. the named legs: each exactly one of the legs back after the connection's start; else refused, naming them
do
  local turn={from='solar-system-edge',to='shattered-planet'}
  local legs={{from='solar-system-edge',to='shattered-planet',km=10000,turn='out'},{from='the turn',to='solar-system-edge',km=21646,turn='back'},
    {from='solar-system-edge',to='aquilo',km=100000,turn='on'}}
  local ra={legs={'solar-system-edge->aquilo'},items={['railgun-ammo']=0},label='FULL36 AQ return: made 2522 used 2432',evidence_ticks={82300000,82340000}}
  E.check_allowance(ra)
  local m=E.match_allowance(turn,legs,ra)
  eq(m.km,100000); eq(m.legs[1],'solar-system-edge->aquilo'); eq(m.label,'FULL36 AQ return: made 2522 used 2432')
  ra.legs='solar-system-edge->aquilo'; eq(E.match_allowance(turn,legs,ra).km,100000,'one leg as a string')
  fails(function() E.match_allowance(turn,legs,{legs={'the turn->solar-system-edge'},items={rocket=1},label='x'}) end,
    'is not one of the legs back after the connection\'s start; the legs back after solar-system-edge: solar-system-edge->aquilo')
  -- a route back through the same leg twice: ambiguous
  local twice={legs[1],legs[2],{from='solar-system-edge',to='aquilo',km=100000,turn='on'},{from='aquilo',to='solar-system-edge',km=100000,turn='on'},{from='solar-system-edge',to='aquilo',km=100000,turn='on'}}
  fails(function() E.match_allowance(turn,twice,{legs={'solar-system-edge->aquilo'},items={rocket=1},label='x'}) end,'names more than one leg (ambiguous)')
  -- back_to the connection's start: no leg after it
  fails(function() E.match_allowance(turn,{legs[1],legs[2]},{legs={'solar-system-edge->aquilo'},items={rocket=1},label='x'}) end,'no leg back after solar-system-edge')
  -- refusals of the argument itself
  fails(function() E.check_allowance({legs={'a->b'},items={['railgun-ammo']=-1},label='x'}) end,'is a count, 0 or more (no production is credited)')
  fails(function() E.check_allowance({legs={'a->b'},items={['railgun-ammo']=1}}) end,'label is the source of the counts')
  fails(function() E.check_allowance({legs={'a b'},items={rocket=1},label='x'}) end,'each is "from->to"')
  fails(function() E.check_allowance({legs={'a->b','a->b'},items={rocket=1},label='x'}) end,'named twice')
  fails(function() E.check_allowance({legs={'a->b'},items={nope=1},label='x'}) end,'unknown item or fluid nope')
  fails(function() E.check_allowance({legs={'a->b'},items={rocket=1},label='x',evidence_ticks={99999999999}}) end,'game ticks up to now')
  fails(function() E.check_allowance({legs={'a->b'},items={rocket=1},label='x',scale=2}) end,'takes legs, items, label and evidence_ticks')
  fails(function() E.check_allowance(5) end,'turnaround.return_allowance is {legs, items')
  print('d29_batch351 2. the named legs: one each, refused when absent, ambiguous or none back after the start; the argument\'s refusals: ok')
end

-- 3. budget_below with and without the allowance: the turnaround (and its allowance) goes to the read as given; it binds on what the read says
do
  local seen
  local C=require('conditions'){return_budget=function(p,name,t)
    seen=t
    if t.return_allowance then return {binds={name='rocket',out_km_max=1356927}} end
    return {binds={name='railgun-ammo',out_km_max=-15148}}
  end}
  local plain={['until']='budget_below',platform='Resolute',turnaround={km=10000,back_to='aquilo'},km=1000}
  C.validate(plain)
  local met,saw=C.check({},plain)
  eq(met,true); has(saw,'railgun-ammo binds first'); eq(seen.return_allowance,nil)
  local with={['until']='budget_below',platform='Resolute',km=1000,
    turnaround={km=10000,back_to='aquilo',return_allowance={legs={'solar-system-edge->aquilo'},items={['railgun-ammo']=0},label='FULL36'}}}
  C.validate(with)
  met,saw=C.check({},with)
  eq(met,false); has(saw,'rocket binds first'); eq(seen.return_allowance.label,'FULL36')
  print('d29_batch351 3. budget_below with and without the allowance: the read decides, as given: ok')
end
