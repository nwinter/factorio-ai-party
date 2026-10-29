-- Run from repository root: lua tests/d29_batch329.lua
-- d29 batch329 PR (Astra, board #2727: "Resolute21 earlyturned~29k because deep phase railNET28.63/min invalidated
-- older10min17.4 rate; manual Sol budget caught it ... Read-only partial-return budget ... per-item reachable stock with
-- exact exclusions, max recent phase/10min net deficit, speed floor, margin and reserve. Expose validated budget_below
-- wait/guard only after audited against manual calculations; do not automate lowering floors.")
-- 1. endurance.return_budget against a calculation by hand: Resolute on solar-system-edge->shattered-planet at
--    4969 km/min (4,000,000 km in 13h25m), 20,000 km flown, railgun ammunition 1741 aboard, 1500 kept, margin 10%:
--    the deep phase's 28.63/min net binds (not the 10 minutes' 17.4), and the turn falls at about 29,000 km.
-- 2. budget_below: met once the binding item's room farther out is under km; read at most every BUDGET_EVERY ticks;
--    its arguments checked when a plan is submitted.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,tol,m) assert(math.abs(a-b)<=(tol or 1),(m or 'not near')..': '..tostring(a)..' vs '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,part) local ok,err=pcall(fn); assert(not ok and tostring(err):find(part,1,true),tostring(err)) end
game={tick=0}
prototypes={item={['railgun-ammo']={type='ammo'}},space_location={['solar-system-edge']={},['shattered-planet']={},aquilo={}}}
defines={flow_precision_index={ten_minutes=1,one_minute=0}}

local E=require('endurance'){}
do
  local v=4000000/(13*60+25)  -- km a minute: 4969.0
  near(v,4969.0,0.1)
  local items={{name='railgun-ammo',stock=1741,made=0,used=28.63,made10=0,used10=17.4,from='this leg so far, 45m00s'},
    {name='rocket',stock=900,made=10,used=4,made10=10,used10=4},                       -- made faster than used: binds nothing
    {name='thruster-fuel',stock=60000,made=1500,used=8000,made10=1500,used10=8000}}    -- 6500/min net
  local out,b=E.return_budget(items,{v=v,flown_km=20000,back_km=0,out_km=9500,margin=0.1,reserve={['railgun-ammo']=1500}})
  -- by hand: usable (1741 - 1500) / 1.1 = 219.09; it lasts 219.09 / 28.63 = 7.6525 min, 38025 km at 4969 km/min;
  -- going x farther and back to the connection's start is 2x + 20000 km, so x = (38025 - 20000) / 2 = 9012 km: the turn
  -- at 29012 km of the connection, 488 km short of the planned 9500
  local r=out[1]
  eq(r.net_used,28.63); eq(r.net_phase,28.63); eq(r.net_10min,17.4); eq(r.worse,'this phase')
  near(r.lasts_min,7.7,0.05); near(r.out_km_max,9012,2,'rail out km'); near(r.spare_km,-488,2)
  near(r.left_at_return,1741-28.63*(2*9500+20000)/v,1)
  eq(out[2].not_used,true); eq(out[2].out_km_max,nil)
  -- fuel: (60000 - 0) / 1.1 / 6500 = 8.392 min -> 41700 km -> x = 10850: rail binds first
  near(out[3].out_km_max,(60000/1.1/6500*v-20000)/2,2)
  eq(b.name,'railgun-ammo'); near(b.out_km_max,9012,2)
  -- with the 10 minutes' 17.4 alone (what misled the early turn): 219.09 / 17.4 * 4969 = 62567 km -> x = 21283 km
  local out10=E.return_budget({{name='railgun-ammo',stock=1741,made=0,used=17.4,made10=0,used10=17.4}},
    {v=v,flown_km=20000,back_km=0,margin=0.1,reserve=1500})
  near(out10[1].out_km_max,21283,3,'the 10-minute rate alone')
  assert(out10[1].out_km_max>r.out_km_max*2,'the deep phase rate more than halves the room out')
  -- the phase's rate below the 10 minutes': the 10 minutes' binds (the worse of the two)
  local o2=E.return_budget({{name='railgun-ammo',stock=1741,made=0,used=10,made10=0,used10=17.4}},{v=v,flown_km=20000,back_km=0,margin=0.1,reserve=1500})
  eq(o2[1].net_used,17.4); eq(o2[1].worse,'the last 10 min')
  -- a speed floor is the planning speed (the caller passes the lower): at 3000 km/min the room shrinks
  local slow=E.return_budget({items[1]},{v=3000,flown_km=20000,back_km=0,margin=0.1,reserve={['railgun-ammo']=1500}})
  near(slow[1].out_km_max,(219.0909/28.63*3000-20000)/2,2)
  -- the way on to another stop counts: back to the edge, then 600000 km to Aquilo
  local far=E.return_budget({items[1]},{v=v,flown_km=20000,back_km=600000,margin=0.1,reserve={['railgun-ammo']=1500}})
  assert(far[1].out_km_max<0,'already short for the way home: a negative room says how far short')
  -- no margin, no reserve: all of it
  near(E.return_budget({items[1]},{v=v,flown_km=20000,back_km=0})[1].out_km_max,(1741/28.63*v-20000)/2,2)
end
print('d29_batch329 1. the return budget: the deep phase rate binds, the turn at about 29,000 km, as calculated by hand: ok')

do
  local reads=0
  local bud={binds={name='railgun-ammo',out_km_max=9012}}
  local C=require('conditions'){return_budget=function(p,name,t) reads=reads+1; eq(name,'Resolute'); eq(t.km,9500)
    return {binds=bud.binds and {name=bud.binds.name,out_km_max=bud.binds.out_km_max}} end}  -- a fresh reading each time
  local c={['until']='budget_below',platform='Resolute',turnaround={km=9500,margin=0.1},km=10000}
  C.validate(c)
  local met,saw=C.check({},c)
  eq(met,true); has(saw,'railgun-ammo binds first, at most 9012 km farther out (met under 10000 km; read at tick 0)')
  game.tick=300
  bud.binds.out_km_max=12000  -- not read again before BUDGET_EVERY: the last reading stands
  met=C.check({},c); eq(met,true); eq(reads,1)
  game.tick=600
  met,saw=C.check({},c); eq(met,false); eq(reads,2); has(saw,'at most 12000 km farther out (met under 10000 km; read at tick 600)')
  bud.binds=nil; game.tick=1200
  met,saw=C.check({},c); eq(met,false); has(saw,'no item used faster than it is made')
  fails(function() C.validate({['until']='budget_below',turnaround={km=1},km=5}) end,'budget_below requires platform')
  fails(function() C.validate({['until']='budget_below',platform='Resolute',km=5}) end,'budget_below turnaround')
  fails(function() C.validate({['until']='budget_below',platform='Resolute',turnaround={km=1}}) end,'budget_below km')
end
print('d29_batch329 2. budget_below: met under km, read at most every 600 ticks, arguments checked: ok')
