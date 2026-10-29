-- platform_defense {platform, aim=true, seconds, positions?}: what each railgun shot was aimed at (d29 batch332 RT, Sol
-- #2734: "Native hit_by classes cannot identify which asteroid a round was aimed at ... Need safe evidence before
-- changing targets"). A bounded read-only watch of 1..MAX railguns for MIN_S..MAX_S, read every tick. Nothing changes
-- in the world or the targeting.
-- What 2.0.77 gives, measured on the iMac copy of world n (Resolute at the Aquilo edge leg, 32 railguns, 27 shots):
-- - a shot: the turret's ammo inventory one item less (railgun ammo: one item a shot) and its 10 MJ buffer emptied, seen
--   by the next tick's read; an inserter refilling in that tick can hide the item, not the buffer, so a buffer drop of
--   more than half the turret's capacity counts too;
-- - the aim: LuaEntity.shooting_target, read every tick. On the tick a shot is seen it already reads nil (the target
--   died) and the previous tick's target is invalid, so each railgun's target is kept (unit number, name, position)
--   from every read, and a shot's aimed target is the one kept on the tick before it;
-- - the hits: on_entity_damaged with the railgun as cause (its unit number), on the tick before the shot is seen: a
--   railgun's line hits everything on it at once, so the aimed asteroid and others on the line (piercing). In 27 of 27
--   shots the kept target was among that shot's hits; every railgun hit belonged to a shot.
-- So per shot: exact when the kept target is among the shot's hits (aimed hit: killed or not; the other hits are
-- collateral, by size); uncertain when nothing was kept or the kept target is not among them (it changed target within
-- the tick, or missed: aimed_not_hit_alive counts the kept target still alive after the shot). Hits by a watched
-- railgun on no seen shot are unattributed. Not given: anything about shots of railguns not watched, and the game's own
-- reason for a target choice.
return function(api)
  local M = {}
  M.MAX, M.MIN_S, M.MAX_S, M.KEEP_SHOTS, M.KEEP_TICKS = 8, 10, 120, 24, 216000
  M.ARGS = {aim='optional true: a railgun aim watch on that platform instead (d29 batch332): with seconds (10..120) it starts one, without it reads yours: 1..8 railguns (positions, else the first 8 by position) read every tick: per railgun shots and ammo used, each shot\'s aimed target (the one it read the tick before) as exact when that shot hit it, else uncertain, aimed hits by size (killed or survived), the shot\'s other hits as collateral by size, hits on no seen shot (unattributed), the last 24 shots; one watch an agent, a new one replaces it; read only'}
  local SIZES = {'small', 'medium', 'big', 'huge'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store() local s = api.state(); s.rail_aim = s.rail_aim or {}; return s.rail_aim end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  -- 'medium-oxide-asteroid' -> 'medium'; another name (a chunk, a modded asteroid) -> 'other'
  function M.size(name)
    local s = type(name) == 'string' and name:match('^(%a+)%-') or nil
    for _, k in ipairs(SIZES) do if s == k then return k end end
    return 'other'
  end
  local function bump(t, k, n) t[k] = (t[k] or 0) + (n or 1) end
  local function sizes(m)
    local o = {}
    for _, k in ipairs{'small', 'medium', 'big', 'huge', 'other'} do if m[k] then o[#o+1] = k .. ' ' .. m[k] end end
    return #o > 0 and table.concat(o, ', ') or 'none'
  end
  local function new_row(e, i)
    return {i=i, e=e, un=e.unit_number, position={x=e.position.x, y=e.position.y}, quality=try(function() return e.quality.name end) or 'normal',
      inv=e.get_inventory(defines.inventory.turret_ammo), cap=try(function() return e.electric_buffer_size end) or 0,
      shots=0, ammo_used=0, exact=0, uncertain=0, no_target=0, aimed_by_size={}, aimed_killed=0, aimed_survived=0,
      aimed_not_hit_alive=0, collateral_by_size={}, collateral_killed=0, hits=0, unattributed=0, pending={}, recent={}}
  end
  -- one tick's read of one railgun; t: its row
  function M.read(job, t, tick)
    local e = t.e
    if not (e and e.valid) then
      if not t.gone then t.gone = tick end
      return
    end
    local n = t.inv.valid and t.inv.get_item_count() or 0
    local en = e.energy
    if t.n ~= nil then
      local dn = t.n - n
      local drop = t.en - en
      local shots = dn > 0 and dn or ((t.cap > 0 and drop > t.cap / 2) and 1 or 0)
      if shots > 0 then M.shot(job, t, tick, shots) end
    end
    -- hits gathered since the last read with no shot seen now: unattributed
    if #t.pending > 0 then t.unattributed = t.unattributed + #t.pending; t.pending = {} end
    -- the target kept (unit number, name, position), re-read only when it changed: the next read's shot was aimed at it
    local tg = e.shooting_target
    if tg and tg.valid then
      if not (t.kept and t.kept_ref and t.kept_ref.valid and t.kept_ref == tg) then
        t.kept_ref = tg
        t.kept = {un=tg.unit_number, name=tg.name, x=tg.position.x, y=tg.position.y, since=tick}
      end
    else
      t.kept_ref, t.kept = nil, nil
    end
    t.n, t.en = n, en
  end
  -- a shot seen at tick: its hits are the ones gathered since the last read (the tick before)
  function M.shot(job, t, tick, shots)
    t.shots = t.shots + shots
    t.ammo_used = t.ammo_used + shots
    local aim, ref = t.kept, t.kept_ref
    local hits = t.pending
    t.pending = {}
    local row = {tick=tick - 1, hits=#hits}
    local found
    if aim then
      for _, h in ipairs(hits) do if h.un == aim.un then found = h end end
    end
    if not aim then
      t.no_target = t.no_target + 1
      t.uncertain = t.uncertain + 1
      row.aimed, row.attribution = nil, 'uncertain: no target read the tick before'
    elseif found then
      t.exact = t.exact + 1
      bump(t.aimed_by_size, M.size(aim.name))
      if found.hp <= 0 then t.aimed_killed = t.aimed_killed + 1 else t.aimed_survived = t.aimed_survived + 1 end
      row.aimed, row.attribution, row.aimed_killed = aim.name, 'exact', found.hp <= 0
    else
      t.uncertain = t.uncertain + 1
      if ref and ref.valid then t.aimed_not_hit_alive = t.aimed_not_hit_alive + 1 end
      row.aimed, row.attribution = aim.name, (ref and ref.valid) and 'uncertain: the target read the tick before was not hit and is alive'
        or 'uncertain: the target read the tick before was not among the hits'
    end
    row.position = aim and {x=aim.x, y=aim.y} or nil
    local coll = {}
    for _, h in ipairs(hits) do
      t.hits = t.hits + 1
      if not (found and h == found) then
        bump(t.collateral_by_size, M.size(h.name))
        if h.hp <= 0 then t.collateral_killed = t.collateral_killed + 1 end
        coll[#coll+1] = h.name
      end
    end
    row.collateral = #coll > 0 and coll or nil
    local r = t.recent
    r[#r+1] = row
    if #r > M.KEEP_SHOTS then table.remove(r, 1); t.recent_more = (t.recent_more or 0) + 1 end
  end
  -- on_entity_damaged: a watched railgun's hit, kept for the next read (the shot's tick)
  function M.on_damaged(event)
    local c = event.cause
    if not (c and c.valid and c.type == 'ammo-turret') then return end
    local un = c.unit_number
    for _, job in pairs(store()) do
      local t = job.live and job.by_un[un]
      if t then
        local e = event.entity
        t.pending[#t.pending+1] = {un=e.valid and e.unit_number or nil, name=e.valid and e.name or '?', hp=event.final_health}
        if #t.pending > 64 then table.remove(t.pending, 1) end
      end
    end
  end
  function M.tick(tick)
    for idx, job in pairs(store()) do
      if job.live then
        for _, t in ipairs(job.rails) do M.read(job, t, tick) end
        job.samples = job.samples + 1
        if tick >= job.until_tick then job.live, job.ended = false, tick end
      elseif job.ended and tick > job.ended + M.KEEP_TICKS then
        store()[idx] = nil
      end
    end
  end
  function M.result(job)
    local rows, tot = {}, {shots=0, ammo_used=0, exact=0, uncertain=0, aimed_by_size={}, collateral_by_size={}, hits=0, unattributed=0,
      aimed_killed=0, aimed_survived=0, aimed_not_hit_alive=0, collateral_killed=0}
    local lines = {}
    for _, t in ipairs(job.rails) do
      for _, k in ipairs{'shots', 'ammo_used', 'exact', 'uncertain', 'hits', 'unattributed', 'aimed_killed', 'aimed_survived', 'aimed_not_hit_alive', 'collateral_killed'} do
        tot[k] = tot[k] + t[k]
      end
      for k, v in pairs(t.aimed_by_size) do bump(tot.aimed_by_size, k, v) end
      for k, v in pairs(t.collateral_by_size) do bump(tot.collateral_by_size, k, v) end
      rows[#rows+1] = {position=t.position, quality=t.quality, shots=t.shots, ammo_used=t.ammo_used, exact=t.exact, uncertain=t.uncertain,
        no_target=t.no_target, aimed_by_size=t.aimed_by_size, aimed_killed=t.aimed_killed, aimed_survived=t.aimed_survived,
        aimed_not_hit_alive=t.aimed_not_hit_alive, collateral_by_size=t.collateral_by_size, collateral_killed=t.collateral_killed,
        hits=t.hits, unattributed=t.unattributed, gone_tick=t.gone, recent=t.recent, recent_more=t.recent_more}
      lines[#lines+1] = string.format('railgun %s (%s): %d shots (%d ammo); aimed, exact %d: %s (killed %d, survived %d); uncertain %d; collateral hits: %s (killed %d)%s%s',
        at(t.position), t.quality, t.shots, t.ammo_used, t.exact, sizes(t.aimed_by_size), t.aimed_killed, t.aimed_survived, t.uncertain,
        sizes(t.collateral_by_size), t.collateral_killed, t.unattributed > 0 and string.format('; %d hits on no seen shot', t.unattributed) or '',
        t.gone and string.format('; gone at tick %d', t.gone) or '')
    end
    table.insert(lines, 1, string.format('%s: %d railguns, ticks %d..%d (%s): %d shots, %d ammo used; aimed (exact) %s; uncertain %d; collateral %s; hits %d (%d unattributed)',
      job.platform, #job.rails, job.start, job.until_tick, job.live and 'running' or 'done', tot.shots, tot.ammo_used, sizes(tot.aimed_by_size),
      tot.uncertain, sizes(tot.collateral_by_size), tot.hits, tot.unattributed))
    return {aim=true, platform=job.platform, start_tick=job.start, end_tick=job.until_tick, seconds=job.seconds, every_ticks=1, samples=job.samples,
      done=not job.live, picked=job.picked, railguns_total=job.total, railguns=rows, totals=tot, lines=lines, reason=job.reason,
      attribution='per shot: exact when the target the railgun read the tick before the shot is among that shot\'s hits (on_entity_damaged with the railgun as cause); the other hits are collateral; uncertain otherwise (no target read, or it was not hit: changed target within the tick, or missed). ammo_used: items that left its ammo slots at a shot (one a shot)',
      not_given='the game\'s reason for a target choice; shots of railguns not watched'}
  end
  function M.handler(p, a)
    assert(a.aim == true, 'aim: true')
    local st = store()
    local idx = p.index
    if a.seconds == nil then
      assert(a.positions == nil, 'positions go with seconds: platform_defense {platform, aim: true, seconds} starts a watch')
      local job = st[idx]
      assert(job, 'no railgun aim watch of yours yet: platform_defense {platform, aim: true, seconds: 10..120, positions?} starts one')
      return M.result(job)
    end
    if a.reason ~= nil then api.reason(a.reason) end
    local seconds = a.seconds
    assert(type(seconds) == 'number' and seconds >= M.MIN_S and seconds <= M.MAX_S and seconds == math.floor(seconds),
      string.format('seconds: %d..%d with aim (every tick)', M.MIN_S, M.MAX_S))
    assert(a.platform ~= nil, 'platform_defense {platform, aim: true, seconds} starts the watch; platform_defense {aim: true} reads it')
    local s = api.on_platform(p, a.platform).surface
    local pl = s.platform
    -- railguns: railgun-turret by name (a name find, not every ammo turret of the hull: 18.7 ms by type on Resolute)
    local picked, total = {}, nil
    if a.positions ~= nil then
      assert(type(a.positions) == 'table' and #a.positions >= 1 and #a.positions <= M.MAX, string.format('positions: 1..%d {x, y} of railguns', M.MAX))
      for i, q in ipairs(a.positions) do
        assert(type(q) == 'table' and type(q.x) == 'number' and type(q.y) == 'number', string.format('positions[%d]: {x, y}', i))
        local found = s.find_entities_filtered{name='railgun-turret', force=p.force, position={q.x, q.y}, radius=2}
        local best, bd
        for _, e in ipairs(found) do
          local d = (e.position.x - q.x) ^ 2 + (e.position.y - q.y) ^ 2
          if not bd or d < bd then best, bd = e, d end
        end
        assert(best, string.format('positions[%d] %s: no railgun turret within 2 tiles on %s', i, at(q), pl.name))
        picked[#picked+1] = best
      end
    else
      local rails = s.find_entities_filtered{name='railgun-turret', force=p.force}
      assert(#rails > 0, string.format('%s has no railgun turrets', pl.name))
      table.sort(rails, function(x, y) if x.position.y ~= y.position.y then return x.position.y < y.position.y end return x.position.x < y.position.x end)
      for i = 1, math.min(M.MAX, #rails) do picked[i] = rails[i] end
      total = #rails
    end
    local job = {platform=pl.name, surface=s.index, start=game.tick, until_tick=game.tick + seconds * 60 - 1, seconds=seconds, samples=0,
      rails={}, by_un={}, live=true, total=total, reason=a.reason,
      picked=total and (total > M.MAX and string.format('the first %d of %d railguns by position (north first): positions picks others', M.MAX, total) or string.format('all %d railguns', total)) or 'by positions'}
    for i, e in ipairs(picked) do
      if not job.by_un[e.unit_number] then
        local t = new_row(e, i)
        job.rails[#job.rails+1] = t
        job.by_un[e.unit_number] = t
      end
    end
    local replaced = st[idx] ~= nil
    st[idx] = job
    for _, t in ipairs(job.rails) do M.read(job, t, game.tick) end
    job.samples = 1
    return {aim=true, started=true, platform=pl.name, railguns=#job.rails, picked=job.picked, start_tick=job.start, end_tick=job.until_tick, seconds=seconds,
      replaced=replaced or nil, line=string.format('railgun aim watch on %s: %d railguns %s, every tick for %d s (to tick %d)%s; platform_defense {aim: true} reads it',
        pl.name, #job.rails, table.concat((function() local o = {} for _, t in ipairs(job.rails) do o[#o+1] = at(t.position) end return o end)(), ' '),
        seconds, job.until_tick, replaced and '; your earlier aim watch is replaced' or '')}
  end
  return M
end
