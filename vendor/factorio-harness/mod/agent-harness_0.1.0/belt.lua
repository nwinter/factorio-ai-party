-- A character standing on a belt is carried by it (shift03: Astra's move_to
-- arrived on an eastbound belt and the game took her 22 tiles on). One search
-- of the character's tile, when an action ends and in status.
return function()
  local M = {}
  local TYPES = {'transport-belt', 'underground-belt', 'splitter', 'lane-splitter', 'loader', 'loader-1x1', 'linked-belt'}
  local BASE = {'transport-belt', 'underground-belt', 'splitter'}
  local names
  local function direction_name(d)
    if not names then
      names = {}
      for k, v in pairs(defines.direction or {}) do names[v] = k end
    end
    return names[d] or tostring(d)
  end
  -- The note for a character on a belt now; nil when not (or in a vehicle).
  function M.note(p)
    local ok, belt = pcall(function()
      if not (p and p.valid and p.character and p.character.valid) or p.driving then return nil end
      local x, y = math.floor(p.position.x), math.floor(p.position.y)
      local area = {{x, y}, {x + 1, y + 1}}
      local found, list = pcall(p.surface.find_entities_filtered, {area=area, type=TYPES, limit=1})
      if not found then list = p.surface.find_entities_filtered{area=area, type=BASE, limit=1} end
      return list[1]
    end)
    if not (ok and belt and belt.valid) then return nil end
    return string.format('standing on %s %s facing %s: it carries you; step off to stay put', belt.name:match('^[aeiou]') and 'an' or 'a',
      belt.name, direction_name(belt.direction))
  end
  return M
end
