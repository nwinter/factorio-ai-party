local out = {}
for c = 1, 2 do
  local done, n = false, 0
  local last
  while not done and n < 40000 do
    n = n + 1
    local p = helpers.create_profiler()
    done = collectgarbage('step', 142)
    p.stop()
    last = p
  end
  out[#out + 1] = {'', 'cycle ', c, ' steps=', n, ' last step ', last, ' heap MB=', math.floor(collectgarbage('count') / 1024)}
end
for i = 1, #out do rcon.print(out[i]) end
