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
  local KEEP, SAMPLE, SEARCH, GIVE_UP, QUIET = 20, 15, 24, 600, 300
  local MAX_LINES = 4  -- a reply's team block shows this many drop lines (board.lua)
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.drops = s.drops or {seq=0, list={}}
    return s.drops
  end
  local function xy(pos) return {x=math.floor(pos.x * 10 + 0.5) / 10, y=math.floor(pos.y * 10 + 0.5) / 10} end
  local function at_text(pos) return string.format('(%d,%d)', math.floor(pos.x + 0.5), math.floor(pos.y + 0.5)) end
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

  -- `to`: a teammate's name or a list of them, told as the sender is.
  function M.recipients(to)
    if to == nil then return {} end
    local list = type(to) == 'table' and to or {to}
    assert(#list <= 8, 'to is at most 8 teammates')
    local out = {}
    for _, name in ipairs(list) do out[#out+1] = api.resolve(name) end
    return out
  end
  -- A new drop from space.lua: {pod, platform, surface, pad, near, sent, to}.
  function M.record(p, d)
    local s = store()
    s.seq = s.seq + 1
    local r = {id=s.seq, by=api.who(p), to=d.to or {}, platform=d.platform, surface=d.surface, pad=d.pad and xy(d.pad) or nil,
      near=d.near and xy(d.near) or nil, sent=d.sent, tick=game.tick, pod=d.pod, state='descending'}
    s.list[#s.list+1] = r
    while #s.list > KEEP do table.remove(s.list, 1) end
    return r.id
  end

  -- Where it came down: the landing pad, else the nearest cargo pod container
  -- to the pod's last sighting on the destination surface (not one another
  -- drop already took).
  local function claimed(s, unit)
    for _, r in ipairs(s.list) do if r.container_unit == unit then return true end end
    return false
  end
  local function settle(s, r)
    if r.pad then
      r.state, r.at, r.into = 'landed', r.pad, 'cargo-landing-pad'
      return
    end
    local surface = game.surfaces[r.surface]
    local seen = r.last and r.last.surface == r.surface and r.last.position or r.near
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
      if r.state == 'descending' then
        local pod = r.pod
        if pod and try(function() return pod.valid end) then
          local where = try(function() return {surface=pod.surface.name, position=xy(pod.position)} end)
          if where then r.last = where end
        else
          r.pod = nil
          r.gone = r.gone or tick
          settle(s, r)
        end
      end
    end
  end

  local function items(r) return table.concat(r.sent or {}, ' ') end
  local function landed_line(r)
    if r.into == 'cargo-landing-pad' then
      return string.format('drop #%d from %s landed in the landing pad at %s on %s: %s', r.id, r.platform, at_text(r.at), r.surface, items(r))
    end
    if r.note then return string.format('drop #%d from %s to %s: %s; it held %s', r.id, r.platform, r.surface, r.note, items(r)) end
    local held = r.landed_with and #r.landed_with > 0 and table.concat(r.landed_with, ' ') or items(r)
    return string.format('drop #%d landed at %s on %s: %s with %s (take them with transfer; it vanishes when empty)',
      r.id, at_text(r.at), r.surface, r.into, held)
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
        elseif r.state == 'landed' and told[r.id] ~= 'landed' then
          lines[#lines+1] = landed_line(r); keep[r.id] = 'landed'
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
        ago=ago(game.tick - r.tick), state=r.state, aimed_near=r.pad or r.near, at=r.at, landed_in=r.into, note=r.note}
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
    drops = {limit='1..20 (default 10)', returns='drops newest first: {id, by, to, platform, surface, items, ago, state (descending|landed), aimed_near, at, landed_in (cargo-pod-container or cargo-landing-pad), container {name, position, holds} or {gone}, note}. Read only'},
  }
  return M
end
