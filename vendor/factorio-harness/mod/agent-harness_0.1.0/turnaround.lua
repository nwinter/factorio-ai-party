-- Shared submission/read argument checks; flight geometry is checked only by the live read.
local budgetwindows = require('budgetwindows')
local M = {}
local RA_FORM = 'turnaround.return_allowance is {legs, items: {item: count}, label, evidence_ticks?}: the caller\'s own count of each item over legs back after the connection\'s start, in place of the net rate x time there'
function M.check_allowance(ra)
  assert(type(ra) == 'table', RA_FORM)
  assert(type(ra.label) == 'string' and #ra.label >= 1 and #ra.label <= 200, 'turnaround.return_allowance.label is the source of the counts, 1..200 characters (said in the reply as given)')
  local legs = type(ra.legs) == 'string' and {ra.legs} or ra.legs
  assert(type(legs) == 'table' and #legs >= 1 and #legs <= 8, 'turnaround.return_allowance.legs: 1..8 legs back after the connection\'s start, each "from->to" as the reply\'s legs name them')
  local seen = {}
  for _, l in ipairs(legs) do
    assert(type(l) == 'string' and l:match('^[^%s]+%->[^%s]+$'), 'turnaround.return_allowance.legs: each is "from->to" (' .. tostring(l) .. ')')
    assert(not seen[l], 'turnaround.return_allowance.legs: ' .. l .. ' named twice')
    seen[l] = true
  end
  assert(type(ra.items) == 'table' and next(ra.items) ~= nil, 'turnaround.return_allowance.items is {item: count}: the count each takes over those legs')
  for k, n in pairs(ra.items) do
    assert(type(k) == 'string' and (prototypes.item[k] or (prototypes.fluid and prototypes.fluid[k])), 'turnaround.return_allowance.items: unknown item or fluid ' .. tostring(k))
    assert(type(n) == 'number' and n >= 0 and n <= 1e9, 'turnaround.return_allowance.items.' .. k .. ' is a count, 0 or more (no production is credited)')
  end
  assert(ra.evidence_ticks == nil or (type(ra.evidence_ticks) == 'table' and #ra.evidence_ticks >= 1 and #ra.evidence_ticks <= 8),
    'turnaround.return_allowance.evidence_ticks is a list of 1..8 game ticks (said in the reply as given)')
  for _, t in ipairs(ra.evidence_ticks or {}) do
    assert(type(t) == 'number' and t == math.floor(t) and t >= 0 and t <= game.tick, 'turnaround.return_allowance.evidence_ticks: game ticks up to now')
  end
  for k in pairs(ra) do
    assert(k == 'label' or k == 'legs' or k == 'items' or k == 'evidence_ticks', 'turnaround.return_allowance takes legs, items, label and evidence_ticks (' .. tostring(k) .. ')')
  end
end
function M.check(ta)
  assert(type(ta) == 'table', 'turnaround is {km | fraction, back_to?, speed_floor?, margin?, reserve?}')
  assert((ta.km == nil) ~= (ta.fraction == nil), 'turnaround.km | turnaround.fraction: exactly one is required (km farther out, or fraction of the connection from its start)')
  assert(ta.km == nil or (type(ta.km) == 'number' and ta.km >= 0 and ta.km <= 1e8), 'turnaround.km is 0..100000000 km farther out from here')
  assert(ta.fraction == nil or (type(ta.fraction) == 'number' and ta.fraction > 0 and ta.fraction <= 1), 'turnaround.fraction is above 0 up to 1')
  assert(ta.back_to == nil or (type(ta.back_to) == 'string' and prototypes.space_location[ta.back_to]), 'turnaround.back_to is a space location name')
  assert(ta.speed_floor == nil or (type(ta.speed_floor) == 'number' and ta.speed_floor > 0 and ta.speed_floor <= 10000), 'turnaround.speed_floor is km/s, above 0')
  assert(ta.margin == nil or (type(ta.margin) == 'number' and ta.margin >= 0 and ta.margin <= 2), 'turnaround.margin is 0..2 (a share kept spare; default 0.1)')
  assert(ta.reserve == nil or (type(ta.reserve) == 'number' and ta.reserve >= 0) or type(ta.reserve) == 'table', 'turnaround.reserve is a count for every item, or {item: count}')
  for k, n in pairs(type(ta.reserve) == 'table' and ta.reserve or {}) do
    assert(type(k) == 'string' and type(n) == 'number' and n >= 0, 'turnaround.reserve: {item: count}')
  end
  -- (d29 batch339 RB, Sol #2745) items: the ones that may bind (e.g. the ammunition and repair packs; the rest
  -- listed, not binding)
  assert(ta.items == nil or (type(ta.items) == 'table' and #ta.items >= 1 and #ta.items <= 32), 'turnaround.items is a list of 1..32 item or fluid names')
  for _, n in ipairs(ta.items or {}) do
    assert(type(n) == 'string' and (prototypes.item[n] or (prototypes.fluid and prototypes.fluid[n])), 'turnaround.items: unknown item or fluid ' .. tostring(n))
  end
  -- (d29 batch351 RA, Astra #2762) return_allowance: the caller's own count for legs back after the connection's
  -- start, in place of the net rate x time there; the harness takes it as given and labels it the caller's
  if ta.return_allowance ~= nil then M.check_allowance(ta.return_allowance) end
  return budgetwindows.config(ta.windows,ta.require,ta.missing)
end
return M
