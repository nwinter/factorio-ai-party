-- Run from repository root: lua tests/d29_batch332.lua
-- d29 batch332 RT (Sol #2734: "Native hit_by classes cannot identify which asteroid a round was aimed at ... Need safe
-- evidence before changing targets"). platform_defense {platform, aim: true, seconds}: per railgun, each shot's aimed
-- target (the one it read the tick before the shot) as exact when that shot hit it, the shot's other hits as collateral.
-- The stand-in follows the game's order: the harness reads on each tick, then the world updates (a railgun fires, its
-- line damages what is on it, on_entity_damaged with the railgun as cause), and the next tick's read sees the shot.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={inventory={turret_ammo=1}}
local T0=500000
game={tick=T0}
local rails={}
local surface={valid=true,index=22,name='platform-22'}
surface.platform={name='Resolute',surface=surface}
local function rail(i,x)
  local inv={count=10}
  inv.valid=true
  function inv.get_item_count() return inv.count end
  local e={valid=true,name='railgun-turret',type='ammo-turret',unit_number=100+i,position={x=x,y=-67.5},quality={name=i==1 and 'rare' or 'normal'},
    electric_buffer_size=10000000,energy=10000000,force='player',inv=inv}
  function e.get_inventory(id) eq(id,1); return inv end
  return e
