-- Research target levels (C2, Sol 16:50: an infinite technology named several times in the queue is kept once, so
-- "through level 10" needed an outside watcher): research {target_level: {name: N}} keeps a leveled technology coming
-- until level N is researched: whenever it is neither researching nor queued and the queue has room, the next level is
-- added to the end of the queue, as the research GUI's queue button does. At most MAX techs a force, N at most AHEAD
-- levels past the one researching now; 0 removes a target. research {targets: true} reads them.
return function(api)
  local M = {}
  local MAX, AHEAD, QUEUE_MAX = 16, 100, 7
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store(force)
    local s = api.state()
    s.research_targets = s.research_targets or {}
    s.research_targets[force.name] = s.research_targets[force.name] or {}
    return s.research_targets[force.name]
  end
  local function queue_of(force) return try(function() return force.research_queue end) or {} end
  -- The first place of a technology in the queue and how many entries it has there (each the next level).
  local function queued_at(force, name)
    local first, n = nil, 0
    for i, t in ipairs(queue_of(force)) do if t.name == name then first = first or i; n = n + 1 end end
    return first, n
  end
  -- What researching that technology now will finish: its level (a leveled technology's level is the one in progress).
  local function level(t) return try(function() return t.level end) or 1 end
  function M.set(force, v)
    assert(type(v) == 'table' and next(v) ~= nil, 'target_level is {technology: level, ...} (0 removes a target)')
    local targets = store(force)
    local out = {}
    for name, n in pairs(v) do
      local t = force.technologies[name]
      assert(t, 'target_level: no technology ' .. tostring(name))
      assert(type(n) == 'number' and n == math.floor(n) and n >= 0, 'target_level: ' .. name .. ' takes a whole level (0 removes it)')
      if n == 0 then targets[name] = nil; out[#out+1] = name .. ': target removed'
      else
        local max = try(function() return t.prototype.max_level end) or 1
        assert(max > (try(function() return t.prototype.level end) or 1), 'target_level: ' .. name .. ' has one level; research it by name')
        assert(n <= max, string.format('target_level: %s goes to level %d at most', name, max))
        assert(n <= level(t) + AHEAD, string.format('target_level: %s is at level %d; a target is at most %d levels past it', name, level(t), AHEAD))
        local count = 0; for _ in pairs(targets) do count = count + 1 end
        assert(targets[name] or count < MAX, 'at most ' .. MAX .. ' research targets; 0 removes one')
        targets[name] = n
        out[#out+1] = string.format('%s: target level %d', name, n)
      end
    end
    M.tick_force(force)
    return out
  end
  -- Each target: done, researching, queued at a place, or waiting for room; what is left.
  function M.read(force)
    local rows = {}
    for name, n in pairs(store(force)) do
      local t = force.technologies[name]
      local lv = t and level(t) or 0
      local done = t and (try(function() return t.researched end) or lv > n)
      local cur = try(function() return force.current_research and force.current_research.name end)
      local at, n_at = queued_at(force, name)
      local plan = api.state().research_plan and api.state().research_plan[force.name]
      local pending = plan and plan.names and #plan.names or 0
      local state = done and 'done' or cur == name and string.format('researching level %d%s', lv, n_at > 1 and string.format(', queued to level %d', lv + n_at - 1) or '') or at and (n_at > 1 and string.format('queued %d times from place %d, levels %d to %d', n_at, at, lv, lv + n_at - 1) or string.format('queued at %d, level %d', at, lv))
        or string.format('not queued: the queue is full (added when there is room%s)', pending > 0 and string.format(', after the %d pending name%s research lists', pending, pending == 1 and '' or 's') or '')
      rows[#rows+1] = {technology=name, target=n, level=lv, left=done and 0 or math.max(0, n - lv + 1),
        line=string.format('%s: target level %d; %s; %d level%s left', name, n, state, done and 0 or math.max(0, n - lv + 1), (n - lv + 1) == 1 and '' or 's')}
    end
    table.sort(rows, function(x, y) return x.technology < y.technology end)
    return rows
  end
  function M.tick_force(force)
    local targets = store(force)
    for name, n in pairs(targets) do
      local t = force.technologies[name]
      if not t then targets[name] = nil
      elseif try(function() return t.researched end) or level(t) > n then targets[name] = nil
      else
        local cur = try(function() return force.current_research and force.current_research.name end)
        local plan = api.state().research_plan and api.state().research_plan[force.name]
        local pending = plan and plan.names and #plan.names > 0
        if cur ~= name and not queued_at(force, name) and not pending and #queue_of(force) < QUEUE_MAX then pcall(function() force.add_research(t) end) end
      end
    end
  end
  -- Every 5 seconds, the forces with targets.
  function M.tick(tick)
    if tick % 300 ~= 0 then return end
    for fname in pairs(api.state().research_targets or {}) do
      local force = game.forces[fname]
      if force then pcall(M.tick_force, force) end
    end
  end
  return M
end
