-- Staging in a requester or buffer chest: what a queue plan asks of one chest at once, against its slots (d27 batch280
-- CS, Astra #2600: a railgun-turret batch asked a 48-slot requester for 930 tungsten-plate, 1588 superconductor, 620
-- carbon-fiber and 3400 quantum-processor, 68 slots; the queue dry run passed and the plan stalled at 1500
-- quantum-processor). Seen on a 2.0.77 copy of world n:
-- - those four requests on an empty 48-slot requester, robots and stock to spare: within 19 s it held 930, 1400, 621
--   and 1500, every slot full, and nothing more came in the next 94 s;
-- - each item and quality fills slots of its own (50 normal and 50 rare quantum-processor: 2 slots); stacks are the
--   item's stack size (tungsten-plate 50, superconductor 200, carbon-fiber and quantum-processor 100);
-- - robots fill a requester only under its bar (bar 11: 10 slots, 1000 quantum-processor of 2000 asked).
-- For each item_count wait (at_least, alone or inside all) at one requester or buffer chest whose requests then name
-- the item: the chest's requests now with the plan's requests steps on it before the wait applied (set, clear,
-- clear_all, active; a step with a section index, add_section, remove_section or group is not followed, and the chest
-- is not checked past it).
-- - The waits there need their items at once while nothing takes from the chest between them: each item and quality
--   waited for (its largest at_least), ceil(count / stack size) slots, with what the chest holds now that stays (other
--   items while trash unrequested is off). Over its slots under its bar: refused, the waits can never all be met.
-- - Its requests then ask (each item's min summed over its active sections, the waited at_least where larger): over
--   its slots, said: robots bring them in any order, and a wait can stall.
-- Something takes from the chest: an inserter (or loader) whose pickup is the chest, unless held whatever the count
-- (its own condition, or a circuit_set before the wait, "ITEM < -2147483648", as assembler_batch holds its input), or
-- a plan step that names the chest's position (transfer, ...) between the requests and the wait. Then the items may go
-- as they arrive (sequential): said, not refused. Trash unrequested on: what is held unrequested goes; not refused.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local HOLD = '< -2147483648'
  local function at(pos) return string.format('(%g,%g)', pos.x or pos[1], pos.y or pos[2]) end
  local function pos_of(v)
    if type(v) ~= 'table' then return nil end
    local x, y = tonumber(v.x or v[1]), tonumber(v.y or v[2])
    if x and y then return {x=x, y=y} end
  end
  local function stack_of(n) return try(function() return prototypes.item[n].stack_size end) or 1 end
  local function quality_of(q)
    if type(q) == 'string' then return q end
    return q ~= nil and try(function() return q.name end) or 'normal'
  end
  local function key(name, q) return q == 'normal' and name or name .. '@' .. q end
  local function name_q(k) local n, q = k:match('^(.-)@([^@]+)$'); return n or k, q or 'normal' end
  -- The requester or buffer chest of ours at pos (on the surface named, else the player's).
  local function chest_at(p, pos, surface)
    local s = surface and game.get_surface(surface) or p.surface
    if not s then return nil end
    local found = try(function()
      return s.find_entities_filtered{area={{pos.x - 0.4, pos.y - 0.4}, {pos.x + 0.4, pos.y + 0.4}}, type='logistic-container', force=p.force, limit=1}
    end)
    local e = found and found[1]
    local mode = e and try(function() return e.prototype.logistic_mode end)
    if mode == 'requester' or mode == 'buffer' then return e end
  end
  local function same_pos(a, e)
    return a and math.abs(a.x - e.position.x) < 0.6 and math.abs(a.y - e.position.y) < 0.6
  end
  -- The chest's requests now: sections [{active, manual, group, req {key: min}, max {key: max}}].
  local function load(e)
    local pt = try(function() return e.get_requester_point() end)
    local secs = {}
    for i = 1, pt and (try(function() return pt.sections_count end) or 0) or 0 do
      local s = pt.get_section(i)
      local row = {active=s.active ~= false, manual=s.is_manual, group=s.group or '', req={}, max={}}
      for _, f in pairs(try(function() return s.filters end) or {}) do
        local v = f.value
        if v and v.name and (v.type == nil or v.type == 'item') then
          local k = key(v.name, quality_of(v.quality))
          row.req[k] = (row.req[k] or 0) + (f.min or 0)
          if f.max then row.max[k] = (row.max[k] or 0) + f.max end
        end
      end
      secs[i] = row
    end
    return {e=e, secs=secs, trash=try(function() return pt.trash_not_requested end) == true, run={}, takers={}, seen={}}
  end
  -- Inserters and loaders that take from the chest, each held (whatever the count) or not by its own condition now.
  local function takers(e)
    local out = {}
    local p0 = e.position
    local found = try(function()
      return e.surface.find_entities_filtered{area={{p0.x - 4, p0.y - 4}, {p0.x + 4, p0.y + 4}}, type={'inserter', 'loader', 'loader-1x1'}, force=e.force}
    end) or {}
    for _, t in ipairs(found) do
      local from
      if t.type == 'inserter' then from = try(function() return t.pickup_target end)
      elseif try(function() return t.loader_type end) == 'output' then from = try(function() return t.loader_container end) end
      if from and from.valid and from.unit_number == e.unit_number then
        local cb = try(function() return t.get_control_behavior() end)
        local held = false
        if cb then
          local lc = try(function() return cb.connect_to_logistic_network and cb.logistic_condition end)
          local c = lc and lc.first_signal and lc.constant == -2147483648 and lc.comparator == '<'
          held = c and true or false
        end
        out[#out+1] = {e=t, pos={x=t.position.x, y=t.position.y}, held=held}
      end
    end
    return out
  end
  -- The section a requests step writes for an item, as space.lua requests does: the manual section that requests it
  -- already, else the first manual one in no group (a new one if none).
  local function section_for(st, k)
    for _, s in ipairs(st.secs) do if s.manual and s.req[k] then return s end end
    for _, s in ipairs(st.secs) do if s.manual and s.group == '' then return s end end
    local s = {active=true, manual=true, group='', req={}, max={}}
    st.secs[#st.secs + 1] = s
    return s
  end
  local function default_section(st)
    for _, s in ipairs(st.secs) do if s.manual and s.group == '' then return s end end
    local s = {active=true, manual=true, group='', req={}, max={}}
    st.secs[#st.secs + 1] = s
    return s
  end
  -- A requests step on the chest, applied; false: not followed.
  local function apply(st, a)
    if a.dry_run then return true end
    if a.section ~= nil or a.add_section ~= nil or a.remove_section ~= nil or a.group ~= nil then return false end
    if a.trash_unrequested ~= nil then st.trash = a.trash_unrequested == true end
    local sec = (a.active ~= nil or a.clear_all) and default_section(st) or nil
    if a.active ~= nil then sec.active = a.active == true end
    if a.clear_all then sec.req, sec.max = {}, {} end
    local names = {}
    for _, n in ipairs(type(a.clear) == 'table' and a.clear or {}) do names[#names + 1] = n end
    for _, n in ipairs(type(a.remove) == 'table' and a.remove or {}) do names[#names + 1] = n end
    for _, n in ipairs(names) do
      if type(n) == 'string' then local s = sec or section_for(st, n); s.req[n] = nil; s.max[n] = nil end
    end
    local set = {}
    if type(a.set) == 'table' then
      if #a.set > 0 then set = a.set
      else for n, v in pairs(a.set) do set[#set + 1] = {item=n, min=v} end end
    end
    for _, r in ipairs(set) do
      if type(r) == 'table' and type(r.item) == 'string' and tonumber(r.min) then
        local k = key(r.item, quality_of(r.quality))
        local s = sec or section_for(st, k)
        s.req[k] = tonumber(r.min)
        if tonumber(r.max) then s.max[k] = tonumber(r.max) elseif r.max ~= nil then s.max[k] = nil end
      end
    end
    return true
  end
  local function asked(st)
    local t = {}
    for _, s in ipairs(st.secs) do
      if s.active then for k, n in pairs(s.req) do t[k] = (t[k] or 0) + n end end
    end
    return t
  end
  local function slots_of(e)
    local inv = try(function() return e.get_inventory(defines.inventory.chest) end)
    if not inv then return nil end
    local n = #inv
    local bar = try(function() return inv.get_bar() end)
    local usable = (bar and bar - 1 < n) and bar - 1 or n
    return usable, n
  end
  -- What the chest holds now of items no request names then (they stay while trash unrequested is off): slots.
  local function staying(st, req)
    if st.trash then return 0, {} end
    local inv = try(function() return st.e.get_inventory(defines.inventory.chest) end)
    local n, parts = 0, {}
    for _, c in pairs(inv and try(function() return inv.get_contents() end) or {}) do
      local k = key(c.name, quality_of(c.quality))
      if not req[k] then
        local s = math.ceil((c.count or 0) / stack_of(c.name))
        n = n + s
        parts[#parts + 1] = string.format('%d %s', c.count or 0, k)
      end
    end
    return n, parts
  end
  local function count_slots(t)
    local n, parts, keys = 0, {}, {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local s = math.ceil(t[k] / stack_of((name_q(k))))
      n = n + s
      parts[#parts + 1] = string.format('%d %s %d', t[k], k, s)
    end
    return n, parts
  end
  -- The item_count conditions of a wait that must hold: the condition, or each member of all (nested).
  local function musts(c, out)
    if type(c) ~= 'table' then return out end
    if c['until'] == 'item_count' then out[#out + 1] = c
    elseif c['until'] == 'all' and type(c.conditions) == 'table' then
      for _, m in ipairs(c.conditions) do musts(m, out) end
    end
    return out
  end
  local function wait_chest(c)
    if c.at_least == nil or c.platform ~= nil or c.network ~= nil or c.quality == 'any' or type(c.item) ~= 'string' then return nil end
    local pos = c.position and pos_of(c.position)
    if not pos and type(c.positions) == 'table' and #c.positions == 1 then pos = pos_of(c.positions[1]) end
    return pos
  end
  -- check(p, items): lines (each chest checked at the wait where its requests or waits first change) and refused
  -- (lines: the waits can never all be met), or nil when the plan has no such wait.
  function M.check(p, items)
    -- the chests waited at, read first (the plan's steps before a wait are followed from the start)
    local chests, list = {}, {}
    for _, step in ipairs(items or {}) do
      if step.action == 'wait_until' and type(step.args) == 'table' then
        for _, c in ipairs(musts(step.args, {})) do
          local pos = wait_chest(c)
          local e = pos and chest_at(p, pos, c.surface)
          if e and not chests[e.unit_number] then
            local st = load(e); st.takers = takers(e)
            chests[e.unit_number] = st; list[#list + 1] = st
          end
        end
      end
    end
    if #list == 0 then return nil end
    local lines, refused = {}, {}
    local off = {}
    local function state(pos)
      for _, st in ipairs(list) do if same_pos(pos, st.e) then return st end end
    end
    for i, step in ipairs(items) do
      local a = type(step.args) == 'table' and step.args or {}
      local pos = pos_of(a.position)
      if step.action == 'requests' and pos and a.platform == nil then
        local st = state(pos)
        if st and not off[st.e.unit_number] and not apply(st, a) then
          off[st.e.unit_number] = true
          lines[#lines + 1] = string.format('%s %s: step %d (requests with section, add_section, remove_section or group) is not followed: its staging is not checked from there',
            st.e.name, at(st.e.position), i)
        end
      elseif step.action == 'circuit_set' and pos then
        for _, st in ipairs(list) do
          for _, t in ipairs(st.takers) do
            if same_pos(pos, t.e) then
              local hold = type(a.logistic) == 'string' and a.logistic:find(HOLD, 1, true) ~= nil
              if hold then t.held = true
              elseif a.logistic ~= nil or a.enable ~= nil or a.remove_condition ~= nil then t.held = false end
            end
          end
        end
      elseif step.action == 'wait_until' then
        for _, c in ipairs(musts(a, {})) do
          local wpos = wait_chest(c)
          local st = wpos and state(wpos)
          local k = key(c.item, quality_of(c.quality))
          local req = st and not off[st.e.unit_number] and asked(st)
          if req and req[k] then
            local need = tonumber(c.at_least) or 0
            st.run[k] = math.max(st.run[k] or 0, need)
            local usable, size = slots_of(st.e)
            local stay, stay_parts = staying(st, req)
            local waited, wparts = count_slots(st.run)
            local all = {}
            for kk, n in pairs(req) do all[kk] = n end
            for kk, n in pairs(st.run) do if req[kk] and n > all[kk] then all[kk] = n end end
            local whole, aparts = count_slots(all)
            local moving = {}
            for _, t in ipairs(st.takers) do if not t.held then moving[#moving + 1] = string.format('%s %s', t.e.name, at(t.pos)) end end
            if st.moved then moving[#moving + 1] = st.moved end
            local where = string.format('%s %s', st.e.name, at(st.e.position))
            local bar = usable and usable < size and string.format(' (its bar at %d of %d)', usable, size) or ''
            -- said once a run of waits (refused) or once for each set of requests and takers
            local sig = table.concat(aparts, ',') .. '|' .. table.concat(moving, ',')
            local over = usable and waited + stay > usable and #moving == 0 and not st.trash
            if usable and (over and not st.refused or not over and not st.seen[sig]) then
              if over then st.refused = true else st.seen[sig] = true end
              local stay_text = stay > 0 and string.format(', and %d slot%s of what it holds that stays (%s)', stay, stay == 1 and '' or 's', table.concat(stay_parts, ', ')) or ''
              local head = string.format('step %d (wait_until item_count %s at %s)', i, k, where)
              if over then
                local l = string.format('%s: the waits there need %d of its %d slots%s at once (%s%s): nothing takes from it between them, so they can never all be met; robots fill its slots and the rest never comes. Refused: fewer at once (clear requests and set the next after a wait), or another chest',
                  head, waited + stay, usable, bar, table.concat(wparts, ', '), stay_text)
                refused[#refused + 1] = l
                lines[#lines + 1] = l
              elseif whole + stay > usable then
                lines[#lines + 1] = string.format('%s: its requests then ask %d of its %d slots%s (%s%s); %s',
                  head, whole + stay, usable, bar, table.concat(aparts, ', '), stay_text,
                  #moving > 0 and string.format('%s take%s from it: they fit only if taken out as they arrive (sequential)', table.concat(moving, ', '), #moving == 1 and 's' or '')
                  or st.trash and 'trash unrequested is on: what it holds unrequested goes to storage'
                  or 'robots bring them in any order, and this wait can stall once its slots are full')
              else
                lines[#lines + 1] = string.format('%s: the requests there ask %d of its %d slots%s (%s%s)%s', head, whole + stay, usable, bar, table.concat(aparts, ', '), stay_text,
                  #moving > 0 and string.format('; %s take%s from it', table.concat(moving, ', '), #moving == 1 and 's' or '') or '')
              end
            end
          end
        end
      end
      -- a step naming a chest's position (other than its requests and waits) may take from it
      if pos and step.action ~= 'requests' and step.action ~= 'wait_until' and step.action ~= 'circuit_set' then
        for _, st in ipairs(list) do
          if same_pos(pos, st.e) then st.moved = string.format('step %d (%s)', i, step.action); st.run = {}; st.refused = nil end
        end
      end
    end
    if #lines == 0 then return nil end
    return lines, #refused > 0 and refused or nil
  end
  return M
end
