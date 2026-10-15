-- A hot runtime install replaces the runtime: control.lua has the outgoing
-- one stop everything (stop_all), which
-- ends every running action and pauses every queue. The incoming runtime notes
-- while it loads what was running (before that stop), and on its first tick or
-- request puts it back, so a deploy is a handoff (shift09, Luna and Haiku: 3+
-- research waits and courier loops cut, each needing a rerun or queue resume):
-- - waits (wait_ticks, wait_until), walk and a transfer/build waiting for a
--   hand craft (feed) carry on as they were: same until_tick, same condition,
--   no interruption in last or the queue history, so a pending fh --wait gets
--   the result as if nothing happened;
-- - so do timed collect and gather (a radius, wait_ticks at a machine), every
--   walking tour (collect, transfer and feed with walk, pick legs, refuel and
--   rearm over a radius), mine, pickup, build_path, construct, kite, repair and
--   a shoot on foot: what was got, placed, built or killed so far, the target
--   count, the next place and until_tick stay (Sol 12:46: a deploy restarted
--   a timed collect and its --wait ended wait_timeout). A repair holds its tool
--   again (the outgoing stop put it back);
-- - queues and standing orders run on: the pending steps, the order and a
--   repeating plan's cycle as they were, a full drop's step while its pods
--   still wait; a current step that walks to a goal (move_to) or shoots from a
--   vehicle starts again by itself, once, from the first via point it had not
--   reached;
-- - a direct move_to or drive starts again from the call that started it
--   (runtime.lua keeps it on the action as `call`), by the same deadline and
--   from the first via point it had not reached; one started by an older
--   runtime has no call, and says to start it again.
-- A carried action runs guarded (runtime.lua tick_action, finish): a shape the
-- new runtime does not expect ends it failed, never the harness tick.
-- Each agent with something running finds one line in its next reply
-- (team.harness_updated). Sleeps are not stopped by an install at all.
-- A restart with a changed mod carries the same way (control.lua boots the
-- runtime in on_configuration_changed, with game, then has it stop_all); a
-- stop after a runtime fault carries nothing.
-- Only reads at load (on_load has no game, so nothing is noted then); the note
-- lives in module state for the rest of that tick, the same on every peer.
return function(api)
  local M={}
  local seen
  -- Kinds whose whole state is the action table and the tick re-applies: they continue.
  local CONTINUE={wait_ticks=true,wait_until=true,walk=true,feed=true,
    gather=true,mine=true,pickup=true,build_path=true,construct=true,kite=true,repair=true}
  M.CONTINUE=CONTINUE
  local function waits(step) return step and (step.action=='wait_until' or step.action=='wait_ticks') end
  local function copy(list)
    local out={}
    for i,v in ipairs(list or {}) do out[i]=v end
    return out
  end
  -- A shoot on foot (combat channel) goes on; one a walk or drive fires goes with that walk or drive; a seated one
  -- stops (a queue's starts again with its queue).
  local function on_foot(c) return c and not c.vehicle and not c.with_move and not c.with_drive end
  -- A walk through via points goes on from the first one it had not reached (as scheduler.lua pause does).
  local function via_left(args,done)
    if not (done and done>0 and type(args)=='table' and type(args.via)=='table') then return args end
    local rest,left={},{}
    for k,v in pairs(args) do rest[k]=v end
    for i=done+1,#args.via do left[#left+1]=args.via[i] end
    rest.via=#left>0 and left or nil
    return rest
  end
  local function load_snapshot()
    local s=game and storage and storage.agent_harness
    if not s then return end
    local snap={tick=game.tick,queues={},active={},last={},combat={}}
    for index,q in pairs(s.queues or {}) do
      if not q.paused then
        snap.queues[index]={current=q.current,pending=copy(q.pending),order=q.order,order_result=q.order_result,
          history_first=q.history[1],history_last=q.history[#q.history]}
      end
    end
    for index,a in pairs(s.active or {}) do
      snap.active[index]=a
      snap.last[index]=(s.last or {})[index] or false
    end
    for index,c in pairs(s.combat or {}) do
      snap.combat[index]={entry=c,target=(s.combat_targets or {})[index],last=(s.last_combat or {})[index] or false}
    end
    seen=snap
  end
  local function note(index,text)
    local s=api.state()
    s.harness_notes=s.harness_notes or {}
    local list=s.harness_notes[index] or {}
    s.harness_notes[index]=list
    if #list<4 then list[#list+1]=text end
  end
  -- A line for one agent's next reply (runtime.lua carry_failed).
  M.note=note
  local function restore_last(s,index,was)
    s.last=s.last or {}
    s.last[index]=was or nil
  end
  function M.carry()
    local snap=seen
    if not snap then return end
    seen=nil
    if game.tick-snap.tick>1 then return end
    local s=api.state()
    local at='harness updated at tick '..snap.tick
    local carried,lines,owned={},{},{}
    local function line(index,text) lines[index]=lines[index] or {}; table.insert(lines[index],text) end
    -- What carried over, by the name the agent called it.
    local function carry(index,what)
      local list=carried[index] or {}
      carried[index]=list
      for _,w in ipairs(list) do if w==what then return end end
      list[#list+1]=what
    end
    for index,was in pairs(snap.queues) do
      local q=s.queues and s.queues[index]
      if q and q.paused then
        local step=was.current
        -- The pause recorded the step interrupted: it never was.
        local last=q.history[#q.history]
        if step and last and last~=was.history_last and last.id==step.id and last.result and last.result.reason=='interrupted' then
          table.remove(q.history)
          -- Recording it pushed the oldest row out of a full history: that row comes back.
          if was.history_first and q.history[1]~=was.history_first then table.insert(q.history,1,was.history_first) end
        end
        q.pending=was.pending; q.order=was.order; q.order_result=was.order_result
        local action=snap.active[index]
        local combat=snap.combat[index]
        -- A full drop's pods waiting for a hatch run on their own channel, which an install leaves alone.
        local dropping=step and step.action=='drop' and s.drop_jobs and s.drop_jobs[index]
        if step and (waits(step) or (action and action.queued and CONTINUE[action.kind]) or (step.action=='shoot' and combat and on_foot(combat.entry))
          or dropping) then
          q.current=step
          if action and action.queued then owned[index]='continue' end
        elseif step then
          -- Starts again from the head of the queue (as the pause would requeue it), and the queue goes on.
          table.insert(q.pending,1,{id=step.id,action=step.action,args=via_left(step.args,step.via_done),wait=step.wait,label=step.label,
            on_fail=step.on_fail,on_short=step.on_short,order=step.order})
          q.current=nil
          owned[index]='restart'
          line(index,string.format('your queue step %s (%s) was interrupted by a harness update; resumed',step.action,tostring(step.id)))
        end
        q.paused=false; q.revision=q.revision+1
        -- A finished queue is left unpaused and empty: nothing of it ran.
        if step or #was.pending>0 or was.order then carry(index,'queue') end
      end
    end
    for index,action in pairs(snap.active) do
      local how=owned[index]
      -- A queue step that starts again owns its action; a direct one beside the queue does not.
      if how=='restart' and not action.queued then how=nil end
      if how=='continue' or (not how and not action.queued and CONTINUE[action.kind]) then
        if not s.active[index] then
          s.active[index]=action; restore_last(s,index,snap.last[index])
          -- Guarded from now on (runtime.lua tick_action, finish).
          action.carried=snap.tick
          -- What a pickup took so far the outgoing runtime counted as hauled when it stopped it (runtime.lua finish).
          if action.kind=='pickup' and action.picked then
            action.hauled={}
            for k,v in pairs(action.picked) do action.hauled[k]=v end
          end
          -- What the outgoing stop undid on the character (a repair's tool in the cursor).
          if api.resume then pcall(api.resume,index,action) end
        end
        -- A queue's own step goes on as part of its queue.
        if how~='continue' then carry(index,M.called(action)) end
      elseif not how and not s.active[index] then
        local call=not action.queued and action.call
        if call and action.kind=='move_to' and action.via then
          call={action=call.action,args=via_left(call.args,(action.via.index or 1)-1),seated=call.seated}
        end
        local ok,err=false,nil
        -- By the deadline it had: a pending fh --wait budgets for that.
        if call then ok,err=api.restart(index,call,action.until_tick) end
        if ok then
          restore_last(s,index,snap.last[index])
          line(index,'your '..action.kind..' was interrupted by a harness update; resumed')
        elseif call then
          line(index,'your '..action.kind..' was interrupted by a harness update; starting it again failed: '..tostring(err))
        else
          line(index,'your '..action.kind..' was interrupted by a harness update; start it again if it is still needed')
        end
      end
    end
    for index,was in pairs(snap.combat) do
      local c=was.entry
      local step=snap.queues[index] and snap.queues[index].current
      if on_foot(c) and not (s.combat and s.combat[index]) then
        -- A shoot on foot goes on: same until_tick, target and ammo count at its start.
        s.combat=s.combat or {}; s.combat[index]=c
        if was.target then s.combat_targets=s.combat_targets or {}; s.combat_targets[index]=was.target end
        s.last_combat=s.last_combat or {}; s.last_combat[index]=was.last or nil
        c.carried=snap.tick
        if not (step and step.action=='shoot' and owned[index]~='restart') then carry(index,'shoot') end
      else
        -- A queued shoot step starts again with its queue.
        local restarting=owned[index]=='restart' and step
        if not (s.combat and s.combat[index]) and not (restarting and restarting.action=='shoot') then
          line(index,'your shoot was interrupted by a harness update; start it again if it is still needed')
        end
      end
    end
    for index,list in pairs(carried) do
      if not lines[index] then note(index,at..' (your '..table.concat(list,' and ')..' carried over)') end
    end
    for index,list in pairs(lines) do
      for _,text in ipairs(list) do note(index,at..': '..text) end
    end
  end
  -- The name an action goes by in a note: the call that started it.
  function M.called(action)
    if action.kind=='gather' then
      if action.op=='transfer' then return action.recover and 'recover' or action.collect and 'collect' or 'transfer' end
      return action.op or 'collect'
    end
    if action.kind=='feed' then return type(action.handler)=='string' and action.handler or 'feed' end
    return action.kind
  end
  -- The lines for one agent's next reply, once.
  function M.take(index)
    local s=api.state()
    local list=s.harness_notes and s.harness_notes[index]
    if list then s.harness_notes[index]=nil end
    return list
  end
  load_snapshot()
  return M
end
