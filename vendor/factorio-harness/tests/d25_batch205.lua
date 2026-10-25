-- d25 batch205. Run from the harness root: lua tests/d25_batch205.lua
-- QR1 (Sol #2337: a 750-magazine pickup to Aquilo outlasted wait_until's 54000-tick timeout, and the wait after a
-- hold or requeue counted pods from its new start): pod_landed takes since_tick and quality, counts from the pod
-- ledger, and a held or requeued step keeps its start tick.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,err=pcall(fn); assert(not ok,'expected a failure: '..x); has(err,x) end
game={tick=200000}
prototypes={item={['firearm-magazine']={},['rocket-fuel']={}},quality={normal={},uncommon={},rare={},epic={},legendary={}}}

local state={}
local podlog=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return state end}
-- journeys as podlog records them: down from Sol's Ferry to Aquilo, other platforms, a rocket up, one in flight
local function journey(planet,r) state.podlog=state.podlog or {seq=0,by={},open={}}; local l=state.podlog.by[planet] or {}; state.podlog.by[planet]=l
  state.podlog.seq=state.podlog.seq+1; r.id=state.podlog.seq; l[#l+1]=r end
journey('aquilo',{platform='Ferry',sent=100000,landed=100900,dest='landing pad (3,4)',items={['firearm-magazine']=200}})
journey('aquilo',{platform='Ferry',sent=150000,landed=150900,dest='landing pad (3,4)',items={['firearm-magazine']=200,['firearm-magazine@rare']=50}})
journey('aquilo',{platform='Other',sent=150100,landed=151000,dest='landing pad (3,4)',items={['firearm-magazine']=200}})
journey('aquilo',{up=true,platform='Ferry',sent=150200,landed=150500,items={['firearm-magazine']=999}})
journey('aquilo',{platform='Ferry',sent=180000,landed=180800,dest='landing pad (3,4)',items={['firearm-magazine']=150,['rocket-fuel']=10}})
journey('aquilo',{platform='Ferry',sent=199000,items={['firearm-magazine']=200}})
journey('nauvis',{platform='Ferry',sent=120000,landed=120700,dest='ground (5,5)',items={['firearm-magazine@rare']=20}})

do
  -- landed after since: every quality of item, one quality, pods, and the newest landed
  local r=podlog.landed_from('Ferry',140000,'firearm-magazine')
  eq(r.pods,2,'pods'); eq(r.items,400,'items, every quality'); eq(r.last.landed,180800); eq(r.complete,true)
  eq(podlog.landed_from('Ferry',140000,'firearm-magazine','rare').items,50,'rare only')
  eq(podlog.landed_from('Ferry',140000,'firearm-magazine','normal').items,350,'normal only')
  eq(podlog.landed_from('Ferry',0,'firearm-magazine').items,620,'every planet, from tick 0')
  eq(podlog.landed_from('Ferry',0).pods,4,'pods, no item: the rocket up and the pod in flight do not count')
  eq(podlog.landed_from('Ferry',180800).pods,0,'landed at since does not count')
  -- a full list whose oldest kept journey was sent after since is incomplete
  local saved=podlog.KEEP; podlog.KEEP=6
  local inc=podlog.landed_from('Ferry',50000,'firearm-magazine')
  eq(inc.complete,false); eq(inc.oldest,100000)
  podlog.KEEP=saved
end

local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
  receipts=function() return {} end,pods_landed=function(name,since,item,q) return podlog.landed_from(name,since,item,q) end}
