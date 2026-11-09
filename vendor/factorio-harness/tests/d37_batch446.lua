-- Astra #2920: a damage hold must not replace a higher-priority critical-loss return.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn); eq(ok,false); has(e,x) end
local START=122311220
local function fixture(lane)
  game={tick=START}
  local state={active={}}; local p={index=1,name='astra'}; local calls={}; local stops=0
  local base={state=function() return state end,player=function() return p end,
    handlers={platform_schedule=function(_,a) calls[#calls+1]=a; return {} end},
    busy=function() return false end,stop=function() stops=stops+1 end,stop_index=function() end,
    validate_condition=function(c) assert(type(c)=='table') end,
    deadline=function(c) return c['until']=='tick_at_least' and c.tick or nil end,
    condition=function(_,c) return game.tick>=c.tick,c['until']=='platform_loss' and 'rail destroyed 15034' or 'damage 1184' end}
  local factory=require('scheduler'); local engine=factory(base)
  local q=require('queue_lanes'){scheduler=engine,factory=factory,base=base,is_read=function() return false end}
  local f={q=q,state=state,calls=calls}
  function f.call(name,a) a=a or {}; a.lane=lane; return q.handlers[name](p,a) end
  function f.status() return f.call('queue_status',{history='all',pending='all'}) end
  function f.tick(n) for _=1,n do game.tick=game.tick+1; q.tick() end end
  function f.stops() return stops end
  return f
end
local function reaction(hold,ticks)
  return {{action='platform_schedule',args={platform='Asterion',current=hold and 2 or 1,paused=hold}},
    {action='wait_ticks',args={ticks=ticks or 54000},label=hold and 'hold' or 'return'}}
end
local function guard(critical,priority,group)
  return {when={['until']=critical and 'platform_loss' or 'platform_damage',platform='Asterion',tick=START+(critical and 10 or 20)},
    priority=priority,exclusive_group=group,steps=reaction(not critical),scope='standing'}
end
local function submit(f,gs)
  return f.call('queue_submit',{steps={{action='wait_ticks',args={ticks=54000}}},guards=gs})
end
for _,lane in ipairs{'body','remote','platform:Asterion'} do
  local f=fixture(lane); local r=submit(f,{guard(true,100),guard(false,10)})
  eq(r.guards[1].priority,100); eq(r.guard_warnings,nil)
  f.tick(10); local s=f.status(); eq(s.guard_control.guard,'guard-1'); eq(s.guard_control.tick,122311230)
  has(s.guard_control.reason,'rail destroyed 15034'); eq(s.active.label,'return')
  local stopped=f.stops(); f.tick(10); s=f.status()
  eq(#f.calls,1); eq(f.calls[1].current,1); eq(f.stops(),stopped); eq(s.active.label,'return')
  eq(s.guard_control.priority,100); eq(#s.guard_suppressed,1)
  local suppressed=s.guard_suppressed[1]
  eq(suppressed.guard,'guard-2'); eq(suppressed.suppressed_by,'guard-1'); eq(suppressed.tick,122311240)
  eq(suppressed.control_tick,122311230); has(suppressed.reason,'rail destroyed 15034')
  eq(s.history[#s.history].action,'guard_suppressed'); eq(s.guards,nil)
  local brief=f.q.lanes(1); brief=lane=='body' and brief.body or lane=='remote' and brief.remote or brief.platforms.Asterion
  eq(brief.guard_control.guard,'guard-1'); eq(#brief.guard_suppressed,1)
  f.tick(30); eq(#f.status().guard_suppressed,1)
  -- Pausing/restarting a reaction preserves its control; explicit replacement releases it.
  f.call('queue_pause'); eq(f.status().guard_control.guard,'guard-1')
  f.call('queue_resume'); f.tick(1); eq(f.status().guard_control.guard,'guard-1')
  f.call('queue_submit',{mode='replace',steps={{action='wait_ticks',args={ticks=100}}}})
  eq(f.status().guard_control,nil)
  -- Unset/equal/higher priorities retain replacement, including a mixed opt-in plan.
  for _,ps in ipairs{{},{100,100},{10,100},{100},{false,10}} do
    f=fixture(lane); submit(f,{guard(true,ps[1] or nil),guard(false,ps[2])}); f.tick(20); s=f.status()
    eq(#f.calls,2); eq(f.calls[2].paused,true); eq(s.active.label,'hold'); eq(s.guard_suppressed,nil)
  end
  -- Explicit groups isolate comparisons within this lane; an ungrouped guard is lane-wide.
  for _,groups in ipairs{{'flight','flight'},{'flight','cargo'},{'flight'},{false,'flight'}} do
    f=fixture(lane); submit(f,{guard(true,100,groups[1] or nil),guard(false,10,groups[2])}); f.tick(20)
    eq(#f.calls,groups[2]=='cargo' and 2 or 1)
  end
  -- Abort-only guards cannot cancel an active higher-priority reaction either.
  f=fixture(lane); local low=guard(false,10); low.steps=nil
  submit(f,{guard(true,100),low}); f.tick(20); eq(f.status().paused,false); eq(f.status().active.label,'return')
  -- A completed reaction releases control; a standing guard can fire afterward.
  f=fixture(lane); local high=guard(true,100); high.steps=reaction(false,1)
  submit(f,{high,guard(false,10)}); f.tick(15); eq(f.status().guard_control,nil)
  f.tick(5); eq(#f.calls,2); eq(f.status().guard_suppressed,nil)
  -- Guard goto protects the chosen tail as well as explicit recovery steps.
  f=fixture(lane); high=guard(true,100); high.steps=nil; high['goto']='return'
  local tail=reaction(false); table.insert(tail,1,{action='wait_ticks',args={ticks=54000}})
  f.call('queue_submit',{steps=tail,guards={high,guard(false,10)}}); f.tick(20)
  eq(f.status().active.label,'return'); eq(#f.status().guard_suppressed,1)
  -- Dry runs do not create a queue; dry and submit return the same warning.
  f=fixture(lane); local a={steps={{action='wait_ticks',args={ticks=100}}},guards={guard(true),guard(false)},dry_run=true}
  r=f.call('queue_submit',a); eq(r.queued,false); has(r.guard_warnings[1],'potentially conflicting')
  eq(f.status().revision,0); a.dry_run=nil; r=f.call('queue_submit',a); has(r.guard_warnings[1],'no priorities set')
  r=f.call('queue_submit',{steps={},guards={guard(false)},dry_run=true}); assert(r.guard_warnings)
  r=f.call('queue_submit',{mode='replace',steps={},guards={guard(false)},dry_run=true}); eq(r.guard_warnings,nil)
  -- Identical actions and priorities are not reported as unprioritized conflicts.
  f=fixture(lane); r=submit(f,{guard(true),guard(true)}); eq(r.guard_warnings,nil)
  f=fixture(lane); submit(f,{guard(true,100)})
  f.call('queue_edit',{expected_revision=f.status().revision,guards={add={guard(false,10,'flight')}}})
  eq(f.status().guards[2].priority,10); eq(f.status().guards[2].exclusive_group,'flight')
  f.tick(20); eq(#f.status().guard_suppressed,1)
  for _,v in ipairs{'critical',false,math.huge,0/0} do
    local bad=guard(true,v); fails(function() submit(f,{bad}) end,'priority must be a finite number')
  end
  for _,v in ipairs{'',false,string.rep('a',65)} do
    fails(function() submit(f,{guard(true,1,v)}) end,'exclusive_group must be a string')
  end
  has(f.q.schema.guards.usage,'priority'); has(f.q.schema.guards.usage,'exclusive_group'); has(f.q.schema.queue_status.returns,'guard_control')
end
-- Same group names in separate lanes never share control.
local f=fixture('body'); submit(f,{guard(true,100,'flight')}); f.tick(10)
f.q.handlers.queue_submit({index=1},{lane='remote',steps={{action='wait_ticks',args={ticks=100}}},guards={guard(false,1,'flight')}})
f.tick(10); eq(#f.calls,2); eq(f.status().guard_control.priority,100)
print('batch446: priority suppression, legacy/equal behavior, groups/lanes, lifecycle, goto/abort, warnings and describe: ok')
