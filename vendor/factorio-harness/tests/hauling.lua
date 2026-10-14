-- Run from repository root: lua tests/hauling.lua
-- Hand hauling (hauling.lua): items and calls by who started them (direct,
-- queue, standing order), the carry distance, the repeated hauls and the
-- operator read. The runtime's own path (a walking collect, a queue sweep)
-- is in mod/tests/runtime_test.lua.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
game = {tick=100}
local st, active, order = {}, {}, {}
local names = {[1]='gemini', [2]='grok'}
local H = dofile('mod/agent-harness_0.1.0/hauling.lua'){state=function() return st end,
  name=function(i) return names[i] end, active=function(i) return active[i] end, order_step=function(i) return order[i] end}
local function row(name)
  for _, r in ipairs(H.operator.hauling({}).agents) do if r.name == name then return r end end
end
local function s(name, count) return {name=name, count=count} end

-- A direct transfer: one call, however many entities it touches.
H.begin(1, 'direct')
H.moved(1, 'to_player', {x=0.5, y=0.5}, 'nauvis', {s('iron-plate', 50)}, 'steel-chest')
H.moved(1, 'to_player', {x=2.5, y=0.5}, 'nauvis', {s('iron-plate', 30)}, 'steel-chest')
H.done(1)
local r = row('gemini')
eq(r.items, 80); eq(r.calls, 1); eq(r.direct_items, 80); eq(r.direct_calls, 1); eq(r.queue_items, 0); eq(r.carry_tiles, 0)
-- Puts 30 tiles east, then 4 more: the carry is the legs, 30 then 4 (a chain of puts).
H.begin(1, 'direct')
H.moved(1, 'to_entity', {x=32.5, y=0.5}, 'nauvis', {s('iron-plate', 40)}, 'stone-furnace')
H.done(1)
H.begin(1, 'direct')
H.moved(1, 'to_entity', {x=32.5, y=4.5}, 'nauvis', {s('iron-plate', 40)}, 'stone-furnace')
H.done(1)
r = row('gemini')
eq(r.items, 160); eq(r.calls, 3); eq(r.carry_tiles, 34)
-- A queue step and a standing order's step.
H.begin(1, 'queue')
H.moved(1, 'to_entity', {x=32.5, y=0.5}, 'nauvis', {s('coal', 5), s('iron-plate', 1)}, 'stone-furnace')
H.done(1)
H.begin(1, 'order')
H.moved(1, 'to_entity', {x=32.5, y=8.5}, 'nauvis', {s('coal', 5)}, 'boiler')
H.done(1)
r = row('gemini')
eq(r.queue_items, 6); eq(r.queue_calls, 1); eq(r.order_items, 5); eq(r.order_calls, 1); eq(r.calls, 5); eq(r.items, 171)
-- A put of several items adds its longest leg once (iron from (33,5) is 4; coal had no spot before: none).
eq(r.carry_tiles, 34 + 4 + 8)
-- A timed action a direct call started moves on later ticks: the call's source, counted once.
local walk = {kind='gather'}
H.begin(2, 'queue')
active[2] = walk
H.done(2)
eq(walk.hauling_src, 'queue')
H.moved(2, 'to_player', {x=100, y=100}, 'nauvis', {s('copper-plate', 10)}, 'stone-furnace')
H.moved(2, 'to_player', {x=110, y=100}, 'nauvis', {s('copper-plate', 10)}, 'stone-furnace')
r = row('grok')
eq(r.queue_items, 20); eq(r.queue_calls, 1); eq(r.direct_calls, 0)
-- An untagged running action: its queued flag and the queue's current step decide.
local orderly = {kind='feed', queued=true}
active[2] = orderly; order[2] = 'boilerfuel'
H.moved(2, 'to_entity', {x=110, y=104}, 'nauvis', {s('copper-plate', 20)}, 'assembling-machine-2')
r = row('grok')
eq(r.order_items, 20); eq(r.order_calls, 1); eq(orderly.hauling_src, 'order')
active[2] = nil; order[2] = nil
-- A pickup's end (runtime.lua finish) names its action: a direct one counts as its own call.
local pick = {kind='pickup', hauling_src='direct'}
H.begin(2, 'direct') -- another request running at that moment does not take it
H.moved(2, 'to_player', {x=0, y=0}, 'nauvis', {s('wood', 4)}, nil, pick)
H.done(2)
r = row('grok')
eq(r.direct_items, 4); eq(r.direct_calls, 1)
-- Another surface: no leg; a leg over 400 tiles: none.
H.begin(2, 'direct'); H.moved(2, 'to_entity', {x=0, y=0}, 'vulcanus', {s('copper-plate', 1)}, 'chest'); H.done(2)
H.begin(2, 'direct'); H.moved(2, 'to_player', {x=0, y=0}, 'nauvis', {s('stone', 1)}, 'chest'); H.done(2)
H.begin(2, 'direct'); H.moved(2, 'to_entity', {x=900, y=0}, 'nauvis', {s('stone', 1)}, 'chest'); H.done(2)
eq(row('grok').carry_tiles, 4)
-- Nothing moved: no call.
H.begin(2, 'direct'); H.moved(2, 'to_entity', {x=0, y=0}, 'nauvis', {}, 'chest'); H.done(2)
eq(row('grok').calls, 6)

-- Repeated hauls: puts grouped by item, the cell taken from and the cell put to (10 tiles).
for i = 1, 12 do
  H.begin(1, 'queue')
  H.moved(1, 'to_player', {x=-48.5, y=73.5}, 'fulgora', {s('solid-fuel', 20)}, 'passive-provider-chest')
  H.moved(1, 'to_entity', {x=-64 + (i % 2), y=71}, 'fulgora', {s('solid-fuel', 20)}, 'stone-furnace')
  H.done(1)
end
r = row('gemini')
local top = r.hauls[1]
eq(top.item, 'solid-fuel'); eq(top.times, 12); eq(top.items, 240); eq(top.surface, 'fulgora')
eq(top.from.x, -48); eq(top.from.y, 74); eq(top.to_name, 'stone-furnace')
-- A put of an item never taken by hand has no from.
local nofrom
for _, h in ipairs(r.hauls) do if h.item == 'coal' then nofrom = h end end
eq(nofrom.from, nil); eq(nofrom.times, 2)
eq(#H.operator.hauling({top=1}).agents[1].hauls, 1)
eq(H.operator.hauling({top=0}).agents[1].hauls, nil)
assert(not pcall(H.operator.hauling, {top=99}))
-- At most 100 kept per agent: the fewest go.
for i = 1, 120 do
  H.begin(1, 'direct'); H.moved(1, 'to_entity', {x=i * 20, y=500}, 'nauvis', {s('stone-brick', 1)}, 'chest'); H.done(1)
end
local kept = 0
for _ in pairs(st.hauling[1].hauls) do kept = kept + 1 end
eq(kept, 100); eq(row('gemini').hauls[1].item, 'solid-fuel')
-- The read: rows by name, with the tick.
local all = H.operator.hauling({})
eq(all.agents[1].name, 'gemini'); eq(all.agents[2].name, 'grok'); eq(all.tick, 100); eq(all.agents[1].since_tick, 100)
print('hauling: ok')
