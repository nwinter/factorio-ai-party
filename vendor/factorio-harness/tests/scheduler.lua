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
-- Changing calls return only the newest 3 entries (shake3: Opus's queue cancel
-- printed 60+); so does queue_status (Sol 10:50: a long done history hid the
-- stalled step), with history: N or 'all' for more.
h.queue_submit(p,{steps={{action='craft'}}}); tick()
-- (round2250a, Grok: the plan last submitted by default; an empty submit starts no plan)
q=h.queue_submit(p,{steps={},start=false}); check(#q.history==1 and q.history_total==4 and q.history[1].action=='craft' and q.plan.id==2 and q.plan.done==1)
check(#h.queue_status(p).history==1 and h.queue_status(p).history_total==4 and h.queue_status(p).history[1].action=='craft')
check(#h.queue_status(p,{orders=true,history='all'}).history==4 and #h.queue_status(p,{orders=true}).history==3 and #h.queue_status(p,{history=1}).history==1)
check(h.queue_status(p,{history=1}).history[1].action=='craft' and #h.queue_status(p,{history=0}).history==0)
check(not pcall(h.queue_status,p,{history=-1}) and not pcall(h.queue_status,p,{history=65}) and not pcall(h.queue_status,p,{pending='some'}))
check(not pcall(h.queue_status,p,{orders='yes'}))
-- Edit only pending steps and reject stale revisions before side effects.
q=h.queue_submit(p,{steps={{action='wait_ticks',args={ticks=10}},{action='craft'}}})
tick(); q=h.queue_status(p)
local revision=q.revision
check(not pcall(h.queue_edit,p,{expected_revision=revision-1,index=1,remove=1,steps={}}))
-- The active step in full with how long it has run; the next step; the count.
check(h.queue_status(p).active.action=='wait_ticks' and h.queue_status(p).active.args.ticks==10)
tick(); check(h.queue_status(p).active.running_s==0)
check(h.queue_status(p).pending[1].action=='craft' and h.queue_status(p).pending_count==1)
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
check(q.pending_count==6 and #q.pending==1 and #h.queue_status(p,{pending='all'}).pending==6 and #h.queue_status(p,{pending=2}).pending==2)
-- Invalid whole plans must not partially append.
local count=q.pending_count
check(not pcall(h.queue_submit,p,{steps={{action='craft'},{action='unknown'}}}))
check(h.queue_status(p).pending_count==count)
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
h.queue_submit(p,{mode='append',steps={{action='walk',args={ticks=30}}}}); tick()
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
-- Couriers (shift08): a step that runs short with on_short=skip, or with up_to=true in its args, is done and the plan
-- goes on; without either, the same step pauses the plan as before.
do
  local cstate,busy_until,outcomes,ran={},{},{},{}
  local give_held
  local ch={
    give=function(_,a) ran[#ran+1]='give'; local n=give_held or a.held; if n==0 then error('no iron-plate in inventory; the target has 0',0) end; return {transferred=n} end,
    tour=function(pp,a) ran[#ran+1]='tour'; busy_until[pp.index]=game.tick+2; outcomes.tour=a.outcome; return {accepted=true} end,
    craft=function() ran[#ran+1]='craft'; return {started=1} end,
    other=function() error('entity is out of reach',0) end,
  }
  local cs=factory{state=function() return cstate end,player=function(i) return players[i] end,handlers=ch,
    busy=function(pp,action) return action=='tour' and busy_until[pp.index] and game.tick<busy_until[pp.index] end,
    outcome=function(_,action) return outcomes[action] end,stop=function() end,stop_index=function() end,
    condition=function() return false end,validate_condition=function() end}
  local function ctick() game.tick=game.tick+1; cs.tick() end
  local function run(steps) cstate.queues=nil; ran={}; cs.handlers.queue_submit(p,{steps=steps}); for _=1,8 do ctick() end return cs.handlers.queue_status(p) end
  local s=run({{action='give',args={held=0},on_short='skip'},{action='craft'}})
  check(not s.paused and ran[2]=='craft'); check(s.history[1].ok and s.history[1].result.short==true)
  s=run({{action='give',args={held=0}},{action='craft'}})
  check(s.paused and #ran==1 and not s.history[1].ok)
  -- a timed tour's out_of_items with up_to=true, and nothing_collected with on_short=skip, count as done
  s=run({{action='tour',args={outcome='out_of_items',up_to=true}},{action='craft'}})
  check(not s.paused and ran[2]=='craft' and s.history[1].result.short==true and s.history[1].result.outcome=='out_of_items')
  s=run({{action='tour',args={outcome='nothing_collected'},on_short='skip'},{action='craft'}})
  check(not s.paused and ran[2]=='craft')
  s=run({{action='tour',args={outcome='out_of_items'}},{action='craft'}})
  check(s.paused and #ran==1)
  -- other failures still pause; a timed_out tour is not short
  s=run({{action='other',on_short='skip'},{action='craft'}})
  check(s.paused and #ran==0)
  s=run({{action='tour',args={outcome='timed_out',up_to=true}},{action='craft'}})
  check(s.paused)
  check(not pcall(cs.handlers.queue_submit,p,{steps={{action='craft',on_short='retry'}}}))
  -- A repeating plan's round with short steps is one grouped line for the team block (Opus), only when it changed.
  -- Shorts the plan allowed for (up_to=true, on_short=skip) stay out of it (Grok, shift10); on_fail=skip does not allow one.
  cstate.queues=nil; ran={}
  cs.handlers.queue_repeat(p,{name='loop3',interval_ticks=60,steps={
    {action='give',args={held=0,item='iron-plate'},on_fail='skip'},{action='give',args={held=0,item='iron-plate'},on_fail='skip'},
    {action='tour',args={outcome='nothing_collected',item='coal'},on_fail='skip'},
    {action='give',args={held=0,item='copper-plate'},on_short='skip'},
    {action='tour',args={outcome='nothing_collected',item='stone',up_to=true}},{action='craft'}}})
  for _=1,12 do ctick() end
  local lines=cs.round_news(1)
  check(lines and #lines==1); check(lines[1]=='queue loop3 round 1: 3 of 6 steps short: give iron-plate none_held x2, tour coal nothing_collected')
  check(cs.round_news(1)==nil)
  local h=cs.handlers.queue_status(p,{history='all'}).history
  check(h[4].action=='give' and h[4].ok and h[4].result.short==true) -- the allowed short is still in the history
  check(h[5].action=='tour' and h[5].ok and h[5].result.short==true)
  for _=1,70 do ctick() end
  check(cs.handlers.queue_status(p).cycle==2); check(cs.round_news(1)==nil) -- the same round again says nothing
  give_held=5
  for _=1,70 do ctick() end
  check(cs.handlers.queue_status(p).cycle==3)
  lines=cs.round_news(1)
  check(lines and lines[1]=='queue loop3 round 3: 1 of 6 steps short: tour coal nothing_collected')
  give_held=nil
  -- A loop whose only shorts are allowed puts no line in the team block, round after round.
  cstate.queues=nil; ran={}
  cs.handlers.queue_repeat(p,{name='bricks',interval_ticks=60,steps={
    {action='give',args={held=0,item='stone-brick'},on_short='skip'},
    {action='tour',args={outcome='out_of_items',item='stone-brick',up_to=true}},{action='craft'}}})
  for _=1,300 do ctick() end
  check(cs.handlers.queue_status(p).cycle>=4); check(cs.round_news(1)==nil)
  check(not pcall(cs.handlers.queue_repeat,p,{name=string.rep('x',40),steps={{action='craft'}}}))
end
-- A loop with an end (Muse, 21:20: provider-to-furnace refills, ~10 a night): times rounds, or no round starting at or
-- after for_ticks from the call; a round under way finishes; the queue is left empty and free, with a loop_done history
-- entry, queue_status loop_done and one team block line.
do
  local lstate,lcalls={},0
  local ls=factory{state=function() return lstate end,player=function(i) return players[i] end,
    handlers={craft=function() lcalls=lcalls+1; return {started=1} end,walk=handlers.walk},
    busy=function(pp,action) return action=='walk' and active[pp.index]~=nil end,stop=stop,stop_index=function(i) active[i]=nil end,
    condition=function() return false end,validate_condition=function() end}
  local lh=ls.handlers
  local function ltick(n) for _=1,n or 1 do tick(); ls.tick() end end
  local r=lh.queue_repeat(p,{name='refill',times=3,interval_ticks=60,steps={{action='craft'}}})
  check(r.repeating and r.times==3 and r.rounds_left==2)
  ltick(70); r=lh.queue_status(p); check(r.cycle==2 and r.rounds_left==1 and lcalls==2)
  ltick(200); r=lh.queue_status(p,{history='all'})
  check(lcalls==3 and not r.repeating and r.times==nil and r.pending_count==0)
  check(r.loop_done.rounds==3 and r.loop_done.name=='refill' and r.loop_done.reason=='3 of 3 rounds run (times 3)')
  local last=r.history[#r.history]
  check(last.action=='loop_done' and last.ok and last.result.rounds==3)
  check(ls.free(1))
  local lines=ls.round_news(1)
  check(lines and lines[#lines]=='queue refill done after 3 rounds: 3 of 3 rounds run (times 3)')
  -- for_ticks 150, a round every 60 ticks: rounds start at +1, +62, +123; the next would start at +184, so it ends.
  lcalls=0
  local start=game.tick
  r=lh.queue_repeat(p,{for_ticks=150,interval_ticks=60,steps={{action='craft'}}})
  check(r.stops_tick==start+150 and r.times==nil)
  ltick(300); r=lh.queue_status(p)
  check(lcalls==3 and not r.repeating and r.loop_done.rounds==3)
  check(r.loop_done.reason==string.format('no round starts at or after tick %d (for_ticks 150)',start+150))
  check(ls.round_news(1)[1]:find('^queue done after 3 rounds: ')~=nil)
  -- A round under way when the time passes finishes.
  lcalls=0
  lh.queue_repeat(p,{for_ticks=60,interval_ticks=60,steps={{action='walk',args={ticks=100}},{action='craft'}}})
  ltick(90); check(lh.queue_status(p).repeating and lcalls==0)
  ltick(40); r=lh.queue_status(p); check(lcalls==1 and not r.repeating and r.loop_done.rounds==1)
  -- times and for_ticks together: the first to come ends it.
  lcalls=0
  lh.queue_repeat(p,{times=2,for_ticks=6000,interval_ticks=60,steps={{action='craft'}}})
  ltick(200); check(lcalls==2 and lh.queue_status(p).loop_done.reason=='2 of 2 rounds run (times 2)')
  -- Refusals; a cancel removes the loop and its end; a new loop clears the last loop_done.
  check(not pcall(lh.queue_repeat,p,{times=0,steps={{action='craft'}}}))
  check(not pcall(lh.queue_repeat,p,{times=1.5,steps={{action='craft'}}}))
  check(not pcall(lh.queue_repeat,p,{for_ticks=30,steps={{action='craft'}}}))
  check(not pcall(lh.queue_repeat,p,{for_ticks=500000,steps={{action='craft'}}}))
  r=lh.queue_repeat(p,{times=5,interval_ticks=60,steps={{action='craft'}}})
  check(r.loop_done==nil and r.times==5)
  r=lh.queue_cancel(p,{}); check(not r.repeating and r.times==nil and r.stops_tick==nil)
  -- Without times or for_ticks a loop runs on as before.
  lcalls=0
  lh.queue_repeat(p,{interval_ticks=60,steps={{action='craft'}}})
  ltick(400); r=lh.queue_status(p); check(r.repeating and lcalls>=6 and r.times==nil and r.rounds_left==nil)
  lh.queue_cancel(p,{})
end
-- Grok, shift14 22:50: queue status showed hours of standing-order history, and a finished pickup plan read as a
-- failure (an order's interrupted transfer was last_failure). By default: the plan last submitted, its entries and a
-- summary; the orders' entries counted; orders=true lists every entry as before.
do
  h.queue_cancel(p,{})
  for _=1,10 do tick() end
  h.queue_submit(p,{steps={{action='craft',label='pick'},{action='craft',label='carry'}}})
  for _=1,4 do tick() end
  local s=h.queue_status(p)
  check(s.plan and s.plan.steps==2 and s.plan.done==2 and s.plan.ok==2 and s.plan.failed==0 and s.plan.pending==0 and s.plan.kind=='submit')
  -- a standing order runs after it, and fails
  scheduler.run_order(1,'adv-free',{{action='broken'},{action='craft'}},'routine')
  for _=1,4 do tick() end
  s=h.queue_status(p)
  check(#s.history==2 and s.history[1].label=='pick' and s.history[2].label=='carry' and s.last_failure==nil)
  check(s.orders_history and s.orders_history:find('^%d+ entries from standing orders left out') ~= nil)
  local all=h.queue_status(p,{orders=true,history='all'})
  local seen_order=false
  for _,e in ipairs(all.history) do if e.order=='adv-free' then seen_order=true end end
  check(seen_order and all.last_failure and all.last_failure.order=='adv-free' and all.orders_history==nil)
  -- a new plan replaces the view; the old plan's entries stay in orders=true
  h.queue_cancel(p,{})
  h.queue_submit(p,{steps={{action='craft',label='next'}}})
  for _=1,3 do tick() end
  s=h.queue_status(p)
  check(#s.history==1 and s.history[1].label=='next' and s.plan.id>1)
  -- a repeating plan's rounds stay in its plan
  h.queue_cancel(p,{})
  h.queue_repeat(p,{interval_ticks=60,times=2,steps={{action='craft',label='round'}}})
  for _=1,200 do tick() end
  s=h.queue_status(p)
  local rounds=0
  for _,e in ipairs(s.history) do if e.label=='round' then rounds=rounds+1 end end
  check(rounds==2 and s.plan.kind=='repeat' and s.history[#s.history].action=='loop_done')
  h.queue_cancel(p,{})
end
-- friction6: validation identifies the step/action/label and nested guard path, without changing the queue.
do
  local state={}
  local s=factory{state=function() return state end,handlers=handlers,stop=function() end,
    check_args=function(_,a) assert(not (a and a.on_short),'unknown argument on_short') end,
    validate_condition=function(c) assert(c and c['until']=='ready','until must be ready') end,
    fix_args=function(action,a) if a and a.ticks_alias then return action,{ticks=a.ticks_alias},nil end return action,a end}
  local h=s.handlers
  h.queue_submit(p,{steps={{action='craft'}},start=false})
  local before=h.queue_status(p).revision
  local function bad(a,needle)
    local ok,err=pcall(h.queue_submit,p,a)
    assert(not ok and tostring(err):find(needle,1,true),tostring(err))
    assert(h.queue_status(p).revision==before and h.queue_status(p).pending_count==1)
  end
  bad({steps={{action='craft'},{action='inspect',label='checkpoint'}}},'steps[2] (inspect, label "checkpoint"): action is not queueable')
  bad({steps={{action='craft',args={on_short='skip'}}}},'steps[1] (craft): args: unknown argument on_short')
  bad({steps={{action='craft',label=string.rep('x',65)}}},'label must be a string of at most 64 bytes')
  bad({steps={{action='craft',label=string.rep('箱',22)}}},'label 66 bytes')
  bad({steps={},guards={{when={['until']='bad'}}}},'guards[1]: when: until must be ready')
  bad({steps={},guards={{when={['until']='ready'},steps={{action='inspect'}}}}},'guards[1]: steps[1] (inspect)')
  local ok,err=pcall(h.queue_repeat,p,{condition={['until']='bad'},steps={{action='craft'}}})
  assert(not ok and tostring(err):find('condition: until must be ready',1,true),tostring(err))
  assert(h.queue_status(p).revision==before and h.queue_status(p).pending_count==1)
  local q=h.queue_submit(p,{steps={{action='wait_ticks',args={ticks_alias=5}}}})
  assert(q.pending[2].args.ticks==5,'validation uses the normalized args')
end

-- Round 00:20: explicit queue precedence and condition-ended carry rounds.
do
  h.queue_repeat(p,{name='plate-haul',interval_ticks=60,steps={{action='wait_until',args={['until']='stock',timeout=500}},{action='craft'}}})
  tick()
  local revision=h.queue_status(p).revision
  local ok,err=pcall(h.queue_submit,p,{steps={{action='craft'}}})
  check(not ok and err:find('plate-haul',1,true) and err:find('mode="ahead"',1,true))
  check(h.queue_status(p).revision==revision and h.queue_status(p).active.action=='wait_until')
  local out=h.queue_submit(p,{mode='ahead',steps={{action='craft',label='urgent'}}})
  check(out.repeating and out.repeat_name=='plate-haul' and out.pending[1].label=='urgent' and out.pending[2].action=='wait_until')
  tick(); check(h.queue_status(p).active.action=='wait_until')
  check(h.queue_status(p).history[1].label=='urgent')
  out=h.queue_submit(p,{mode='replace',steps={{action='craft',label='replacement'}}})
  check(not out.repeating and not out.active and #out.pending==1 and out.submission:find('stopped and replaced',1,true))
  tick(); check(h.queue_status(p).history[1].label=='replacement')
  h.queue_repeat(p,{name='relative',steps={{action='wait_ticks',args={ticks=50}}}}); tick()
  revision=h.queue_status(p).revision
  check(not pcall(h.queue_submit,p,{mode='ahead',steps={{action='craft'}}}))
  check(h.queue_status(p).revision==revision and h.queue_status(p).active.action=='wait_ticks')
  h.queue_cancel(p,{})
  world.stock=true
  out=h.queue_repeat(p,{condition={['until']='stock'},steps={{action='craft'}}})
  check(not out.repeating and #out.pending==0 and out.loop_done.rounds==0)
  world.stock=false
  h.queue_repeat(p,{name='carry',interval_ticks=60,condition={['until']='stock'},steps={{action='craft'}}})
  tick(); world.stock=true; tick()
  out=h.queue_status(p)
  check(not out.repeating and out.loop_done.rounds==1 and out.loop_done.reason=='condition met: saw stock')
  world.stock=false
  h.queue_repeat(p,{interval_ticks=60,condition={['until']='stock'},steps={{action='craft'}}})
  tick(); tick(); world.stock=true
  for _=1,70 do tick() end
  out=h.queue_status(p)
  check(not out.repeating and out.loop_done.rounds==1)
  check(not pcall(h.queue_repeat,p,{condition='stock',steps={{action='craft'}}}))
  h.queue_cancel(p,{})
end
print('scheduler: '..assertions..' assertions passed')
