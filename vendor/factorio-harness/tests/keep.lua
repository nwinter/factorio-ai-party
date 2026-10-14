-- Run from repository root: lua tests/keep.lua
-- Requests under a paste (keep.lua): snapshot, compare, text, restore, the
-- blueprint's own sections, and the lines after a paste and in a dry run.
-- Engine behaviour checked on a private 2.0.77 server: a paste over a hub
-- (Astra's 08:41 blueprint without requests, and a hub blueprint with them)
-- left the hub's sections as they were; restore put back a switched-off
-- section with its import planets.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
prototypes = {entity={['space-platform-hub']={type='space-platform-hub'}, ['requester-chest']={type='logistic-container'}, ['iron-chest']={type='container'}}}
local K = dofile('mod/agent-harness_0.1.0/keep.lua'){}
-- Fake logistic sections as the engine keeps them.
local function sections(list)
  local secs = {}
  setmetatable(secs, {__index=function(_, k) if k == 'sections_count' then return #list end end})
  function secs.get_section(i) return list[i] end
  function secs.remove_section(i) table.remove(list, i) end
  function secs.add_section(group) local s = {is_manual=true, group=group or '', active=true, multiplier=1, filters={}}; list[#list+1] = s; return s end
  return secs
end
local function filter(name, min, max, from) return {value={type='item', name=name, quality='normal', comparator='='}, min=min, max=max, import_from=from and {name=from} or nil} end
local hub_list = {{is_manual=false, group='', active=true, multiplier=1, filters={}},
  {is_manual=true, group='', active=false, multiplier=1, filters={filter('calcite', 500, 500, 'vulcanus'), filter('iron-plate', 1000, 1000, 'vulcanus')}}}
local hub = {valid=true, name='space-platform-hub', position={x=0, y=0}, get_logistic_sections=function() return sections(hub_list) end}

local snap = K.snapshot(hub)
eq(#snap.sections, 2); eq(snap.sections[2].filters[1].import_from, 'vulcanus'); eq(snap.sections[2].active, false)
eq(K.text(snap), '1 section, 1 off', 'the game\'s own section does not count')
eq(K.same(snap, K.snapshot(hub)), true)
-- Changed: the section's filters cleared, switched on, a section added; restore puts it back.
hub_list[2].filters = {}; hub_list[2].active = true
hub_list[3] = {is_manual=true, group='', active=true, multiplier=1, filters={filter('coal', 5)}}
eq(K.same(snap, K.snapshot(hub)), false)
K.restore(hub, snap)
eq(#hub_list, 2); eq(hub_list[1].is_manual, false, 'the game\'s section stays'); eq(hub_list[2].active, false)
eq(hub_list[2].filters[2].value.name, 'iron-plate'); eq(hub_list[2].filters[1].import_from, 'vulcanus')
eq(K.same(snap, K.snapshot(hub)), true, 'as before')
eq(K.bp_sections({request_filters={sections={{index=1}, {index=2, filters={{name='calcite'}}}}}}), 1)
eq(K.bp_sections({name='space-platform-hub'}), 0)

-- Before and after a paste: kept; the blueprint's own not applied; changed with none of its own: put back.
local surface = {find_entities_filtered=function(f) if f.name == 'space-platform-hub' and f.position.x == 0 then return {hub} end return {} end}
local list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=0}, {name='iron-chest', position={x=3, y=3}, own=0}})
eq(#list, 1, 'only entities with requests')
eq(K.after(list)[1], 'space-platform-hub (0,0): requests kept (1 section, 1 off)')
list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=2}})
eq(K.after(list)[1], 'space-platform-hub (0,0): requests kept (1 section, 1 off); the blueprint\'s own requests (2 sections) are not applied by a paste')
list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=0}})
hub_list[2].filters = {}
eq(K.after(list)[1], 'space-platform-hub (0,0): requests kept (1 section, 1 off; the paste had changed them and they were put back)')
eq(hub_list[2].filters[1].value.name, 'calcite')
list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=1}})
hub_list[2].filters = {filter('stone', 7)}
eq(K.after(list)[1], 'space-platform-hub (0,0): replaced by the blueprint\'s (1 section, 1 off)')
-- The dry run's line.
eq(K.plan(surface, 'space-platform-hub', {x=0, y=0}, 1), 'space-platform-hub (0,0): its requests stay (1 section, 1 off); the blueprint\'s own requests (1 section) are not applied by a paste')
eq(K.plan(surface, 'iron-chest', {x=3, y=3}, 0), nil)
print('keep: ok')
