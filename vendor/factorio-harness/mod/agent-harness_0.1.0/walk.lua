-- Whole-surface reads in bands (operator 04:00: in the 03:58 profile the
-- background jobs burst, pushalerts.tick 138 ms and networks.tick 122 ms in
-- single game seconds, survey.tick 50-57 ms in several: each step found one
-- type over a whole surface, and a whole-surface find sweeps every chunk).
-- A walk covers a surface's box of chunks one band a step: a band is rows by
-- columns of chunks, sized from what the last band found so a band finds
-- about TARGET entities (time can't be read in game, so entities stand for
-- it). An entity is kept by the band its position falls in (a find by area
-- also returns entities that only overlap it), so none is read twice.
-- The box is where the force built (grown by every walk from what it found,
-- kept in storage) and every player on the surface, each grown by MARGIN
-- chunks: new buildings go up near a player or near other buildings (a
-- roboport's construction area is under 2 chunks). With no box yet, a walk
-- covers the generated chunks the threat chart saw (threat.lua), else it is
-- one whole-surface find, once per surface.
-- A band covers at most MAX_CHUNKS chunks (operator 18:12: at 17:53 survey.tick took 66 ms in one game second; on
-- world n a find of the survey's types over one 34-chunk row of the base found 1346 in 6.7 ms with their positions
-- read, and a band grown to 8 such rows over a sparse edge would find them all in one step).
-- pace: one step every N ticks, N from the steps the last pass took, so a
-- pass spreads over SPREAD of its period instead of its first seconds.
return function(api)
  local W = {}
  local TARGET, MARGIN, ROWS_MAX, SPREAD, FIRST_EVERY, MAX_EVERY, MAX_CHUNKS = 250, 4, 8, 0.8, 4, 600, 32
  local function boxes()
    local s = api.state()
    s.walk_box = s.walk_box or {}
    return s.walk_box
  end
  local function grow(b, x, y)
    if b.left == nil then b.left, b.right, b.top, b.bottom = x, x, y, y; return end
    if x < b.left then b.left = x elseif x > b.right then b.right = x end
    if y < b.top then b.top = y elseif y > b.bottom then b.bottom = y end
  end
  local function chunk(v) return math.floor(v / 32) end
  -- The generated chunks the threat chart saw on this surface, any force.
  local function generated(index)
    local box
    for key, e in pairs(api.state().threat_shared or {}) do
      local g = e.chart and e.chart.gen
      if g and g.left and tostring(key):match('/(%d+)$') == tostring(index) then
        box = box or {}
        grow(box, g.left, g.top); grow(box, g.right, g.bottom)
      end
    end
    return box
  end

  -- A new walk of surface s: {surface, box, x, y, rows, cols} (chunks), or
  -- {surface, whole=true} when nothing tells where to look.
  -- extra: more positions on the surface the box reaches (MARGIN chunks around each), as the players' (census.lua: bot
  -- characters, which are no players).
  -- opts.max_chunks: at most this many chunks a band (MAX_CHUNKS by default; the census takes 1, d21 batch73).
  function W.start(s, extra, opts)
    local built = boxes()[s.index]
    local box = {}
    if built and built.left then
      grow(box, built.left - MARGIN, built.top - MARGIN); grow(box, built.right + MARGIN, built.bottom + MARGIN)
    else
      local g = generated(s.index)
      if g then grow(box, g.left, g.top); grow(box, g.right, g.bottom) end
    end
    if box.left then
      for _, pl in pairs(game.players or {}) do
        local ok, here = pcall(function() return pl.surface.index == s.index and pl.position end)
        if ok and here then
          grow(box, chunk(here.x) - MARGIN, chunk(here.y) - MARGIN); grow(box, chunk(here.x) + MARGIN, chunk(here.y) + MARGIN)
        end
      end
      for _, here in ipairs(extra or {}) do
        grow(box, chunk(here.x) - MARGIN, chunk(here.y) - MARGIN); grow(box, chunk(here.x) + MARGIN, chunk(here.y) + MARGIN)
      end
    end
    if not box.left then return {surface=s.index, whole=true} end
    local max = opts and opts.max_chunks or MAX_CHUNKS
    return {surface=s.index, box=box, x=box.left, y=box.top, rows=1, band_rows=1, cols=math.min(max, box.right - box.left + 1),
      max=max ~= MAX_CHUNKS and max or nil}
  end

  -- (d22 batch110 BT1: census.walk made 15.4 KB of garbage a call on the private copy) a band's find filter and area,
  -- one pair for every band (the find keeps neither): the caller's fields copied in, a field it no longer gives cleared
  local F, AREA = {}, {{0, 0}, {0, 0}}
  local function filter_of(filter)
    for k in pairs(F) do if filter[k] == nil then F[k] = nil end end
    for k, v in pairs(filter) do F[k] = v end
    return F
  end
  -- The next band's entities (a table, maybe empty), or nil when the walk is
  -- done. filter: find_entities_filtered's filter without area or position.
  -- out_pos (optional): a table this fills with each entity's position as the band read it (out_pos[i] for list[i],
  -- i = 1..#list; nothing past that is cleared), returned second, so a caller reads no position again.
  -- The list is the find's own table with the entities outside the band taken out, in the find's order.
  function W.band(w, s, filter, out_pos)
    if w.done then return nil end
    local all = boxes()
    local built = all[s.index] or {}
    all[s.index] = built
    local f = filter_of(filter)
    if w.whole then
      w.done = true
      local list = s.find_entities_filtered(f)
      for i, e in ipairs(list) do
        local p = e.position
        if out_pos then out_pos[i] = p end
        grow(built, chunk(p.x), chunk(p.y))
      end
      return list, out_pos
    end
    local b = w.box
    if w.y > b.bottom then w.done = true; return nil end
    if w.x == b.left then w.band_rows = w.rows end
    local x1, y1 = math.min(w.x + w.cols - 1, b.right), math.min(w.y + w.band_rows - 1, b.bottom)
    local X0, Y0, X1, Y1 = w.x * 32, w.y * 32, (x1 + 1) * 32, (y1 + 1) * 32
    local a1, a2 = AREA[1], AREA[2]
    a1[1], a1[2], a2[1], a2[2] = X0, Y0, X1, Y1
    f.area = AREA
    local list = s.find_entities_filtered(f)
    local found, n = #list, 0
    for i = 1, found do
      local e = list[i]
      local p = e.position
      if p.x >= X0 and p.x < X1 and p.y >= Y0 and p.y < Y1 then
        n = n + 1
        list[n] = e
        if out_pos then out_pos[n] = p end
        grow(built, chunk(p.x), chunk(p.y))
      end
    end
    for i = found, n + 1, -1 do list[i] = nil end
    -- The next band: smaller after a full one, larger after a near-empty one.
    local width = b.right - b.left + 1
    local maxc = w.max or MAX_CHUNKS
    if #list > TARGET then
      w.rows, w.cols = 1, math.max(1, math.floor(w.cols / 2))
    elseif #list * 4 < TARGET then
      if w.cols < width then w.cols = math.min(width, w.cols * 2, math.max(1, math.floor(maxc / w.rows)))
      elseif w.rows < ROWS_MAX and w.rows * 2 * w.cols <= maxc then w.rows = w.rows * 2 end
    end
    w.x = x1 + 1
    if w.x > b.right then w.x = b.left; w.y = y1 + 1 end
    w.bands = (w.bands or 0) + 1
    return list, out_pos
  end

  -- One step every this many ticks for a job of `period` ticks whose last
  -- pass took `steps` steps (FIRST_EVERY before any pass).
  function W.every(steps, period)
    if not steps or steps < 1 then return FIRST_EVERY end
    return math.max(1, math.min(MAX_EVERY, math.floor(period * SPREAD / steps)))
  end
  -- Whether job {start, every, last} takes a step at tick: `every` ticks
  -- after its last; a pass still running past SPREAD of its period (it took
  -- more steps than the last, as when a box is first known) goes on every
  -- FIRST_EVERY ticks.
  function W.due(job, tick, period)
    local every = job.every
    if tick - job.start > period * SPREAD and every > FIRST_EVERY then every = FIRST_EVERY end
    if tick - (job.last or job.start) < every then return false end
    job.last = tick
    return true
  end
  return W
end
