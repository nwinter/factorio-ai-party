-- "open for you": one line of what is open for an agent, on a sleep's replies and in the idle nudge (d15-sleepwhy
-- H3, Nick 07:45: 285 of 297 long idle sleeps in shifts 14-16 began with alerts in view, and Sonnet slept on Vulcanus
-- with its own plastic chain starved). Four parts, each a count and up to 3 examples with positions:
--   board: the agent's own active board items (claims aside), with their status;
--   alerts: push alert groups centred in one of its fresh claims (the background alert job's last groups);
--   machines: machines idle or starved in its fresh claims (the factory survey's cached non-working positions, up to 16
--     per machine name and status on a surface, so a count can be low; never a scan here);
--   unanswered: board requests teammates gave it that it has not noted or edited, and tells to it (not fyi, not to the
--     whole team) from the last 30 minutes that it has not told the sender (or the team) anything since.
-- Facts only: what the board, the alert panel, the machines' status icons and the tells show.
return function(api)
  local M = {}
  local EXAMPLES, TELL_WINDOW = 3, 30 * 3600
  local ACTIVE = {open=true, claimed=true, doing=true, blocked=true}
  local IDLE = {item_ingredient_shortage='ingredient shortage', fluid_ingredient_shortage='fluid ingredient shortage',
    no_ingredients='no ingredients', no_input_fluid='no input fluid', full_output='output full',
    waiting_for_space_in_destination='output blocked', no_fuel='no fuel', no_power='no power', no_recipe='no recipe',
    no_minable_resources='out of ore', low_input_fluid='low input fluid'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function ago(ticks)
    local sec = math.floor(math.max(0, ticks) / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  local function clip(text, n)
    text = tostring(text or ''):gsub('%s+', ' ')
    return #text > n and text:sub(1, n - 3) .. '...' or text
  end
  local function at(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  local function inside(a, pos)
    return pos.x >= a.left_top.x and pos.x <= a.right_bottom.x and pos.y >= a.left_top.y and pos.y <= a.right_bottom.y
  end
  local function part(n, one, many, examples)
    if n == 0 then return nil end
    local text = n .. ' ' .. (n == 1 and one or many)
    if #examples > 0 then text = text .. ' (' .. table.concat(examples, '; ') .. (n > #examples and '; ...' or '') .. ')' end
    return text
  end
  -- The agent's fresh claims: {item, surface}.
  local function fresh_claims(me)
    local out = {}
    local board = api.state().board
    for _, i in pairs(board and board.items or {}) do
      if i.kind == 'claim' and i.owner == me and i.area and ACTIVE[i.status] and not (api.claim_stale and api.claim_stale(i)) then
        out[#out+1] = {item=i, surface=api.claim_surface and api.claim_surface(i) or i.surface or 'nauvis'}
      end
    end
    table.sort(out, function(a, b) return a.item.id < b.item.id end)
    return out
  end
  local function claim_at(claims, surface, pos)
    for _, c in ipairs(claims) do if c.surface == surface and inside(c.item.area, pos) then return c.item end end
  end
  -- Parts as {count, examples}; M.line joins them.
  function M.parts(me, force)
    local board = api.state().board
    local items = {}
    for _, i in pairs(board and board.items or {}) do items[#items+1] = i end
    table.sort(items, function(a, b) return a.id < b.id end)
    -- Own active items (claims are the areas below; plans and harness requests are not jobs).
    local own, own_ex = 0, {}
    local asked, asked_ex = 0, {}
    for _, i in ipairs(items) do
      if i.owner == me and ACTIVE[i.status] and i.kind ~= 'claim' and i.kind ~= 'plan' and i.kind ~= 'harness' and i.kind ~= 'note' then
        own = own + 1
        if #own_ex < EXAMPLES then own_ex[#own_ex+1] = string.format('#%d %s [%s]', i.id, clip(i.title, 60), i.status) end
        if i.kind == 'request' and i.requested_by and i.requested_by ~= me then
          local answered = false
          for _, n in ipairs(i.notes or {}) do if n.by == me then answered = true end end
          for _, e in ipairs(i.edits or {}) do if e.by == me then answered = true end end
          if not answered then
            asked = asked + 1
            if #asked_ex < EXAMPLES then asked_ex[#asked_ex+1] = string.format('board #%d from %s %s ago: %s', i.id, i.requested_by, ago(game.tick - (i.created_tick or game.tick)), clip(i.title, 60)) end
          end
        end
      end
    end
    local claims = fresh_claims(me)
    -- Alert groups centred in a fresh claim.
    local alerts, alerts_ex = 0, {}
    if #claims > 0 and api.alert_groups then
      for _, g in ipairs(try(function() return api.alert_groups(force) end) or {}) do
        local c = g.center and claim_at(claims, g.surface, g.center)
        if c then
          alerts = alerts + 1
          if #alerts_ex < EXAMPLES then
            local text = api.alert_text and try(function() return api.alert_text(g) end) or string.format('%s near %s', tostring(g.kind), at(g.center))
            alerts_ex[#alerts_ex+1] = clip(text, 110) .. string.format(' (claim #%d)', c.id)
          end
        end
      end
    end
    -- Machines idle or starved in a fresh claim (the survey's cached positions).
    local idle, idle_ex = 0, {}
    if #claims > 0 then
      local cache = api.state().survey_cache or {}
      local surfaces = {}
      for _, c in ipairs(claims) do surfaces[c.surface] = true end
      for name in pairs(surfaces) do
        local index = try(function() return game.surfaces[name].index end)
        local entry = index and cache[force.name .. '/' .. index]
        local names = {}
        for machine in pairs(entry and entry.positions or {}) do if machine ~= 'belt_ends' then names[#names+1] = machine end end
        table.sort(names)
        for _, machine in ipairs(names) do
          local statuses = {}
          for status in pairs(entry.positions[machine]) do if IDLE[status] then statuses[#statuses+1] = status end end
          table.sort(statuses)
          for _, status in ipairs(statuses) do
            for _, pos in ipairs(entry.positions[machine][status]) do
              if claim_at(claims, name, pos) then
                idle = idle + 1
                if #idle_ex < EXAMPLES then idle_ex[#idle_ex+1] = string.format('%s %s %s', machine, at(pos), IDLE[status]) end
              end
            end
          end
        end
      end
    end
    -- Tells to me in the window that I have not answered (told the sender or the team since).
    local tells = try(function() return api.state().tells.log end) or {}
    local last_to = {}
    for _, t in ipairs(tells) do
      if t.from == me then
        if t.team then last_to['*team*'] = t.tick end
        for _, n in ipairs(t.to or {}) do last_to[n] = t.tick end
      end
    end
    local seen = {}
    for k = #tells, 1, -1 do
      local t = tells[k]
      if game.tick - t.tick > TELL_WINDOW then break end
      local to_me = false
      for _, n in ipairs(t.to or {}) do if n == me then to_me = true end end
      if to_me and not t.team and not t.fyi and t.from ~= me and t.from ~= 'operator' and not seen[t.from] then
        seen[t.from] = true
        local answered = (last_to[t.from] or -1) > t.tick or (last_to['*team*'] or -1) > t.tick
        if not answered then
          asked = asked + 1
          if #asked_ex < EXAMPLES then asked_ex[#asked_ex+1] = string.format('tell from %s %s ago: %s', t.from, ago(game.tick - t.tick), clip(t.text, 70)) end
        end
      end
    end
    return {board={own, own_ex}, alerts={alerts, alerts_ex}, machines={idle, idle_ex}, unanswered={asked, asked_ex}, claims=#claims}
  end
  function M.line(me, force)
    local x = M.parts(me, force)
    local parts = {}
    for _, p in ipairs{part(x.board[1], 'board item of yours', 'board items of yours', x.board[2]),
      part(x.alerts[1], 'alert group in your claims', 'alert groups in your claims', x.alerts[2]),
      part(x.machines[1], 'machine idle or starved in your claims', 'machines idle or starved in your claims', x.machines[2]),
      part(x.unanswered[1], 'request or tell to you unanswered', 'requests or tells to you unanswered', x.unanswered[2])} do
      if p then parts[#parts+1] = p end
    end
    if #parts == 0 then
      return 'open for you: none (no board items of yours, ' .. (x.claims == 0 and 'no fresh claims' or 'no alert groups or idle machines in your claims')
        .. ', no unanswered requests or tells)'
    end
    return 'open for you: ' .. table.concat(parts, '; ')
  end
  return M
end
