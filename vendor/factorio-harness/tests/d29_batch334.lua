-- d29 batch334 LH (operator 03:27): the harness's per-tick and per-reply garbage cut, the same results. Run from the
-- harness root: lua tests/d29_batch334.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- 1: an idle queue (no step, nothing pending, no loop, order or guards) makes no player or proxy each tick: the lookup's
-- asserts only (player_check); a failing check still pauses it with the reason, as the full lookup did.
do
  game={tick=0}
  local st={}
  local players={[1]={index=1}}
  local full,checks,fail_check=0,0,nil
  local handlers={craft=function() return {} end}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,
    player=function(i) full=full+1; return players[i] end,
    player_check=function(i) checks=checks+1; if fail_check then error(fail_check,0) end; return true end,
    handlers=handlers,busy=function() return false end,stop=function() end,stop_index=function() end,
    condition=function() return false end,validate_condition=function() end}
  S.handlers.queue_submit(players[1],{mode='replace',steps={{action='craft',args={recipe='x'}}}})
  game.tick=1; S.tick()
  eq(full,1,'the step ran with the player')
  full,checks=0,0
  for t=2,11 do game.tick=t; S.tick() end
  eq(full,0,'an idle queue: no player made'); eq(checks,10,'its check each tick')
  fail_check='bot sol is dead; it respawns at tick 900'
  game.tick=12; S.tick()
  local status=S.handlers.queue_status(players[1],{})
  eq(status.paused,true,'paused by the failing check')
  has(status.paused_why, 'the queue could not act for you: bot sol is dead')
  -- with a step pending the full lookup runs again
  fail_check=nil
  S.handlers.queue_submit(players[1],{mode='replace',steps={{action='craft',args={recipe='y'}}}})
  full=0
  game.tick=13; S.tick()
  eq(full,1,'a queue with work: the player made')
  -- without player_check (an api from before) the full lookup runs
  local st2={}
  local S2=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st2 end,
    player=function(i) full=full+1; return players[i] end,handlers=handlers,busy=function() return false end,stop=function() end,
    stop_index=function() end,condition=function() return false end,validate_condition=function() end}
  S2.handlers.queue_submit(players[1],{mode='replace',steps={{action='craft',args={recipe='x'}}}})
  full=0
  for t=14,16 do game.tick=t; S2.tick() end
  eq(full,3,'no player_check: the lookup each tick, as before')
  game=nil
end
print('d29_batch334 1 idle queues: ok')

-- 2: a bot aboard a platform reads the force's platforms once while the platform it found stays valid, again when it
-- goes invalid (the same platform by index comes back).
do
  local reads=0
  local lark={valid=true,index=2,name='Lark',surface={valid=true,name='platform-2'}}
  local other={valid=true,index=1,name='Swift',surface={valid=true,name='platform-1'}}
  local list={other,lark}
  local force=setmetatable({},{__index=function(_,k) if k=='platforms' then reads=reads+1; return list end end})
  game={tick=0,forces={player=force}}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/bots.lua'){state=function() return st end}
  local b={name='sol',index=1000002,travel={state='aboard',platform='Lark',platform_index=2,since=0}}
  for t=1,5 do game.tick=t; B.travel_tick(b,t) end
  eq(reads,1,'one read for five ticks aboard')
  eq(b.travel.platform,'Lark')
  lark.valid=false
  local lark2={valid=true,index=2,name='Lark II',surface={valid=true,name='platform-2'}}
  list={other,lark2}
  game.tick=6; B.travel_tick(b,6)
  eq(reads,2,'the kept one invalid: found again'); eq(b.travel.platform,'Lark II','renamed, by index')
  game.tick=7; B.travel_tick(b,7)
  eq(reads,2,'then kept again')
  game=nil
end
print('d29_batch334 2 bot platform kept: ok')

-- 3: platalerts.listeners reads every agent's place once (not once a platform per agent), with the same answers: the
-- creator hears it; a bot aboard and a player whose surface is the platform hear it; no one else then.
do
  local agents_calls=0
  local lark={valid=true,index=2,name='Lark',surface={valid=true,name='platform-2'}}
  local s_lark={valid=true,name='platform-2',platform=lark}
  local s_nauvis={valid=true,name='nauvis'}
  local bots={[11]={travel={state='aboard',platform='Lark'}},[12]={}}
  local people={[1]={valid=true,physical_surface=s_lark},[2]={valid=true,physical_surface=s_nauvis}}
  game={tick=100}
  local P=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return {} end,
    agents=function() agents_calls=agents_calls+1; return {{index=1,name='nick'},{index=2,name='far'},{index=11,name='sol'},{index=12,name='luna'}} end,
    bot=function(i) return bots[i] end,lookup=function(i) return people[i] end}
  local out=P.listeners(lark)
  local names={}
  for _,a in ipairs(out) do names[#names+1]=a.name end
  eq(table.concat(names,','),'nick,sol','on it: the player on its surface and the bot aboard')
  eq(agents_calls,2,'the agents read twice in all (the list and who is aboard), not once a listener')
  -- nobody on it, no creator: every agent hears it
  bots[11].travel=nil; people[1].physical_surface=s_nauvis
  out=P.listeners(lark)
  eq(#out,4,'no one on it: all hear it')
  game=nil
end
print('d29_batch334 3 platform listeners: ok')

-- 4: pushalerts.lines makes the roster and the owners once a tick for every agent's reply in it.
do
  local agents_calls=0
  local st={push_bg=true,push_alerts={player={tick=0,groups={
    {key='g1',kind='ammo_empty',surface='nauvis',center={x=0,y=0},by={sol=1},n=1},
    {key='g2',kind='ammo_empty',surface='nauvis',center={x=50,y=0},by={sol=1},n=1}}}}}
  game={tick=10}
  defines={entity_status={}}
  local A=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,
    agents=function() agents_calls=agents_calls+1; return {{index=1,name='sol'},{index=2,name='luna'},{index=3,name='grok'}} end,
    who=function(p) return p.name end}
  local force={name='player'}
  local luna={name='luna',force=force,surface={name='nauvis'}}
  local grok={name='grok',force=force,surface={name='nauvis'}}
  local l1=A.lines(luna,{})
  local l2=A.lines(grok,{})
  eq(#l1,0); eq(#l2,0,'built by sol: not luna\'s or grok\'s')
  eq(agents_calls,1,'one roster for both replies in the tick')
  game.tick=11
  A.lines(luna,{})
  eq(agents_calls,2,'a new tick: made again')
  game,defines=nil,nil
end
print('d29_batch334 4 alert owners once a tick: ok')
