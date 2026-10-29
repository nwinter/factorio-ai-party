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
-- (d28 batch316 SW, Sol #2703: Resolute's adaptive pilot pulses its pumps 1-2 ticks in each 10-tick clock period, and a
-- sample every 60 ticks reads the same phase every time) signal_watch {entities, seconds}: a duty watch of 1..8
-- entities for 10..60 s, each one's status read every tick (on the iMac copy of world n: about 0.2 us an entity, 0.55
-- us a get_signal on a held network, so this one rather than signals every tick): its ticks by status, enabled (any
-- status but disabled_by_control_behavior) as ticks and a share, the runs enabled and disabled by length, the ticks
-- between one enable and the next, each 60-tick window's enabled ticks (min and max), the transitions (count, the first
-- and last DUTY_EDGES with their ticks) and the runs cut by the window. Histograms keep DUTY_KEYS lengths each (the rest
-- counted together). Read only; ended and freed at its end.
-- (d28 batch327 AG, Sol #2719: "Resolute bow railgun emptied for 271 ticks despite global rail>1600 ... ~0.64 s inspect
-- polls ... miss short arrivals; native flight_watch only samples turrets 1s") signal_watch {triples, seconds}: an ammo
-- gap watch of 1..AMMO_MAX {turret, inserter, pickup} for 10..120 s, read every tick: the turret's ammo (the items of
-- its ammo inventory), the inserter's hand and status, and the pickup's count of the turret's ammo (the inserter's
-- pickup_target unless named: a belt, chest or platform hub; get_item_count, on a belt its transport lines' count). Per
-- triple: the turret's ticks empty, the inserter's ticks with no source (waiting_for_source_items with an empty hand) and
-- the pickup's ticks with none, each with its longest run and start tick, runs by length (DUTY_KEYS kept), the first and
-- last DUTY_EDGES transitions; ammo, hand and pickup min and max; the inserter's ticks by status; context: the turret's
-- ammo slots, the ammo's stack size and the turret's automated_ammo_count (what inserters fill it to), the inserter's
-- stack size override and the most it held, the pickup's kind and slots. Read only; one watch an agent, as the others.
return function(api)
  local M = {}
  M.SAMPLE, M.MAX_SIGNALS, M.MIN_S, M.MAX_S, M.MAX_GAPS = 60, 8, 10, 3600, 32
  M.DUTY_MAX, M.DUTY_MIN_S, M.DUTY_MAX_S, M.DUTY_KEYS, M.DUTY_EDGES, M.DUTY_WINDOW = 8, 10, 60, 24, 8, 60
  M.AMMO_MAX, M.AMMO_MIN_S, M.AMMO_MAX_S = 4, 10, 120
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
  -- (batch316 SW) the duty watch
  local names_of
  local function status_name(v)
    if not names_of then
      names_of = {}
      for k, x in pairs(defines.entity_status or {}) do names_of[x] = k end
    end
    return v == -1 and 'none' or names_of[v] or ('status ' .. tostring(v))
  end
  -- a histogram {[length] = count}: DUTY_KEYS lengths, the rest in other {count, min, max}
  local function hist(h, len)
    if h.n[len] then h.n[len] = h.n[len] + 1
    elseif h.keys < M.DUTY_KEYS then h.n[len], h.keys = 1, h.keys + 1
    else
      local o = h.other or {count=0, min=len, max=len}
      o.count, o.min, o.max = o.count + 1, math.min(o.min, len), math.max(o.max, len)
      h.other = o
    end
  end
  local function new_hist() return {n={}, keys=0} end
  local function edge(d, tick, on)
    d.transitions = d.transitions + 1
    local row = {tick=tick, to=on and 'enabled' or 'disabled'}
    if #d.first_edges < M.DUTY_EDGES then d.first_edges[#d.first_edges+1] = row end
    d.last_edges[(d.transitions - 1) % M.DUTY_EDGES + 1] = row
  end
  function M.duty_sample(job, tick)
    local dbcb = defines.entity_status.disabled_by_control_behavior
    local close = (tick - job.start + 1) % M.DUTY_WINDOW == 0
    local live = 0
    for _, d in ipairs(job.ents) do
      local e = d.e
      if e and not e.valid then d.gone_tick, d.e, e = tick, nil, nil end
      if e then
        live = live + 1
        local s = e.status or -1  -- none: an entity without a status (a wall)
        d.st[s] = (d.st[s] or 0) + 1
        d.ticks = d.ticks + 1
        local on = s ~= dbcb
        if on then d.on_ticks, d.win = d.on_ticks + 1, d.win + 1 end
        if d.on == nil then d.on, d.run0, d.cut0 = on, tick, true
        elseif on ~= d.on then
          local len = tick - d.run0
          if d.cut0 then d.open_start, d.cut0 = {enabled=d.on, ticks=len}, nil
          else
            hist(d.on and d.runs_on or d.runs_off, len)
            local best = d.on and d.long_on or d.long_off
            if not best.ticks or len > best.ticks then best.ticks, best.from_tick = len, d.run0 end
          end
          if on then
            if d.rise then hist(d.gaps, tick - d.rise) end
            d.rise = tick
          end
          edge(d, tick, on)
          d.on, d.run0 = on, tick
        end
        if close then
          if not d.wmin or d.win < d.wmin.enabled_ticks then d.wmin = {enabled_ticks=d.win, from_tick=tick - M.DUTY_WINDOW + 1} end
          if not d.wmax or d.win > d.wmax.enabled_ticks then d.wmax = {enabled_ticks=d.win, from_tick=tick - M.DUTY_WINDOW + 1} end
          d.windows, d.win = d.windows + 1, 0
        end
      end
    end
    if live == 0 then job.gone, job.gone_tick = 'every entity is gone', tick end
    job.samples = job.samples + 1
    job.sampled = tick
  end
  local function rows_of(h)
    local out = {}
    for len, c in pairs(h.n) do out[#out+1] = {ticks=len, count=c} end
    table.sort(out, function(a, b) return a.ticks < b.ticks end)
    return out, h.other
  end
  local function hist_text(h, what)
    local rows, other = rows_of(h)
    local t = {}
    for _, r in ipairs(rows) do t[#t+1] = string.format('%d x%d', r.ticks, r.count) end
    if other then t[#t+1] = string.format('%d more %d-%d', other.count, other.min, other.max) end
    return #t > 0 and what .. ' ' .. table.concat(t, ', ') or nil
  end
  function M.duty_result(job, done)
    local ents, lines = {}, {}
    local to = done and (job.gone_tick or job.until_tick) or job.sampled
    for i, d in ipairs(job.ents) do
      local st, st_list = {}, {}
      for v, n in pairs(d.st) do st[status_name(v)] = n; st_list[#st_list+1] = {status_name(v), n} end
      table.sort(st_list, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
      local on_rows, on_other = rows_of(d.runs_on)
      local off_rows, off_other = rows_of(d.runs_off)
      local gap_rows, gap_other = rows_of(d.gaps)
      local open_end = d.on ~= nil and {enabled=d.on, ticks=(to or d.run0) - d.run0 + 1} or nil
      if d.cut0 then open_end = nil end  -- no transition: the whole window is one run (open_start below)
      local r = {name=d.name, position=d.position, ticks=d.ticks, enabled_ticks=d.on_ticks,
        enabled_share=d.ticks > 0 and math.floor(d.on_ticks / d.ticks * 10000 + 0.5) / 10000 or nil, status=st,
        transitions=d.transitions, enabled_runs=on_rows, enabled_runs_other=on_other, disabled_runs=off_rows, disabled_runs_other=off_other,
        enable_every=gap_rows, enable_every_other=gap_other, longest_enabled=d.long_on.ticks and d.long_on or nil,
        longest_disabled=d.long_off.ticks and d.long_off or nil,
        windows={count=d.windows, ticks=M.DUTY_WINDOW, min=d.wmin, max=d.wmax},
        open_start=d.open_start or (d.cut0 and d.on ~= nil and {enabled=d.on, ticks=d.ticks, whole_window=true}) or nil, open_end=open_end,
        first_transitions=#d.first_edges > 0 and d.first_edges or nil, gone_tick=d.gone_tick}
      local last = {}
      for k = 1, math.min(d.transitions, M.DUTY_EDGES) do last[k] = d.last_edges[(d.transitions - math.min(d.transitions, M.DUTY_EDGES) + k - 1) % M.DUTY_EDGES + 1] end
      r.last_transitions = #last > 0 and last or nil
      local parts = {string.format('%s %s: enabled %d of %d ticks (%s%%)', d.name, at(d.position), d.on_ticks, d.ticks,
        d.ticks > 0 and string.format('%.1f', d.on_ticks / d.ticks * 100) or '-')}
      parts[#parts+1] = hist_text(d.runs_on, 'enabled runs (ticks x times)')
      parts[#parts+1] = hist_text(d.runs_off, 'disabled runs')
      parts[#parts+1] = hist_text(d.gaps, 'enabled again after')
      if d.wmin then parts[#parts+1] = string.format('per %d-tick window %d-%d enabled ticks (least from tick %d, most from tick %d)', M.DUTY_WINDOW,
        d.wmin.enabled_ticks, d.wmax.enabled_ticks, d.wmin.from_tick, d.wmax.from_tick) end
      parts[#parts+1] = d.transitions > 0 and string.format('%d transitions, ticks %d to %d', d.transitions, d.first_edges[1].tick, last[#last].tick)
        or string.format('no transition: %s the whole window', d.on and 'enabled' or 'disabled')
      local sl = {}
      for _, x in ipairs(st_list) do sl[#sl+1] = string.format('%s %d', x[1], x[2]) end
      parts[#parts+1] = 'status ' .. table.concat(sl, ', ')
      if d.gone_tick then parts[#parts+1] = string.format('gone at tick %d', d.gone_tick) end
      r.line = table.concat(parts, '; ')
      ents[i], lines[i] = r, r.line
    end
    local out = {watching=not done or nil, done=done or nil, id=job.id or string.format('signal_watch@%d', job.start), scope=job.scope, duty=true,
      surface=job.surface_name, platform=job.platform, start_tick=job.start, end_tick=job.until_tick, seconds=job.seconds, every_ticks=1,
      samples=job.samples, last_tick=job.sampled, ended=job.gone and {tick=job.gone_tick, why=job.gone} or nil, entities=ents, entity_lines=lines, reason=job.reason}
    out.line = string.format('%s %s: every tick from tick %d%s (%d ticks); %s', out.id, job.scope, job.start,
      done and string.format(' to tick %d', to or job.until_tick) or string.format(', running until tick %d', job.until_tick), job.samples, table.concat(lines, ' | '))
    out.note = M.DUTY_NOTE
    return out
  end
  M.DUTY_NOTE = 'each entity\'s status every tick (the game\'s, as its window shows it): enabled is any status but disabled_by_control_behavior; '
    .. 'a circuit condition takes effect on the tick after it is met (on Resolute\'s copy: fulfilled at C=0, the pump working at C=1); '
    .. 'runs are counted between two transitions (the runs cut by the window\'s start and end are open_start and open_end); '
    .. 'enabled again after: the ticks from one enable to the next; windows: 60-tick windows from the start, whole ones only'

  -- (batch327 AG) the ammo gap watch: a run tracker of one condition (empty, no source, none at the pickup), every tick
  local function run_new() return {ticks=0, edges=0, runs=new_hist(), longest={}, first={}, last={}} end
  local function run_end(r, tick)
    local len = tick - r.run0
    if not r.cut0 then hist(r.runs, len) end
    if not r.longest.ticks or len > r.longest.ticks then r.longest = {ticks=len, from_tick=r.run0, to_tick=tick - 1, began_before=r.cut0 or nil} end
  end
  local function run_step(r, on, tick)
    if on then r.ticks = r.ticks + 1 end
    if r.on == nil then r.on, r.run0, r.cut0 = on, tick, true; return end
    if on == r.on then return end
    if r.on then run_end(r, tick) end
    r.cut0 = nil
    r.edges = r.edges + 1
    local row = {tick=tick, to=on}
    if #r.first < M.DUTY_EDGES then r.first[#r.first+1] = row end
    r.last[(r.edges - 1) % M.DUTY_EDGES + 1] = row
    r.on, r.run0 = on, tick
  end
  -- min and max of a count: the first tick each was seen
  local function span(m, n, tick)
    if not m.min or n < m.min.count then m.min = {count=n, tick=tick} end
    if not m.max or n > m.max.count then m.max = {count=n, tick=tick} end
  end
  local WAIT_SOURCE
  function M.ammo_sample(job, tick)
    WAIT_SOURCE = WAIT_SOURCE or defines.entity_status.waiting_for_source_items
    local live = 0
    for _, t in ipairs(job.triples) do
      local tu, ins, pk = t.turret, t.inserter, t.pickup
      if tu and not (tu.valid and ins.valid and (not pk or pk.valid)) then t.gone_tick, t.turret, t.inserter, t.pickup, tu = tick, nil, nil, nil, nil end
      if tu then
        live = live + 1
        t.ticks = t.ticks + 1
        local a = t.inv.get_item_count()
        span(t.ammo, a, tick)
        run_step(t.empty, a == 0, tick)
        local h = ins.held_stack
        local held = h.valid_for_read and h.count or 0
        span(t.hand, held, tick)
        local st = ins.status or -1
        t.st[st] = (t.st[st] or 0) + 1
        run_step(t.nosource, st == WAIT_SOURCE and held == 0, tick)
        if pk then
          local n = pk.get_item_count(t.item)
          span(t.at_pickup, n, tick)
          run_step(t.none, n == 0, tick)
        end
      end
    end
    if live == 0 then job.gone, job.gone_tick = 'every triple is gone (a turret, inserter or pickup removed)', tick end
    job.samples = job.samples + 1
    job.sampled = tick
  end
  local function run_out(r, to, what)
    local longest = r.longest
    local open_end
    if r.on and r.run0 then
      open_end = {ticks=to - r.run0 + 1, from_tick=r.run0, began_before=r.cut0 or nil}
      if not longest.ticks or open_end.ticks > longest.ticks then longest = {ticks=open_end.ticks, from_tick=r.run0, to_tick=to, began_before=r.cut0 or nil, still=true} end
    end
    local rows, other = rows_of(r.runs)
    local last = {}
    for k = 1, math.min(r.edges, M.DUTY_EDGES) do last[k] = r.last[(r.edges - math.min(r.edges, M.DUTY_EDGES) + k - 1) % M.DUTY_EDGES + 1] end
    local text = r.ticks == 0 and ('never ' .. what) or string.format('%s %d ticks; longest %d from tick %d%s%s', what, r.ticks, longest.ticks, longest.from_tick,
      longest.began_before and ' (began before the watch)' or '', longest.still and ' (still at the end)' or '')
    local h = hist_text(r.runs, 'runs (ticks x times)')
    if h then text = text .. '; ' .. h end
    return {ticks=r.ticks, longest=longest.ticks and longest or nil, runs=rows, runs_other=other, open_end=open_end, transitions=r.edges,
      first_transitions=#r.first > 0 and r.first or nil, last_transitions=#last > 0 and last or nil}, text
  end
  local function mm(m) return m.min and string.format('%d-%d', m.min.count, m.max.count) or '-' end
  function M.ammo_result(job, done)
    local rows, lines = {}, {}
    local to = done and (job.gone_tick or job.until_tick) or job.sampled
    for i, t in ipairs(job.triples) do
      local to_t = t.gone_tick and t.gone_tick - 1 or to
      local empty, et = run_out(t.empty, to_t, 'empty')
      local nos, nt = run_out(t.nosource, to_t, 'no source')
      local none, pt = run_out(t.none, to_t, 'none at the pickup')
      local st = {}
      for v, n in pairs(t.st) do st[status_name(v)] = n end
      local r = {turret={name=t.names.turret, position=t.pos.turret}, inserter={name=t.names.inserter, position=t.pos.inserter},
        pickup=t.names.pickup and {name=t.names.pickup, position=t.pos.pickup} or nil, ammo=t.item, ticks=t.ticks,
        turret_empty=empty, no_source=nos, pickup_none=t.names.pickup and none or nil,
        turret_ammo={min=t.ammo.min, max=t.ammo.max}, hand={min=t.hand.min, max=t.hand.max}, inserter_status=st,
        at_pickup=t.names.pickup and {min=t.at_pickup.min, max=t.at_pickup.max} or nil, context=t.context, gone_tick=t.gone_tick}
      local parts = {string.format('%s %s <- %s %s%s: %d ticks', t.names.turret, at(t.pos.turret), t.names.inserter, at(t.pos.inserter),
        t.names.pickup and string.format(' <- %s %s', t.names.pickup, at(t.pos.pickup)) or ' (no pickup)', t.ticks)}
      parts[#parts+1] = string.format('turret %s (ammo %s)', et, mm(t.ammo))
      parts[#parts+1] = string.format('inserter %s (hand %s)', nt, mm(t.hand))
      if t.names.pickup then parts[#parts+1] = string.format('pickup %s (%s %s)', pt, t.item, mm(t.at_pickup)) end
      if t.gone_tick then parts[#parts+1] = string.format('gone at tick %d', t.gone_tick) end
      r.line = table.concat(parts, '; ')
      rows[i], lines[i] = r, r.line
    end
    local out = {watching=not done or nil, done=done or nil, id=job.id or string.format('signal_watch@%d', job.start), scope=job.scope, ammo_gaps=true,
      surface=job.surface_name, platform=job.platform, start_tick=job.start, end_tick=job.until_tick, seconds=job.seconds, every_ticks=1,
      samples=job.samples, last_tick=job.sampled, ended=job.gone and {tick=job.gone_tick, why=job.gone} or nil, triples=rows, triple_lines=lines, reason=job.reason}
    out.line = string.format('%s %s: every tick from tick %d%s (%d ticks); %s', out.id, job.scope, job.start,
      done and string.format(' to tick %d', to or job.until_tick) or string.format(', running until tick %d', job.until_tick), job.samples, table.concat(lines, ' | '))
    out.note = M.AMMO_NOTE
    return out
  end
  M.AMMO_NOTE = 'every tick: the turret\'s ammo inventory (every item in it), the inserter\'s hand and status, the pickup\'s count of the ammo (normal quality unless the turret held another); '
    .. 'empty: the turret holds no ammo; no source: the inserter waits for source items with an empty hand; runs are counted between two transitions, a run cut by the watch\'s start says began_before, '
    .. 'one still on at the end says still (open_end); longest includes both. Read only: nothing is changed'
  -- the turret's ammo item: named, else what its ammo inventory holds, else the one item of its ammo categories
  local function ammo_of(turret, inv, name)
    if name ~= nil then
      assert(type(name) == 'string' and prototypes.item[name] and prototypes.item[name].type == 'ammo', 'ammo: an ammo item name')
      return name
    end
    local held = try(function() return inv.get_contents() end) or {}
    if held[1] then return held[1].name, held[1].quality end
    local cats, found = {}, {}
    for _, c in ipairs(try(function() return turret.prototype.attack_parameters.ammo_categories end) or {}) do cats[c] = true end
    for n, it in pairs(prototypes.item) do
      if it.type == 'ammo' then
        local c = try(function() local x = it.ammo_category; return type(x) == 'string' and x or x.name end)
        if c and cats[c] then found[#found+1] = n end
      end
    end
    table.sort(found)
    assert(#found == 1, string.format('ammo: %s is empty and takes %s: name the ammo to count at the pickup', turret.name,
      #found > 0 and table.concat(found, ', ') or 'no ammo item'))
    return found[1]
  end
  local function ammo_start(p, a)
    assert(a.position == nil and a.wire == nil and a.side == nil and a.signals == nil and a.entities == nil,
      'triples starts an ammo gap watch; position, wire, side, signals and entities go with the other watches')
    local seconds = a.seconds
    assert(type(seconds) == 'number' and seconds >= M.AMMO_MIN_S and seconds <= M.AMMO_MAX_S and seconds == math.floor(seconds),
      string.format('seconds: %d..%d with triples (every tick)', M.AMMO_MIN_S, M.AMMO_MAX_S))
    assert(type(a.triples) == 'table' and #a.triples >= 1 and #a.triples <= M.AMMO_MAX,
      string.format('triples: 1..%d {turret, inserter, pickup?, ammo?}, each a position {x, y}', M.AMMO_MAX))
    local reason = api.reason and api.reason(a.reason)
    local q = a.surface ~= nil and api.on_surface(p, a.surface) or a.platform ~= nil and api.on_platform(p, a.platform) or p
    local triples, names, surface = {}, {}, nil
    for i, x in ipairs(a.triples) do
      assert(type(x) == 'table' and type(x.turret) == 'table' and type(x.inserter) == 'table',
        string.format('triples[%d]: {turret {x, y}, inserter {x, y}, pickup {x, y}?, ammo?}', i))
      local tu = api.remote_entity(q, {position=x.turret})
      local inv = tu.get_inventory(defines.inventory.turret_ammo)
      assert(inv, string.format('triples[%d].turret: %s %s has no ammo inventory', i, tu.name, at(tu.position)))
      local ins = api.remote_entity(q, {position=x.inserter})
      assert(ins.type == 'inserter', string.format('triples[%d].inserter: %s %s is not an inserter', i, ins.name, at(ins.position)))
      local pk
      if x.pickup ~= nil then pk = api.remote_entity(q, {position=x.pickup})
      else pk = try(function() local e = ins.pickup_target; return e and e.valid and e or nil end) end
      assert(tu.surface == ins.surface and (not pk or pk.surface == tu.surface), string.format('triples[%d]: on one surface', i))
      surface = surface or tu.surface
      assert(tu.surface == surface, 'triples: every triple on one surface')
      local item, quality = ammo_of(tu, inv, x.ammo)
      local want = (quality and quality ~= 'normal') and {name=item, quality=quality} or item
      local proto = prototypes.item[item]
      local pslots = pk and try(function() local i2 = pk.get_inventory(defines.inventory.chest) or pk.get_inventory(defines.inventory.hub_main); return i2 and #i2 end)
      local context = {turret_ammo_slots=#inv, ammo_stack_size=proto and proto.stack_size, automated_ammo_count=try(function() return tu.prototype.automated_ammo_count end),
        inserter_stack_size_override=try(function() local v = ins.inserter_stack_size_override; return v and v > 0 and v or nil end),
        pickup_kind=pk and pk.type or nil, pickup_slots=pslots, pickup_lines=pk and try(function() return pk.get_max_transport_line_index() end) or nil,
        ammo_quality=quality ~= 'normal' and quality or nil}
      local t = {turret=tu, inserter=ins, pickup=pk, inv=inv, item=want, names={turret=tu.name, inserter=ins.name, pickup=pk and pk.name or nil},
        pos={turret={x=tu.position.x, y=tu.position.y}, inserter={x=ins.position.x, y=ins.position.y}, pickup=pk and {x=pk.position.x, y=pk.position.y} or nil},
        ticks=0, st={}, ammo={}, hand={}, at_pickup={}, empty=run_new(), nosource=run_new(), none=run_new(), context=context}
      triples[#triples+1] = t
      names[#names+1] = string.format('%s %s', tu.name, at(tu.position))
    end
    local pl = try(function() return surface.platform end)
    local job = {ammo=true, start=game.tick, until_tick=game.tick + seconds * 60 - 1, next_tick=game.tick, seconds=seconds, samples=0, triples=triples,
      surface=surface.index, surface_name=surface.name, platform=pl and pl.name or nil, reason=reason}
    job.scope = string.format('the ammo gaps every tick of %s on %s', table.concat(names, ', '), pl and pl.name or surface.name)
    local old = store()[p.index]
    local replaced = old and string.format('your earlier signal watch (%s, %s) was replaced', old.scope or '?', old.result and 'done' or 'still running')
    store()[p.index] = job
    ident(job, p.index)
    M.ammo_sample(job, game.tick)
    job.next_tick = game.tick + 1
    local now = {}
    for _, t in ipairs(triples) do
      now[#now+1] = string.format('%s: ammo %d, hand %d%s', t.names.turret, t.ammo.min and t.ammo.min.count or 0, t.hand.min and t.hand.min.count or 0,
        t.pickup and string.format(', pickup %d', t.at_pickup.min and t.at_pickup.min.count or 0) or '')
    end
    return {watching=true, ammo_gaps=true, id=job.id or string.format('signal_watch@%d', job.start), scope=job.scope, start_tick=job.start,
      end_tick=job.until_tick, every_ticks=1, replaced=replaced, now=table.concat(now, '; '),
      line=string.format('watching %s for %d s (%d ticks, to tick %d): signal_watch {} reads it so far, and in full once done; now %s',
        job.scope, seconds, seconds * 60, job.until_tick, table.concat(now, '; '))}
  end
  function M.tick(tick)
    local all = api.state().signal_watch
    if not all then return end
    for index, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        if job.ammo then
          M.ammo_sample(job, tick)
          if job.gone or tick >= job.until_tick then
            ident(job, index)
            job.result = M.ammo_result(job, true)
            for _, t in ipairs(job.triples) do t.turret, t.inserter, t.pickup, t.inv = nil, nil, nil, nil end
          else job.next_tick = tick + 1 end
        elseif job.duty then
          M.duty_sample(job, tick)
          if job.gone or tick >= job.until_tick then
            ident(job, index)
            job.result = M.duty_result(job, true)
            for _, d in ipairs(job.ents) do d.e = nil end
          else job.next_tick = tick + 1 end
        else
          M.sample(job, tick)
          if job.gone or tick >= job.until_tick then finish(job, tick, index)
          else job.next_tick = math.min(tick + M.SAMPLE, job.until_tick) end
        end
      end
    end
  end
  -- signal_watch {entities, seconds}: the duty watch's start
  local function duty_start(p, a)
    assert(a.position == nil and a.wire == nil and a.side == nil and a.signals == nil,
      'entities starts a duty watch (each entity\'s status every tick); position, wire, side and signals go with a signal watch')
    local seconds = a.seconds
    assert(type(seconds) == 'number' and seconds >= M.DUTY_MIN_S and seconds <= M.DUTY_MAX_S and seconds == math.floor(seconds),
      string.format('seconds: %d..%d with entities (a status read every tick)', M.DUTY_MIN_S, M.DUTY_MAX_S))
    assert(type(a.entities) == 'table' and #a.entities >= 1 and #a.entities <= M.DUTY_MAX,
      string.format('entities: 1..%d {x, y} of the entities to read every tick', M.DUTY_MAX))
    local reason = api.reason and api.reason(a.reason)
    local q = a.surface ~= nil and api.on_surface(p, a.surface) or a.platform ~= nil and api.on_platform(p, a.platform) or p
    local ents, seen, names = {}, {}, {}
    for _, pos in ipairs(a.entities) do
      assert(type(pos) == 'table', 'entities: each {x, y}')
      local e = api.remote_entity(q, {position=pos})
      local u = e.unit_number or string.format('%g,%g', e.position.x, e.position.y)
      assert(not seen[u], string.format('entities: %s %s is named twice', e.name, at(e.position)))
      seen[u] = true
      ents[#ents+1] = {e=e, name=e.name, position={x=e.position.x, y=e.position.y}, st={}, ticks=0, on_ticks=0, win=0, windows=0,
        transitions=0, runs_on=new_hist(), runs_off=new_hist(), gaps=new_hist(), long_on={}, long_off={}, first_edges={}, last_edges={}}
      names[#names+1] = e.name .. ' ' .. at(e.position)
    end
    local e1 = ents[1].e
    local pl = try(function() return e1.surface.platform end)
    local job = {duty=true, start=game.tick, until_tick=game.tick + seconds * 60 - 1, next_tick=game.tick, seconds=seconds, samples=0, ents=ents,
      surface=e1.surface.index, surface_name=e1.surface.name, platform=pl and pl.name or nil, reason=reason}
    job.scope = string.format('the status every tick of %s on %s', table.concat(names, ', '), pl and pl.name or e1.surface.name)
    local old = store()[p.index]
    local replaced = old and string.format('your earlier signal watch (%s, %s) was replaced', old.scope or '?', old.result and 'done' or 'still running')
    store()[p.index] = job
    ident(job, p.index)
    M.duty_sample(job, game.tick)  -- its first tick now: seconds x 60 ticks read, to until_tick
    job.next_tick = game.tick + 1
    return {watching=true, duty=true, id=job.id or string.format('signal_watch@%d', job.start), scope=job.scope, start_tick=job.start,
      end_tick=job.until_tick, every_ticks=1, replaced=replaced,
      line=string.format('watching %s for %d s (%d ticks, to tick %d): signal_watch {} reads it so far, and in full once done',
        job.scope, seconds, seconds * 60, job.until_tick)}
  end
  function M.handler(p, a)
    a = a or {}
    if a.triples ~= nil then return ammo_start(p, a) end
    if a.entities ~= nil then return duty_start(p, a) end
    if a.position == nil and a.seconds == nil then
      assert(a.signals == nil and a.wire == nil and a.surface == nil and a.platform == nil,
        'position, wire, signals and seconds start a watch; signal_watch {} reads yours')
      local job = store()[p.index]
      assert(job, 'no signal watch of yours yet: signal_watch {position, surface | platform, wire, side?, signals, seconds} starts one')
      ident(job, p.index)
      if job.result then job.read_tick = game.tick; return job.result end
      return job.ammo and M.ammo_result(job, false) or job.duty and M.duty_result(job, false) or M.result(job, false)
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
    seconds='10..3600: how long to watch (10..60 with entities, 10..120 with triples)',
    triples='1..4 {turret {x, y}, inserter {x, y}, pickup {x, y}?, ammo?} (with seconds 10..120, on the platform or surface given): an ammo gap watch, read every tick: the turret\'s ammo inventory, the inserter\'s hand and status, the pickup\'s count of the ammo (pickup: the inserter\'s pickup_target unless named, a belt, chest or hub; ammo: what the turret holds, else the one ammo its categories take, else name it). Per triple: turret_empty, no_source (waiting for source items with an empty hand) and pickup_none, each {ticks, longest {ticks, from_tick, to_tick, began_before, still}, runs [{ticks, count}], runs_other, open_end, transitions, first_transitions, last_transitions [{tick, to}]}; turret_ammo, hand and at_pickup {min, max {count, tick}}; inserter_status {name: ticks}; context (turret_ammo_slots, ammo_stack_size, automated_ammo_count, inserter_stack_size_override, pickup_kind, pickup_slots, pickup_lines); line',
    entities='1..8 {x, y} (with seconds 10..60, instead of position, wire and signals): a duty watch, each entity\'s status every tick (on the platform or surface given): enabled (any status but disabled_by_control_behavior) ticks and share, ticks by status, enabled and disabled runs by length, the ticks from one enable to the next, the least and most enabled ticks in a 60-tick window, transitions (count, the first and last 8 with their ticks), the runs cut by the window (open_start, open_end)', reason='optional text, up to 200 characters: your own reason to wait for it, shown with the watch in your sleep line, sleep_check and the operator\'s idle check',
    returns='the start: id, scope, network_id, start_tick, end_tick, now (each signal\'s count now), line; signal_watch {} reads it so far (watching) or done: samples (one every 60 ticks), missed, '
      .. 'signals [{name, start {count, tick}, end {count, tick}, min {count, tick, where}, max {count, tick, where}, line}] (min and max: the first tick that count was seen; where: the platform then, flying or at a location, and its speed), '
      .. 'signal_lines, gaps [{why (no network on that wire, network changed), from_tick, to_tick, missed}] and gap_lines, ended {tick, why} (the entity or its surface gone), line, note. '
      .. 'With entities (a duty watch): entities [{name, position, ticks, enabled_ticks, enabled_share, status {name: ticks}, transitions, enabled_runs [{ticks, count}], disabled_runs, '
      .. 'enable_every [{ticks, count}] (ticks from one enable to the next), *_other {count, min, max} (lengths past the 24 kept), longest_enabled {ticks, from_tick}, longest_disabled, '
      .. 'windows {count, ticks, min {enabled_ticks, from_tick}, max}, open_start, open_end, first_transitions, last_transitions [{tick, to}], gone_tick, line}], entity_lines, note. '
      .. 'One watch an agent (a duty watch too): a new one replaces it (replaced). Read only'}}
  return M
end
