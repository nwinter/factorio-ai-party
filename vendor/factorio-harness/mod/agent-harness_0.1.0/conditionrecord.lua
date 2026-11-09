-- Persistent state by member position, recursively for compound conditions. No parent
-- pointer or metatable: records survive storage reloads and queue_status JSON copies.
return function(record,index)
  if not record then return nil end
  record.condition_members=record.condition_members or {}
  local child=record.condition_members[index]
  if not child then child={}; record.condition_members[index]=child end
  -- Timing belongs to the enclosing wait; baselines belong to the member. Refresh
  -- context after hold/resume without resetting the observations already kept here.
  child.start_tick=record.start_tick
  child.wait_started=record.wait_started
  child.started_tick=record.started_tick
  child.after_step=record.after_step
  return child
end