end
for i=1,9 do rails[i]=rail(i,-16.5+3*(i-1)) end
local finds=0
function surface.find_entities_filtered(f)
  finds=finds+1
  eq(f.name,'railgun-turret','railguns found by name')
  local out={}
  for i=#rails,1,-1 do  -- out of order: the watch sorts them
    local e=rails[i]
    if e.valid and (not f.position or ((e.position.x-f.position[1])^2+(e.position.y-f.position[2])^2)<=f.radius^2) then out[#out+1]=e end
  end
  return out
end
local function asteroid(un,name) return {valid=true,unit_number=un,name=name,position={x=un,y=-110}} end
local S={}
local W=dofile('mod/agent-harness_0.1.0/railaim.lua'){state=function() return S end,reason=function(v) assert(#v<=200,'reason: up to 200') return v end,
  on_platform=function(p,name) eq(name,'Resolute'); return {surface=surface} end}
local p={index=7,force='player'}
local A,B=rails[1],rails[2]
-- a shot in the world update of tick t: one item and the buffer gone; each hit an on_entity_damaged with the railgun as cause
local function fire(r,hits,refill)
  if not refill then r.inv.count=r.inv.count-1 end
  r.energy=0
  r.shooting_target=nil
  for _,h in ipairs(hits) do
    W.on_damaged({entity=h.e,cause=r,final_health=h.hp})
    if h.hp<=0 then h.e.valid=false end
  end
end
local plan={}
-- the buffers recharge 1 MJ a tick after a shot (a railgun fires from a full 10 MJ buffer)
local function recharge(r) r.energy=math.min(10000000,r.energy+1000000) end
local function run(to) while game.tick<to do game.tick=game.tick+1; W.tick(game.tick); recharge(A); recharge(B); local f=plan[game.tick-T0]; if f then f() end end end

-- bounds and refusals
fails(function() W.handler(p,{platform='Resolute',aim=true,seconds=9}) end,'seconds: 10..120 with aim')
fails(function() W.handler(p,{platform='Resolute',aim=true,seconds=121}) end,'seconds: 10..120 with aim')
fails(function() W.handler(p,{platform='Resolute',aim=true,seconds=30.5}) end,'seconds: 10..120 with aim')
fails(function() W.handler(p,{aim=true}) end,'no railgun aim watch of yours yet')
fails(function() W.handler(p,{aim=true,seconds=30}) end,'platform_defense {platform, aim: true, seconds} starts the watch')
local nine={}
for i=1,9 do nine[i]={x=rails[i].position.x,y=-67.5} end
fails(function() W.handler(p,{platform='Resolute',aim=true,seconds=30,positions=nine}) end,'positions: 1..8')
fails(function() W.handler(p,{platform='Resolute',aim=true,seconds=30,positions={{x=40,y=0}}}) end,'positions[1] (40,0): no railgun turret within 2 tiles on Resolute')
fails(function() W.handler(p,{platform='Resolute',aim=true,seconds=30,reason=string.rep('x',201)}) end,'reason: up to 200')

-- no positions: the first 8 of 9 by position
local r=W.handler(p,{platform='Resolute',aim=true,seconds=10})
eq(r.railguns,8); eq(r.picked,'the first 8 of 9 railguns by position (north first): positions picks others')
has(r.line,'railgun aim watch on Resolute: 8 railguns (-16.5,-67.5) (-13.5,-67.5)')
eq(S.rail_aim[7].rails[1].e,A,'sorted by position'); eq(S.rail_aim[7].rails[1].quality,'rare')

-- positions: A and B only, 10 s
finds=0
r=W.handler(p,{platform='Resolute',aim=true,seconds=10,positions={{x=-16,y=-67},{x=-13.5,y=-67.5}},reason='Sol #2734'})
eq(r.railguns,2); eq(r.picked,'by positions'); eq(r.replaced,true); eq(finds,2,'one small find a position')
has(r.line,'your earlier aim watch is replaced')

local M1,S1,B1=asteroid(1,'medium-oxide-asteroid'),asteroid(2,'small-oxide-asteroid'),asteroid(3,'big-metallic-asteroid')
local X,Y=asteroid(4,'medium-carbonic-asteroid'),asteroid(5,'big-carbonic-asteroid')
local H1=asteroid(6,'huge-metallic-asteroid')
-- k=5..9: A aims at M1; tick 10's update fires: M1 and S1 killed, B1 hit and left at 100
plan[4]=function() A.shooting_target=M1 end
plan[10]=function() fire(A,{{e=M1,hp=0},{e=S1,hp=0},{e=B1,hp=100}}) end
-- k=20..28: A aims at X; tick 29's update retargets to Y and fires: Y hit, X alive and not hit
plan[19]=function() A.shooting_target=X end
plan[29]=function() A.shooting_target=Y; fire(A,{{e=Y,hp=0}}) end
-- B fires at tick 40 with no target read the tick before (it acquired and fired within the update)
plan[40]=function() fire(B,{{e=H1,hp=500}}) end
-- B fires at tick 50 while an inserter refills it: the item count unchanged, the buffer gone
plan[49]=function() B.shooting_target=H1 end
plan[50]=function() fire(B,{{e=H1,hp=0}},true) end
-- tick 60: a hit by A with no shot of A's seen (unattributed); a gun turret's hit and one with no cause ignored
plan[60]=function()
  W.on_damaged({entity=X,cause=A,final_health=10})
  W.on_damaged({entity=X,cause={valid=true,type='ammo-turret',unit_number=999},final_health=5})
  W.on_damaged({entity=X,cause=nil,final_health=5})
end
run(T0+300)
local job=S.rail_aim[7]
eq(job.live,true,'running at 300 ticks')
local mid=W.handler(p,{aim=true})
eq(mid.done,false)
run(T0+600)
r=W.handler(p,{aim=true})
eq(r.done,true); eq(r.samples,600); eq(r.every_ticks,1); eq(r.reason,'Sol #2734')
local a,b=r.railguns[1],r.railguns[2]
eq(a.shots,2); eq(a.ammo_used,2); eq(a.exact,1); eq(a.uncertain,1); eq(a.no_target,0)
eq(a.aimed_by_size.medium,1); eq(a.aimed_killed,1); eq(a.aimed_survived,0); eq(a.aimed_not_hit_alive,1)
eq(a.collateral_by_size.small,1); eq(a.collateral_by_size.big,2,'B1 at the first shot, Y at the retarget'); eq(a.collateral_killed,2)
eq(a.hits,4); eq(a.unattributed,1)
eq(a.recent[1].attribution,'exact'); eq(a.recent[1].aimed,'medium-oxide-asteroid'); eq(a.recent[1].tick,T0+10); eq(a.recent[1].aimed_killed,true)
eq(#a.recent[1].collateral,2); eq(a.recent[1].position.x,1)
eq(a.recent[2].attribution,'uncertain: the target read the tick before was not hit and is alive'); eq(a.recent[2].aimed,'medium-carbonic-asteroid')
eq(b.shots,2); eq(b.ammo_used,2,'the refill hid the item: the buffer counts it'); eq(b.no_target,1); eq(b.exact,1); eq(b.uncertain,1)
eq(b.aimed_by_size.huge,1); eq(b.collateral_by_size.huge,1,'the shot with no target read: its hit is collateral')
eq(b.recent[1].attribution,'uncertain: no target read the tick before')
eq(r.totals.shots,4); eq(r.totals.exact,2); eq(r.totals.uncertain,2); eq(r.totals.hits,6); eq(r.totals.unattributed,1)
has(r.lines[1],'Resolute: 2 railguns, ticks '..(T0)..'..'..(T0+599)..' (done): 4 shots, 4 ammo used; aimed (exact) medium 1, huge 1; uncertain 2; collateral small 1, big 2, huge 1; hits 6 (1 unattributed)')
has(r.lines[2],'railgun (-16.5,-67.5) (rare): 2 shots (2 ammo); aimed, exact 1: medium 1 (killed 1, survived 0); uncertain 1; collateral hits: small 1, big 2 (killed 2); 1 hits on no seen shot')
has(r.attribution,'exact when the target the railgun read the tick before the shot is among that shot\'s hits')
has(r.not_given,'the game\'s reason for a target choice')
-- ended: no more reads; a hit after the end is not gathered
local before=r.samples
W.on_damaged({entity=X,cause=A,final_health=1})
run(T0+700)
eq(W.handler(p,{aim=true}).samples,before,'no reads after the end')
-- a railgun removed while watched: its gone tick
r=W.handler(p,{platform='Resolute',aim=true,seconds=10,positions={{x=-13.5,y=-67.5}}})
run(T0+710); B.valid=false; run(T0+720)
r=W.handler(p,{aim=true}); eq(r.railguns[1].gone_tick,T0+711); has(r.lines[2],'; gone at tick '..(T0+711))
-- sizes
eq(W.size('small-promethium-asteroid'),'small'); eq(W.size('huge-oxide-asteroid'),'huge'); eq(W.size('metallic-asteroid-chunk'),'other')
-- kept a while after the end, then freed
run(T0+1300+W.KEEP_TICKS+2); eq(S.rail_aim[7],nil,'freed after KEEP_TICKS')
-- the description names it (platform_defense's arguments)
has(W.ARGS.aim,'a railgun aim watch'); has(W.ARGS.aim,'exact when that shot hit it, else uncertain')
print('d29 batch332: ok')
