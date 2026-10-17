-- platform_rename {platform, name} (C1, Astra 13:30, viewer LimeLight's idea): renames one of our platforms, as its GUI
-- does (LuaSpacePlatform.name), and lists what still names the old name: each agent's queue steps (pending and
-- running), running action, standing orders and saved plans, and board items. Nothing of theirs is changed. Platform
-- schedules and logistic requests name planets, not platforms, so a rename leaves them as they are.
return function(api)
  local M = {}
  local MAX_LINES = 24
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Whether a value holds the string old (equal, or a word of a longer text), at most 6 deep.
  local function names(v, old, depth, budget)
    depth = depth or 0; budget = budget or {n=0}
    budget.n = budget.n + 1
    if budget.n > 4000 or depth > 6 then return false end
    if type(v) == 'string' then
      if v == old then return true end
      local s, e = v:find(old, 1, true)
      while s do
        local before, after = s > 1 and v:sub(s - 1, s - 1) or ' ', e < #v and v:sub(e + 1, e + 1) or ' '
        if not before:match('[%w_%-]') and not after:match('[%w_%-]') then return true end
        s, e = v:find(old, e + 1, true)
      end
      return false
    end
    if type(v) ~= 'table' then return false end
    for k, x in pairs(v) do
      if names(k, old, depth + 1, budget) or names(x, old, depth + 1, budget) then return true end
    end
    return false
  end
  M.names = names
  function M.rename(p, a)
    assert(type(a.platform) == 'string', 'platform is the platform\'s name now')
    assert(type(a.name) == 'string' and #a.name >= 1 and #a.name <= 64, 'name must be 1..64 characters')
    local pl = api.platform(p, a.platform)
    local old = pl.name
    assert(a.name ~= old, 'the platform is named ' .. old .. ' already')
    for _, other in pairs(p.force.platforms) do
      assert(not (other.valid and other ~= pl and other.name == a.name), 'another platform of ours is named ' .. a.name)
    end
    pl.name = a.name
    assert(pl.name == a.name, 'the game kept the name ' .. tostring(pl.name))
    local s = api.state()
    local lines = {}
    local function add(t) if #lines < MAX_LINES then lines[#lines+1] = t end end
    local function who(i) return api.name_of and api.name_of(i) or ('agent ' .. tostring(i)) end
    for index, q in pairs(s[api.queue_key or 'queues'] or {}) do
      if q.current and names(q.current.args, old) then add(string.format('%s\'s queue: the running step %s%s', who(index), tostring(q.current.action), q.current.label and ' (' .. q.current.label .. ')' or '')) end
      for i, step in ipairs(q.pending or {}) do
        if names(step.args, old) then add(string.format('%s\'s queue: pending step %d %s%s', who(index), i, tostring(step.action), step.label and ' (' .. step.label .. ')' or '')) end
      end
      if q.loop and names(q.loop, old) then add(string.format('%s\'s repeating plan', who(index))) end
    end
    for index, act in pairs(s.active or {}) do
      if names(act.args, old) or names(act.then_launch, old) or names(act.load, old) or names(act.await_silo, old) then
        add(string.format('%s\'s running %s', who(index), tostring(act.op or act.handler or act.kind)))
      end
    end
    for index, o in pairs(s.orders or {}) do
      for _, order in ipairs(o.list or {}) do
        if names(order, old) then add(string.format('%s\'s standing order %s', who(index), tostring(order.name or '?'))) end
      end
    end
    for owner, list in pairs(s.plans or {}) do
      for pname, plan in pairs(list) do
        if names(plan, old) then add(string.format('%s\'s saved plan %s', tostring(owner), tostring(pname))) end
      end
    end
    local b = s.board
    for id, item in pairs(b and b.items or {}) do
      if item.status ~= 'done' and item.status ~= 'dropped' and (names(item.title, old) or names(item.text, old) or names(item.body, old)) then
        add(string.format('board #%d (%s) "%s"', id, tostring(item.kind or 'item'), tostring(item.title or ''):sub(1, 60)))
      end
    end
    table.sort(lines)
    return {platform=a.name, was=old, still_named=#lines > 0 and lines or nil,
      line=string.format('platform %s is named %s now; %s', old, a.name, #lines > 0 and string.format('%d place%s still name %s (nothing of theirs was changed)', #lines, #lines == 1 and '' or 's', old)
        or 'no queue, running action, order, saved plan or open board item names ' .. old),
      note='platform schedules and logistic requests name planets, not platforms: they are as they were'}
  end
  M.schema = {platform_rename = {platform='the platform\'s name now', name='the new name, 1..64 characters, not another platform\'s',
    returns='platform, was, line, still_named: each agent\'s queue steps (pending, running), running action, standing orders and saved plans, and open board items that name the old name (nothing of theirs changed)'}}
  return M
end