local p={force={platforms={{valid=true,name='Ferry'}}}}
do
  local c={['until']='pod_landed',platform='Ferry',item='firearm-magazine',at_least=750,since_tick=90000}
  C.validate(c)
  local met,saw=C.check(p,c,nil,{})
  eq(met,false); eq(saw,'4 pods from Ferry landed and delivered since tick 90000 with 620 firearm-magazine (the last delivered at tick 180800, landing pad (3,4) on aquilo)')
  c.at_least=620; eq((C.check(p,c,nil,{})),true,'met at 620')
  local rare={['until']='pod_landed',platform='Ferry',item='firearm-magazine',quality='rare',at_least=70,since_tick=0}
  C.validate(rare)
  met,saw=C.check(p,rare,nil,{})
  eq(met,true); has(saw,'with 70 firearm-magazine (rare quality)')
  -- with no since_tick it counts from the wait's first check, and says that tick
  local rec={}
  game.tick=181000
  met,saw=C.check(p,{['until']='pod_landed',platform='Ferry'},nil,rec)
  eq(met,false); eq(rec.pod_since,181000); eq(saw,'0 pods from Ferry landed and delivered since the wait began (tick 181000)')
  game.tick=200000
  -- refused
  fails(function() C.validate({['until']='pod_landed',platform='Ferry',since_tick=200001}) end,'pod_landed since_tick is a whole game tick 0..now (200000)')
  fails(function() C.validate({['until']='pod_landed',platform='Ferry',since_tick=10.5}) end,'pod_landed since_tick is a whole game tick')
  fails(function() C.validate({['until']='pod_landed',platform='Ferry',last_drop=true,since_tick=10}) end,'no since_tick')
  fails(function() C.validate({['until']='pod_landed',platform='Ferry',quality='rare'}) end,'pod_landed quality goes with item')
  fails(function() C.validate({['until']='pod_landed',platform='Ferry',item='firearm-magazine',quality='shiny'}) end,'quality is a quality name')
  fails(function() C.validate({['until']='platform_arrived',platform='Ferry',quality='rare'}) end,'quality applies to item_count, platform_ammo_below and pod_landed only')
end

-- A held wait (on_timeout hold) and a requeued one (the queue paused while it ran) keep their start tick: pods that
-- landed between the first start and the resume count.
do
  game.tick=300000
  local qstate={}
  local players={[1]={index=1,force=p.force}}
  local sch=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return qstate end,player=function(i) return players[i] end,
    handlers={craft=function() return {started=1} end},busy=function() return false end,stop=function() end,stop_index=function() end,
    condition=function(pp,c,record) return C.check(pp,c,nil,record) end,validate_condition=function(c) C.validate(c) end}
  local h=sch.handlers
  local function tick(n) for _=1,n do game.tick=game.tick+1; sch.tick() end end
  local wait={['until']='pod_landed',platform='Ferry',item='firearm-magazine',at_least=300,timeout=30,on_timeout='hold'}
  h.queue_submit(players[1],{steps={{action='wait_until',args=wait},{action='craft'}}})
  tick(60)
  local q=h.queue_status(players[1])
  assert(q.paused,'held'); has(q.history[#q.history].result.saw,'since the wait began (tick 300002)')
  -- two pods land while it is held
  journey('aquilo',{platform='Ferry',sent=300010,landed=300050,dest='landing pad (3,4)',items={['firearm-magazine']=200}})
  game.tick=320000
  h.queue_resume(players[1],{})
  tick(15)
  q=h.queue_status(players[1])
  has(q.active and q.active.saw or q.history[#q.history].result.saw,'since the wait began (tick 300002) with 200 firearm-magazine')
  -- the queue paused while it waits (a direct call, a deploy): requeued at the head with the same start
  sch.pause(1,'a direct walk')
  eq(qstate.queues[1].pending[1].pod_since,300002,'requeued with its start')
  journey('aquilo',{platform='Ferry',sent=320100,landed=320500,dest='landing pad (3,4)',items={['firearm-magazine']=100}})
  game.tick=321000
  h.queue_resume(players[1],{})
  tick(15)
  q=h.queue_status(players[1])
  local done=q.history[#q.history-1]
  eq(done.action,'wait_until'); eq(done.result.outcome,'met'); has(done.result.saw,'2 pods from Ferry landed and delivered since the wait began (tick 300002) with 300 firearm-magazine')
  -- a queue_submit with since_tick past the present is refused at submit and in dry_run
  fails(function() h.queue_submit(players[1],{steps={{action='wait_until',args={['until']='pod_landed',platform='Ferry',since_tick=game.tick+5}}}}) end,'since_tick is a whole game tick')
end
print('d25_batch205 QR1 pod_landed since_tick from the pod ledger, kept across hold and requeue: ok')
-- the wait's line names the pods landed from the platform (not its hub)
do
  local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){}
  eq(W.estimate(p,{['until']='pod_landed',platform='Ferry',item='firearm-magazine',since_tick=90000},false).condition,'pod_landed firearm-magazine landed from Ferry since tick 90000')
  eq(W.estimate(p,{['until']='pod_landed',platform='Ferry'},false).condition,'pod_landed pods landed from Ferry')
end
print('d25_batch205 QR1 wait line: ok')
