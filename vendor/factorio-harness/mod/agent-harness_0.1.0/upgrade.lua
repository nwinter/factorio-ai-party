-- upgrade {position | positions | area, to | map, from?} (C8, Astra 15:20: a Von Braun belt change took 174
-- deconstruct calls and a full repaste): what the upgrade planner does. A ghost is changed in place to the other
-- entity of its kind (checked on the copy of world n: a turbo-transport-belt ghost became a transport-belt ghost, its
-- direction kept; an inserter ghost became a fast-inserter ghost with its filter and red wire kept); a built entity
-- is marked for upgrade, which construction robots carry out with the item. Ours only, in a chunk our force sees
-- (in sight or remote view, as the planner works on the map). The target must share the entity's fast-replace group
-- and size, as the planner requires.
return function(api)
  local M = {}
  local MAX, AREA = 512, 128
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function size(proto)
    local b = proto and proto.collision_box
    if not b then return nil end
    return string.format('%.2fx%.2f', b.right_bottom.x - b.left_top.x, b.right_bottom.y - b.left_top.y)
  end
  function M.run(p, a)
    local map = {}
    if a.map ~= nil then
      assert(type(a.map) == 'table' and next(a.map) ~= nil and a.to == nil and a.from == nil, 'map is {from_name: to_name, ...} (not with to or from)')
      for f, t in pairs(a.map) do
        assert(prototypes.entity[f] and prototypes.entity[t], 'map: unknown entity ' .. tostring(prototypes.entity[f] and t or f))
        map[f] = t
      end
    else
      assert(type(a.to) == 'string' and prototypes.entity[a.to], 'to must be an entity name (the upgrade target)')
      assert(a.from == nil or (type(a.from) == 'string' and prototypes.entity[a.from]), 'from must be an entity name')
    end
    local found = {}
    if a.area ~= nil then
      local lt, rb = api.position(a.area.left_top or a.area[1]), api.position(a.area.right_bottom or a.area[2])
      assert(rb.x > lt.x and rb.y > lt.y and rb.x - lt.x <= AREA and rb.y - lt.y <= AREA, 'area must be nonempty and at most 128x128')
      api.read_sight(p, {x=(lt.x + rb.x) / 2, y=(lt.y + rb.y) / 2}, 'area')
      found = p.surface.find_entities_filtered{area={lt, rb}, force=p.force, limit=MAX + 1}
    else
      local list = a.positions or (a.position ~= nil and {a.position}) or nil
      assert(type(list) == 'table' and #list >= 1 and #list <= MAX, 'give position, positions (1..512) or area')
      for _, raw in ipairs(list) do
        local q = api.position(raw)
        api.read_sight(p, q, 'target')
        for _, e in ipairs(p.surface.find_entities_filtered{position=q, radius=0.3, force=p.force}) do found[#found+1] = e end
      end
    end
    local ghosts, marked, skipped, need = 0, 0, {}, {}
    local seen = {}
    local function skip(text) if #skipped < 8 then skipped[#skipped+1] = text end end
    local n = 0
    for _, e in ipairs(found) do
      if e.valid and not seen[e] then
        seen[e] = true
        local ghost = e.type == 'entity-ghost'
        local name = ghost and e.ghost_name or e.name
        local to
        if a.map then to = map[name] elseif a.from == nil or a.from == name then to = a.to end
        if to and to ~= name and e.type ~= 'tile-ghost' then
          n = n + 1
          if n > MAX then break end
          local from_p, to_p = prototypes.entity[name], prototypes.entity[to]
          local g1, g2 = try(function() return from_p.fast_replaceable_group end), try(function() return to_p.fast_replaceable_group end)
          if not g1 or g1 ~= g2 or size(from_p) ~= size(to_p) then
            skip(string.format('%s%s %s: %s is not of its kind (fast-replace group %s, size %s; %s: %s, %s)', ghost and 'ghost of ' or '', name, at(e.position), to,
              tostring(g1), tostring(size(from_p)), to, tostring(g2), tostring(size(to_p))))
          else
            local pos = {x=e.position.x, y=e.position.y}
            local ok, r = pcall(function() return e.order_upgrade{target=to, force=p.force, player=api.real and api.real(p) or nil} end)
            if not ok or r == false then skip(string.format('%s %s: the game refused the upgrade%s', name, at(pos), ok and '' or ': ' .. tostring(r)))
            elseif ghost then
              local now
              for _, g in ipairs(p.surface.find_entities_filtered{position=pos, radius=0.3, type='entity-ghost', force=p.force}) do if g.ghost_name == to then now = g end end
              if now then ghosts = ghosts + 1 else skip(string.format('ghost of %s %s: still %s after the upgrade order', name, at(pos), name)) end
            else
              marked = marked + 1
              need[to] = (need[to] or 0) + 1
            end
          end
        end
      end
    end
    local needs = {}
    for k, v in pairs(need) do needs[#needs+1] = v .. ' ' .. k end
    table.sort(needs)
    return {ghosts_upgraded=ghosts, marked_for_upgrade=marked, skipped=#skipped > 0 and skipped or nil, capped=n > MAX and MAX or nil,
      line=string.format('%d ghost%s changed in place (wires and settings kept); %d built entit%s marked for upgrade%s', ghosts, ghosts == 1 and '' or 's',
        marked, marked == 1 and 'y' or 'ies', marked > 0 and ' (construction robots replace them with ' .. table.concat(needs, ', ') .. ' from the network or hub)' or '')}
  end
  M.schema = {upgrade = {position='{x,y}: the entity or ghost there', positions='or 1..512 positions', area='or {left_top, right_bottom} up to 128x128',
    to='the entity name to upgrade (or downgrade) to, of the same kind (fast-replace group and size)', from='optional: only entities or ghosts of this name',
    map='or {from_name: to_name, ...} (several kinds at once, e.g. {"turbo-transport-belt": "transport-belt", "turbo-underground-belt": "underground-belt"})',
    surface='optional planet name: by remote view there', platform='optional platform name',
    returns='as the upgrade planner: ghosts_upgraded (a ghost is changed in place, its wires and settings kept), marked_for_upgrade (a built one is marked; robots replace it with the item), skipped (another kind, refused), line'}}
  return M
end
