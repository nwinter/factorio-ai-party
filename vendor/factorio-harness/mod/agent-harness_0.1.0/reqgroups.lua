-- reqgroups: logistic sections added and removed, and named logistic groups, as the logistics GUI does them (d20 batch53
-- L3, Sol #1276; L4, Astra #1035 for host NickWinter). requests {add_section}, {remove_section}, {section, group} and
-- {groups: true} go through here (space.lua M.requests).
-- On 2.0.77 (the copy of world n, two requester chests): naming a group that does not exist makes it from the section's
-- requests; a section that joins a group that exists takes the group's requests and its own are gone (coal 7 was gone,
-- the group's iron-plate 10 took its place); an edit in any member is every member's; a section that leaves a group
-- keeps a copy of its requests; add_section(group) makes a section already in the group; a group with no members left
-- stays in the list.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  M.MAX_NAME = 100
  -- Filters as short texts (item min..max), for what a group change takes or drops.
  local function texts(filters)
    local out = {}
    for _, f in ipairs(filters or {}) do
      local v = f.value
      local n = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
      if n then
        local q = type(v.quality) == 'string' and v.quality or try(function() return v.quality.name end) or 'normal'
        out[#out+1] = n .. (q ~= 'normal' and '@' .. q or '') .. ' ' .. tostring(f.min or 0) .. '..' .. (f.max and tostring(f.max) or 'inf')
      end
    end
    return out
  end
  M.texts = texts
  -- Where a member section is: the entity (a platform's hub by its platform), its surface and position, the section.
  function M.member_text(sec)
    local e = try(function() return sec.owner end)
    local idx = try(function() return sec.index end)
    if not (e and e.valid) then return 'a section of an entity no longer there' end
    local pl = try(function() return e.surface.platform end)
    local where = pl and (pl.name .. ' hub') or (e.type == 'character' and ((try(function() return e.player and e.player.name end)) or 'a character') .. '\'s requests')
      or string.format('%s (%g,%g) on %s', e.name, e.position.x, e.position.y, e.surface.name)
    return where .. (idx and ' section ' .. idx or '')
  end
  function M.check_name(v)
    assert(type(v) == 'string' and v ~= '' and #v <= M.MAX_NAME, 'group is a name (1..' .. M.MAX_NAME .. ' characters), or false to leave the group')
    return v
  end
  -- Every group of the force, with its requests and members (the GUI's group list shows each name with its member count;
  -- each member is an entity of ours whose logistics GUI shows the group).
  function M.list(force, limit)
    limit = limit or 32
    local names = try(function() return force.get_logistic_groups() end) or {}
    table.sort(names)
    local rows = {}
    for i, n in ipairs(names) do
      if i > limit then break end
      local g = try(function() return force.get_logistic_group(n) end) or {}
      local members = {}
      for k, m in ipairs(g.members or {}) do if k <= 16 then members[#members+1] = M.member_text(m) end end
      local req = texts(g.filters)
      rows[#rows+1] = {name=n, members_count=#(g.members or {}), members=#members > 0 and members or nil,
        members_more=#(g.members or {}) > 16 and #g.members - 16 or nil, requests=req,
        line=string.format('%s: %d member%s, %d request%s', n, #(g.members or {}), #(g.members or {}) == 1 and '' or 's', #req, #req == 1 and '' or 's')}
    end
    return {groups=rows, groups_more=#names > limit and #names - limit or nil,
      note='a group\'s requests are every member\'s: an edit in one member changes all of them; a group with no members stays in the list'}
  end
  -- The members an edit of the group of sec changes besides sec itself (nil when it is in no group or the only member).
  function M.others(force, sec)
    local name = try(function() return sec.group end)
    if not name or name == '' then return nil end
    local g = try(function() return force.get_logistic_group(name) end)
    local list = {}
    for _, m in ipairs(g and g.members or {}) do
      local same = try(function() return m.owner == sec.owner and m.index == sec.index end)
      if not same then list[#list+1] = M.member_text(m) end
    end
    if #list == 0 then return nil end
    return {group=name, members=list,
      line=string.format('section %s is in the group "%s": the edit changes %d other member%s too%s', tostring(sec.index), name, #list, #list == 1 and '' or 's',
        #list > 0 and ': ' .. table.concat(list, ', ', 1, math.min(8, #list)) .. (#list > 8 and string.format(' and %d more', #list - 8) or '') or '')}
  end
  -- sec joins (name) or leaves (false) a group. Returns what the GUI's change of group does: the group, whether it was
  -- made now, the section's own requests the change drops (joining one that exists), what it now requests.
  function M.set_group(force, sec, name)
    assert(sec.is_manual, 'section ' .. sec.index .. ' is controlled by the game')
    local was = sec.group or ''
    local own = texts(try(function() return sec.filters end))
    if name == false or name == '' then
      assert(was ~= '', 'section ' .. sec.index .. ' is in no group')
      sec.group = ''
      return {left=was, kept=own, line=string.format('section %d left the group "%s" and keeps its %d request%s as its own; the group\'s other members are unchanged',
        sec.index, was, #own, #own == 1 and '' or 's')}
    end
    M.check_name(name)
    assert(was ~= name, 'section ' .. sec.index .. ' is in the group "' .. name .. '" already')
    local existed = try(function() return force.get_logistic_group(name) end)
    local others = existed and #(existed.members or {}) or 0
    sec.group = name
    local now = texts(try(function() return sec.filters end))
    local dropped = {}
    if existed then
      local keep = {}
      for _, t in ipairs(now) do keep[t] = true end
      for _, t in ipairs(own) do if not keep[t] then dropped[#dropped+1] = t end end
    end
    return {group=name, made=not existed or nil, left=was ~= '' and was or nil, requests=now, dropped=#dropped > 0 and dropped or nil,
      line=existed and string.format('section %d joined the group "%s" (%d other member%s): it requests the group\'s %d request%s%s', sec.index, name, others,
        others == 1 and '' or 's', #now, #now == 1 and '' or 's', #dropped > 0 and '; its own ' .. table.concat(dropped, ', ') .. ' are gone' or '')
        or string.format('the group "%s" made from section %d\'s %d request%s', name, sec.index, #now, #now == 1 and '' or 's')}
  end
  -- What remove_section N drops: its requests, its group (the group stays).
  function M.removal(sec)
    local own = texts(try(function() return sec.filters end))
    local g = sec.group ~= '' and sec.group or nil
    return {removed=sec.index, requests=own, group=g,
      line=string.format('section %d removed with its %d request%s%s', sec.index, #own, #own == 1 and '' or 's',
        g and string.format(' (it left the group "%s"; the group and its other members stay)', g) or '')}
  end
  -- A dry run's undo: each manual section's group, put back before its requests (a section in a group writes the group).
  function M.snapshot(secs)
    local out = {}
    for i = 1, secs.sections_count do
      local s_ = secs.get_section(i)
      if s_.is_manual then out[i] = s_.group or '' end
    end
    return out
  end
  function M.restore_group(force, s_, was, made)
    if s_.group ~= was then
      if s_.group ~= '' then s_.group = '' end
      if was ~= '' then s_.group = was end
    end
  end
  -- Groups a dry run made: gone again when no member is left.
  function M.drop_made(force, names)
    for name in pairs(names or {}) do
      local g = try(function() return force.get_logistic_group(name) end)
      if g and #(g.members or {}) == 0 then pcall(force.delete_logistic_group, name) end
    end
  end
  return M
end
