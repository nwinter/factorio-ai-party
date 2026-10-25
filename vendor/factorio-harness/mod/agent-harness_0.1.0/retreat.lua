-- Retreat (operator 12:27; Astra lost a tank and died in shift12): move_to, shoot, kite and vehicle {drive} take
-- retreat {to, health_below, shield_below} (fractions; any one triggers), and a standing retreat_guard {to,
-- health_below, shield_below} applies to each of them until cleared. The runtime reads the health every 5 ticks: the
-- character's, or the vehicle's when it drives one (seated or by remote view) or sits in one. Below a threshold and
-- lower than when the action began (so a character already hurt still walks where it likes until it is hit again),
-- the action ends retreated and the agent goes back to `to` at once: a vehicle it drives is driven there (the drive's
-- own path and guards, its guns on), on foot it walks there with the enemy check (avoid_enemies) and its guns on auto
-- while it has ammunition. last.retreated says why, from where, the health then and where to; the walk or drive back
-- ends retreated on arrival.
return function(api)
  local M = {handlers={}}
  local function round(x) return math.floor(x + 0.5) end
  -- What to watch: a vehicle driven by remote view, the vehicle the character sits in, else the character.
  function M.body(p, action)
    if action and action.remote and action.vehicle then return action.vehicle end
    local c = p.character
    local v = c and c.valid and c.vehicle
    if v and v.valid then return v end
    return c
  end
  local function reading(e)
    local ok, h, m = pcall(function() return e.health, e.max_health end)
    if not (ok and h and m and m > 0) then return nil end
    local s, sm
    pcall(function() local g = e.grid; if g then s, sm = g.shield, g.max_shield end end)
    if not (sm and sm > 0) then s, sm = nil, nil end
    return h, m, s, sm
  end
  local function fraction(v, what)
    if v == nil then return nil end
    if type(v) ~= 'number' or v <= 0 or v >= 1 then error(what .. ' is a fraction between 0 and 1 (0.4 is 40%)', 0) end
    return v
  end
  -- The retreat a call asks for: its own retreat (an object, or {x,y} for its point), false for none, else the
  -- standing guard. Nil when none.
  function M.config(p, a, kind)
    local r, standing = a.retreat, nil
    if r == false then return nil end
    if r == nil then
      r = (api.state().retreat_guards or {})[p.index]
      -- (a guard that only says idle: false has no retreat for actions)
      if not (r and (r.to or r.retreat_to)) then return nil end
      standing = true
    end
    if type(r) ~= 'table' then error('retreat is {to: {x,y}, health_below: 0..1, shield_below: 0..1} (any one triggers), or false for none', 0) end
    local to = r.to or r.retreat_to
    if to == nil and (r.x ~= nil or r[1] ~= nil) then to = r end
    if to == nil then error('retreat needs to: {x,y}, the place to go back to', 0) end
    to = api.position(to)
    local cfg = {to=to, health_below=fraction(r.health_below, 'health_below'), shield_below=fraction(r.shield_below, 'shield_below'),
      standing=standing}
    if not (cfg.health_below or cfg.shield_below) then cfg.health_below = 0.4 end
    return cfg
  end
  -- The readings the action starts with: a threshold triggers only below them.
  function M.arm(p, action, cfg)
    if not cfg then action.retreat = nil; return nil end
    local e = M.body(p, action)
    local h, m, s, sm = reading(e)
    cfg.h0 = h and h / m or 1
    cfg.s0 = s and s / sm or nil
    action.retreat = cfg
    return cfg
  end
  local function line(cfg)
    local parts = {}
    if cfg.health_below then parts[#parts + 1] = string.format('health under %d%%', round(cfg.health_below * 100)) end
    if cfg.shield_below then parts[#parts + 1] = string.format('shield under %d%%', round(cfg.shield_below * 100)) end
    return string.format('to (%g,%g) at %s%s', cfg.to.x, cfg.to.y, table.concat(parts, ' or '), cfg.standing and ' (standing retreat_guard)' or '')
  end
  M.line = line
  M.reading = reading
  M.check_goal = api.check_goal
  -- Every 5 ticks: what triggers the retreat (why, from, health, shield, to), or nil.
  function M.check(p, action)
    return M.check_entity(M.body(p, action), action.retreat)
  end
  -- The same for one entity and a cfg {health_below, shield_below, h0, s0, to, standing} (a spidertron's guard too).
  function M.check_entity(e, cfg)
    if not (cfg and e and e.valid) then return nil end
    local h, m, s, sm = reading(e)
    if not h then return nil end
    local what = e.type == 'character' and '' or (e.name .. ' ')
    local hf, sf = h / m, s and s / sm or nil
    local why
    if cfg.health_below and hf < cfg.health_below and hf < cfg.h0 - 0.005 then
      why = string.format('%shealth %d%% (%d/%d) under %d%%', what, math.floor(hf * 100), round(h), round(m), round(cfg.health_below * 100))
    elseif cfg.shield_below and sf and sf < cfg.shield_below and sf < (cfg.s0 or 1) - 0.005 then
      why = string.format('%sshield %d%% (%d/%d) under %d%%', what, math.floor(sf * 100), round(s), round(sm), round(cfg.shield_below * 100))
    end
    if not why then return nil end
    local pos = e.position
    return {why=why, from={x=math.floor(pos.x * 10 + 0.5) / 10, y=math.floor(pos.y * 10 + 0.5) / 10}, health=string.format('%d/%d', round(h), round(m)),
      shield=s and string.format('%d/%d', round(s), round(sm)) or nil, to=cfg.to, standing=cfg.standing, tick=game.tick}
  end
  -- The health when the retreat ends (arrived or not).
  function M.now(p, action)
    local e = M.body(p, action)
    local h, m = reading(e)
    return h and string.format('%d/%d', round(h), round(m)) or nil
  end
  M.schema = {
    retreat_guard={to='{x,y}: where to go back to',retreat_to='the same as to',health_below='0..1, default 0.4 when neither is given',shield_below='0..1 (the armor\'s, or the vehicle\'s grid when driving)',
      clear='true: no standing retreat any more (and no go_to retreat on the spidertrons you sent)',
      idle='true (default) or false: when hit with no action running, or during a mine, a walking tour, pickup, repair, construct or a wait (with its guns off), the character walks away at once: to to when set, else 24 tiles straight away from the attacker; false keeps it standing',
      note='a standing retreat for move_to, shoot, kite, vehicle drive and the spidertrons you send by vehicle go_to or ride (its route replaced by one to to, read every 30 ticks; then go_to on it is refused until this guard is set again or cleared) until cleared (a call\'s own retreat wins; retreat: false skips it); no arguments: shows it',
      returns='retreat_guard: what is set, or false; idle when set to false'},
  }
  function M.handlers.retreat_guard(p, a)
    local s = api.state()
    s.retreat_guards = s.retreat_guards or {}
    -- idle (round1950a): walking away when hit with nothing walking it; kept with the guard, or alone.
    if a.idle ~= nil then
      if type(a.idle) ~= 'boolean' then error('idle must be true or false', 0) end
      if a.clear ~= nil then error('clear goes alone', 0) end
      if a.to == nil and a.retreat_to == nil and a.health_below == nil and a.shield_below == nil then
        local g = s.retreat_guards[p.index] or {}
        if a.idle == false then g.idle = false else g.idle = nil end
        if next(g) == nil then s.retreat_guards[p.index] = nil else s.retreat_guards[p.index] = g end
        return {retreat_guard=g.to and line({to=g.to, health_below=g.health_below, shield_below=g.shield_below, standing=true}) or false,
          idle=a.idle}
      end
    end
    if a.clear ~= nil then
      if a.clear ~= true then error('clear must be true', 0) end
      if a.to ~= nil or a.retreat_to ~= nil or a.health_below ~= nil or a.shield_below ~= nil then error('clear goes alone', 0) end
      s.retreat_guards[p.index] = nil
      return {retreat_guard=false}
    end
    if a.to == nil and a.retreat_to == nil and a.health_below == nil and a.shield_below == nil then
      local g = s.retreat_guards[p.index]
      local out = {retreat_guard=g and g.to and line({to=g.to, health_below=g.health_below, shield_below=g.shield_below, standing=true}) or false}
      if g and g.idle == false then out.idle = false end
      return out
    end
    local cfg = M.config(p, {retreat={to=a.to or a.retreat_to, health_below=a.health_below, shield_below=a.shield_below}})
    if api.check_goal then api.check_goal(p, cfg.to) end
    local was = s.retreat_guards[p.index]
    local g = {to=cfg.to, health_below=cfg.health_below, shield_below=cfg.shield_below, set_tick=game.tick}
    if a.idle == false or (a.idle == nil and was and was.idle == false) then g.idle = false end
    s.retreat_guards[p.index] = g
    cfg.standing = true
    local out = {retreat_guard=line(cfg)}
    if g.idle == false then out.idle = false end
    return out
  end
  return M
end
