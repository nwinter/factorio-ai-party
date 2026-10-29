-- Run from repository root: lua tests/d29_batch339.lua
-- d29 batch339 RB (Sol, board #2745: "Resolute native81387340 at13sAQ->edge: return_budget fuel stock1977/oxid1682 vs
-- fuel_outlook8703aboard; reserve12k yieldsnegativeoutmax andbinds although fuelstockscope differs ... Clean179s leg
-- native81397275: held853fuel/558oxid vs fuel_outlook7208aboard; fuel7190use/6000made within1500batch no deficit, oxid
-- 7500made. Last10min includes startup1653net. Also 12k reserve exceeds actual working aboard 7208").
-- 1. return_budget rows say their stock scope and usable basis; fuel at fuel_outlook's aboard (8703, not 1977 held);
--    a reserve over the stock said; a fuel deficit within a batch a maker binds nothing (Sol's 7190 used / 6000 made,
--    batches of 1500).
-- 2. turnaround items: the ammunition and repair packs only: fuel listed, not binding; the ammunition binds.
-- 3. the second rate's window leaves out the leg's startup (its first 60 s and the stop before): 10 min only when
--    wholly after it, else 5 or 1 min, else none.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,tol,m) assert(math.abs(a-b)<=(tol or 1),(m or 'not near')..': '..tostring(a)..' vs '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
game={tick=0}
prototypes={item={['railgun-ammo']={type='ammo'},['repair-pack']={type='repair-tool'}},space_location={},fluid={['thruster-fuel']={},['thruster-oxidizer']={}}}
defines={flow_precision_index={ten_minutes=4,five_minutes=3,one_minute=2}}
local E=require('endurance'){}
local v=4969.0
local FUEL_SCOPE='aboard: thrusters, tanks, pipes, pumps and the makers\' outputs (fuel_outlook; held in thrusters and tanks 1977)'

do
  -- 1. Sol's first read (tick 81387340, 13 s into Aquilo->edge): fuel 8703 aboard (1977 held), oxidizer, ammunition
  local items={
    {name='thruster-fuel',stock=8703,made=6000,used=7190,made10=6000,used10=7190,scope=FUEL_SCOPE,window='its last 60 s'},
    {name='thruster-oxidizer',stock=7208,made=7500,used=7190,made10=7500,used10=7190,scope='aboard',window='its last 60 s'},
    {name='railgun-ammo',stock=3050,made=0,used=2.2,made10=0,used10=1.5,scope='reaches the turrets',window='the last 10 min'},
    {name='repair-pack',stock=85,made=0,used=0,made10=0,used10=0,scope='aboard'}}
  local out,b=E.return_budget(items,{v=v,flown_km=1000,back_km=0,margin=0.1,reserve={['thruster-fuel']=12000,['railgun-ammo']=1500}})
  local f=out[1]
  eq(f.stock,8703,'fuel at what is aboard, not the 1977 held'); eq(f.stock_scope,FUEL_SCOPE)
  eq(f.reserve_over_stock,true,'the 12000 kept is more than the 8703 aboard: said')
  eq(f.usable_basis,'(8703 aboard - 12000 kept) / (1 + 0.1 margin)'); near(f.usable,(8703-12000)/1.1,1)
  assert(f.out_km_max<0,'a negative room, as Sol saw, but now on the stock aboard')
  eq(b.name,'thruster-fuel','with every item selectable, fuel binds')
  eq(out[2].not_used,true,'oxidizer made 7500 over 7190 used: binds nothing')
  eq(out[3].usable_basis,'(3050 aboard - 1500 kept) / (1 + 0.1 margin)')
  -- the clean 179 s leg (tick 81397275): fuel used 7190, made 6000, batches of 1500: within a batch, no deficit
  local o2=E.return_budget({{name='thruster-fuel',stock=7208,made=6000,used=7190,made10=6000,used10=7190,within_step=true,scope=FUEL_SCOPE}},
    {v=v,flown_km=1000,back_km=0,margin=0.1})
  eq(o2[1].within_step,true); eq(o2[1].net_used,0); eq(o2[1].out_km_max,nil); eq(o2[1].not_used,true)
  print('d29_batch339 1. fuel counted aboard (8703, not 1977 held), its scope and usable basis said, a reserve over it said, within a batch no deficit: ok')

  -- 2. items: the ammunition and repair packs: fuel listed, not binding; the ammunition binds
  local sel={['railgun-ammo']=true,['repair-pack']=true}
  local out3,b3=E.return_budget(items,{v=v,flown_km=1000,back_km=0,margin=0.1,reserve={['thruster-fuel']=12000,['railgun-ammo']=1500},selected=sel})
  eq(b3.name,'railgun-ammo'); eq(out3[1].not_selected,true); assert(out3[1].out_km_max<0,'still listed with its numbers')
  near(b3.out_km_max,((3050-1500)/1.1/2.2*v-1000)/2,2)
  -- budget_below with items binds on the ammunition only (the turnaround passes items to the read)
  local C=require('conditions'){return_budget=function(p,name,t)
    eq(t.items[1],'railgun-ammo'); return {binds={name=b3.name,out_km_max=b3.out_km_max}} end}
  local c={['until']='budget_below',platform='Resolute',turnaround={km=1000,items={'railgun-ammo','repair-pack'}},km=5000000}
  C.validate(c)
  local met,saw=C.check({},c)
  eq(met,true); has(saw,'railgun-ammo binds first')
  print('d29_batch339 2. items (ammunition and repair packs): fuel listed and not binding, the ammunition binds; budget_below follows it: ok')
end

do
  -- 3. the second rate's window: the leg's startup (60 s) left out
  local P=defines.flow_precision_index
  local function w(m) local pi,mn,t=E.budget_window(m,P); return pi,mn,t end
  local pi,mn,t=w(nil); eq(pi,P.ten_minutes); eq(mn,10); eq(t,'the last 10 min')
  pi,mn=w(11.0); eq(pi,P.ten_minutes,'11 min into the leg: the 10 lie after its first minute')
  pi,mn,t=w(10.5); eq(pi,P.five_minutes); eq(mn,5); has(t,'the 10 would hold the leg\'s startup')
  pi,mn=w(3.0); eq(pi,P.one_minute); eq(mn,1)
  pi,mn,t=w(13/60); eq(pi,nil,'13 s into the leg (Sol\'s first read): no window after the startup yet'); has(t,'no window after the leg\'s startup yet')
  pi=w(179/60); eq(pi,P.one_minute,'the clean 179 s leg: its last minute, not the 10 with the startup\'s 1653 net')
  print('d29_batch339 3. the second rate leaves out the leg\'s startup: 10 min only wholly after its first 60 s, else 5 or 1, else none: ok')
end
