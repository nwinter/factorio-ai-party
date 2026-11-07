-- Successor plans that drain in their first tick must retire their own guards.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
game={tick=100}
local s={}
local p={index=1}
local fired=0
local q=require('scheduler'){
  state=function() return s end,player=function() return p end,
  handlers={noop=function() return {} end,reaction=function() fired=fired+1; return {} end},
  busy=function() return false end,stop=function() end,stop_index=function() end,
  validate_condition=function() end,
  condition=function(_,c) return game.tick>=c.tick,'tick '..game.tick end,
}
local h=q.handlers
local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; q.tick() end end
local function status() return h.queue_status(p,{history='all'}) end
local function guard(scope,at)
  return {scope=scope,when={['until']='tick_at_least',tick=at or 1000},steps={{action='reaction'}}}
end
-- Both replace and append start successor plans; none may inherit the prior drain.
for _,mode in ipairs{'replace','append'} do
  h.queue_submit(p,{mode='replace',steps={{action='noop'}},guards={guard('plan')}})
  tick()
  eq(status().guards,nil)
  local first=status().plan.id
  h.queue_submit(p,{mode=mode,steps={{action='noop'}},guards={guard('plan'),guard('standing')}})
  tick()
  local st=status()
  eq(st.plan.id,first+1)
  eq(st.active,false)
  eq(#st.guards,1,'only the standing guard survives successor completion')
  eq(st.guards[1].scope,'standing')
  local row=st.history[#st.history]
  eq(row.action,'guards_retired')
  eq(row.plan,st.plan.id)
  eq(row.finished_tick,st.history[#st.history-1].finished_tick)
  assert(st.guards_after_plan:find('plan #'..st.plan.id..' finished',1,true))
  local history=#s.queues[1].history
  tick(20)
  eq(#s.queues[1].history,history,'idle ticks do not repeat retirement')
end
-- A standing guard survives append, fires later, and no retired plan guard fires with it.
h.queue_submit(p,{steps={{action='noop'}},guards={guard('plan')}})
tick()
eq(#status().guards,1)
tick(1000-game.tick)
eq(fired,1)
eq(status().paused,false)
print('batch455: first-tick successor retirement, plan/standing scopes and single retirement: ok')
