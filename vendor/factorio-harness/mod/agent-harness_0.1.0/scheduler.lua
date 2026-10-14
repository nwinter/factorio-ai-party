-- Short-horizon plans execute at simulation speed. No coroutines or host clock.
return function(api)
  local M = {handlers={}}
  local MAX_PENDING, MAX_HISTORY, MAX_INSTANT, MAX_BYTES, MAX_GUARDS, CHECK_TICKS = 128, 64, 4, 1048576, 8, 10
  -- Outcomes of timed actions that count as the step succeeding.
  local SUCCESS={duration_elapsed=true,target_mined=true,repair_completed=true,arrived=true,arrived_near=true,path_built=true,constructed=true,nothing_to_do=true,clear=true,fed=true,collected=true,topped_up=true}
  -- construct's 'incomplete' (ghosts left for lack of items, or failures) is a failure.
  local forbidden = {attach=true, detach=true, recipes=true, technologies=true, inspect=true, blueprint_export=true, blueprint_list=true, stop=true, describe=true, status=true, observe=true, screenshot=true, map=true, nearest=true, craftable=true, scan=true, power=true, grid=true, rates=true, bottleneck=true, stock=true, platforms=true,
    order_set=true, order_remove=true, orders=true, orders_pause=true, orders_resume=true}
  local function queue(index)
    local s=api.state()
    s.queues=s.queues or {}
    s.queues[index]=s.queues[index] or {revision=0,sequence=0,pending={},history={},paused=true}
    return s.queues[index]
  end
  local function revision(q,a)
    if a.expected_revision~=nil then assert(a.expected_revision==q.revision,'queue revision conflict; inspect queue_status') end
  end
  local function steps(a)
    assert(type(a.steps)=='table' and #a.steps<=MAX_PENDING,'steps must be an array of at most 128 entries')
    local out={}
    for _,step in ipairs(a.steps) do
      assert(type(step)=='table' and type(step.action)=='string','each step needs an action')
      assert(not step.action:match('^queue_') and not forbidden[step.action],'action is not queueable')
      assert(step.action=='wait_ticks' or step.action=='wait_until' or api.handlers[step.action],'unknown action in plan')
      assert(step.args==nil or type(step.args)=='table','step args must be an object')
      if api.check_args then api.check_args(step.action,step.args) end
      assert(step.wait==nil or type(step.wait)=='boolean','step wait must be boolean')
      assert(step.label==nil or (type(step.label)=='string' and #step.label<=64),'step label must be a short string')
      local on_fail=step.on_fail
      assert(on_fail==nil or on_fail=='abort' or on_fail=='skip' or (type(on_fail)=='string' and on_fail:match('^goto:.+')),'on_fail must be abort, skip or goto:<label>')
      if step.action=='wait_ticks' then
        local ticks=step.args and step.args.ticks
        assert(type(ticks)=='number' and ticks==math.floor(ticks) and ticks>=1 and ticks<=54000,'wait_ticks requires ticks 1..54000')
      end
      if step.action=='wait_until' then
        local timeout=step.args and step.args.timeout
        assert(timeout==nil or (type(timeout)=='number' and timeout==math.floor(timeout) and timeout>=1 and timeout<=54000),'wait_until timeout must be 1..54000 ticks')
        api.validate_condition(step.args)
      end
      out[#out+1]={action=step.action,args=step.args or {},wait=step.wait~=false,label=step.label,on_fail=on_fail}
    end
    return out
  end
  -- Conservative JSON-size estimate, independent of Factorio's serializer.
  -- Count keys even for arrays; this slightly overestimates rather than allowing
  -- many blueprint imports to grow pending work without a memory bound.
  local function bytes(value,depth)
    assert(depth<=32,'queue arguments exceed maximum nesting depth')
    if type(value)=='string' then
      local _,escaped=value:gsub('[%z\1-\31\\"]','')
      return #value+escaped*5+2
    end
    if type(value)~='table' then return 32 end
    local size=2
    for key,item in pairs(value) do
      size=size+bytes(tostring(key),depth+1)+bytes(item,depth+1)+2
      assert(size<=MAX_BYTES,'queue argument byte budget exceeded')
    end
    return size
  end
  local function total(items)
    local size=0
    for _,step in ipairs(items) do size=size+bytes(step,0) end
    return size
  end
  local function assign(q,items)
    for _,step in ipairs(items) do q.sequence=q.sequence+1; step.id='job-'..q.sequence end
  end
  local function copy_steps(items)
    local out={}
    for _,step in ipairs(items) do out[#out+1]={action=step.action,args=step.args,wait=step.wait,label=step.label,on_fail=step.on_fail} end
    return out
  end
  -- Guards: {when=<condition>, goto='label' | steps=[...] | neither (abort)}.
  local function guards(a)
    if a.guards==nil then return {} end
    assert(type(a.guards)=='table' and #a.guards<=MAX_GUARDS,'guards must be an array of at most '..MAX_GUARDS)
    local out={}
    for _,g in ipairs(a.guards) do
      assert(type(g)=='table','each guard is {when, goto|steps}')
      api.validate_condition(g.when)
      assert(g['goto']==nil or type(g['goto'])=='string','guard goto must be a label')
      assert(not (g['goto'] and g.steps),'a guard takes goto or steps, not both')
      out[#out+1]={when=g.when,['goto']=g['goto'],steps=g.steps and steps({steps=g.steps}) or nil}
    end
    return out
  end
  -- recent: keep only the newest entries of the history (the changing calls;
  -- shake3: Opus's queue cancel printed 60+ entries); queue_status shows it all.
  local RECENT=3
  local function snapshot(q,recent)
    local failure
    for i=#q.history,1,-1 do if not q.history[i].ok then failure=q.history[i]; break end end
    local history=q.history
    if recent and #history>recent then
      history={}
      for i=#q.history-recent+1,#q.history do history[#history+1]=q.history[i] end
    end
    return {revision=q.revision,paused=q.paused,pending=q.pending,active=q.current or false,history=history,
      order=q.order and {name=q.order.name,reason=q.order.reason,steps=q.order.total} or nil,
      history_total=history~=q.history and #q.history or nil,
      waiting=q.current and q.current.action=='wait_until' and {condition=q.current.args,saw=q.current.saw,until_tick=q.current.until_tick} or nil,
      guards=q.guards and #q.guards>0 and q.guards or nil,last_failure=failure,after_direct=q.after_direct,
      repeating=q.loop~=nil,cycle=q.cycle,next_cycle_tick=q.next_cycle_tick,
      limits={pending=MAX_PENDING,history=MAX_HISTORY,instant_per_tick=MAX_INSTANT,argument_bytes=MAX_BYTES}}
  end
  local function record(q,step,ok,result)
    q.history[#q.history+1]={id=step.id,action=step.action,label=step.label,ok=ok,result=result,started_tick=step.started_tick,finished_tick=game.tick,order=step.order}
    if #q.history>MAX_HISTORY then table.remove(q.history,1) end
    q.revision=q.revision+1
  end
  -- Drops pending steps up to the labelled one; false when it is not pending.
  local function jump(q,label)
    for i,step in ipairs(q.pending) do
      if step.label==label then
        for _=1,i-1 do table.remove(q.pending,1) end
        q.revision=q.revision+1
        return true
      end
    end
    return false
  end
  -- A failed step follows its on_fail policy; the default stops the plan.
  local function fail(q,p,step,result)
    record(q,step,false,result)
    local policy=step.on_fail or 'abort'
    if policy=='skip' then return end
    local label=policy:match('^goto:(.+)$')
    if label and jump(q,label) then api.stop(p); return end
    if label then q.history[#q.history].result.goto_error='label not pending: '..label end
    q.paused=true; api.stop(p)
    -- A standing order's run ends here (orders.lua counts the failure); its
    -- remaining steps are dropped, so the queue is free again.
    if q.order then
      local why=type(result)=='table' and (result.reason or result.outcome) or result
      q.order_result={name=q.order.name,outcome='failed',reason=step.action..': '..tostring(why),tick=game.tick}
      q.order=nil; q.pending={}; q.revision=q.revision+1
    end
  end
  local function check_guards(q,p)
    for i,g in ipairs(q.guards or {}) do
      local ok,met,saw=pcall(api.condition,p,g.when)
      if ok and met then
        -- A guard fires once; its reaction replaces whatever was running.
        table.remove(q.guards,i)
        if q.current then record(q,q.current,false,{reason='guard',condition=g.when['until'],saw=saw}); q.current=nil end
        api.stop(p)
        q.history[#q.history+1]={action='guard',ok=true,result={condition=g.when['until'],saw=saw},finished_tick=game.tick}
        if #q.history>MAX_HISTORY then table.remove(q.history,1) end
        if g.steps then
          local items=copy_steps(g.steps); assign(q,items); q.pending=items
        elseif not (g['goto'] and jump(q,g['goto'])) then q.paused=true end
        q.revision=q.revision+1
        return
      end
    end
  end
  -- An interrupted step goes back to the head of pending work (restarting from
  -- scratch), so resuming retries it instead of running later steps without it.
  -- Steps toward an absolute goal restart cleanly; relative ones (walk N
  -- ticks, wait N ticks) would repeat what already happened, so they are not
  -- requeued.
  local RESTARTABLE={move_to=true,construct=true,build_path=true,mine=true,repair=true,kite=true,wait_until=true,rearm=true,refuel=true,collect=true}
  function M.pause(index)
    local q=queue(index)
    if q.current then
      local step=q.current
      local again=RESTARTABLE[step.action]==true
      record(q,step,false,{reason='interrupted',requeued=again or nil}); q.current=nil
      if again then table.insert(q.pending,1,{id=step.id,action=step.action,args=step.args,wait=step.wait,label=step.label,on_fail=step.on_fail}) end
    end
    q.paused=true; q.revision=q.revision+1
    -- A standing order stopped by anything else (the agent's own request, a
    -- ride, a death) keeps its remaining steps for later (orders.lua) and
    -- leaves the queue empty for the agent.
    if q.order then
      q.order_result={name=q.order.name,outcome='interrupted',remaining=copy_steps(q.pending),tick=game.tick}
      q.order=nil; q.pending={}
    end
  end
  -- Standing orders (orders.lua) run in the agent's own queue while it is
  -- free: no step running or pending and no repeating plan.
  function M.free(index)
    local q=(api.state().queues or {})[index]
    return not q or (not q.current and #q.pending==0 and not q.loop)
  end
  function M.run_order(index,name,items,reason)
    local q=queue(index)
    assert(M.free(index),'the queue is busy')
    items=copy_steps(items); assign(q,items)
    for _,step in ipairs(items) do step.order=name end
    q.pending=items; q.paused=false
    q.order={name=name,reason=reason,total=#items,started_tick=game.tick}
    q.revision=q.revision+1
  end
  -- The running order: name, reason, its step number and count.
  function M.order(index)
    local q=(api.state().queues or {})[index]
    if not (q and q.order) then return nil end
    local o=q.order
    return {name=o.name,reason=o.reason,total=o.total,started_tick=o.started_tick,step=math.max(1,math.min(o.total,o.total-#q.pending))}
  end
  -- Ends the running order at once (removed, over its time): outcome and reason for orders.lua.
  function M.cancel_order(index,outcome,why)
    local q=(api.state().queues or {})[index]
    if not (q and q.order) then return end
    local name=q.order.name
    if q.current then record(q,q.current,false,{reason=why}); q.current=nil end
    api.stop_index(index)
    q.order=nil; q.pending={}; q.paused=true; q.revision=q.revision+1
    q.order_result={name=name,outcome=outcome,reason=why,tick=game.tick}
  end
  function M.order_result(index)
    local q=(api.state().queues or {})[index]
    local r=q and q.order_result
    if r then q.order_result=nil end
    return r
  end
  -- The agent's own queue calls come first: a running order steps aside.
  local function preempt(p,q)
    if q.order then api.stop(p); M.pause(p.index) end
  end
  -- A repeating plan resting between cycles runs nothing, so a runtime
  -- replacement leaves it scheduled instead of pausing the loop.
  function M.pause_all()
    for index,q in pairs(api.state().queues or {}) do
      local resting=q.loop and not q.current and #q.pending==0 and not (api.state().active or {})[index]
      if not resting then M.pause(index) end
    end
  end
  function M.handlers.queue_status(p) return snapshot(queue(p.index)) end
  -- Checks a plan as queue_submit would (saved plans, standing orders);
  -- returns its byte size and the checked steps.
  function M.validate(a)
    local items=steps(a)
    assert(#items<=MAX_PENDING,'queue capacity exceeded')
    guards(a)
    local size=total(items)
    assert(size<=MAX_BYTES,'queue argument byte budget exceeded')
    return size,items
  end
  function M.handlers.queue_submit(p,a)
    local q=queue(p.index); revision(q,a)
    local items=steps(a)
    local new_guards=guards(a)
    preempt(p,q)
    assert(a.mode==nil or a.mode=='append' or a.mode=='replace','mode must be append or replace')
    assert((a.mode=='replace' and 0 or #q.pending)+#items<=MAX_PENDING,'queue capacity exceeded')
    assert((a.mode=='replace' and 0 or total(q.pending))+total(items)<=MAX_BYTES,'queue argument byte budget exceeded')
    -- Replace affects pending work only; active cancellation is always explicit.
    assign(q,items)
    if a.mode=='replace' then q.pending={}; q.loop=nil; q.next_cycle_tick=nil; q.guards={} end
    for _,step in ipairs(items) do q.pending[#q.pending+1]=step end
    q.guards=q.guards or {}
    assert(#q.guards+#new_guards<=MAX_GUARDS,'at most '..MAX_GUARDS..' guards')
    for _,g in ipairs(new_guards) do q.guards[#q.guards+1]=g end
    if a.start~=false then q.paused=false end
    q.revision=q.revision+1
    return snapshot(q,RECENT)
  end
  function M.handlers.queue_repeat(p,a)
    local q=queue(p.index); revision(q,a)
    local items=steps(a)
    assert(#items>0,'repeating plan must not be empty')
    assert(total(items)<=MAX_BYTES,'queue argument byte budget exceeded')
    local interval=a.interval_ticks or 1800
    assert(type(interval)=='number' and interval==math.floor(interval) and interval>=60 and interval<=36000,'interval_ticks must be 60..36000')
    preempt(p,q)
    api.stop(p)
    M.pause(p.index)
    q.loop=copy_steps(items); q.interval=interval; q.next_cycle_tick=nil; q.cycle=1
    assign(q,items); q.pending=items; q.paused=false; q.revision=q.revision+1
    return snapshot(q,RECENT)
  end
  function M.handlers.queue_edit(p,a)
    local q=queue(p.index)
    assert(a.expected_revision~=nil,'queue_edit requires expected_revision')
    revision(q,a)
    assert(not q.order,'a standing order ('..(q.order and q.order.name or '')..') is running in the queue: queue_cancel stops it, then edit your own steps')
    local index=a.index
    assert(type(index)=='number' and index==math.floor(index) and index>=1 and index<=#q.pending+1,'index outside pending queue (1-based)')
    local remove=a.remove or 0
    assert(type(remove)=='number' and remove==math.floor(remove) and remove>=0 and remove<=#q.pending-index+1,'invalid remove count')
    local items=steps(a)
    assert(#q.pending-remove+#items<=MAX_PENDING,'queue capacity exceeded')
    local size=total(q.pending)+total(items)
    for n=index,index+remove-1 do size=size-bytes(q.pending[n],0) end
    assert(size<=MAX_BYTES,'queue argument byte budget exceeded')
    assign(q,items)
    for _=1,remove do table.remove(q.pending,index) end
    for n=#items,1,-1 do table.insert(q.pending,index,items[n]) end
    q.revision=q.revision+1
    return snapshot(q,RECENT)
  end
  function M.handlers.queue_cancel(p,a)
    local q=queue(p.index); revision(q,a)
    preempt(p,q)
    api.stop(p)
    M.pause(p.index)
    if a.clear~=false then q.pending={}; q.loop=nil; q.next_cycle_tick=nil; q.guards={} end
    return snapshot(q,RECENT)
  end
  function M.handlers.queue_resume(p,a)
    local q=queue(p.index); revision(q,a)
    q.paused=false; q.revision=q.revision+1
    return snapshot(q,RECENT)
  end
  function M.tick()
    for index,q in pairs(api.state().queues or {}) do
      if not q.paused then
        local valid,p=pcall(api.player,index)
        if not valid then
          api.stop_index(index); M.pause(index)
        else
          -- The agent's guards watch its own plans, not a standing order's run.
          if q.guards and #q.guards>0 and not q.order and game.tick%CHECK_TICKS==0 then check_guards(q,p) end
          if q.current and q.current.action=='wait_until' then
            local step=q.current
            if game.tick>=step.next_check then
              step.next_check=game.tick+CHECK_TICKS
              local ok,met,saw=pcall(api.condition,p,step.args)
              step.saw=ok and saw or nil
              q.current=nil
              if not ok then fail(q,p,step,{reason=tostring(met)})
              elseif met then record(q,step,true,{outcome='met',saw=saw})
              elseif game.tick>=step.until_tick then fail(q,p,step,{outcome='timed_out',saw=saw})
              else q.current=step end
            end
          elseif q.current then
            local step=q.current
            local waiting=step.action=='wait_ticks' and game.tick<step.until_tick or
              step.action~='wait_ticks' and api.busy(p,step.action)
            if not waiting then
              local outcome=step.action~='wait_ticks' and api.outcome and api.outcome(p,step.action) or nil
              local success=not outcome or SUCCESS[outcome]==true
              local result={accepted=step.result,outcome=outcome or 'completed',completion=api.completion and api.completion(p,step.action)}
              q.current=nil
              if success then record(q,step,true,result) else fail(q,p,step,result) end
            end
          end
          if not q.paused and not q.current and #q.pending==0 and q.loop then
            if not q.next_cycle_tick then q.next_cycle_tick=game.tick+q.interval end
            if game.tick>=q.next_cycle_tick then
              q.pending=copy_steps(q.loop); assign(q,q.pending)
              q.next_cycle_tick=nil; q.cycle=q.cycle+1; q.revision=q.revision+1
            end
          end
          -- A plan submitted while a direct command still drives the
          -- character runs after it, as if it had been the plan's first step.
          q.after_direct=nil
          if not q.paused and not q.current and #q.pending>0 and api.direct_action then q.after_direct=api.direct_action(p) end
          for _=1,MAX_INSTANT do
            if q.paused or q.current or q.after_direct or #q.pending==0 then break end
            local step=table.remove(q.pending,1)
            step.started_tick=game.tick
            q.revision=q.revision+1
            -- Every step started counts as the agent's (selfview.lua my_hour).
            if api.on_step then pcall(api.on_step,index,step.action) end
            if step.action=='wait_ticks' then
              step.until_tick=game.tick+step.args.ticks
              q.current=step
            elseif step.action=='wait_until' then
              -- Checked from the next tick, so a wait placed after an action
              -- sees the world that action changed.
              step.until_tick=game.tick+(step.args.timeout or 3600)
              step.next_check=game.tick+1
              q.current=step
            else
              local ok,result=pcall(api.handlers[step.action],p,step.args)
              if ok and api.claim then api.claim(p) end
              if not ok then
                fail(q,p,step,{reason=api.reason and api.reason(result) or tostring(result)})
              elseif step.wait and api.busy(p,step.action) then
                step.result=result; q.current=step
              else record(q,step,true,result) end
            end
          end
          if q.order and not q.paused and not q.current and #q.pending==0 then
            q.order_result={name=q.order.name,outcome='done',tick=game.tick}
            q.order=nil; q.revision=q.revision+1
          end
        end
      end
    end
  end
  -- A direct wait while the queue runs would pause it (runtime.lua dispatch_request refuses it).
  local PAUSE_QUEUE='direct call only, boolean: true pauses your running queue for this wait; without it a direct wait refuses while your queue runs (fh sleep SECONDS waits and lets it run)'
  M.schema={
    queue_status={returns='the whole history (up to 64 entries); the other queue calls return only the newest 3 and history_total'},
    queue_repeat={steps='replace the queue with a repeating plan; errors pause it; cancel clear=true removes the loop',interval_ticks='60..36000 pause between cycles; default 1800',expected_revision='optional'},
    queue_submit={steps='array of {action,args,wait?,label?,on_fail?}; max 128; wait defaults true; use shoot wait=false for firing while walking; a timed action started by a direct call finishes first (after_direct names it; to preempt it, stop then queue_resume)',mode='append|replace pending only',start='default true',expected_revision='optional optimistic concurrency guard',guards='optional, see guards; replace clears them'},
    queue_edit={expected_revision='required from queue_status',index='1-based pending index',remove='count to remove',steps='replacement steps'},
    queue_cancel={clear='default true; false retains pending steps; always cancels active controls and pauses',expected_revision='optional'},
    queue_resume={expected_revision='optional'},
    wait_ticks={ticks='1..54000 simulation ticks: a queue step, or a direct timed action (fh call wait_ticks --wait)',pause_queue=PAUSE_QUEUE},
    wait_until={['until']='no_enemy_structures|no_enemies|turrets_idle|ammo_below|health_below|health_above|item_count|crafting_done|researched|ghosts_waiting|damaged|fuel_below; a queue step, a standing order\'s when, or a direct timed action (fh call wait_until --wait): outcomes met | timed_out | failed; status/last show saw',
      position='area predicates: centre (default character)',radius='1..128 (default 32)',count='ammo_below: per-turret ammo items; fuel_below: fuel items per burner machine (furnaces, drills, boilers, burner inserters, ...)',fraction='health_*: 0..1; damaged: our buildings under this health fraction (default 1: any damage)',
      item='item_count',at_least='item_count; ghosts_waiting: ghosts (entity and tile) in the area (default 1)',below='item_count',positions='item_count: 1..64 {x,y} of our entities (chests, machines) to count in, summed over all their inventories; default the character\'s inventory',technology='researched',timeout='ticks 1..54000 (default 3600; fh call wait_until --wait takes it from --wait-timeout); timing out fails the step (timed_out)',
      checked='every 10 ticks; enemies count only if known from the chart (units only in visible chunks)',pause_queue=PAUSE_QUEUE},
    step_options={label='name a step as a goto target',on_fail='abort (default: pause plan) | skip | goto:<label> (drops pending steps before it)'},
    guards={usage='queue_submit guards=[{when={until=...,...}, goto=label | steps=[...] | neither=abort}]; checked every 10 ticks while the plan runs; each fires once, stops the running step',max=MAX_GUARDS}
  }
  return M
end
