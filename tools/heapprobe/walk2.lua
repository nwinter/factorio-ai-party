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
local out = {}
for _, key in ipairs({'belt_memory', 'asteroid_watch', 'ores', 'fog_memory', 'census', 'ghost_log', 'read_memory', 'podlog', 'platform_alerts', 'lost_log', 'flightwatch', 'efficiency'}) do
  local rows = {}
  local n = 0
  for k, v in pairs(storage.agent_harness[key] or {}) do
    n = n + 1
    local acc = {tables = 0, entries = 0, bytes = 0, strings = 0, sbytes = 0, ud = 0, biggest = 0}
    walk(v, acc)
    rows[#rows + 1] = {k = k, a = acc}
  end
  table.sort(rows, function(x, y) return x.a.bytes > y.a.bytes end)
  local parts = {}
  for i = 1, math.min(5, #rows) do parts[#parts + 1] = tostring(rows[i].k) .. '=' .. math.floor(rows[i].a.bytes / 1024) .. 'KB/' .. rows[i].a.tables .. 't/' .. rows[i].a.entries .. 'e' end
  out[#out + 1] = key .. ' (' .. n .. ' children): ' .. table.concat(parts, ', ')
end
for i = 1, #out do rcon.print(out[i]) end
