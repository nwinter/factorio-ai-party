-- Where a drop landed (space.lua drop). Astra, shift06 14:55: a drop from
-- Sunward to Vulcanus near (14,134) "succeeded" and Sol found nothing within
-- 16 tiles after 90 s; the operator found it in a cargo-pod-container at
-- (0,129), and a second drop's barrels at (5,131). Pods scatter and land after
-- the tool returns, so each drop's pod is followed (its surface and position
-- every 15 ticks while it exists); when it is gone, the container it became
-- is found near where it was last seen (or the landing pad took it). The
-- sender and the teammates named in `to` hear it in their next reply's team
-- block, once while it is still descending and once when it has landed; the
-- `drops` read lists recent drops and their containers. Read only, as a
-- player sees pods come down and containers on the ground.
-- Kept in storage so every peer computes the same lines.
return function(api)
  local M = {}
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.MAX_TO = 8
  local KEEP, SAMPLE, SEARCH, GIVE_UP, QUIET = 20, 15, 24, 600, 300
  local MAX_LINES = 4  -- a reply's team block shows this many drop lines (board.lua)
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.drops = s.drops or {seq=0, list={}}
    return s.drops
  end
  local function xy(pos) return {x=math.floor(pos.x * 10 + 0.5) / 10, y=math.floor(pos.y * 10 + 0.5) / 10} end
  -- Exact, as the entity stands (Sonnet, shift14 22:50: "landed at (12,153)" sent a transfer to (12.5,153.5); the
  -- container was at (11.5,152.5), another at (13.5,153.5)).
  local function at_text(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local NEARBY, MAX_NEARBY = 8, 4
  local function items(r) return table.concat(r.sent or {}, ' ') end
  local pad_counts
  local function ago(ticks)
    local sec = math.floor(ticks / 60)
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  local function contents(e)
    local inv = try(function() return e.get_inventory(defines.inventory.chest) end) or try(function() return e.get_inventory(1) end)
    if not inv then return nil end
    local out = {}
    for _, s in ipairs(try(function() return inv.get_contents() end) or {}) do
      out[#out+1] = s.name .. (s.quality and s.quality ~= 'normal' and '@' .. s.quality or '') .. '*' .. s.count
    end
    return out
  end

  -- (d17 batch34 A2, Astra, Luna: Petrel's drop 1376 of 3 underground belts and a chest landed on Gleba's pad and
  -- construction robots spent them on 20+ unrelated ghosts within seconds; four reads found nothing) A drop into a
  -- landing pad: what of the sent items the pad held before, when it landed, and for WATCH ticks after, each sample
  -- where the pad's count fell, the robots of ours within ROBOT_R tiles of the pad holding that item (each counted once)
  -- and the ghost or entity each one's first order is on. The game reserves nothing for the sender: the pad's items are
  -- the network's, as a player sees them leave in its GUI.
  local WATCH, ROBOT_R = 1200, 8
  local function label(w) return w.name .. (w.quality and w.quality ~= 'normal' and '@' .. w.quality or '') end
  pad_counts = function(r)
    local out = {}
    for _, w in ipairs(r.items or {}) do
      out[label(w)] = try(function() return r.pad_e.get_item_count({name=w.name, quality=w.quality or 'normal'}) end) or 0
    end
    return out
  end
  local function robots_with(r, w, seen)
    local pad = r.pad_e
    local got = {construction=0, logistic=0, targets={}}
    local list = try(function() return pad.surface.find_entities_filtered{type={'construction-robot', 'logistic-robot'}, position=pad.position, radius=ROBOT_R, force=pad.force} end) or {}
    for _, b in ipairs(list) do
      local u = b.valid and b.unit_number
      if u and not seen[u] then
        local inv = try(function() return b.get_inventory(defines.inventory.robot_cargo) end)
        local n = inv and try(function() return inv.get_item_count({name=w.name, quality=w.quality or 'normal'}) end) or 0
        if n > 0 then
          seen[u] = true
          local kind = b.type == 'construction-robot' and 'construction' or 'logistic'
          got[kind] = got[kind] + n
          local o = (try(function() return b.robot_order_queue end) or {})[1]
          local t = o and o.target and try(function() return o.target.valid and o.target end)
          if t and #got.targets < 8 then
            got.targets[#got.targets+1] = string.format('%s %s', t.type == 'entity-ghost' and t.ghost_name .. ' ghost' or t.name, at_text(t.position))
          end
        end
      end
    end
    return got
  end
  local function watch_step(r, tick)
    local now = pad_counts(r)
    local w = r.watch
    for _, it in ipairs(r.items) do
      local k = label(it)
      local fell = (w.last[k] or 0) - (now[k] or 0)
      if fell > 0 then
        local got = robots_with(r, it, w.seen)
        local t = w.took[k] or {construction=0, logistic=0, other=0, targets={}}
        w.took[k] = t
        local c = math.min(fell, got.construction)
        local l = math.min(fell - c, got.logistic)
        t.construction, t.logistic, t.other = t.construction + c, t.logistic + l, t.other + fell - c - l
        for _, x in ipairs(got.targets) do if #t.targets < 8 then t.targets[#t.targets+1] = x end end
      end
    end
    w.last = now
    if tick >= w.until_tick then r.watch_done, r.pad_after = true, now end
  end
  -- The pad's story for one drop: "the pad held underground-belt 0 before it and 3 when it landed; in the 20 s after,
  -- construction robots took underground-belt*3 (for underground-belt ghost (54.5,8.5), ...); it holds 0 now".
  function M.pad_text(r)
    if not r.watch then return nil end
    local held, landed, took, after = {}, {}, {}, {}
    for _, it in ipairs(r.items) do
      local k = label(it)
      held[#held+1] = string.format('%s %d', k, (r.pad_before or {})[k] or 0)
      landed[#landed+1] = string.format('%s %d', k, r.watch.landed[k] or 0)
      local t = r.watch.took[k]
      if t then
        local by = {}
        if t.construction > 0 then by[#by+1] = string.format('construction robots took %d', t.construction) end
        if t.logistic > 0 then by[#by+1] = string.format('logistic robots took %d', t.logistic) end
        if t.other > 0 then by[#by+1] = string.format('%d left with no robot of ours seen holding it within %d tiles (an inserter, a player, or a robot already off)', t.other, ROBOT_R) end
        took[#took+1] = string.format('%s: %s%s', k, table.concat(by, ', '), #t.targets > 0 and ' (first orders: ' .. table.concat(t.targets, '; ') .. ')' or '')
      end
      if r.pad_after then after[#after+1] = string.format('%s %d', k, r.pad_after[k] or 0) end
    end
    return string.format('the pad held %s before it and %s when it landed; %s%s', table.concat(held, ', '), table.concat(landed, ', '),
      #took > 0 and string.format('in the %d s after: %s', math.floor(WATCH / 60), table.concat(took, '; ')) or string.format('none of it left the pad in the %d s after', math.floor(WATCH / 60)),
      #after > 0 and '; it held ' .. table.concat(after, ', ') .. ' then' or ' (still watched)')
  end
  -- What the drop's pad shows in one phrase: landed, then taken by construction robots (all of what was sent).
  function M.pad_verdict(r)
    if not (r.watch and r.watch_done) then return nil end
    local sent, cons, gone = 0, 0, 0
    for _, it in ipairs(r.items) do
      local t = r.watch.took[label(it)]
      sent = sent + it.count
      if t then cons = cons + t.construction; gone = gone + t.construction + t.logistic + t.other end
    end
    if cons > 0 and cons >= sent then return 'landed, then taken by construction robots' end
    if cons > 0 then return string.format('landed, then %d of %d taken by construction robots', cons, sent) end
    if gone > 0 then return string.format('landed, then %d of %d left the pad', gone, sent) end
  end
  -- (d17 batch34 A2) recent drops into a pad that held the item, for where_is and shipment: {line, verdict} newest first
  function M.taken(filter)
    local out = {}
    local s = api.state().drops
    for i = #(s and s.list or {}), 1, -1 do
      local r = s.list[i]
      local hit = r.watch ~= nil and (not filter.surface or r.surface == filter.surface) and (not filter.platform or r.platform == filter.platform)
      if hit and filter.item then
        hit = false
        for _, it in ipairs(r.items) do if it.name == filter.item then hit = true end end
      end
      if hit and #out < (filter.limit or 4) then
        out[#out+1] = {id=r.id, verdict=M.pad_verdict(r), line=string.format('drop #%d from %s (%s ago) into the landing pad at %s on %s: %s; %s', r.id, r.platform,
          ago(game.tick - r.tick), at_text(r.pad), r.surface, items(r), M.pad_text(r))}
      end
    end
    return out
  end

  -- `to`: a teammate's name or a list of them, told as the sender is.
  function M.recipients(to)
    if to == nil then return {} end
    local list = type(to) == 'table' and to or {to}
    assert(#list <= M.MAX_TO, 'to is at most ' .. M.MAX_TO .. ' teammates')
    local out = {}
    for _, name in ipairs(list) do out[#out+1] = api.resolve(name) end
    return out
  end
  -- A new drop from space.lua: {pod, platform, surface, pad, near, sent, to}.
  function M.record(p, d)
    local s = store()
    s.seq = s.seq + 1
    local r = {id=s.seq, by=api.who(p), force=p.force and p.force.name, to=d.to or {}, platform=d.platform, surface=d.surface, pad=d.pad and xy(d.pad) or nil,
      near=d.near and xy(d.near) or nil, sent=d.sent, tick=game.tick, pod=d.pod, hub=d.hub, state='descending'}
    -- (d17 batch34 A2) the pad it is sent to, and what of the sent items the pad holds before it lands
    if d.pad_e and try(function() return d.pad_e.valid end) and d.items then
      r.pad_e, r.items = d.pad_e, {}
      for i, w in ipairs(d.items) do r.items[i] = {name=w.name, quality=w.quality, count=w.count} end
      r.pad_before = pad_counts(r)
      -- (d18 batch36 D3) what the pad asked for the sent items then: "low-density-structure 200 (held 40)"
      local asks, want = {}, {}
      for _, w in ipairs(r.items) do want[w.name] = true end
      local secs = try(function() return d.pad_e.get_logistic_sections() end)
      for i = 1, secs and secs.sections_count or 0 do
        local sec = try(function() return secs.get_section(i) end)
        for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
          local v = f.value
          local n = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
          if n and want[n] then asks[#asks+1] = string.format('%s %d (held %d)', n, f.min or 0, (r.pad_before or {})[n] or 0) end
        end
      end
      r.pad_asks = #asks > 0 and table.concat(asks, ', ') or 'none of these items'
    end
    s.list[#s.list+1] = r
    while #s.list > KEEP do table.remove(s.list, 1) end
    -- (d24 batch179 QV1) the pod's journey in the pod ledger (podlog.lua) is this drop
    if api.podlog and d.pod then pcall(api.podlog, d.pod, {kind='drop', by=r.by, drop=r.id}) end
    return r.id
  end

  -- (d18 batch36 D3) the kept drops for the cargo ledger (ledger.lua): each with where it landed, the pad's story and
  -- verdict, and what the pad asked then
  function M.ledger_rows()
    local out = {}
    for _, r in ipairs((api.state().drops or {list={}}).list) do
      out[#out+1] = {id=r.id, tick=r.tick, platform=r.platform, surface=r.surface, sent=r.sent, state=r.state, at=r.at, landed_in=r.into,
        pad_text=M.pad_text(r), verdict=M.pad_verdict(r), pad_asks=r.pad_asks}
    end
    return out
  end
  -- (d17 batch33 A4) a drop by id, and a platform's latest drop (its id), for pod_landed {drop_id | last_drop}
  function M.find(id)
    for _, r in ipairs(store().list) do if r.id == id then return r end end
    return nil
  end
  function M.last_of(platform)
    local best
    for _, r in ipairs(store().list) do if r.platform == platform and (not best or r.id > best.id) then best = r end end
    return best and best.id or nil
  end
  -- Where it came down: the landing pad, else the nearest cargo pod container
  -- to the pod's last sighting on the destination surface (not one another
  -- drop already took).
  local function claimed(s, unit)
    for _, r in ipairs(s.list) do if r.container_unit == unit then return true end end
    return false
  end
  -- (d18 batch38 B3, Luna) the sent items that more ghosts of ours in the landing spot's network want than it holds:
  -- each such ghost, with its claim and distance (ghostlist.contested), once when it lands
  local function contest(r, surface)
    if not (api.contested and surface and r.at) then return end
    local force = r.force and game.forces[r.force]
    if not force then return end
    local out, seen = {}, {}
    for _, t in ipairs(r.sent or {}) do
      local name = t:match('^([^@*]+)')
      if name and not seen[name] and #out < 2 then
        seen[name] = true
        local c = try(function() return api.contested(surface, force, name, r.at) end)
        if c then out[#out+1] = c.line end
      end
    end
    r.contested = #out > 0 and out or nil
  end
  -- (d20 batch52 K3, Sol #1323: drop 1809's 725 foundation read "landed" while Aquilo's pad held none before, at or
  -- 20 s after: Kestrel IV's hub had died during the drop.) 2.0.77 on the private copy: a cargo pod still on its platform's surface (waiting to launch, rising, or passing to the planet: its first 400 ticks or so) is removed with the platform when its hub is destroyed, and what it carried is gone; one already coming down over the planet lands as usual. A pod gone after its hub, last seen still on
  -- the platform's surface: lost (unless the pad it was sent to holds more of what was sent than before it).
  local function hub_gone(r)
    if r.hub_gone then return r.hub_gone end
    if r.hub ~= nil and not try(function() return r.hub.valid end) then r.hub_gone = game.tick; return r.hub_gone end
  end
  local function pad_gained(r)
    if not (r.pad_e and try(function() return r.pad_e.valid end) and r.items and r.pad_before) then return false end
    for k, n in pairs(pad_counts(r)) do if n > (r.pad_before[k] or 0) then return true end end
    return false
  end
  local function on_platform(r) return not (r.last and r.last.surface == r.surface) end
  local function mark_lost(r)
    r.state, r.hub = 'lost', nil
    r.note = string.format('its platform %s\'s hub was destroyed (seen at tick %d, %s after the drop) before the pod left the platform\'s surface: it delivered nothing (%s)',
      tostring(r.platform), r.hub_gone, ago(r.hub_gone - r.tick), '2.0.77 on the private copy: a cargo pod still on its platform\'s surface (waiting to launch, rising, or passing to the planet: its first 400 ticks or so) is removed with the platform when its hub is destroyed, and what it carried is gone; one already coming down over the planet lands as usual')
  end
  local function settle(s, r)
    local surface = game.surfaces[r.surface]
    -- (backlog #812, Aquilo drop 786: read "landed in the landing pad" while the pad was full and its cargo lay round it)
    -- sent to a pad: landed in it unless a cargo pod container near the pad holds what was sent (the pad was full)
    if r.pad then
      local spilled
      for _, e in pairs(surface and surface.find_entities_filtered{name='cargo-pod-container', position=r.pad, radius=SEARCH} or {}) do
        if e.valid and not claimed(s, e.unit_number) then
          for _, t in ipairs(contents(e) or {}) do
            for _, w in ipairs(r.sent or {}) do if t:match('^([^@*]+)') == w:match('^([^@*]+)') then spilled = true end end
          end
        end
      end
      if not spilled and hub_gone(r) and on_platform(r) and not pad_gained(r) then mark_lost(r); return end
      if not spilled then
        r.state, r.at, r.into = 'landed', r.pad, 'cargo-landing-pad'
        if r.pad_e and try(function() return r.pad_e.valid end) then
          local now = pad_counts(r)
          r.watch = {landed=now, last=now, took={}, seen={}, until_tick=game.tick + WATCH}
        end
        contest(r, surface)
        return
      end
      r.pad_full = r.pad
    end
    local seen = r.last and r.last.surface == r.surface and r.last.position or r.near or r.pad
    -- One holding what was sent comes first (another drop's container may lie nearer).
    local want = {}
    for _, t in ipairs(r.sent or {}) do want[t:match('^([^@*]+)')] = true end
    local best, score = nil, -math.huge
    if surface and seen then
      for _, e in pairs(surface.find_entities_filtered{name='cargo-pod-container', position=seen, radius=SEARCH}) do
        if e.valid and not claimed(s, e.unit_number) then
          local held = false
          for _, t in ipairs(contents(e) or {}) do if want[t:match('^([^@*]+)')] then held = true end end
          local sc = (held and 1e6 or 0) - ((e.position.x - seen.x) ^ 2 + (e.position.y - seen.y) ^ 2)
          if sc > score then best, score = e, sc end
        end
      end
    end
    if best then
      r.state, r.at, r.into, r.container, r.container_unit = 'landed', xy(best.position), best.name, best, best.unit_number
      r.landed_with = contents(best)
      contest(r, surface)
      -- The other cargo pod containers near it, each where it stands and what it holds (pods scatter: two a tile apart).
      local near = {}
      for _, e in pairs(surface.find_entities_filtered{name='cargo-pod-container', position=best.position, radius=NEARBY}) do
        if e.valid and e ~= best then near[#near+1] = e end
      end
      table.sort(near, function(x, y)
        return (x.position.x - best.position.x) ^ 2 + (x.position.y - best.position.y) ^ 2 < (y.position.x - best.position.x) ^ 2 + (y.position.y - best.position.y) ^ 2
      end)
      r.nearby = {}
      for i = 1, math.min(MAX_NEARBY, #near) do
        r.nearby[i] = {position=xy(near[i].position), holds=contents(near[i])}
      end
      if #near > MAX_NEARBY then r.nearby_more = #near - MAX_NEARBY end
      if #r.nearby == 0 then r.nearby = nil end
    elseif hub_gone(r) and on_platform(r) then mark_lost(r)
    elseif game.tick - (r.gone or game.tick) >= GIVE_UP then
      r.state, r.at = 'landed', seen and xy(seen) or nil
      r.note = string.format('no cargo pod container within %d tiles of %s (emptied already, or it landed farther off)', SEARCH,
        seen and at_text(seen) or 'its landing spot')
    end
  end
  function M.tick(tick)
    local s = api.state().drops
    if not s or tick % SAMPLE ~= 0 then return end
    for _, r in ipairs(s.list) do
      if r.watch and not r.watch_done then
        if try(function() return r.pad_e.valid end) then watch_step(r, tick) else r.watch_done = true end
      end
      if r.state == 'descending' then
        local pod = r.pod
        if pod and try(function() return pod.valid end) then
          local where = try(function() return {surface=pod.surface.name, position=xy(pod.position)} end)
          if where then r.last = where end
          hub_gone(r)
        else
          r.pod = nil
          r.gone = r.gone or tick
          settle(s, r)
        end
      end
    end
  end

  local function landed_line(r)
    if r.into == 'cargo-landing-pad' then
      local pad = M.pad_text(r)
      return string.format('drop #%d from %s landed in the landing pad at %s on %s: %s%s%s', r.id, r.platform, at_text(r.at), r.surface, items(r),
        pad and '; ' .. pad or '', r.contested and '; ' .. table.concat(r.contested, '; ') or '')
    end
    if r.note then return string.format('drop #%d from %s to %s: %s; it held %s', r.id, r.platform, r.surface, r.note, items(r)) end
    local held = r.landed_with and #r.landed_with > 0 and table.concat(r.landed_with, ' ') or items(r)
    local others = {}
    for _, n in ipairs(r.nearby or {}) do
      others[#others+1] = string.format('%s holds %s', at_text(n.position), n.holds and #n.holds > 0 and table.concat(n.holds, ' ') or 'nothing')
    end
    return string.format('drop #%d %s at %s on %s: %s with %s (take them with transfer; it vanishes when empty)%s',
      r.id, r.pad_full and string.format('was sent to the landing pad at %s, which took none of it (full): it landed beside it', at_text(r.pad_full)) or 'landed',
      at_text(r.at), r.surface, r.into, held,
      #others > 0 and string.format('; other cargo pod containers within %d tiles: %s%s', NEARBY, table.concat(others, '; '),
        r.nearby_more and string.format(' (+%d more)', r.nearby_more) or '') or '') .. (r.contested and '; ' .. table.concat(r.contested, '; ') or '')
  end
  -- Team block lines for the sender and the teammates named in `to`.
  function M.lines(p, h)
    local s = api.state().drops
    if not s then return {} end
    local me = api.who(p)
    local told = h.drops or {}
    local keep, lines = {}, {}
    for _, r in ipairs(s.list) do
      local mine = r.by == me
      for _, n in ipairs(r.to) do if n == me then mine = true end end
      if mine then
        keep[r.id] = told[r.id]
        if #lines >= MAX_LINES then
          -- the rest come in the next replies, untold until shown
        elseif r.state == 'landed' and told[r.id] ~= 'landed' and not (r.watch and not r.watch_done) then
          lines[#lines+1] = landed_line(r); keep[r.id] = 'landed'
        elseif r.state == 'lost' and told[r.id] ~= 'lost' then
          lines[#lines+1] = string.format('drop #%d from %s to %s: lost: %s; it held %s', r.id, tostring(r.platform), r.surface, r.note, items(r)); keep[r.id] = 'lost'
        elseif r.state == 'descending' and not told[r.id] and (r.by ~= me or game.tick - r.tick >= QUIET) then
          lines[#lines+1] = string.format('drop #%d from %s to %s: still descending (%s ago, aimed near %s); pods scatter: the team block says where it lands (drops reads them all)',
            r.id, r.platform, r.surface, ago(game.tick - r.tick), r.pad and at_text(r.pad) or r.near and at_text(r.near) or '?')
          keep[r.id] = 'descending'
        end
      end
    end
    h.drops = next(keep) and keep or nil
    return lines
  end

  -- The `drops` read: recent drops, newest first, with their containers now.
  function M.read(p, a)
    local s = api.state().drops or {list={}}
    local limit = a.limit ~= nil and api.integer(a.limit, 10, 1, KEEP, 'limit') or 10
    local rows = {}
    for i = #s.list, 1, -1 do
      if #rows >= limit then break end
      local r = s.list[i]
      local row = {id=r.id, by=r.by, to=#r.to > 0 and r.to or nil, platform=r.platform, surface=r.surface, items=r.sent,
        ago=ago(game.tick - r.tick), state=r.state, aimed_near=r.pad or r.near, at=r.at, landed_in=r.into, note=r.note,
        nearby=r.nearby, nearby_more=r.nearby_more, pad=M.pad_text(r), pad_verdict=M.pad_verdict(r)}
      if r.watch and r.watch_done and try(function() return r.pad_e.valid end) then
        local now, parts = pad_counts(r), {}
        for _, it in ipairs(r.items) do parts[#parts+1] = string.format('%s %d', label(it), now[label(it)] or 0) end
        row.pad_now = 'the pad holds ' .. table.concat(parts, ', ') .. ' now'
      end
      if r.container then
        if try(function() return r.container.valid end) then
          row.container = {name=r.container.name, position=xy(r.container.position), holds=contents(r.container)}
        else
          row.container = {gone='emptied or removed (a cargo pod container vanishes when empty)'}
        end
      end
      rows[#rows+1] = row
    end
    return {drops=rows, note=#rows == 0 and 'no drops yet' or nil}
  end
  M.schema = {
    drops = {limit='1..20 (default 10)', returns='drops newest first: {id, by, to, platform, surface, items, ago, state (descending|landed|lost: its platform\'s hub was destroyed before the pod left the platform\'s surface, which removes the pod and its cargo in 2.0.77; note says when), aimed_near, at, landed_in (cargo-pod-container or cargo-landing-pad), container {name, position, holds} or {gone}, pad (a drop into a landing pad: what of the sent items the pad held before it and when it landed, and in the 20 s after, how many construction robots and logistic robots of ours within 8 tiles took, with the first orders they flew to (ghosts or entities), and what left with no robot seen; what it held then), pad_verdict (landed, then taken by construction robots | landed, then N of M taken by construction robots | landed, then N of M left the pad), pad_now (the sent items in the pad now), nearby [{position, holds}] (other cargo pod containers within 8 tiles when it landed, nearest first, at most 4; nearby_more), note}. Positions as the entities stand (x.5 for a container). A drop into a landing pad comes to the team block 20 s after it lands, with the pad\'s line. The game reserves nothing for the sender: robots may take what lands in a pad. Read only'},
  }
  return M
end
