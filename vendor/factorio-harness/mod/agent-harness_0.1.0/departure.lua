-- departure (B2, Grok 6x and 16:50: Swift's schedule read a 3600 s stop at Gleba while Sol's queue sent it on as soon as
-- cargo landed): the agents' queue steps and standing orders that set a platform's schedule (platform_schedule), each
-- with the wait that comes before it in that queue or the order's own trigger, beside the schedule's own waits.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function cond_text(c)
    if type(c) ~= 'table' then return tostring(c) end
    local parts = {tostring(c['until'] or c.type or '?')}
    for _, k in ipairs({'item', 'platform', 'location', 'at_least', 'below', 'technology'}) do
      if c[k] ~= nil then parts[#parts+1] = k .. ' ' .. tostring(c[k]) end
    end
    if type(c.position) == 'table' then parts[#parts+1] = string.format('at (%g,%g)', c.position.x or 0, c.position.y or 0) end
    return table.concat(parts, ' ')
  end
  local function stops_text(args)
    local t = {}
    for _, st in ipairs(type(args.stops) == 'table' and args.stops or {}) do t[#t+1] = tostring(st.station) end
    return #t > 0 and table.concat(t, ' -> ') or 'its schedule'
  end
  -- Lines naming what will send platform `name` on, from every agent's queue and orders.
  function M.lines(name)
    local s = api.state()
    local out = {}
    local function who(i) return api.name_of and api.name_of(i) or ('agent ' .. tostring(i)) end
    for index, q in pairs(s[api.queue_key or 'queues'] or {}) do
      local seq = {}
      if q.current then seq[#seq+1] = q.current end
      for _, st in ipairs(q.pending or {}) do seq[#seq+1] = st end
      local looped = false
      if q.loop then for _, st in ipairs(q.loop) do seq[#seq+1] = st end; looped = true end
      for i, st in ipairs(seq) do
        local a = st.args
        if st.action == 'platform_schedule' and type(a) == 'table' and a.platform == name and a.stops ~= nil then
          local prev = seq[i - 1]
          local wait = prev and prev.action == 'wait_until' and type(prev.args) == 'table' and cond_text(prev.args) or nil
          out[#out+1] = string.format('%s\'s queue%s: %s then platform_schedule %s (%s)%s', who(index), q.paused and ' (paused)' or '',
            wait and ('wait_until ' .. wait) or 'right after its step before', name, stops_text(a), looped and '; it repeats' or '')
        end
      end
    end
    for index, o in pairs(s.orders or {}) do
      for _, order in ipairs(o.list or {}) do
        for _, st in ipairs(order.steps or {}) do
          local a = st.args
          if st.action == 'platform_schedule' and type(a) == 'table' and a.platform == name and a.stops ~= nil then
            out[#out+1] = string.format('%s\'s standing order %s: when %s, platform_schedule %s (%s)', who(index), tostring(order.name),
              order.when and cond_text(order.when) or 'its round comes', name, stops_text(a))
          end
        end
      end
    end
    table.sort(out)
    return #out > 0 and out or nil
  end
  return M
end
