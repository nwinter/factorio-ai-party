-- checks (d20 batch55 P2, viewer Aurora 14:37: "Could task and blueprint checks show observed pass, fail or stale, and
-- rerun after relevant changes?"). A check is a read a player could make by looking, kept with its last observed result:
-- - condition: a wait_until condition (conditions.lua), met or not when run;
-- - blueprint: a library blueprint's last placement (blueprint_place {name}) over its area: every entity of it standing
--   built where the paste put it, facing as placed (flipped pastes: facing not compared).
-- A check may name a board item and an area (a placement's box for a blueprint check). Its result is pass or fail, with
-- the tick, who ran it and what it saw. It reads stale when, after that run: our entities in its area differ from what
-- stood there at the run (built, removed or turned: compared when the check is read, as a player remembers how the area
-- looked; up to COMPARE checks a read, each one find over its area), its blueprint was pasted there again, or the run is
-- older than its stale age (stale_after_s, default 30 game minutes). It runs when added and on checks {run}; nothing
-- runs it in the background.
return function(api)
  local M = {}
  -- (a find over a 96x96 box of the private copy's base, 3221 of ours, took 5.3 ms; bounded by limit, 600 of ours read about
  -- 1 ms: COMPARE such reads a listing)
  M.MAX, M.MAX_OWN, M.MAX_SIDE, M.MAX_ENTITIES, M.COMPARE, M.MAX_BP, M.BP_FIND = 64, 16, 96, 600, 6, 400, 1200
  M.STALE = 108000
  M.PLACEMENTS = 4
  -- what moves or is not a building: not compared
  local SKIP = {['entity-ghost']=true, ['tile-ghost']=true, character=true, ['item-request-proxy']=true, car=true, ['spider-vehicle']=true,
    locomotive=true, ['cargo-wagon']=true, ['fluid-wagon']=true, ['artillery-wagon']=true, ['construction-robot']=true,
    ['logistic-robot']=true, ['combat-robot']=true, unit=true, ['spider-unit']=true, ['cargo-pod']=true, fire=true, stream=true,
    projectile=true, ['item-entity']=true, corpse=true, ['character-corpse']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.checks = s.checks or {seq=0, list={}, placements={}}
    return s.checks
  end
  local function ago(t)
    local s = math.floor(math.max(0, t) / 60)
    if s < 120 then return s .. 's' end
    local m = math.floor(s / 60)
    return m < 120 and m .. 'm' or string.format('%dh%02dm', math.floor(m / 60), m % 60)
  end
  local function at(x, y) return string.format('(%g,%g)', x, y) end
  local function text(v, max, what)
    assert(type(v) == 'string' and v:find('%S'), what .. ' is text')
    local t = v:gsub('[%c]+', ' ')
    assert(#t <= max, what .. ' is at most ' .. max .. ' characters')
    return t
  end
  local function overlaps(a, b) return a.l < b.r and b.l < a.r and a.t < b.b and b.t < a.b end
  local function box_text(b) return string.format('(%g,%g)-(%g,%g)', b.l, b.t, b.r, b.b) end
  -- The area argument: {left_top, right_bottom} or [[x1,y1],[x2,y2]], or position with radius.
  local function area_of(a)
    if a.area ~= nil then
      assert(type(a.area) == 'table', 'area is {left_top, right_bottom} or [[x1,y1],[x2,y2]]')
      local l, r = api.position(a.area.left_top or a.area[1]), api.position(a.area.right_bottom or a.area[2])
      assert(r.x > l.x and r.y > l.y, 'area must be nonempty')
      return {l=l.x, t=l.y, r=r.x, b=r.y}
    end
    if a.position ~= nil then
      local q = api.position(a.position)
      local rad = a.radius == nil and 8 or a.radius
      assert(type(rad) == 'number' and rad >= 1 and rad <= M.MAX_SIDE / 2, 'radius is 1..' .. M.MAX_SIDE / 2)
      return {l=q.x - rad, t=q.y - rad, r=q.x + rad, b=q.y + rad}
    end
  end
  -- What stands in the box now: {units = {[unit] = {name, d, x, y}}, n, capped}.
  local function look(surface, force, b)
    local list = surface.find_entities_filtered{area={{b.l, b.t}, {b.r, b.b}}, force=force, limit=M.MAX_ENTITIES + 1}
    local snap = {units={}, n=0}
    if #list > M.MAX_ENTITIES then snap.capped = true; return snap end
    for _, e in ipairs(list) do
      local u = e.valid and not SKIP[e.type] and e.unit_number
      if u then
        snap.n = snap.n + 1
        if snap.n > M.MAX_ENTITIES then snap.capped = true; snap.units = {}; return snap end
        snap.units[u] = {name=e.name, d=e.direction or 0, x=e.position.x, y=e.position.y}
      end
    end
    return snap
  end
  -- What differs between a run's look and now: {built, removed, turned, first}.
  local function differ(old, now)
    local d = {built=0, removed=0, turned=0, first={}}
    local function note(kind, r) if #d.first < 3 then d.first[#d.first+1] = string.format('%s %s %s', r.name, at(r.x, r.y), kind) end end
    for u, r in pairs(now.units) do
      local o = old.units[u]
      if not o then d.built = d.built + 1; note('built', r)
      elseif o.d ~= r.d then d.turned = d.turned + 1; note('turned', r) end
    end
    for u, r in pairs(old.units) do if not now.units[u] then d.removed = d.removed + 1; note('removed', r) end end
    table.sort(d.first)
    return d
  end
  local function surface_of(c) return game.get_surface(c.surface) end
  local function newest_placement(name, box)
    local list = store().placements[name] or {}
    for i = #list, 1, -1 do
      if not box or overlaps(list[i].box, box) then return list[i] end
    end
  end
  -- A blueprint placement as it stands: the line and whether every entity stands built as placed.
  local function blueprint_read(surface, force, pl)
    local b = pl.box
    local built, ghosts = {}, {}
    local list = surface.find_entities_filtered{area={{b.l - 0.5, b.t - 0.5}, {b.r + 0.5, b.b + 0.5}}, force=force, limit=M.BP_FIND + 1}
    assert(#list <= M.BP_FIND, string.format('its box holds over %d entities of ours: not read', M.BP_FIND))
    for _, e in ipairs(list) do
      if e.valid then
        local ghost = e.type == 'entity-ghost'
        local name = ghost and e.ghost_name or e.name
        local k = name .. '@' .. e.position.x .. ',' .. e.position.y
        if ghost then ghosts[k] = e elseif not SKIP[e.type] then built[k] = e end
      end
    end
    local ok, ghost, missing, turned, rows = 0, 0, 0, 0, {}
    local function row(kind, x) if #rows < 4 then rows[#rows+1] = string.format('%s %s %s', x.name, at(x.x, x.y), kind) end end
    for _, x in ipairs(pl.entities) do
      local k = x.name .. '@' .. x.x .. ',' .. x.y
      local e = built[k]
      if e then
        local rotates = x.d ~= nil and try(function() return e.prototype.supports_direction end)
        if rotates and (e.direction or 0) ~= x.d then turned = turned + 1; row('facing otherwise', x) else ok = ok + 1 end
      elseif ghosts[k] then ghost = ghost + 1; row('a ghost', x)
      else missing = missing + 1; row('missing', x) end
    end
    local n = #pl.entities
    local parts = {string.format('%d of %d built as placed', ok, n)}
    if ghost > 0 then parts[#parts+1] = ghost .. ' still a ghost' end
    if missing > 0 then parts[#parts+1] = missing .. ' missing' end
    if turned > 0 then parts[#parts+1] = turned .. ' facing otherwise' end
    if #rows > 0 then parts[#parts+1] = 'first: ' .. table.concat(rows, ', ') end
    if pl.capped then parts[#parts+1] = string.format('only the first %d of its %d entities compared', n, pl.count) end
    return ok == n, table.concat(parts, '; ')
  end
  -- Run c now as p: its result, and what stands in its area.
  local function run(p, c)
    local surface = surface_of(c)
    assert(surface, 'its surface is gone')
    local pass, line
    if c.condition then
      assert(p.surface.index == c.surface, 'a condition check is read where it was added: on ' .. surface.name)
      local ok, met, saw = pcall(api.condition, p, c.condition)
      assert(ok, 'the condition read failed: ' .. tostring(met))
      pass, line = met == true, type(saw) == 'string' and saw:sub(1, 300) or (met and 'met' or 'not met')
    else
      local pl = newest_placement(c.blueprint, c.box)
      assert(pl, 'no placement of blueprint ' .. c.blueprint .. ' over ' .. box_text(c.box))
      if pl.tick ~= c.placed_tick then c.placed_tick, c.box = pl.tick, pl.box end
      pass, line = blueprint_read(surface, p.force, pl)
    end
    c.result = {pass=pass, tick=game.tick, by=api.who(p), line=line}
    c.history = c.history or {}
    c.history[#c.history+1] = {tick=game.tick, pass=pass}
    while #c.history > 5 do table.remove(c.history, 1) end
    c.look = c.box and look(surface, p.force, c.box) or nil
    c.repasted = nil
  end
  -- Its state for a read; compare: the area read again now.
  local function view(c, compare, force)
    local r = c.result
    local why = {}
    if r then
      if game.tick - r.tick > c.stale_after then why[#why+1] = string.format('run %s ago, past its stale age of %s', ago(game.tick - r.tick), ago(c.stale_after)) end
      if c.repasted then why[#why+1] = string.format('blueprint %s pasted there again by %s %s ago', c.blueprint, c.repasted.by, ago(game.tick - c.repasted.tick)) end
    end
    local compared
    -- (a run this tick has just read the area)
    if r and c.box and c.look and r.tick < game.tick then
      if c.look.capped then compared = string.format('area not compared: over %d of our entities there', M.MAX_ENTITIES)
      elseif compare then
        local surface = surface_of(c)
        local now = surface and try(function() return look(surface, force, c.box) end)
        if now and not now.capped then
          local d = differ(c.look, now)
          if d.built + d.removed + d.turned > 0 then
            local parts = {}
            for _, k in ipairs({'built', 'removed', 'turned'}) do if d[k] > 0 then parts[#parts+1] = d[k] .. ' ' .. k end end
            why[#why+1] = string.format('since that run, in its area: %s (%s)', table.concat(parts, ', '), table.concat(d.first, ', '))
          end
          compared = 'area compared now'
        else compared = 'area not compared: ' .. (now and string.format('over %d of our entities there now', M.MAX_ENTITIES) or 'its surface could not be read') end
      else compared = 'area not compared in this read (checks {id} compares it)' end
    end
    local state = not r and 'not run' or #why > 0 and 'stale' or (r.pass and 'pass' or 'fail')
    local what = c.condition and 'condition ' .. tostring(c.condition['until']) or 'blueprint ' .. c.blueprint
    local line = string.format('check #%d %s (%s%s, %s): %s', c.id, c.name, c.owner, c.item and ', board #' .. c.item or '', what,
      r and string.format('%s at tick %d, %s ago, by %s: %s', r.pass and 'pass' or 'fail', r.tick, ago(game.tick - r.tick), r.by, r.line) or 'not run')
      .. (#why > 0 and '; stale: ' .. table.concat(why, '; ') or '') .. (compared and compared ~= 'area compared now' and '; ' .. compared or '')
    local s = surface_of(c)
    return {id=c.id, name=c.name, owner=c.owner, item=c.item, kind=c.condition and 'condition' or 'blueprint', blueprint=c.blueprint,
      surface=s and s.name or nil, area=c.box and {left_top={x=c.box.l, y=c.box.t}, right_bottom={x=c.box.r, y=c.box.b}} or nil,
      state=state, result=r and (r.pass and 'pass' or 'fail') or nil, result_tick=r and r.tick or nil, result_age_s=r and math.floor((game.tick - r.tick) / 60) or nil,
      by=r and r.by or nil, saw=r and r.line or nil, stale=#why > 0 or nil, stale_why=#why > 0 and why or nil, compared=compared,
      stale_after_s=math.floor(c.stale_after / 60), history=c.history, line=line}
  end
  -- blueprint_place {name}: where the paste put each entity (blueprints.lua); a check of that blueprint over the box is
  -- stale from now.
  function M.placed(p, name, rec)
    local st = store()
    rec.tick, rec.by = game.tick, api.who(p)
    local list = st.placements[name] or {}
    st.placements[name] = list
    list[#list+1] = rec
    while #list > M.PLACEMENTS do table.remove(list, 1) end
    for _, c in pairs(st.list) do
      if c.blueprint == name and c.surface == rec.surface and c.box and overlaps(c.box, rec.box) then c.repasted = {tick=game.tick, by=rec.by} end
    end
    local n = 0
    for _ in pairs(st.placements) do n = n + 1 end
    if n > 32 then
      local oldest, ot
      for k, l in pairs(st.placements) do if not ot or l[#l].tick < ot then oldest, ot = k, l[#l].tick end end
      st.placements[oldest] = nil
    end
  end
  local function find(id)
    local c = store().list[id]
    assert(c, 'no check #' .. tostring(id))
    return c
  end
  local function add(p, a)
    local st = store()
    local me = api.who(p)
    local own, all = 0, 0
    for _, c in pairs(st.list) do all = all + 1; if c.owner == me then own = own + 1 end end
    assert(own < M.MAX_OWN, string.format('you have %d checks, the most a teammate keeps: checks {remove: id} one first', M.MAX_OWN))
    assert(all < M.MAX, string.format('the team has %d checks, the most kept', M.MAX))
    assert(type(a) == 'table', 'add is {name, condition | blueprint, item?, area? | position+radius?, stale_after_s?}')
    local c = {name=text(a.name, 80, 'name'), owner=me, created=game.tick}
    assert((a.condition ~= nil) ~= (a.blueprint ~= nil), 'a check is a condition (a wait_until condition) or a blueprint (a library name), one of them')
    if a.condition ~= nil then
      assert(type(a.condition) == 'table', 'condition is a wait_until condition: {until: "item_count", item, at_least, ...}')
      local ok, err = pcall(api.validate, a.condition)
      assert(ok, 'condition: ' .. tostring(err))
      c.condition = a.condition
      c.surface = p.surface.index
      c.box = area_of(a)
    else
      c.blueprint = text(a.blueprint, 200, 'blueprint')
      local want = area_of(a)
      local pl = newest_placement(c.blueprint, want)
      assert(pl, 'no placement of blueprint ' .. c.blueprint .. (want and ' over ' .. box_text(want) or '') .. ' remembered: blueprint_place {name} records one (the last ' .. M.PLACEMENTS .. ' a name)')
      c.surface, c.box, c.placed_tick = pl.surface, pl.box, pl.tick
    end
    if c.box then assert(c.box.r - c.box.l <= M.MAX_SIDE and c.box.b - c.box.t <= M.MAX_SIDE, string.format('the area is at most %dx%d', M.MAX_SIDE, M.MAX_SIDE)) end
    if a.item ~= nil then
      assert(type(a.item) == 'number' and api.item_exists and api.item_exists(a.item), 'item is a board item number')
      c.item = math.floor(a.item)
    end
    local sa = a.stale_after_s == nil and M.STALE / 60 or a.stale_after_s
    assert(type(sa) == 'number' and sa >= 60 and sa <= 86400, 'stale_after_s is 60..86400 game seconds (default 1800)')
    c.stale_after = math.floor(sa) * 60
    st.seq = st.seq + 1
    c.id = st.seq
    st.list[c.id] = c
    local ok, err = pcall(run, p, c)
    if not ok then c.result = {pass=false, tick=game.tick, by=me, line='the run failed: ' .. tostring(err):gsub('^[^:]*:%d+: ', '')} end
    return c
  end
  function M.handler(p, a)
    a = a or {}
    local st = store()
    local force = p.force
    if a.add ~= nil then return {added=add(p, a.add).id, check=view(st.list[st.seq], false, force)} end
    if a.run ~= nil then
      local c = find(a.run)
      local before = c.result and (c.result.pass and 'pass' or 'fail') or 'not run'
      run(p, c)
      return {ran=c.id, was=before, check=view(c, false, force)}
    end
    if a.remove ~= nil then
      local c = find(a.remove)
      st.list[c.id] = nil
      return {removed=c.id, line=string.format('check #%d %s removed (it was %s\'s)', c.id, c.name, c.owner)}
    end
    if a.id ~= nil then return {check=view(find(a.id), true, force)} end
    local me = api.who(p)
    local rows = {}
    for _, c in pairs(st.list) do
      if (a.item ~= nil and c.item == a.item) or (a.item == nil and (a.all or c.owner == me)) then rows[#rows+1] = c end
    end
    table.sort(rows, function(x, y) return x.id < y.id end)
    local out, lines = {}, {}
    for i, c in ipairs(rows) do
      local v = view(c, i <= M.COMPARE, force)
      out[#out+1] = v; lines[#lines+1] = v.line
    end
    return {checks=out, lines=lines, count=#out, note=#rows > M.COMPARE and string.format('the first %d checks\' areas compared; checks {id} compares one', M.COMPARE) or nil}
  end
  -- A check's state as stored (no area read), for a loss incident's recovery line: nil when there is no such check.
  function M.state_of(id)
    local c = store().list[id]
    if not c then return nil end
    local v = view(c, false)
    return string.format('check #%d %s: %s%s', c.id, c.name, v.state, v.result_age_s and string.format(' (last run %s %s ago)', v.result, ago(game.tick - v.result_tick)) or '')
  end
  -- (d21 batch68 AD2) the newest-run blueprint check of name over a box on a surface (index), as stored (no area read):
  -- {id, name, state (pass | fail | stale | not run), tick (its last run)}, or nil with none.
  function M.area_state(name, surface, box)
    local best
    for _, c in pairs(store().list) do
      if c.blueprint == name and c.surface == surface and c.box and overlaps(c.box, box) then
        if not best or (c.result and c.result.tick or -1) > (best.result and best.result.tick or -1) then best = c end
      end
    end
    if not best then return nil end
    local v = view(best, false)
    return {id=best.id, name=best.name, state=v.state, tick=best.result and best.result.tick or nil}
  end
  -- A board item's checks, as stored (no area read): lines for the item's view.
  function M.item_lines(id)
    local out = {}
    for _, c in pairs(store().list) do if c.item == id then out[#out+1] = view(c, false).line end end
    table.sort(out)
    return #out > 0 and out or nil
  end
  M.schema = {checks = {add='optional {name, condition (a wait_until condition) | blueprint (a library name: its last placement by blueprint_place {name}, over area if given), item? (a board item number), area? {left_top, right_bottom} | position with radius? (default 8; a condition check\'s area: what it depends on), stale_after_s? (60..86400, default 1800)}: adds a check and runs it once',
    run='optional check number: runs it again now (a condition: on its surface; a blueprint: its newest placement over its area)', remove='optional check number',
    id='optional check number: that check, its area compared now', item='optional board item number: its checks', all='optional true: every teammate\'s (default yours)',
    returns='checks [{id, name, owner, item, kind, blueprint, surface, area, state (pass | fail | stale | not run), result (the last run: pass or fail), result_tick, result_age_s, by, saw (what the run read), stale, stale_why (since that run: our entities built, removed or turned in its area; its blueprint pasted there again; past its stale age), compared, stale_after_s, history (the last 5 runs: tick, pass), line}], lines; the areas of up to 6 checks compared in a read (over 600 of ours in one: not compared). A check runs when added and on run; nothing runs it in the background. At most 16 a teammate, 64 in all'}}
  return M
end
