-- The latest belt watch remains at belt_flow[index] for old saves and callers.
-- Up to four watches per agent, including completed results. Running watches are never evicted.
local M = {LIMIT=4}
function M.list(s, kind, index)
  local out = {}
  local latest = (s[kind] or {})[index]
  if latest then out[1] = latest end
  if kind == 'belt_flow' then
    for _, job in ipairs((s.belt_flow_kept or {})[index] or {}) do out[#out+1] = job end
  end
  return out
end
function M.find(s, index, id)
  if id == nil then return (s.belt_flow or {})[index] end
  for _, job in ipairs(M.list(s, 'belt_flow', index)) do if job.id == id then return job end end
end
function M.room(s, index, replacing)
  local list, oldest = M.list(s, 'belt_flow', index)
  for _, job in ipairs(list) do
    if job == replacing then return end
    if job.result and (not oldest or (job.serial or 0) < (oldest.serial or 0)) then oldest = job end
  end
  assert(#list < M.LIMIT or oldest, 'belt_flow: all 4 watch slots are sampling; no watch replaced; each ends at until_tick')
  return #list >= M.LIMIT and oldest or nil
end
function M.add(s, index, job, replacing, evict)
  local kept = {}
  for _, old in ipairs(M.list(s, 'belt_flow', index)) do
    if old ~= replacing and old ~= evict then kept[#kept+1] = old end
  end
  s.belt_flow_kept = s.belt_flow_kept or {}; s.belt_flow_kept[index] = kept
  s.belt_flow = s.belt_flow or {}; s.belt_flow[index] = job
end
return M
