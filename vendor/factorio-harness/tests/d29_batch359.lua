-- All-shot statistics must outlive the bounded recent window. Run from the harness root, no live game needed.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function sum(t) local n=0 for _,v in pairs(t) do n=n+v end return n end
defines={inventory={turret_ammo=1}}
local T0=10000
local function fixture(seconds,nominal)
  game={tick=T0}
  local state={}
  local inv={valid=true,count=10}; function inv.get_item_count() return inv.count end
  local target={valid=true,unit_number=2,name='big-metallic-asteroid',position={x=0,y=-30}}
  local turret={valid=true,unit_number=1,type='ammo-turret',name='railgun-turret',position={x=0,y=0},
    quality={name='normal'},prototype={attack_parameters={cooldown=nominal or 170}},electric_buffer_size=10000000,
    energy=10000000,shooting_target=target}
  function turret.get_inventory() return inv end
  local surface={index=3,platform={name='Test'}}
  function surface.find_entities_filtered() return {turret} end
  local w=dofile('mod/agent-harness_0.1.0/railaim.lua'){state=function() return state end,
    on_platform=function() return {surface=surface} end}
  local p={index=1,force='player'}
  w.handler(p,{platform='Test',aim=true,seconds=seconds})
  w.tick(game.tick) -- an RCON watch start on a paused tick is not sampled twice when the copy resumes
  eq(state.rail_aim[1].samples,1)
  return w,state.rail_aim[1],turret,target,inv,p
end
local function histogram_sum(s)
  local h=s.intervals.histogram
  local n=sum(h.ticks)
  for _,b in ipairs(h.wider) do n=n+b.count end
  return n
end
local function run(shots)
  local w,j,e,target,inv,p=fixture(120)
  local plan={} for _,tick in ipairs(shots) do plan[tick]=true end
  -- Exactly 7200 samples, including the start. Refill in the same tick as each shot hides its item count;
  -- the buffer drop still detects it. A surviving target permits exact attribution on every shot.
  for offset=0,7198 do
    if plan[offset] then
      e.energy=0
      w.on_damaged{cause=e,entity=target,final_health=100}
    else e.energy=e.electric_buffer_size end
    game.tick=T0+offset+1; w.tick(game.tick)
  end
  local r=w.handler(p,{aim=true}); local a=r.railguns[1]; local s=a.statistics
  eq(r.done,true); eq(r.samples,7200); eq(a.shots,#shots); eq(s.shots,#shots)
  eq(s.intervals.count,#shots-1); eq(histogram_sum(s),#shots-1)
  eq(sum(s.shots_by_second),#shots); eq(#s.shots_by_second,120)
  eq(sum(s.shots_by_target_size),#shots); eq(s.shots_by_target_size.big,#shots)
  eq(#a.recent,24); eq(a.recent_more,#shots-24); eq(s.prior_shots,0)
  eq(s.samples.count,7200); eq(s.samples.target_present_ticks,7200)
  eq(s.samples.energy_ready_ticks,7200-#shots); eq(s.samples.ammo_present_share,1)
  eq(s.samples.energy_ready_share,(7200-#shots)/7200)
  eq(s.nominal_cooldown.ticks,170); eq(s.nominal_cooldown.source,'LuaEntityPrototype.attack_parameters.cooldown')
  return s,a
end

local saturated={}
for tick=1,7198,171 do saturated[#saturated+1]=tick end
local s=run(saturated)
eq(#saturated,43); eq(s.intervals.min_ticks,171); eq(s.intervals.max_ticks,171)
eq(s.intervals.mean_ticks,171); eq(s.intervals.sum_ticks,42*171)
eq(s.intervals.histogram.exact_through_ticks,171); eq(s.intervals.histogram.ticks['171'],42)

-- The extrema are deliberately outside recent's final 24 records; only an all-shot accumulator can retain them.
local varied={1,36,936}
for tick=1107,7198,171 do varied[#varied+1]=tick end
local a
s,a=run(varied)
eq(s.intervals.min_ticks,35); eq(s.intervals.max_ticks,900)
eq(s.intervals.sum_ticks,varied[#varied]-varied[1])
eq(s.intervals.mean_ticks,(varied[#varied]-varied[1])/(#varied-1))
eq(a.recent[1].tick>T0+936,true); eq(s.intervals.histogram.wider[3].count,1)

-- Bucket boundaries and multiple items lost in one read (ambiguous, assigned the same detected tick).
local w,j,e,target,inv,p=fixture(120)
local at=T0+1
for _,dt in ipairs{0,1,170,171,172,342,343,684,685} do
  at=at+dt; w.shot(j,j.rails[1],at,1)
end
w.shot(j,j.rails[1],at+1,3)
s=w.result(j).railguns[1].statistics
eq(s.intervals.count,11); eq(histogram_sum(s),11); eq(s.multi_shot_observations,1)
eq(s.intervals.histogram.ticks['0'],2); eq(s.intervals.histogram.ticks['1'],2)
eq(s.intervals.histogram.wider[1].count,2); eq(s.intervals.histogram.wider[2].count,2)
eq(s.intervals.histogram.wider[3].count,1)
eq(sum(s.shots_by_second),12); eq(sum(s.shots_by_target_size),12)

-- Independent sample denominators, no intervals for zero/one shot, gone turrets stop sampling.
w,j,e,target,inv,p=fixture(10)
s=w.result(j).railguns[1].statistics
eq(s.intervals.count,0); eq(s.intervals.min_ticks,nil); eq(s.intervals.mean_ticks,nil)
e.shooting_target=nil; e.energy=5000000; inv.count=0
game.tick=T0+1; w.tick(game.tick)
-- The removed inventory is detected as an ambiguous multi-item observation, never hidden in recent alone.
s=w.result(j).railguns[1].statistics
eq(s.shots,10); eq(s.multi_shot_observations,1); eq(s.intervals.count,9)
eq(s.samples.count,2); eq(s.samples.target_present_share,0.5); eq(s.samples.energy_ready_share,0.5)
eq(s.samples.ammo_present_share,0.5)
e.valid=false; game.tick=T0+2; w.tick(game.tick)
eq(w.result(j).railguns[1].statistics.samples.count,2)

-- A watch saved by the old runtime gains counters only from the first new read, with explicit prior-shot coverage.
w,j,e,target,inv,p=fixture(10)
local row=j.rails[1]; row.stats=nil; row.shots=40
game.tick=T0+60; w.tick(game.tick)
e.energy=0; e.shooting_target=nil; game.tick=T0+61; w.tick(game.tick)
s=w.result(j).railguns[1].statistics
eq(s.prior_shots,40); eq(s.since_tick,T0+60); eq(s.shots,1); eq(s.intervals.count,0)
e.energy=10000000; game.tick=T0+62; w.tick(game.tick)
e.energy=0; game.tick=T0+63; w.tick(game.tick)
s=w.result(j).railguns[1].statistics
eq(s.shots_by_target_size.unknown,1); eq(s.intervals.mean_ticks,2)
eq(histogram_sum(s),1)
print('d29 batch359: ok (120 s saturated, >24 shots, all-shot extrema/mean, bounded histogram, seconds/size, samples, migration)')
