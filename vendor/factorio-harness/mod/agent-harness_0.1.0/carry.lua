-- A hot runtime install (or a restart with a changed mod) replaces the
-- runtime: control.lua has the outgoing one stop everything (stop_all), which
-- pauses every queue. The incoming runtime notes while it loads which queues
-- were running, and on its first tick or request carries them on: a
-- wait_until or wait_ticks step keeps its own clock, a step toward a goal
-- (move_to, construct, ...: the pause requeued it) starts again, any other
-- step leaves the queue paused. Each agent whose work was cut finds a line in
-- its next reply (team.harness_updated).
-- Only reads at load (on_load has no game, so nothing is noted then); the note
-- lives in module state for the rest of that tick, the same on every peer.
return function(api)
  local M={}
  local seen
  local function waits(step) return step and (step.action=='wait_until' or step.action=='wait_ticks') end
  local function load_snapshot()
    local s=game and storage and storage.agent_harness
    if not s then return end
    local snap={tick=game.tick,queues={},direct={}}
    for index,q in pairs(s.queues or {}) do
      if not q.paused then snap.queues[index]={current=q.current} end
    end
    -- What runs outside a queue step: a direct action, a no-wait step's action, combat.
    for index,a in pairs(s.active or {}) do
      local q=snap.queues[index]
      if not (q and q.current and not waits(q.current)) then snap.direct[index]=a.kind end
    end
    for index in pairs(s.combat or {}) do snap.direct[index]=snap.direct[index] or 'shoot' end
    seen=snap
  end
  local function note(index,text)
    local s=api.state()
    s.harness_notes=s.harness_notes or {}
    local list=s.harness_notes[index] or {}
    s.harness_notes[index]=list
    if #list<4 then list[#list+1]=text end
  end
  function M.carry()
    local snap=seen
    if not snap then return end
    seen=nil
    if game.tick-snap.tick>1 then return end
    local s=api.state()
    local at='harness updated at tick '..snap.tick..': '
    for index,was in pairs(snap.queues) do
      local q=s.queues and s.queues[index]
      if q and q.paused then
        local step,run=was.current,true
        if waits(step) then
          -- The pause recorded it interrupted (and requeued a wait_until): it never was.
          local last=q.history[#q.history]
          if last and last.id==step.id and last.result and last.result.reason=='interrupted' then table.remove(q.history) end
          if q.pending[1] and q.pending[1].id==step.id then table.remove(q.pending,1) end
          q.current=step
        elseif step and q.pending[1] and q.pending[1].id==step.id then
          note(index,at..'your queue step '..step.action..' ('..tostring(step.id)..') was interrupted and starts again')
        elseif step then
          run=false
          note(index,string.format('%syour queue step %s (%s) was interrupted; the queue is paused with %d steps pending: fh queue resume continues with the next one',
            at,step.action,tostring(step.id),#q.pending))
        end
        if run then q.paused=false; q.revision=q.revision+1 end
      end
    end
    for index,kind in pairs(snap.direct) do note(index,at..'your '..kind..' was interrupted; start it again if it is still needed') end
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
