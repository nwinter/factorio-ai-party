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
-- - queues and standing orders run on: the pending steps, the order and a
--   repeating plan's cycle as they were; a current step that moves or builds
--   (move_to, construct, mine, ...) starts again by itself, once;
-- - a direct action that moves or builds starts again from the call that
--   started it (runtime.lua keeps it on the action as `call`); one started by
--   an older runtime has no call, and says to start it again.
-- Each agent with something running finds one line in its next reply
-- (team.harness_updated). Sleeps are not stopped by an install at all.
-- A restart with a changed mod and a stop after a runtime fault carry nothing.
-- Only reads at load (on_load has no game, so nothing is noted then); the note
-- lives in module state for the rest of that tick, the same on every peer.
return function(api)
  local M={}
  local seen
  -- Kinds whose whole state is the action table and the tick re-applies: they continue.
  local CONTINUE={wait_ticks=true,wait_until=true,walk=true,feed=true}
  M.CONTINUE=CONTINUE
  local function waits(step) return step and (step.action=='wait_until' or step.action=='wait_ticks') end
  local function copy(list)
    local out={}
    for i,v in ipairs(list or {}) do out[i]=v end
    return out
  end
  local function load_snapshot()
    local s=game and storage and storage.agent_harness
    if not s then return end
    local snap={tick=game.tick,queues={},active={},last={},combat={}}
    for index,q in pairs(s.queues or {}) do
      if not q.paused then
        snap.queues[index]={current=q.current,pending=copy(q.pending),order=q.order,order_result=q.order_result,
          history_last=q.history[#q.history]}
      end
    end
    for index,a in pairs(s.active or {}) do
      snap.active[index]=a
      snap.last[index]=(s.last or {})[index] or false
    end
    for index in pairs(s.combat or {}) do snap.combat[index]=true end
    seen=snap
  end
  local function note(index,text)
    local s=api.state()
    s.harness_notes=s.harness_notes or {}
    local list=s.harness_notes[index] or {}
    s.harness_notes[index]=list
    if #list<4 then list[#list+1]=text end
  end
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
    for index,was in pairs(snap.queues) do
      local q=s.queues and s.queues[index]
      if q and q.paused then
        local step=was.current
        -- The pause recorded the step interrupted: it never was.
        local last=q.history[#q.history]
        if step and last and last~=was.history_last and last.id==step.id and last.result and last.result.reason=='interrupted' then table.remove(q.history) end
        q.pending=was.pending; q.order=was.order; q.order_result=was.order_result
        local action=snap.active[index]
        if step and (waits(step) or (action and action.queued and CONTINUE[action.kind])) then
          q.current=step
          if action and action.queued then owned[index]='continue' end
        elseif step then
          -- Starts again from the head of the queue (as the pause would requeue it), and the queue goes on.
          table.insert(q.pending,1,{id=step.id,action=step.action,args=step.args,wait=step.wait,label=step.label,on_fail=step.on_fail,
            on_short=step.on_short,order=step.order})
          q.current=nil
          owned[index]='restart'
          line(index,string.format('your queue step %s (%s) was interrupted by a harness update; resumed',step.action,tostring(step.id)))
        end
        q.paused=false; q.revision=q.revision+1
        -- A finished queue is left unpaused and empty: nothing of it ran.
        if step or #was.pending>0 or was.order then carried[index]=true end
      end
    end
    for index,action in pairs(snap.active) do
      local how=owned[index]
      -- A queue step that starts again owns its action; a direct one beside the queue does not.
      if how=='restart' and not action.queued then how=nil end
      if how=='continue' or (not how and not action.queued and CONTINUE[action.kind]) then
        if not s.active[index] then s.active[index]=action; restore_last(s,index,snap.last[index]) end
        carried[index]=true
      elseif not how and not s.active[index] then
        local call=not action.queued and action.call
        local ok,err=false,nil
        if call then ok,err=api.restart(index,call) end
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
    for index in pairs(snap.combat) do
      -- A queued shoot step starts again with its queue.
      local step=owned[index]=='restart' and snap.queues[index].current
      if not (s.combat and s.combat[index]) and not (step and step.action=='shoot') then line(index,'your shoot was interrupted by a harness update; start it again if it is still needed') end
    end
    for index in pairs(carried) do
      if not lines[index] then note(index,at..' (your wait/queue carried over)') end
    end
    for index,list in pairs(lines) do
      for _,text in ipairs(list) do note(index,at..': '..text) end
    end
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
