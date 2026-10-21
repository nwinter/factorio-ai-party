-- A turret's kills and damage dealt, as its tooltip shows a player (LuaEntity.kills and damage_dealt in 2.0.77), in
-- inspect, and turret_tally {positions | area, seconds?}: a bounded watch of up to MAX turrets giving each one's counts
-- at the start and the end and the change, zero changes included (d20 batch60 V3, Astra #1521: a Tesla trial saw 17-18
-- attackers inside range, powered turrets and no breach, and nothing said which turret fought). Read once a second, so
-- a turret destroyed or mined during the watch keeps its change up to its last read. Read on the private copy (2.0.77,
-- a test surface): both counts read on ammo, electric (laser, tesla) and fluid turrets and artillery; damage_dealt is
-- the sum of each hit after the target's resistances, overkill included (a gun turret: 66 hits of 23.8 on three
-- 500-health worms, 1570.8 dealt; a tesla turret: 120 a hit on 15-health biters); a tesla's chain, an explosive
-- rocket's splash and a flamethrower's stream and the fire it lays are the turret's (each within 0.2% of the health
-- its targets lost over the same window); a kill is the entity's whose hit destroyed the target (a gun and a laser on
-- three worms: the gun 3 kills and 1166 dealt, the laser 0 and 384); trees and rocks the splash hits count (one
-- explosive rocket: 3 trees destroyed counted 3 kills, a rock's 380 lost in the damage); two trees beside a
-- flamethrower's worm caught fire and burned down after it died with no change to the turret's counts; the counts are the entity's (a turret mined and placed
-- again from its item read 0 and 0).
return function(api)
  local M = {}
  M.MAX, M.AREA_SIDE = 64, 200
  M.TYPES = {'ammo-turret', 'electric-turret', 'fluid-turret', 'artillery-turret', 'artillery-wagon'}
  local IS = {}
  for _, t in ipairs(M.TYPES) do IS[t] = true end
  M.NOTE = 'the counts are the turret\'s own since it was placed, as its tooltip shows (Kills, Damage dealt): damage dealt is each hit after the target\'s resistances, overkill included; '
    .. 'a tesla\'s chain, a rocket\'s splash and a flamethrower\'s stream and the fire it lays count for the turret; a kill counts for the one whose hit destroyed the target, not the others that damaged it; '
    .. 'trees and rocks a splash hits count in both, the same as enemies (a tree destroyed is a kill); trees set alight near its targets that burned down did not count; a turret mined or rebuilt starts again at 0'
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function store() local s = api.state(); s.turret_tally = s.turret_tally or {}; return s.turret_tally end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  function M.is_turret(e) return e and e.valid and IS[e.type] or false end
  -- {kills, damage_dealt} of a built turret, artillery turret or artillery wagon; nil for anything else.
  function M.read(e)
    if not M.is_turret(e) then return nil end
    local k, d = try(function() return e.kills end), try(function() return e.damage_dealt end)
    if type(k) ~= 'number' or type(d) ~= 'number' then return nil end
    return {kills=k, damage_dealt=r1(d)}
  end
  function M.text(r) return string.format('kills %d, damage dealt %g', r.kills, r.damage_dealt) end
  function M.in_area(q, a)
    local ar = a.area
    local lt, rb = type(ar) == 'table' and (ar.left_top or ar[1]), type(ar) == 'table' and (ar.right_bottom or ar[2])
    local x0, y0 = lt and (lt.x or lt[1]), lt and (lt.y or lt[2])
    local x1, y1 = rb and (rb.x or rb[1]), rb and (rb.y or rb[2])
    assert(type(x0) == 'number' and type(y0) == 'number' and type(x1) == 'number' and type(y1) == 'number' and x1 > x0 and y1 > y0,
      'area: {left_top={x,y}, right_bottom={x,y}}')
    assert(x1 - x0 <= M.AREA_SIDE and y1 - y0 <= M.AREA_SIDE, 'area: at most ' .. M.AREA_SIDE .. ' tiles a side')
    assert(a.name == nil or type(a.name) == 'string', 'name: a turret name')
    local found = q.surface.find_entities_filtered{area={{x0, y0}, {x1, y1}}, type=M.TYPES, name=a.name, force=q.force, limit=M.MAX + 1}
    assert(#found >= 1, string.format('no turret of ours%s in that area', a.name and ' named ' .. a.name or ''))
    assert(#found <= M.MAX, string.format('more than %d turrets in that area: at most %d (a smaller area, or name one)', M.MAX, M.MAX))
    local out = {}
    for _, e in ipairs(found) do out[#out+1] = {position=e.position, unit_number=e.unit_number} end
    return out
  end
  function M.sample(job, tick)
    for _, t in ipairs(job.turrets) do
      if not t.gone then
        local r = t.e and M.read(t.e)
        if r then
          if r.kills ~= t.k1 or r.damage_dealt ~= t.d1 then
            t.first = t.first or tick
            t.last = tick
            t.rising = t.rising + 1
          end
          t.k1, t.d1 = r.kills, r.damage_dealt
        else
          t.gone = tick
          t.e = nil
        end
      end
    end
    job.samples = job.samples + 1
    -- (d20 batch70 AF1) when it was last read, and whether a turret is left to read (measures.lua: the idle count)
    local live = false
    for _, t in ipairs(job.turrets) do if not t.gone then live = true; break end end
    job.sampled, job.all_gone = tick, not live or nil
  end
  local function secs(job, tick) return math.floor((tick - job.start) / 6 + 0.5) / 10 end
  function M.result(job, done)
    local now = done and job.until_tick or game.tick
    local rows, lines, by, order = {}, {}, {}, {}
    local fought, kills, dmg = 0, 0, 0
    for _, t in ipairs(job.turrets) do
      local dk, dd = t.k1 - t.k0, r1(t.d1 - t.d0)
      if dk ~= 0 or dd ~= 0 then fought = fought + 1 end
      kills, dmg = kills + dk, dmg + dd
      local row = {name=t.name, position=t.position, quality=t.quality ~= 'normal' and t.quality or nil, kills_start=t.k0, kills_end=t.k1, kills_change=dk,
        damage_start=t.d0, damage_end=t.d1, damage_change=dd,
        first_change_s=t.first and secs(job, t.first) or nil, last_change_s=t.last and secs(job, t.last) or nil,
        seconds_changing=t.rising, gone_s=t.gone and secs(job, t.gone) or nil}
      rows[#rows+1] = row
      local when = t.first and string.format(' (rising in %d of %d one-second reads, first at +%gs, last at +%gs)', t.rising, job.samples - 1, row.first_change_s, row.last_change_s) or ''
      lines[#lines+1] = string.format('%s%s %s: kills %d -> %d (%+d), damage dealt %g -> %g (%+g)%s%s', t.name,
        row.quality and ' (' .. row.quality .. ')' or '', at(t.position), t.k0, t.k1, dk, t.d0, t.d1, dd,
        (dk == 0 and dd == 0) and ': no change' or when,
        t.gone and string.format('; gone at +%gs (not read since: its counts went with it)', row.gone_s) or '')
      local g = by[t.name]
      if not g then g = {name=t.name, turrets=0, changed=0, kills=0, damage=0}; by[t.name] = g; order[#order+1] = t.name end
      g.turrets = g.turrets + 1
      g.changed = g.changed + ((dk ~= 0 or dd ~= 0) and 1 or 0)
      g.kills, g.damage = g.kills + dk, r1(g.damage + dd)
    end
    local groups = {}
    for _, n in ipairs(order) do
      local g = by[n]
      groups[#groups+1] = g
      g.line = string.format('%s x%d: %d with a change, %d without; kills %+d, damage dealt %+g', n, g.turrets, g.changed, g.turrets - g.changed, g.kills, g.damage)
    end
    local s = secs(job, now)
    return {watching=not done or nil, done=done or nil, seconds=job.seconds, seconds_watched=s, start_tick=job.start, end_tick=done and job.until_tick or nil,
      turrets=rows, groups=groups, kills_change=kills, damage_change=r1(dmg), changed=fought, unchanged=#job.turrets - fought, lines=lines,
      line=string.format('%s %d turret%s for %gs%s: %d with a change in kills or damage dealt, %d without; kills %+d, damage dealt %+g in all', done and 'watched' or 'watching',
        #job.turrets, #job.turrets == 1 and '' or 's', s, done and '' or string.format(' of %ds', job.seconds), fought, #job.turrets - fought, kills, r1(dmg)),
      note=M.NOTE}
  end
  function M.tick(tick)
    local all = api.state().turret_tally
    if not all then return end
    for _, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        M.sample(job, tick)
        if tick >= job.until_tick then
          job.result = M.result(job, true)
          job.turrets = nil
        else
          job.next_tick = math.min(tick + 60, job.until_tick)
        end
      end
    end
  end
  function M.handler(p, a)
    if a.positions == nil and a.position == nil and a.area == nil then
      local job = store()[p.index]
      assert(job, 'no turret_tally watch yet: turret_tally {positions, seconds?}')
      if job.result then job.read_tick = game.tick end  -- its final read (measures.lua)
      return job.result or M.result(job, false)
    end
    local seconds = a.seconds == nil and 120 or a.seconds
    assert(type(seconds) == 'number' and seconds >= 5 and seconds <= 3600 and seconds == math.floor(seconds), 'seconds: 5..3600 (default 120)')
    local reason = api.reason and api.reason(a.reason)  -- (d20 batch70 AF1) its own reason to wait (measures.lua)
    local q = a.surface ~= nil and api.on_surface(p, a.surface) or a.platform ~= nil and api.on_platform(p, a.platform) or p
    local list = a.positions or a.position and {a.position} or M.in_area(q, a)
    assert(type(list) == 'table' and #list >= 1 and #list <= M.MAX, 'positions: 1..' .. M.MAX .. ' turrets {x,y} (or area {left_top, right_bottom})')
    local turrets, seen = {}, {}
    for _, pos in ipairs(list) do
      local e = api.remote_entity(q, {position=pos.position or pos, unit_number=pos.unit_number})
      local r = M.read(e)
      assert(r, string.format('%s %s is not a built turret (an ammo, electric or fluid turret, an artillery turret or wagon)', e.name, at(e.position)))
      if not seen[e.unit_number] then
        seen[e.unit_number] = true
        turrets[#turrets+1] = {e=e, name=e.name, position={x=e.position.x, y=e.position.y}, quality=try(function() return e.quality.name end) or 'normal',
          k0=r.kills, d0=r.damage_dealt, k1=r.kills, d1=r.damage_dealt, rising=0}
      end
    end
    local replaced = store()[p.index] and not store()[p.index].result
    local job = {start=game.tick, until_tick=game.tick + seconds * 60, next_tick=game.tick + 60, seconds=seconds, samples=1, turrets=turrets, reason=reason}
    store()[p.index] = job
    local lines = {}
    for _, t in ipairs(turrets) do lines[#lines+1] = string.format('%s %s: %s so far', t.name, at(t.position), M.text({kills=t.k0, damage_dealt=t.d0})) end
    return {watching=true, seconds=seconds, start_tick=job.start, turrets=#turrets, baseline=lines, replaced=replaced and 'your earlier watch, still running, was replaced' or nil,
      line=string.format('watching %d turret%s for %ds, their kills and damage dealt read once a second: turret_tally {} reads it so far, and in full once done', #turrets, #turrets == 1 and '' or 's', seconds),
      note=M.NOTE}
  end
  M.schema = {turret_tally = {reason='optional text, up to 200 characters: your own reason to wait for it, shown with the watch in your sleep line, sleep_check and the operator\'s idle check', positions='1..64 turrets {x,y} (ammo, electric or fluid turrets, artillery turrets or wagons; in sight or by remote view)', position='or one',
    area='or {left_top={x,y}, right_bottom={x,y}} (up to 200 tiles a side): the turrets of ours in it, up to 64', name='optional with area: only turrets of this name',
    seconds='optional 5..3600 (default 120): how long to watch', surface='optional planet name (by remote view)', platform='optional platform name',
    returns='a watch, one an agent (a new one replaces it): the start returns baseline (each turret\'s kills and damage dealt so far) and line; turret_tally {} reads it so far (watching) or done: turrets [{name, position, quality, kills_start, kills_end, kills_change, damage_start, damage_end, damage_change, first_change_s and last_change_s (seconds into the watch of the first and last read with a change), seconds_changing (one-second reads with a change), gone_s (destroyed or mined: its change up to its last read)}] with no change said as no change, groups (by name: turrets, changed, kills, damage), changed, unchanged, kills_change, damage_change, lines, line, note (what the counts take in and leave out). Read only; the counts are the ones the turret\'s tooltip shows'}}
  return M
end
