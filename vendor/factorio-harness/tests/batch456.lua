-- First failure survives the aim watch's bounded shot history, including a deployed legacy watch.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
game={tick=1000}
defines={inventory={turret_ammo=1}}
local inv={valid=true,get_item_count=function() return 100 end}
local rail={valid=true,unit_number=1,position={x=1,y=2},quality={name='normal'},energy=100,
  electric_buffer_size=100,prototype={attack_parameters={cooldown=60}},get_inventory=function() return inv end}
local surface={index=1,platform={name='Test'},find_entities_filtered=function() return {rail} end}
local state={}
local W=require('railaim'){state=function() return state end,on_platform=function() return {surface=surface} end}
local p={index=1,force='player'}
local function start()
  W.handler(p,{platform='Test',aim=true,seconds=120})
  local job=state.rail_aim[1]
  return job,job.rails[1]
end
local function shot(job,t,i,kind)
  t.kept=kind~='no_target' and {un=i,name='huge-metallic-asteroid',x=i,y=-50} or nil
  t.kept_ref={valid=kind~='kill'}
  t.pending=(kind=='kill' or kind=='survived') and {{un=i,name='huge-metallic-asteroid',hp=kind=='kill' and 0 or 100}} or {}
  W.shot(job,t,1000+i,1)
  assert(#t.recent<=24)
end
for _,kind in ipairs{'survived','miss','no_target'} do
  local job,t=start()
  for i=1,80 do shot(job,t,i,i==3 and kind or 'kill') end
  local r=W.handler(p,{aim=true})
  local out=r.railguns[1]
  eq(#out.recent,24); eq(out.recent_more,56); eq(out.shots,80); eq(out.statistics.shots,80)
  eq(out.first_failure,out.recent[1]); eq(out.first_failure.tick,1002)
  if kind=='no_target' then eq(out.first_failure.aimed,nil) else eq(out.first_failure.aimed,'huge-metallic-asteroid') end
  if kind~='no_target' then eq(out.first_failure.position.x,3); eq(out.first_failure.position.y,-50) end
  for i=2,24 do eq(out.recent[i].tick,1055+i) end
  assert(r.recent_note:find('first_failure',1,true))
  -- Done reads retain it too, and new watches reset it.
  job.live=false
  eq(W.handler(p,{aim=true}).railguns[1].first_failure.tick,1002)
end
local job,t=start()
eq(t.first_failure,nil)
for i=1,40 do shot(job,t,i,'kill') end
eq(t.first_failure,nil); eq(#t.recent,24); eq(t.recent[1].tick,1016)
-- A later failure is pinned once it reaches the oldest slot; later failures cannot replace it.
shot(job,t,41,'miss')
for i=42,90 do shot(job,t,i,'survived') end
eq(t.first_failure.tick,1040); eq(t.recent[1],t.first_failure); eq(#t.recent,24)
-- Legacy runtime state: recover the earliest failure still present, never invent evicted history.
job,t=start()
for i=1,10 do shot(job,t,i,i==5 and 'survived' or 'kill') end
t.first_failure,t.failure_checked=nil,nil
for i=11,60 do shot(job,t,i,'kill') end
eq(t.first_failure.tick,1004); eq(t.recent[1],t.first_failure); eq(#t.recent,24)
eq(t.recent_more,36)
assert(W.ARGS.aim:find('first_failure',1,true))
print('batch456: aim first failure, newest shots, cap, totals, done/reset and legacy state: ok')
