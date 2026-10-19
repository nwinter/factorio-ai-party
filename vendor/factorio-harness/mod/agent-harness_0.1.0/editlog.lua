-- Who changed a request section or a departure gate (d19 batch41 B1, Sol seq 861: another agent switched off
-- Swiftlet's required section 5 while Sol's queue waited on it; the reads showed the section off and no name). Each
-- edit of a request section (a hub's, a chest's, a landing pad's) and of a platform stop's departure conditions keeps
-- the editor, the tick and the old and new values, the last KEEP a section or stop. The reads show the last edit. The
-- agent whose values an edit changes (the last editor before it) is told once a call when someone else edits.
-- Records begin with this change: a section or stop nobody edited since has no editor and tells nobody.
-- (d19 batch46 3) Also a silo's switches (automatic requests, send to orbit automatically) and a platform's settings
-- (its schedule's stops, paused, a request's custom minimum payload set by min_payload): M.setting and M.lines.
return function(api)
  local M = {}
  local KEEP, TEXT = 5, 300
  local function store()
    local s = api.state()
    s.edit_log = s.edit_log or {}
    return s.edit_log
  end
  local function clip(t)
    t = tostring(t)
    if #t <= TEXT then return t end
    return t:sub(1, TEXT - 3) .. '...'
  end
  local function ago(ticks)
    local m = math.floor(math.max(0, ticks) / 3600)
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), m % 60) end
    if m >= 1 then return m .. 'm' end
    return math.floor(math.max(0, ticks) / 60) .. 's'
  end
  -- before, after: {[n]=text} by section or stop number; the numbers whose text changed, in key order: {key, old, new} (nil: none there).
  function M.diff(before, after)
    local keys, seen = {}, {}
    for k in pairs(before or {}) do if not seen[k] then seen[k] = true; keys[#keys+1] = k end end
    for k in pairs(after or {}) do if not seen[k] then seen[k] = true; keys[#keys+1] = k end end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
      local o, n = (before or {})[k], (after or {})[k]
      if o ~= n then out[#out+1] = {key=k, old=o, new=n} end
    end
    return out
  end
  -- scope: 'req:<unit number>' or 'gate:<platform>'; label(key): 'Swiftlet request section 5'. Records each change
  -- and returns the lines each earlier editor other than `by` is owed: {[name]={lines}}.
  function M.record(scope, by, changes, label)
    local log = store()
    log[scope] = log[scope] or {}
    local owed = {}
    for _, c in ipairs(changes) do
      local key = tostring(c.key)
      local list = log[scope][key] or {}
      log[scope][key] = list
      local prev = list[#list]
      list[#list+1] = {by=by, tick=game.tick, old=c.old and clip(c.old) or nil, new=c.new and clip(c.new) or nil}
      while #list > KEEP do table.remove(list, 1) end
      if prev and prev.by and prev.by ~= by then
        owed[prev.by] = owed[prev.by] or {}
        table.insert(owed[prev.by], string.format('%s: %s -> %s', label(c.key), c.old or 'none', c.new or 'none'))
      end
    end
    return owed
  end
  function M.last(scope, key)
    local list = (store()[scope] or {})[tostring(key)]
    return list and list[#list] or nil
  end
  -- (d19 batch46 3, viewer Aurora) a silo's and a platform's settings ('silo:<unit number>', 'plat:<platform>'): the
  -- latest edit of each key edited, oldest first: "automatic requests: on -> off, by sol at 153h12m (tick N, 3m ago)".
  function M.lines(scope, label)
    local out = {}
    for key, list in pairs(store()[scope] or {}) do
      local e = list[#list]
      if e then out[#out+1] = {tick=e.tick, key=key, e=e} end
    end
    table.sort(out, function(x, y) if x.tick ~= y.tick then return x.tick < y.tick end return x.key < y.key end)
    for i, r in ipairs(out) do
      local m = math.floor(r.e.tick / 3600)
      out[i] = string.format('%s: %s -> %s, by %s at game time %dh%02dm (tick %d, %s ago)', label and label(r.key) or r.key,
        r.e.old or 'none', r.e.new or 'none', r.e.by or '?', math.floor(m / 60), m % 60, r.e.tick, ago(game.tick - r.e.tick))
    end
    return #out > 0 and out or nil
  end
  -- One setting changed by `by`: recorded under scope and key, earlier editors told (not with quiet: a change another
  -- record of the same call already tells). Returns the names told.
  function M.setting(scope, key, by, old, new, quiet)
    if old == new then return nil end
    local owed = M.record(scope, by, {{key=key, old=old, new=new}}, function(k) return k end)
    return not quiet and M.tell(owed, by) or nil
  end
  function M.text(e)
    if not e then return nil end
    return string.format('last edit by %s %s ago (tick %d): %s -> %s', e.by or '?', ago(game.tick - e.tick), e.tick, e.old or 'none', e.new or 'none')
  end
  -- One tell to each earlier editor owed lines (names without an index, the operator among them, are skipped).
  function M.tell(owed, by)
    local told = {}
    for name, lines in pairs(owed) do
      local index = api.index_of and api.index_of(name)
      if index and api.deliver then
        local ok = pcall(api.deliver, index, {seq='edit', tick=game.tick, from=by,
          text=string.format('changed what you set last: %s', table.concat(lines, '; '))})
        if ok then told[#told+1] = name end
      end
    end
    table.sort(told)
    return #told > 0 and told or nil
  end
  return M
end
