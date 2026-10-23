-- Run from repository root: lua tests/profile.lua
-- The operator profiler (profile.lua) against a fake engine: per-second and
-- total lines per dispatch (action/scope), reply encoding, event, tick and part.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
-- Fake profilers on a fake clock (ms): a stopped profiler holds what it timed.
local now=0
local function profiler(stopped)
  local p={ms=0}
  local from=not stopped and now or nil
  p.stop=function() if from then p.ms=p.ms+now-from; from=nil end end
  p.add=function(o) p.ms=p.ms+o.ms end
  return p
end
local created=0
helpers={create_profiler=function(stopped) created=created+1; return profiler(stopped) end,
  table_to_json=function(t) now=now+(t.big and 40 or 1); return '{}' end}
game={tick=600}
defines={events={on_tick=0,on_entity_damaged=97,on_built_entity=6}}
local logged={}
log=function(m) logged[#logged+1]=m end
local function text(m) local out={} for i=2,#m do out[#out+1]=type(m[i])=='table' and (string.format('%g',m[i].ms)..'ms') or tostring(m[i]) end return table.concat(out) end
local function lines(prefix) local out={} for _,m in ipairs(logged) do local t=text(m); if t:sub(1,#prefix)==prefix then out[#out+1]=t end end return out end
local function find(prefix,pattern) for _,t in ipairs(lines(prefix)) do if t:find(pattern,1,true) then return t end end end

local R={}
local team_calls=0
local part={team=function(p,x) team_calls=team_calls+1; now=now+3; return 'team',x end}
R.dispatch=function(request)
  if request.action=='boom' then error('broke',0) end
  now=now+(request.action=='observe' and 2 or 5)
  local a,b=part.team(1,'x'); assert(a=='team' and b=='x')
  return {big=request.action=='defense'}
end
R.on_event=function(event) now=now+(event.name==97 and 1 or 7) end
R.tick=function(event) now=now+0.5 end
local profile=require('profile')()
profile.wrap(R,{{part,'team','board.team'},{nil,'tick','missing'}})
local function tick() game.tick=game.tick+1; R.tick{tick=game.tick} end

-- Idle: the wrappers pass through and make no profiler.
eq(R.dispatch{action='status'}.big,false); R.on_event{name=97}; tick()
eq(created,0); eq(#logged,0); eq(team_calls,1)

-- A run: two dispatches of observe/sleep_check, one defense with a big reply, an event, a failure that still raises.
game.tick=600
local started=profile.start({seconds=2})
eq(started.until_tick,game.tick+120); assert(profile.running())
R.dispatch{action='observe',args={scope='sleep_check'}}
R.dispatch{action='observe',args={scope='sleep_check'}}
R.dispatch{action='defense',args={}}
R.on_event{name=97}; R.on_event{name=6}
local ok,err=pcall(R.dispatch,{action='boom'}); eq(ok,false); eq(err,'broke')
for _=1,60 do tick() end
-- The game second ended: one line per key that ran in it, '*' summing the top-level keys (parts excluded).
eq(find('agent-harness profile second','key=dispatch observe/sleep_check'),'agent-harness profile second tick=600 n=2 key=dispatch observe/sleep_check time=10ms')
eq(find('agent-harness profile second','key=dispatch defense'),'agent-harness profile second tick=600 n=1 key=dispatch defense time=8ms')
eq(find('agent-harness profile second','key=encode defense'),'agent-harness profile second tick=600 n=1 key=encode defense time=40ms')
eq(find('agent-harness profile second','key=event on_entity_damaged'),'agent-harness profile second tick=600 n=1 key=event on_entity_damaged time=1ms')
eq(find('agent-harness profile second','key=event on_built_entity'),'agent-harness profile second tick=600 n=1 key=event on_built_entity time=7ms')
eq(find('agent-harness profile second','key=dispatch boom'),'agent-harness profile second tick=600 n=1 key=dispatch boom time=0ms')
eq(find('agent-harness profile second','key=part board.team'),'agent-harness profile second tick=600 n=3 key=part board.team time=9ms')
eq(find('agent-harness profile second','key=tick time='),'agent-harness profile second tick=600 n=59 key=tick time=29.5ms')
-- 10+8+1(encode observe)*2+40+1+7+0+29.5
eq(find('agent-harness profile second','key=*'),'agent-harness profile second tick=600 n=68 key=* time=97.5ms')
eq(lines('agent-harness profile total')[1],nil)
-- The Lua heap that second, read once a tick: KB now, grown and fallen.
local heap=find('agent-harness profile heap','tick=600 kb=')
assert(heap and heap:match('^agent%-harness profile heap tick=600 kb=%d+ grew_kb=%d+ fell_kb=%d+$'),tostring(heap))
-- At until_tick: the last second's lines, then totals per key and a done line; afterwards idle again.
for _=1,60 do tick() end
assert(not profile.running())
eq(find('agent-harness profile total','key=dispatch observe/sleep_check'),'agent-harness profile total ticks=120 n=2 key=dispatch observe/sleep_check time=10ms')
eq(find('agent-harness profile total','key=tick time='),'agent-harness profile total ticks=120 n=120 key=tick time=60ms')
eq(find('agent-harness profile second','tick=660 n=60 key=tick time='),'agent-harness profile second tick=660 n=60 key=tick time=30ms')
assert(find('agent-harness profile done','from_tick=600 to_tick=720 (elapsed) keys=10'),text(logged[#logged]))
local before=#logged
R.dispatch{action='observe',args={scope='sleep_check'}}; tick(); eq(#logged,before)

-- An operator relay is keyed apart; stop ends a run early; seconds is bounded.
profile.start({seconds=600})
R.dispatch{action='board',operator=true}
eq(profile.start({stop=true}).note,'stopped; the lines are in the server log')
assert(find('agent-harness profile total','key=dispatch board (operator)'))
assert(find('agent-harness profile done','(stopped)'))
eq(profile.start({stop=true}).note,'no profile is running')
assert(not pcall(profile.start,{seconds=601}))
-- Starting again ends the run in progress.
profile.start({seconds=5}); tick(); profile.start({seconds=5})
assert(find('agent-harness profile done','(restarted)'))
profile.start({stop=true})
-- A labelled part from inside a module (a background job's step by kind): idle, just the call; in a run, timed as
-- that part; an error still raises.
local made=created
local a,b=profile.part('pushalerts.band',function(x,y) now=now+4; return x+y,'z' end,1,2)
eq(a,3); eq(b,'z'); eq(created,made,'idle: no profiler')
profile.start({seconds=5})
profile.part('pushalerts.band',function() now=now+4 end)
profile.part('pushalerts.band',function() now=now+2 end)
ok,err=pcall(profile.part,'pushalerts.merge',function() error('merge broke',0) end)
eq(ok,false); eq(err,'merge broke')
profile.start({stop=true})
eq(find('agent-harness profile total','key=part pushalerts.band'),'agent-harness profile total ticks=0 n=2 key=part pushalerts.band time=6ms')
-- (d22 batch110 BT1) alloc: the heap grown inside each key (KB, a key's parts inside it); gc "stop" stops the collector
-- for the run and restarts it at the end; a call the heap fell in is counted as gc_inside, its growth not.
do
  local kb,calls=1000,{}
  local real=collectgarbage
  collectgarbage=function(what) calls[#calls+1]=what; if what=='count' then return kb elseif what=='isrunning' then return true end return 0 end
  local R2={}
  local P2={grow=function(n) kb=kb+n end}
  R2.dispatch=function(request) kb=kb+(request.action=='status' and 30 or 2); P2.grow(5); return {} end
  R2.tick=function() kb=kb+1 end
  local prof=require('profile')
  local pr=prof()
  pr.wrap(R2,{{P2,'grow','grow'}})
  local r=pr.start({seconds=1,alloc=true,gc='stop'})
  eq(r.collector.stop,'stopped for the run'); eq(r.collector.count_kb,1000); eq(r.collector.isrunning,true)
  R2.dispatch{action='status'}
  R2.dispatch{action='observe',args={scope='sleep_check'}}
  P2.grow(-50)  -- a collection step inside a part: its growth not counted
  for _=1,60 do game.tick=game.tick+1; R2.tick{tick=game.tick} end
  eq(find('agent-harness profile alloc','key=dispatch status '),'agent-harness profile alloc ticks=60 n=1 key=dispatch status kb=35 gc_inside=0')
  eq(find('agent-harness profile alloc','key=dispatch observe/sleep_check'),'agent-harness profile alloc ticks=60 n=1 key=dispatch observe/sleep_check kb=7 gc_inside=0')
  eq(find('agent-harness profile alloc','key=part grow'),'agent-harness profile alloc ticks=60 n=3 key=part grow kb=10 gc_inside=1')
  eq(find('agent-harness profile alloc','key=tick '),'agent-harness profile alloc ticks=60 n=60 key=tick kb=60 gc_inside=0')
  eq(calls[#calls],'restart','the collector restarted at the end')
  -- without alloc: no alloc lines, the collector untouched
  local before_calls=#calls
  pr.start({seconds=1}); for _=1,60 do game.tick=game.tick+1; R2.tick{tick=game.tick} end
  for i=before_calls+1,#calls do assert(calls[i]=='count',calls[i]) end
  assert(not pcall(pr.start,{seconds=1,gc='step'}))
  collectgarbage=real
end
print('profile: ok')
