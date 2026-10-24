-- Who placed a ghost (d20 batch56 R7, Luna #1434: three Nauvis belts built by network 243's robots that no teammate
-- said they ordered; Luna's own belt_route had placed their ghosts 4 s before she found them).
-- What the game keeps (2.0.77, read on a copy of world n): LuaEntity.last_user, the entity tooltip's "Last user" line.
-- A ghost placed with a player has that player; the entity robots (or a revive) build from it keeps it. The harness
-- places a bot's ghosts with no player (a bot is not one), so those ghosts and what robots build from them read nil.
-- So the harness keeps its own record: each ghost an agent places (place_ghosts and what goes through it: the belt,
-- pipe and pole routes, ...; paste and blueprint_place; restore) and each entity an agent builds by hand, by its
-- surface, entity name and position, with the agent, the tick and the request (a call, a queue step, a standing
-- order). The last MAX placements are kept (a ring); a removal (mined by a player or a robot) drops its record. An
-- entity that stands where a ghost of its name was placed was built from that ghost (robots or a hand: the harness
-- does not see robot builds).
return function(api)
  local M = {}
  local MAX = 8192
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function st()
    local s = api.state()
    local L = s.ghost_log
    if not L then L = {map={}, ring={}, next=1, total=0, since=game.tick, pidx={}, pidx_done=true}; s.ghost_log = L end
    -- (d24 batch144 PP1) tile ghosts in a ring of their own, so a platform's foundation does not push out the entities'
    if not L.tmap then L.tmap, L.tring, L.tnext, L.tsince = {}, {}, 1, game.tick end
    -- (d24 batch144 cp2) a record log from before the position index: the index is built in slices (M.index_tick)
    if not L.pidx then L.pidx, L.pidx_slot, L.pidx_done = {}, 1, nil end
    return L
  end
  local function is_tile(e) return e.type == 'tile-ghost' end
  local function key_of(e)
    local name = (e.type == 'entity-ghost' or e.type == 'tile-ghost') and e.ghost_name or e.name
    local pos = e.position
    return e.surface.name .. '|' .. name .. '|' .. pos.x .. ',' .. pos.y
  end
  local function ago(ticks)
    local m = math.floor(math.max(0, ticks) / 3600)
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), m % 60) end
    if m >= 1 then return m .. 'm' end
    return math.floor(math.max(0, ticks) / 60) .. 's'
  end
  M.ago = ago
  -- The request running now: {action, step?, label?, order?} (runtime.lua sets it for a call and each queue step).
  local function via_text(v)
    if type(v) ~= 'table' or not v.action then return nil end
    if v.order then return string.format('%s, standing order "%s"', v.action, tostring(v.order)) end
    if v.step then return string.format('%s, queue step %s%s', v.action, tostring(v.step):gsub('^job%-', ''), v.label and ' "' .. tostring(v.label) .. '"' or '') end
    return v.action .. ', a call'
  end
  M.via_text = via_text
  -- (d24 batch144 PP1) A numeric key for a position (x and y on the half-tile grid; no text: turning a number into text
  -- took about 8 us in the 2.0.77 container, 632 ghosts 10 ms) and, per surface, how many records stand at each (pidx):
  -- a ghost with none there has no record, read without building its text key. A record counted there carries x.
  -- (cp2) Records from before the index are counted in slices, ring slot by ring slot (entities' ring, then tiles'):
  -- a record placed meanwhile is counted when placed and skipped when its slot is reached.
  local OFF, MUL = 4194304, 8388608
  local function nkey(x, y) return (x * 2 + OFF) * MUL + (y * 2 + OFF) end
  local function count(L, r)
    if r.n and not r.x then local t = L.pidx[r.s] or {}; L.pidx[r.s] = t; t[r.n] = (t[r.n] or 0) + 1; r.x = true end
  end
  local function unindex(L, r)
    if not (r and r.x) then return end
    local t = L.pidx[r.s]
    if t and t[r.n] then t[r.n] = t[r.n] > 1 and t[r.n] - 1 or nil end
    r.x = nil
  end
  M.INDEX_SLICE = 512
  -- Up to n ring slots counted into the index; returns how many were read (0 once it is done).
  function M.index_tick(n)
    local L = st()
    if L.pidx_done then return 0 end
    local slot, read = L.pidx_slot or 1, 0
    while read < n and slot <= 2 * MAX do
      local tile = slot > MAX
      local i = tile and slot - MAX or slot
      local k = (tile and L.tring or L.ring)[i]
      local r = k and (tile and L.tmap or L.map)[k]
      if r and r.i == i and not r.x then
        if not r.n then
          local sn, x, y = k:match('^(.-)|.-|(.-),(.-)$')
          x, y = tonumber(x), tonumber(y)
          if sn and x and y then r.s, r.n = sn, nkey(x, y) end
        end
        count(L, r)
      end
      slot, read = slot + 1, read + 1
    end
    L.pidx_slot = slot
    if slot > 2 * MAX then L.pidx_done = true end
    return read
  end
  -- nil once the index is whole, else {read, of}: ring slots read of all.
  function M.index_state()
    local L = st()
    if L.pidx_done then return nil end
    return {read=(L.pidx_slot or 1) - 1, of=2 * MAX, slice=M.INDEX_SLICE}
  end
  local function put(k, rec, tile)
    local L = st()
    local map, ring = L.map, L.ring
    if tile then map, ring = L.tmap, L.tring end
    local slot = tile and L.tnext or L.next
    local old = ring[slot]
    if old and map[old] and map[old].i == slot then unindex(L, map[old]); map[old] = nil end
    if map[k] then unindex(L, map[k]) end
    count(L, rec)
    rec.i = slot
    ring[slot] = k
    map[k] = rec
    if tile then L.tnext = slot % MAX + 1 else L.next = slot % MAX + 1 end
    L.total = L.total + 1
  end
  local function rec_of(e)
    local L = st()
    return (is_tile(e) and L.tmap or L.map)[key_of(e)]
  end
  -- A ghost an agent placed (who: its name), or with hand=true an entity it built by hand. A hand build of a ghost
  -- (revived) keeps the ghost's record and adds who built it.
  function M.placed(who, e, hand, revived)
    if not (who and e and e.valid) then return end
    local k = key_of(e)
    local via = via_text(api.via and api.via())
    if revived then
      local r = st().map[k]
      if r then r.b = who; r.bt = game.tick; return end
    end
    local pos = e.position
    put(k, {a=who, t=game.tick, v=via, h=hand or nil, s=e.surface.name, n=nkey(pos.x, pos.y)}, is_tile(e))
  end
  function M.forget(e)
    if not (e and e.valid) then return end
    local k = try(function() return key_of(e) end)
    if k then
      local L = st()
      local map = is_tile(e) and L.tmap or L.map
      unindex(L, map[k]); map[k] = nil
    end
  end
  local function user_name(e) local u = e.last_user; return u and u.name end
  local function last_user(e) local ok, v = pcall(user_name, e); if ok then return v end end
  -- For an entity or a ghost: {by, tick, ago, through, built_by_hand, last_user, line} or {unknown=true, line}.
  function M.read(e)
    if not (e and e.valid) then return nil end
    local L = st()
    local ghost = e.type == 'entity-ghost' or is_tile(e)
    local r = rec_of(e)
    local lu = last_user(e)
    local out = {last_user=lu}
    local parts = {}
    if r then
      out.by, out.tick, out.ago, out.through = r.a, r.t, ago(game.tick - r.t), r.v
      local what
      if r.h then what = 'built by hand by '
      elseif ghost then what = 'ghost placed by '
      else what = 'its ghost placed by ' end
      parts[1] = string.format('%s%s %s ago (tick %d)%s', what, r.a, out.ago, r.t, r.v and ' through ' .. r.v or '')
      if r.b then
        out.built_by_hand = r.b
        parts[#parts+1] = string.format('built by hand by %s %s ago', r.b, ago(game.tick - r.bt))
      elseif not ghost and not r.h then
        parts[#parts+1] = 'built from it since (robots or a hand: the harness does not see which)'
      end
    else
      out.unknown = true
      parts[1] = string.format('unknown: no harness record of placing %s here (the record began %s ago, at tick %d, and keeps the last %d placements); placed before then, by the game (the ghost of a destroyed entity) or by a player',
        ghost and 'this ghost' or 'it or its ghost', ago(game.tick - L.since), L.since, MAX)
    end
    if lu then parts[#parts+1] = 'the game\'s last user: ' .. lu end
    out.line = table.concat(parts, '; ')
    return out
  end
  -- One short text for a row (nil when the record has none and the game no last user).
  function M.short(e)
    if not (e and e.valid) then return nil end
    local r = rec_of(e)
    local lu = last_user(e)
    if not r then return lu and 'last user ' .. lu or nil end
    local t = string.format('%s%s %s ago%s', r.h and 'built by ' or 'ghost by ', r.a, ago(game.tick - r.t), r.v and ' (' .. r.v .. ')' or '')
    if r.b then t = t .. ', built by hand by ' .. r.b end
    if lu then t = t .. '; last user ' .. lu end
    return t
  end
  -- (d24 batch144 PP1) Who placed a ghost: the agent of the harness's record, else the game's last user; nil when
  -- neither knows. The second value says which: 'record' or 'last_user'.
  function M.owner(e)
    if not (e and e.valid) then return nil end
    local r = rec_of(e)
    if r then return r.a, 'record' end
    local lu = last_user(e)
    if lu then return lu, 'last_user' end
  end
  -- The same from what the caller read already (a surface's ghosts in one pass: about half the reads).
  function M.owner_at(surface_name, name, pos, tile, e)
    local L = st()
    local t = L.pidx[surface_name]
    local r
    if not L.pidx_done or (t and t[nkey(pos.x, pos.y)]) then r = (tile and L.tmap or L.map)[surface_name .. '|' .. name .. '|' .. pos.x .. ',' .. pos.y] end
    if r then return r.a, 'record' end
    local lu = last_user(e)
    if lu then return lu, 'last_user' end
  end
  function M.stats()
    local L = st()
    return {kept=table_size(L.map), placed=L.total, since_tick=L.since, max=MAX}
  end
  return M
end
