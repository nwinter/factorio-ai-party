-- Run from repository root: lua tests/d26_batch251.lua
-- d26 batch251 GL (Sol #2466: queue_submit {dry_run: true, lane: "remote", mode: "append"} took a wait_ticks step with
-- on_fail goto:missing-label, and an Asterion draft dry run at tick 68087211 passed with step 11's
-- goto:sink-source-stop on no step; at run time a goto that finds no pending step of its label pauses the queue).
-- Every on_fail goto and guard goto is checked against the steps that can be pending when it runs, at submit and in
-- the dry run alike (one check), in queue_repeat, queue_edit (inserts, removals, moves, guards) and order_set; each
-- refusal names the step path, the label and the labels there are.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(type(s)=='string' and s:find(x,1,true),tostring(s)..'\n  lacks: '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok,'refused: '..text); has(tostring(err),text); return tostring(err) end
game={tick=1000}
local st={}
local sol={index=1,name='sol',valid=true,position={x=0,y=0},surface={name='nauvis'},force={name='player'}}
local ran={}
local base={state=function() return st end,player=function() return sol end,
  handlers={platform_schedule=function(_,a) ran[#ran+1]=a.current; return {ok=true} end},
  condition=function() return false,'not yet' end,wait_check=function() return false,'not yet' end,
  validate_condition=function(c) assert(type(c)=='table' and type(c['until'])=='string','until is required') end,
  busy=function() return false end,stop=function() end,stop_index=function() end}
local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
local body=factory(base)
local S=dofile('mod/agent-harness_0.1.0/queue_lanes.lua'){scheduler=body,factory=factory,base=base,is_read=function() return false end}
local H=S.handlers
local function w(ticks,label,on_fail) return {action='wait_ticks',args={ticks=ticks},label=label,on_fail=on_fail} end
-- the same refusal from the dry run and the submit
local function both(a,text)
  local d=a; d.dry_run=true
  local e1=fails(function() H.queue_submit(sol,d) end,text)
  d.dry_run=nil
  local e2=fails(function() H.queue_submit(sol,d) end,text)
  eq(e1,e2,'the dry run and the submit refuse alike')
  return e1
end

-- 1. Sol's case: the remote lane, append, one step whose goto names no label
local e=both({lane='remote',mode='append',steps={w(1,nil,'goto:missing-label')}},
  'steps[1] (wait_ticks): on_fail goto:missing-label names no step after it (a goto continues at the first pending step of that label after the failed one): missing-label labels no step of the plan; labels after it: none')

-- 2. the Asterion draft's shape: step 11's goto names a label no step has; the labels there are are listed
local draft={}
for i=1,12 do draft[i]=w(60,({'depart','burn','coast','arrive'})[i] or (i==12 and 'sink-stop' or nil)) end
draft[11].on_fail='goto:sink-source-stop'
both({lane='platform:Asterion',steps=draft},'steps[11] (wait_ticks): on_fail goto:sink-source-stop names no step after it')
both({lane='platform:Asterion',steps=draft},'sink-source-stop labels no step of the plan; labels after it: sink-stop')
-- fixed, it is taken, dry run and submit
draft[11].on_fail='goto:sink-stop'
eq(H.queue_submit(sol,{lane='platform:Asterion',steps=draft,dry_run=true}).steps,12)
H.queue_submit(sol,{lane='platform:Asterion',steps=draft})

-- 3. a goto back to a step that has run by then; several at once, each named
e=both({lane='remote',mode='replace',steps={w(5,'start'),w(5,nil,'goto:start'),w(5,'end'),w(5,nil,'goto:nope')}},
  'steps[2] (wait_ticks): on_fail goto:start names no step after it')
has(e,'start is on steps[1] (wait_ticks, label "start"), before it, which has run by then; labels after it: end')
has(e,' | steps[4] (wait_ticks): on_fail goto:nope')

-- 4. guards: a goto to no step refused; to a step of the plan, or of another guard's steps, taken
local when={['until']='platform_hit',platform='Asterion'}
e=both({lane='remote',mode='replace',steps={w(5,'a'),w(5,'b')},guards={{when=when,['goto']='home'}}},
  'guards[1]: goto home names no step of the queue (a guard\'s goto continues at the first pending step of that label when it fires); labels of the plan, the steps pending and the loop: a, b')
H.queue_submit(sol,{lane='remote',mode='replace',steps={w(5,'a'),w(5,'home')},guards={{when=when,['goto']='home'}},dry_run=true})
H.queue_submit(sol,{lane='remote',mode='replace',steps={w(5,'a')},guards={{when=when,steps={w(5,'retreat')}},{when=when,['goto']='retreat'}},dry_run=true})
e=both({lane='remote',mode='replace',steps={w(5,'a')},guards={{when=when,steps={w(5,'retreat')}},{when=when,['goto']='nowhere'}}},'guards[2]: goto nowhere')
has(e,'; of the guards\' steps: retreat')

-- 5. a guard's replacement steps on their own: their gotos within them, not the plan's labels
both({lane='remote',mode='replace',steps={w(5,'home')},guards={{when=when,steps={w(5,nil,'goto:home'),w(5)}}}},
  'guards[1].steps[1] (wait_ticks): on_fail goto:home names no step after it')
H.queue_submit(sol,{lane='remote',mode='replace',steps={w(5)},guards={{when=when,steps={w(5,nil,'goto:back'),w(5,'back')}}},dry_run=true})

-- 6. the modes against the queue: next and ahead put the new steps before the pending ones (their labels count);
-- append puts them after (the pending steps have run by then), but a guard reaches them
H.queue_cancel(sol,{lane='remote'})
H.queue_submit(sol,{lane='remote',steps={w(50000),w(5,'later')},start=false})
H.queue_submit(sol,{lane='remote',mode='next',steps={w(5,nil,'goto:later')},dry_run=true})
H.queue_submit(sol,{lane='remote',mode='ahead',steps={w(5,nil,'goto:later')},dry_run=true})
both({lane='remote',mode='append',steps={w(5,nil,'goto:later')}},'steps[1] (wait_ticks): on_fail goto:later names no step after it')
H.queue_submit(sol,{lane='remote',mode='append',steps={w(5)},guards={{when=when,['goto']='later'}},dry_run=true})
-- replace drops them: the guard's goto then has nothing
both({lane='remote',mode='replace',steps={w(5)},guards={{when=when,['goto']='later'}}},'guards[1]: goto later names no step of the queue')
-- (a mode the submit refuses, the dry run refuses too)
both({lane='remote',mode='bogus',steps={w(5)}},'mode must be append, replace, ahead, next or pending')

-- 7. queue_repeat: a round's gotos within the round
fails(function() H.queue_repeat(sol,{lane='remote',steps={w(60,'top'),w(60,nil,'goto:top')}}) end,'steps[2] (wait_ticks): on_fail goto:top names no step after it')
H.queue_repeat(sol,{lane='remote',steps={w(60,nil,'goto:tail'),w(60,'tail')}})

-- 8. queue_edit: an inserted step, a removal or a move that leaves a goto without its label, a new guard's goto
H.queue_cancel(sol,{lane='remote'})
H.queue_submit(sol,{lane='remote',steps={w(50000),w(5,nil,'goto:out'),w(5),w(5,'out')},start=false})
local q=st.remote_queues[1]
local rev=q.revision
fails(function() H.queue_edit(sol,{lane='remote',expected_revision=rev,index=1,remove=0,steps={w(5,nil,'goto:none')}}) end,
  'steps[1] (wait_ticks): on_fail goto:none names no step after it')
local job=q.pending[2].id
e=fails(function() H.queue_edit(sol,{lane='remote',expected_revision=rev,index=4,remove=1,steps={}}) end,'on_fail goto:out names no step after it')
has(e,'pending[2] '..job..' (wait_ticks): on_fail goto:out'); has(e,'labels after it once edited: none')
fails(function() H.queue_edit(sol,{lane='remote',id=q.pending[4].id,to=1}) end,'pending[3] '..job..' (wait_ticks): on_fail goto:out names no step after it')
fails(function() H.queue_edit(sol,{lane='remote',expected_revision=rev,guards={add={{when=when,['goto']='missing'}}}}) end,'a new guard (new): goto missing names no step of the queue')
fails(function() H.queue_edit(sol,{lane='remote',expected_revision=rev,guards={add={{when=when,steps={w(5,nil,'goto:x')}}}}}) end,'guards.add[1].steps[1] (wait_ticks): on_fail goto:x names no step after it')
local r=H.queue_edit(sol,{lane='remote',expected_revision=rev,guards={add={{when=when,['goto']='out'}}}})
eq(#r.guards,1)
-- a removal that takes the guard's label is refused; one that leaves it is taken
rev=H.queue_status(sol,{lane='remote'}).revision
fails(function() H.queue_edit(sol,{lane='remote',expected_revision=rev,index=2,remove=3,steps={}}) end,'guard-1 after this edit: goto out names no step of the queue')
H.queue_edit(sol,{lane='remote',expected_revision=rev,index=3,remove=1,steps={}})
eq(#st.remote_queues[1].pending,3,'the step removed')

-- 9. order_set's steps (scheduler validate): their gotos within them
fails(function() body.validate({steps={w(5,nil,'goto:x'),w(5)}}) end,'steps[1] (wait_ticks): on_fail goto:x names no step after it')
body.validate({steps={w(5,nil,'goto:x'),w(5,'x')}})
print('d26_batch251 GL goto labels checked at submit, dry run, repeat, edit and orders: ok')
