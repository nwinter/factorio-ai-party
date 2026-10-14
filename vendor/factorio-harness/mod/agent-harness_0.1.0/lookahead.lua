-- The look-ahead block (Nick 12:35: a periodic look-ahead prompt, much more often than shift changes; what agents
-- do with it is up to them). The read: the agent's plan line and how long since it changed, its open board items,
-- the team plan goals; the research running and queued next; items whose stock in a logistic network falls at the
-- last 30 min's rate to zero within 2 hours (at most 5); then one sentence. When it comes is the host's (fh: about
-- every 45 real minutes per agent, offset by agent, not in a shift's first 20 min, with the time left in the shift);
-- `fh call lookahead` reads it any time.
return function(api)
  local M = {}
  local SENTENCE = 'look ahead: a moment to think past the current task: what you and the team will need in the next hour or two, '
    .. 'and whether your plan line still says it. What you do with this is up to you.'
  M.SENTENCE = SENTENCE
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function span(ticks)
    local m = math.floor(ticks / 3600)
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), m % 60) end
    return m < 1 and math.floor(ticks / 60) .. 's' or m .. 'm'
  end
  local function research(force)
    local cur = try(function() return force.current_research end)
    local queue = try(function() return force.research_queue end) or {}
    local next_names = {}
    for _, t in ipairs(queue) do
      local name = try(function() return t.name end)
      if name and (not cur or name ~= cur.name) and #next_names < 4 then next_names[#next_names+1] = name end
    end
    local line
    if cur then
      local pct = math.floor((try(function() return force.research_progress end) or 0) * 100)
      line = string.format('research: %s %d%% running', cur.name, pct)
    else line = 'research: none running' end
    return line .. (#next_names > 0 and '; queued next: ' .. table.concat(next_names, ', ') or '; nothing queued next')
  end
  function M.lines(p)
    local who = api.who(p)
    local b = api.board_view(who)
    local out = {}
    if b.line then
      out[#out+1] = string.format('your plan line: "%s" (set %s ago%s)', b.line, span(game.tick - (b.line_tick or game.tick)),
        b.line_by and ' by ' .. b.line_by or '')
    else out[#out+1] = 'your plan line: none' end
    out[#out+1] = #b.items > 0 and 'your open board items: ' .. table.concat(b.items, '; ') or 'your open board items: none'
    out[#out+1] = 'team plan goals: ' .. (b.goals or 'none')
    out[#out+1] = research(p.force)
    local rows, enough = api.running_out(p.force, 5)
    if #rows > 0 then
      local parts = {}
      for _, r in ipairs(rows) do
        parts[#parts+1] = string.format('%s in network #%d (%s) in %s (%d left)', r.name, r.id, r.surface, span(r.ticks), math.floor(r.left))
      end
      out[#out+1] = 'stock falling to zero within 2 h at the last 30 min rate: ' .. table.concat(parts, '; ')
    else
      out[#out+1] = enough and 'stock falling to zero within 2 h at the last 30 min rate: none'
        or 'stock falling to zero within 2 h at the last 30 min rate: under 30 min of network samples yet'
    end
    return out
  end
  -- The read: lines, then the sentence (the host puts the time left in the shift between them).
  function M.read(p)
    return {lines=M.lines(p), sentence=SENTENCE}
  end
  M.schema = {lookahead={returns='lines: your plan line and how long since it changed, your open board items, the team plan goals; '
    .. 'the research running and queued next; items whose stock in a logistic network falls at the last 30 min\'s rate to zero within 2 h '
    .. '(at most 5, game time); sentence. fh adds the time left in the shift. The same block comes in a reply about every 45 real minutes '
    .. '(not in a shift\'s first 20 min), once'}}
  return M
end
