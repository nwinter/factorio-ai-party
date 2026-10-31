-- Stale ammunition policy, background refresh, guards, wait deadlines and a finite production lane.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn); assert(not ok); has(tostring(e),x) end
defines={inventory={hub_main=1}}
prototypes={item={['railgun-ammo']={type='ammo'}},quality={normal={}}}
game={tick=12000}
local native,made,reads=1500,1000,0
local force={name='player'}
local surface={name='platform-1',index=1,valid=true,get_chunks=function() return function() end end}
local hub={valid=true,position={x=0,y=0},get_inventory=function()
  reads=reads+1
  return {get_contents=function() return {{name='railgun-ammo',quality='normal',count=native}} end}
end}
local pl={index=1,valid=true,name='Asterion',surface=surface,hub=hub,force=force}
force.platforms={pl}; game.forces={player=force}
force.get_item_production_statistics=function(s)
  eq(s,surface); return {get_input_count=function() return made end}
end
local p={index=1,force=force}
local st={active={}}
local A=require('ammoreserve'){state=function() return st end,walk={}}
local C=require('conditions'){ammo_reserve=function(pl,f,c) return A.check(pl,f,c) end,position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end}
local function cond(policy,extra)
  local c={['until']='platform_ammo_below',platform='Asterion',item='railgun-ammo',count=1600,max_age=60,on_stale=policy}
  for k,v in pairs(extra or {}) do c[k]=v end
  return c
end
local function seed(count,age)
  st.ammo_reserve=nil
  local r=A.want(pl,force)
  r.first=game.tick-3601
  if count then r.done={start=game.tick-age,finish=game.tick-age+1,counts={['railgun-ammo']={normal={hub=count}}},
    ents={turrets=0,belts=0,inserters=0,machines=0,chests=0}} end
  return r
end
local function check(c)
  C.validate(c)
  local before=reads
  local met,saw=C.check(p,c)
  eq(reads,before,'checking never reads an entity')
  has(saw,'max_age 1m00s'); has(saw,'refresh_pending ')
  return met,saw
end
local function pass(c)
  local start=game.tick
  for _=1,65 do game.tick=game.tick+1; A.tick(game.tick) end
  assert(st.ammo_reserve.plats[1].done.start>start,'the existing background picker refreshed')
  return check(c)
end

fails(function() C.validate(cond('ignore')) end,'on_stale: "met" (default) or "wait"')
fails(function() C.validate({['until']='tick_at_least',tick=game.tick,on_stale='wait'}) end,'on_stale applies to platform_ammo_below only')
fails(function() C.validate({['until']='any',conditions={cond()},on_stale='wait'}) end,'on_stale applies to platform_ammo_below only')
for _,policy in ipairs({'met','wait','default'}) do
  local c=cond(policy~='default' and policy or nil)
  for _,cached in ipairs({10,3000}) do
    for _,actual in ipairs({1500,1700}) do
      seed(cached,3601); native=actual
      local met,saw=check(c)
      eq(met,policy~='wait','both stale low and stale high use the policy')
      has(saw,'reading_tick '..game.tick-3601); has(saw,'age 1m00s (3601 ticks)')
      has(saw,'refresh_pending true'); has(saw,'on_stale '..(policy=='default' and 'met' or policy))
      met,saw=pass(c)
      eq(met,actual<1600,'a fresh pass uses the new total, not cached stock')
      has(saw,'refresh_pending false'); has(saw,actual..' railgun-ammo')
    end
  end
  seed(nil); local met,saw=check(c)
  eq(met,policy~='wait','none past max_age')
  has(saw,'reading_tick none; age unknown'); has(saw,'refresh_pending true')
  native=1700; eq(pass(c),false,'first pass arrives high')
  seed(1500,3600); eq(check(c),true,'exactly max_age is fresh')
  seed(1700,3600); eq(check(c),false,'fresh high is unmet')
  local r=seed(nil); r.first=game.tick
  eq(check(c),false,'first reading pending within max_age')
  r.first=game.tick-3600; eq(check(c),false,'missing at the exact boundary remains unmet')
  -- A newly requested scope has its own missing-reading clock even when the platform has a fresh total.
  seed(10,0)
  local scoped=cond(c.on_stale,{area={{-1,-1},{1,1}}})
  eq(check(scoped),false)
  game.tick=game.tick+3601
  met,saw=check(scoped); eq(met,policy~='wait'); has(saw,'reading_tick none; age unknown')
  native=1700; eq(pass(scoped),false,'fresh scoped high reading')
