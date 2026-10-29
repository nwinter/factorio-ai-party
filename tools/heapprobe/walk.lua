local seen = {}
local function pow2(n) local s = 1 while s < n do s = s * 2 end return s end
local function walk(root, acc)
  local stack = {root}
  while #stack > 0 do
    local v = stack[#stack]
    stack[#stack] = nil
    local tv = type(v)
    if tv == 'table' and not seen[v] then
      seen[v] = true
      local n = #v
      local arr, hash = n, 0
      for k, x in pairs(v) do
        if not (type(k) == 'number' and k >= 1 and k <= n and k % 1 == 0) then hash = hash + 1 end
        local tk = type(k)
        if tk == 'table' or tk == 'string' then stack[#stack + 1] = k end
        local tx = type(x)
        if tx == 'table' or tx == 'string' then stack[#stack + 1] = x elseif tx == 'userdata' then acc.ud = acc.ud + 1 end
      end
      acc.tables = acc.tables + 1
      acc.entries = acc.entries + arr + hash
      acc.bytes = acc.bytes + 56 + arr * 16 + (hash > 0 and pow2(hash) * 40 or 0)
      if arr + hash > acc.biggest then acc.biggest = arr + hash end
    elseif tv == 'string' and not seen[v] then
      seen[v] = true
      acc.strings = acc.strings + 1
      acc.sbytes = acc.sbytes + 25 + #v
      acc.bytes = acc.bytes + 25 + #v
    end
  end
end
local rows = {}
local h = storage.agent_harness
for k, v in pairs(h) do
  local acc = {tables = 0, entries = 0, bytes = 0, strings = 0, sbytes = 0, ud = 0, biggest = 0}
  if type(v) == 'table' or type(v) == 'string' then walk(v, acc) end
  rows[#rows + 1] = {k = k, a = acc}
end
local other = {tables = 0, entries = 0, bytes = 0, strings = 0, sbytes = 0, ud = 0, biggest = 0}
for k, v in pairs(storage) do if k ~= 'agent_harness' then walk(v, other) end end
rows[#rows + 1] = {k = '(storage, not agent_harness)', a = other}
table.sort(rows, function(x, y) return x.a.bytes > y.a.bytes end)
local tot = {tables = 0, entries = 0, bytes = 0, strings = 0, ud = 0}
for _, r in ipairs(rows) do for f in pairs(tot) do tot[f] = tot[f] + r.a[f] end end
rcon.print('TOTAL bytes=' .. tot.bytes .. ' tables=' .. tot.tables .. ' entries=' .. tot.entries .. ' strings=' .. tot.strings .. ' userdata=' .. tot.ud .. ' heap_kb=' .. math.floor(collectgarbage('count')))
for i = 1, math.min(60, #rows) do
  local a = rows[i].a
  rcon.print('K ' .. tostring(rows[i].k) .. ' bytes=' .. a.bytes .. ' tables=' .. a.tables .. ' entries=' .. a.entries .. ' strings=' .. a.strings .. ' sbytes=' .. a.sbytes .. ' ud=' .. a.ud .. ' biggest=' .. a.biggest)
end
