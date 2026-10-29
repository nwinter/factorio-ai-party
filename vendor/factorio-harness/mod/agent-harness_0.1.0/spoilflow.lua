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
-- (d25 batch201 QN3, Sol #2328: Nauvis agricultural science held 2801 then 2934, made 0, used 572: -705 read "spoiled,
-- or carried off the surface") the residual is signed and each sign says what it can be; cargo pods counted by the
-- pod log over the same interval (landed, sent up in rockets) are set beside and taken out of it. Spoiling has no count
-- in the game's statistics (on neither side), so no residual is named spoiling.
-- (d28 batch325 IC, Astra #2717: Nauvis agricultural science, the census at its caps, 10000 of 19304 belts and 4096 of
-- 7523 robots read, gave residual +208 read "spoiling ... or what left uncounted") a count whose census stopped at a
-- cap, then or now, misses what the holders it left out hold: such a measure has no residual and no uncounted, only
-- "indeterminate (N of M holders counted)", and names no cause. cover: {complete, counted, of, text} from supply
-- (supply.lua M.coverage); none: complete (callers before it).
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
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
  -- The statistics' running totals over every quality (d24 batch152 PX1; normal quality only before): made, used.
  function M.totals(force, surface, item)
    local st = try(function() return force.get_item_production_statistics(surface) end)
    if not st then return 0, 0 end
    return try(function() return qflow.count(st, item, 'input') end) or 0, try(function() return qflow.count(st, item, 'output') end) or 0
  end
  -- What a residual's sign can be (then + made + landed - used - sent up - now).
  function M.means(res)
    if res > 0 then return 'more left the stock than these count: spoiling (no count of it in the game\'s statistics), or what left the surface uncounted (characters, vehicles, pods the log missed)' end
    if res < 0 then return 'more came into the stock than these count: what arrived uncounted (cargo pods the log missed, what characters or vehicles brought, items put in by script)' end
    return 'the counts account for every change'
  end
  M.NOTE = 'the production statistics leave spoiling out: made counts crafts (a productivity bonus\'s extra among them), used counts ingredients and fuel burned'
  -- A whole-surface count of a spoilable item now (stock: every place counted): kept, and against the one kept 1 to 60
  -- minutes before, what left uncounted. nil for an item that does not spoil; {} with no count to measure against yet.
  local function cover_text(c) return c and c.complete == false and (c.text or (c.counted .. ' of ' .. c.of .. ' holders counted')) or nil end
  M.cover_text = cover_text
  function M.sample(force, surface, item, stock, cover)
    if not M.spoils(item) then return nil end
    local made, used = M.totals(force, surface, item)
    local b, k = book(), key(force, surface, item)
    local prev = b[k]
    if prev and not prev.q then b[k], prev = nil, nil end   -- (PX1) a count kept before every quality was summed
    local dt = prev and game.tick - prev.tick
    local out = {}
    local short_now = cover_text(cover)
    if prev and dt >= M.MIN_TICKS and dt <= M.MAX_TICKS and (short_now or prev.short) then
      local m, u = made - prev.made, used - prev.used
      local mins = dt / 3600
      local which = short_now and prev.short and string.format('then %s; now %s', prev.short, short_now)
        or short_now and ('now ' .. short_now) or ('then ' .. prev.short)
      out = {minutes=r1(mins), since_tick=prev.tick, made=m, used=u, stock_then=prev.stock, stock_now=stock, tick=game.tick,
        indeterminate=string.format('indeterminate (%s)', which)}
      out.line = string.format('over the last %g min (whole-surface counts at tick %d and now): made %d, used %d; held %s%d then, %s%d now; residual indeterminate (%s): the census stopped at its caps, so the held counts leave out what the holders it did not read hold; supply {item, count_all: true} counts every belt and robot of it',
        out.minutes, prev.tick, m, u, prev.short and 'at least ' or '', prev.stock, short_now and 'at least ' or '', stock, which)
    elseif prev and dt >= M.MIN_TICKS and dt <= M.MAX_TICKS then
      local m, u = made - prev.made, used - prev.used
      local gone = prev.stock + m - u - stock
      local mins = dt / 3600
      out = {minutes=r1(mins), since_tick=prev.tick, made=m, used=u, stock_then=prev.stock, stock_now=stock, uncounted=gone,
        uncounted_per_min=r1(gone / mins), tick=game.tick}
      local pods = api.pods and try(function() return api.pods(surface.name, item, prev.tick, game.tick) end)
      local res = gone
      local pod_text = 'cargo pods: no pod log here'
      if pods then
        res = gone + pods.landed - pods.sent_up
        out.landed, out.landed_pods, out.sent_up, out.sent_pods = pods.landed, pods.landed_pods, pods.sent_up, pods.sent_pods
        out.pods_complete = pods.complete or nil
        pod_text = string.format('cargo pods (the pod log): %d landed in %d pod%s, %d sent up in %d rocket%s%s', pods.landed, pods.landed_pods,
          pods.landed_pods == 1 and '' or 's', pods.sent_up, pods.sent_pods, pods.sent_pods == 1 and '' or 's',
          pods.complete and '' or ' (the log\'s oldest kept journey is after the interval began: some may be missing)')
      end
      out.residual, out.residual_per_min = res, r1(res / mins)
      out.residual_means = M.means(res)
      out.line = string.format('over the last %g min (whole-surface counts at tick %d and now): made %d, used %d; held %d then, %d now; %s; residual %+d (%+g a minute; held then + made + landed - used - sent up - held now): %s',
        out.minutes, prev.tick, m, u, prev.stock, stock, pod_text, res, out.residual_per_min, out.residual_means)
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
      b[k] = {tick=game.tick, made=made, used=used, stock=stock, last=last, q=true, short=short_now}
    end
    return out
  end
  -- The last measure for a surface and item, at most 30 minutes old, for reads that count part of a surface; an
  -- indeterminate one only with any (its rates are not measured: dependency.lua reads none).
  function M.last(force, surface, item, any)
    local r = book()[key(force, surface, item)]
    local m = r and r.last
    if m and game.tick - m.tick <= M.QUOTE_TICKS and (any or not m.indeterminate) then return m end
  end
  -- For a made/used line of a spoilable item: the measure quoted, or the note. nil for an item that does not spoil.
  function M.text(force, surface, item)
    if not M.spoils(item) then return nil end
    local m = M.last(force, surface, item, true)
    if m and m.indeterminate then
      return string.format('%s; residual %s, measured by supply over %g min to %s ago', M.NOTE, m.indeterminate, m.minutes,
        api.secs and api.secs(game.tick - m.tick) or (game.tick - m.tick) .. ' ticks')
    end
    if m then
      local res = m.residual_per_min or m.uncounted_per_min
      return string.format('%s; residual %+g a minute (%s), measured by supply over %g min to %s ago',
        M.NOTE, res, M.means(res), m.minutes, api.secs and api.secs(game.tick - m.tick) or (game.tick - m.tick) .. ' ticks')
    end
    return M.NOTE .. '; supply {item, surface} measures the residual between two of its reads 1 to 60 min apart'
  end
  return M
end
