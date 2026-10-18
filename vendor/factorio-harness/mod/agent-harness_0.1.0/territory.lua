-- Demolisher territory up front (d17 batch14 B5, Sonnet: lost a coal outpost on Vulcanus within 9 minutes): a build,
-- ghost placement, paste, belt or rail route (and their dry runs) whose chunks lie in a demolisher's territory, as the
-- map draws its border on charted ground, says so: how many of its chunks, and the territory's demolisher where our
-- force sees it now (else that none is seen). Read only; bounded: MAX_CHUNKS chunks of the placement's box.
return function(api)
  local M = {}
  M.MAX_CHUNKS = 64
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%d,%d)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  -- {x0, y0, x1, y1} round the points.
  function M.box(points)
    local b
    for _, q in ipairs(points) do
      if q and type(q.x) == 'number' and type(q.y) == 'number' then
        if not b then b = {q.x, q.y, q.x, q.y}
        else b = {math.min(b[1], q.x), math.min(b[2], q.y), math.max(b[3], q.x), math.max(b[4], q.y)} end
      end
    end
    return b
  end
  function M.note(surface, force, box)
    if not (surface and box) or surface.platform ~= nil then return nil end
    if not try(function() return #surface.get_territories() > 0 end) then return nil end
    local cx0, cy0, cx1, cy1 = math.floor(box[1] / 32), math.floor(box[2] / 32), math.floor(box[3] / 32), math.floor(box[4] / 32)
    local order, n = {}, 0
    for cx = cx0, cx1 do
      for cy = cy0, cy1 do
        n = n + 1
        if n > M.MAX_CHUNKS then break end
        if try(function() return force.is_chunk_charted(surface, {x=cx, y=cy}) end) then
          local t = try(function() return surface.get_territory_for_chunk({x=cx, y=cy}) end)
          if t then
            local f
            for _, o in ipairs(order) do if o.t == t then f = o end end
            if not f then f = {t=t, chunks=0}; order[#order+1] = f end
            f.chunks = f.chunks + 1
          end
        end
      end
    end
    if #order == 0 then return nil end
    local parts, live = {}, false
    for _, f in ipairs(order) do
      local seen
      for _, u in ipairs(try(function() return f.t.get_segmented_units() end) or {}) do
        local q = try(function() return u.position end)
        if q and try(function() return force.is_chunk_visible(surface, {x=math.floor(q.x / 32), y=math.floor(q.y / 32)}) end) then
          seen = string.format('%s at %s, seen now', u.name, at(q)); break
        end
      end
      -- (d17 territory) its state as the demolishers read gives it: has a demolisher, killed at T by X, none in it now
      local state, line
      if not seen and api.state then state, line = api.state(surface, force, f.t) end
      if seen or state == 'has a demolisher' or state == 'not in sight' or not api.state then live = true end
      parts[#parts+1] = string.format('%d chunk%s of it in a demolisher territory (%s)', f.chunks, f.chunks == 1 and '' or 's', seen or line or 'its demolisher not in sight now')
    end
    return string.format('the placement lies inside a demolisher territory on %s, as the map draws its border: %s%s',
      surface.name, table.concat(parts, '; '), live and '; a demolisher attacks what is built in its territory' or '')
  end
  return M
end
