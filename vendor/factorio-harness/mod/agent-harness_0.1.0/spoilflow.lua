-- spoilflow (d20 batch122 CE2, viewer Aurora 10:13: Gleba's nutrients read made above used while the stock fell): what
-- the production statistics leave out for an item that spoils, and how much of it left a surface uncounted, measured
-- between two whole-surface counts. Read on a private 2.0.77 copy of world n (its 10:26 save):
-- - spoiling counts on neither side: 100 nutrients spoiled in a chest read used 0, and spoilage made 0;
-- - fuel counts as used when a burner takes it from its fuel slot (a biochamber's 5 nutrients: used 5);
-- - a productivity bonus's extra products count as made, ingredients only for the crafts run (yumako-processing in a
--   biochamber at +50%: 34 yumako used, 50 crafts finished);
-- - Gleba over 5 game minutes: nutrients made 20,120 and used 17,445, every place held 3,758 then 3,770, so 2,663 (532
--   a minute) spoiled.
-- A whole-surface count (supply without an area) is kept per force, surface and item; the next one 1 to 60 minutes
-- later gives made, used, the stock then and now, and what left uncounted: then + made - used - now.
return function(api)
  local M = {}
  M.MIN_TICKS, M.MAX_TICKS, M.KEEP, M.QUOTE_TICKS = 3600, 216000, 64, 108000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local spoil_ticks = {}
  function M.spoils(item)
    local t = spoil_ticks[item]
    if t == nil then t = try(function() return prototypes.item[item].get_spoil_ticks() end) or 0; spoil_ticks[item] = t end
    return t > 0
  end
  local function book()
    local s = api.state()
    s.spoilflow = s.spoilflow or {}
    return s.spoilflow
  end
  local function key(force, surface, item) return force.name .. '|' .. surface.index .. '|' .. item end
  -- The statistics' running totals (normal quality): made, used.
  function M.totals(force, surface, item)
    local st = try(function() return force.get_item_production_statistics(surface) end)
    if not st then return 0, 0 end
    return try(function() return st.get_input_count(item) end) or 0, try(function() return st.get_output_count(item) end) or 0
  end
  M.NOTE = 'the production statistics leave spoiling out: made counts crafts (a productivity bonus\'s extra among them), used counts ingredients and fuel burned'
  -- A whole-surface count of a spoilable item now (stock: every place counted): kept, and against the one kept 1 to 60
  -- minutes before, what left uncounted. nil for an item that does not spoil; {} with no count to measure against yet.
  function M.sample(force, surface, item, stock)
    if not M.spoils(item) then return nil end
    local made, used = M.totals(force, surface, item)
    local b, k = book(), key(force, surface, item)
    local prev = b[k]
    local dt = prev and game.tick - prev.tick
    local out = {}
    if prev and dt >= M.MIN_TICKS and dt <= M.MAX_TICKS then
      local m, u = made - prev.made, used - prev.used
      local gone = prev.stock + m - u - stock
      local mins = dt / 3600
      out = {minutes=r1(mins), since_tick=prev.tick, made=m, used=u, stock_then=prev.stock, stock_now=stock, uncounted=gone,
        uncounted_per_min=r1(gone / mins), tick=game.tick}
      out.line = string.format('over the last %g min (whole-surface counts at tick %d and now): made %d, used %d; held %d then, %d now; %d left uncounted (%g a minute): spoiled, or carried off the surface',
        out.minutes, prev.tick, m, u, prev.stock, stock, gone, out.uncounted_per_min)
    elseif prev and dt < M.MIN_TICKS then
      out.note = string.format('the whole-surface count kept %ds ago is under a minute old: the next read from %ds on is measured against it', math.floor(dt / 60), math.ceil((M.MIN_TICKS - dt) / 60))
    end
    -- A count under a minute after the kept one leaves it in place, so the next is measured against it.
    if not prev or dt >= M.MIN_TICKS then
      local last = out.line and out or (prev and prev.last)
      if not b[k] then
        local n, oldest, ok = 0, nil, nil
        for kk, r in pairs(b) do n = n + 1; if not oldest or r.tick < oldest then oldest, ok = r.tick, kk end end
        if n >= M.KEEP and ok then b[ok] = nil end
      end
      b[k] = {tick=game.tick, made=made, used=used, stock=stock, last=last}
    end
    return out
  end
  -- The last measure for a surface and item, at most 30 minutes old, for reads that count part of a surface.
  function M.last(force, surface, item)
    local r = book()[key(force, surface, item)]
    local m = r and r.last
    if m and game.tick - m.tick <= M.QUOTE_TICKS then return m end
  end
  -- For a made/used line of a spoilable item: the measure quoted, or the note. nil for an item that does not spoil.
  function M.text(force, surface, item)
    if not M.spoils(item) then return nil end
    local m = M.last(force, surface, item)
    if m then
      return string.format('%s; %g a minute left uncounted (spoiled, or carried off the surface), measured by supply over %g min to %s ago',
        M.NOTE, m.uncounted_per_min, m.minutes, api.secs and api.secs(game.tick - m.tick) or (game.tick - m.tick) .. ' ticks')
    end
    return M.NOTE .. '; supply {item, surface} measures what left uncounted between two of its reads 1 to 60 min apart'
  end
  return M
end
