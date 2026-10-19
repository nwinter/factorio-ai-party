-- platjobs: every agent's queued or running jobs that touch a platform (d18 batch37 D4, viewer Aurora 18:11: unload plans
-- hidden in agents' queues read as missing automation). Read only. A step touches the platform when its lane is
-- platform:NAME, or its args name it (platform, platforms, a wait's platform, an all wait's members). Each row: the owner,
-- the lane, the step (running now or pending, with its place), a wait's condition and what it saw last, and the queue's
-- drops to that platform so far (from its history). The platforms read and platform_digest carry the lines.
return function(api)
  local M = {}
  M.SHOW = 16
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- the platform names a step's args give (platform, platforms, a wait's platform, an all wait's members)
  local function collect(v, set)
    if type(v) ~= 'table' then return set end
    if type(v.platform) == 'string' then set[v.platform] = true end
    if type(v.platforms) == 'table' then for _, x in ipairs(v.platforms) do if type(x) == 'string' then set[x] = true end end end
    if type(v.conditions) == 'table' then for _, c in ipairs(v.conditions) do collect(c, set) end end
    return set
  end
  local function cond_text(c)
    if type(c) ~= 'table' then return '' end
    local u = c['until']
    if u == 'all' then
      local parts = {}
      for _, m in ipairs(c.conditions or {}) do parts[#parts+1] = cond_text(m) end
      return 'all of (' .. table.concat(parts, '; ') .. ')'
    end
    local bits = {tostring(u)}
    if c.item then bits[#bits+1] = c.item end
    if c.fluid then bits[#bits+1] = c.fluid end
    if c.at_least then bits[#bits+1] = '>= ' .. c.at_least end
    if c.below then bits[#bits+1] = '< ' .. c.below end
    if c.platform then bits[#bits+1] = 'on ' .. c.platform end
    if c.location then bits[#bits+1] = 'at ' .. c.location end
    if c.surface then bits[#bits+1] = 'on ' .. c.surface end
    return table.concat(bits, ' ')
  end
  local function step_text(step)
    local a = step.args or {}
    if step.action == 'wait_until' then return 'wait_until ' .. cond_text(a) end
    if step.action == 'drop' then
      local items = {}
      for _, it in ipairs(type(a.items) == 'table' and a.items or {}) do
        if type(it) == 'table' then items[#items+1] = tostring(it.item or it.name) .. (it.count and '*' .. it.count or '') else items[#items+1] = tostring(it) end
      end
      if a.item then items[#items+1] = a.item .. (a.count and '*' .. a.count or '') end
      return 'drop' .. (#items > 0 and ' ' .. table.concat(items, ', ') or '') .. (a.to and ' to ' .. tostring(a.to) or '')
    end
    return step.action .. (step.label and ' (' .. step.label .. ')' or '')
  end
  local function ago(t) return string.format('%ds ago', math.floor((game.tick - t) / 60)) end
  -- The rows by platform name, every agent's lanes, in one pass over the queues.
  function M.all()
    local s = api.state()
    local by = {}
    local keys = {{key='queues', lane='body'}}
    for _, k in ipairs(api.remote_keys(s)) do
      local pl = k:match('^lane_queues|(.+)$')
      keys[#keys+1] = {key=k, lane=pl and ('platform:' .. pl) or 'remote', platform=pl}
    end
    for _, k in ipairs(keys) do
      for index, q in pairs(s[k.key] or {}) do
        local rows = {}
        local function row(name)
          local r = rows[name]
          if not r then
            r = {owner=try(function() return api.lookup(index).name end) or ('#' .. tostring(index)), lane=k.lane, repeating=q.loop ~= nil or nil, steps={}, drops={}, ok=0, failed=0}
            rows[name] = r
          end
          return r
        end
        local function touched(args)
          local set = collect(args, {})
          if k.platform then set[k.platform] = true end
          return set
        end
        if q.current then
          local c = q.current
          for name in pairs(touched(c.args)) do
            local text = step_text(c) .. (q.paused and ' (the queue is paused' .. (q.paused_why and q.paused_why.line and ': ' .. q.paused_why.line or '') .. ')' or ', running')
            if c.action == 'wait_until' then
              local saw = c.saw and (type(c.saw) == 'table' and (c.saw.line or c.saw.text) or tostring(c.saw)) or nil
              text = text .. (c.started_tick and ', waiting since ' .. ago(c.started_tick) or '') .. (saw and '; saw ' .. saw or '')
            end
            table.insert(row(name).steps, 'now: ' .. text)
          end
        end
        for i, step in ipairs(q.pending or {}) do
          for name in pairs(touched(step.args)) do table.insert(row(name).steps, string.format('pending #%d: %s', i, step_text(step))) end
        end
        for _, e in ipairs(q.history or {}) do
          if e.action == 'drop' then
            for name in pairs(touched(e.args)) do
              local r = row(name)
              if e.ok then r.ok = r.ok + 1 else r.failed = r.failed + 1 end
              local res = type(e.result) == 'table' and e.result or {}
              local what = type(res.dropped) == 'table' and #res.dropped > 0 and table.concat(res.dropped, ', ') or (e.ok and 'nothing dropped' or tostring(res.error or res.why or 'failed'))
              r.drops[#r.drops+1] = string.format('%s%s%s', what, res.not_sent and '; not sent ' .. res.not_sent or '', e.finished_tick and ' (' .. ago(e.finished_tick) .. ')' or '')
            end
          end
        end
        -- a queue's past drops alone (nothing queued or running for it) are no job
        for name, r in pairs(rows) do
          if #r.steps > 0 then
            local n = #r.drops
            r.drops = n > 0 and string.format('%d drop%s so far (%d ok, %d failed); last %s', n, n == 1 and '' or 's', r.ok, r.failed, r.drops[n]) or nil
            r.ok, r.failed = nil, nil
            by[name] = by[name] or {}
            table.insert(by[name], r)
          end
        end
      end
    end
    for _, list in pairs(by) do
      table.sort(list, function(x, y) if x.owner ~= y.owner then return x.owner < y.owner end return x.lane < y.lane end)
    end
    return by
  end
  function M.rows(name, by) return (by or M.all())[name] or {} end
  -- One line a row: "Luna, lane platform:Kestrel II (repeating): now: wait_until ...; pending #2: drop ...; 3 drops so far ...".
  function M.lines(name, by)
    local rows = M.rows(name, by)
    if #rows == 0 then return {'no agent has a queued or running job that acts on or waits on ' .. name} end
    local out = {}
    for i, r in ipairs(rows) do
      if i > M.SHOW then out[#out+1] = string.format('+%d more', #rows - M.SHOW); break end
      local parts = {}
      for _, st in ipairs(r.steps) do parts[#parts+1] = st end
      if r.drops then parts[#parts+1] = r.drops end
      out[#out+1] = string.format('%s, lane %s%s: %s', r.owner, r.lane, r.repeating and ' (repeating)' or '', table.concat(parts, '; '))
    end
    return out
  end
  return M
end
