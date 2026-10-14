-- Board claims seen from gameplay: whose claimed area a position lies in, so
-- collect can leave another agent's stock alone and say whose it is.
-- A claim lives on its owner's activity (shift07: 67 claims open at the end,
-- 60 untouched all shift): posting it, the owner's board updates on it, and
-- the owner's requests made inside its area or acting on a position in it.
-- Anyone may build in a claim (team.md); removing or rebuilding a teammate's
-- machines takes a notice first. After STALE without any activity it is
-- stale: no notice needed (stock no longer skips it, the label says so).
-- After EXPIRE the board closes it (board.lua). An `allow` list names agents
-- (or everyone) who need no notice while it is fresh.
-- A claim is on one surface (Sol 07:52: Astra's Nauvis claim #212 labelled
-- Gleba furnaces at (62,22)): the poster's when posted (or `surface`); one
-- posted before claims had one, the first time it is read: the one planet its
-- title names ("Gleba landing power"), else its owner's surface (else nauvis)
-- unless its area holds none of our buildings there and exactly one other
-- planet's does (world n, 08:05: Luna on Gleba, her claim #111 built only on
-- Nauvis). Positions on other surfaces are never in it.
return function(api)
  local M = {}
  local ACTIVE = {open=true, claimed=true, doing=true, blocked=true}
  M.STALE, M.EXPIRE = 30 * 3600, 120 * 3600
  local function inside(area, pos)
    return pos.x >= area.left_top.x and pos.x <= area.right_bottom.x and pos.y >= area.left_top.y and pos.y <= area.right_bottom.y
  end
  local function ago(ticks)
    local sec = math.floor(math.max(0, ticks) / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  -- A claim from before activity was kept gets its timers started the first
  -- time anything reads it (the deploy): a fresh 30 min and 2 h.
  function M.activity(i)
    if not i.active_tick and i.kind == 'claim' and ACTIVE[i.status] then i.active_tick = game.tick end
    return i.active_tick or i.updated_tick or i.created_tick or 0
  end
  function M.stale(i) return game.tick - M.activity(i) >= M.STALE end
  -- Claim i's surface name (set here, once, for a claim from before claims had one).
  function M.surface_of(i)
    if not i.surface then
      local planets = api.planets and api.planets() or {}
      local title, named = type(i.title) == 'string' and i.title:lower() or '', nil
      for _, name in ipairs(planets) do
        if title:find(name, 1, true) then
          if named then named = false; break end
          named = name
        end
      end
      if named then i.surface = named; return named end
      local s = api.owner_surface and api.owner_surface(i.owner)
      s = type(s) == 'string' and s or 'nauvis'
      if i.area and api.built_on and not api.built_on(s, i.area) then
        local only
        for _, name in ipairs(planets) do
          if name ~= s and api.built_on(name, i.area) then
            if only then only = false; break end
            only = name
          end
        end
        if only then s = only end
      end
      i.surface = s
    end
    return i.surface
  end
  local function on(i, surface, pos) return i.area ~= nil and surface ~= nil and M.surface_of(i) == surface and inside(i.area, pos) end
  local function surface_name(p) local ok, v = pcall(function() return p.surface.name end); return ok and v or nil end
  function M.allows(i, name)
    for _, n in ipairs(i.allow or {}) do if n == name or n == 'everyone' then return true end end
    return false
  end
  -- Whether claim i asks agent `name` to keep out (ask its owner first).
  function M.binding(i, name) return i.owner ~= name and not M.stale(i) and not M.allows(i, name) end
  -- Claims by others at pos on p's surface.
  local function claims_at(p, pos)
    local board = api.state().board
    if not board then return function() return nil end end
    local me, surface = p.name, surface_name(p)
    local k, v
    return function()
      repeat
        k, v = next(board.items, k)
        if v and v.kind == 'claim' and ACTIVE[v.status] and v.owner and v.owner ~= me and on(v, surface, pos)
          and game.tick - M.activity(v) < M.EXPIRE then return v end
      until not k
    end
  end
  -- The claim by someone else that asks p to keep out of pos (fresh, not
  -- allowing p), or nil.
  function M.other(p, pos)
    for i in claims_at(p, pos) do if M.binding(i, p.name) then return i end end
  end
  -- Any open claim by someone else at pos, a binding one first (collect's
  -- `claimed`: its label says when no notice is needed).
  function M.find(p, pos)
    local any
    for i in claims_at(p, pos) do
      if M.binding(i, p.name) then return i end
      any = any or i
    end
    return any
  end
  -- The owner touched claim i (board.lua; runtime.lua dispatch through M.worked).
  function M.touch(i) i.active_tick = game.tick end
  -- An owner's own request: its claims around the character, or holding the
  -- position the request acts on, are active.
  function M.worked(p, args)
    local board = api.state().board
    if not board then return end
    local me, c = p.name, p.character
    local at = c and c.valid and c.position
    local at_surface = at and surface_name(c)
    local pos = type(args) == 'table' and args.position
    if not (type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number') then pos = nil end
    local surface = surface_name(p)
    for _, i in pairs(board.items) do
      if i.kind == 'claim' and i.owner == me and ACTIVE[i.status] and i.area
          and ((at and on(i, at_surface, at)) or (pos and on(i, surface, pos))) then i.active_tick = game.tick end
    end
  end
  -- How a claim stands for reader p (or no reader): age, the owner's last
  -- activity on it and their state, and what that means for p.
  function M.state_text(i, p)
    local parts = {'posted ' .. ago(game.tick - (i.created_tick or 0)) .. ' ago',
      'owner active on it ' .. ago(game.tick - M.activity(i)) .. ' ago'}
    local st = api.owner_state and api.owner_state(i.owner)
    if st then parts[#parts+1] = i.owner .. ' ' .. st end
    if #(i.allow or {}) > 0 then parts[#parts+1] = 'allows ' .. table.concat(i.allow, ', ') end
    if M.stale(i) then parts[#parts+1] = 'stale: no notice needed to remove or rebuild; closes ' .. ago(M.EXPIRE - (game.tick - M.activity(i))) .. ' from now unless its owner works on it'
    elseif p and M.allows(i, p.name) then parts[#parts+1] = 'you are allowed' end
    return table.concat(parts, ', ')
  end
  -- With reader p: where the owner is when somewhere else (where.lua), and the state.
  function M.label(i, p)
    local where = p and api.where_from and api.where_from(p.name)
    local away = where and where(i.owner)
    return string.format('#%d %s (claim by %s%s; %s)', i.id, i.title or '', i.owner, away and ', ' .. away or '', M.state_text(i, p))
  end
  return M
end
