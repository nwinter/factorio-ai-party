collectgarbage('collect') collectgarbage('collect') collectgarbage('collect')
local kb0 = collectgarbage('count')
local f = load(storage.agent_harness.source, '@b334-probe', 't', _ENV)
collectgarbage('collect') collectgarbage('collect') collectgarbage('collect')
local kb1 = collectgarbage('count')
local m = f()
collectgarbage('collect') collectgarbage('collect') collectgarbage('collect')
local kb2 = collectgarbage('count')
f = nil
m = nil
collectgarbage('collect') collectgarbage('collect') collectgarbage('collect')
local kb3 = collectgarbage('count')
local seq={} for i=1,4 do collectgarbage('collect') seq[#seq+1]=math.floor(collectgarbage('count')/1024) end rcon.print('more collects: '..table.concat(seq,' ')) rcon.print('live MB ' .. math.floor(kb0 / 1024) .. '; compiled chunk +' .. math.floor((kb1 - kb0) / 1024) .. ' MB; modules built +' .. math.floor((kb2 - kb1) / 1024) .. ' MB; after drop ' .. math.floor(kb3 / 1024) .. ' MB')
