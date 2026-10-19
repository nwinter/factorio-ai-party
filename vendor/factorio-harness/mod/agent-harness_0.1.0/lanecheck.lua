-- platform_lanes {platform, all?} (d19 batch45, batch40 D1, Sol: several hours on Wayfarer's fuel and ammunition
-- starvation): each belt line's end on a platform, lane by lane, as a player sees the belts. A line ends where a belt
-- has no belt after it. For each lane holding items at an end: whether it has stopped (MIN_FULL or more on the end
-- tile), what lies past the end (empty space, the hull's foundation edge, an entity), and, along the run back from the
-- end (up to RUN tiles of belts with one input), the inserters that pick from it: which lane each takes from
-- (pickup_from_left_lane / right) and which items its filter lets through. Flagged: a stopped lane no inserter on the run
-- takes from, a lane whose front item no inserter there takes (filter, or a lane it does not pick from). By default only
-- the items that feed the platform's thruster fuel and oxidizer and its ammunition (the ingredients of the recipes set
-- in its machines that make those, and the ammunition items its turrets take); all: true, every item. Read only.
return function(api)
  local M = {}
  local RUN, MIN_FULL, MAX_BELTS, MAX_ENDS = 64, 3, 4000, 64
  local BELTS = {'transport-belt', 'underground-belt', 'splitter'}
  local function try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function side(i) return i % 2 == 1 and 'left' or 'right' end
  local STEP = {[0]={0, -1}, [4]={1, 0}, [8]={0, 1}, [12]={-1, 0}}
  -- The items that matter: what fuel, oxidizer and ammunition are made from, and the ammunition itself.
  local FLUIDS = {['thruster-fuel']=true, ['thruster-oxidizer']=true}
  function M.wanted(s, force)
    local want = {}
    for _, e in ipairs(try(function() return s.find_entities_filtered{type={'assembling-machine', 'furnace'}, force=force} end) or {}) do
      local r = try(function() return e.get_recipe() end)
      local feeds = false
      for _, pr in ipairs(r and r.products or {}) do
        if FLUIDS[pr.name] then feeds = true end
        local proto = pr.type == 'item' and prototypes.item[pr.name]
        if proto and proto.type == 'ammo' then feeds = true; want[pr.name] = true end
      end
      if feeds then for _, ing in ipairs(r.ingredients or {}) do if ing.type == 'item' then want[ing.name] = true end end end
    end
    for _, t in ipairs(try(function() return s.find_entities_filtered{type='ammo-turret', force=force} end) or {}) do
      for _, c in ipairs(try(function() return t.prototype.attack_parameters.ammo_categories end) or {}) do
        for name, it in pairs(try(function() return prototypes.get_item_filtered{{filter='type', type='ammo'}} end) or {}) do
          if try(function() return it.ammo_category.name end) == c then want[name] = true end
        end
      end
    end
    return want
  end
  -- The tile past a belt's end: empty space, outside the foundation; or what stands there.
  local function past(s, e)
    local d = STEP[try(function() return e.direction end) or 0] or STEP[0]
    local q = {x=e.position.x + d[1], y=e.position.y + d[2]}
    local tile = try(function() return s.get_tile(q.x, q.y).name end)
    if tile == 'empty-space' or tile == 'out-of-map' then return 'the hull edge (empty space past it)', q end
    local o = try(function() return s.find_entities_filtered{position=q, limit=1, type={'character', 'item-entity', 'entity-ghost'}, invert=true}[1] end)
    if o then return o.name .. ' ' .. at(o.position), q end
    return 'open foundation', q
  end
  local function front(e, k)
    local best, bp
    for _, st in ipairs(try(function() return e.get_transport_line(k).get_detailed_contents() end) or {}) do
      local name = st.stack and st.stack.valid_for_read and st.stack.name
      if name and (not bp or st.position > bp) then best, bp = name, st.position end
    end
    return best
  end
  local function filters_of(i)
    local n = try(function() return i.filter_slot_count end) or 0
    if n == 0 or try(function() return i.use_filters end) == false then return nil end
    local list, mode = {}, try(function() return i.inserter_filter_mode end) or 'whitelist'
    for k = 1, n do
      local f = try(function() return i.get_filter(k) end)
      local name = type(f) == 'string' and f or type(f) == 'table' and (type(f.name) == 'string' and f.name or f.name and f.name.name) or nil
      if name then list[name] = true end
    end
    if not next(list) then return nil end
    return list, mode
  end
  local function takes(i, item, lane)
    local key = lane == 'left' and 'pickup_from_left_lane' or 'pickup_from_right_lane'
    if try(function() return i[key] end) == false then return false, 'picks from the other lane' end
    local list, mode = filters_of(i)
    if list then
      if mode == 'blacklist' and list[item] then return false, 'its filter excludes ' .. item end
      if mode ~= 'blacklist' and not list[item] then return false, 'its filter does not name ' .. item end
    end
    return true
  end
  function M.read(p, a)
    assert(a.all == nil or type(a.all) == 'boolean', 'all must be true or false')
    local pl = api.platform(p, a.platform)
    local s, force = pl.surface, p.force
    local belts = try(function() return s.find_entities_filtered{type=BELTS, force=force, limit=MAX_BELTS} end) or {}
    local want = not a.all and M.wanted(s, force) or nil
    -- inserters by the belt they pick from
    local by_pickup = {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=force} end) or {}) do
      local t = try(function() return i.pickup_target end)
      local u = t and t.valid and t.unit_number
      if u then by_pickup[u] = by_pickup[u] or {}; table.insert(by_pickup[u], i) end
    end
    local rows, lines, ends, flagged = {}, {}, 0, 0
    for _, e in ipairs(belts) do
      local outs = try(function() return e.belt_neighbours.outputs end) or {}
      local paired = e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'input' and try(function() return e.neighbours end)
      if #outs == 0 and not paired and ends < MAX_ENDS then
        ends = ends + 1
        -- the run back from the end: belts with one input, up to RUN tiles; the inserters picking there
        local run, ins, b = {}, {}, e
        for _ = 1, RUN do
          if not (b and b.valid) then break end
          run[#run+1] = b
          for _, i in ipairs(by_pickup[b.unit_number] or {}) do ins[#ins+1] = i end
          local inputs = try(function() return b.belt_neighbours.inputs end) or {}
          -- an underground's exit: back through its entrance
          if #inputs == 0 and b.type == 'underground-belt' and try(function() return b.belt_to_ground_type end) == 'output' then
            local entry = try(function() return b.neighbours end)
            inputs = entry and entry.valid and {entry} or {}
          end
          b = #inputs == 1 and inputs[1] or nil
        end
        for k = 1, math.min(2, try(function() return e.get_max_transport_line_index() end) or 0) do
          local lane = side(k)
          local line = try(function() return e.get_transport_line(k) end)
          local n = line and try(function() return line.get_item_count() end) or 0
          local item = n > 0 and front(e, k)
          if item and (not want or want[item]) then
            local stopped = n >= MIN_FULL
            local why_not, any = {}, false
            for _, i in ipairs(ins) do
              local ok, why = takes(i, item, lane)
              if ok then any = true elseif #why_not < 3 then why_not[#why_not+1] = string.format('%s %s %s', i.name, at(i.position), why) end
            end
            local beyond = past(s, e)
            if e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'output' and not try(function() return e.neighbours end) then
              beyond = beyond .. '; an underground exit with no entrance paired'
            end
            local flag
            if not any and #ins == 0 and stopped then flag = 'stopped: no inserter on the run takes from it'
            elseif not any and #ins > 0 then flag = 'no inserter on the run takes ' .. item .. ' from this lane (' .. table.concat(why_not, '; ') .. ')' end
            if flag then flagged = flagged + 1 end
            local row = {position=e.position, name=e.name, lane=lane, front=item, on_tile=n, stopped=stopped or nil, past=beyond,
              run_tiles=#run, inserters=#ins, flag=flag}
            rows[#rows+1] = row
            if flag or stopped then
              lines[#lines+1] = string.format('%s %s %s lane: %d on the end tile%s, front %s; past it %s; %d inserter%s on the %d tile%s back%s',
                e.name, at(e.position), lane, n, stopped and ' (stopped)' or '', item, beyond, #ins, #ins == 1 and '' or 's', #run, #run == 1 and '' or 's', flag and ': ' .. flag or '')
            end
          end
        end
      end
    end
    table.sort(lines)
    return {platform=pl.name, belts=#belts, ends=ends, flagged=flagged, rows=rows, lines=#lines > 0 and lines or {'no belt line on ' .. pl.name .. ' ends with a stopped lane or one no inserter takes from'},
      items=want and (function() local l = {} for k in pairs(want) do l[#l+1] = k end table.sort(l) return #l > 0 and table.concat(l, ', ') or 'none (no machine makes fuel, oxidizer or ammunition, no turret)' end)() or 'every item',
      capped=(#belts >= MAX_BELTS or ends >= MAX_ENDS) and string.format('the first %d belts and %d line ends read', MAX_BELTS, MAX_ENDS) or nil}
  end
  M.schema = {platform_lanes = {platform='platform name', all='optional true: every item (default the items that feed thruster fuel, oxidizer and ammunition there, and the ammunition)',
    returns='belts, ends (lines that end: a belt with no belt after it), flagged, rows [{position, name, lane (left|right), front (the item at the lane\'s front), on_tile, stopped (3 or more on the end tile), past (what is past the end: the hull edge, open foundation, an entity), run_tiles (back from the end with one input, up to 64), inserters (picking on that run), flag}], lines (stopped or flagged lanes), items (what was looked at), capped. A flag: a stopped lane no inserter on the run takes from; a lane whose front item no inserter there takes (its lane choice or its filter). Read only'}}
  return M
end
