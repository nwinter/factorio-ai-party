-- Run from repository root: lua tests/keep.lua
-- Requests under a paste (keep.lua): snapshot, compare, text, restore, the
-- blueprint's own sections, and the lines after a paste and in a dry run.
-- Engine behaviour checked on private 2.0.77 servers: restore put back a
-- switched-off section with its import planets; Astra's Starling hub
-- blueprint (shift12 19:16) pasted over the hub left it one empty manual
-- section, switched off, and switched its Request missing construction
-- materials off, which drops the game's construction section; a hub
-- blueprint with it on brings the section back (empty that tick, filled from
-- the ghosts the next).
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

-- Astra's Starling (shift12 19:16): the game's construction section (Request missing construction materials on:
-- fast-inserter 19, space-platform-foundation 624, crusher 3 from its ghosts) and one empty manual section. The fake
-- engine builds a hub blueprint over the hub as 2.0.77 did: the blueprint's request sections (one empty, switched
-- off) in place of the manual ones, and the construction section by the blueprint hub's setting (emptied that tick).
defines = {logistic_section_type={manual=0, circuit_controlled=1, transitional_request_controlled=2, request_missing_materials_controlled=3},
  build_mode={normal=0, forced=1, superforced=2}}
local function construction_section(filters) return {is_manual=false, type=3, group='', active=true, multiplier=1, filters=filters or {}} end
local function starling()
  return {construction_section({filter('fast-inserter', 19, nil, 'nauvis'), filter('space-platform-foundation', 624, nil, 'nauvis'),
    filter('crusher', 3, nil, 'nauvis')}), {is_manual=true, type=0, group='', active=true, multiplier=1, filters={}}}
end
local function engine_paste(flag)
  for i = #hub_list, 1, -1 do
    local s = hub_list[i]
    if s.is_manual or (s.type == 3 and not flag) then table.remove(hub_list, i) end
  end
  if flag and not (hub_list[1] and hub_list[1].type == 3) then table.insert(hub_list, 1, construction_section()) end
  if flag then hub_list[1].filters = {} end
  hub_list[#hub_list+1] = {is_manual=true, type=0, group='', active=false, multiplier=1, filters={}}
end
local builds, refuse = {}, nil
game = {create_inventory=function()
  local st = {}
  function st.set_stack() return true end
  function st.set_blueprint_entities(list) st.entities = list end
  function st.build_blueprint(args)
    if refuse then error(refuse, 0) end
    eq(#st.entities, 1); eq(st.entities[1].name, 'space-platform-hub'); eq(args.position, hub.position, 'over the hub')
    builds[#builds+1] = st.entities[1].request_missing_construction_materials
    engine_paste(st.entities[1].request_missing_construction_materials)
  end
  local inv = {st}
  function inv.destroy() end
  return inv
end}
hub.surface, hub.force = 'platform-2', 'player'
hub_list = starling()
eq(K.items_text(K.snapshot(hub).construction), 'fast-inserter 19, space-platform-foundation 624, crusher 3')
eq(K.text(K.snapshot(hub)), '0 sections', 'the game\'s section is not a manual one')
-- The dry run says the paste keeps them on.
eq(K.plan(surface, 'space-platform-hub', {x=0, y=0}, 0, false), 'space-platform-hub (0,0): its requests stay (0 sections); '
  ..'construction requests stay on (this blueprint\'s hub has Request missing construction materials off, which a paste switches off; '
  ..'the paste switches it back on): fast-inserter 19, space-platform-foundation 624, crusher 3')
eq(K.plan(surface, 'space-platform-hub', {x=0, y=0}, 0, true), 'space-platform-hub (0,0): its requests stay (0 sections); construction requests stay on')
-- Her paste: the blueprint's hub has it off. After it the section is gone; paste switches it back on (one build over
-- the hub with it on) and puts the manual section back as it was (switched on).
list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=0, construction=false}})
engine_paste(false)
eq(K.construction(hub), nil, 'the paste switched it off')
eq(K.after(list)[1], 'space-platform-hub (0,0): requests kept (0 sections; the paste had changed them and they were put back); '
  ..'construction requests kept on (the paste switched off Request missing construction materials, which this blueprint\'s hub has off; '
  ..'switched back on, the game refills them from the platform\'s ghosts within a second; before the paste: fast-inserter 19, '
  ..'space-platform-foundation 624, crusher 3)')
eq(#builds, 1); eq(builds[1], true)
assert(K.construction(hub), 'on again'); eq(#hub_list, 2); eq(hub_list[2].active, true, 'the manual section as before')
-- A blueprint whose hub has it on: on, nothing built.
builds = {}
hub_list = starling()
list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=0, construction=true}})
engine_paste(true)
eq(K.after(list)[1], 'space-platform-hub (0,0): requests kept (0 sections; the paste had changed them and they were put back); construction requests on')
eq(#builds, 0)
-- Off before: a blueprint with it on switches it on; one with it off says nothing of it.
hub_list = {{is_manual=true, type=0, group='', active=true, multiplier=1, filters={}}}
list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=0, construction=true}})
engine_paste(true)
eq(K.after(list)[1], 'space-platform-hub (0,0): requests kept (0 sections; the paste had changed them and they were put back); '
  ..'construction requests switched on by the blueprint\'s hub (the game fills them from the platform\'s ghosts within a second)')
hub_list = {{is_manual=true, type=0, group='', active=true, multiplier=1, filters={}}}
list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=0, construction=false}})
engine_paste(false)
eq(K.after(list)[1], 'space-platform-hub (0,0): requests kept (0 sections; the paste had changed them and they were put back)')
-- Switching back on refused: said, with the call that switches it.
hub_list = starling()
list = K.before(surface, {{name='space-platform-hub', position={x=0, y=0}, own=0, construction=false}})
engine_paste(false)
refuse = 'no room'
eq(K.after(list)[1], 'space-platform-hub (0,0): requests kept (0 sections; the paste had changed them and they were put back); '
  ..'construction requests off (the paste switched off Request missing construction materials, which this blueprint\'s hub has off; '
  ..'switching it back on failed: no room; before the paste: fast-inserter 19, space-platform-foundation 624, crusher 3); '
  ..'requests {platform, construction_requests: true} switches it on')
refuse = nil
-- The switch itself (requests construction_requests): off and on, the manual sections as they were.
hub_list = starling()
hub_list[2].filters = {filter('iron-plate', 50, nil, 'nauvis')}
eq(K.set_construction(hub, false), false); eq(K.construction(hub), nil)
eq(#hub_list, 1); eq(hub_list[1].active, true); eq(hub_list[1].filters[1].value.name, 'iron-plate', 'its request put back')
eq(K.set_construction(hub, true), true); eq(hub_list[1].type, 3); eq(hub_list[2].filters[1].value.name, 'iron-plate')
print('keep: ok')
