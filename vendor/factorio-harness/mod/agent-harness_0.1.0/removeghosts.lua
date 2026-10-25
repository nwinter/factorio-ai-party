-- remove_ghosts (d24 batch144 PP1, Luna #2137: staging ghosts placed with place_ghosts in a charted area no
-- construction area covers, saved as a blueprint, could not be taken back: deconstruct {dry_run} on a 24-ghost copy
-- read would_mark 0). In 2.0 a player in remote view removes ghosts anywhere the map is charted, as the deconstruction
-- planner does. This takes entity ghosts of ours (tile ghosts only with tiles: true) in an area or at positions on one
-- surface; never a built entity or a tile. Whose a ghost is: the harness's placement record (ghostlog.lua: the agent
-- whose place_ghosts, route, paste or blueprint_place put it down), else the game's last user (a player who placed it).
-- By default only one's own; owner: "any" or an agent's name widens it, and the reply lists them by owner.
return function(api)
  local M = {}
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.NAMES = 32
  local MAX_FIND, MAX_REMOVE, MAX_ROWS, MAX_SIDE, MAX_POSITIONS = 4096, 256, 64, 256, 64
  M.MAX_POSITIONS = MAX_POSITIONS  -- (d25 batch208 QU1) also a queue step's check (runtime.lua step_lengths)
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function area_of(v)
    assert(type(v) == 'table', 'area is {left_top, right_bottom} or [[x1,y1],[x2,y2]]')
    local a = api.position(v.left_top or v[1])
    local b = api.position(v.right_bottom or v[2])
    local box = {{math.min(a.x, b.x), math.min(a.y, b.y)}, {math.max(a.x, b.x), math.max(a.y, b.y)}}
    assert(box[2][1] - box[1][1] <= MAX_SIDE and box[2][2] - box[1][2] <= MAX_SIDE, 'area is at most ' .. MAX_SIDE .. ' tiles a side')
    return box
  end
  local function names_of(v)
    if v == nil then return nil end
    local list = type(v) == 'string' and {v} or v
    assert(type(list) == 'table' and #list >= 1 and #list <= M.NAMES, 'names: 1..' .. M.NAMES .. ' entity or tile names (or one)')
    for _, n in ipairs(list) do assert(type(n) == 'string' and n ~= '', 'names: 1..' .. M.NAMES .. ' entity or tile names (or one)') end
    return list
  end
  local function by_text(t)
    local list = {}
    for k, c in pairs(t) do list[#list+1] = {k, c} end
    table.sort(list, function(x, y) if x[2] ~= y[2] then return x[2] > y[2] end return x[1] < y[1] end)
    local parts = {}
    for i, e in ipairs(list) do parts[i] = e[2] .. ' ' .. e[1] end
    return #parts > 0 and table.concat(parts, ', ') or nil
  end
  local function key(g)
    local u = try(function() return g.unit_number end)
    if u then return u end
    return g.type .. '|' .. tostring(try(function() return g.ghost_name end)) .. '|' .. g.position.x .. ',' .. g.position.y
  end

  function M.handler(p, a)
    assert(a.dry_run == nil or type(a.dry_run) == 'boolean', 'dry_run must be true or false')
    assert(a.tiles == nil or type(a.tiles) == 'boolean', 'tiles must be true or false')
    assert(a.owner == nil or (type(a.owner) == 'string' and a.owner ~= ''), 'owner: "any", or an agent\'s name (default: yours)')
    assert((a.area ~= nil) ~= (a.positions ~= nil), 'remove_ghosts takes area or positions (one of them)')
    local dry = a.dry_run == true
    -- (cp2) while the placement records' position index is built after a harness update (a few hundred ring slots a
    -- tick), whose ghost is whose is not read
    local ix = api.index_state and api.index_state()
    if ix then
      error(string.format('nothing removed: the ghost placement records are being indexed after a harness update (%d of %d record slots read, %d a tick, about %.1f s left); remove_ghosts answers once that is done',
        ix.read, ix.of, ix.slice or 512, (ix.of - ix.read) / (ix.slice or 512) / 60), 0)
    end
    local s, f = p.surface, p.force
    local who = api.who(p)
    local names = names_of(a.names)
    local filter = {type=a.tiles and {'entity-ghost', 'tile-ghost'} or 'entity-ghost', force=f, limit=MAX_FIND}
    if names then filter.ghost_name = names end
    local found, seen, scope = {}, {}, nil
    -- (positions can find one ghost twice; an area's one search cannot)
    local function take(list)
      for _, g in ipairs(list or {}) do
        if g.valid then
          local k = key(g)
          if not seen[k] then seen[k] = true; found[#found+1] = g end
        end
      end
    end
    if a.area ~= nil then
      local box = area_of(a.area)
      filter.area = box
      found = s.find_entities_filtered(filter)
      scope = string.format('in the area (%g,%g)-(%g,%g) on %s', box[1][1], box[1][2], box[2][1], box[2][2], s.name)
    else
      local list = a.positions
      assert(type(list) == 'table' and #list >= 1 and #list <= MAX_POSITIONS, 'positions: 1..' .. MAX_POSITIONS .. ' {x, y}')
      for _, q in ipairs(list) do
        local pos = api.position(q)
        filter.position, filter.radius = pos, 0.5
        take(s.find_entities_filtered(filter))
      end
      scope = string.format('at %d position%s on %s', #list, #list == 1 and '' or 's', s.name)
    end
    -- whose each is, and which go
    local go, rows, by_name, by_owner = {}, {}, {}, {}
    local left = {others={}, unknown=0, uncharted=0, over_cap=0}
    local chunks, sname = {}, s.name
    for _, g in ipairs(found) do
      if g.valid then
        local pos, tile, gname = g.position, g.type == 'tile-ghost', g.ghost_name
        local cx, cy = math.floor(pos.x / 32), math.floor(pos.y / 32)
        local ck = cx * 65536 + cy
        if chunks[ck] == nil then chunks[ck] = api.charted(p, pos) and true or false end
        local owner, source = api.owner_at(sname, gname, pos, tile, g)
        if not chunks[ck] then left.uncharted = left.uncharted + 1
        elseif a.owner == nil and owner ~= who or a.owner ~= nil and a.owner ~= 'any' and owner ~= a.owner then
          if owner then left.others[owner] = (left.others[owner] or 0) + 1 else left.unknown = left.unknown + 1 end
        elseif #go >= MAX_REMOVE then left.over_cap = left.over_cap + 1
        else
          go[#go+1] = g
          by_name[gname] = (by_name[gname] or 0) + 1
          local o = owner or 'unknown'
          by_owner[o] = (by_owner[o] or 0) + 1
          if #rows < MAX_ROWS then
            rows[#rows+1] = {name=gname, tile=tile or nil, position={x=pos.x, y=pos.y}, owner=owner or 'unknown',
              placed=source == 'record' and api.placed_by(g) or nil}
          end
        end
      end
    end
    local removed = 0
    if not dry then
      for _, g in ipairs(go) do
        if g.valid then
          pcall(api.forget, g)
          if try(function() return g.destroy{raise_destroy=true} end) then removed = removed + 1 end
        end
      end
    end
    local n_others = 0
    for _, c in pairs(left.others) do n_others = n_others + c end
    local n_left = n_others + left.unknown + left.uncharted + left.over_cap
    local n_go = dry and #go or removed
    local kind = (a.tiles and 'ghost' or 'entity ghost') .. (n_go == 1 and '' or 's')
    local whose = a.owner == nil and 'of yours' or a.owner == 'any' and 'of ours (any owner)' or 'placed by ' .. a.owner
    local out = {surface=s.name, dry_run=dry or nil, found=#found, capped_find=#found >= MAX_FIND and MAX_FIND or nil,
      by_name=by_text(by_name), by_owner=a.owner == 'any' and by_text(by_owner) or nil, ghosts=rows,
      more=#go > #rows and #go - #rows or nil, left=n_left}
    if dry then out.would_remove = #go else out.removed = removed end
    local why = {}
    if n_others > 0 then
      out.left_others = left.others
      why[#why+1] = string.format('%d placed by others (%s; owner: "any" or the agent\'s name takes them)', n_others, by_text(left.others))
    end
    if left.unknown > 0 then
      out.left_unknown = left.unknown
      why[#why+1] = string.format('%d with no placement record and no last user (placed before the record began, by the game as the ghost of a destroyed entity, or its record left the last 8192 placements; owner: "any" takes them)', left.unknown)
    end
    if left.uncharted > 0 then
      out.left_uncharted = left.uncharted
      why[#why+1] = string.format('%d in chunks our force has not charted', left.uncharted)
    end
    if left.over_cap > 0 then
      out.left_over_cap = left.over_cap
      why[#why+1] = string.format('%d past the %d a call takes (call it again)', left.over_cap, MAX_REMOVE)
    end
    out.left_why = #why > 0 and why or nil
    out.line = string.format('%s %d %s %s %s%s; left %d%s',
      dry and 'would remove' or 'removed', n_go, kind, whose, scope,
      #go > 0 and ': ' .. by_text(by_name) or '', n_left, #why > 0 and ': ' .. table.concat(why, '; ') or '')
    if #found >= MAX_FIND then out.line = out.line .. string.format('; the search stopped at %d ghosts: a smaller area reads the rest', MAX_FIND) end
    return out
  end

  M.schema = {remove_ghosts = {
    area='{left_top, right_bottom} or [[x1,y1],[x2,y2]], at most 256 tiles a side: the ghosts in it', positions='or 1..64 {x, y}: the ghosts whose centre is within 0.5 tiles of each',
    surface='optional planet or platform name (default yours)', platform='optional platform name',
    names='optional 1..32 entity or tile names (or one): only ghosts of them', tiles='optional true: tile ghosts too (default entity ghosts only)',
    owner='optional "any" (every ghost of ours, listed by owner) or an agent\'s name (only the ghosts it placed); default only the ghosts you placed',
    dry_run='optional true: remove nothing; would_remove and the list',
    note='takes ghosts away at once, as the deconstruction planner does over ghosts in remote view: on charted chunks, no reach, no robots; never a built entity or a tile. Whose a ghost is: the harness\'s placement record (place_ghosts and the routes, paste, blueprint_place: the agent and request), else the game\'s last user; at most 256 removed a call',
    returns='surface, found (ghosts in the scope of the names and kind given), removed or would_remove, by_name, by_owner (owner "any"), ghosts [{name, tile, position, owner, placed}] (the first 64 taken; more past them), left (in the scope and not taken) with left_others {agent: count}, left_unknown, left_uncharted, left_over_cap and left_why, capped_find (the search stopped at 4096), line'}}
  return M
end
