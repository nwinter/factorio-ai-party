-- What already feeds the tiles a belt line will take (d20 batch67 AC2, Astra #1647: a belt_route put an underground
-- entrance under the drop point of an orphan inserter, which put coal and ammunition onto the new ore line; the
-- footprint check passed, the tiles were empty). For each planned belt, underground end or splitter: our inserters
-- whose drop point is on its tile (what each holds, where it takes from and what is there), and our belts, underground
-- exits and splitters whose output runs into it (what they carry). With item: feeders of any other item are conflicts.
-- Built entities only; read in short stretches of the line (a box round each STRETCH planned tiles).
return function(api)
  local M = {}
  -- REACH: an inserter's centre to its drop point, at most (a long-handed inserter's 2 tiles, and its own half tile).
  M.ROWS, M.STRETCH, M.REACH = 12, 8, 2.7
  local STEP = {[0]={0, -1}, [4]={1, 0}, [8]={0, 1}, [12]={-1, 0}}
  local SIDE = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local DIR = {north=0, east=4, south=8, west=12}
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function key(x, y) return x .. ',' .. y end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  local function dir_of(d) if type(d) == 'string' then return DIR[d] end return d and d % 16 end
  local types = {}
  local function ptype(name)
    if types[name] == nil then types[name] = try(function() return prototypes.entity[name].type end) or false end
    return types[name] or nil
  end
  local function what(t) return t.type == 'input' and ' entrance' or t.type == 'output' and ' exit' or '' end
  -- name -> count, the first `limit` by count (a list of {name, count}).
  local function top(counts, limit)
    local list = {}
    for name, n in pairs(counts) do list[#list+1] = {name=name, count=n} end
    table.sort(list, function(x, y) if x.count ~= y.count then return x.count > y.count end return x.name < y.name end)
    while #list > limit do table.remove(list) end
    return list
  end
  local function add(counts, contents)
    for k, v in pairs(contents or {}) do
      local name = type(v) == 'table' and v.name or k
      local n = type(v) == 'table' and v.count or v
      if type(name) == 'string' and type(n) == 'number' then counts[name] = (counts[name] or 0) + n end
    end
  end
  local function text(list)
    local parts = {}
    for k, x in ipairs(list) do parts[k] = x.name .. ' ' .. x.count end
    return table.concat(parts, ', ')
  end
  -- Items on a belt-type entity's lanes.
  local function on_lanes(e)
    local counts = {}
    for i = 1, math.min(8, try(function() return e.get_max_transport_line_index() end) or 2) do
      local line = try(function() return e.get_transport_line(i) end)
      if line then add(counts, try(function() return line.get_contents() end)) end
    end
    return counts
  end
  -- What an inserter's source offers now: its output inventory (a chest's, a machine's result) or a belt's lanes; a
  -- machine's recipe (its products count as what it offers).
  local function offers(src)
    if BELT[src.type] then return on_lanes(src) end
    local counts, recipe = {}, nil
    local inv = try(function() return src.get_output_inventory() end)
    if inv then add(counts, try(function() return inv.get_contents() end)) end
    if src.type == 'assembling-machine' or src.type == 'furnace' then
      recipe = try(function() return src.get_recipe() end)
      if not recipe then
        local n = try(function() return src.previous_recipe.name end)
        recipe = type(n) == 'string' and try(function() return prototypes.recipe[n] end) or n
      end
    end
    return counts, recipe
  end
  local function filters(ins)
    if not try(function() return ins.use_filters end) then return nil end
    local names = {}
    for i = 1, try(function() return ins.filter_slot_count end) or 0 do
      local f = try(function() return ins.get_filter(i) end)
      local name = f and (type(f) == 'string' and f or f.name)
      if name then names[#names+1] = name end
    end
    return {mode=try(function() return ins.inserter_filter_mode end) or 'whitelist', names=names}
  end

  -- entities: the planned line ({name, position, direction, type?}); opts: {item?, joins = {x, y} the existing belt the
  -- line extends (its feed is the line's own), own = the line's entities standing already (a re-run lays the rest)}. Returns nil when nothing feeds it, else {rows, more, conflicts, line}.
  function M.check(surface, force, entities, opts)
    opts = opts or {}
    local planned, list = {}, {}
    for i, e in ipairs(entities or {}) do
      local pt = ptype(e.name)
      if BELT[pt or ''] and e.position then
        local t = {name=e.name, position=e.position, dir=dir_of(e.direction) or 0, type=e.type, first=(i == 1)}
        local px, py = math.floor(e.position.x), math.floor(e.position.y)
        if t.type == nil and pt == 'splitter' then
          local h = (t.dir == 0 or t.dir == 8) and {{-0.5, 0}, {0.5, 0}} or {{0, -0.5}, {0, 0.5}}
          for _, o in ipairs(h) do planned[key(math.floor(e.position.x + o[1]), math.floor(e.position.y + o[2]))] = t end
        else planned[key(px, py)] = t end
        list[#list+1] = e
      end
    end
    if #list == 0 then return nil end
    local item, own = opts.item, {}
    for _, e in ipairs(opts.own or {}) do if e.position then own[key(math.floor(e.position.x), math.floor(e.position.y))] = true end end
    local rows, seen, conflicts, more, kinds = {}, {}, 0, 0, {inserter=0, belt=0}
    local function row(r)
      if r.conflict then conflicts = conflicts + 1 end
      kinds[r.kind] = kinds[r.kind] + 1
      if #rows < M.ROWS then rows[#rows+1] = r else more = more + 1 end
    end
    local function other(counts)
      if not item then return nil end
      local o = {}
      for name in pairs(counts) do if name ~= item then o[#o+1] = name end end
      table.sort(o)
      return #o > 0 and o or nil
    end
    local function inserter(ins)
      local drop = try(function() return ins.drop_position end)
      if not drop then return end
      local t = planned[key(math.floor(drop.x), math.floor(drop.y))]
      if not t then return end
      if #rows >= M.ROWS and not item then return row({kind='inserter'}) end
      local held = try(function() local s = ins.held_stack; return s.valid_for_read and {name=s.name, count=s.count} or nil end)
      local src = try(function() return ins.pickup_target end)
      local counts, recipe = {}, nil
      if src and src.valid then counts, recipe = offers(src) end
      local f = filters(ins)
      local moves = {}
      if held then moves[held.name] = true end
      local offered = {}
      for n in pairs(counts) do offered[n] = true end
      for _, pr in ipairs(recipe and try(function() return recipe.products end) or {}) do
        if pr.type ~= 'fluid' then offered[pr.name] = true end
      end
      local listed_filter = {}
      for _, n in ipairs(f and f.names or {}) do listed_filter[n] = true end
      for n in pairs(offered) do
        local passes = not f or (f.mode == 'blacklist') ~= (listed_filter[n] == true)
        if passes then moves[n] = true end
      end
      recipe = recipe and recipe.name
      local o = other(moves)
      if #rows >= M.ROWS then return row({kind='inserter', conflict=o and true or nil}) end
      local listed = top(counts, 4)
      local from = src and src.valid and string.format('takes from %s %s%s%s', src.name, at(src.position), recipe and ' making ' .. recipe or '',
        #listed > 0 and ': ' .. text(listed) or ', nothing there now')
        or 'nothing at its pickup ' .. at(try(function() return ins.pickup_position end) or ins.position)
      row({kind='inserter', name=ins.name, position=ins.position, drop=drop, onto={name=t.name, position=t.position, type=t.type},
        holds=held, from=src and src.valid and {name=src.name, position=src.position, recipe=recipe, items=listed} or nil,
        filters=f, conflict=o and true or nil, others=o,
        line=string.format('%s %s drops at %s, on the planned %s%s %s; holds %s; %s%s%s', ins.name, at(ins.position), at(drop), t.name, what(t), at(t.position),
          held and held.name .. ' ' .. held.count or 'nothing', from,
          f and #f.names > 0 and string.format('; %s %s', f.mode, table.concat(f.names, ', ')) or '',
          o and string.format('; not %s: %s', item, table.concat(o, ', ')) or '')})
    end
    -- A belt, an underground exit or a splitter whose output tile is planned (not head on, not the belt the line extends).
    local function belt(b)
      local bt, pos = b.type, b.position
      local bx, by = math.floor(pos.x), math.floor(pos.y)
      if own[key(bx, by)] then return end
      if bt == 'underground-belt' and try(function() return b.belt_to_ground_type end) ~= 'output' then return end
      local d = b.direction % 16
      local st = STEP[d]
      if not st then return end
      local outs, joins = {}, opts.joins and math.floor(opts.joins.x) == bx and math.floor(opts.joins.y) == by
      if bt == 'splitter' then
        local h = (d == 0 or d == 8) and {{-0.5, 0}, {0.5, 0}} or {{0, -0.5}, {0, 0.5}}
        for _, o in ipairs(h) do outs[#outs+1] = {math.floor(pos.x + o[1]) + st[1], math.floor(pos.y + o[2]) + st[2]} end
      else outs[1] = {bx + st[1], by + st[2]} end
      for _, o in ipairs(outs) do
        local t = planned[key(o[1], o[2])]
        if t and d ~= (t.dir + 8) % 16 and not (joins and t.first) then
          if #rows >= M.ROWS and not item then return row({kind='belt'}) end
          local how = d == t.dir and 'from behind' or 'from its ' .. SIDE[(d + 8) % 16] .. ' side'
          local counts = on_lanes(b)
          local o2 = other(counts)
          if #rows >= M.ROWS then return row({kind='belt', conflict=o2 and true or nil}) end
          local listed = top(counts, 4)
          row({kind='belt', name=b.name, position=pos, direction=SIDE[d], onto={name=t.name, position=t.position, type=t.type}, how=how,
            items=listed, conflict=o2 and true or nil, others=o2,
            line=string.format('%s %s facing %s runs into the planned %s%s %s %s; carries %s%s', b.name, at(pos), SIDE[d], t.name, what(t), at(t.position), how,
              #listed > 0 and text(listed) or 'nothing now', o2 and string.format('; not %s: %s', item, table.concat(o2, ', ')) or '')})
          return
        end
      end
    end
    for s = 1, #list, M.STRETCH do
      local l, t, r, b
      for i = s, math.min(#list, s + M.STRETCH - 1) do
        local p = list[i].position
        l, t = math.min(l or p.x, p.x), math.min(t or p.y, p.y)
        r, b = math.max(r or p.x, p.x), math.max(b or p.y, p.y)
      end
      for _, e in ipairs(try(function() return surface.find_entities_filtered{area={{l - M.REACH, t - M.REACH}, {r + M.REACH, b + M.REACH}}, type='inserter', force=force} end) or {}) do
        local id = e.unit_number or key(e.position.x, e.position.y)
        if e.valid and not seen[id] then seen[id] = true; inserter(e) end
      end
      for _, e in ipairs(try(function() return surface.find_entities_filtered{area={{l - 1.2, t - 1.2}, {r + 1.2, b + 1.2}}, type={'transport-belt', 'underground-belt', 'splitter'}, force=force} end) or {}) do
        local id = e.unit_number or key(e.position.x, e.position.y)
        if e.valid and not seen[id] then seen[id] = true; belt(e) end
      end
    end
    if #rows == 0 then return nil end
    local n, ins, bl = #rows + more, kinds.inserter, kinds.belt
    return {rows=rows, more=more > 0 and more or nil, conflicts=item and conflicts or nil,
      line=string.format('%s the planned tiles (%d inserter%s, %d belt%s)%s%s', n == 1 and '1 entity of ours feeds' or n .. ' entities of ours feed', ins, ins == 1 and '' or 's', bl, bl == 1 and '' or 's',
        more > 0 and string.format(', the first %d listed', #rows) or '',
        item and string.format('; %d feed%s items other than %s', conflicts, conflicts == 1 and 's' or '', item) or '')}
  end
  return M
end
