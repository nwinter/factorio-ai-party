-- floorphases (d24 batch165 QH1, Sol #2223: Asterion's narrow hull 2210 took several failed drafts, each floor check
-- seeing the marks of the moment, not the floor the earlier steps would leave; what worked was the marks cancelled, a
-- solid inner fill, then the outer columns one at a time): platform_plan {phases}, a read. Each phase is cancel, remove
-- and/or fill (tiles or areas), applied in order to a model of the floor: its tiles now, its deconstruction marks and
-- its foundation tile ghosts. After each phase's changes the model is played to stability by the hub's rules
-- (tilecheck.lua: a marked tile goes with exactly one run of empty space beside it, nothing standing on it and room
-- in the hub; a ghost is built with foundation among its 8 neighbours, at most one run beside it, out of a
-- thruster's exhaust and within 200 tiles north of the hub, while the hub holds foundation), removals and builds in
-- turn until neither changes. Per phase: what went, what was built, what waits and why, and floor cut off from the
-- hub (joined by sides) with what stands on it. After the last: the floor changed against the start, and the rollback
-- (the tiles to put back and to take up), played the same way from the end. Nothing in the game changes.
return function(api)
  local M = {}
  local TC = require('tilecheck')()
  local key, is_empty = TC.key, TC.is_empty
  -- tiles a read, rule checks a read (all phases and the rollback), a cut piece followed up to
  -- (a plan: tiles, rule checks; units (rule checks, tile reads, tiles followed) in the call and a tick after: on world n
  -- and a copy alike a unit costs about 10-20 us, most of it tile reads, so NOW and TICK keep a call or a tick near 2-3 ms)
  local MAX_TILES, STEPS, PIECE, LISTED = 8192, 40000, 256, 8
  local NOW, TICK, JOBS = 150, 120, 4
  local MARKS = 4096
  local RING = {{0,-1},{1,-1},{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1}}
  local SIDES = {{1,0},{-1,0},{0,1},{0,-1}}
  local FOUNDATION = 'space-platform-foundation'
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(x, y) return string.format('(%g,%g)', x + 0.5, y + 0.5) end

  -- A phase's tile set: a list of {x, y} (a tile's centre or corner), an area {left_top, right_bottom} (the tiles in
  -- it), or a list of areas. Returns its items in the order given, {x, y} for a tile and {x0, y0, x1, y1, a=true} for an
  -- area (its tiles walked row by row when the phase runs: an 8192-tile plan's parse took 10 ms expanded), and how many
  -- tiles they hold.
  function M.tiles_of(v, what, budget)
    assert(type(v) == 'table' or type(v) == 'string', what .. ': tiles ({x,y} each), an area {left_top, right_bottom} or "x0..x1,y0..y1", or a list of them')
    local out, n = {}, 0
    local function grow(x0, y0, x1, y1, count)
      n = n + count
      budget.n = budget.n + count
      if budget.n > MAX_TILES then error(string.format('phases: at most %d tiles in all a read', MAX_TILES), 0) end
      local b = budget.box
      if x0 < b[1] then b[1] = x0 end; if y0 < b[2] then b[2] = y0 end; if x1 > b[3] then b[3] = x1 end; if y1 > b[4] then b[4] = y1 end
    end
    local function add(x, y)
      grow(x, y, x, y, 1)
      out[#out+1] = {x, y}
    end
    local function area(ar)
      local lt, rb = ar.left_top or ar[1], ar.right_bottom or ar[2]
      assert(type(lt) == 'table' and type(rb) == 'table' and type(lt.x or lt[1]) == 'number' and type(rb.x or rb[1]) == 'number',
        what .. ': an area is {left_top: {x,y}, right_bottom: {x,y}}')
      local x0, y0, x1, y1 = lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2]
      assert(x1 > x0 and y1 > y0 and x1 - x0 <= 256 and y1 - y0 <= 256, what .. ': an area nonempty, at most 256x256')
      local a = {math.floor(x0), math.floor(y0), math.ceil(x1) - 1, math.ceil(y1) - 1, a=true}
      grow(a[1], a[2], a[3], a[4], (a[3] - a[1] + 1) * (a[4] - a[2] + 1))
      out[#out+1] = a
    end
    -- "x0..x1,y0..y1" (the tiles x0 to x1 and y0 to y1, as the read gives areas back) or "x,y" (one tile)
    local function text(e, i)
      local x0, x1, y0, y1 = e:match('^%s*(-?%d+)%.%.(-?%d+)%s*,%s*(-?%d+)%.%.(-?%d+)%s*$')
      if x0 then return area({left_top={x=tonumber(x0), y=tonumber(y0)}, right_bottom={x=tonumber(x1) + 1, y=tonumber(y1) + 1}}) end
      local x, y = e:match('^%s*(-?[%d.]+)%s*,%s*(-?[%d.]+)%s*$')
      if x and tonumber(x) and tonumber(y) then return add(math.floor(tonumber(x)), math.floor(tonumber(y))) end
      error(string.format('%s[%s]: "%s" is not "x0..x1,y0..y1" or "x,y"', what, tostring(i), e), 0)
    end
    if type(v) == 'string' then text(v, 1); return out, n end
    if v.left_top or v.right_bottom then area(v); return out, n end
    for i, e in ipairs(v) do
      assert(type(e) == 'table' or type(e) == 'string', string.format('%s[%d]: {x,y}, an area or "x0..x1,y0..y1"', what, i))
      if type(e) == 'string' then text(e, i)
      elseif e.left_top or e.right_bottom then area(e)
      else
        local x, y = e.x or e[1], e.y or e[2]
        assert(type(x) == 'number' and type(y) == 'number', string.format('%s[%d]: {x,y} or an area', what, i))
        add(math.floor(x), math.floor(y))
      end
    end
    return out, n
  end

  -- The model: the surface's tiles through a cache (true: empty), marks and ghosts as ordered sets, the hub's foundation.
  -- (box: the phases' tiles; the marks and tile ghosts read within MARGIN of it, the thrusters within 90 tiles north:
  -- a whole platform's searches cost 2.5-3 ms each on a copy of world n's Asterion)
  local MARGIN = 8
  -- (the three searches are the job's first steps, each charged by the area it looks at: a search over a whole
  -- Asterion-sized platform costs 2.5-3 ms on a copy of world n, so a step a tick at most)
  local function new_model(pl, box)
    local s, hub = pl.surface, pl.hub and pl.hub.valid and pl.hub or nil
    local m = {s=s, hub=hub, cache={}, start={}, start_list={}, marks={list={}, at={}}, ghosts={list={}, at={}}, steps=0, stand={},
      near={{box[1] - MARGIN, box[2] - MARGIN}, {box[3] + MARGIN + 1, box[4] + MARGIN + 1}},
      thr_area={{box[1] - 16, box[2] - 90}, {box[3] + 17, box[4] + 1}}, init=1}
    m.area_cost = math.max(1, math.floor((box[3] - box[1] + 2 * MARGIN + 1) * (box[4] - box[2] + 2 * MARGIN + 1) / 250))
    m.stock = hub and try(function() return hub.get_item_count(FOUNDATION) end) or 0
    m.room = hub and TC.room(hub, FOUNDATION) or math.huge
    return m
  end
  local function init_step(m)
    local s = m.s
    if m.init == 1 then
      m.thr = try(function() return s.find_entities_filtered{type='thruster', area=m.thr_area, limit=64} end) or {}
      m.st = TC.play_start({}, m.hub, m.thr)
    elseif m.init == 2 then
      for i, e in ipairs(try(function() return s.find_entities_filtered{type='deconstructible-tile-proxy', area=m.near, limit=MARKS + 1} end) or {}) do
        if i > MARKS then m.marks_capped = true; break end
        local x, y = math.floor(e.position.x), math.floor(e.position.y)
        local k = key(x, y)
        if not m.marks.at[k] then local t = {x, y}; m.marks.at[k] = t; m.marks.list[#m.marks.list+1] = t end
      end
    else
      for i, g in ipairs(try(function() return s.find_entities_filtered{type='tile-ghost', area=m.near, limit=MARKS + 1} end) or {}) do
        if i > MARKS then m.ghosts_capped = true; break end
        if try(function() return g.ghost_name end) == FOUNDATION then
          local x, y = math.floor(g.position.x), math.floor(g.position.y)
          local k = key(x, y)
          if not m.ghosts.at[k] then local t = {x, y}; m.ghosts.at[k] = t; m.ghosts.list[#m.ghosts.list+1] = t end
        end
      end
      m.start_marks, m.start_ghosts = #m.marks.list, #m.ghosts.list
    end
    m.init = m.init + 1
    if m.init > 3 then m.init = nil end
    return m.area_cost
  end
  local function empty(m, x, y) return is_empty(m.s, x, y, m.cache) end
  -- A tile's state at the start, kept the first time the model changes it.
  local function set(m, x, y, is_empty_now)
    local k = key(x, y)
    if m.start[k] == nil then local v = {x, y, empty(m, x, y)}; m.start[k] = v; m.start_list[#m.start_list+1] = v end
    m.cache[k] = is_empty_now
  end
  local function drop(set_, k)
    if not set_.at[k] then return false end
    set_.at[k] = nil
    return true
  end
  local function add(set_, x, y)
    local k = key(x, y)
    if set_.at[k] then return false end
    local t = {x, y}
    set_.at[k] = t; set_.list[#set_.list+1] = t
    return true
  end
  local function standing(m, x, y)
    local k = key(x, y)
    local v = m.stand[k]
    if v == nil or (v and not v.valid) then v = TC.standing(m.s, x, y) or false; m.stand[k] = v end
    return v or nil
  end
  -- Why a marked tile does not go now, or nil.
  local function removal_why(m, x, y)
    local e = standing(m, x, y)
    if e then return string.format('%s %s stands on it', e.name, string.format('(%g,%g)', e.position.x, e.position.y)), e end
    local why = TC.removal_rule(m.s, x, y, m.cache)
    if why then return why end
    if m.room <= 0 then return 'the hub has no room for ' .. FOUNDATION end
    return nil
  end
  -- Why a ghost is not built now, or nil.
  local function build_why(m, x, y)
    local r = TC.play_rule(m.s, m.st, m.cache)({x, y})
    if type(r) == 'string' then return r end
    if type(r) == 'table' then
      local firsts = {}
      for i, run in ipairs(r) do if i <= 4 then firsts[i] = at(run[1][1], run[1][2]) end end
      return string.format('building it would split the empty space beside it: %s meet only through it', table.concat(firsts, ' and '))
    end
    if m.stock <= 0 then return 'the hub holds no ' .. FOUNDATION end
    return nil
  end
  -- How many runs of empty space round (x,y): blocks of empty places round the ring of 8 that hold a side (as
  -- tilecheck's runs, without building them).
  local function run_count(m, x, y)
    local e = {}
    for i, d in ipairs(RING) do e[i] = empty(m, x + d[1], y + d[2]) end
    local start
    for i = 1, 8 do if not e[i] then start = i; break end end
    if not start then return 1 end
    local n, inrun, side = 0, false, false
    for step = 1, 8 do
      local i = (start + step - 1) % 8 + 1
      if e[i] then
        inrun = true
        if i % 2 == 1 then side = true end
      elseif inrun then
        if side then n = n + 1 end
        inrun, side = false, false
      end
    end
    if inrun and side then n = n + 1 end
    return n
  end
  -- The rules as the play checks them (the reasons are read apart, for what is left).
  local function can_remove(m, x, y)
    return m.room > 0 and run_count(m, x, y) == 1 and not standing(m, x, y)
  end
  local function can_build(m, x, y)
    local st = m.st
    if st.hub_y and y + 0.5 < st.hub_y - 200 then return false end
    for _, b in ipairs(st.thr) do
      if x + 0.5 > b.x0 and x + 0.5 < b.x1 and y + 0.5 > b.y1 and y + 0.5 < b.y1 + 82 then return false end
    end
    local near = false
    for _, d in ipairs(RING) do if not empty(m, x + d[1], y + d[2]) then near = true; break end end
    return near and run_count(m, x, y) <= 1 and m.stock > 0
  end
  -- The play of one phase as a job's steps, resumable across ticks: each unit is a rule check, a tile read for a phase's
  -- change, or a tile followed for floor cut off. job.stage: ops (the phase's changes), settle (removals and builds
  -- until neither changes: every mark and ghost looked at once, then those beside a tile that changed), cuts (from
  -- each tile that went), then the phase's row.
  local function begin_phase(job, spec, label)
    job.spec, job.label, job.stage, job.op = spec, label, 'ops', {list='cancel', i=1}
    job.ph = {went={}, built={}, n={cancelled_marks=0, cancelled_ghosts=0, marked=0, ghosts_dropped=0, already_empty=0, ghosted=0, unmarked=0, already_floor=0}}
  end
  -- (cancel_more: the rollback's second list to cancel, the ghosts after the marks)
  local OPS = {'cancel', 'cancel_more', 'remove', 'fill'}
  -- A walk over a set's list in steps (the settle's work list, the residuals): the live entries kept in a new list.
  local function walk_start(m, which) return {which=which, list=m[which].list, i=1, keep={}} end
  local function op_step(job)
    local m, ph, spec, op = job.m, job.ph, job.spec, job.op
    local list = spec[op.list] or {}
    local item = list[op.i]
    local t = item
    if item and item.a then
      -- an area's next tile, row by row
      op.cx, op.cy = op.cx or item[1], op.cy or item[2]
      t = {op.cx, op.cy}
      op.cx = op.cx + 1
      if op.cx > item[3] then op.cx, op.cy = item[1], op.cy + 1 end
      if op.cy > item[4] then op.cx, op.cy = nil, nil; op.i = op.i + 1 end
    elseif item then op.i = op.i + 1 end
    if not t then
      local nxt
      for j, name in ipairs(OPS) do if name == op.list then nxt = OPS[j + 1] end end
      if nxt then op.list, op.i, op.cx, op.cy = nxt, 1, nil, nil; return 0 end
      job.work, job.queued, job.walk, job.stage = {}, {}, walk_start(m, 'marks'), 'prep'
      return 0
    end
    local n = ph.n
    local k = key(t[1], t[2])
    if op.list == 'cancel' or op.list == 'cancel_more' then
      if drop(m.marks, k) then n.cancelled_marks = n.cancelled_marks + 1 end
      if drop(m.ghosts, k) then n.cancelled_ghosts = n.cancelled_ghosts + 1 end
      return 0.1
    elseif op.list == 'remove' then
      if drop(m.ghosts, k) then n.ghosts_dropped = n.ghosts_dropped + 1
      elseif empty(m, t[1], t[2]) then n.already_empty = n.already_empty + 1
      elseif add(m.marks, t[1], t[2]) then n.marked = n.marked + 1 end
    else
      if drop(m.marks, k) then n.unmarked = n.unmarked + 1
      elseif not empty(m, t[1], t[2]) then n.already_floor = n.already_floor + 1
      elseif add(m.ghosts, t[1], t[2]) then n.ghosted = n.ghosted + 1 end
    end
    return 1
  end
  -- The settle's work list: every live mark, then every live ghost.
  local function prep_step(job)
    local m, w = job.m, job.walk
    local set_ = m[w.which]
    local t = w.list[w.i]
    if not t then
      set_.list = w.keep
      if w.which == 'marks' then job.walk = walk_start(m, 'ghosts') else job.walk, job.wi, job.stage = nil, 1, 'settle' end
      return 0
    end
    w.i = w.i + 1
    local k = key(t[1], t[2])
    if set_.at[k] == t then w.keep[#w.keep+1] = t; job.work[#job.work+1] = t; job.queued[k] = true end
    return 0.2
  end
  local function settle_step(job)
    local m, ph = job.m, job.ph
    local t = job.work[job.wi]
    if not t or m.steps >= STEPS then
      job.unsettled = t ~= nil or nil
      job.work, job.queued, job.cut_i, job.joined, job.cut, job.stage = nil, nil, 1, {}, {}, 'cuts'
      return 0
    end
    job.wi = job.wi + 1
    local x, y = t[1], t[2]
    local k = key(x, y)
    job.queued[k] = nil
    local did = false
    if m.marks.at[k] then
      if empty(m, x, y) then drop(m.marks, k); return 0.1 end
      m.steps = m.steps + 1
      if can_remove(m, x, y) then
        set(m, x, y, true); drop(m.marks, k)
        m.room, m.stock = m.room - 1, m.stock + 1
        ph.went[#ph.went+1] = t; did = true
      end
    elseif m.ghosts.at[k] then
      if not empty(m, x, y) then drop(m.ghosts, k); return 0.1 end
      m.steps = m.steps + 1
      if can_build(m, x, y) then
        set(m, x, y, false); drop(m.ghosts, k)
        m.stock, m.room = m.stock - 1, m.room + 1
        ph.built[#ph.built+1] = t; did = true
      end
    else return 0.1 end
    if did then
      for _, d in ipairs(RING) do
        local nk = key(x + d[1], y + d[2])
        local n = m.marks.at[nk] or m.ghosts.at[nk]
        if n and not job.queued[nk] then job.queued[nk] = true; job.work[#job.work+1] = n end
      end
    end
    return 1
  end
  -- Floor cut off from the hub by a tile that went: from each built side neighbour, the foundation joined to it by
  -- sides, followed up to PIECE tiles (more, or the hub's tile: joined); a piece cut off with its tiles, box and what
  -- stands on it. Charged a unit for 4 tiles followed.
  local function cut_step(job)
    local m = job.m
    local t = job.ph.went[job.cut_i]
    if not t then job.walk, job.res, job.stage = walk_start(m, 'marks'), {wait={}, unbuilt={}, nw=0, nu=0}, 'resid'; return 0 end
    job.cut_i = job.cut_i + 1
    local joined, cost = job.joined, 0
    local hx, hy = m.hub and m.hub.valid and math.floor(m.hub.position.x) or 0, m.hub and m.hub.valid and math.floor(m.hub.position.y) or 0
    for _, d in ipairs(SIDES) do
      local sx, sy = t[1] + d[1], t[2] + d[2]
      local sk = key(sx, sy)
      if joined[sk] == nil and not empty(m, sx, sy) then
        local seen, queue, i, reached = {[sk]=true}, {{sx, sy}}, 1, false
        while queue[i] and not reached do
          local c = queue[i]; i = i + 1
          if (c[1] == hx and c[2] == hy) or joined[key(c[1], c[2])] == true or #queue > PIECE then reached = true; break end
          for _, e in ipairs(SIDES) do
            local nx, ny = c[1] + e[1], c[2] + e[2]
            local nk = key(nx, ny)
            if not seen[nk] and not empty(m, nx, ny) then seen[nk] = true; queue[#queue+1] = {nx, ny} end
          end
        end
        cost = cost + #queue
        for _, c in ipairs(queue) do joined[key(c[1], c[2])] = reached end
        if not reached then
          local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
          local on = {}
          for _, c in ipairs(queue) do
            x0, y0, x1, y1 = math.min(x0, c[1]), math.min(y0, c[2]), math.max(x1, c[1]), math.max(y1, c[2])
            local e = standing(m, c[1], c[2])
            if e and #on < 8 then on[#on+1] = string.format('%s (%g,%g)', e.name, e.position.x, e.position.y) end
          end
          job.cut_tiles = (job.cut_tiles or 0) + #queue
          job.cut[#job.cut+1] = string.format('%d foundation tile%s in %d..%d,%d..%d cut off from the hub\'s floor (joined by sides)%s', #queue, #queue == 1 and '' or 's',
            x0, x1, y0, y1, #on > 0 and '; on it: ' .. table.concat(on, ', ') or '')
        end
      end
    end
    return math.max(0.25, cost / 4)
  end
  -- The residuals: each marked tile waiting and each ghost unbuilt, counted, with why for the first LISTED of each.
  local function resid_step(job)
    local m, w, r = job.m, job.walk, job.res
    local set_ = m[w.which]
    local t = w.list[w.i]
    if not t then
      set_.list = w.keep
      if w.which == 'marks' then job.walk = walk_start(m, 'ghosts') else job.walk, job.stage = nil, 'row' end
      return 0
    end
    w.i = w.i + 1
    local k = key(t[1], t[2])
    if set_.at[k] ~= t then return 0.1 end
    w.keep[#w.keep+1] = t
    if w.which == 'marks' then
      if not empty(m, t[1], t[2]) then
        r.nw = r.nw + 1
        if #r.wait < LISTED then r.wait[#r.wait+1] = at(t[1], t[2]) .. ': ' .. (removal_why(m, t[1], t[2]) or 'not reached: the rule checks ran out'); return 1 end
      end
    elseif empty(m, t[1], t[2]) then
      r.nu = r.nu + 1
      if #r.unbuilt < LISTED then r.unbuilt[#r.unbuilt+1] = at(t[1], t[2]) .. ': ' .. (build_why(m, t[1], t[2]) or 'not reached: the rule checks ran out'); return 1 end
    end
    return 0.2
  end
  local function head(list, n)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
  end
  -- The phase's row.
  local function phase_row(job, i)
    local ph, spec, r = job.ph, job.spec, job.res
    local wait, unbuilt, nwait, nunbuilt = r.wait, r.unbuilt, r.nw, r.nu
    local cut, n = job.cut, ph.n
    local parts = {}
    local nc, nr, nf = spec.n_cancel or (#(spec.cancel or {}) + #(spec.cancel_more or {})), spec.n_remove or #(spec.remove or {}), spec.n_fill or #(spec.fill or {})
    if nc > 0 then parts[#parts+1] = string.format('cancel %d tiles (%d marks, %d ghosts cancelled)', nc, n.cancelled_marks, n.cancelled_ghosts) end
    if nr > 0 then parts[#parts+1] = string.format('remove %d tiles (%d marked%s%s)', nr, n.marked,
      n.ghosts_dropped > 0 and string.format(', %d ghosts dropped', n.ghosts_dropped) or '', n.already_empty > 0 and string.format(', %d empty already', n.already_empty) or '') end
    if nf > 0 then parts[#parts+1] = string.format('fill %d tiles (%d ghosts%s%s)', nf, n.ghosted,
      n.unmarked > 0 and string.format(', %d marks cancelled', n.unmarked) or '', n.already_floor > 0 and string.format(', %d floor already', n.already_floor) or '') end
    local cut_tiles = job.cut_tiles or 0
    job.cut_tiles = nil
    local unsettled = job.unsettled
    -- (strings, few numbers: a number costs about 28 us in the reply's JSON on a copy of world n, a string next to none)
    local out = {phase=i, name=type(spec.name) == 'string' and spec.name or nil, went=#ph.went, built=#ph.built,
      marks_waiting=nwait, ghosts_unbuilt=nunbuilt, waiting=#wait > 0 and wait or nil, unbuilt=#unbuilt > 0 and unbuilt or nil,
      cut=#cut > 0 and head(cut, 8) or nil, cut_tiles=cut_tiles > 0 and cut_tiles or nil, unsettled=unsettled,
      settled=nwait == 0 and nunbuilt == 0 and #cut == 0 and not unsettled}
    out.line = string.format('%s%s: %s; played to stability: %d tile%s went, %d built; %d marked tile%s wait, %d ghost%s unbuilt%s%s',
      job.label, out.name and ' (' .. out.name .. ')' or '', #parts > 0 and table.concat(parts, ', ') or 'no change', #ph.went, #ph.went == 1 and '' or 's', #ph.built,
      nwait, nwait == 1 and '' or 's', nunbuilt, nunbuilt == 1 and '' or 's',
      #cut > 0 and string.format('; %d tiles cut off from the hub\'s floor: %s', cut_tiles, cut[1]) or '',
      unsettled and string.format('; not settled: the %d rule checks a plan takes ran out', STEPS) or '')
    job.unsettled = nil
    return out
  end
  -- The floor changed against the start, a tile at a time: removed (floor then, empty now), added (empty then, floor now).
  local function ends_step(job)
    local m = job.m
    local v = m.start_list[job.ei]
    if not v then
      job.ei = nil
      local removed, added = job.removed, job.added
      job.end_wait, job.end_unbuilt = job.res.nw, job.res.nu
      job.steps_before_rollback = m.steps
      -- the rollback: the marks and ghosts left cancelled with the removed tiles filled back, then the added taken up
      job.back = {}
      if #removed + #added > 0 then
        local first = {}
        if #m.marks.list > 0 then first.cancel = m.marks.list end
        if #m.ghosts.list > 0 then first.cancel_more = m.ghosts.list end
        if #removed > 0 then first.fill = removed end
        if next(first) then job.back[#job.back+1] = {spec=first, step='fill back'} end
        if #added > 0 then job.back[#job.back+1] = {spec={remove=added}, step='take up'} end
      end
      job.bi, job.back_rows, job.stage = 0, {}, 'back'
      return 0
    end
    job.ei = job.ei + 1
    local now = m.cache[key(v[1], v[2])]
    if v[3] == false and now == true then job.removed[#job.removed+1] = {v[1], v[2]}
    elseif v[3] == true and now == false then job.added[#job.added+1] = {v[1], v[2]} end
    return 0.1
  end
  -- Tiles as rectangles, a row at a time (each row's runs, joined with the same run on the row below), as strings
  -- "x0..x1,y0..y1"; at most AREAS kept (the rest counted).
  local AREAS = 256
  local function areas_step(job)
    local a = job.ar
    if a.phase == 'bucket' then
      local t = a.list[a.i]
      if t then
        a.i = a.i + 1
        local r = a.rows[t[2]]
        if not r then r = {}; a.rows[t[2]] = r; a.ys[#a.ys+1] = t[2] end
        r[#r+1] = t[1]
        return 0.1
      end
      table.sort(a.ys)
      a.phase, a.yi, a.open = 'rows', 1, {}
      return 1
    end
    local y = a.ys[a.yi]
    if not y then
      local res = {}
      for i, b in ipairs(a.out) do if i <= AREAS then res[i] = string.format('%d..%d,%d..%d', b.x0, b.x1, b.y0, b.y1) end end
      job.areas[a.which] = {list=res, more=#a.out > AREAS and #a.out - AREAS or nil}
      if a.which == 'removed' then job.ar = {which='added', list=job.added, i=1, phase='bucket', rows={}, ys={}, out={}}
      else job.ar = nil; job.stage = 'final' end
      return 0
    end
    a.yi = a.yi + 1
    local xs = a.rows[y]
    table.sort(xs)
    local runs, i = {}, 1
    while xs[i] do
      local j = i
      while xs[j + 1] == xs[j] + 1 do j = j + 1 end
      runs[#runs+1] = {xs[i], xs[j]}
      i = j + 1
    end
    local next_open = {}
    for _, r in ipairs(runs) do
      local id = r[1] .. ':' .. r[2]
      local b = a.open[id]
      if b and b.y1 == y - 1 then b.y1 = y else b = {x0=r[1], x1=r[2], y0=y, y1=y}; a.out[#a.out+1] = b end
      next_open[id] = b
    end
    a.open = next_open
    return 1 + #xs * 0.1
  end
  local function result(job)
    local m, rows = job.m, job.rows
    local removed, added = job.removed, job.added
    local ra, aa = job.areas.removed, job.areas.added
    local rollback = {fill=#ra.list > 0 and ra.list or nil, fill_more_areas=ra.more, remove=#aa.list > 0 and aa.list or nil, remove_more_areas=aa.more,
      fill_count=#removed, remove_count=#added}
    if #removed + #added > 0 then
      local waits, unbuilt, unsettled, settled = 0, 0, false, true
      for _, r in ipairs(job.back_rows) do
        waits, unbuilt = waits + r.marks_waiting, unbuilt + r.ghosts_unbuilt
        unsettled = unsettled or r.unsettled ~= nil
        settled = settled and r.settled
      end
      rollback.played = job.back_rows
      rollback.order_checked = not unsettled
      -- every removed tile built back and every added one taken up: the floor is the start's again
      rollback.restores = settled
      rollback.line = rollback.restores and string.format('rollback: %d tiles to fill back, then %d to take up, played from the end floor by the same rules: it returns to the start (order checked)', #removed, #added)
        or string.format('rollback: %d tiles to fill back, then %d to take up, played from the end floor: %d marked tiles wait, %d ghosts unbuilt%s: coordinates only, no order that returns to the start was found',
          #removed, #added, waits, unbuilt, unsettled and ', not settled' or '')
      rollback.steps = m.steps - job.steps_before_rollback
    else
      rollback.line = 'rollback: nothing to put back (the floor ends as it began)'
    end
    local all_settled, unsettled_phases = true, {}
    for _, r in ipairs(rows) do if not r.settled then all_settled = false; unsettled_phases[#unsettled_phases+1] = r.phase end end
    local line = string.format('%s: %d phase%s played on a model of the floor (%d foundation tiles marked and %d tile ghosts at the start, within 8 tiles of the phases\' tiles%s%s); the end floor: %d tiles taken up, %d added, %d marked tiles waiting, %d ghosts unbuilt; %s; %s',
      job.platform, #rows, #rows == 1 and '' or 's', m.start_marks or 0, m.start_ghosts or 0, (m.marks_capped or m.ghosts_capped) and string.format(', the first %d of each read', MARKS) or '',
      job.ticks > 0 and string.format('; played over %d ticks, the tiles read as each was reached', job.ticks) or '',
      #removed, #added, job.end_wait, job.end_unbuilt,
      all_settled and 'every phase settles (nothing waits, nothing cut off)' or string.format('phase%s %s leave%s residuals (each phase\'s line)', #unsettled_phases == 1 and '' or 's',
        table.concat(unsettled_phases, ', '), #unsettled_phases == 1 and 's' or ''),
      rollback.line)
    return {platform=job.platform, phases=rows,
      ['end']={removed=#removed, added=#added, marks_waiting=job.end_wait, ghosts_unbuilt=job.end_unbuilt, removed_areas=#ra.list > 0 and ra.list or nil, added_areas=#aa.list > 0 and aa.list or nil},
      settled=all_settled, rollback=rollback, rule_checks=m.steps, tiles=job.tiles, ticks=job.ticks, line=line,
      note='read only. A phase: cancel, remove, fill (in that order), then the hub\'s rules played until nothing changes (marks, then ghosts, in the order given; again beside each change). Rules: a marked tile goes with one run of empty space beside it, nothing on it, room in the hub; a ghost is built with foundation among its 8 neighbours, at most one run beside it, out of thruster exhaust, within 200 tiles north of the hub, while the hub holds foundation. Marks and ghosts read within 8 tiles of the phases\' tiles; cut off: not joined to the hub\'s tile by sides (followed ' .. PIECE .. ' tiles). Bounded: ' .. MAX_TILES .. ' tiles and ' .. STEPS .. ' rule checks a plan, ' .. AREAS .. ' areas a list; ' .. NOW .. ' units in the call, ' .. TICK .. ' a tick after (phases_check)'}
  end
  -- Up to n units of work; true when the job is done.
  local function work(job, n)
    local left = n
    while left > 0 and not job.done do
      local used = 0
      local m = job.m
      if m.init then used = init_step(m)
      elseif job.stage == 'ops' then used = op_step(job)
      elseif job.stage == 'prep' then used = prep_step(job)
      elseif job.stage == 'settle' then used = settle_step(job)
      elseif job.stage == 'cuts' then used = cut_step(job)
      elseif job.stage == 'resid' then used = resid_step(job)
      elseif job.stage == 'row' then
        local r = phase_row(job, job.k)
        used = 1
        if job.rollback_step then
          r.phase = nil; r.step = job.rollback_step
          r.waiting = r.waiting and head(r.waiting, 2) or nil; r.unbuilt = r.unbuilt and head(r.unbuilt, 2) or nil; r.cut = r.cut and head(r.cut, 2) or nil
          job.back_rows[#job.back_rows+1] = r
          job.stage = 'back'
        else
          job.rows[#job.rows+1] = r
          job.k = job.k + 1
          if job.k <= #job.parsed then begin_phase(job, job.parsed[job.k], 'phase ' .. job.k)
          else job.removed, job.added, job.ei, job.stage = {}, {}, 1, 'ends' end
        end
      elseif job.stage == 'ends' then used = ends_step(job)
      elseif job.stage == 'back' then
        job.bi = job.bi + 1
        local b = job.back[job.bi]
        if b then job.rollback_step = b.step; begin_phase(job, b.spec, 'rollback (' .. b.step .. ')')
        else job.rollback_step = nil; job.areas = {}; job.ar = {which='removed', list=job.removed, i=1, phase='bucket', rows={}, ys={}, out={}}; job.stage = 'areas' end
      elseif job.stage == 'areas' then used = areas_step(job)
      elseif job.stage == 'final' then
        job.done = game and game.tick or 0; job.result = result(job)
        job.m, job.parsed, job.back, job.ph, job.spec, job.res, job.removed, job.added, job.back_rows, job.rows, job.areas = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        used = 1
      end
      left = left - used
      if used == 0 then left = left - 0.05 end
    end
    return job.done ~= nil
  end

  local function store()
    local st = api.state and api.state()
    if not st then return nil end
    st.floorphases = st.floorphases or {seq=0, jobs={}}
    return st.floorphases
  end
  -- platform_plan {platform, phases: [{cancel?, remove?, fill?, name?}, ...]}: the plan's job; done in the call when it
  -- fits NOW units, else read later by phases_check (TICK units a tick).
  function M.read(pl, phases)
    assert(type(phases) == 'table' and #phases >= 1 and #phases <= 16, 'phases: 1..16 phases, each {cancel, remove, fill: tiles or an area; name}')
    -- every phase's tiles first (refusals before any work; the box the model reads round)
    local budget = {n=0, box={math.huge, math.huge, -math.huge, -math.huge}}
    local parsed = {}
    for i, spec in ipairs(phases) do
      if not (type(spec) == 'table' and (spec.cancel ~= nil or spec.remove ~= nil or spec.fill ~= nil)) then
        error(string.format('phases[%d]: {cancel, remove, fill} (tiles or an area each; applied in that order), name optional', i), 0)
      end
      for k in pairs(spec) do
        if not (k == 'cancel' or k == 'remove' or k == 'fill' or k == 'name') then error(string.format('phases[%d].%s: a phase takes cancel, remove, fill and name', i, tostring(k)), 0) end
      end
      local ph = {name=spec.name}
      for _, op in ipairs({'cancel', 'remove', 'fill'}) do
        if spec[op] ~= nil then ph[op], ph['n_' .. op] = M.tiles_of(spec[op], string.format('phases[%d].%s', i, op), budget) end
      end
      parsed[i] = ph
    end
    if budget.box[1] == math.huge then budget.box = {0, 0, 0, 0} end
    local job = {platform=pl.name, m=new_model(pl, budget.box), parsed=parsed, rows={}, k=1, tiles=budget.n, started=game and game.tick or 0, ticks=0}
    begin_phase(job, parsed[1], 'phase 1')
    if work(job, NOW) then return job.result end
    local st = store()
    -- (no store: a test's platplan) the rest in the call
    if not st then work(job, math.huge); return job.result end
    st.seq = st.seq + 1
    job.id = st.seq
    st.jobs[job.id] = job
    local ids = {}
    for id in pairs(st.jobs) do ids[#ids+1] = id end
    table.sort(ids)
    while #ids > JOBS do st.jobs[table.remove(ids, 1)] = nil end
    return {platform=pl.name, phases_check=job.id, running=true, tiles=budget.n,
      line=string.format('%s: %d phases, %d tiles: more than one tick of rule checks (%d units in the call, %d a tick after); platform_plan {platform: "%s", phases_check: %d} reads it',
        pl.name, #parsed, budget.n, NOW, TICK, pl.name, job.id)}
  end
  -- One running job a tick (the oldest): TICK units.
  function M.tick()
    local st = api.state and api.state().floorphases
    if not st then return end
    local job
    for _, j in pairs(st.jobs) do if not j.done and (not job or j.id < job.id) then job = j end end
    if not job then return end
    if not (job.m and job.m.s) or job.m.s.valid == false then job.done = game.tick; job.result = {line='the platform\'s surface is gone'}; return end
    job.ticks = job.ticks + 1
    work(job, TICK)
  end
  -- platform_plan {platform, phases_check: id}
  function M.check(id)
    local st = store()
    local job = st and st.jobs[id]
    if not job then
      local ids = {}
      for k in pairs(st and st.jobs or {}) do ids[#ids+1] = k end
      table.sort(ids)
      error(string.format('no phases plan #%s (kept: the last %d; held now: %s)', tostring(id), JOBS, #ids > 0 and table.concat(ids, ', ') or 'none'), 0)
    end
    if not job.done then
      return {phases_check=id, running=true, ticks=job.ticks, phase=job.rollback_step and 'rollback' or job.k, of=#(job.parsed or {}), rule_checks=job.m and job.m.steps,
        line=string.format('phases plan #%d running: %s, %d ticks so far', id, job.rollback_step and 'the rollback' or string.format('phase %d of %d', job.k, #job.parsed), job.ticks)}
    end
    local r = job.result
    r.phases_check = id
    return r
  end
  M.run_count = function(s, x, y, cache) return run_count({s=s, cache=cache}, x, y) end
  return M
end
