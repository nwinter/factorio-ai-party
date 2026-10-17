-- d16 batch8 (operator 18:30, agents' requests at the 16:50 and 18:20 polls). Run from the harness root: lua tests/d16_batch8.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A5 (Opus 2x: a queue that paused itself after a craft step): queue_status says why it paused.
do
  game={tick=0}
  local st={}
  local players={[1]={index=1}}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,
    handlers={craft=function() error('not crafted: 8 gun-turret held by our factory',0) end,walk=function() return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,validate_condition=function() end}
  local function run(n) for _=1,n do game.tick=game.tick+1; S.tick() end end
  S.handlers.queue_submit(players[1],{steps={{action='craft',args={recipe='gun-turret',count=8}},{action='walk',args={direction='north',ticks=3}}}})
  run(3)
  local q=S.handlers.queue_status(players[1],{})
  eq(q.paused,true)
  has(q.paused_why,'craft failed: not crafted: 8 gun-turret held by our factory (on_fail abort pauses the plan; on_fail skip goes on)')
  has(q.paused_why,'queue_resume runs the rest')
  S.pause(1,'stop')
  has(S.handlers.queue_status(players[1],{}).paused_why,'stop (tick')
end
print('d16_batch8 A5 why the queue paused: ok')
