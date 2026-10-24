-- A platform's foundation tiles waiting to go or to be built (tilecheck.lua), by the rules the game showed on a
-- copy of world n (platformtiles2; Astra, shift14 21:55: a marked tile at (-2,8) on Sunward stayed 30+ s, and three
-- foundation ghosts in a hole beside it were never built). The hub changes one tile at a time and looks at the
-- tile's 8 neighbours only:
-- - a run is the empty side neighbours (north, east, south, west) joined through the empty corners between them;
-- - a marked foundation tile goes only with exactly one run: none (all four sides foundation) would open a new
--   hole, two would join separate empty space; the hub must have room for what it returns, and nothing may stand
--   on it. Whether the rest of the foundation stays joined is not looked at;
-- - a foundation ghost is built with at most one run (an enclosed one-tile hole fills) and foundation among its 8
--   neighbours (a corner is enough); two runs would split the empty space beside it, even when both sides stay
--   open; also never in a thruster's exhaust or more than 200 tiles north of the hub.
-- Each check plays the queue out in order, a tile at a time (a marked tile beside one that goes may go next; a
-- ghost beside one built may be built next), so what stays is what waits for good, each with its reason in the
-- end state. Bounded: GHOSTS ghosts and MARKS marked tiles a read, STEPS tile looks, holes followed up to LIMIT
-- tiles (larger ones count as open space).
return function()
  local M = {}
  local LIMIT, GHOSTS, MARKS, STEPS = 512, 64, 256, 4096
  local DIRS = {{1,0},{-1,0},{0,1},{0,-1}}
  -- The 8 tiles around one, in order from north: odd places are the side neighbours, even ones the corners.
  local RING = {{0,-1},{1,-1},{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1}}
  local function key(x, y) return x * 4194304 + y end
  M.key = key
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Whether a tile is empty space (out of the map counts as empty); cache[key] = true/false, kept per check.
  -- (d24 batch166) cache.grid {x0, y0, w, h, cell, keep} (platplan.lua's support job: arrays by (y - y0) * w + (x - x0) +
  -- 1) answers before a tile read: built floor (cell 1) is not empty, a foundation tile ghost (cell 2) or a kept tile is.
  local function is_empty(s, x, y, cache)
    local k = key(x, y)
    local v = cache[k]
    if v == nil then
      local g = cache.grid
      local dx, dy = g and x - g[1], g and y - g[2]
      local i = g and dx >= 0 and dy >= 0 and dx < g[3] and dy < g[4] and dy * g[3] + dx + 1
      if i and g[5][i] == 1 then v = false
      elseif i and (g[5][i] == 2 or g[6][i]) then v = true
      else
        local ok, name = pcall(function() return s.get_tile(x, y).name end)
        v = not ok or name == 'empty-space' or name == 'out-of-map'
      end
      cache[k] = v
    end
    return v
  end
  M.is_empty = is_empty
  local function at(x, y) return string.format('(%g,%g)', x + 0.5, y + 0.5) end
  -- The runs round (x,y): a list of runs, each the side neighbours {x, y} it holds.
  function M.runs(s, x, y, cache)
    local empty = {}
    for i, d in ipairs(RING) do empty[i] = is_empty(s, x + d[1], y + d[2], cache) end
    local runs, seen = {}, {}
    for i = 1, 8, 2 do
      if empty[i] and not seen[i] then
        local run = {}
        -- Walk round both ways through empty places from this side.
        local stack = {i}
        seen[i] = true
        while #stack > 0 do
          local j = table.remove(stack)
          if j % 2 == 1 then run[#run+1] = {x + RING[j][1], y + RING[j][2]} end
          for _, n in ipairs({j % 8 + 1, (j - 2) % 8 + 1}) do
            if empty[n] and not seen[n] then seen[n] = true; stack[#stack+1] = n end
          end
        end
        runs[#runs+1] = run
      end
    end
    return runs
  end
  local function list(cells, n)
    local parts = {}
    for i = 1, math.min(n, #cells) do parts[i] = at(cells[i][1], cells[i][2]) end
    return table.concat(parts, ' and ') .. (#cells > n and ', ...' or '')
  end
  -- Why a marked tile cannot go by the rule of runs, or nil when it can.
  function M.removal_rule(s, x, y, cache)
    local runs = M.runs(s, x, y, cache)
    if #runs == 1 then return nil end
    if #runs == 0 then
      return 'none of its four side neighbours (north, east, south, west) is empty space: the hub removes a foundation tile only beside empty space'
    end
    local firsts = {}
    for i, r in ipairs(runs) do firsts[i] = r[1] end
    return string.format('its empty side neighbours %s do not meet through the tiles round it: removing it would join separate empty space, which the hub does not do', list(firsts, 4))
  end
  -- What stands on a tile (not ghosts, proxies or characters): the first entity, or nil.
  local SKIP = {['entity-ghost']=true, ['tile-ghost']=true, ['deconstructible-tile-proxy']=true, character=true,
    ['item-request-proxy']=true, ['highlight-box']=true, ['flying-text']=true, particle=true, explosion=true, smoke=true}
  local function standing(s, x, y)
    for _, e in ipairs(try(function() return s.find_entities_filtered{area={{x + 0.05, y + 0.05}, {x + 0.95, y + 0.95}}} end) or {}) do
      if e.valid and not SKIP[e.type] then return e end
    end
  end
  -- The hub's room for a tile's product: how many it takes, and the item.
  local function product(s, x, y)
    local p = try(function() return s.get_tile(x, y).prototype.mineable_properties.products[1] end)
    return p and p.name
  end
  local function room(hub, item)
    if not (hub and hub.valid and item) then return nil end
    local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    return inv and try(function() return inv.get_insertable_count(item) end)
  end
  -- (d24 batch165) for floorphases.lua: what stands on a tile, a tile's product, the hub's room for an item
  M.standing, M.product, M.room = standing, product, room
  -- The marked tiles on a surface, or in an area: {x, y} each, at most MARKS (more: the count).
  function M.marked(s, area)
    local f = {type='deconstructible-tile-proxy', limit=MARKS + 1}
    if area then f.area = area end
    local proxies = try(function() return s.find_entities_filtered(f) end) or {}
    local out = {}
    for i, e in ipairs(proxies) do
      if i > MARKS then break end
      out[#out+1] = {math.floor(e.position.x), math.floor(e.position.y)}
    end
    return out, #proxies > MARKS
  end
  -- The marked tiles played out: which go (in the order the rule lets them, each once a tile beside it has gone)
  -- and which wait, with why. tiles: {x, y} each; hub: the platform's hub (its room for each tile's product).
  -- Returns {go = {{x, y}...}, waiting = {{x, y, why}...}, room = what the hub still takes after}.
  function M.plan_removals(s, tiles, hub, cache)
    cache = cache or {}
    local mark, order, gone = {}, {}, {}
    for _, t in ipairs(tiles) do mark[key(t[1], t[2])] = t end
    local rooms = {}
    local function room_for(item)
      if not item then return math.huge end
      if rooms[item] == nil then rooms[item] = room(hub, item) or math.huge end
      return rooms[item]
    end
    local under = {}
    for _, t in ipairs(tiles) do
      local e = standing(s, t[1], t[2])
      if e then under[key(t[1], t[2])] = e end
    end
    local work, steps = {}, 0
    for i = #tiles, 1, -1 do work[#work+1] = tiles[i] end
    while #work > 0 and steps < STEPS do
      local t = table.remove(work)
      local k = key(t[1], t[2])
      steps = steps + 1
      if not gone[k] and not under[k] and not is_empty(s, t[1], t[2], cache) and #M.runs(s, t[1], t[2], cache) == 1 then
        local item = product(s, t[1], t[2])
        if room_for(item) > 0 then
          gone[k] = true; order[#order+1] = t; cache[k] = true
          if item and rooms[item] then rooms[item] = rooms[item] - 1 end
          -- The marked tiles round it may go next.
          for _, d in ipairs(RING) do
            local n = mark[key(t[1] + d[1], t[2] + d[2])]
            if n and not gone[key(n[1], n[2])] then work[#work+1] = n end
          end
        end
      end
    end
    local waiting = {}
    for _, t in ipairs(tiles) do
      local k = key(t[1], t[2])
      if not gone[k] and not is_empty(s, t[1], t[2], cache) then
        local why
        local e = under[k]
        if e then why = string.format('%s %s stands on it', e.name, at(e.position.x - 0.5, e.position.y - 0.5))
        else
          why = M.removal_rule(s, t[1], t[2], cache)
          -- A marked tile beside it that waits holds it too.
          if why and #M.runs(s, t[1], t[2], cache) == 0 then
            for _, d in ipairs(DIRS) do
              local n = mark[key(t[1] + d[1], t[2] + d[2])]
              if n and not gone[key(n[1], n[2])] then why = why .. string.format('; the marked tile beside it at %s waits too', at(n[1], n[2])); break end
            end
          end
        end
        if not why then
          local item = product(s, t[1], t[2])
          why = string.format('the hub has no room for %s', tostring(item))
        end
        waiting[#waiting+1] = {t[1], t[2], why}
      end
    end
    return {go=order, waiting=waiting, unchecked=#work > 0 and #work or nil}
  end
  -- Lines for a plan: go ('5 marked tiles on the platform go, one at a time, ...: (x,y), ...') and one per waiting
  -- tile (the first 8). adj, where: words round 'tile(s)' ('marked', 'on the platform').
  function M.removal_lines(plan, adj, where)
    local out = {}
    if #plan.go > 0 then
      local first = {}
      for i = 1, math.min(8, #plan.go) do first[i] = at(plan.go[i][1], plan.go[i][2]) end
      local n = #plan.go
      out.go = string.format('%d %s tile%s%s %s, one at a time, each once a side neighbour is empty space, in this order: %s%s', n, adj,
        n == 1 and '' or 's', where and ' ' .. where or '', n == 1 and 'goes' or 'go', table.concat(first, ', '), n > 8 and ', ...' or '')
    end
    if #plan.waiting > 0 then
      out.waiting = {}
      for i = 1, math.min(8, #plan.waiting) do
        local w = plan.waiting[i]
        out.waiting[i] = string.format('%s: %s', at(w[1], w[2]), w[3])
      end
      out.more = #plan.waiting > 8 and #plan.waiting - 8 or nil
    end
    return out
  end

  -- A ghost's quality name (normal when unreadable).
  function M.quality_of(g)
    local ok, q = pcall(function() return g.quality end)
    q = ok and q
    if type(q) == 'table' or type(q) == 'userdata' then q = q.name end
    return type(q) == 'string' and q or 'normal'
  end
  -- The empty tiles reachable from (x,y) with (bx,by) filled and the ghosts filled: the list when enclosed, nil when it
  -- reaches open space (more than LIMIT tiles).
  local function enclosed(s, x, y, bx, by, cache, budget)
    local seen, queue = {[key(x, y)]=true}, {{x, y}}
    local i = 1
    while queue[i] do
      if #queue > LIMIT then return nil end
      budget.left = budget.left - 1
      if budget.left < 0 then return nil end
      local c = queue[i]; i = i + 1
      for _, d in ipairs(DIRS) do
        local nx, ny = c[1] + d[1], c[2] + d[2]
        local k = key(nx, ny)
        if not seen[k] and not (nx == bx and ny == by) and is_empty(s, nx, ny, cache) then
          seen[k] = true; queue[#queue+1] = {nx, ny}
        end
      end
    end
    return queue
  end
  -- Whether a tile ghost stands on (x,y): the ghosts read are known, any other tile is looked up once (Astra,
  -- shift12 12:41: Starling had 624 tile ghosts, only the 64 read counted, and a ghost past them was taken for a hole).
  local function ghost_at(s, x, y, ghosted)
    local k = key(x, y)
    local v = ghosted[k]
    if v == nil then
      local ok, n = pcall(function()
        return s.count_entities_filtered{area={{x + 0.1, y + 0.1}, {x + 0.9, y + 0.9}}, type='tile-ghost', limit=1}
      end)
      v = ok and n > 0
      ghosted[k] = v
    end
    return v
  end
  -- The tile ghosts of a platform played out: built in the order the rules let them; the rest stay, with why.
  -- ghosts: {x, y, name} each. Returns lines naming each stalled tile ghost; nil when none. A ghost held back only by
  -- ghosts on one side (an enclosed side all ghosted, some past the ones read) is not named: those go first.
  -- The ghosts played out by the build rules: {built = {key = true}, rule = function(g)} (rule: nil, a reason string,
  -- or the runs a split leaves). The cache holds the end state (a built ghost is not empty).
  -- (d17 batch33 A1, Sol: Wayfarer's floor dry run said 107 tiles unbuildable while the fill is one region) the play in
  -- parts: play_start lays out the work (each ghost once on the work list; the hub's y and the thrusters' exhaust boxes
  -- read once), play_run makes up to n rule checks (a ghost already built or not empty costs none) and can be resumed on a
  -- later tick (floorcheck.lua keeps one in storage), and what is still on the work list when it stops is unchecked,
  -- never unbuilt. On world n a rule check cost about 26 us before the reads were moved out (2000 checks of Wayfarer's
  -- 2772 tile ghosts: 52 ms, 1810 built, 7892 entries still queued in the old play).
  local function thruster_boxes(thrusters)
    local out = {}
    for _, t in ipairs(thrusters or {}) do
      local b = try(function() return t.bounding_box end)
      if b then out[#out+1] = {x0=b.left_top.x, x1=b.right_bottom.x, y1=b.right_bottom.y, px=t.position.x, py=t.position.y} end
    end
    return out
  end
  function M.play_start(ghosts, hub, thrusters)
    local st = {at_key={}, built={}, work={}, inwork={}, steps=0, thr=thruster_boxes(thrusters),
      hub_y=hub and try(function() return hub.valid and hub.position.y end) or nil}
    for _, g in ipairs(ghosts) do st.at_key[key(g[1], g[2])] = g end
    for i = #ghosts, 1, -1 do
      local g = ghosts[i]
      local k = key(g[1], g[2])
      if not st.inwork[k] then st.inwork[k] = true; st.work[#st.work+1] = g end
    end
    return st
  end
  function M.play_rule(s, st, cache)
    return function(g)
      local x, y = g[1], g[2]
      if st.hub_y and y + 0.5 < st.hub_y - 200 then return 'more than 200 tiles north of the hub' end
      for _, b in ipairs(st.thr) do
        if x + 0.5 > b.x0 and x + 0.5 < b.x1 and y + 0.5 > b.y1 and y + 0.5 < b.y1 + 82 then
          return string.format('in the 82 tiles south of the thruster at (%g,%g), where no foundation is built', b.px, b.py)
        end
      end
      local near = false
      for _, d in ipairs(RING) do if not is_empty(s, x + d[1], y + d[2], cache) then near = true; break end end
      if not near then return 'no foundation among the 8 tiles round it' end
      local runs = M.runs(s, x, y, cache)
      if #runs >= 2 then return runs end
      return nil
    end
  end
  -- Up to n rule checks; true when the work list is empty.
  function M.play_run(s, st, cache, n)
    local rule = M.play_rule(s, st, cache)
    local done = 0
    while #st.work > 0 and done < n do
      local g = table.remove(st.work)
      local k = key(g[1], g[2])
      st.inwork[k] = nil
      if not st.built[k] and is_empty(s, g[1], g[2], cache) then
        done = done + 1; st.steps = st.steps + 1
        if rule(g) == nil then
          st.built[k] = true; cache[k] = false
          for _, d in ipairs(RING) do
            local nk = key(g[1] + d[1], g[2] + d[2])
            local nb = st.at_key[nk]
            if nb and not st.built[nk] and not st.inwork[nk] then st.inwork[nk] = true; st.work[#st.work+1] = nb end
          end
        end
      end
    end
    return #st.work == 0
  end
  -- In one go: built (key -> true), rule, left (still queued), unchecked (key -> true: never decided), steps.
  function M.play(s, ghosts, hub, thrusters, cache, steps_max)
    cache = cache or {}
    local st = M.play_start(ghosts, hub, thrusters)
    M.play_run(s, st, cache, steps_max or STEPS)
    local unchecked = {}
    for _, g in ipairs(st.work) do unchecked[key(g[1], g[2])] = true end
    return {built=st.built, rule=M.play_rule(s, st, cache), left=#st.work, unchecked=unchecked, steps=st.steps}
  end
  -- The fewest empty tiles that join tiles (cells: {x, y} each) to built foundation (d17 batch21->22 A1, Sol and Astra:
  -- a placement on a sparse floor): the shortest chain of tiles each touching the next by a side or a corner (a
  -- corner is enough for the hub to build), from any of them to a tile that is foundation in cache's end state; within
  -- WINDOW tiles of the first, at most SEARCH tiles looked at. Returns the chain (nearest the cells first) or nil.
  local WINDOW, SEARCH = 48, 6000
  function M.connect(s, cells, cache)
    if #cells == 0 then return nil end
    local ox, oy = cells[1][1], cells[1][2]
    local from, queue, start = {}, {}, {}
    for _, c in ipairs(cells) do local k = key(c[1], c[2]); start[k] = true; from[k] = false; queue[#queue+1] = c end
    local i, goal = 1, nil
    while queue[i] and i <= SEARCH do
      local c = queue[i]; i = i + 1
      for _, d in ipairs(RING) do
        local nx, ny = c[1] + d[1], c[2] + d[2]
        local k = key(nx, ny)
        if from[k] == nil and math.abs(nx - ox) <= WINDOW and math.abs(ny - oy) <= WINDOW then
          if not is_empty(s, nx, ny, cache) then goal = c; break end
          from[k] = c; queue[#queue+1] = {nx, ny}
        end
      end
      if goal then break end
    end
    if not goal then return nil end
    local chain = {}
    local c = goal
    while c and not start[key(c[1], c[2])] do chain[#chain+1] = c; c = from[key(c[1], c[2])] end
    local out = {}
    for j = #chain, 1, -1 do out[#out+1] = chain[j] end
    return out
  end
  function M.plan_builds(s, ghosts, hub, thrusters, cache)
    cache = cache or {}
    local at_key, built, ghosted = {}, {}, {}
    for _, g in ipairs(ghosts) do at_key[key(g[1], g[2])] = g; ghosted[key(g[1], g[2])] = true end
    local function rule(g)
      local x, y = g[1], g[2]
      if hub and hub.valid and y + 0.5 < hub.position.y - 200 then return 'more than 200 tiles north of the hub' end
      for _, t in ipairs(thrusters) do
        local b = t.bounding_box
        if x + 0.5 > b.left_top.x and x + 0.5 < b.right_bottom.x and y + 0.5 > b.right_bottom.y and y + 0.5 < b.right_bottom.y + 82 then
          return string.format('in the 82 tiles south of the thruster at (%g,%g), where no foundation is built', t.position.x, t.position.y)
        end
      end
      local near = false
      for _, d in ipairs(RING) do if not is_empty(s, x + d[1], y + d[2], cache) then near = true end end
      if not near then return 'no foundation among the 8 tiles round it' end
      local runs = M.runs(s, x, y, cache)
      if #runs >= 2 then return runs end
      return nil
    end
    local work, steps = {}, 0
    for i = #ghosts, 1, -1 do work[#work+1] = ghosts[i] end
    while #work > 0 and steps < STEPS do
      local g = table.remove(work)
      local k = key(g[1], g[2])
      steps = steps + 1
      if not built[k] and is_empty(s, g[1], g[2], cache) and rule(g) == nil then
        built[k] = true; cache[k] = false
        for _, d in ipairs(RING) do
          local n = at_key[key(g[1] + d[1], g[2] + d[2])]
          if n and not built[key(n[1], n[2])] then work[#work+1] = n end
        end
      end
    end
    local out, budget, unchecked = {}, {left=STEPS}, 0
    -- (d20 batch52 K9) the ghosts the budget left unjudged, by key, for a read about one of them
    local skipped = {}
    for _, g in ipairs(ghosts) do
      local k = key(g[1], g[2])
      if not built[k] and is_empty(s, g[1], g[2], cache) then
        local r = rule(g)
        local why
        if type(r) == 'table' and budget.left <= 0 then r = nil; unchecked = unchecked + 1; skipped[k] = true end
        if r == 'no foundation among the 8 tiles round it' then
          -- A ghost round it (one past those read too) may be built first.
          local beside = false
          for _, d in ipairs(RING) do if ghost_at(s, g[1] + d[1], g[2] + d[2], ghosted) then beside = true end end
          if not beside then why = r end
        elseif type(r) == 'string' then why = r
        elseif type(r) == 'table' then
          local firsts = {}
          for i, run in ipairs(r) do firsts[i] = run[1] end
          why = string.format('building it would split the empty space beside it: %s meet only through it (the hub builds no foundation that splits empty space, even when each side stays open)', list(firsts, 4))
          -- A side that would be a hole: its tiles with no ghost; all ghosted, it waits for them (not named).
          for _, run in ipairs(r) do
            local region = enclosed(s, run[1][1], run[1][2], g[1], g[2], cache, budget)
            if budget.left < 0 then why = nil; unchecked = unchecked + 1; skipped[k] = true; break end
            if region then
              local bare = {}
              for _, c in ipairs(region) do if not ghost_at(s, c[1], c[2], ghosted) then bare[#bare+1] = c end end
              if #bare > 0 then
                local parts = {}
                for i = 1, math.min(4, #bare) do parts[i] = at(bare[i][1], bare[i][2]) end
                why = why .. string.format('; on one side a hole of %d empty tile%s with no ghost: %s%s', #bare, #bare == 1 and '' or 's',
                  table.concat(parts, ', '), #bare > 4 and ', ...' or '')
              else why = nil end
              break
            end
          end
        end
        if why then out[#out+1] = string.format('tile ghost %s %s: %s', at(g[1], g[2]), tostring(g[3]), why) end
      end
    end
    unchecked = unchecked + #work
    if unchecked > 0 then
      out[#out+1] = string.format('%d more tile ghost%s not checked (the check looks at most %d tiles per read)', unchecked, unchecked == 1 and '' or 's', STEPS)
    end
    return #out > 0 and out or nil, skipped
  end
  -- Lines naming each stalled tile ghost of a platform and its cause; nil when none.
  function M.stalled(pl)
    local s, hub = pl.surface, pl.hub
    local ghosts = try(function() return s.find_entities_filtered{type='tile-ghost', limit=GHOSTS} end) or {}
    if #ghosts == 0 then return nil end
    local thrusters = try(function() return s.find_entities_filtered{type='thruster', limit=64} end) or {}
    local list2 = {}
    for _, g in ipairs(ghosts) do list2[#list2+1] = {math.floor(g.position.x), math.floor(g.position.y), g.ghost_name} end
    return M.plan_builds(s, list2, hub, thrusters, {})
  end
  -- The marked tiles of a platform: {marked, go, waiting (lines), more}; nil when none.
  function M.removals(pl)
    local s = pl.surface
    local tiles, more = M.marked(s)
    if #tiles == 0 then return nil end
    local plan = M.plan_removals(s, tiles, pl.hub, {})
    local lines = M.removal_lines(plan, 'marked')
    return {marked=#tiles .. (more and '+' or ''), go=lines.go, waiting=lines.waiting, waiting_more=lines.more}
  end
  -- inspect of a marked tile (its proxy) or a tile ghost on a platform: what holds it, or that nothing does.
  function M.note(pl, e)
    local s = pl.surface
    local x, y = math.floor(e.position.x), math.floor(e.position.y)
    if e.type == 'deconstructible-tile-proxy' then
      local tiles = M.marked(s)
      local plan = M.plan_removals(s, tiles, pl.hub, {})
      for i, t in ipairs(plan.go) do
        if t[1] == x and t[2] == y then
          return i == 1 and 'marked for removal: nothing holds it; the hub removes it next' or
            string.format('marked for removal: it goes once a tile beside it has gone (%d before it in the order the rule allows)', i - 1)
        end
      end
      for _, w in ipairs(plan.waiting) do
        if w[1] == x and w[2] == y then return 'marked for removal: waits: ' .. w[3] end
      end
    elseif e.type == 'tile-ghost' then
      -- (d20 batch52 K9, Astra #928: Kestrel's tile ghost at (20.5,73.5) read "nothing ... holds it back" while it
      -- stayed unbuilt with 34 foundation in the hub: the check read the platform's first 64 tile ghosts, not that one)
      -- this ghost first, then those within 16 tiles of it; a ghost the budget left unjudged is said so
      local list2 = {{x, y, try(function() return e.ghost_name end)}}
      local seen = {[key(x, y)] = true}
      for _, g in ipairs(try(function() return s.find_entities_filtered{type='tile-ghost', area={{x - 16, y - 16}, {x + 17, y + 17}}, limit=GHOSTS} end) or {}) do
        local gx, gy = math.floor(g.position.x), math.floor(g.position.y)
        if gx == x and gy == y then list2[1][3] = list2[1][3] or g.ghost_name
        elseif not seen[key(gx, gy)] then seen[key(gx, gy)] = true; list2[#list2+1] = {gx, gy, g.ghost_name} end
      end
      local thrusters = try(function() return s.find_entities_filtered{type='thruster', limit=64} end) or {}
      local lines, skipped = M.plan_builds(s, list2, pl.hub, thrusters, {})
      for _, line in ipairs(lines or {}) do
        if line:find('tile ghost ' .. at(x, y), 1, true) then return 'waits: ' .. line end
      end
      if skipped and skipped[key(x, y)] then
        return string.format('not checked: the check ran out of its %d tile looks before deciding this one (a hole beside it larger than it follows); unknown, not clear', STEPS)
      end
      return string.format('nothing the foundation rules hold it back by (checked with the %d tile ghost%s within 16 tiles of it)', #list2, #list2 == 1 and '' or 's')
    end
  end
  -- platform_tiles (batch24 B3, Astra: learned by trial that a tile is deconstructed only beside empty space): each
  -- tile's state and whether the hub takes it away now (foundation) or builds foundation there now (empty space), by
  -- the rules above, with why. cells: {x, y} each (tile corners).
  local QUERY = 64
  function M.query(pl, cells)
    local s, hub = pl.surface, pl.hub
    local cache = {}
    local thrusters = try(function() return s.find_entities_filtered{type='thruster', limit=64} end) or {}
    local function one(f, x, y)
      for _, e in ipairs(try(function() return s.find_entities_filtered{area={{x + 0.1, y + 0.1}, {x + 0.9, y + 0.9}}, type=f, limit=4} end) or {}) do
        if math.floor(e.position.x) == x and math.floor(e.position.y) == y then return e end
      end
    end
    local rows, lines = {}, {}
    for i, c in ipairs(cells) do
      if i > QUERY then break end
      local x, y = math.floor(c[1]), math.floor(c[2])
      local name = try(function() return s.get_tile(x, y).name end) or 'out-of-map'
      local row = {position={x=x + 0.5, y=y + 0.5}, tile=name}
      local empty = is_empty(s, x, y, cache)
      local proxy, ghost = one('deconstructible-tile-proxy', x, y), one('tile-ghost', x, y)
      row.marked = proxy and true or nil
      row.ghost = ghost and try(function() return ghost.ghost_name end) or nil
      local e = standing(s, x, y)
      row.entity = e and string.format('%s %s', e.name, at(e.position.x - 0.5, e.position.y - 0.5)) or nil
      local words = {empty and 'empty space' or name}
      if row.marked then words[#words+1] = 'marked for removal' end
      if row.ghost then words[#words+1] = 'ghost of ' .. row.ghost end
      if row.entity then words[#words+1] = 'under ' .. row.entity end
      if empty then
        local why
        if hub and hub.valid and y + 0.5 < hub.position.y - 200 then why = 'more than 200 tiles north of the hub' end
        for _, t in ipairs(thrusters) do
          local b = t.bounding_box
          if not why and x + 0.5 > b.left_top.x and x + 0.5 < b.right_bottom.x and y + 0.5 > b.right_bottom.y and y + 0.5 < b.right_bottom.y + 82 then
            why = string.format('in the 82 tiles south of the thruster at (%g,%g), where no foundation is built', t.position.x, t.position.y)
          end
        end
        if not why then
          local near = false
          for _, d in ipairs(RING) do if not is_empty(s, x + d[1], y + d[2], cache) then near = true end end
          if not near then why = 'no foundation among the 8 tiles round it' end
        end
        if not why then
          local runs = M.runs(s, x, y, cache)
          if #runs >= 2 then
            local firsts = {}
            for k, run in ipairs(runs) do firsts[k] = run[1] end
            why = string.format('building it would split the empty space beside it: %s meet only through it', list(firsts, 4))
          end
        end
        row.build = {now=why == nil, why=why or 'foundation among the 8 tiles round it and one run of empty space beside it: the hub builds it'}
        words[#words+1] = why and ('foundation not built here now: ' .. why) or 'foundation can be built here now'
      else
        local why
        if e then why = row.entity .. ' stands on it' end
        why = why or M.removal_rule(s, x, y, cache)
        if not why then
          local item = product(s, x, y)
          local r = room(hub, item)
          if item and r == 0 then why = string.format('the hub has no room for %s', item) end
        end
        row.remove = {now=why == nil, why=why or 'empty space on one side run and nothing on it: the hub takes it away once marked'}
        words[#words+1] = why and ('not removable now: ' .. why) or 'removable now'
      end
      row.line = at(x, y) .. ': ' .. table.concat(words, '; ')
      rows[#rows+1] = row; lines[#lines+1] = row.line
    end
    return {platform=pl.name, tiles=rows, lines=lines, more=#cells > QUERY and #cells - QUERY or nil,
      note='the hub changes one tile at a time and looks at its 8 neighbours: it removes a marked foundation tile with exactly one run of empty space beside it, nothing on it and room in the hub; it builds foundation with foundation among the 8 tiles round it and at most one run of empty space beside it, not in a thruster\'s exhaust or over 200 tiles north of the hub'}
  end
  M.schema = {platform_tiles = {platform='platform name', positions='1..64 tiles {x,y} (platform coordinates)', area='or {left_top, right_bottom}: its tiles, at most 64',
    returns='tiles [{position, tile (its name), marked (for removal), ghost (a tile ghost\'s name), entity (what stands on it), remove {now, why} (foundation: whether the hub takes it away now, once marked), build {now, why} (empty space: whether the hub builds foundation there now)}], lines, note. Read only'}}
  return M
end
