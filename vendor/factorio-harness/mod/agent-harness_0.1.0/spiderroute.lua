-- A spidertron's route as its remote gives it (d22 batch101 BK1, viewer Aurora site:4308: "Published go_to appends targets,
-- so a blocked one can trap later detours. Please add clear and replace options and feedback when movement stalls.").
-- vehicle {go_to} appended every target (add_autopilot_destination): on world n Opus's spidertron stood at the shore of a
-- lake at (-134,-433) from shift59 22:28 with [(185,175), (-60,-300)] queued, the first across deep water, which its legs
-- cannot stand on, and the detour behind it; another stood at (-40,498) with [(-70,545), (-72,545)] since shift58 19:28.
-- The game keeps walking at a target its legs cannot reach: speed 0, the target kept, nothing said.
-- - set: the remote's click (mode "replace", the default: the route becomes the target or targets given), its shift-click
--   (mode "append": added at the end), or clear: the route emptied (autopilot_destination nil);
-- - each spidertron sent this way is sampled every SAMPLE ticks (its position and how far it is from its next target);
--   no progress (moved under MOVED tiles and no nearer) for STALL ticks while it has a target is a stall: when it began,
--   where it stands, the target; the agent who sent it gets one line when it begins (and one when it moves again);
-- - facts(spider): the route and, when stalled, the stall with what stands on the straight line ahead within AHEAD tiles
--   (a tile or an entity its legs collide with, as the leg prototype's collision mask says), read when asked.
-- Facts only; nothing is moved or cleared but by the call, or by a retreat:
-- - (d24 batch189 QAE1, viewer Aurora site:4814: "Could native retreat_guard handle Spidertrons using vehicle shield/health
--   limits? On a trigger, replace outward waypoints and start retreat without waiting for another model response.")
--   a spidertron sent this way with a guard (the go_to's own retreat, else its sender's standing retreat_guard, else the
--   one of the agent riding it) is read every GUARD_EVERY ticks: its health, or its grid's shield, under the limit and
--   lower than when it was sent replaces its route by one to `to` (as a click on its remote), once until it is sent
--   again; the sender (and the rider whose guard it was) read it in team.spidertron_retreated and in status.
return function(api)
  local M = {}
  M.SAMPLE, M.STALL, M.MOVED, M.AHEAD, M.MAX_TARGETS = 60, 600, 0.5, 24, 16
  -- (d22 batch122 CE2) a stalled spidertron's body sways where its legs stand: on a copy of world n's 08:53 save,
  -- Opus's at a lake's edge read speed 0 and moved 1.2 tiles between two samples, and "moves again" was said 4 s after
  -- its stall. Stalled, it moves again only past WOBBLE tiles from where it stood or that much nearer its target.
  M.WOBBLE = 3
  M.GUARD_EVERY = 30
  local function store()
    local s = api.state()
    s.spiderroute = s.spiderroute or {spiders={}, events={}, eseq=0}
    return s.spiderroute
  end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(p) return string.format('(%g,%g)', math.floor(p.x * 10 + 0.5) / 10, math.floor(p.y * 10 + 0.5) / 10) end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function ago(t)
    local s = math.floor(t / 60)
    if s < 60 then return s .. 's' end
    if s < 3600 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s / 60) % 60)
  end
  local function route(spider)
    local out = {}
    for _, d in ipairs(try(function() return spider.autopilot_destinations end) or {}) do
      local pos = d.position or d
      out[#out+1] = {x=pos.x, y=pos.y}
    end
    return out
  end
  M.route = route
  local function route_line(r)
    if #r == 0 then return 'no target: it stands' end
    local parts = {}
    for i, d in ipairs(r) do parts[i] = at(d) end
    return string.format('%d target%s: %s', #r, #r == 1 and '' or 's', table.concat(parts, ' -> '))
  end
  -- The health and shield fractions now (the baseline a guard triggers under).
  local function fractions(spider)
    if not api.reading then return 1, nil end
    local h, m, sh, sm = api.reading(spider)
    return h and h / m or 1, sh and sh / sm or nil
  end
  local function entry(spider, r, by, index)
    local h0, s0 = fractions(spider)
    return {by=by, idx=index, tick=game.tick, pos={x=spider.position.x, y=spider.position.y}, near=dist(spider.position, r[1]),
      moved=game.tick, target={x=r[1].x, y=r[1].y}, h0=h0, s0=s0}
  end
  local function event(text, to, unit)
    local st = store()
    st.eseq = st.eseq + 1
    st.events[#st.events+1] = {id=st.eseq, text=text, to=to, unit=unit, tick=game.tick}
    while #st.events > 64 do table.remove(st.events, 1) end
  end
  local function points(a)
    if type(a) == 'table' and (a.x ~= nil or a[1] ~= nil and type(a[1]) == 'number') then return {api.position(a)} end
    assert(type(a) == 'table' and #a >= 1 and #a <= M.MAX_TARGETS, 'go_to is {x,y} or a list of 1..' .. M.MAX_TARGETS .. ' of them')
    local out = {}
    for i, q in ipairs(a) do out[i] = api.position(q) end
    return out
  end
  -- The call: go_to (with mode) or clear. -> the reply's facts. index: the sender's player index (its standing
  -- retreat_guard); own: the go_to's own retreat cfg, or false for none (retreat: false).
  function M.set(spider, a, by, index, own)
    assert(a.mode == nil or a.mode == 'replace' or a.mode == 'append', 'mode is "replace" (the default: the route becomes these targets, as a click on the remote) or "append" (added at the end, as a shift-click)')
    assert(a.clear == nil or a.clear == true, 'clear must be true')
    local before = route(spider)
    local out = {}
    if a.clear then
      assert(a.go_to == nil or a.mode ~= 'append', 'clear goes alone or with go_to (then the route becomes go_to)')
      spider.autopilot_destination = nil
      out.cleared = #before
    end
    if a.go_to ~= nil then
      local list = points(a.go_to)
      local mode = a.mode or 'replace'
      if mode == 'replace' and not a.clear then spider.autopilot_destination = nil end
      if mode == 'append' and #before + #list > 128 then error('the route would hold over 128 targets', 0) end
      for _, q in ipairs(list) do
        local ok, err = pcall(function() spider.add_autopilot_destination(q) end)
        if not ok then error('the game refused the destination ' .. at(q) .. ': ' .. tostring(err), 0) end
      end
      out.mode = mode
      if mode == 'replace' and #before > 0 and not a.clear then
        local parts = {}
        for i, d in ipairs(before) do parts[i] = at(d) end
        out.replaced = parts
      end
    end
    local r = route(spider)
    out.route, out.route_line = r, route_line(r)
    local st = store()
    if #r > 0 then
      local t = entry(spider, r, by, index)
      if own ~= nil then t.retreat = own end
      st.spiders[spider.unit_number] = t
      local cfg = M.guard(spider, t)
      if cfg then out.retreat = api.retreat_line(cfg) .. (cfg.rider and ' (' .. cfg.rider .. ' rides it)' or '') .. string.format(', read every %d ticks', M.GUARD_EVERY) end
    else
      st.spiders[spider.unit_number] = nil
    end
    return out
  end
  -- What stands on the straight line from the spidertron toward its target, within AHEAD tiles, that its legs collide
  -- with: the first tile or entity, as text, or nil.
  local function ahead(spider, target)
    local legs = try(function() return spider.get_spider_legs() end) or {}
    local mask = legs[1] and try(function() return legs[1].prototype.collision_mask end)
    local layers = mask and mask.layers or {}
    if not next(layers) then return nil end
    -- the layers it shares with the legs' mask, named in order ("player, water_tile")
    local function hits(m)
      local out = {}
      for l in pairs(m and m.layers or {}) do if layers[l] then out[#out+1] = l end end
      table.sort(out)
      return #out > 0 and table.concat(out, ', ') or nil
    end
    local function tiles(k) return k == 1 and '1 tile' or k .. ' tiles' end
    local pos, s = spider.position, spider.surface
    local d = dist(pos, target)
    if d < 0.5 then return nil end
    for k = 1, math.min(M.AHEAD, math.floor(d)) do
      local q = {x=pos.x + (target.x - pos.x) * k / d, y=pos.y + (target.y - pos.y) * k / d}
      local t = try(function() return s.get_tile(q.x, q.y) end)
      local layer = t and hits(try(function() return t.prototype.collision_mask end))
      if layer then return string.format('%s at %s, %s ahead (collision layers it shares with the legs: %s)', t.name, at({x=math.floor(q.x) + 0.5, y=math.floor(q.y) + 0.5}), tiles(k), layer) end
      for _, e in pairs(try(function() return s.find_entities_filtered{position=q, radius=0.6} end) or {}) do
        if e.valid and e.type ~= 'spider-leg' and e ~= spider then
          local l = hits(try(function() return e.prototype.collision_mask end))
          if l then return string.format('%s at %s, %s ahead (collision layers it shares with the legs: %s)', e.name, at(e.position), tiles(k), l) end
        end
      end
    end
    return nil
  end
  -- The route and, when stalled, the stall: {route, route_line, stalled?}. A spidertron with a route that nothing samples
  -- yet (sent before, or by a player) is sampled from this read on, `by` told of a stall (sampling: since when).
  function M.facts(spider, by, index)
    local r = route(spider)
    local out = {route=r, route_line=route_line(r)}
    local t = store().spiders[spider.unit_number]
    if not t and #r > 0 and by then
      t = entry(spider, r, by, index)
      store().spiders[spider.unit_number] = t
      out.sampling = 'from now: no progress for ' .. math.floor(M.STALL / 60) .. ' s is said in your next reply'
    elseif t and #r > 0 and not t.stalled then
      out.sampling = string.format('moving or sampled under %d s: last progress %s ago', math.floor(M.STALL / 60), ago(game.tick - t.moved))
    end
    if t and t.retreated then out.retreated = t.retreated end
    if t and #r > 0 and t.stalled then
      local why = ahead(spider, r[1])
      out.stalled = {since_tick=t.moved, for_s=math.floor((game.tick - t.moved) / 60), position=spider.position, target=r[1],
        ahead=why, line=string.format('no progress toward %s for %s, standing at %s (%.0f tiles from it)%s', at(r[1]), ago(game.tick - t.moved),
          at(spider.position), dist(spider.position, r[1]), why and '; on the straight line ahead: ' .. why or '; nothing its legs collide with on the straight line ahead within ' .. M.AHEAD .. ' tiles')}
    end
    return out
  end
  -- The guard that watches a spidertron now: the go_to's own retreat; else the sender's standing retreat_guard; else
  -- that of the agent riding it (driver, then passenger). nil when none (or retreat: false).
  function M.guard(spider, t)
    if t.retreat == false then return nil end
    if t.retreat then return t.retreat end
    local guards = api.state().retreat_guards
    if not guards then return nil end
    local g = t.idx and guards[t.idx]
    if g and g.to then return {to=g.to, health_below=g.health_below or (not g.shield_below and 0.4 or nil), shield_below=g.shield_below, standing=true} end
    local index, name = nil, nil
    if api.rider then index, name = api.rider(spider) end
    g = index and guards[index]
    if g and g.to then return {to=g.to, health_below=g.health_below or (not g.shield_below and 0.4 or nil), shield_below=g.shield_below, standing=true, rider=name} end
    return nil
  end
  -- Every GUARD_EVERY ticks: each spidertron with a route and a guard, read once; a trigger sends it to `to`.
  function M.guard_tick()
    local st = api.state().spiderroute
    if not (st and next(st.spiders)) then return end
    local guards = api.state().retreat_guards
    local any = guards and next(guards) ~= nil
    for unit, t in pairs(st.spiders) do
      if not t.retreated and (t.retreat or (t.retreat == nil and any)) then
        local e = game.get_entity_by_unit_number(unit)
        local cfg = e and e.valid and M.guard(e, t)
        if cfg then
          local look = {to=cfg.to, health_below=cfg.health_below, shield_below=cfg.shield_below, h0=t.h0 or 1, s0=t.s0, standing=cfg.standing}
          local info = api.retreat_check(e, look)
          if info then M.retreat(e, unit, t, cfg, info) end
        end
      end
    end
  end
  -- The retreat: the route replaced by one to `to` (the remote's click), said to the sender and the guard's rider.
  function M.retreat(e, unit, t, cfg, info)
    local st = store()
    local before = route(e)
    local refused
    local ok, err = pcall(function()
      e.autopilot_destination = nil
      e.add_autopilot_destination(cfg.to)
    end)
    if not ok then refused = 'the game refused the destination ' .. at(cfg.to) .. ': ' .. tostring(err) end
    local r = route(e)
    local parts = {}
    for i, d in ipairs(before) do parts[i] = at(d) end
    local rec = {spidertron=e.name, unit_number=unit, why=info.why, from=info.from, health=info.health, shield=info.shield, to=cfg.to,
      replaced=parts, route_line=route_line(r), refused=refused, guard=cfg.standing and (cfg.rider and cfg.rider .. '\'s standing retreat_guard (riding it)' or 'standing retreat_guard') or 'the go_to\'s retreat',
      tick=game.tick}
    t.retreated = rec
    if #r > 0 then
      t.pos, t.near, t.moved, t.stalled, t.target = {x=e.position.x, y=e.position.y}, dist(e.position, r[1]), game.tick, nil, {x=r[1].x, y=r[1].y}
    end
    st.retreats = st.retreats or {}
    st.rseq = (st.rseq or 0) + 1
    st.retreats[#st.retreats+1] = {id=st.rseq, to={t.by, cfg.rider}, rec=rec}
    while #st.retreats > 32 do table.remove(st.retreats, 1) end
  end
  -- retreat_guard {clear: true}: the go_to retreats of the spidertrons this agent sent are dropped too. -> how many.
  function M.clear_retreats(name)
    local n = 0
    for _, t in pairs(store().spiders) do
      if t.by == name and t.retreat then t.retreat = nil; n = n + 1 end
    end
    return n
  end
  -- The retreats this agent has not read yet (team.spidertron_retreated), once each.
  function M.retreats(p, h)
    local st = api.state().spiderroute
    if not (st and st.retreats and #st.retreats > 0) then return nil end
    local me = api.who and api.who(p) or p.name
    local out = {}
    for _, r in ipairs(st.retreats) do
      if r.id > (h.spider_retreat_seen or 0) and (r.to[1] == me or r.to[2] == me) then out[#out+1] = r.rec end
    end
    h.spider_retreat_seen = st.rseq
    return #out > 0 and out or nil
  end
  local function retreat_text(rec)
    return string.format('retreated %s ago (%s: %s) from %s, health %s%s; its route became %s%s', ago(game.tick - rec.tick), rec.guard, rec.why, at(rec.from), rec.health,
      rec.shield and ', shield ' .. rec.shield or '', rec.route_line, rec.refused and '; ' .. rec.refused or '')
  end
  -- Every SAMPLE ticks: each spidertron sent by go_to.
  function M.tick()
    local st = store()
    for unit, t in pairs(st.spiders) do
      local e = game.get_entity_by_unit_number(unit)
      local r = e and e.valid and route(e) or {}
      if #r == 0 then
        st.spiders[unit] = nil
        if e and e.valid and t.stalled then event(string.format('spidertron #%d at %s: its route is empty now', unit, at(e.position)), t.by, unit) end
      else
        local pos = e.position
        local near = dist(pos, r[1])
        local target_moved = math.abs(r[1].x - t.target.x) + math.abs(r[1].y - t.target.y) > 0.01
        local step = t.stalled and M.WOBBLE or M.MOVED
        if dist(pos, t.pos) >= step or near < t.near - step or target_moved then
          if t.stalled then event(string.format('spidertron #%d moves again: at %s toward %s', unit, at(pos), at(r[1])), t.by, unit) end
          t.pos, t.near, t.moved, t.stalled, t.target = {x=pos.x, y=pos.y}, near, game.tick, nil, {x=r[1].x, y=r[1].y}
        elseif not t.stalled and game.tick - t.moved >= M.STALL then
          t.stalled = true
          local f = M.facts(e)
          event(string.format('spidertron #%d: %s; its route: %s (vehicle {go_to, mode: "replace"} sets a new one, {clear: true} empties it)',
            unit, f.stalled and f.stalled.line or 'no progress', f.route_line), t.by, unit)
        end
      end
    end
  end
  -- The lines for the agent who sent a spidertron (team alerts), once each.
  function M.lines(p, h)
    local st = api.state().spiderroute
    if not st or #st.events == 0 then return nil end
    local me = api.who and api.who(p) or p.name
    local out = {}
    for _, e in ipairs(st.events) do
      if e.id > (h.spiderroute_seen or 0) and e.to == me then out[#out+1] = e.text end
    end
    h.spiderroute_seen = st.eseq
    return #out > 0 and out or nil
  end
  -- The spidertrons this agent sent that hold a route now, for its status.
  function M.mine(name)
    local out, seen = {}, {}
    for unit, t in pairs(store().spiders) do
      if t.by == name then
        local e = game.get_entity_by_unit_number(unit)
        if e and e.valid then
          local f = M.facts(e)
          out[#out+1] = string.format('spidertron #%d at %s: %s%s%s', unit, at(e.position), f.route_line, f.stalled and '; ' .. f.stalled.line or '',
            t.retreated and '; ' .. retreat_text(t.retreated) or '')
          seen[unit] = true
        end
      end
    end
    -- a retreat in the last 10 minutes whose route has ended since
    local recent = {}
    for _, r in ipairs(store().retreats or {}) do
      if (r.to[1] == name or r.to[2] == name) and game.tick - r.rec.tick < 36000 and not seen[r.rec.unit_number] then recent[r.rec.unit_number] = r.rec end
    end
    for unit, rec in pairs(recent) do
      local e = game.get_entity_by_unit_number(unit)
      local where = 'gone'
      if e and e.valid then where = 'at ' .. at(e.position) .. ': ' .. route_line(route(e)) end
      out[#out+1] = string.format('spidertron #%d %s; %s', unit, where, retreat_text(rec))
    end
    table.sort(out)
    return #out > 0 and out or nil
  end
  return M
end
