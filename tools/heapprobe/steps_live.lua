
local out = {}
local done = false
local n = 0
local total = helpers.create_profiler()
while not done and n < 40000 do
  n = n + 1
  local p = helpers.create_profiler()
  done = collectgarbage('step', 142)
  p.stop()
  out[#out + 1] = {'', 'S ', n, ' ', p, ' kb=', math.floor(collectgarbage('count'))}
end
total.stop()
rcon.print({'', 'steps=', n, ' done=', tostring(done), ' total ', total})
for i = 1, #out do rcon.print(out[i]) end
