-- Personal logistics and auto-trash (Astra, 01:53: "warn when a manual
-- collection exceeds personal logistic max and will immediately auto-trash
-- (two cargo hauls lost to that this shift)"). Checked on a private 2.0.77
-- server: with a personal request max of 100 iron plates, taking 400 moved
-- 308 (of the 408 then held) into the character's trash slots within 15
-- ticks, with no logistic network around; the main inventory is what the
-- game holds against the max.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function key(name, quality) return name..'@'..(quality or 'normal') end
  -- The character's requests as the game compiles them (all its active
  -- sections): the max per item and quality, which items are requested, and
  -- whether unrequested items go to trash. nil when personal logistics are
  -- off, not researched or the body has no requester point.
  function M.limits(p)
    local c = try(function() return p.character end)
    local rp = c and c.valid and try(function() return c.get_requester_point() end)
    if not (rp and try(function() return rp.enabled end)) then return nil end
    local out = {max={}, requested={}, unrequested=try(function() return rp.trash_not_requested end) == true}
    for _, f in ipairs(try(function() return rp.filters end) or {}) do
      if f.name then
        local k = key(f.name, type(f.quality) == 'table' and f.quality.name or f.quality)
        out.requested[k] = true
        if f.max_count then out.max[k] = math.min(out.max[k] or math.huge, f.max_count) end
      end
    end
    return out
  end
  -- The most of an item the character holds before the game trashes the rest:
  -- its request max, 0 when it is unrequested and unrequested items go to
  -- trash, else nil (no limit).
  function M.cap(lim, name, quality)
    if not lim then return nil end
    local k = key(name, quality)
    if lim.max[k] then return lim.max[k] end
    if lim.unrequested and not lim.requested[k] then return 0 end
    return nil
  end
  local function held(p, name, quality)
    local inv = try(function() return p.get_main_inventory() end)
    return inv and try(function() return inv.get_item_count{name=name, quality=quality or 'normal'} end) or 0
  end
  -- How many more the character can take before the game trashes some (nil: no limit).
  function M.room(p, name, quality, lim)
    lim = lim or M.limits(p)
    local cap = M.cap(lim, name, quality)
    if not cap then return nil end
    return math.max(0, cap-held(p, name, quality))
  end
  -- After a take: one line per item the game will move to the trash slots.
  -- moved: {{name, quality, count}}.
  function M.lines(p, moved)
    local lim = M.limits(p)
    if not lim then return nil end
    local trash = try(function() return p.character.get_inventory(defines.inventory.character_trash) end)
    local rows = {}
    for _, s in ipairs(moved or {}) do
      if (s.count or 0) > 0 then
        local cap = M.cap(lim, s.name, s.quality)
        local excess = cap and held(p, s.name, s.quality)-cap or 0
        if excess > 0 then
          local free = trash and try(function() return trash.get_insertable_count{name=s.name, quality=s.quality or 'normal'} end) or 0
          local go = math.min(excess, free)
          local label = s.name..(s.quality and s.quality ~= 'normal' and '@'..s.quality or '')
          local why = lim.max[key(s.name, s.quality)] and string.format('your request max is %d', cap)
            or 'it is not requested and your unrequested items go to trash'
          rows[#rows+1] = string.format('%d %s taken; %s: %d go to trash', s.count, label, why, go)
            ..(go < excess and string.format('; %d more stay in your inventory (trash slots full)', excess-go) or '')
        end
      end
    end
    return #rows > 0 and rows or nil
  end
  -- What the trash slots hold: "iron-plate*308 copper-cable*20", or nil.
  function M.held(p)
    local trash = try(function() return p.character.get_inventory(defines.inventory.character_trash) end)
    if not trash or try(function() return trash.is_empty() end) then return nil end
    local parts = {}
    for _, s in ipairs(try(function() return trash.get_contents() end) or {}) do
      parts[#parts+1] = s.name..(s.quality and s.quality ~= 'normal' and '@'..s.quality or '')..'*'..s.count
    end
    return #parts > 0 and table.concat(parts, ' ') or nil
  end
  -- During a timed take (pickup, collect over a radius) the game trashes the
  -- excess within ticks, so each take counts what it put over the cap into
  -- a tally {key = {name, quality, n, cap, unrequested}} kept on the action.
  function M.count(p, tally, name, quality, n)
    local lim = M.limits(p)
    local cap = M.cap(lim, name, quality)
    if not cap or (n or 0) <= 0 then return tally end
    local over = math.min(n, held(p, name, quality)-cap)
    if over <= 0 then return tally end
    tally = tally or {}
    local k = key(name, quality)
    local t = tally[k]
    if not t then t = {name=name, quality=quality, n=0, cap=cap, unrequested=lim.max[k] == nil}; tally[k] = t end
    t.n = t.n + over
    return tally
  end
  -- The tally as lines when the action ends.
  function M.done(tally)
    local rows = {}
    for _, t in pairs(tally or {}) do
      local label = t.name..(t.quality and t.quality ~= 'normal' and '@'..t.quality or '')
      rows[#rows+1] = t.unrequested and string.format('%d %s taken, not requested: the game moves them to your trash slots (unrequested items go to trash)', t.n, label)
        or string.format('%d %s taken over your request max (%d): the game moves them to your trash slots', t.n, label, t.cap)
    end
    table.sort(rows)
    return #rows > 0 and rows or nil
  end
  -- The status line while the trash slots hold items.
  function M.status(p)
    local held_text = M.held(p)
    return held_text and held_text..' in your trash slots: the game moves there what is over your request max (or unrequested, when '
      ..'unrequested items go to trash); logistic robots take them to storage' or nil
  end
  return M
end
