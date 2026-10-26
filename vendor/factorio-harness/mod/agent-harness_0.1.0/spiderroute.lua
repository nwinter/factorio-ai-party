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
-- - (addendum, Aurora 20:07 site:4823: "Could Spidertron retreat ignore old or competing commands until rearmed?") once
--   it has retreated the spidertron is held: go_to and clear on it are refused (a queued one too) until one of those
--   agents re-arms: retreat_guard {to, ...} again, a go_to with its own retreat, or retreat_guard {clear: true}. A
--   sleep wakes and a direct wait ends on it (since).
return function(api)
  local M = {}
  M.SAMPLE, M.STALL, M.MOVED, M.AHEAD, M.MAX_TARGETS = 60, 600, 0.5, 24, 16
  -- (d22 batch122 CE2) a stalled spidertron's body sways where its legs stand: on a copy of world n's 08:53 save,
  -- Opus's at a lake's edge read speed 0 and moved 1.2 tiles between two samples, and "moves again" was said 4 s after
  -- its stall. Stalled, it moves again only past WOBBLE tiles from where it stood or that much nearer its target.
  M.WOBBLE = 3
  M.GUARD_EVERY = 30
  -- (d26 batch243 SR, viewer Aurora 13:42) a spidertron 1 tile from water (water within WATER_NEAR tiles on the line to its next
  -- target) with no path being asked recovers after STALL_WATER ticks without progress: it backs off to the newest spot
  -- of its trail (the last 6 sampled spots it stood with room for a path's box) 3 tiles or more away, else straight
  -- back from its target, and asks again for a path from there, up to RECOVER times; then the stall.
  M.STALL_WATER, M.WATER_NEAR, M.RECOVER = 180, 3, 3
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
    -- (d24 batch191) a route round water holds many points: the first 4 and the last 2
    if #r > 8 then parts = {parts[1], parts[2], parts[3], parts[4], string.format('... %d more ...', #r - 6), parts[#r - 1], parts[#r]} end
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
    local st = store()
    local lock = st.locks and st.locks[spider.unit_number]
    local out = {}
    if lock and type(own) == 'table' then
      st.locks[spider.unit_number] = nil
      out.rearmed = 'its retreat hold ended: this go_to carries its own retreat'
    elseif lock then
      local rec = lock.rec
      error(string.format('spidertron #%d is held on its retreat (%s %s ago: %s; its route became %s): go_to and clear are refused until re-armed; retreat_guard {to, health_below} again, retreat_guard {clear: true}, or a go_to with its own retreat {to, health_below} re-arms it',
        spider.unit_number, rec.guard, ago(game.tick - rec.tick), rec.why, rec.route_line), 0)
    end
    local before = route(spider)
    if a.clear then
      assert(a.go_to == nil or a.mode ~= 'append', 'clear goes alone or with go_to (then the route becomes go_to)')
      spider.autopilot_destination = nil
      out.cleared = #before
    end
    if a.go_to ~= nil then
      local list = points(a.go_to)
      -- (d26 batch243) a target on water: the dry spot nearest it (its legs stand nowhere on water; at (200,600) and
      -- (500,600) on d26 the route ended at the shore, stalled)
      if api.path and api.path.landing then
        for i, q in ipairs(list) do
          local okl, d, note = pcall(api.path.landing, spider.surface, q)
          if okl and note then list[i] = d; out.landed = out.landed or {}; out.landed[#out.landed + 1] = note end
        end
      end
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
    if #r > 0 then
      local t = entry(spider, r, by, index)
      if own ~= nil then t.retreat = own end
      -- (d26 batch243) its trail (spots it stood with room for a path) is the spidertron's, kept across go_to calls
      local old = st.spiders[spider.unit_number]
      if old and old.trail then t.trail = old.trail end
      st.spiders[spider.unit_number] = t
      local cfg = M.guard(spider, t)
      if cfg then out.retreat = api.retreat_line(cfg) .. (cfg.rider and ' (' .. cfg.rider .. ' rides it)' or '') .. string.format(', read every %d ticks', M.GUARD_EVERY) end
    else
      st.spiders[spider.unit_number] = nil
    end
    -- (d24 batch191) each straight leg read for water its legs cannot cross; paths round it requested (spiderpath.lua)
    if a.go_to ~= nil and #r > 0 and api.path then
      local ok, lines = pcall(api.path.plan, spider, r, {owner='route', by=by})
      if ok and lines then out.water = {crossing=lines, note='paths round the water were requested: the route becomes them when they come (often within this call), said once in team alerts (this reply or a later one)'} end
    end
    return out
  end
  -- (d24 batch191) the paths of a plan are in: its route goes round the water (unless it was set again since).
  function M.routed(rec, plan, spider, pts, notes)
    local unit = spider.unit_number
    local r = route(spider)
    local last = plan.targets[#plan.targets]
    if #r == 0 or dist(r[#r], last) > 0.5 then return end
    local found = false
    for _, seg in pairs(plan.segs or {}) do if type(seg) == 'table' then found = true end end
    local t0 = store().spiders[unit]
    if not found and not plan.via then
      if t0 then t0.no_path = table.concat(notes, '; ') end
      event(string.format('spidertron #%d: %s; its route stays %s', unit, table.concat(notes, '; '), route_line(r)), plan.by, unit)
      return
    end
    if t0 then t0.no_path = not found and table.concat(notes, '; ') or nil end
    local err = api.path.write(spider, pts)
    local now = route(spider)
    local t = store().spiders[unit]
    if t and #now > 0 then t.near, t.best, t.target, t.moved = dist(spider.position, now[1]), dist(spider.position, now[1]), {x=now[1].x, y=now[1].y}, game.tick end
    -- (d26 batch243) a back-off's plan with no path found: its route goes back there and on, said as such
    event(string.format(found and 'spidertron #%d: its route goes round the water now: %s%s%s' or 'spidertron #%d: no path round the water from its back-off spot either; its route: %s%s%s',
      unit, route_line(now), #notes > 0 and '; ' .. table.concat(notes, '; ') or '', err and '; the game refused it: ' .. err or ''), plan.by, unit)
  end
  -- (d26 batch243) no progress with water within WATER_NEAR ahead (or STALL with water within GAP + 4) and no path being
  -- asked: back off to the last spot it stood with room for a path's box (else the nearest one) and ask again from there,
  -- the route going there first at once. -> what was done, or nil when nothing can be (then the stall line).
  local function recover(e, t, r)
    local P = api.path
    if not (P and P.dry) then return nil end
    t.tries = t.tries or {}
    if #t.tries >= M.RECOVER then return nil end
    local pos, q = e.position, r[1]
    local okw, ahead = pcall(P.water_ahead, e.surface, pos, q)
    if not (okw and ahead) then return nil end
    -- the newest spot of its trail 3 tiles or more away (back the way it came), else straight back from the target
    local back, from_trail = nil, false
    for i = #(t.trail or {}), 1, -1 do
      if dist(t.trail[i], pos) >= 3 then back, from_trail = t.trail[i], true; break end
    end
    if not back then
      local okd, d = pcall(P.back, e.surface, pos, q)
      back = okd and d or nil
    end
    if not back then return nil end
    local target = r[#r]
    local route2 = {{x=back.x, y=back.y}}
    for _, w in ipairs(r) do route2[#route2 + 1] = w end
    local err = P.write(e, route2)
    -- its legs did not cross here: any water on the line from the back-off spot asks for a path (gap 0)
    local okp, lines = pcall(P.plan, e, {target}, {owner='route', by=t.by, from=back, gap=0})
    local did = string.format('stalled %s, %s from water on the line to %s, with no path being asked: backed off to %s, the %s, and %s (recovery %d of %d)',
      at(pos), ahead == 1 and '1 tile' or ahead .. ' tiles', at(q), at(back),
      from_trail and 'last spot it stood 3 tiles or more back with room for a path' or 'spot with room for a path straight back from its target',
      okp and lines and 'asked again for a path round the water to ' .. at(target) .. ' from there' or 'its route goes on from there (no water on the line from it)',
      #t.tries + 1, M.RECOVER)
    if err then did = did .. ' (the game refused the route: ' .. err .. ')' end
    t.tries[#t.tries + 1] = did
    t.far = dist(pos, target)
    return did
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
    -- (d26 batch243) what it did on its own, and whether a path is being asked or none was found
    if t and t.tries and #t.tries > 0 then out.recovery = t.tries end
    if api.path and api.path.pending and api.path.pending(spider.unit_number) then out.path = 'a path round the water is being asked'
    elseif t and t.no_path then out.no_path = t.no_path end
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
    -- (d24 batch191 addendum) the retreat leg over water its legs cannot cross: a path round it, as go_to's; its own
    -- re-route and shore recovery once more on this route
    local water
    if not refused and api.path then
      local okp, lines = pcall(api.path.plan, e, {cfg.to}, {owner='route', by=t.by})
      if okp and lines then water = lines[1] .. ': a path round the water was requested (the route becomes it when it comes)' end
    end
    t.rerouted, t.recovered, t.tries = nil, nil, nil
    local parts = {}
    for i, d in ipairs(before) do parts[i] = at(d) end
    local rec = {spidertron=e.name, unit_number=unit, why=info.why, from=info.from, health=info.health, shield=info.shield, to=cfg.to,
      replaced=parts, route_line=route_line(r), refused=refused, guard=cfg.standing and (cfg.rider and cfg.rider .. '\'s standing retreat_guard (riding it)' or 'standing retreat_guard') or 'the go_to\'s retreat',
      tick=game.tick, water=water}
    t.retreated = rec
    if #r > 0 then
      t.pos, t.near, t.moved, t.stalled, t.target = {x=e.position.x, y=e.position.y}, dist(e.position, r[1]), game.tick, nil, {x=r[1].x, y=r[1].y}
    end
    st.retreats = st.retreats or {}
    st.rseq = (st.rseq or 0) + 1
    st.retreats[#st.retreats+1] = {id=st.rseq, to={t.by, cfg.rider}, rec=rec}
    while #st.retreats > 32 do table.remove(st.retreats, 1) end
    st.locks = st.locks or {}
    st.locks[unit] = {agents={t.by, cfg.rider}, rec=rec}
    st.rlast = st.rlast or {}
    for _, name in ipairs({t.by, cfg.rider}) do st.rlast[name] = {tick=game.tick, unit=unit} end
  end
  -- A retreat said to this agent at or after tick (a sleep's or a direct wait's start): its line, or nil.
  function M.since(name, tick)
    local st = api.state().spiderroute
    local last = st and st.rlast and st.rlast[name]
    if not (last and last.tick >= tick) then return nil end
    local lock = st.locks and st.locks[last.unit]
    local rec = lock and lock.rec
    if not rec then return string.format('spidertron #%d retreated', last.unit) end
    return string.format('spidertron #%d retreated (%s: %s) from %s; its route became %s', last.unit, rec.guard, rec.why, at(rec.from), rec.route_line)
  end
  -- Re-armed by one of the agents it told (retreat_guard set or cleared): the holds end. -> how many.
  function M.rearm(name)
    local st = api.state().spiderroute
    local n = 0
    for unit, lock in pairs(st and st.locks or {}) do
      if lock.agents[1] == name or lock.agents[2] == name then st.locks[unit] = nil; n = n + 1 end
    end
    return n
  end
  -- retreat_guard {clear: true}: the go_to retreats of the spidertrons this agent sent are dropped too (and the holds
  -- end: M.rearm). -> how many.
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
    local held = store().locks and store().locks[rec.unit_number]
    return string.format('retreated %s ago (%s: %s) from %s, health %s%s; its route became %s%s%s', ago(game.tick - rec.tick), rec.guard, rec.why, at(rec.from), rec.health,
      rec.shield and ', shield ' .. rec.shield or '', rec.route_line, rec.refused and '; ' .. rec.refused or rec.water and '; ' .. rec.water or '',
      held and held.rec == rec and '; held: go_to and clear refused until re-armed' or '')
  end
  -- Every SAMPLE ticks: each spidertron sent by go_to.
  function M.tick()
    local st = store()
    for unit in pairs(st.locks or {}) do
      local e = game.get_entity_by_unit_number(unit)
      if not (e and e.valid) then st.locks[unit] = nil end
    end
    for unit, t in pairs(st.spiders) do
      local e = game.get_entity_by_unit_number(unit)
      local r = e and e.valid and route(e) or {}
      if #r == 0 then
        st.spiders[unit] = nil
        -- (d26 batch243 review) its arrival said to the sender: a go_to replied at once and nothing said it got there
        local last = t.last_target
        local arrived = e and e.valid and last and not t.stalled and dist(e.position, last) <= 4
        if arrived then
          event(string.format('spidertron #%d arrived at %s (its route ended at %s)', unit, at(e.position), at(last)), t.by, unit)
        elseif e and e.valid and t.stalled then event(string.format('spidertron #%d at %s: its route is empty now', unit, at(e.position)), t.by, unit) end
        -- (d26 batch247 NV1) how its route ended, for a waited go_to (watch)
        if e and e.valid then
          st.done = st.done or {}
          st.done[unit] = {tick=game.tick, arrived=arrived or false, at={x=e.position.x, y=e.position.y}, target=last, set_tick=t.tick}
        end
      else
        local pos = e.position
        t.last_target = {x=r[#r].x, y=r[#r].y}
        local near = dist(pos, r[1])
        local target_moved = math.abs(r[1].x - t.target.x) + math.abs(r[1].y - t.target.y) > 0.01
        -- (d24 batch191) progress: nearer its target than it has been (a body swaying at a shore comes no nearer than
        -- its nearest; it moved over 1 tile without coming nearer while sliding along a lake's edge on the copy)
        local step = t.stalled and M.WOBBLE or 2 * M.MOVED
        local best = t.best or t.near
        -- (d26 batch243) the last spot it stood with room for a path's box (where a back-off goes)
        local P = api.path
        if P and P.clear then
          local okc, room = pcall(P.clear, e.surface, pos)
          local q0 = {x=math.floor(pos.x) + 0.5, y=math.floor(pos.y) + 0.5}
          t.trail = t.trail or {}
          local last = t.trail[#t.trail]
          if okc and room and not (last and last.x == q0.x and last.y == q0.y) then
            t.trail[#t.trail + 1] = q0
            if #t.trail > 6 then table.remove(t.trail, 1) end
          end
        end
        local idle = game.tick - t.moved
        local quick = false
        if not t.stalled and idle >= M.STALL_WATER and P and P.water_ahead and not (P.pending and P.pending(unit)) then
          local okw, wa = pcall(P.water_ahead, e.surface, pos, r[1], M.WATER_NEAR)
          quick = okw and wa or false
        end
        -- recoveries count afresh once it is 30 tiles nearer its last target than at the last one
        if t.tries and t.far and dist(pos, r[#r]) < t.far - 30 then t.tries, t.far = nil, nil end
        if near < best - step or target_moved then
          if t.stalled then event(string.format('spidertron #%d moves again: at %s toward %s', unit, at(pos), at(r[1])), t.by, unit) end
          t.pos, t.near, t.best, t.moved, t.stalled, t.target = {x=pos.x, y=pos.y}, near, near, game.tick, nil, {x=r[1].x, y=r[1].y}
        elseif quick or (not t.stalled and idle >= M.STALL) then
          local did = recover(e, t, r)
          if did then
            local now = route(e)
            t.moved, t.best, t.near = game.tick, now[1] and dist(pos, now[1]) or near, now[1] and dist(pos, now[1]) or near
            if now[1] then t.target = {x=now[1].x, y=now[1].y} end
            event(string.format('spidertron #%d: no progress toward %s for %s; %s', unit, at(r[1]), ago(idle), did), t.by, unit)
          else
            t.stalled = true
            local f = M.facts(e)
            local held = st.locks and st.locks[unit]
            event(string.format('spidertron #%d: %s%s%s; its route: %s (%s)', unit, f.stalled and f.stalled.line or 'no progress',
              t.tries and #t.tries > 0 and string.format('; %d recover%s tried', #t.tries, #t.tries == 1 and 'y' or 'ies') or '',
              t.no_path and '; ' .. t.no_path or '', f.route_line,
              held and 'its retreat route; held: go_to is refused until re-armed (retreat_guard set or cleared, or a go_to with its own retreat)'
                or 'vehicle {go_to, mode: "replace"} sets a new one, {clear: true} empties it'), t.by, unit)
            if held and held.agents[2] and held.agents[2] ~= t.by then event(st.events[#st.events].text, held.agents[2], unit) end
          end
        end
      end
    end
  end
  -- (d26 batch247 NV1, viewer Aurora 14:13: "go_to --wait and an arrival outcome") a waited go_to (vehicle {go_to,
  -- wait: true}, fh --wait): its outcome from the route this go_to set, read with the samples (M.tick every 60 ticks):
  -- arrived (its route ended within 4 tiles of its last target); stalled (the stall line, after the recoveries);
  -- unreachable (stalled with no path found, or a target on water with no tile its legs stand on near it);
  -- route_changed (another go_to or clear, or a player, set its route); retreated (its guard sent it back);
  -- route_emptied (its route ended elsewhere); destroyed. nil while it walks.
  function M.watch(action)
    local e = action.spider
    if not (e and e.valid) then return 'destroyed' end
    local st = store()
    local done = st.done and st.done[action.unit]
    if done and done.set_tick == action.set_tick then
      action.done = done
      return done.arrived and 'arrived' or 'route_emptied'
    end
    local t = st.spiders[action.unit]
    if not t then return nil end
    if t.tick ~= action.set_tick then return 'route_changed' end
    if t.retreated then return 'retreated' end
    if t.stalled then return (t.no_path or action.unlanded) and 'unreachable' or 'stalled' end
    return nil
  end
  -- The waited go_to's last: where it stands, its route, what it did, and why it ended.
  function M.finish(action, outcome, last)
    local e = action.spider
    last.spidertron = string.format('spidertron #%d', action.unit)
    last.target = action.target
    if action.landed then last.landed = action.landed end
    if not (e and e.valid) then last.why = 'the spidertron is gone'; return end
    last.position = {x=e.position.x, y=e.position.y}
    local t = store().spiders[action.unit]
    local f = M.facts(e)
    last.route_line = f.route_line
    if t and t.tick == action.set_tick then
      if t.tries and #t.tries > 0 then last.recovery = t.tries end
      if t.no_path then last.no_path = t.no_path end
    end
    local d = action.done
    if outcome == 'arrived' and d then
      last.why = string.format('arrived at %s (its route ended at %s)', at(d.at), at(d.target or action.target))
    elseif outcome == 'stalled' or outcome == 'unreachable' then
      last.why = (f.stalled and f.stalled.line or 'no progress') .. (last.recovery and string.format('; %d recover%s tried', #last.recovery, #last.recovery == 1 and 'y' or 'ies') or '')
        .. (last.no_path and '; ' .. last.no_path or '') .. (outcome == 'unreachable' and action.unlanded and '; ' .. action.unlanded or '')
    elseif outcome == 'route_changed' then
      last.why = 'its route was set again (another go_to or clear, or a player): ' .. f.route_line
    elseif outcome == 'retreated' then
      last.why = t and t.retreated and retreat_text(t.retreated) or 'it retreated'
    elseif outcome == 'route_emptied' and d then
      last.why = string.format('its route ended at %s, %.0f tiles from %s', at(d.at), d.target and dist(d.at, d.target) or 0, at(d.target or action.target))
    elseif outcome == 'timed_out' then
      last.why = string.format('still walking after %d s: %s (its route goes on; vehicle {remote, vehicle} reads it)', math.floor((game.tick - action.start_tick) / 60), f.route_line)
    end
  end
  -- The waited go_to in status (active): where it is and its route.
  function M.go_line(action)
    local e = action.spider
    if not (e and e.valid) then return nil end
    return string.format('spidertron #%d at %s: %s', action.unit, at(e.position), M.facts(e).route_line)
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
    -- held after a retreat, its route ended since (or sent by another agent): until re-armed
    for unit, lock in pairs(store().locks or {}) do
      local rec = lock.rec
      local e = (lock.agents[1] == name or lock.agents[2] == name) and not seen[unit] and game.get_entity_by_unit_number(unit)
      if e and e.valid then
        out[#out+1] = string.format('spidertron #%d at %s: %s; %s', unit, at(e.position), route_line(route(e)), retreat_text(rec))
      end
    end
    table.sort(out)
    return #out > 0 and out or nil
  end
  return M
end
