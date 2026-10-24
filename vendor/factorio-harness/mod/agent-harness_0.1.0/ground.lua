-- Items on the ground (item-entity): a summary by item for an area (scan and
-- observe), the watch behind status alerts (a full cargo landing pad whose
-- pods spill, large piles near our buildings), marking them for deconstruction
-- as a planner does (robots take them to storage), and picking them up over an
-- area, walking from one to the next as a player holding the pickup key.
local snapfail = require('snapfail')
local groundstack = require('groundstack')
return function(api)
  local M = {handlers={}}
  local WATCH_EVERY = 1800      -- ticks between watch passes (shared by every agent)
  local PILE_MIN = 100          -- stacks in a 64-tile cell that make a pile
  local PILE_CELL = 64
  local PAD_RADIUS = 40         -- spill counted around a full landing pad
  local SAMPLE = 5000           -- stacks read for item counts (the stack total is exact)
  local SCAN_LIMIT = 30000      -- stacks binned per surface for piles
  local MAX_MARK = 32768
  local PICK_EVERY = 6          -- one stack every 6 ticks, as pickup does
  local MAX_SKIPS = 8

  -- (d23 batch121 CD3, viewer Aurora site:4362: "Could scans label entities, item counts and usable storage slots
  -- separately? Gleba's cleanup was estimated at 120 chests before Astra clarified the counts and calculated eight.")
  -- Sonnet read the status line's "11793 item stacks on the ground" as full stacks; each was one item on the ground.
  -- An item's storage slots: its count over its stack size, rounded up.
  local sizes = {}
  local function stack_size(name)
    local n = sizes[name]
    if n == nil then
      local ok, v = pcall(function() return prototypes.item[name].stack_size end)
      n = ok and type(v) == 'number' and v > 0 and v or false
      sizes[name] = n
    end
    return n or nil
  end
  M.stack_size = stack_size
  local function key_of(stack)
    local q = stack.quality and stack.quality.name
    return stack.name .. ((q and q ~= 'normal') and ' (' .. q .. ')' or '')
  end
  -- Per item: count, stacks and the box they lie in; most first. `limit`
  -- items are listed, the rest counted in more_items.
  function M.summary(list, limit)
    local by, order, stacks = {}, {}, 0
    for _, e in ipairs(list) do
      local s = e.valid and e.stack
      if s and s.valid_for_read then
        stacks = stacks + 1
        local k, pos = key_of(s), e.position
        local r = by[k]
        if not r then
          r = {name=k, base=s.name, count=0, stacks=0, box={left_top={x=pos.x, y=pos.y}, right_bottom={x=pos.x, y=pos.y}}}
          by[k] = r; order[#order+1] = r
        end
        r.count = r.count + s.count; r.stacks = r.stacks + 1
        -- (d22 batch78 AN1) an item that spoils: its stalest stack's freshness, percent
        local st = groundstack.stack(e)
        if st and st.fresh and (not r.fresh or st.fresh < r.fresh) then r.fresh = st.fresh end
        local b = r.box
        b.left_top.x = math.min(b.left_top.x, pos.x); b.left_top.y = math.min(b.left_top.y, pos.y)
        b.right_bottom.x = math.max(b.right_bottom.x, pos.x); b.right_bottom.y = math.max(b.right_bottom.y, pos.y)
      end
    end
    if stacks == 0 then return nil end
    table.sort(order, function(x, y) if x.count ~= y.count then return x.count > y.count end return x.name < y.name end)
    -- stacks: entities on the ground (each one item stack, often of 1); count: the items they hold; slots: the storage
    -- slots those items fill at their stack size (an item whose stack size is not read leaves slots out)
    local count, slots = 0, 0
    for _, r in ipairs(order) do
      local size = stack_size(r.base)
      r.slots = size and math.ceil(r.count / size) or nil
      count, slots = count + r.count, slots and r.slots and slots + r.slots or nil
      r.base = nil
    end
    local out = {stacks=stacks, count=count, slots=slots, items={}}
    for i = 1, math.min(#order, limit or 16) do out.items[i] = order[i] end
    if #order > #out.items then out.more_items = #order - #out.items end
    return out
  end
  local function short(sum, n)
    local parts = {}
    for i = 1, math.min(n, #sum.items) do parts[i] = sum.items[i].count .. ' ' .. sum.items[i].name end
    local more = #sum.items - n + (sum.more_items or 0)
    return table.concat(parts, ', ') .. (more > 0 and string.format(' (+%d more items)', more) or '')
  end
  local function xy(pos) return string.format('(%d,%d)', math.floor(pos.x), math.floor(pos.y)) end

  -- The watch: one pass per force every WATCH_EVERY ticks, on demand (status,
  -- reply hints), nothing per tick.
  local function pad_inventory(pad)
    local ok, inv = pcall(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
    return ok and inv or nil
  end
  local function ours(surface, force, area)
    for _, e in pairs(surface.find_entities_filtered{area=area, force=force, limit=8}) do
      if e.valid and e.type ~= 'character' then return true end
    end
    return false
  end
  local function scan_surface(surface, force, w)
    local total = surface.count_entities_filtered{type='item-entity'}
    if total == 0 then return end
    local near_pads = {}
    for _, pad in pairs(surface.find_entities_filtered{type='cargo-landing-pad', force=force}) do
      local inv = pad.valid and pad_inventory(pad)
      if inv and inv.count_empty_stacks(true, false) == 0 then
        local stacks = surface.count_entities_filtered{position=pad.position, radius=PAD_RADIUS, type='item-entity'}
        if stacks > 0 then
          local sum = M.summary(surface.find_entities_filtered{position=pad.position, radius=PAD_RADIUS, type='item-entity', limit=SAMPLE}, 8)
          w.pads[#w.pads+1] = {key='pad:' .. surface.name .. xy(pad.position), surface=surface.name, position=pad.position,
            slots=#inv, stacks=stacks, items=sum, sampled=stacks > SAMPLE and SAMPLE or nil}
          near_pads[#near_pads+1] = pad.position
        end
      end
    end
    if total < PILE_MIN then return end
    local cells = {}
    for _, e in pairs(surface.find_entities_filtered{type='item-entity', limit=SCAN_LIMIT}) do
      local pos = e.position
      local k = math.floor(pos.x / PILE_CELL) .. ',' .. math.floor(pos.y / PILE_CELL)
      cells[k] = (cells[k] or 0) + 1
    end
    for k, n in pairs(cells) do
      if n >= PILE_MIN then
        local cx, cy = k:match('^(-?%d+),(-?%d+)$')
        cx, cy = tonumber(cx) * PILE_CELL, tonumber(cy) * PILE_CELL
        local area = {left_top={x=cx, y=cy}, right_bottom={x=cx + PILE_CELL, y=cy + PILE_CELL}}
        local mid = {x=cx + PILE_CELL / 2, y=cy + PILE_CELL / 2}
        local by_pad = false
        for _, pp in ipairs(near_pads) do if api.distance(pp, mid) < PAD_RADIUS + PILE_CELL / 2 then by_pad = true end end
        if not by_pad and ours(surface, force, area) then
          local stacks = surface.count_entities_filtered{area=area, type='item-entity'}
          local sum = M.summary(surface.find_entities_filtered{area=area, type='item-entity', limit=SAMPLE}, 8)
          w.piles[#w.piles+1] = {key='pile:' .. surface.name .. ':' .. k, surface=surface.name, area=area, stacks=stacks, items=sum,
            sampled=stacks > SAMPLE and SAMPLE or nil}
        end
      end
    end
  end
  -- With the background pass running (M.watch_tick) the watch is its last complete pass; before it has one (and in tests
  -- without it) it is made here at once.
  function M.watch(force)
    local s = api.state()
    s.ground_watch = s.ground_watch or {}
    s.ground_forces = s.ground_forces or {}
    s.ground_forces[force.name] = true
    local w = s.ground_watch[force.name]
    if w and (s.ground_bg or (game.tick - w.tick < WATCH_EVERY and game.tick >= w.tick)) then return w end
    w = {tick=game.tick, pads={}, piles={}}
    for _, surface in pairs(game.surfaces) do
      local ok, err = pcall(scan_surface, surface, force, w)
      if not ok then w.error = tostring(err) end
    end
    table.sort(w.piles, function(x, y) return x.stacks > y.stacks end)
    s.ground_watch[force.name] = w
    return w
  end
  -- The background pass (operator 22:00, task-slowreads: the watch counted and found every item on the ground on
  -- every surface in one tick, 31 ms on world n, every 30 s, inside whichever reply came then): per force asked for,
  -- each surface walked in bands (walk.lua) for items on the ground and landing pads, the items binned in PILE_CELL
  -- cells as they come; then one full pad or one pile cell a step, as scan_surface reads them; the pass replaces the
  -- watch when it ends, one every WATCH_EVERY ticks.
  local walk = api.walk or require('walk'){state=api.state}
  local function watch_step(s, force, tick)
    s.ground_jobs = s.ground_jobs or {}
    s.ground_steps = s.ground_steps or {}
    local job = s.ground_jobs[force.name]
    if not job then
      local w = s.ground_watch and s.ground_watch[force.name]
      if w and tick - snapfail.since(w.tick, w.refresh_failed) < WATCH_EVERY then return end
      local list = {}
      for _, surface in pairs(game.surfaces) do list[#list+1] = surface.index end
      table.sort(list)
      s.ground_jobs[force.name] = {start=tick, surfaces=list, si=1, w={tick=tick, pads={}, piles={}}, steps=0,
        every=walk.every(s.ground_steps[force.name], WATCH_EVERY)}
      return
    end
    if not walk.due(job, tick, WATCH_EVERY) then return end
    job.steps = job.steps + 1
    if job.todo then
      local x = table.remove(job.todo, 1)
      local surface = x and game.get_surface(x.surface)
      if surface and x.kind == 'pad' then
        local pad = x.pad
        local inv = pad.valid and pad_inventory(pad)
        if inv and inv.count_empty_stacks(true, false) == 0 then
          local stacks = surface.count_entities_filtered{position=pad.position, radius=PAD_RADIUS, type='item-entity'}
          if stacks > 0 then
            local sum = M.summary(surface.find_entities_filtered{position=pad.position, radius=PAD_RADIUS, type='item-entity', limit=SAMPLE}, 8)
            job.w.pads[#job.w.pads+1] = {key='pad:' .. surface.name .. xy(pad.position), surface=surface.name, position=pad.position,
              slots=#inv, stacks=stacks, items=sum, sampled=stacks > SAMPLE and SAMPLE or nil}
            job.near[#job.near+1] = pad.position
          end
        end
      elseif surface and x.kind == 'pile' then
        local cx, cy = x.cx * PILE_CELL, x.cy * PILE_CELL
        local area = {left_top={x=cx, y=cy}, right_bottom={x=cx + PILE_CELL, y=cy + PILE_CELL}}
        local mid = {x=cx + PILE_CELL / 2, y=cy + PILE_CELL / 2}
        local by_pad = false
        for _, pp in ipairs(job.near) do if api.distance(pp, mid) < PAD_RADIUS + PILE_CELL / 2 then by_pad = true end end
        if not by_pad and ours(surface, force, area) then
          local stacks = surface.count_entities_filtered{area=area, type='item-entity'}
          local sum = M.summary(surface.find_entities_filtered{area=area, type='item-entity', limit=SAMPLE}, 8)
          job.w.piles[#job.w.piles+1] = {key='pile:' .. surface.name .. ':' .. x.cx .. ',' .. x.cy, surface=surface.name, area=area,
            stacks=stacks, items=sum, sampled=stacks > SAMPLE and SAMPLE or nil}
        end
      end
      if #job.todo == 0 then job.todo = nil; job.si = job.si + 1 end
      return
    end
    local surface = job.surfaces[job.si] and game.get_surface(job.surfaces[job.si])
    if not job.surfaces[job.si] then
      table.sort(job.w.piles, function(x, y) return x.stacks > y.stacks end)
      s.ground_watch = s.ground_watch or {}
      -- (a watch made since the pass started, a force's first in a reply, is newer: the pass's is dropped)
      local held = s.ground_watch[force.name]
      if not snapfail.older(job.start, held and held.tick) then s.ground_watch[force.name] = job.w end
      s.ground_steps[force.name] = job.steps
      s.ground_jobs[force.name] = nil
      return
    end
    if not surface then job.si = job.si + 1; job.walk = nil; return end
    job.walk = job.walk or walk.start(surface)
    job.cells, job.pads = job.cells or {}, job.pads or {}
    local list = walk.band(job.walk, surface, {type={'item-entity', 'cargo-landing-pad'}})
    if list then
      for _, e in ipairs(list) do
        if e.valid and e.type == 'item-entity' then
          local pos = e.position
          local k = math.floor(pos.x / PILE_CELL) .. ',' .. math.floor(pos.y / PILE_CELL)
          job.cells[k] = (job.cells[k] or 0) + 1
          job.items = (job.items or 0) + 1
          -- (d19 batch44 A1) each item's stacks by 32-tile cell, for where_is (a whole-surface find of the ground's
          -- stacks took 8 ms on the private copy's Nauvis)
          local okst, st = pcall(function() return e.stack end)
          if okst and st and st.valid_for_read then
            job.w.items = job.w.items or {}
            local by = job.w.items[surface.index]
            if not by then by = {}; job.w.items[surface.index] = by end
            local it = by[st.name]
            if not it then it = {}; by[st.name] = it end
            local ck = math.floor(pos.x / 32) .. ',' .. math.floor(pos.y / 32)
            local c = it[ck]
            if not c then c = {x=pos.x, y=pos.y, count=0, stacks=0}; it[ck] = c end
            c.count, c.stacks = c.count + st.count, c.stacks + 1
          end
        elseif e.valid and e.force == force then job.pads[#job.pads+1] = e end
      end
      return
    end
    -- The surface is walked: its full pads first (the piles beside them are the pads'), then its pile cells.
    local todo = {}
    if (job.items or 0) > 0 then
      for _, pad in ipairs(job.pads) do todo[#todo+1] = {kind='pad', surface=surface.index, pad=pad} end
      local keys = {}
      for k, n in pairs(job.cells) do if n >= PILE_MIN then keys[#keys+1] = k end end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local cx, cy = k:match('^(-?%d+),(-?%d+)$')
        todo[#todo+1] = {kind='pile', surface=surface.index, cx=tonumber(cx), cy=tonumber(cy)}
      end
    end
    job.walk, job.cells, job.pads, job.items, job.near = nil, nil, nil, nil, {}
    if #todo > 0 then job.todo = todo else job.si = job.si + 1 end
  end
  function M.watch_tick(tick)
    local s = api.state()
    s.ground_bg = true
    local names = {}
    for name in pairs(s.ground_forces or {player=true}) do names[#names+1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local force = game.forces[name]
      if force then
        local ok, err = pcall(watch_step, s, force, tick)
        if not ok then
          if s.ground_jobs then s.ground_jobs[name] = nil end
          s.ground_errors = {count=((s.ground_errors or {}).count or 0) + 1, last=tostring(err), tick=tick}
          -- (the watch keeps the tick it was made at; the next pass starts WATCH_EVERY after the failure, snapfail.lua)
          if s.ground_watch and s.ground_watch[name] then s.ground_watch[name].refresh_failed = snapfail.failed(err, tick) end
        end
      end
    end
  end
  -- (CD3) the entities on the ground, the items they hold and the storage slots those fill, each labelled
  local function counts_text(n, sum, sampled)
    if not sum then return string.format('entities %d (each an item stack on the ground); items not read', n) end
    return string.format('entities %d (each an item stack on the ground); items %d%s: %s; storage slots they fill %s',
      n, sum.count or 0, sampled and string.format(' in the %d entities read', sampled) or '', short(sum, 5),
      sum.slots and tostring(sum.slots) .. ' (at each item\'s stack size)' or 'not read')
  end
  M.counts_text = counts_text
  local function pad_line(pad)
    return string.format('cargo landing pad at %s on %s is full (%d/%d slots) and pods spill within %d tiles: %s',
      xy(pad.position), pad.surface, pad.slots, pad.slots, PAD_RADIUS, counts_text(pad.stacks, pad.items, pad.sampled))
  end
  local function pile_line(pile)
    local lt, rb = pile.area.left_top, pile.area.right_bottom
    if pile.items then
      -- The box the stacks lie in, within the cell.
      local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
      for _, r in ipairs(pile.items.items) do
        x1 = math.min(x1, r.box.left_top.x); y1 = math.min(y1, r.box.left_top.y)
        x2 = math.max(x2, r.box.right_bottom.x); y2 = math.max(y2, r.box.right_bottom.y)
      end
      lt, rb = {x=x1, y=y1}, {x=x2, y=y2}
    end
    return string.format('items on the ground at %s-%s on %s, near our buildings: %s', xy(lt), xy(rb), pile.surface,
      counts_text(pile.stacks, pile.items, pile.sampled))
  end
  -- status alerts: every spilling pad and the largest piles.
  function M.alerts(p)
    local ok, w = pcall(M.watch, p.force)
    if not ok then return nil end
    local lines = {}
    for _, pad in ipairs(w.pads) do lines[#lines+1] = pad_line(pad) end
    for i, pile in ipairs(w.piles) do
      if i > 3 then lines[#lines+1] = string.format('+%d more piles of 100+ item stacks', #w.piles - 3); break end
      lines[#lines+1] = pile_line(pile)
    end
    lines[#lines+1] = snapfail.line('the ground watch', w.tick, w.refresh_failed)
    return #lines > 0 and lines or nil
  end
  -- Reply hints: a pad or pile once when first seen by this player, again
  -- when it has grown by half since.
  function M.unseen(p, lines)
    local ok, w = pcall(M.watch, p.force)
    if not ok then return lines end
    local s = api.state()
    s.ground_seen = s.ground_seen or {}
    local seen = s.ground_seen[p.index] or {}
    s.ground_seen[p.index] = seen
    local add = {}
    local function check(x, line)
      local was = seen[x.key]
      if not was or x.stacks >= was * 1.5 then add[#add+1] = line(x); seen[x.key] = x.stacks end
    end
    for _, pad in ipairs(w.pads) do check(pad, pad_line) end
    for i, pile in ipairs(w.piles) do if i <= 3 then check(pile, pile_line) end end
    if #add == 0 then return lines end
    lines = lines or {}
    for _, line in ipairs(add) do lines[#lines+1] = line end
    return lines
  end

  -- (d19 batch41 A3, Sol seq 863: a cancel over 823 stacks on Fulgora read cancelled 0 beside item_stacks 823, and 163
  -- construction robots seemed queued there still) the construction robots of the networks whose construction area
  -- covers the box (sampled every 32 tiles) with an order on an item stack in it: robots and orders, the first MAX_ROBOTS
  -- robots read (50 robots read in 0.29 ms on the private copy). On 2.0.77 (a private copy of world n) a cancel takes the orders off at once: 84 orders on 200 marked
  -- stacks went to 0 the same tick; robots already carrying a stack take it on to storage.
  local MAX_ROBOTS = 1000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function robot_orders(surface, force, box)
    local nets, seen = {}, {}
    local lt, rb = box.left_top or box[1], box.right_bottom or box[2]
    local x = lt.x
    while true do
      local y = lt.y
      while true do
        for _, n in ipairs(try(function() return surface.find_logistic_networks_by_construction_area({x=x, y=y}, force) end) or {}) do
          if n.valid and not seen[n.network_id] then seen[n.network_id] = true; nets[#nets+1] = n end
        end
        if y >= rb.y then break end
        y = math.min(rb.y, y + 32)
      end
      if x >= rb.x then break end
      x = math.min(rb.x, x + 32)
    end
    local robots, orders, read, capped, on, busy = 0, 0, 0, false, {}, {}
    for _, n in ipairs(nets) do
      for _, r in ipairs(try(function() return n.construction_robots end) or {}) do
        read = read + 1
        if read > MAX_ROBOTS then capped = true; break end
        local mine = false
        local q = try(function() return r.robot_order_queue end) or {}
        for _, o in ipairs(q) do
          local t = o.target
          if t and t.valid and t.type == 'item-entity' then
            local at = t.position
            if at.x >= lt.x and at.x <= rb.x and at.y >= lt.y and at.y <= rb.y then orders = orders + 1; mine = true end
          end
        end
        if mine then robots = robots + 1; on[r] = true end
        if #q > 0 then busy[r] = true end
      end
      if capped then break end
    end
    return {robots=robots, orders=orders, networks=#nets, capped=capped, on=on, busy=busy}
  end
  M.robot_orders = robot_orders
  local function freed_text(out)
    return out.robots_freed, out.robots_carrying and string.format(' (%d of them still %s a stack they picked up to storage)', out.robots_carrying, out.robots_carrying == 1 and 'carries' or 'carry') or ''
  end

  -- (d19 batch44 A1) an item's stacks on a surface as the last watch pass binned them, as stores.lua on_ground gives
  -- them (cells in chunks our force sees now); nil before a pass that bins them. {count, stacks, cells, as_of}.
  function M.on_ground_index(force, surface, item)
    local w = (api.state().ground_watch or {})[force.name]
    if not (w and w.items) then return nil end
    local by = (w.items[surface.index] or {})[item] or {}
    local cells, count, stacks = {}, 0, 0
    for k, c in pairs(by) do
      local cx, cy = k:match('^(-?%d+),(-?%d+)$')
      local okv, v = pcall(function() return force.is_chunk_visible(surface, {x=tonumber(cx), y=tonumber(cy)}) end)
      if okv and v == true then
        cells[#cells+1] = {position={x=c.x, y=c.y}, count=c.count, stacks=c.stacks}
        count, stacks = count + c.count, stacks + c.stacks
      end
    end
    table.sort(cells, function(x, y) return x.count > y.count end)
    return {count=count, stacks=stacks, cells=cells, as_of=w.tick}
  end

  -- deconstruct items_on_ground: mark (or cancel) every item stack in the
  -- area, as a deconstruction planner over items on the ground does.
  function M.mark(p, box, cancel, out)
    local list = p.surface.find_entities_filtered{area=box, type='item-entity', limit=MAX_MARK + 1}
    local before = cancel and robot_orders(p.surface, p.force, box)
    local n, already, marked = 0, 0, {}
    local nets, net_seen, outside, cover = 0, {}, 0, {}
    local storages, chests = 0, {}
    for i, e in ipairs(list) do
      if i > MAX_MARK then out.items_truncated = true; break end
      if e.valid then
        if cancel then
          if e.to_be_deconstructed() then e.cancel_deconstruction(p.force, api.real(p)); n = n + 1 end
        elseif e.to_be_deconstructed() then already = already + 1
        elseif e.order_deconstruction(p.force, api.real(p)) then
          n = n + 1
          marked[#marked+1] = e
          -- Robots reach what lies in a roboport's construction area.
          local pos = e.position
          local ck = math.floor(pos.x / 4) .. ',' .. math.floor(pos.y / 4)
          local c = cover[ck]
          if c == nil then
            local okn, found = pcall(function() return p.surface.find_logistic_networks_by_construction_area(pos, p.force) end)
            c = okn and found or {}
            cover[ck] = c
            for _, net in ipairs(c) do
              local id = net.network_id
              if id and not net_seen[id] then
                net_seen[id] = true; nets = nets + 1
                pcall(function() storages = storages + #net.storages; for _, st in ipairs(net.storages) do chests[#chests+1] = st end end)
              end
            end
          end
          if #c == 0 then outside = outside + 1 end
        end
      end
    end
    if cancel then
      out.item_stacks_cancelled = n
      local after = before and robot_orders(p.surface, p.force, box)
      if before then
        local freed, carrying = 0, 0
        for r in pairs(before.on) do
          if not after.on[r] then freed = freed + 1; if after.busy[r] then carrying = carrying + 1 end end
        end
        out.robot_orders_cancelled = math.max(0, before.orders - after.orders)
        out.robots_freed = freed
        out.robots_carrying = carrying > 0 and carrying or nil
        out.robots_still_on_stacks = after.robots > 0 and after.robots or nil
        out.robots_read = before.capped and string.format('the first %d construction robots of %d networks read', MAX_ROBOTS, before.networks) or nil
      end
      out.item_stacks_line = string.format('%d item stack%s on the ground unmarked%s', n, n == 1 and '' or 's',
        before and string.format('; %d robot orders on them cancelled; %d construction robots had orders on them and have none now%s', out.robot_orders_cancelled, freed_text(out)) or '')
    else out.item_stacks = n end
    if not cancel then
      out.item_stacks_already = already > 0 and already or nil
      local sum = M.summary(marked, 12)
      out.items = sum and sum.items or nil
      for _, r in ipairs(out.items or {}) do r.box = nil end
      out.robot_networks = nets
      out.storage_chests = storages
      out.outside_construction_area = outside > 0 and outside or nil
      -- (CD3) labelled apart: the entities marked, the items they hold, the storage slots those fill, and the empty slots
      -- of the storage chests robots may put them in (no filter, or a filter on one of these items; read up to
      -- STORAGE_READ chests; a filtered chest takes only its item, and a part-filled stack of the same item takes more)
      if sum then
        out.items_total, out.storage_slots_needed = sum.count, sum.slots
        local names = {}
        for _, e in ipairs(marked) do local okn, st = pcall(function() return e.stack.name end); if okn and st then names[st] = true end end
        local free, read = 0, 0
        for _, st in ipairs(chests) do
          if read >= M.STORAGE_READ then break end
          read = read + 1
          local okf, flt = pcall(function() return st.storage_filter end)
          local fname = okf and flt and (type(flt) == 'table' and (type(flt.name) == 'table' and flt.name.name or flt.name) or flt) or nil
          if not fname or names[fname] then
            local oki, inv = pcall(function() return st.get_inventory(defines.inventory.chest) end)
            if oki and inv then free = free + (inv.count_empty_stacks(true, false) or 0) end
          end
        end
        out.storage_free_slots = free
        out.counts = string.format('entities %d marked (each an item stack on the ground); items %d; storage slots they fill %s; empty slots in the storage chests that may take them: %d (%d of %d chests read)',
          n, sum.count, sum.slots and tostring(sum.slots) or 'not read', free, read, storages)
      end
    end
    return out
  end
  M.STORAGE_READ = 256

  -- pickup over an area: a timed action that picks up every stack in reach,
  -- then walks to the nearest one left in the area.
  function M.pickup(p, a)
    local box
    if a.area then
      assert(a.position == nil and a.radius == nil, 'give area, or position and radius')
      local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
      assert(rb.x > lt.x and rb.y > lt.y and rb.x - lt.x <= 64 and rb.y - lt.y <= 64, 'area must be nonempty and at most 64x64')
      box = {left_top=lt, right_bottom=rb}
    else
      local c = a.position and api.position(a.position) or p.position
      local r = api.integer(a.radius, 8, 1, 32, 'radius')
      box = {left_top={x=c.x - r, y=c.y - r}, right_bottom={x=c.x + r, y=c.y + r}}
    end
    api.assert_visible(p, {x=(box.left_top.x + box.right_bottom.x) / 2, y=(box.left_top.y + box.right_bottom.y) / 2}, 'pickup area')
    local items
    if a.items ~= nil then
      assert(type(a.items) == 'table' and #a.items >= 1 and #a.items <= 16, 'items requires 1..16 item names')
      items = {}
      for _, name in ipairs(a.items) do assert(type(name) == 'string', 'items requires item names'); items[name] = true end
    end
    local ticks = api.integer(a.ticks, 3600, 1, 36000, 'ticks')
    local list = p.surface.find_entities_filtered{area=box, type='item-entity', limit=SAMPLE}
    local wanted = {}
    for _, e in ipairs(list) do
      if e.valid and e.stack and e.stack.valid_for_read and (not items or items[e.stack.name]) then wanted[#wanted+1] = e end
    end
    assert(#wanted > 0, string.format('no items on the ground%s in (%g,%g)-(%g,%g)', items and ' matching items' or '',
      box.left_top.x, box.left_top.y, box.right_bottom.x, box.right_bottom.y))
    local c = p.character
    local reach = c and c.valid and c.prototype and c.prototype.item_pickup_distance or 1
    local action = {kind='pickup', area=box, items=a.items, reach=reach, until_tick=game.tick + ticks, skips={}, skipped=0}
    api.start(p, action)
    local sum = M.summary(wanted, 8)
    for _, r in ipairs(sum.items) do r.box = nil end
    return {until_tick=action.until_tick, area=box, item_stacks=#list >= SAMPLE and p.surface.count_entities_filtered{area=box, type='item-entity'} or sum.stacks,
      items=sum.items, more_items=sum.more_items, rate='one stack every 6 ticks'}
  end
  local function inside(box, pos)
    return pos.x >= box.left_top.x and pos.x <= box.right_bottom.x and pos.y >= box.left_top.y and pos.y <= box.right_bottom.y
  end
  local function wanted(action, e)
    local s = e.valid and e.stack
    if not (s and s.valid_for_read) then return false end
    if action.items then
      local ok = false
      for _, name in ipairs(action.items) do if name == s.name then ok = true end end
      if not ok then return false end
    end
    return true
  end
  local function pos_key(pos) return string.format('%.2f,%.2f', pos.x, pos.y) end
  -- The nearest stack left in the area: around the character first, then
  -- the whole area.
  local function nearest(p, action)
    local best, bd
    local function consider(list)
      for _, e in ipairs(list) do
        if wanted(action, e) and inside(action.area, e.position) and not action.skips[pos_key(e.position)] then
          local d = api.distance(p.position, e.position)
          if not bd or d < bd then best, bd = e, d end
        end
      end
    end
    consider(p.surface.find_entities_filtered{position=p.position, radius=8, type='item-entity', limit=64})
    if not best then consider(p.surface.find_entities_filtered{area=action.area, type='item-entity', limit=4096}) end
    return best
  end
  function M.left(p, action)
    local n = 0
    for _, e in ipairs(p.surface.find_entities_filtered{area=action.area, type='item-entity', limit=SAMPLE}) do
      if wanted(action, e) then n = n + 1 end
    end
    return n
  end
  function M.tick(p, action, tick)
    -- In reach: pick up, one stack every PICK_EVERY ticks.
    local here
    for _, e in ipairs(p.surface.find_entities_filtered{position=p.position, radius=action.reach or 1, type='item-entity', limit=16}) do
      if wanted(action, e) then here = e; break end
    end
    if here then
      if action.nav then api.stop_walking(p); action.nav = nil end
      action.target = nil
      -- No picking_state: the engine would pick stacks up too, uncounted in
      -- last.picked (live: picked 550 of 1600 plates).
      if tick < (action.next_pick or 0) then return nil end
      action.next_pick = tick + PICK_EVERY
      local s = here.stack
      local name, count = s.name, s.count
      local got = p.insert{name=name, count=count, quality=s.quality and s.quality.name or nil}
      if got == 0 then return 'inventory_full' end
      action.picked = action.picked or {}
      action.picked[name] = (action.picked[name] or 0) + got
      -- Over the personal request max: what the game moves to trash (trash.lua).
      if api.trash then action.trashed = api.trash.count(p, action.trashed, name, s.quality and s.quality.name or nil, got) end
      if got >= count then here.destroy() else s.count = count - got end
      return nil
    end
    -- Arrived at the last target and it is still out of reach: skip it.
    if action.target and not action.nav then
      action.skips[action.target] = true; action.skipped = action.skipped + 1; action.target = nil
      if action.skipped >= MAX_SKIPS then return 'blocked' end
    end
    if not action.nav then
      local e = nearest(p, action)
      -- Nothing left but stacks it walked away from: blocked.
      if not e then return action.skipped > 0 and 'blocked' or 'picked_up' end
      action.target = pos_key(e.position)
      action.nav = {position=e.position, tolerance=math.max(0.3, (action.reach or 1) * 0.7), max_stalls=6, replans=0, stalled=0, last_position=p.position}
      api.request_path(p, action.nav)
    end
    local outcome = api.navigate(p, action.nav)
    if outcome then
      api.stop_walking(p)
      action.nav = nil
      if outcome ~= 'arrived' and outcome ~= 'arrived_near' then
        action.skips[action.target or ''] = true; action.skipped = action.skipped + 1; action.target = nil
        if action.skipped >= MAX_SKIPS then return 'blocked' end
      end
    end
    return nil
  end
  return M
end
