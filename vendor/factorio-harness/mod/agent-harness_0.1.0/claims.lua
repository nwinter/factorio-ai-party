-- Board claims seen from gameplay: whose claimed area a position lies in, so
-- collect can leave another agent's stock alone and say whose it is.
-- A claim lives on its owner's activity (shift07: 67 claims open at the end,
-- 60 untouched all shift): posting it, the owner's board updates on it, and
-- the owner's requests made inside its area or acting on a position in it.
-- The harness enforces no ownership: anyone may build or act anywhere, and who
-- may remove, move or reconfigure what is the team's own rule (team.md, d15
-- 06:25). What a claim does here: positions in it are labelled `claimed`, its
-- area's alerts go to its owner, and teammates' `stock` sweeps leave its chests
-- alone while it is fresh. After STALE without any activity it is stale (the
-- label says so and stock sweeps include it); after EXPIRE the board closes it
-- (board.lua). An `allow` list names agents (or everyone) its labels show as
-- allowed, whose own stock sweeps include it while it is fresh.
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
  -- Whether agent `name`'s stock sweeps skip claim i (fresh, someone else's, not allowing `name`).
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
  -- The claim by someone else whose chests p's stock sweeps skip at pos (fresh,
  -- not allowing p), or nil.
  function M.other(p, pos)
    for i in claims_at(p, pos) do if M.binding(i, p.name) then return i end end
  end
  -- Any open claim by someone else at pos, a binding one first (collect's
  -- `claimed` label: whose, fresh or stale, whom it allows).
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
  -- read: the request is a read (inspect, observe, supply ...): a claim holding its position (or its area's centre)
  -- records the inspection, by anyone (B2: the last inspection of an area).
  function M.worked(p, args, action, read)
    local board = api.state().board
    if not board then return end
    local me, c = p.name, p.character
    local at = c and c.valid and c.position
    local at_surface = at and surface_name(c)
    local pos = type(args) == 'table' and args.position
    if not (type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number') then pos = nil end
    if read and not pos and type(args) == 'table' and type(args.area) == 'table' and type(args.area.left_top) == 'table' and type(args.area.right_bottom) == 'table' then
      local lt, rb = args.area.left_top, args.area.right_bottom
      if type(lt.x) == 'number' and type(rb.x) == 'number' then pos = {x=(lt.x + rb.x) / 2, y=(lt.y + rb.y) / 2} end
    end
    local surface = surface_name(p)
    for _, i in pairs(board.items) do
      if i.kind == 'claim' and ACTIVE[i.status] and i.area then
        if i.owner == me and ((at and on(i, at_surface, at)) or (pos and on(i, surface, pos))) then i.active_tick = game.tick end
        if read and pos and on(i, surface, pos) then i.inspected = {tick=game.tick, by=me, action=action} end
      end
    end
  end
  -- board_review {ownership: true, surface?} (d17 batch33 B2, Sol, Astra and viewer Foobator 08:09-08:10: who looks
  -- after each system): per surface, the systems of ours (each electric network's machines from the census pass, each
  -- logistic network, each platform) and the open claims that cover them: how many of a system's machines (or
  -- roboports) lie in each claim's area, overlaps, an open claim with no area on that surface (a planet-wide claim)
  -- when no area covers it, else none; each claim's owner, their last activity there (requests in the area, board
  -- updates) and the last inspection of the area (a read there, by whom). Then each owner's blocked board items with
  -- the latest note. Facts only; read only.
  local SYSTEMS, SAMPLE = 32, 256
  function M.ownership(p, a)
    local board = api.state().board or {items={}}
    local force = p.force
    local list = {}
    if a.surface ~= nil then
      local s = game.get_surface(a.surface)
      assert(s, 'no surface ' .. tostring(a.surface))
      list[1] = s
    else
      for _, s in pairs(game.surfaces) do
        local ok, planet = pcall(function() return s.planet end)
        if ok and planet then list[#list+1] = s end
      end
      for _, pl in pairs(force.platforms or {}) do if pl.valid and pl.surface then list[#list+1] = pl.surface end end
    end
    table.sort(list, function(x, y) return x.index < y.index end)
    local claims, owners = {}, {}
    for _, i in pairs(board.items) do
      if i.kind == 'claim' and ACTIVE[i.status] and game.tick - M.activity(i) < M.EXPIRE then claims[#claims+1] = i end
    end
    table.sort(claims, function(x, y) return x.id < y.id end)
    local function claim_text(i)
      local ins = i.inspected
      return string.format('#%d %s (active there %s ago%s)', i.id, tostring(i.owner or 'no owner'), ago(game.tick - M.activity(i)),
        ins and string.format(', inspected %s ago by %s', ago(game.tick - ins.tick), ins.by) or ', no inspection there recorded')
    end
    local out_surfaces, lines = {}, {}
    for _, s in ipairs(list) do
      local systems = {}
      local pl = s.platform
      if pl then
        systems[1] = {kind='platform', name=pl.name, n=0, positions={}}
      else
        local by_net = {}
        for _, e in ipairs(api.crafters and api.crafters(force, s) or {}) do
          local id = e.valid and e.electric_network_id
          if id then
            local g = by_net[id]
            if not g then g = {kind='power', id=id, n=0, names={}, positions={}}; by_net[id] = g; systems[#systems+1] = g end
            g.n = g.n + 1
            g.names[e.name] = (g.names[e.name] or 0) + 1
            if #g.positions < SAMPLE then g.positions[#g.positions+1] = e.position end
          end
        end
        for _, ln in ipairs((force.logistic_networks or {})[s.name] or {}) do
          local g = {kind='logistic', id=ln.network_id, n=0, positions={}}
          for _, cell in ipairs(ln.cells or {}) do
            local o = cell.owner
            if o and o.valid then g.n = g.n + 1; if #g.positions < SAMPLE then g.positions[#g.positions+1] = o.position end end
          end
          systems[#systems+1] = g
        end
      end
      table.sort(systems, function(x, y) return x.n > y.n end)
      local rows = {}
      for k, g in ipairs(systems) do
        if k > SYSTEMS then rows[#rows+1] = {line=string.format('+%d more systems', #systems - SYSTEMS)}; break end
        local cover, fallback = {}, {}
        for _, i in ipairs(claims) do
          if M.surface_of(i) == s.name then
            if not i.area then fallback[#fallback+1] = i
            elseif g.kind ~= 'platform' then
              local inn = 0
              for _, q in ipairs(g.positions) do if inside(i.area, q) then inn = inn + 1 end end
              if inn > 0 then cover[#cover+1] = {i=i, n=inn} end
            else cover[#cover+1] = {i=i, n=1} end
          elseif g.kind == 'platform' and type(i.title) == 'string' and i.title:lower():find(g.name:lower(), 1, true) then
            cover[#cover+1] = {i=i, n=1, by_title=true}
          end
        end
        table.sort(cover, function(x, y) return x.n > y.n end)
        local what
        if g.kind == 'power' then
          local names = {}
          for name, c in pairs(g.names) do names[#names+1] = {name, c} end
          table.sort(names, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
          local parts = {}
          for j = 1, math.min(3, #names) do parts[j] = names[j][2] .. ' ' .. names[j][1] end
          what = string.format('electric network #%d: %d machine%s (%s)', g.id, g.n, g.n == 1 and '' or 's', table.concat(parts, ', '))
        elseif g.kind == 'logistic' then
          what = string.format('logistic network #%d: %d roboport cell%s', g.id, g.n, g.n == 1 and '' or 's')
        else what = 'platform ' .. g.name end
        local who
        if #cover > 0 then
          local parts = {}
          for _, c in ipairs(cover) do
            owners[c.i.owner or '?'] = true
            parts[#parts+1] = claim_text(c.i) .. (g.kind ~= 'platform' and string.format(': %d of %d sampled', c.n, #g.positions) or (c.by_title and ': its title names it' or ''))
          end
          who = (#cover > 1 and 'overlap: ' or 'claim ') .. table.concat(parts, '; ')
        elseif #fallback > 0 then
          local parts = {}
          for _, i in ipairs(fallback) do owners[i.owner or '?'] = true; parts[#parts+1] = claim_text(i) end
          who = 'no area covers it; planet-wide claim ' .. table.concat(parts, '; ')
        else who = 'no claim covers it' end
        rows[#rows+1] = {kind=g.kind, id=g.id, name=g.name, size=g.n, claims=#cover, owner_line=who, line=what .. ': ' .. who}
      end
      if #rows > 0 then
        out_surfaces[#out_surfaces+1] = {surface=s.name, systems=rows}
        lines[#lines+1] = s.name .. ':'
        for _, r in ipairs(rows) do lines[#lines+1] = '  ' .. r.line end
      end
    end
    -- each owner's blocked board items, with the latest note
    local blockers = {}
    for _, i in pairs(board.items) do
      if i.status == 'blocked' and i.owner and owners[i.owner] then
        local note = i.notes and i.notes[#i.notes]
        blockers[#blockers+1] = {id=i.id, line=string.format('%s: #%d %s is blocked%s', i.owner, i.id, tostring(i.title or ''),
          note and string.format(' (latest note %s ago by %s: %s)', ago(game.tick - (note.tick or game.tick)), tostring(note.by), tostring(note.text):sub(1, 120)) or '')}
      end
    end
    table.sort(blockers, function(x, y) return x.id < y.id end)
    local bl = {}
    for j, b in ipairs(blockers) do if j <= 16 then bl[j] = b.line end end
    return {surfaces=out_surfaces, lines=lines, blocked=#bl > 0 and bl or nil,
      note='machines from the census pass (assemblers and furnaces), grouped by electric network; coverage counts sampled positions inside each claim area; activity: the owner\'s requests in the area and board updates; inspection: the last read there by anyone. Read only'}
  end
  -- How a claim stands for reader p (or no reader): age, the owner's last
  -- activity on it and their state, and what that means for p.
  function M.state_text(i, p)
    local parts = {'posted ' .. ago(game.tick - (i.created_tick or 0)) .. ' ago',
      'owner active on it ' .. ago(game.tick - M.activity(i)) .. ' ago'}
    local st = api.owner_state and api.owner_state(i.owner)
    if st then parts[#parts+1] = i.owner .. ' ' .. st end
    if #(i.allow or {}) > 0 then parts[#parts+1] = 'allows ' .. table.concat(i.allow, ', ') end
    if M.stale(i) then parts[#parts+1] = 'stale: stock sweeps include it; closes ' .. ago(M.EXPIRE - (game.tick - M.activity(i))) .. ' from now unless its owner works on it'
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