end

local W=require('waiteta'){}
has(W.estimate(p,cond('wait'),false,nil,{}).condition,'on_stale wait')
local enabled=false
local base={state=function() return st end,player=function() return p end,
  handlers={circuit_set=function(_,a) enabled=a.switch_on; return {} end},busy=function() return false end,
  stop=function() end,stop_index=function() end,claim=function() end,direct_action=function() end,
  outcome=function() return 'done' end,validate_condition=function(c) return C.validate(c) end,
  condition=function(p,c,record) return C.check(p,c,nil,record) end}
local make=require('scheduler')
local lanes=require('queue_lanes'){scheduler=make(base),factory=make,base=base,is_read=function() return false end}
local h=lanes.handlers
local function tick(n) for _=1,n do game.tick=game.tick+1; lanes.tick() end end
local function queue(lane) return st[lane=='remote' and 'remote_queues' or lane=='body' and 'queues' or 'lane_queues|Asterion'][1] end
local function submit(lane,steps,guards) return h.queue_submit(p,{lane=lane,mode='replace',steps=steps,guards=guards}) end
local function switch(on,label) return {action='circuit_set',args={platform='Asterion',position={0,0},switch_on=on},label=label} end

for _,policy in ipairs({'met','wait'}) do
  for _,lane in ipairs({'body','remote','platform:Asterion'}) do
    -- An unmet wait keeps its original deadline. Stale wait does not extend it on repeated checks.
    seed(policy=='wait' and 10 or 1700,policy=='wait' and 3601 or 0)
    submit(lane,{{action='wait_until',args=cond(policy,{timeout=30})}})
    tick(1); local q=queue(lane); local deadline=q.current.until_tick
    tick(20); eq(q.current.until_tick,deadline)
    tick(20); eq(q.current,nil); eq(q.history[#q.history].result.outcome,'timed_out')
    -- A guard uses the same policy in a compound condition. No fresh pass: wait leaves it armed.
    seed(10,3601); enabled=false
    submit(lane,{{action='wait_ticks',args={ticks=1000}},switch(true,'stop')},
      {{when={['until']='any',conditions={cond(policy)}},['goto']='stop'}})
    tick(120); eq(enabled,policy=='met','guard stale policy')
    if policy=='wait' then
      local saw=queue(lane).guards[1].saw; has(saw,'refresh_pending true'); has(saw,'on_stale wait')
      native=1500; pass(cond('wait')); tick(120); eq(enabled,true,'guard fires after fresh low pass')
    end
    h.queue_cancel(p,{lane=lane})
  end
  -- Sol's six-step structure: demand gate, makers on, produced +50, makers off.
  -- A stale wait does not turn makers on; a fresh low reading lets both policies run the same finite budget.
  local lane='platform:Asterion'
  seed(10,3601); native=1500; made=1000; enabled=false
  submit(lane,{{action='wait_until',args={['until']='all',conditions={cond(policy)},timeout=18000}},
    switch(true),switch(true),
    {action='wait_until',args={['until']='produced',platform='Asterion',item='railgun-ammo',at_least=50,timeout=27000}},
    switch(false,'rail-safe-stop'),switch(false)})
  tick(60); eq(enabled,policy=='met')
  if policy=='wait' then pass(cond(policy)); tick(60) end
  eq(enabled,true)
  local q=queue(lane); eq(q.current.args['until'],'produced'); eq(q.current.args.at_least,50)
  eq(q.current.until_tick-q.current.started_tick,27000,'production timeout unchanged')
  made=1049; tick(30); eq(enabled,true); eq(q.current.args['until'],'produced')
  made=1050; tick(30); eq(enabled,false); eq(q.current,nil); eq(#q.pending,0)
end
print('d30_batch390: stale policies, refresh, scopes, guards, deadlines and finite produced budget: ok')
