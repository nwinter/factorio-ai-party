local function pow2(n) local s = 1 while s < n do s = s * 2 end return s end
local function est(root)
  local seen, stack, b = {}, {root}, 0
  while #stack > 0 do
    local v = stack[#stack] stack[#stack] = nil
    if type(v) == 'table' and not seen[v] then
      seen[v] = true
      local n, h = #v, 0
      for k, x in pairs(v) do
        if not (type(k) == 'number' and k >= 1 and k <= n and k % 1 == 0) then h = h + 1 end
        if type(k) == 'table' then stack[#stack + 1] = k end
        if type(x) == 'table' then stack[#stack + 1] = x end
      end
      b = b + 56 + n * 16 + (h > 0 and pow2(h) * 40 or 0)
    end
  end
  return b
end
local function copy(v, seen)
  if type(v) ~= 'table' then return v end
  if seen[v] then return seen[v] end
  local t = {} seen[v] = t
  for k, x in pairs(v) do t[copy(k, seen)] = copy(x, seen) end
  return t
end
local out = {}
for _, key in ipairs({'belt_memory', 'asteroid_watch', 'ores', 'census', 'podlog'}) do
  local src = storage.agent_harness[key]
  local e = est(src)
  collectgarbage('collect') collectgarbage('collect')
  local kb0 = collectgarbage('count')
  local c = copy(src, {})
  collectgarbage('collect') collectgarbage('collect')
  local kb1 = collectgarbage('count')
  c = nil
  out[#out + 1] = key .. ': model tables ' .. math.floor(e / 1024) .. ' KB, copy measured ' .. math.floor(kb1 - kb0) .. ' KB'
end
collectgarbage('collect')
rcon.print(table.concat(out, '; '))
