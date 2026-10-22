-- An agent's bounded watches: uptime, turret_tally, belt_flow and collector_tally (d22 batch78 AN2), one of each an agent (d20 batch70 AF1, Aurora; d21
-- 12:11: the idle nudge told Haiku it had stood idle 11 min, 72 s into a 120 s uptime watch Astra had asked of it).
-- A watch running is the agent's work: from its start to its end tick, its sampler reading it. The idle count, the
-- clock line, the sleep line and the operator's idle report (idle.lua) read it as busy with that watch, named.
-- Each watch: id (kind@start tick), scope, start and end tick, samples, the latest sample, and a state:
--   running  sampled within STALE ticks, before its end tick
--   done     its final result is in (final_read: the agent read it after the end, or not yet)
--   late     its end tick passed LATE ticks ago and no final result came (its sampler stopped); not work
--   stalled  before its end tick, no sample for STALE ticks; not work
--   invalid  nothing left to read: every machine, turret or belt point gone or out of sight at every sample, or no
--            sample (running or done); not work
return function(api)
  local M = {}
  M.LATE, M.STALE = 300, 600
  M.KINDS = {'uptime', 'turret_tally', 'belt_flow', 'collector_tally'}
  -- how each kind's final is read (default: KIND {})
  M.READ = {collector_tally='platform_supply {platform, collection: true}'}
  -- (d20 batch70 AF1, operator d21 13:18) the agent's own reason to wait, given with a watch or a sleep: up to REASON
  -- characters, shown back as given; nil when none.
  M.REASON = 200
  M.REASON_ARG = 'optional text, up to 200 characters: your own reason to wait, shown back to you and in the operator\'s idle check'
  function M.reason(v)
    if v == nil then return nil end
    assert(type(v) == 'string', 'reason: text, up to ' .. M.REASON .. ' characters')
    v = v:gsub('[\r\n]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    assert(#v <= M.REASON, 'reason: up to ' .. M.REASON .. ' characters')
    return v ~= '' and v or nil
  end
  local function at(q) return q and string.format('(%g,%g)', q.x, q.y) or '?' end
  local function pct(n, d) return d > 0 and math.floor(100 * n / d + 0.5) or 0 end
  local function jobs(kind) return (api.state()[kind] or {}) end
  -- What a watch reads (units: machines, turrets or belt points), how many are gone, its scope and latest sample.
  local DESCRIBE = {}
  function DESCRIBE.uptime(job)
    local n, gone, recipes, order, status, first = 0, 0, {}, {}, {}, nil
    for _, m in ipairs(job.machines or {}) do
      n = n + 1
      first = first or m.position
      if m.gone then gone = gone + 1 end
      local r = m.lab and 'lab' or m.recipe or 'none'
      if not recipes[r] then recipes[r] = 0; order[#order+1] = r end
      recipes[r] = recipes[r] + 1
      for st, k in pairs(m.status or {}) do status[st] = (status[st] or 0) + k end
    end
    local parts = {}
    for i, r in ipairs(order) do if i <= 3 then parts[#parts+1] = r .. ' ' .. recipes[r] end end
    if #order > 3 then parts[#parts+1] = (#order - 3) .. ' more' end
    -- a statistics watch: its items (uptime.flows_start rows, one per item and quality)
    local items, seen = {}, {}
    for _, f in ipairs(job.flows and job.flows.rows or {}) do
      if f.name and not seen[f.name] then seen[f.name] = true; items[#items+1] = f.name end
    end
    local scope = n > 0 and string.format('%d machine%s (%s) from %s', n, n == 1 and '' or 's', table.concat(parts, ', '), at(first)) or ''
    if #items > 0 then scope = scope .. (n > 0 and '; ' or '') .. 'items ' .. table.concat(items, ', ') end
    local total, shares = 0, {}
    for _, k in pairs(status) do total = total + k end
    for st, k in pairs(status) do shares[#shares+1] = {st, k} end
    table.sort(shares, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local said = {}
    for i, s in ipairs(shares) do if i <= 3 then said[#said+1] = string.format('%s %d%%', (s[1]:gsub('_', ' ')), pct(s[2], total)) end end
    return {units=n, gone=gone, scope=scope ~= '' and scope or 'nothing',
      sample=#said > 0 and 'machine samples ' .. table.concat(said, ', ') or (#items > 0 and 'production statistics' or nil),
      empty=n == 0 and #items == 0}
  end
  function DESCRIBE.turret_tally(job)
    local n, gone, changed, kills, first = 0, 0, 0, 0, nil
    for _, t in ipairs(job.turrets or {}) do
      n = n + 1
      first = first or t.position
      if t.gone then gone = gone + 1 end
      if t.first then changed = changed + 1 end
      kills = kills + ((t.k1 or 0) - (t.k0 or 0))
    end
    -- done: its turrets are let go, the result has their rows
    if not job.turrets and job.result then
      for _, t in ipairs(job.result.turrets or {}) do
        n = n + 1
        first = first or t.position
        if t.gone_s then gone = gone + 1 end
      end
      changed, kills = job.result.changed or 0, job.result.kills_change or 0
    end
    return {units=n, gone=gone, scope=string.format('%d turret%s from %s', n, n == 1 and '' or 's', at(first)),
      sample=string.format('%d of %d turrets with a change, kills %+d', changed, n, kills), empty=n == 0}
  end
  function DESCRIBE.belt_flow(job)
    local scope = string.format('belt line %s to %s (%s tiles) on %s', at(job.path_from), at(job.path_to), tostring(job.tiles or '?'), tostring(job.surface_name or job.surface or '?'))
    local n, gone, passed = 0, 0, 0
    if job.points then
      for _, pt in ipairs(job.points) do
        n = n + 1
        if pt.gone or (pt.unseen or 0) >= (job.samples or 0) and (job.samples or 0) > 0 then gone = gone + 1 end
        for k = 1, 2 do for _ in pairs(pt.left and pt.left[k] or {}) do passed = passed + 1 end end
      end
    elseif job.result then
      for _, row in ipairs(job.result.points or {}) do
        n = n + 1
        if row.gone or row.out_of_sight and row.out_of_sight:find('^out of sight %(') then gone = gone + 1 end
      end
    end
    return {units=n, gone=gone, scope=scope, sample=job.points and string.format('%d items passed the sampled tiles', passed) or nil, empty=n == 0}
  end
  -- (d22 batch78 AN2) a platform's collectors: collectreach.lua
  function DESCRIBE.collector_tally(job)
    local n, gone, seen = 0, 0, 0
    for _, c in ipairs(job.collectors or {}) do
      n = n + 1
      if c.gone then gone = gone + 1 end
      seen = seen + (c.taken or 0)
    end
    if not job.collectors and job.result then
      n, seen = #(job.result.collectors or {}), job.result.taken_seen or 0
      for _, c in ipairs(job.result.collectors or {}) do if c.gone_s then gone = gone + 1 end end
    end
    return {units=n, gone=gone, scope=string.format('%d collector%s on %s', n, n == 1 and '' or 's', tostring(job.platform)),
      sample=string.format('%d chunks seen taken', seen), empty=n == 0}
  end
  -- One watch's row; tick = now.
  local function row(kind, job, tick)
    local d = DESCRIBE[kind](job)
    local sampled = job.sampled
    local state
    if (job.samples or 0) == 0 and job.result or d.empty or d.units > 0 and d.gone >= d.units then state = 'invalid'
    elseif job.result then state = 'done'
    elseif tick > job.until_tick + M.LATE then state = 'late'
    elseif sampled and tick - sampled > M.STALE then state = 'stalled'
    else state = 'running' end
    local r = {id=kind .. '@' .. job.start, kind=kind, scope=d.scope, start_tick=job.start, end_tick=job.until_tick, state=state,
      samples=job.samples or 0, gone=d.gone > 0 and d.gone or nil, of=d.units,
      latest=sampled and {tick=sampled, s_ago=math.floor((tick - sampled) / 60), line=d.sample} or (d.sample and {line=d.sample}) or nil,
      final_read=nil}
    if job.result then r.final_read = (job.read_tick or -1) >= job.until_tick end
    r.reason = job.reason
    local left = math.max(0, math.ceil((job.until_tick - tick) / 60))
    local why = {
      running=string.format('running in the background until tick %d (%d s more): your actions meanwhile do not end it', job.until_tick, left),
      done=string.format('done at tick %d, its final %s', job.until_tick, r.final_read and 'read' or 'not read yet (' .. (M.READ[kind] or kind .. ' {}') .. ' reads it)'),
      late=string.format('late: its end tick %d passed %d s ago and no final result came; it is not counted as work', job.until_tick, math.floor((tick - job.until_tick) / 60)),
      stalled=string.format('stalled: no sample for %d s before its end tick %d; it is not counted as work', math.floor((tick - (sampled or job.start)) / 60), job.until_tick),
      invalid=d.empty and 'invalid: it reads nothing' or (job.samples or 0) == 0 and 'invalid: no sample taken'
        or string.format('invalid: all %d of what it reads gone or out of sight; it is not counted as work', d.units)}
    r.line = string.format('%s %s: %s; %d sample%s%s%s', r.id, d.scope, why[state], r.samples, r.samples == 1 and '' or 's',
      state ~= 'invalid' and d.gone > 0 and string.format(', %d of %d gone or out of sight', d.gone, d.units) or '',
      r.latest and r.latest.line and string.format('; latest%s: %s', r.latest.s_ago and string.format(' %d s ago', r.latest.s_ago) or '', r.latest.line) or '')
      .. (job.reason and string.format('; your reason: %s', job.reason) or '')
    return r
  end
  -- The agent's watches, running ones first then by start; those that ended over KEEP ticks ago are left out, read or
  -- not (d20 batch70 AF3: on the copy, a turret_tally final unread for 13 h still flagged).
  M.KEEP = 216000
  function M.list(index, tick)
    tick = tick or game.tick
    local out = {}
    for _, kind in ipairs(M.KINDS) do
      local job = jobs(kind)[index]
      if type(job) == 'table' and job.start and job.until_tick and tick - job.until_tick <= M.KEEP then
        local ok, r = pcall(row, kind, job, tick)
        if ok then out[#out+1] = r end
      end
    end
    table.sort(out, function(a, b)
      if (a.state == 'running') ~= (b.state == 'running') then return a.state == 'running' end
      return a.start_tick > b.start_tick
    end)
    return out
  end
  -- The id of the watch keeping the agent busy now, or nil: cheap, once a second (idle.lua busy()). Running: before its
  -- end tick, no final result, sampled within STALE ticks (or not yet stamped), and something left to read.
  function M.running(index, tick)
    tick = tick or game.tick
    for _, kind in ipairs(M.KINDS) do
      local job = jobs(kind)[index]
      if type(job) == 'table' and not job.result and job.until_tick and tick <= job.until_tick
        and not (job.sampled and tick - job.sampled > M.STALE) and not job.all_gone then
        return kind .. '@' .. job.start, job
      end
    end
  end
  -- Lines for the watches that are not running and need the agent: late, stalled, invalid, or a final not read yet.
  function M.flags(index, tick)
    local out = {}
    for _, r in ipairs(M.list(index, tick)) do
      if r.state ~= 'running' and (r.state ~= 'done' or not r.final_read) then out[#out+1] = r.line end
    end
    return out
  end
  -- (d20 batch70 AF3) status {brief, work}: the watches running or needing the agent (as flags reads them), in short
  -- rows for the stream's agent cards; nil when there are none.
  function M.card(index, tick)
    local out = {}
    for _, r in ipairs(M.list(index, tick)) do
      if r.state ~= 'done' or not r.final_read then
        out[#out+1] = {id=r.id, kind=r.kind, scope=r.scope, state=r.state, start_tick=r.start_tick, end_tick=r.end_tick,
          latest=r.latest and r.latest.line and {tick=r.latest.tick, line=r.latest.line} or nil, reason=r.reason, line=r.line}
      end
    end
    return #out > 0 and out or nil
  end
  return M
end
