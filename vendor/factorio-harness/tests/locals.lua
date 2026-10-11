-- Run from repository root: lua tests/locals.lua
-- Lua allows 200 locals per function. A fresh world loads runtime.lua through
-- the mod as its own chunk (the hot-deploy bundle wraps it in a function, which
-- hides this), so one local past 200 breaks every new world at load. Count the
-- free top-level slots by compiling each chunk with N extra locals in front;
-- fail when fewer than MIN_FREE are left.
local MIN_FREE = 3
local DIR = 'mod/agent-harness_0.1.0/'
local function read(path)
  local f = assert(io.open(path, 'r'))
  local text = f:read('a')
  f:close()
  return text
end
-- Free top-level local slots in a chunk: the most extra locals it still compiles with.
local function free(source, name)
  local ok, err = load(source, '=' .. name)
  if not ok then error(name .. ' does not compile: ' .. tostring(err), 0) end
  local function fits(n)
    local pad = {}
    for i = 1, n do pad[i] = '_pad' .. i end
    -- Same first line, so the chunk's line numbers stay as they are.
    return load('local ' .. table.concat(pad, ',') .. ' ' .. source, '=' .. name) ~= nil
  end
  local low, high = 0, 200 -- fits(low) holds; find the largest n that fits
  while low < high do
    local mid = math.floor((low + high + 1) / 2)
    if fits(mid) then low = mid else high = mid - 1 end
  end
  return low
end
local checked = {'runtime.lua', 'control.lua'}
local failures = {}
for _, file in ipairs(checked) do
  local left = free(read(DIR .. file), file)
  print(string.format('locals: %s has %d of 200 top-level local slots free', file, left))
  if left < MIN_FREE then
    failures[#failures+1] = string.format('%s has only %d of Lua\'s 200 top-level locals free (a fresh world loads it as its own chunk; '
      .. 'at 201 every new world fails to load). Move helpers into a module (require) or group them in a table '
      .. '(see docs/HARNESS3-NOTES.md, "runtime.lua locals"); do not add top-level locals', file, left)
  end
end
assert(#failures == 0, table.concat(failures, '\n'))
-- The counter itself: a chunk at the limit has 0 free, one below has 1.
local full = {}
for i = 1, 199 do full[i] = 'local v' .. i .. '=' .. i end
assert(free(table.concat(full, '\n'), 'full199') == 1, 'counter: 199 locals leave 1')
full[199] = nil
assert(free(table.concat(full, '\n'), 'full198') == 2 and 2 < MIN_FREE, 'counter: 198 locals leave 2, which fails the guard')
full[199] = 'local v199=199'
full[200] = 'local v200=200'
assert(free(table.concat(full, '\n'), 'full200') == 0, 'counter: 200 locals leave 0')
print('locals: ok')
