-- Run from repository root: lua tests/d22_batch92.lua
-- d22 batch92 BB1 (Sol #1884: platform_loss guards react only once something is destroyed; medium asteroid impacts can
-- cascade before the next flight_watch read; damaged reads no platform): platform_hit, a wait_until condition and queue
-- guard met on the first hit (or at_least hits, on entity_names) on our entities on a platform since the wait or guard
-- began; one ring row a hit (platalerts.lua). BB2 (Astra #1886): the same with damage summed (platform_damage), a fired
-- guard keeping its first hits, and platform_energy_below over a platform's accumulators. BB3 (Astra #1887):
-- platform_progress, the share of its leg a platform has flown, on the leg asked only.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
do
  prototypes={entity={['solar-panel']={},thruster={},['gun-turret']={}},item={},quality={normal={}}}
  local st={}
  game={tick=1000}
  local deck={name='platform-7'}
  local edge={valid=true,name='Edge5',index=7,surface=deck}
  deck.platform=edge
  local other={valid=true,name='Wren',index=8,surface={name='platform-8'}}
  other.surface.platform=other
  local force={name='player',platforms={edge,other}}
  local enemy={name='enemy'}
  local sol={position={x=0,y=0},surface={name='nauvis'},force=force}
  local A=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
    platform_hits=function(pl) return A.hit_ring(pl),A.HIT_RING end}
  local function hit(name,x,y,d,cause,surf)
    local e={valid=true,name=name,type='solar-panel',force=force,surface=surf or deck,position={x=x,y=y}}
    local ev={entity=e,force=enemy,final_damage_amount=d,tick=game.tick}
    if cause then ev.cause={valid=true,name=cause} else ev.damage_type={name='impact'} end
    return A.on_damaged(ev)
  end
  -- a hit before the guard began does not count
  eq(hit('solar-panel',3,3,40,'small-metallic-asteroid'),true)
  game.tick=1200
  local guard={['until']='platform_hit',platform='Edge5'}
  C.validate(guard)
  local met,saw=C.check(sol,guard)
  eq(met,false); eq(saw,'platform Edge5: no hit on ours since tick 1200'); eq(guard.hit_since,1200,'kept on the condition')
  -- our own force's damage and another platform's hits do not count
  game.tick=1300
  A.on_damaged({entity={valid=true,name='thruster',force=force,surface=deck,position={x=0,y=9}},force=force,final_damage_amount=5,tick=1300})
  hit('solar-panel',1,1,10,'medium-carbonic-asteroid',other.surface)
  eq((C.check(sol,guard)),false)
  -- the first hit: met, naming it
  game.tick=1400
  hit('thruster',-4.5,10.5,123.25,'medium-carbonic-asteroid')
  game.tick=1460
  met,saw=C.check(sol,guard)
  eq(met,true); eq(saw,'platform Edge5: 1 hit, 123.3 damage, on ours since tick 1200, first: thruster (-4.5,10.5) 123.3 damage by medium-carbonic-asteroid 1s ago')
  -- at_least, entity_names, since_tick before the hits (read back through the ring), a hit with no cause
  hit('gun-turret',6,-12,8,nil)
  local two={['until']='platform_hit',platform='Edge5',at_least=3,since_tick=999}
  C.validate(two)
  met,saw=C.check(sol,two)
  eq(met,true); eq(saw,'platform Edge5: 3 hits, 171.3 damage, on ours since tick 999, first: solar-panel (3,3) 40 damage by small-metallic-asteroid 7s ago, thruster (-4.5,10.5) 123.3 damage by medium-carbonic-asteroid 1s ago, gun-turret (6,-12) 8 damage (impact, no cause) 0s ago')
  local four={['until']='platform_hit',platform='Edge5',at_least=4,since_tick=999}
  met,saw=C.check(sol,four)
  eq(met,false); assert(saw:find('3 hits, 171.3 damage, on ours since tick 999 (met at 4 hits)',1,true),saw)
  -- BB2 (Astra #1886): damage summed since the baseline, whichever of at_least and damage is reached first; platform_damage
  -- is its other name
  local dmg={['until']='platform_damage',platform='Edge5',damage=150,since_tick=1200}
  C.validate(dmg); eq(dmg['until'],'platform_hit')
  met,saw=C.check(sol,dmg)
  eq(met,false); assert(saw:find('2 hits, 131.3 damage, on ours since tick 1200 (met at 150 damage)',1,true),saw)
  met=C.check(sol,{['until']='platform_hit',platform='Edge5',damage=150,since_tick=999}); eq(met,true,'171.3 since 999')
  met=C.check(sol,{['until']='platform_hit',platform='Edge5',damage=500,at_least=2,since_tick=1200}); eq(met,true,'2 hits first')
  fails(function() C.validate({['until']='platform_hit',platform='Edge5',damage=0}) end,'damage must be a number in 0.1..')
  local named={['until']='platform_hit',platform='Edge5',entity_names={'gun-turret'},since_tick=1200}
  C.validate(named)
  met,saw=C.check(sol,named)
  eq(met,true); eq(saw,'platform Edge5: 1 hit, 8 damage, on ours of those names since tick 1200, first: gun-turret (6,-12) 8 damage (impact, no cause) 0s ago')
  -- a wait step keeps its start on its record, and reads only the hits since its last check
  local rec={}
  local w={['until']='platform_hit',platform='Edge5',entity_names={'thruster'}}
  eq((C.check(sol,w,nil,rec)),false); eq(rec.hit_since,1460); eq(w.hit_since,nil)
  -- more hits between two checks than the ring holds: all counted; by name, the overwritten ones said
  game.tick=1500
  for i=1,A.HIT_RING+6 do hit(i==1 and 'thruster' or 'solar-panel',i,0,1,'small-carbonic-asteroid') end
  met,saw=C.check(sol,w,nil,rec)
  eq(met,false); eq(saw,'platform Edge5: no hit on ours of those names since tick 1460 (6 more hits came between two checks, not read by name)')
  met,saw=C.check(sol,guard)
  eq(met,true); assert(saw:find('platform Edge5: 72 hits, 201.3 damage, on ours since tick 1200, first: thruster (-4.5,10.5)',1,true) and saw:find(', +68 more',1,true),saw)
  -- the ring: one row a hit, the last HIT_RING kept
  local r=A.hit_ring(edge)
  eq(r.seq,73); eq(r.ring[(73-1)%A.HIT_RING+1].s,73); eq(r.ring[(73-1)%A.HIT_RING+1].n,'solar-panel')
  local n=0; for _ in pairs(r.ring) do n=n+1 end; eq(n,A.HIT_RING)
  -- a platform never hit; refusals
  eq((C.check(sol,{['until']='platform_hit',platform='Wren',entity_names={'thruster'}})),false)
  fails(function() C.check(sol,{['until']='platform_hit',platform='Nope'}) end,'no platform of ours named Nope')
  fails(function() C.validate({['until']='platform_hit'}) end,'platform_hit requires platform')
  fails(function() C.validate({['until']='platform_hit',platform='Edge5',since_tick=99999}) end,'platform_hit since_tick is a game tick up to now')
  fails(function() C.validate({['until']='platform_hit',platform='Edge5',entity_names={'tank-x'}}) end,'platform_hit entity_names: tank-x is no entity name')
  fails(function() C.validate({['until']='platform_hit',platform='Edge5',at_least=0}) end,'at_least')
  -- the damage counted after a hit the ring no longer holds: from the platform's running total
  local late={['until']='platform_hit',platform='Edge5',damage=1}
  eq((C.check(sol,late)),false); game.tick=1600; hit('solar-panel',2,2,2.5,'small-carbonic-asteroid')
  met,saw=C.check(sol,late); eq(met,true); assert(saw:find('1 hit, 2.5 damage',1,true),saw)
  -- platform_energy_below: the accumulators together, stored over capacity
  local accs={}
  deck.find_entities_filtered=function(f) eq(f.type,'accumulator'); return accs end
  local low={['until']='platform_energy_below',platform='Edge5',fraction=0.3}
  C.validate(low)
  met,saw=C.check(sol,low)
  eq(met,false); eq(saw,'platform Edge5: no accumulator of ours')
  accs={{energy=4e6,electric_buffer_size=5e6},{energy=0,electric_buffer_size=5e6}}
  met,saw=C.check(sol,low)
  eq(met,false); eq(saw,'platform Edge5: 2 accumulators hold 4.0 of 10.0 MJ (40%; met under 30%)')
  accs[1].energy=2.5e6
  met,saw=C.check(sol,low)
  eq(met,true); eq(saw,'platform Edge5: 2 accumulators hold 2.5 of 10.0 MJ (25%; met under 30%)')
  fails(function() C.validate({['until']='platform_energy_below',platform='Edge5'}) end,'platform_energy_below fraction')
  fails(function() C.validate({['until']='platform_energy_below',platform='Edge5',fraction=1.5}) end,'platform_energy_below fraction')
  fails(function() C.validate({['until']='platform_energy_below',fraction=0.5}) end,'platform_energy_below requires platform')
  -- BB3 (Astra #1887): platform_progress, the share of its leg flown, as the platforms read gives it, on the leg asked
  prototypes.space_location={aquilo={},['solar-system-edge']={},nauvis={}}
  local leg
  C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
    platform_hits=function(pl) return A.hit_ring(pl),A.HIT_RING end,leg=function(pl) return leg end}
  local out={['until']='platform_progress',platform='Edge5',at_least=0.2,from='aquilo',to='solar-system-edge'}
  C.validate(out)
  edge.space_location={name='aquilo'}
  met,saw=C.check(sol,out)
  eq(met,false); eq(saw,'platform Edge5: not flying (at aquilo): not counted (asked: aquilo->solar-system-edge)')
  edge.space_location=nil
  leg={from='aquilo',to='solar-system-edge',flown=0.1234,length=100000}
  met,saw=C.check(sol,out)
  eq(met,false); eq(saw,'platform Edge5: flying aquilo->solar-system-edge, 12.3% of 100000 km flown (met at 20%)'); eq(out.evidence,nil)
  game.tick=2000; leg.flown=0.2049
  met,saw=C.check(sol,out)
  eq(met,true); eq(saw,'platform Edge5: flying aquilo->solar-system-edge, 20.5% of 100000 km flown (met at 20%)')
  eq(out.evidence.tick,2000); eq(out.evidence.from,'aquilo'); eq(out.evidence.to,'solar-system-edge'); eq(out.evidence.flown,0.205); eq(out.evidence.length_km,100000)
  -- the return leg, 90% flown (its far end is 10% out): not the leg asked
  leg={from='solar-system-edge',to='aquilo',flown=0.9,length=100000}
  met,saw=C.check(sol,{['until']='platform_progress',platform='Edge5',at_least=0.2,from='aquilo'})
  eq(met,false); eq(saw,'platform Edge5: flying solar-system-edge->aquilo, 90% flown: not the leg asked, not counted (asked: aquilo->any)')
  eq((C.check(sol,{['until']='platform_progress',platform='Edge5',at_least=0.2})),true,'any leg')
  fails(function() C.validate({['until']='platform_progress',platform='Edge5'}) end,'platform_progress at_least: the share of the leg flown')
  fails(function() C.validate({['until']='platform_progress',platform='Edge5',at_least=20}) end,'platform_progress at_least')
  fails(function() C.validate({['until']='platform_progress',platform='Edge5',at_least=0.2,to='edge'}) end,'platform_progress to: a planet or space location name')
  -- the remote lane takes it, as a wait and a guard's when
  local lanes=dofile('mod/agent-harness_0.1.0/queue_lanes.lua')
  local checked
  local function factory(api) checked=api.check_step; return {handlers={},schema={queue_submit={}}} end
  pcall(lanes,{scheduler={handlers={},schema={queue_submit={}}},base={player=function() end,busy=function() end},factory=factory,is_read=function() return false end})
  assert(checked,'the lane check')
  checked('wait_until',{['until']='platform_hit',platform='Edge5'})
  checked('wait_until',{['until']='platform_damage',platform='Edge5',damage=50})
  checked('wait_until',{['until']='platform_energy_below',platform='Edge5',fraction=0.3})
  checked('wait_until',{['until']='platform_progress',platform='Edge5',at_least=0.2})
  fails(function() checked('wait_until',{['until']='platform_hit'}) end,'platform_hit (platform_damage), platform_energy_below, platform_progress or ghosts_waiting with platform')
  prototypes=nil
end
print('d22_batch92 BB1, BB2, BB3 platform_hit (platform_damage), platform_energy_below, platform_progress: ok')
