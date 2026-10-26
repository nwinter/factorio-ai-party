-- signal_watch {position, surface | platform, wire, side?, signals, seconds}: a bounded watch (measures kind
-- signal_watch) of named signals on one circuit network (d24 batch140 PL1, Sol #2116: Petrel's zero-hub trial needed the
-- whole-loop calcite minimum on belt (-13.5,4.5)'s green network 815 through flight and coasting; flight_watch reads
-- fuel and ammunition, an inspect now and then can miss a brief low, and a queue's inspect reads one moment). Read only.
-- - the network: the one on an entity's red or green wire connector (a two-sided combinator's input or output side), as
--   a player hovering over that wire sees it; 1..MAX_SIGNALS signals named as inspect's `signals` names them
--   (circuits.lua parse_signals);
-- - every SAMPLE ticks, from the start: one get_signal per signal (0 when absent, the game's own count);
-- - each signal's start, end, min and max, each with its tick (min and max: the first tick that value was seen; on a
--   platform, where the platform was then);
-- - gaps: samples with nothing to read (no network on that wire: a wire cut or its network gone), a change of network
--   id (the wire joined to another network), and the end when the entity or its surface is gone.
-- One watch an agent; a new one replaces it and says so. signal_watch {} reads it so far, and in full once done.
return function(api)
  local M = {}
  M.SAMPLE, M.MAX_SIGNALS, M.MIN_S, M.MAX_S, M.MAX_GAPS = 60, 8, 10, 3600, 32
  local TWO_SIDED = {['arithmetic-combinator']=true, ['decider-combinator']=true, ['selector-combinator']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store() local s = api.state(); s.signal_watch = s.signal_watch or {}; return s.signal_watch end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  -- The connector id of a wire colour and side on e, and its key as inspect names it (green, red_input, ...).
  local function connector(e, wire, side)
    local W = defines.wire_connector_id
    assert(wire == 'red' or wire == 'green', 'wire: red or green')
    if TWO_SIDED[e.type] then
      assert(side == 'input' or side == 'output', string.format('side: input or output (%s has both)', e.name))
      local id = side == 'input' and (wire == 'red' and W.combinator_input_red or W.combinator_input_green)
        or (wire == 'red' and W.combinator_output_red or W.combinator_output_green)
      return id, wire .. '_' .. side
    end
    assert(side == nil, string.format('side: only for a combinator with an input and an output side; %s has one', e.name))
    return wire == 'red' and W.circuit_red or W.circuit_green, wire
  end
  -- Where a platform was at a tick: flying from-to, or at a location, and its speed.
  local function place(job)
    if not job.platform then return nil end
    local s = game.surfaces[job.surface]
    local pl = s and s.valid and s.platform
    if not pl then return nil end
    local c = try(function() return pl.space_connection end)
    local where = c and string.format('flying %s-%s', c.from.name, c.to.name)
      or (try(function() return pl.space_location.name end) and 'at ' .. pl.space_location.name) or 'in space'
    local v = try(function() return pl.speed end)
    return v and string.format('%s, %g km/s', where, math.floor(v * 60 * 10 + 0.5) / 10) or where
  end
  -- a gap row, MAX_GAPS kept (gaps_more past them)
  local function add_gap(job, row)
    if #job.gaps < M.MAX_GAPS then job.gaps[#job.gaps+1] = row else job.gaps_more = (job.gaps_more or 0) + 1 end
  end
  local function gap_close(job, tick)
    if not job.gap then return end
    add_gap(job, {why=job.gap.why, from_tick=job.gap.from, to_tick=tick, missed=job.gap.missed})
    job.gap = nil
  end
  -- One sample: the network on the wire, then one get_signal per signal.
  function M.sample(job, tick)
    local e = job.e
    if not (e and e.valid) then
      local s = game.surfaces[job.surface]
      job.gone = (s and s.valid) and 'the entity is gone' or 'its surface is gone'
      job.gone_tick = tick
      return
    end
    local net = e.get_circuit_network(job.cid)
    if not net then
      job.gap = job.gap or {why=string.format('no %s network on that wire (wire cut, or no wire)', job.key), from=tick, missed=0}
      job.gap.missed = job.gap.missed + 1
      job.missed = job.missed + 1
      return
    end
    gap_close(job, tick)
    local id = net.network_id
    if id ~= job.network_id then
      add_gap(job, {why=string.format('network changed: #%s to #%s', tostring(job.network_id), tostring(id)), from_tick=tick, to_tick=tick, missed=0})
      job.network_id = id
    end
    for i, pk in ipairs(job.picks) do
      local n = net.get_signal(pk.id)
      local st = job.stats[i]
      if not st.c0 then st.c0, st.t0, st.mn, st.tmn, st.mx, st.tmx = n, tick, n, tick, n, tick
      else
        if n < st.mn then st.mn, st.tmn, st.wmn = n, tick, true end
        if n > st.mx then st.mx, st.tmx, st.wmx = n, tick, true end
      end
      st.c1, st.t1 = n, tick
    end
    -- where the platform was at a new min or max: read at most once a sample, only when one was set
    if job.platform then
      local w
      for _, st in ipairs(job.stats) do
        if st.t0 == tick then st.wmn, st.wmx = true, true end
        if st.wmn or st.wmx then
          w = w or place(job) or '?'
          if st.wmn then st.pmn = w end
          if st.wmx then st.pmx = w end
          st.wmn, st.wmx = nil, nil
        end
      end
    end
    job.samples = job.samples + 1
    job.sampled = tick
  end
  function M.result(job, done)
    local rows, lines = {}, {}
    for i, pk in ipairs(job.picks) do
      local st = job.stats[i]
      local r = {name=pk.text}
      if st.c0 then
        r.start = {count=st.c0, tick=st.t0}
        r['end'] = {count=st.c1, tick=st.t1}
        r.min = {count=st.mn, tick=st.tmn, where=st.pmn}
        r.max = {count=st.mx, tick=st.tmx, where=st.pmx}
        r.line = string.format('%s: start %d (tick %d), end %d (tick %d), min %d (tick %d%s), max %d (tick %d%s)', pk.text,
          st.c0, st.t0, st.c1, st.t1, st.mn, st.tmn, st.pmn and ', ' .. st.pmn or '', st.mx, st.tmx, st.pmx and ', ' .. st.pmx or '')
      else
        r.line = pk.text .. ': no sample read'
      end
      rows[i] = r
      lines[i] = r.line
    end
    local gaps = {}
    for i, g in ipairs(job.gaps) do gaps[i] = g end
    if job.gap then gaps[#gaps+1] = {why=job.gap.why, from_tick=job.gap.from, to_tick=nil, missed=job.gap.missed, open=true} end
    local gap_lines = {}
    for i, g in ipairs(gaps) do
      gap_lines[i] = g.from_tick == g.to_tick and string.format('tick %d: %s', g.from_tick, g.why)
        or string.format('ticks %d-%s: %s (%d sample%s missed)', g.from_tick, g.to_tick and tostring(g.to_tick) or 'now', g.why, g.missed, g.missed == 1 and '' or 's')
    end
    if job.gaps_more then gap_lines[#gap_lines+1] = string.format('%d more gaps not kept', job.gaps_more) end
    if job.gone then gap_lines[#gap_lines+1] = string.format('tick %d: %s; the watch ended there', job.gone_tick, job.gone) end
    local out = {watching=not done or nil, done=done or nil, id=job.id or string.format('signal_watch@%d', job.start), scope=job.scope,
      entity={name=job.name, position=job.position}, surface=job.surface_name, platform=job.platform, wire=job.key,
      network_id=job.network_id, start_tick=job.start, end_tick=job.until_tick, seconds=job.seconds, every_ticks=M.SAMPLE,
      samples=job.samples, missed=job.missed > 0 and job.missed or nil, last_tick=job.sampled,
      ended=job.gone and {tick=job.gone_tick, why=job.gone} or nil, signals=rows, signal_lines=lines,
      gaps=#gaps > 0 and gaps or nil, gaps_more=job.gaps_more, gap_lines=#gap_lines > 0 and gap_lines or nil, reason=job.reason}
    out.line = string.format('%s %s: %d sample%s every %d ticks from tick %d%s; %s%s', out.id, job.scope, job.samples, job.samples == 1 and '' or 's', M.SAMPLE, job.start,
      done and string.format(' to tick %d', job.gone_tick or job.until_tick) or string.format(', running until tick %d', job.until_tick),
      table.concat(lines, '; '), #gap_lines > 0 and '; gaps: ' .. table.concat(gap_lines, '; ') or '; no gaps')
    out.note = M.NOTE
    return out
  end
  M.NOTE = 'each sample is the network\'s own count of each signal (get_signal: 0 when absent), as a player hovering over that wire sees it, every 60 ticks; '
    .. 'a value held for less than 60 ticks can fall between two samples; min and max give the first tick each was seen'
  -- (d25 batch215 QZ3) the watch's id, its owner named (measures.id): signal_watch@START_TICK/AGENT
  local function ident(job, index) if api.watch_id and index then api.watch_id('signal_watch', job, index) end end
  local function finish(job, tick, index)
    ident(job, index)
    gap_close(job, tick)
    job.result = M.result(job, true)
    job.e = nil
  end
  function M.tick(tick)
    local all = api.state().signal_watch
    if not all then return end
    for index, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        M.sample(job, tick)
        if job.gone or tick >= job.until_tick then finish(job, tick, index)
        else job.next_tick = math.min(tick + M.SAMPLE, job.until_tick) end
      end
    end
  end
  function M.handler(p, a)
    a = a or {}
    if a.position == nil and a.seconds == nil then
      assert(a.signals == nil and a.wire == nil and a.surface == nil and a.platform == nil,
        'position, wire, signals and seconds start a watch; signal_watch {} reads yours')
      local job = store()[p.index]
      assert(job, 'no signal watch of yours yet: signal_watch {position, surface | platform, wire, side?, signals, seconds} starts one')
      ident(job, p.index)
      if job.result then job.read_tick = game.tick; return job.result end
      return M.result(job, false)
    end
    local seconds = a.seconds
    assert(type(seconds) == 'number' and seconds >= M.MIN_S and seconds <= M.MAX_S and seconds == math.floor(seconds),
      string.format('seconds: %d..%d', M.MIN_S, M.MAX_S))
    assert(type(a.position) == 'table', 'position: {x, y} of the entity whose wire to read')
    if type(a.signals) == 'table' and not (a.signals.name or a.signals.type) then
      assert(#a.signals <= M.MAX_SIGNALS, string.format('signals: 1..%d names', M.MAX_SIGNALS))
    end
    local picks = api.parse_signals(a.signals, 'signals')
    assert(#picks <= M.MAX_SIGNALS, string.format('signals: 1..%d names', M.MAX_SIGNALS))
    local reason = api.reason and api.reason(a.reason)
    local q = a.surface ~= nil and api.on_surface(p, a.surface) or a.platform ~= nil and api.on_platform(p, a.platform) or p
    local e = api.remote_entity(q, {position=a.position})
    local cid, key = connector(e, a.wire, a.side)
    local net = e.get_circuit_network(cid)
    assert(net, string.format('%s %s has no %s network on that wire', e.name, at(e.position), key))
    local pl = try(function() return e.surface.platform end)
    local names = {}
    for i, pk in ipairs(picks) do names[i] = pk.text end
    local job = {start=game.tick, until_tick=game.tick + seconds * 60, next_tick=game.tick, seconds=seconds, samples=0, missed=0,
      e=e, cid=cid, key=key, wire=a.wire, name=e.name, position={x=e.position.x, y=e.position.y}, surface=e.surface.index,
      surface_name=e.surface.name, platform=pl and pl.name or nil, network_id=net.network_id, picks=picks, stats={}, gaps={}, reason=reason}
    for i = 1, #picks do job.stats[i] = {} end
    job.scope = string.format('%s on the %s network #%d of %s %s on %s', table.concat(names, ', '), key, net.network_id, e.name,
      at(e.position), pl and pl.name or e.surface.name)
    local old = store()[p.index]
    local replaced = old and string.format('your earlier signal watch (%s, %s) was replaced', old.scope or '?', old.result and 'done' or 'still running')
    store()[p.index] = job
    ident(job, p.index)
    M.sample(job, game.tick)
    job.next_tick = game.tick + M.SAMPLE
    local now = {}
    for i, pk in ipairs(picks) do now[i] = string.format('%s %s', pk.text, tostring(job.stats[i].c1 or '?')) end
    return {watching=true, id=job.id or string.format('signal_watch@%d', job.start), scope=job.scope, network_id=job.network_id, start_tick=job.start,
      end_tick=job.until_tick, every_ticks=M.SAMPLE, now=table.concat(now, ', '), replaced=replaced,
      line=string.format('watching %s for %d s, a sample every %d ticks until tick %d: signal_watch {} reads it so far, and in full once done; now %s',
        job.scope, seconds, M.SAMPLE, job.until_tick, table.concat(now, ', '))}
  end
  M.schema = {signal_watch = {position='{x, y}: the entity whose wire to read (with seconds: starts a watch; signal_watch {} reads yours)',
    surface='optional planet or surface name (remote view)', platform='optional platform name: the entity on that platform',
    wire='red or green', side='input or output: only on a combinator with both sides (arithmetic, decider, selector)',
    signals='1..8 signal names as inspect\'s signals takes them ("calcite", "signal-R", "iron-plate@rare", "recipe:NAME", {type, name, quality}), a list or one string with | or ,',
    seconds='10..3600: how long to watch', reason='optional text, up to 200 characters: your own reason to wait for it, shown with the watch in your sleep line, sleep_check and the operator\'s idle check',
    returns='the start: id, scope, network_id, start_tick, end_tick, now (each signal\'s count now), line; signal_watch {} reads it so far (watching) or done: samples (one every 60 ticks), missed, '
      .. 'signals [{name, start {count, tick}, end {count, tick}, min {count, tick, where}, max {count, tick, where}, line}] (min and max: the first tick that count was seen; where: the platform then, flying or at a location, and its speed), '
      .. 'signal_lines, gaps [{why (no network on that wire, network changed), from_tick, to_tick, missed}] and gap_lines, ended {tick, why} (the entity or its surface gone), line, note. '
      .. 'One watch an agent: a new one replaces it (replaced). Read only'}}
  return M
end
