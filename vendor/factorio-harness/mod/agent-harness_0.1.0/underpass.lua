-- Why an underground belt or pipe-to-ground has no partner (operator 15:48:
-- Sol's two Vulcanus pairs spanned lava and stayed unpaired, a rebuild too;
-- the 8 paired ones spanned none). The runtime API does not expose an
-- underground's own collision mask (it is data-stage only), so the tiles
-- checked are the ones the pipe router also keeps undergrounds from:
-- lava (collision layer lava_tile) and empty space (empty_space). Facts only.
return function(api)
  local M = {}
  local STEP = {[0]={0, -1}, [4]={1, 0}, [8]={0, 1}, [12]={-1, 0}}
  local OPPOSITE = {[0]=8, [4]=12, [8]=0, [12]=4}
  local NAMES = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local BLOCKING = {lava_tile='lava', empty_space='empty space'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Name, type and kind of an underground or its ghost.
  local function what(e)
    if e.type == 'entity-ghost' then return e.ghost_name, e.ghost_type end
    return e.name, e.type
  end
  local function belt_end(e) return try(function() return e.belt_to_ground_type end) end
  -- The tiles between e and where its partner could be, its partner (or the
  -- nearest same-name end on its axis), and what of those tiles it cannot pass.
  -- end_hint: a belt ghost's end as it was placed (a ghost may not read it back).
  function M.span(e, end_hint)
    local name, kind = what(e)
    if kind ~= 'underground-belt' and kind ~= 'pipe-to-ground' then return nil end
    local dir = e.direction or 0
    local reach = try(function() return prototypes.entity[name].max_underground_distance end) or 0
    -- Where the partner lies: a belt entrance downstream, an exit upstream;
    -- a pipe-to-ground away from its above-ground connection.
    local this_end = kind == 'underground-belt' and (belt_end(e) or end_hint) or nil
    local toward = kind == 'pipe-to-ground' and OPPOSITE[dir] or (this_end == 'output' and OPPOSITE[dir] or dir)
    local step = STEP[toward]
    if not step then return nil end
    local out = {name=name, kind=kind, ['end']=this_end, reach=reach, toward=toward, blocked={}}
    local x, y = e.position.x, e.position.y
    for k = 1, reach do
      local px, py = x + step[1] * k, y + step[2] * k
      local found
      for _, o in pairs(try(function() return e.surface.find_entities_filtered{position={x=px, y=py}, radius=0.3} end) or {}) do
        local oname, okind = what(o)
        if o.valid and o ~= e and oname == name and okind == kind then found = o; break end
      end
      if found then
        out.other = found
        out.other_ghost = found.type == 'entity-ghost' or nil
        -- A partner: a belt end of the other kind flowing the same way, or a
        -- pipe-to-ground facing back.
        if kind == 'underground-belt' then
          out.matches = found.direction == dir and belt_end(found) ~= this_end
        else
          out.matches = found.direction == OPPOSITE[dir]
        end
        break
      end
      local layers = try(function() return e.surface.get_tile(math.floor(px), math.floor(py)).prototype.collision_mask.layers end)
      for layer, word in pairs(BLOCKING) do
        if layers and layers[layer] then
          local tile = try(function() return e.surface.get_tile(math.floor(px), math.floor(py)).name end) or word
          out.blocked[#out.blocked+1] = {x=math.floor(px), y=math.floor(py), tile=tile}
          break
        end
      end
    end
    return out
  end
  -- One line on why e is unpaired (nil when it is paired, or not an underground).
  function M.why(e, end_hint)
    local s = M.span(e, end_hint)
    if not s then return nil end
    local label = s.kind == 'underground-belt' and ('the ' .. (s['end'] == 'input' and 'output' or 'input')) or 'its partner'
    local parts = {}
    if #s.blocked > 0 then
      local tiles = {}
      for i, t in ipairs(s.blocked) do
        if i > 4 then tiles[#tiles+1] = '+' .. (#s.blocked - 4) .. ' more'; break end
        tiles[#tiles+1] = string.format('%s at (%d,%d)', t.tile, t.x, t.y)
      end
      parts[#parts+1] = 'it cannot pass under ' .. table.concat(tiles, ', ')
    end
    if s.other and s.matches then
      parts[#parts+1] = string.format('%s at (%g,%g)%s', label, s.other.position.x, s.other.position.y,
        s.other_ghost and ' is still a ghost' or (#s.blocked > 0 and ' is on the far side' or ' is in reach and the game did not pair them'))
    elseif s.other then
      local oend = s.kind == 'underground-belt' and belt_end(s.other)
      parts[#parts+1] = string.format('the nearest %s on its axis, at (%g,%g), is %s', s.name, s.other.position.x, s.other.position.y,
        s.kind == 'underground-belt' and string.format('an %s flowing %s', tostring(oend), NAMES[s.other.direction] or '?')
          or ('facing ' .. (NAMES[s.other.direction] or '?')))
    else
      parts[#parts+1] = string.format('no %s %s within %d tiles %s', s.name,
        s.kind == 'underground-belt' and (s['end'] == 'input' and 'output' or 'input') or 'end', s.reach, NAMES[s.toward] or '?')
    end
    return table.concat(parts, '; ')
  end
  return M
end
