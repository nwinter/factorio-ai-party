-- Lessons that surface when they matter (d17 batch15 Group D, Sol 08:09 and 08:12, Astra 08:09 and 08:14). board.lua
-- keeps the lessons (lesson_add, lesson_edit, lesson_verify) and matches them to calls; this keeps what the agents
-- wrote on top of them and what the game shows of them. The harness decides nothing: it stores, scores and shows.
-- - a score per lesson: impact (0..5, as written, with what it prevented), applicability (how many keys narrow it:
--   names, a place, a surface), evidence (how many times verified, at most 5) and recency (verified within 2 h: 3,
--   12 h: 1, stale: 0); board.lua ranks matched lessons by it, and before a consequential call (launch, a departure by
--   platform_schedule, construct, load_silo, and their dry runs and queue steps) shows the best one with its check;
-- - control (what in the factory must change) and check (a wait_until condition): a lesson with a check stays
--   unresolved until the check holds, read every minute as its owner would read it (resolved then, and said);
-- - what surfaced: each lesson shown to an agent before a call is remembered for 30 minutes; a failure of that agent
--   matching the lesson's failure pattern (action:reason words) in that time counts as "did not prevent", none as
--   "no repeat"; lesson_review gives the counts, duplicates (the same keys and most title words alike), superseded and
--   stale ones;
-- - ground rules: the team writes up to 8 (ground_rule_add, from lessons it names), shown once at each shift start in the
--   team block with the lessons' evidence and the exceptions written; ground_rule_retire retires one (superseded).
return function(api)
  local M = {}
  M.WINDOW, M.MAX_RULES, M.MAX_SURFACED = 108000, 8, 400
  M.CONSEQUENTIAL = {launch=true, platform_schedule=true, construct=true, load_silo=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.lessonbook = s.lessonbook or {surfaced={}, counts={}, rules={}, rule_seq=0}
    return s.lessonbook
  end
  local function hours(t) return math.floor(t / 216000 * 10 + 0.5) / 10 end
  -- The fields lesson_add and lesson_edit take here; nil when none was given.
  function M.fields(a, i)
    local any = false
    if a.impact ~= nil then
      assert(type(a.impact) == 'number' and a.impact >= 0 and a.impact <= 5, 'impact is 0..5: how much the failure it prevents costs (as you judge it)')
      i.impact = math.floor(a.impact); any = true
    end
    for _, f in ipairs({'prevented', 'control', 'failure'}) do
      if a[f] ~= nil then
        assert(type(a[f]) == 'string', f .. ' is text')
        i[f] = a[f] ~= '' and a[f]:sub(1, 200) or nil; any = true
      end
    end
    if a.check ~= nil then
      if a.check == false then i.check, i.resolved_tick = nil, nil
      else
        assert(type(a.check) == 'table' and api.validate, 'check is a wait_until condition: {until: "item_count", item, at_least, ...} (false clears it)')
        local ok, err = pcall(api.validate, a.check)
        assert(ok, 'check: ' .. tostring(err))
        i.check, i.resolved_tick, i.check_line = a.check, nil, nil
      end
      any = true
    end
    return any
  end
  function M.score(i)
    local k = i.keys or {}
    local names = (k.item and 1 or 0) + (k.recipe and 1 or 0) + (k.entity and 1 or 0) + (k.action and 1 or 0)
    local apply = names + ((k.position or k.area) and 2 or 0) + (k.surface and 1 or 0)
    local ev = math.min(5, i.verify_count or 1)
    local age = game.tick - (i.last_verified or i.created_tick or 0)
    local rec = age <= 7200 * 60 and 3 or age <= api.stale and 1 or 0
    local impact = i.impact or 1
    local n = impact * 2 + apply + ev + rec
    return n, string.format('score %d: impact %d%s, applies to %d key%s, verified %d time%s, %s ago', n, impact,
      i.prevented and ' (' .. i.prevented .. ')' or '', apply, apply == 1 and '' or 's', ev, ev == 1 and '' or 's', hours(age) .. 'h')
  end
  -- The lesson's own words past its rule: control and check (resolved or not).
  function M.extra(i)
    local parts = {}
    if i.control then parts[#parts+1] = 'control: ' .. i.control end
    if i.check then
      parts[#parts+1] = i.resolved_tick and string.format('check met %sh ago (resolved)', hours(game.tick - i.resolved_tick))
        or 'unresolved: check not met' .. (i.check_line and ' (' .. i.check_line .. ')' or '')
    end
    return #parts > 0 and table.concat(parts, '; ') or nil
  end
  -- Each lesson shown to agent index before action: remembered for WINDOW.
  function M.surfaced(index, lessons, action)
    local st = store()
    for _, i in ipairs(lessons) do
      st.surfaced[#st.surfaced+1] = {index=index, id=i.id, action=action, tick=game.tick}
      local c = st.counts[i.id] or {shown=0, repeat_=0, no_repeat=0}
      st.counts[i.id] = c
      c.shown = c.shown + 1
    end
    while #st.surfaced > M.MAX_SURFACED do table.remove(st.surfaced, 1) end
  end
  -- A failure of agent index (selfview.lua): each lesson surfaced to it within WINDOW whose failure pattern matches.
  function M.failed(index, action, reason)
    local st = store()
    local text = (tostring(action) .. ':' .. tostring(reason)):lower()
    local items = api.items()
    for _, s in ipairs(st.surfaced) do
      local i = items[s.id]
      if s.index == index and not s.done and i and i.failure and game.tick - s.tick <= M.WINDOW then
        local all = true
        for w in i.failure:lower():gmatch('[%w_%-]+') do if not text:find(w, 1, true) then all = false; break end end
        if all then
          s.done = 'repeat'
          local c = st.counts[s.id]
          if c then c.repeat_ = c.repeat_ + 1 end
        end
      end
    end
  end
  -- Every minute: surfacings past WINDOW with no repeat counted; checks read.
  function M.tick()
    local st = store()
    local keep = {}
    for _, s in ipairs(st.surfaced) do
      if game.tick - s.tick > M.WINDOW then
        if not s.done then
          local c = st.counts[s.id]
          local i = api.items()[s.id]
          if c and i and i.failure then c.no_repeat = c.no_repeat + 1 end
        end
      else keep[#keep+1] = s end
    end
    st.surfaced = keep
    for _, i in pairs(api.items()) do
      if i.kind == 'lesson' and i.check and not i.resolved_tick and api.active(i) then
        local p = api.player_of(i.owner)
        if p then
          local ok, met, line = pcall(api.condition, p, i.check)
          if ok then
            i.check_line = type(line) == 'string' and line:sub(1, 160) or nil
            if met then i.resolved_tick = game.tick end
          end
        end
      end
    end
  end
  -- lesson_review: counts, duplicates, superseded, stale, unresolved, and what surfacing was followed by.
  local function words(t)
    local out, n = {}, 0
    for w in tostring(t):lower():gmatch('%a%a%a+') do if not out[w] then out[w] = true; n = n + 1 end end
    return out, n
  end
  local function same_keys(a, b)
    local ka, kb = a.keys or {}, b.keys or {}
    for _, f in ipairs({'item', 'recipe', 'entity', 'action', 'surface'}) do if ka[f] ~= kb[f] then return false end end
    return true
  end
  function M.review(p, a)
    local stale_h = a.stale_hours ~= nil and a.stale_hours or api.stale / 216000
    assert(type(stale_h) == 'number' and stale_h > 0 and stale_h <= 200, 'stale_hours is 1..200 game hours')
    local st = store()
    local active, list = 0, {}
    local c = {open=0, dropped=0, superseded=0, stale=0, unresolved=0, resolved=0, with_check=0, with_failure=0, shown=0, repeat_=0, no_repeat=0}
    for _, i in pairs(api.items()) do
      if i.kind == 'lesson' then
        if api.active(i) then
          active = active + 1; c.open = c.open + 1; list[#list+1] = i
          if game.tick - (i.last_verified or i.created_tick or 0) > stale_h * 216000 then c.stale = c.stale + 1 end
          if i.check then c.with_check = c.with_check + 1; if i.resolved_tick then c.resolved = c.resolved + 1 else c.unresolved = c.unresolved + 1 end end
          if i.failure then c.with_failure = c.with_failure + 1 end
        else c.dropped = c.dropped + 1 end
        if i.superseded_by then c.superseded = c.superseded + 1 end
        local k = st.counts[i.id]
        if k then c.shown, c.repeat_, c.no_repeat = c.shown + k.shown, c.repeat_ + k.repeat_, c.no_repeat + k.no_repeat end
      end
    end
    table.sort(list, function(x, y) return x.id < y.id end)
    local dups = {}
    for x = 1, #list do
      local wx, nx = words(list[x].title)
      for y = x + 1, #list do
        if same_keys(list[x], list[y]) then
          local wy, ny = words(list[y].title)
          local both = 0
          for w in pairs(wx) do if wy[w] then both = both + 1 end end
          if both >= 3 and both / math.max(1, math.min(nx, ny)) >= 0.6 and #dups < 12 then
            dups[#dups+1] = string.format('#%d and #%d: the same keys, %d title words alike (lesson_edit {id, supersedes} merges them)', list[x].id, list[y].id, both)
          end
        end
      end
    end
    local lines = {string.format('%d open lessons (%d retired, %d superseded); %d stale (not verified for %g game hours); %d with a check: %d resolved, %d unresolved; %d with a failure pattern',
      c.open, c.dropped, c.superseded, c.stale, stale_h, c.with_check, c.resolved, c.unresolved, c.with_failure),
      string.format('surfaced before calls %d times in what is kept; of those with a failure pattern: %d followed by that failure within 30 min (did not prevent), %d not', c.shown, c.repeat_, c.no_repeat)}
    local rows = {}
    for _, i in ipairs(list) do
      local k = st.counts[i.id]
      local n = M.score(i)
      if k and (k.repeat_ > 0) and #rows < 12 then rows[#rows+1] = string.format('#%d shown %d, followed by its failure %d, not %d: %s', i.id, k.shown, k.repeat_, k.no_repeat, i.title) end
      if i.check and not i.resolved_tick and #rows < 12 then rows[#rows+1] = string.format('#%d unresolved (score %d): %s%s', i.id, n, i.title, i.check_line and '; check: ' .. i.check_line or '') end
    end
    return {lines=lines, duplicates=#dups > 0 and dups or nil, notable=#rows > 0 and rows or nil, counts=c}
  end
  -- Ground rules ------------------------------------------------------------------
  local function active_rules()
    local out = {}
    for _, r in ipairs(store().rules) do if not r.retired_tick then out[#out+1] = r end end
    return out
  end
  function M.rule_add(p, a)
    assert(type(a.text) == 'string' and #a.text >= 1 and #a.text <= 200, 'text is the rule, 1..200 characters')
    local ids = type(a.lessons) == 'number' and {a.lessons} or a.lessons
    assert(type(ids) == 'table' and #ids >= 1 and #ids <= 4, 'lessons: 1..4 lesson numbers it rests on (their evidence is shown with it)')
    local items = api.items()
    for _, id in ipairs(ids) do
      local i = items[id]
      assert(i and i.kind == 'lesson', 'no lesson #' .. tostring(id))
    end
    assert(a.exceptions == nil or (type(a.exceptions) == 'string' and #a.exceptions <= 200), 'exceptions is text, at most 200 characters')
    local st = store()
    local supersedes = a.supersedes
    if supersedes ~= nil then
      local found
      for _, r in ipairs(st.rules) do if r.id == supersedes and not r.retired_tick then found = r end end
      assert(found, 'supersedes: no active ground rule #' .. tostring(supersedes))
      found.retired_tick, found.superseded_by = game.tick, st.rule_seq + 1
    end
    assert(#active_rules() < M.MAX_RULES, string.format('at most %d ground rules: ground_rule_retire {id} one, or supersedes it', M.MAX_RULES))
    st.rule_seq = st.rule_seq + 1
    local r = {id=st.rule_seq, text=a.text, lessons=ids, exceptions=a.exceptions, by=api.who(p), tick=game.tick}
    st.rules[#st.rules+1] = r
    while #st.rules > 32 do table.remove(st.rules, 1) end
    return {rule=r, rules=M.rule_lines()}
  end
  function M.rule_retire(p, a)
    local st = store()
    for _, r in ipairs(st.rules) do
      if r.id == a.id and not r.retired_tick then
        r.retired_tick, r.retired_by, r.reason = game.tick, api.who(p), type(a.reason) == 'string' and a.reason:sub(1, 200) or nil
        return {retired=r.id, rules=M.rule_lines()}
      end
    end
    error('no active ground rule #' .. tostring(a.id), 0)
  end
  function M.rule_lines()
    local items = api.items()
    local out = {}
    for _, r in ipairs(active_rules()) do
      local ev = {}
      for _, id in ipairs(r.lessons) do
        local i = items[id]
        if i then ev[#ev+1] = string.format('#%d (evidence tick %d, verified %sh ago%s)', id, i.evidence_tick or i.created_tick or 0,
          hours(game.tick - (i.last_verified or i.created_tick or 0)), api.active(i) and '' or ', retired') end
      end
      out[#out+1] = string.format('rule %d (by %s): %s; from lessons %s%s', r.id, r.by, r.text, table.concat(ev, ', '), r.exceptions and '; exceptions: ' .. r.exceptions or '')
    end
    return out
  end
  function M.rules_read(p, a)
    local l = M.rule_lines()
    local old = {}
    for _, r in ipairs(store().rules) do
      if r.retired_tick and #old < 8 then old[#old+1] = string.format('rule %d retired %sh ago%s: %s', r.id, hours(game.tick - r.retired_tick),
        r.superseded_by and ' (superseded by rule ' .. r.superseded_by .. ')' or (r.reason and ' (' .. r.reason .. ')' or ''), r.text) end
    end
    return {rules=#l > 0 and l or {'no ground rules yet'}, retired=#old > 0 and old or nil, note=string.format('at most %d; shown once at each shift start in team.shift', M.MAX_RULES)}
  end
  M.schema = {
    lesson_review = {stale_hours='optional game hours unverified that read stale (default 12)',
      returns='lines: open, retired, superseded, stale lessons; with a check resolved and unresolved; how often lessons surfaced before calls and, for those with a failure pattern, how often that failure followed within 30 min (did not prevent) and how often not; duplicates (the same keys and most title words alike); notable (followed by their failure; unresolved checks); counts'},
    ground_rule_add = {text='the rule, 1..200 characters, as the team writes it', lessons='1..4 lesson numbers it rests on', exceptions='optional text: when it does not hold',
      supersedes='optional ground rule number it replaces (that one is retired)', returns='rule and the active rules (at most 8); shown once at each shift start in team.shift with the lessons\' evidence'},
    ground_rule_retire = {id='a ground rule number', reason='optional text', returns='retired and the active rules'},
    ground_rules = {returns='rules (active, with their lessons\' evidence and exceptions) and retired (the last 8)'},
  }
  M.handlers = {lesson_review=function(p, a) return M.review(p, a) end, ground_rule_add=function(p, a) return M.rule_add(p, a) end,
    ground_rule_retire=function(p, a) return M.rule_retire(p, a) end, ground_rules=function(p, a) return M.rules_read(p, a) end}
  return M
end
