local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
local world={}
game={tick=0}
local state,active,combat,calls={},{},{},{}
local players={[1]={index=1}}
local handlers={
  walk=function(p,a) active[p.index]=game.tick+(a.ticks or 3); calls[#calls+1]='walk'; return {accepted=true} end,
  shoot=function(p,a) combat[p.index]=game.tick+(a.ticks or 5); calls[#calls+1]='shoot'; return {} end,
  craft=function() calls[#calls+1]='craft'; return {started=1} end,
  broken=function() error('fixture failure') end,
}
local function stop(p) active[p.index]=nil; combat[p.index]=nil end
local scheduler=factory{
  state=function() return state end,
  player=function(i) assert(players[i],'player unavailable'); return players[i] end,
  handlers=handlers,
  busy=function(p,action) return action=='shoot' and combat[p.index]~=nil or action=='walk' and active[p.index]~=nil end,
  stop=stop,stop_index=function(i) active[i]=nil;combat[i]=nil end,
  condition=function(_,c) return world[c['until']]==true,'saw '..c['until'] end,
  validate_condition=function(c) assert(type(c)=='table' and c['until'],'until must be one of') end,
}
local h=scheduler.handlers
local p=players[1]
local assertions=0
local function check(condition) assertions=assertions+1; assert(condition,'assertion '..assertions) end
local function tick()
  game.tick=game.tick+1
  for i,expiry in pairs(active) do if game.tick>=expiry then active[i]=nil end end
  for i,expiry in pairs(combat) do if game.tick>=expiry then combat[i]=nil end end
  scheduler.tick()
end
local q=h.queue_submit(p,{steps={{action='shoot',args={ticks=8},wait=false},{action='walk',args={ticks=3}},{action='craft'}}})
check(#q.pending==3)
tick(); check(combat[1] and active[1]); check(#calls==2)
tick(); tick(); check(#calls==2)
tick(); check(calls[3]=='craft'); check(combat[1]~=nil)
q=h.queue_status(p); check(#q.history==3 and not q.active)
-- Edit only pending steps and reject stale revisions before side effects.
q=h.queue_submit(p,{steps={{action='wait_ticks',args={ticks=10}},{action='craft'}}})
tick(); q=h.queue_status(p)
local revision=q.revision
check(not pcall(h.queue_edit,p,{expected_revision=revision-1,index=1,remove=1,steps={}}))
check(h.queue_status(p).active.action=='wait_ticks')
q=h.queue_edit(p,{expected_revision=revision,index=1,remove=1,steps={{action='walk'}}})
check(#q.pending==1 and q.pending[1].action=='walk')
q=h.queue_cancel(p,{clear=false})
-- A relative step (wait N ticks) is not requeued: it would repeat itself.
check(q.paused and not q.active and #q.pending==1)
check(not q.history[#q.history].result.requeued)
check(not active[1] and not combat[1])
tick(); check(not active[1])
h.queue_resume(p,{}); tick(); check(active[1]~=nil)
h.queue_cancel(p,{})
-- A failed step pauses, leaves later work untouched, and records evidence.
h.queue_submit(p,{steps={{action='broken'},{action='craft'}}})
tick(); q=h.queue_status(p)
check(q.paused and #q.pending==1)
check(q.history[#q.history].ok==false)
check(q.history[#q.history].result.reason:find('fixture failure')~=nil)
h.queue_cancel(p,{})
-- Instant work is bounded per tick.
local steps={}; for i=1,10 do steps[i]={action='craft'} end
h.queue_submit(p,{steps=steps});tick();q=h.queue_status(p)
check(#q.pending==6)
-- Invalid whole plans must not partially append.
local count=#q.pending
check(not pcall(h.queue_submit,p,{steps={{action='craft'},{action='unknown'}}}))
check(#h.queue_status(p).pending==count)
check(not pcall(h.queue_submit,p,{steps={{action='queue_submit'}}}))
check(not pcall(h.queue_submit,p,{steps={{action='wait_ticks',args={ticks=-1}}}}))
-- Death/disappearance pauses instead of continuing mutations.
players[1]=nil;tick();check(h.queue_status(p).paused)
-- Large blueprint-like payloads are bounded across successive submissions.
h.queue_cancel(p,{})
h.queue_submit(p,{steps={{action='craft',args={payload=string.rep('x',600000)}}}})
check(not pcall(h.queue_submit,p,{steps={{action='craft',args={payload=string.rep('x',600000)}}}}))
check(#h.queue_status(p).pending==1)
players[1]=p
h.queue_cancel(p,{})
local before=#calls
h.queue_repeat(p,{steps={{action='craft'}},interval_ticks=60})
for _=1,65 do tick() end
q=h.queue_status(p)
check(q.repeating and q.cycle==2 and #calls==before+2)
h.queue_cancel(p,{clear=false})
for _=1,70 do tick() end
check(#calls==before+2 and h.queue_status(p).repeating)
h.queue_resume(p,{}); tick(); check(#calls==before+3)
-- A runtime replacement leaves a loop resting between cycles scheduled,
-- but pauses one with work under way.
tick(); check(not h.queue_status(p).paused)
scheduler.pause_all(); check(not h.queue_status(p).paused)
h.queue_submit(p,{steps={{action='walk',args={ticks=30}}}}); tick()
scheduler.pause_all(); check(h.queue_status(p).paused)
h.queue_resume(p,{})
h.queue_cancel(p,{})
check(not h.queue_status(p).repeating)
h.queue_repeat(p,{steps={{action='broken'},{action='craft'}},interval_ticks=60})
tick(); check(h.queue_status(p).paused)
before=#calls
for _=1,70 do tick() end
check(#calls==before)
h.queue_submit(p,{mode='replace',steps={}})
check(not h.queue_status(p).repeating)
-- wait_until finishes when its condition holds and fails on timeout.
h.queue_cancel(p,{}); calls={}
h.queue_submit(p,{steps={{action='wait_until',args={['until']='clear',timeout=50}},{action='craft'}}})
tick(); tick(); check(h.queue_status(p).waiting.condition['until']=='clear'); check(#calls==0)
world.clear=true; for _=1,10 do tick() end
check(calls[1]=='craft'); check(h.queue_status(p).history[#h.queue_status(p).history-1].result.outcome=='met')
world.clear=false
h.queue_submit(p,{steps={{action='wait_until',args={['until']='clear',timeout=20}},{action='craft'}}})
for _=1,40 do tick() end
q=h.queue_status(p); check(q.paused); check(q.last_failure.result.outcome=='timed_out'); check(#q.pending==1)
check(not pcall(h.queue_submit,p,{steps={{action='wait_until',args={}}}}))
check(not pcall(h.queue_submit,p,{steps={{action='craft',on_fail='retry'}}}))
-- on_fail: skip continues, goto drops pending steps up to the label.
h.queue_cancel(p,{}); calls={}
h.queue_submit(p,{steps={{action='broken',on_fail='skip'},{action='craft'}}})
tick(); check(calls[1]=='craft'); check(not h.queue_status(p).paused)
calls={}
h.queue_submit(p,{steps={{action='broken',on_fail='goto:out'},{action='walk'},{action='craft',label='out'}}})
tick(); check(calls[1]=='craft' and #calls==1)
h.queue_submit(p,{steps={{action='broken',on_fail='goto:nowhere'},{action='craft'}}})
tick(); q=h.queue_status(p); check(q.paused); check(q.last_failure.result.goto_error~=nil)
-- A guard interrupts the running step once and runs its reaction.
h.queue_cancel(p,{}); calls={}; world.hurt=false
h.queue_submit(p,{guards={{when={['until']='hurt'},steps={{action='craft'}}}},
  steps={{action='walk',args={ticks=500}},{action='walk',args={ticks=5}}}})
tick(); check(active[1]~=nil)
world.hurt=true
for _=1,12 do tick() end
q=h.queue_status(p)
check(calls[#calls]=='craft'); check(#q.pending==0); check(q.guards==nil)
local fired=false
for _,entry in ipairs(q.history) do if entry.action=='guard' then fired=true end end
check(fired)
check(not pcall(h.queue_submit,p,{guards={{when={['until']='hurt'},['goto']='a',steps={}}},steps={}}))
print('scheduler: '..assertions..' assertions passed')
