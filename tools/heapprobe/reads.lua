collectgarbage('collect')
collectgarbage('stop')
local f = game.forces.player
local pl1 = nil
for _, x in pairs(f.platforms) do pl1 = x break end
local p = game.get_player(1) or game.connected_players[1]
local N = 1000
local function m(label, fn)
  local kb0 = collectgarbage('count')
  local t = helpers.create_profiler()
  for i = 1, N do fn() end
  t.stop()
  local kb1 = collectgarbage('count')
  return {'', label, ' ', math.floor((kb1 - kb0) * 1024 / N), ' B a read; ', t, '\n'}
end
local nplat = table_size(f.platforms)
local out = {'', 'platforms=', nplat, ' players=', #game.players, '\n'}
local rows = {
  m('f.platforms', function() local x = f.platforms end),
  m('pl.surface', function() local x = pl1.surface end),
  m('game.forces', function() local x = game.forces end),
  m('f.players', function() local x = f.players end),
  m('e.position', function() local x = pl1.surface.name end),
  m('closure+pcall', function() local ok, x = pcall(function() return 1 end) end),
  m('table {a,b,c}', function() local x = {1, 2, 3} end),
  m('number..string', function() local x = 'k' .. 12345 end),
}
collectgarbage('restart')
for _, r in ipairs(rows) do rcon.print(r) end
rcon.print(out)
