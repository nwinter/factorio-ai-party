-- Two spidertrons on one route (d28 batch310 PS, Updates row paired-spiders, viewer Aurora site:4841: "Could you finish
-- paired Spidertron routing, narrow passes and short water steps next? Batch305 is live. Keep emergency retreats
-- independent"). vehicle {pair: {lead, follower, distance}} pairs two spidertrons (one agent's; another agent's only once
-- that agent makes the same call); a go_to on the lead then moves both:
-- - the lead walks its own route (spiderroute.lua and spiderpath.lua as alone: paths round water, stored routes,
--   recoveries, its guard);
-- - the follower walks the lead's steps: the spots the lead stood on, every CRUMB tiles (dry ones; read every EVERY
--   ticks), given to it once the lead is `distance` tiles past them along its steps (less AHEAD while the lead walks:
--   it brakes toward its last point); A step the lead's legs took, the
--   follower's legs take: the same prototype has the same legs (2.0.77 has one spider-vehicle prototype, spidertron);
-- - the lead waits (its route kept aside and given back) while the follower is more than distance + SLACK tiles behind
--   along the steps (it joins first), and past a gate (a water step its legs crossed, or a narrow pass: dry ground
--   across its line no wider than NECK tiles) until the follower is past it too;
-- - the follower making no progress for STALL ticks splits the pair: said with where it stands and the gate it stood at;
--   the lead goes on alone;
-- - both arrived: said once, with where each stands.
-- Retreats stay independent: each spidertron's own guard (spiderroute.lua) watches it as alone; a retreat, spider_kite,
-- or another call setting the follower's route ends the pair at once (said), never waiting for or moving the partner
-- but to give the lead its own route back or to stop the follower where it stands.
-- (copy of world n's d28 09:50 save, iMac) a spidertron walks 13-13.6 tiles/s on grass; points 4 tiles apart (all at
-- once, or appended one at a time) keep that speed; a cleared route stops it within 3-4 tiles and its route given back
-- has it at full speed again in about 1 s. The game's own follow_target trailed the lead straight at it (no path round
-- water) and closed to 2 tiles when the lead stopped: the harness gives the steps instead.
return function(api)
  local M = {}
  M.EVERY, M.CRUMB, M.DIST, M.DIST_MIN, M.DIST_MAX = 10, 2, 10, 6, 40
  -- the lead waits over distance + SLACK behind, until within distance + RESUME: at equal speed (one prototype) nothing
  -- else closes a gap, as the follower's join from where it stands
  M.SLACK, M.RESUME, M.STALL, M.GATE_PAST, M.OFFER = 4, 2, 300, 4, 36000
  M.NECK, M.NECK_SIDE, M.ENDED = 3, 4, 16
  -- (copy, d28 10:40) a spidertron brakes toward its route's last point (it stopped within 3-4 tiles from full speed):
  -- steps given only up to `distance` behind the lead had the follower braking at each and the lead waiting (gaps 6-19,
  -- 100 tiles in 18.3 s); the follower's steps reach AHEAD tiles nearer the lead while it walks, so it walks at speed
  -- about distance behind, and are cut back to distance behind once the lead's route ends
  M.AHEAD = 5
  -- (d26 batch247 NV4) water a spidertron's legs step across, by prototype; another's is not measured: any water on its
  -- line counts (0)
  M.MEASURED = {spidertron=true}
  local function store()
    local s = api.state()
    s.spiderpairs = s.spiderpairs or {list={}, by_unit={}, offers={}, ended={}, seq=0, wseq=0}
    return s.spiderpairs
  end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function ent(u) local e = game.get_entity_by_unit_number(u); return e and e.valid and e or nil end
  local function tiles(n) n = math.floor(n + 0.5); return n == 1 and '1 tile' or n .. ' tiles' end
  function M.of(unit)
    local st = api.state().spiderpairs
    local id = st and st.by_unit[unit]
    return id and st.list[id] or nil
  end
  local function say(pr, text) for _, a in ipairs(pr.agents) do api.say(text, a, pr.lead) end end
  local function name(pr) return string.format('pair %d (#%d leads, #%d follows)', pr.id, pr.lead, pr.follower) end
  -- The water its legs step across (tiles): measured for the spidertron only.
  function M.reach(e) return M.MEASURED[e.name] and api.path.GAP or 0 end
  -- The rule the pair takes: the shorter reach of the two, and the line saying it.
  function M.rule(L, F)
    local a, b = M.reach(L), M.reach(F)
    local function one(e, r) return r > 0 and string.format('%s: its legs step across up to %d tiles of water', e.name, r) or string.format('%s: its legs\' reach is not measured, so any water on its line counts', e.name) end
    if L.name == F.name then return a, string.format('both are %s (one prototype, the same legs): a water step or a narrow pass one takes the other takes; %s', L.name, one(L, a)) end
    return math.min(a, b), string.format('%s and %s; the route is planned for the shorter reach (%d tiles)', one(L, a), one(F, b), math.min(a, b))
  end
  -- The pair's planning gap for its lead's go_to: nil when it is the spidertron's own.
  function M.gap(spider)
    local pr = M.of(spider.unit_number)
    if not (pr and pr.lead == spider.unit_number) then return nil end
    local F = ent(pr.follower)
    if not F then return nil end
    local g = M.rule(spider, F)
    return g < M.reach(spider) and g or nil
  end
  -- Dry ground across the line a -> b at b, counted out from b each side (up to NECK_SIDE): its width when no wider than
  -- NECK tiles (a narrow pass), else nil.
  function M.neck(surface, a, b)
    local d = dist(a, b)
    if d < 0.5 then return nil end
    local wet = api.path.wet
    if wet(surface, b.x, b.y) then return nil end
    local nx, ny = -(b.y - a.y) / d, (b.x - a.x) / d
    local w = 1
    for _, sg in ipairs({1, -1}) do
      for k = 1, M.NECK_SIDE do
        if wet(surface, b.x + sg * nx * k, b.y + sg * ny * k) then break end
        w = w + 1
        if w > M.NECK then return nil end
      end
    end
    return w
  end
  -- The gates on a route from `from`: water steps (a leg crossing 1..reach tiles of water) and narrow passes (every
  -- CRUMB tiles), in order; at most 8 said. -> list of {kind, at, run|width, line}.
  function M.gates(surface, from, pts)
    local P = api.path
    local out, prev = {}, from
    local last_neck
    for _, q in ipairs(pts) do
      local run = P.run(surface, prev, q)
      if run >= 1 then
        local b = P.segment(surface, prev, q, 0)
        out[#out + 1] = {kind='water step', at=b and b.at or q, run=math.floor(run + 0.5), line=string.format('a water step of %s at %s', tiles(run), at(b and b.at or q))}
      end
      local d = dist(prev, q)
      for k = M.CRUMB, math.floor(d), M.CRUMB do
        local c = {x=prev.x + (q.x - prev.x) * k / d, y=prev.y + (q.y - prev.y) * k / d}
        local w = M.neck(surface, prev, c)
        if w and not (last_neck and dist(last_neck, c) <= M.CRUMB + 0.5) then
          out[#out + 1] = {kind='narrow pass', at=c, width=w, line=string.format('a narrow pass %s wide at %s', tiles(w), at(c))}
        end
        if w then last_neck = c end
      end
      prev = q
      if #out >= 8 then break end
    end
    return out
  end
  local function gates_text(list)
    if #list == 0 then return 'no water step or narrow pass on its route' end
    local parts = {}
    for i, g in ipairs(list) do parts[i] = g.line end
    return table.concat(parts, '; ')
  end
  -- Whose a spidertron is: the agent riding it, else the one whose timed action runs with it, else the one who sent it
  -- last (go_to, clear, spider_kite). -> name, how (or nil).
  function M.owner(e)
    local name = api.rider and select(2, api.rider(e))
    if name then return name, 'rides it' end
    name = api.actor and api.actor(e)
    if name then return name, 'runs an action with it' end
    name = api.sender and api.sender(e.unit_number)
    if name then return name, 'sent it last' end
    return nil
  end
  function M.line(pr)
    local w = pr.walk
    local s = string.format('%s, %d tiles apart on the lead\'s steps (agreed by %s)', name(pr), pr.dist, table.concat(pr.agents, ', '))
    if not w then return s .. '; a go_to on #' .. pr.lead .. ' moves both' end
    local L, F = ent(pr.lead), ent(pr.follower)
    local parts = {s}
    if L and F then parts[#parts + 1] = string.format('walking: #%d at %s, #%d at %s, %.0f tiles from it', pr.lead, at(L.position), pr.follower, at(F.position), dist(L.position, F.position)) end
    if w.hold then parts[#parts + 1] = '#' .. pr.lead .. ' waits ' .. w.hold.why end
    if w.holds > 0 then parts[#parts + 1] = string.format('#%d waited %d time%s', pr.lead, w.holds, w.holds == 1 and '' or 's') end
    return table.concat(parts, '; ')
  end
  -- A step given to the follower.
  local function give(w, F, k)
    local c = w.crumbs[k]
    F.add_autopilot_destination({x=c.x, y=c.y})
    w.given = k
  end
  -- The walk: from the lead's spot now; the follower's route becomes its way to that spot (a path round water when its
  -- line there crosses more than its legs step: asked as go_to's are). -> the reply's lines.
  function M.start(pr, L, F)
    local st = store()
    st.wseq = st.wseq + 1
    local P = api.path
    local w = {id=st.wseq, tick=game.tick, crumbs={{x=L.position.x, y=L.position.y, s=0}}, given=0, lead_s=0, f_moved=game.tick, holds=0, said={}}
    pr.walk, pr.done = w, nil
    api.adopt(F, pr)
    F.autopilot_destination = nil
    give(w, F, 1)
    pr.seq_l, pr.seq_f = api.seq(L.unit_number), api.seq(F.unit_number)
    local out = {}
    local reach = M.reach(F)
    local b = P.segment(F.surface, F.position, w.crumbs[1], reach)
    if b then
      local ok, lines = pcall(P.plan, F, {w.crumbs[1]}, {owner='route', by=pr.agents[1], reuse=true, gap=reach ~= P.GAP and reach or nil, claim=api.seq(F.unit_number)})
      out.join = ok and lines and string.format('#%d\'s line to #%d crosses water its legs do not step across (%s): a path round it was asked for #%d; #%d waits for it', F.unit_number, L.unit_number, b.line, F.unit_number, L.unit_number)
        or string.format('#%d\'s line to #%d crosses water its legs do not step across (%s), and no path could be asked: it walks the line', F.unit_number, L.unit_number, b.line)
    else
      out.join = string.format('#%d joins from %s, %.0f tiles from #%d; #%d waits while it is over %d tiles behind', F.unit_number, at(F.position), dist(F.position, L.position), L.unit_number, L.unit_number, pr.dist + M.SLACK)
    end
    local route = api.route(L)
    if #route > 0 and not (P.pending and P.pending(L.unit_number)) then
      w.gates_said = true
      out.gates = gates_text(M.gates(L.surface, L.position, route))
    else
      out.gates = 'its route is being asked: the water steps and narrow passes on it are said when it comes'
    end
    return out
  end
  -- The lead's route came (paths round water): its gates said once.
  function M.routed(spider)
    local pr = M.of(spider.unit_number)
    if not (pr and pr.walk and pr.lead == spider.unit_number) or pr.walk.gates_said then return end
    pr.walk.gates_said = true
    local route = api.route(spider)
    if #route > 0 then say(pr, string.format('%s: #%d\'s route came: %s', name(pr), pr.lead, gates_text(M.gates(spider.surface, spider.position, route)))) end
  end
  -- Ends the pair: said to its agents. o: {keep_l (the lead's route is another's now), keep_f (the follower's route is its
  -- own now: a retreat or another call), stalled, at}.
  function M.release(pr, why, o)
    o = o or {}
    local st = store()
    local L, F = ent(pr.lead), ent(pr.follower)
    if L and not o.keep_l then api.resume(L) end
    if F then api.unadopt(F, not o.keep_f and pr.walk ~= nil) end
    st.list[pr.id] = nil
    if st.by_unit[pr.lead] == pr.id then st.by_unit[pr.lead] = nil end
    if st.by_unit[pr.follower] == pr.id then st.by_unit[pr.follower] = nil end
    st.ended[#st.ended + 1] = {id=pr.id, walk=pr.walk and pr.walk.id, tick=game.tick, why=why, stalled=o.stalled, at=o.at}
    while #st.ended > M.ENDED do table.remove(st.ended, 1) end
    say(pr, name(pr) .. ' ended: ' .. why)
  end
  local function ended(id, walk)
    for i = #store().ended, 1, -1 do
      local e = store().ended[i]
      if e.id == id and e.walk == walk then return e end
    end
  end
  -- Another call on either: a retreat, spider_kite, the follower's route set. -> why and the release's o, or nil.
  local function taken(pr, L, F)
    for _, x in ipairs({{L, 'lead'}, {F, 'follower'}}) do
      local e, role = x[1], x[2]
      local rec = api.retreated(e)
      if rec and rec.tick >= (pr.walk and pr.walk.tick or pr.tick) then
        local other = role == 'lead' and F or L
        return string.format('#%d retreated (%s: %s) from %s; its retreat goes on alone; %s', e.unit_number, rec.guard or 'its guard', rec.why or 'retreat', at(rec.from or e.position),
          role == 'lead' and string.format('#%d stops where it stands at %s (its route cleared)', other.unit_number, at(other.position)) or string.format('#%d goes on alone (its route stays)', other.unit_number)),
          {keep_l=role == 'lead', keep_f=role == 'follower'}
      end
      local seq = api.seq(e.unit_number)
      local mine = role == 'lead' and pr.seq_l or pr.seq_f
      if pr.walk and seq ~= mine then
        local s = api.set_of(e.unit_number) or {}
        return string.format('%s set #%d\'s route (%s) %s', tostring(s.by or 'another call'), e.unit_number, s.how or 'a call', role == 'lead' and string.format('outside the pair; #%d stops where it stands (its route cleared)', F.unit_number) or string.format('outside the pair; #%d goes on alone (its route stays)', L.unit_number)),
          {keep_l=role == 'lead', keep_f=role == 'follower'}
      end
    end
  end
  -- The follower's progress along the steps: the step it walks to now (its route's last point is the step given last;
  -- points before the first step are its way round water to it).
  local function f_progress(w, F, fr)
    local k = w.given - #fr + 1
    if k > w.given then return w.crumbs[w.given].s end
    if k < 1 then
      -- its way round water to the first step: what is left of it, along it
      local rem = dist(F.position, fr[1])
      for i = 1, 1 - k do rem = rem + dist(fr[i], fr[i + 1]) end
      return -rem
    end
    return w.crumbs[k].s - dist(F.position, w.crumbs[k])
  end
  local function step(pr, L, F)
    local w = pr.walk
    local why, o = taken(pr, L, F)
    if why then return M.release(pr, why, o) end
    local P = api.path
    local surface = L.surface
    local held = api.held(L)
    -- (copy) the lead's whole route read each sample cost most of this tick: its first point says whether it has one
    local walking = L.autopilot_destination ~= nil
    local lpos = L.position
    local last = w.crumbs[#w.crumbs]
    local d = dist(lpos, last)
    if d >= M.CRUMB * 0.75 and not P.wet(surface, lpos.x, lpos.y) then
      local c = {x=math.floor(lpos.x * 10 + 0.5) / 10, y=math.floor(lpos.y * 10 + 0.5) / 10, s=last.s + d}
      local run = P.run(surface, last, c)
      if run >= 1 then
        local b = P.segment(surface, last, c, 0)
        c.gate = {kind='water step', at=b and b.at or c, s=c.s, line=string.format('the water step at %s (%s of water)', at(b and b.at or c), tiles(run))}
        w.neck = nil
      else
        local wd = M.neck(surface, last, c)
        -- a neck read at consecutive steps is one pass: the gate ends at the last of them
        if wd and w.neck and w.neck.s == last.s then w.neck.s = c.s
        elseif wd then c.gate = {kind='narrow pass', at={x=c.x, y=c.y}, s=c.s, line=string.format('the narrow pass at %s (%s wide)', at(c), tiles(wd))} end
        w.neck = wd and (c.gate or w.neck) or nil
      end
      w.crumbs[#w.crumbs + 1] = c
      last, d = c, 0
    end
    w.lead_s = last.s + d
    local lead_done = not walking and not held and not (P.pending and P.pending(L.unit_number))
    local fpend = P.pending and P.pending(F.unit_number)
    local fr = api.route(F)
    -- steps given once the lead is distance past them
    if not fpend then
      local limit = w.lead_s - pr.dist + (lead_done and 0 or M.AHEAD)
      while w.given < #w.crumbs and w.crumbs[w.given + 1].s <= limit do
        give(w, F, w.given + 1)
        fr[#fr + 1] = w.crumbs[w.given]
      end
      -- the lead's route ended: the follower's steps cut back to distance behind it
      if lead_done and not w.trimmed then
        w.trimmed = true
        local keep, first = {}, w.given - #fr + 1
        for k = math.max(first, 1), w.given do if w.crumbs[k].s <= limit then keep[#keep + 1] = w.crumbs[k] end end
        if #keep < #fr then
          F.autopilot_destination = nil
          for _, c in ipairs(keep) do F.add_autopilot_destination({x=c.x, y=c.y}) end
          w.given = math.max(first, 1) + #keep - 1
          fr = api.route(F)
        end
      end
    end
    local fs = f_progress(w, F, fr)
    w.f_s = fs
    if fpend then
      w.f_best, w.f_moved = nil, game.tick  -- its way round water is being asked: progress counts from its path
    elseif #fr == 0 or fs > (w.f_best or -1e9) + 0.5 then
      w.f_best, w.f_moved = math.max(fs, w.f_best or -1e9), game.tick
    elseif game.tick - w.f_moved >= M.STALL then
      local gate
      for k = 2, #w.crumbs do
        local c = w.crumbs[k]
        if c.gate and c.gate.s >= fs - M.CRUMB then gate = c.gate; break end
      end
      local ahead = api.ahead and api.ahead(F, fr[1])
      local text = string.format('#%d made no progress for %ds at %s, %.0f tiles behind #%d on its steps%s%s; #%d goes on alone (its route stays); #%d stops there (its route cleared)',
        F.unit_number, math.floor((game.tick - w.f_moved) / 60), at(F.position), w.lead_s - fs, L.unit_number,
        gate and string.format(', at %s that #%d crossed', gate.line, L.unit_number) or '', ahead and '; on the straight line ahead: ' .. ahead or '', L.unit_number, F.unit_number)
      return M.release(pr, text, {stalled='follower', at={x=F.position.x, y=F.position.y}})
    end
    -- both arrived: the lead's route ended and every step it is due is walked
    if lead_done then
      if w.hold then w.hold = nil end
      if #fr == 0 and not fpend then
        local gap = dist(L.position, F.position)
        pr.done = {walk=w.id, tick=game.tick, lead={x=L.position.x, y=L.position.y}, follower={x=F.position.x, y=F.position.y}, gap=gap, holds=w.holds}
        say(pr, string.format('%s arrived: #%d at %s, #%d at %s (%.0f tiles apart)%s', name(pr), L.unit_number, at(L.position), F.unit_number, at(F.position), gap,
          w.holds > 0 and string.format('; #%d waited %d time%s for #%d', L.unit_number, w.holds, w.holds == 1 and '' or 's', F.unit_number) or ''))
        api.unadopt(F, false)
        pr.walk = nil
      end
      return
    end
    -- the lead waits: the follower too far behind, or a gate between them the lead is distance + GATE_PAST past (a
    -- wait with a gate between them is said once as a wait at that gate)
    local lag = w.lead_s - fs
    local gate
    for k = 2, #w.crumbs do
      local g = w.crumbs[k].gate
      if g and fs < g.s and g.s <= w.lead_s then gate = g; break end
    end
    local want = lag > pr.dist + M.SLACK or (w.hold and lag > pr.dist + M.RESUME) or (gate and w.lead_s >= gate.s + pr.dist + M.GATE_PAST)
    if want and gate then
      want = 'past ' .. gate.line .. ' for #' .. F.unit_number .. ' to cross it'
      if not w.said[gate.line] then
        w.said[gate.line] = true
        say(pr, string.format('%s: #%d waits past %s for #%d to cross it', name(pr), L.unit_number, gate.line, F.unit_number))
      end
    elseif want then
      want = string.format('for #%d, %.0f tiles behind on its steps', F.unit_number, lag)
    end
    if want and not w.hold then
      if api.hold(L, want) then w.hold = {why=want, tick=game.tick}; w.holds = w.holds + 1 end
    elseif want then
      w.hold.why = want
    elseif w.hold then
      api.resume(L)
      w.hold = nil
    end
  end
  -- Every EVERY ticks: each pair walking.
  function M.tick()
    local st = api.state().spiderpairs
    if not (st and next(st.list)) then return end
    for key, off in pairs(st.offers) do if game.tick - off.tick > M.OFFER then st.offers[key] = nil end end
    for _, pr in pairs(st.list) do
      local L, F = ent(pr.lead), ent(pr.follower)
      if not (L and F) then M.release(pr, string.format('#%d is gone', L and pr.follower or pr.lead), {keep_l=not L, keep_f=not F})
      elseif pr.walk then step(pr, L, F) end
    end
  end
  -- spiderroute.set on a spidertron of a pair (go_to or clear by any call): the lead's go_to moves both, its clear stops
  -- both; the follower's route set ends the pair. -> the reply's pair lines, or nil.
  function M.on_set(spider, a, by)
    local pr = M.of(spider.unit_number)
    if not pr then return nil end
    local L, F = ent(pr.lead), ent(pr.follower)
    if not (L and F) then return nil end
    if spider.unit_number == pr.follower then
      local why = string.format('%s set #%d\'s route (%s): a call on the follower ends the pair; #%d goes on alone (its route stays)', by, F.unit_number, a.go_to ~= nil and 'go_to' or 'clear', L.unit_number)
      M.release(pr, why, {keep_f=true})
      return {released=why}
    end
    if a.go_to ~= nil and pr.walk and a.mode == 'append' then
      pr.seq_l = api.seq(L.unit_number)
      return {line=M.line(pr), note='appended: #' .. F.unit_number .. ' goes on following its steps'}
    end
    if a.go_to ~= nil and #api.route(L) > 0 then
      local out = M.start(pr, L, F)
      out.line, out.rule = M.line(pr), select(2, M.rule(L, F))
      return out
    end
    if pr.walk then
      pr.walk = nil
      api.unadopt(F, true)
    end
    pr.seq_l = api.seq(L.unit_number)
    return {line=M.line(pr), note=string.format('#%d stops where it stands (its route cleared)', F.unit_number)}
  end
  -- This agent's pairs, for its status.
  function M.mine(who)
    local out = {}
    local st = api.state().spiderpairs
    for _, pr in pairs(st and st.list or {}) do
      for _, a in ipairs(pr.agents) do if a == who then out[#out + 1] = M.line(pr); break end end
    end
    for _, off in pairs(st and st.offers or {}) do
      if off.agreed[who] then out[#out + 1] = string.format('asked to pair #%d (lead) and #%d (follower) %s ago: waits for the other agent\'s same call', off.lead, off.follower, math.floor((game.tick - off.tick) / 60) .. 's') end
    end
    table.sort(out)
    return out
  end
  -- The pair now: {id, walk} of the lead's walk (a waited go_to keeps it), or nil.
  function M.walk_of(unit)
    local pr = M.of(unit)
    if pr and pr.lead == unit and pr.walk then return {id=pr.id, walk=pr.walk.id} end
  end
  -- A waited go_to of the lead: 'arrived' (both), 'stalled' (the follower; the pair split), 'walking' (the lead may have
  -- arrived; the follower not yet), or nil (the pair has no part in it now: released otherwise, or a new walk).
  function M.watch(action)
    local st = api.state().spiderpairs
    if not st then return nil end
    local pr = st.list[action.pair]
    if pr and pr.done and pr.done.walk == action.walk then action.pair_done = pr.done; return 'arrived' end
    if pr and pr.walk and pr.walk.id == action.walk then return 'walking' end
    local e = ended(action.pair, action.walk)
    if e then
      action.pair_end = e
      if e.stalled then return 'stalled' end
    end
    return nil
  end
  -- The waited go_to's last: the pair's part.
  function M.finish(action, last)
    local d, e = action.pair_done, action.pair_end
    if d then
      last.pair = string.format('both arrived: #%d at %s, its follower at %s (%.0f tiles apart)%s', action.unit, at(d.lead), at(d.follower), d.gap,
        d.holds > 0 and string.format('; it waited %d time%s for its follower', d.holds, d.holds == 1 and '' or 's') or '')
      return
    end
    if e then
      last.pair = string.format('pair %d ended %ds after this go_to: %s', e.id, math.floor((e.tick - action.start_tick) / 60), e.why)
      if e.stalled then last.why = (e.stalled == 'follower' and 'its follower stalled: ' or '') .. e.why; last.stalled_one = e.stalled; last.stalled_at = e.at end
      return
    end
    local pr = api.state().spiderpairs and api.state().spiderpairs.list[action.pair]
    if pr then last.pair = M.line(pr) end
  end
  -- vehicle {pair: {lead, follower, distance}} (or pair: false with vehicle): resolve(ref) -> the spidertron by remote
  -- view. Either spidertron another agent's (M.owner): an offer until each such agent makes the same call (OFFER ticks).
  function M.call(a, me, resolve)
    local st = store()
    if a.pair == false then
      if a.vehicle == nil then error('pair: false goes with vehicle: either spidertron of the pair (its unit_number or {x,y})', 0) end
      local e = resolve(a.vehicle)
      local pr = M.of(e.unit_number)
      if not pr then
        local n = 0
        for key, off in pairs(st.offers) do if off.lead == e.unit_number or off.follower == e.unit_number then st.offers[key] = nil; n = n + 1 end end
        if n > 0 then return {withdrawn=string.format('%d offer%s to pair spidertron #%d withdrawn', n, n == 1 and '' or 's', e.unit_number)} end
        error(string.format('spidertron #%d is in no pair', e.unit_number), 0)
      end
      local text = name(pr)
      M.release(pr, string.format('%s ended it (vehicle {pair: false})%s', me, pr.walk and string.format('; #%d goes on alone (its route stays); #%d stops where it stands (its route cleared)', pr.lead, pr.follower) or ''))
      return {released=text}
    end
    if type(a.pair) ~= 'table' or a.pair.lead == nil or a.pair.follower == nil then
      error('pair is {lead, follower, distance} (lead and follower: a spidertron\'s unit_number or {x,y}, by remote view in a chunk our force sees; distance ' .. M.DIST_MIN .. '..' .. M.DIST_MAX .. ' tiles, default ' .. M.DIST .. '), or false with vehicle to end one', 0)
    end
    for k in pairs(a.pair) do
      if k ~= 'lead' and k ~= 'follower' and k ~= 'distance' then error('pair takes lead, follower and distance; not ' .. tostring(k), 0) end
    end
    local D = a.pair.distance == nil and M.DIST or a.pair.distance
    if type(D) ~= 'number' or D < M.DIST_MIN or D > M.DIST_MAX then error('distance is ' .. M.DIST_MIN .. '..' .. M.DIST_MAX .. ' tiles (along the lead\'s steps)', 0) end
    local L, F = resolve(a.pair.lead), resolve(a.pair.follower)
    if L == F or L.unit_number == F.unit_number then error('lead and follower are two spidertrons', 0) end
    if L.surface ~= F.surface then error(string.format('#%d is on %s and #%d on %s: a pair walks on one surface', L.unit_number, L.surface.name, F.unit_number, F.surface.name), 0) end
    for _, e in ipairs({L, F}) do
      local pr = M.of(e.unit_number)
      if pr and not (pr.lead == L.unit_number and pr.follower == F.unit_number) then
        error(string.format('spidertron #%d is in %s: vehicle {pair: false, vehicle: %d} ends it first', e.unit_number, name(pr), e.unit_number), 0)
      end
    end
    local pr = M.of(L.unit_number)
    if pr then
      pr.dist = D
      return {pair=M.line(pr), note='already paired; distance ' .. D .. ' tiles'}
    end
    for _, e in ipairs({L, F}) do
      local why = api.busy and api.busy(e)
      if why then error(string.format('spidertron #%d: %s', e.unit_number, why), 0) end
    end
    local others, order = {}, {}
    for _, e in ipairs({L, F}) do
      local o, how = M.owner(e)
      if o and o ~= me and not others[o] then others[o] = string.format('#%d: %s %s', e.unit_number, o, how); order[#order + 1] = o end
    end
    local key = L.unit_number .. '>' .. F.unit_number
    local off = st.offers[key]
    if off and game.tick - off.tick > M.OFFER then off = nil end
    if #order > 0 then
      off = off or {tick=game.tick, agreed={}, lead=L.unit_number, follower=F.unit_number}
      off.agreed[me] = true
      local wait = {}
      for _, o in ipairs(order) do
        if not off.agreed[o] then
          wait[#wait + 1] = others[o]
          api.say(string.format('%s asks to pair spidertron #%d (lead) and #%d (follower), %d tiles apart: vehicle {pair: {lead: %d, follower: %d}} agrees, within %d min of the ask; vehicle {pair: false, vehicle: %d} declines',
            me, L.unit_number, F.unit_number, D, L.unit_number, F.unit_number, math.floor(M.OFFER / 3600), L.unit_number), o, L.unit_number)
        end
      end
      if #wait > 0 then
        st.offers[key] = off
        return {offered=string.format('#%d (lead) and #%d (follower): each spidertron another agent has is paired once that agent makes the same call (within %d min): %s', L.unit_number, F.unit_number, math.floor(M.OFFER / 3600), table.concat(wait, '; '))}
      end
    end
    st.offers[key] = nil
    local agents = {me}
    for o in pairs(off and off.agreed or {}) do if o ~= me then agents[#agents + 1] = o end end
    table.sort(agents, function(x, y) if x == me or y == me then return x == me end return x < y end)
    st.seq = st.seq + 1
    pr = {id=st.seq, lead=L.unit_number, follower=F.unit_number, dist=D, agents=agents, tick=game.tick}
    st.list[pr.id], st.by_unit[L.unit_number], st.by_unit[F.unit_number] = pr, pr.id, pr.id
    local out = {pair=M.line(pr), rule=select(2, M.rule(L, F))}
    if #api.route(L) > 0 then
      local s = M.start(pr, L, F)
      out.join, out.gates, out.pair = s.join, s.gates, M.line(pr)
    end
    return out
  end
  return M
end
