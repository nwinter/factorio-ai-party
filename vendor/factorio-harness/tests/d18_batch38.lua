-- d18 batch38 (the 18:20 poll). Run from the harness root: lua tests/d18_batch38.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A1 (Sol 18:21: platform_schedule failed for no_schedule while the platform began flying moments later): a queue step
-- whose platform read no_schedule in the call's tick waits for the second read; it fails only when that still reads it.
do
  game={tick=0}
  local st={}
  local players={{index=1,valid=true,name='sol',force={name='player'}}}
  local verdict
  local calls=0
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,
    handlers={platform_schedule=function() calls=calls+1; return {state='no_schedule',recheck={platform='Wayfarer',first='no_schedule'}} end,craft=function() return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,validate_condition=function() end,
    recheck_read=function(rc) return verdict end}
  local function run(n) for _=1,n do game.tick=game.tick+1; S.tick() end end
  S.handlers.queue_submit(players[1],{steps={{action='platform_schedule',args={platform='Wayfarer',next=true}},{action='craft'}}})
  run(25)
  local q=st.queues[1]
  eq(calls,1); assert(q.current and q.current.action=='platform_schedule','the step waits for the second read')
  eq(#q.pending,1,'craft waits behind it')
  verdict={ok=true,line='Wayfarer read no_schedule at tick 1 and on_the_path 39 ticks later'}
  run(10)
  eq(q.current,nil); eq(q.history[1].ok,true); eq(q.history[1].result.recheck_read,verdict.line)
  run(2); eq(#q.pending,0,'then the next step')
  -- still stuck: the step fails with the second read
  verdict=nil
  S.handlers.queue_submit(players[1],{steps={{action='platform_schedule',args={platform='Wayfarer',next=true}},{action='craft'}}})
  run(20)
  verdict={ok=false,line='x',error='Wayfarer read no_schedule at tick 40 and still no_schedule 300 ticks later; the call failed'}
  run(10)
  local last=q.history[#q.history]
  eq(last.ok,false); has(last.result.reason,'still no_schedule 300 ticks later')
  game=nil
end
print('d18_batch38 A1 a queue step waits for the second read: ok')

print('d18 batch38 ok')
