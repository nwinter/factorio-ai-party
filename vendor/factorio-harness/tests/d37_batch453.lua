-- Aurora: replacement, held recovery and runtime carry must retain guard policy/identity.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local failures,cases={},0
local function test(name,fn)
  cases=cases+1
  local ok,err=pcall(fn)
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function fixture(lane)
  game={tick=1000}; local state={active={}}; storage={agent_harness=state}
  local p={index=1,name='astra'}; local calls={}; local finished=false
  local base={state=function() return state end,player=function() return p end,
    handlers={platform_schedule=function(_,a)
      calls[#calls+1]=a.current
      return a.recheck and not finished and {recheck={}} or {}
    end},recheck_read=function() return false,{} end,
    busy=function() return false end,stop=function() end,stop_index=function() end,
    validate_condition=function(c) assert(type(c)=='table') end,
    deadline=function(c) return c['until']=='tick_at_least' and c.tick or nil end,
    condition=function(_,c) return game.tick>=c.tick,'read at '..game.tick end}
  local factory=require('scheduler'); local engine=factory(base)
  local q=require('queue_lanes'){scheduler=engine,factory=factory,base=base,is_read=function() return false end}
  local f={q=q,state=state,calls=calls}
  function f.finish_recheck() finished=true end
  function f.call(name,a) a=a or {}; a.lane=lane; return q.handlers[name](p,a) end
  function f.status() return f.call('queue_status',{history='all',pending='all'}) end
  function f.tick(n) for _=1,n do game.tick=game.tick+1; q.tick() end end
  function f.update()
    -- Incoming carry snapshots before outgoing stop_all pauses every lane.
    local carry=require('carry'){state=function() return state end}
    q.pause_all('harness update'); carry.carry()
  end
  return f
end
local function wait(ticks) return {action='wait_ticks',args={ticks=ticks or 500},label='recovery'} end
local function guard(tick,priority,group,steps)
  return {when={['until']='tick_at_least',tick=tick},priority=priority,exclusive_group=group,scope='standing',steps=steps or {wait()}}
end
local function submit(f,high,low)
  return f.call('queue_submit',{steps={wait()},guards={high,low}})
end
local function low(priority,group)
  return guard(1040,priority,group,{{action='platform_schedule',args={platform='Asterion',current=2}},wait()})
end
local function protected(f)
  local s=f.status()
  eq(#f.calls,0,'lower guard must not run'); eq(#(s.guard_suppressed or {}),1,'suppression')
  eq(s.guard_control.priority,100); eq(s.guard_control.exclusive_group,'flight')
  eq(s.guard_control.tick,1010); eq(s.guard_control.guard,'guard-1')
end
for _,lane in ipairs{'body','remote','platform:Asterion'} do
  for _,mode in ipairs{'explicit','omitted'} do
    test(lane..' replacement '..mode,function()
      local f=fixture(lane); submit(f,guard(1010,100,'flight'),low(10,'flight'))
      local r=guard(1010,mode=='explicit' and 100 or nil,mode=='explicit' and 'flight' or nil)
      r.id='guard-1'; r.scope=nil
      f.call('queue_edit',{expected_revision=f.status().revision,guards={replace={r}}})
      f.tick(40); protected(f)
      eq(f.status().active.label,'recovery')
    end)
  end
  test(lane..' replacement different group',function()
    local f=fixture(lane); submit(f,guard(1010,100,'flight'),low(10,'cargo'))
    local r=guard(1010,100,'flight'); r.id='guard-1'
    local s=f.call('queue_edit',{expected_revision=f.status().revision,guards={replace={r}}})
    eq(s.guards[1].priority,100); eq(s.guards[1].exclusive_group,'flight')
    f.tick(40); eq(#f.calls,1); eq(f.status().guard_suppressed,nil)
  end)
  test(lane..' replacement overrides and validates',function()
    local f=fixture(lane); submit(f,guard(1010,100,'flight'),low(10,'flight'))
    local r=guard(1010,0,'cargo'); r.id='guard-1'
    local s=f.call('queue_edit',{expected_revision=f.status().revision,guards={replace={r}}})
    eq(s.guards[1].priority,0); eq(s.guards[1].exclusive_group,'cargo')
    for _,bad in ipairs{{priority='high'},{priority=math.huge},{exclusive_group=''}} do
      local spec=guard(1010,0,'cargo'); spec.id='guard-1'
      for k,v in pairs(bad) do spec[k]=v end
      local rev=f.status().revision
      local ok=pcall(f.call,'queue_edit',{expected_revision=rev,guards={replace={spec}}})
      eq(ok,false,'invalid replacement'); eq(f.status().revision,rev,'atomic refusal')
      eq(f.status().guards[1].priority,0); eq(f.status().guards[1].exclusive_group,'cargo')
    end
  end)
  for _,resume in ipairs{false,true} do
    test(lane..' timeout hold/resume '..tostring(resume),function()
      local f=fixture(lane)
      local step={action='wait_until',args={['until']='platform_arrived',platform='Asterion',tick=2000,timeout=10,on_timeout='hold'},label='recovery'}
      submit(f,guard(1010,100,'flight',{step}),low(10,'flight')); f.tick(10)
      local run=f.status().active.guard_run
      f.tick(11); local s=f.status(); eq(s.paused,true); eq(s.pending[1].guard_run,run,'held recovery identity')
      eq(s.guard_control.run,run)
      if resume then
        f.call('queue_resume'); f.tick(1)
        eq(f.status().active.guard_run,run,'resumed recovery identity')
        eq(f.status().active.until_tick,1032,'fresh timeout')
      end
      f.tick(1040-game.tick)
      -- Body guards wait for resume; remote deadline guards also run while held.
      if lane=='body' then f.call('queue_resume'); f.tick(10) end
      protected(f)
    end)
  end
  for _,kind in ipairs{'pending','wait_ticks','wait_until','restart','held'} do
    test(lane..' hot update '..kind,function()
      local f=fixture(lane); local step=wait()
      if kind=='wait_until' or kind=='held' then
        step={action='wait_until',args={['until']='platform_arrived',platform='Asterion',tick=2000,timeout=kind=='held' and 10 or 500,on_timeout='hold'}}
      end
      if kind=='restart' then step={action='platform_schedule',args={platform='Asterion',current=1,recheck=true},label='recovery'} end
      submit(f,guard(1010,100,'flight',{step}),low(10,'flight')); f.tick(10)
      local run=f.status().active.guard_run
      if kind=='pending' then f.call('queue_pause'); f.call('queue_resume') end
      if kind=='held' then f.tick(11) end
      local before=f.status(); local control=before.guard_control
      f.update(); local s=f.status()
      eq(s.guard_control and s.guard_control.run,run,'carried recovery identity')
      eq(s.guard_control.tick,control.tick); eq(s.guard_control.reason,control.reason)
      eq((s.active or s.pending[1]).guard_run,run)
      eq(#s.history,#before.history,'no spurious interruption')
      if kind=='held' then eq(s.paused,true); f.call('queue_resume') else eq(s.paused,false) end
      if kind=='wait_ticks' or kind=='wait_until' then eq(s.active.until_tick,before.active.until_tick) end
      f.tick(1040-game.tick)
      if lane=='body' and kind=='held' then f.call('queue_resume'); f.tick(10) end
      eq(#(f.status().guard_suppressed or {}),1,'low guard suppressed after carry')
      for _,current in ipairs(f.calls) do eq(current,1,'no lower schedule after carry') end
    end)
  end
  test(lane..' held recovery completes and releases control',function()
    local f=fixture(lane)
    local step={action='wait_until',args={['until']='platform_arrived',platform='Asterion',tick=1030,timeout=10,on_timeout='hold'}}
    submit(f,guard(1010,100,'flight',{step}),low(10,'flight'))
    f.tick(21); eq(f.status().paused,true); eq(f.status().guard_control.priority,100)
    f.update(); f.call('queue_resume'); f.tick(12)
    eq(f.status().guard_control,nil,'completed reaction releases control')
    f.tick(7); eq(#f.calls,1); eq(f.status().guard_suppressed,nil)
  end)
  test(lane..' restarted recovery completes and releases control',function()
    local f=fixture(lane)
    local step={action='platform_schedule',args={platform='Asterion',current=1,recheck=true}}
    submit(f,guard(1010,100,'flight',{step}),low(10,'flight')); f.tick(10)
    f.update(); eq(f.status().guard_control.priority,100)
    -- End the simulated schedule recheck on its restart, before the next guard fires.
    f.finish_recheck()
    f.tick(1); eq(f.status().guard_control,nil,'finished restart releases control')
    f.tick(29); eq(f.calls[#f.calls],2); eq(f.status().guard_suppressed,nil)
  end)
  test(lane..' legacy replacement/hold/update',function()
    local f=fixture(lane)
    local step={action='wait_until',args={['until']='platform_arrived',platform='Asterion',tick=2000,timeout=10,on_timeout='hold'}}
    submit(f,guard(1010,nil,nil,{step}),low(nil,nil))
    local r=guard(1010,nil,nil,{step}); r.id='guard-1'
    f.call('queue_edit',{expected_revision=f.status().revision,guards={replace={r}}})
    f.tick(21); f.update(); eq(f.status().paused,true); eq(f.status().guard_control,nil)
    f.call('queue_resume'); f.tick(20)
    if lane=='body' then f.call('queue_resume'); f.tick(10) end
    eq(#f.calls,1); eq(f.status().guard_suppressed,nil)
  end)
end
for _,err in ipairs(failures) do print('FAIL '..err) end
assert(#failures==0,string.format('%d/%d batch453 regressions failed',#failures,cases))
print(string.format('batch453: %d lane/path guard-policy and recovery-identity regressions passed',cases))
