-- A machine's modules in one call (Astra and Gemini, shift12 15:10: Sunward's module swaps took three blueprint round
-- trips, Fulgora's upgrades four): configure {position(s), modules} sets the module slots. modules is
-- - a list of modules: the machine ends up holding these; the ones it holds (or has coming) that the list names stay
--   in their slots and the rest go into the other slots in slot order; slots left over end up empty (Astra, shift13
--   19:40: applied slot by slot, ["speed-module-2", "efficiency-module"] on drills holding speed-module-2 in slots 1
--   and 2 and efficiency-module in slot 3 took the efficiency module out of slot 3 and asked for one in slot 2, with
--   none in the network: 11 drills drew more power);
-- - a list with "keep" or "empty" entries: slot by slot, entry i for slot i; "keep" leaves the slot (and any request
--   on it) as it is, slots past the list end up empty;
-- - numbered slots, {"1": "speed-module", "3": "empty"}: only the slots named change.
-- Read on 2.0.77, a private copy of world n:
-- - In reach, by hand: the old modules go to the character's inventory and the new ones come from it, as a player
--   swaps them in the machine's GUI.
-- - Out of reach, on another surface or on a platform: an item request on the machine (2.0's item-request-proxy, as
--   remote view's ghost cursor makes): an insert plan for the new modules and a removal plan for the old ones.
--   Construction robots did the swap in about 8 s (the removed modules ride to storage; with none free a robot
--   keeps them); on Starling and Sunward the platform hub did it in the same time, the removed ones into the hub.
-- - A ghost: the module requests of its insert plan, which the robots that build it bring.
-- Which module goes where (5892 machine, recipe and module cases agreed with the engine's can_set_stack): a module
-- category the machine or its recipe lists is required when either lists any; each effect a module improves (speed,
-- productivity, quality up; consumption, pollution down) must be allowed by the machine and by its recipe; effects
-- it worsens do not count.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- The module inventory of a ghost's entity, by its type (a built one names its own: crafters 4, drills 2, labs 3,
  -- beacons 1 on 2.0.77).
  local GHOST_INVENTORY = {['mining-drill']='mining_drill_modules', lab='lab_modules', beacon='beacon_modules'}
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function key(name, quality) return name .. '@' .. (quality or 'normal') end
  local function label(name, quality) return name .. ((quality and quality ~= 'normal') and '@' .. quality or '') end
  -- 'speed-module*2 efficiency-module@rare*1', or 'empty'.
  function M.text(counts)
    local parts = {}
    for _, c in ipairs(counts) do parts[#parts+1] = label(c.name, c.quality) .. '*' .. c.count end
    return #parts > 0 and table.concat(parts, ' ') or 'empty'
  end
  local function tally(list)
    local by, order = {}, {}
    for _, m in pairs(list) do
      if m then
        local k = key(m.name, m.quality)
        if not by[k] then by[k] = {name=m.name, quality=m.quality, count=0}; order[#order+1] = k end
        by[k].count = by[k].count + 1
      end
    end
    local out = {}
    for _, k in ipairs(order) do out[#out+1] = by[k] end
    return out
  end

  -- Module item names like a word that is no module.
  local function modules_like(word)
    local words, hits = {}, {}
    for w in tostring(word):lower():gmatch('[^%-_%s]+') do if w ~= 'module' and w ~= 'modules' then words[#words+1] = w end end
    for name, item in pairs(prototypes.item) do
      if item.type == 'module' then
        local all = true
        for _, w in ipairs(words) do if not name:find(w, 1, true) then all = false; break end end
        if all then hits[#hits+1] = name end
      end
    end
    table.sort(hits)
    local shown = {}
    for i = 1, math.min(#hits, 12) do shown[i] = hits[i] end
    return table.concat(shown, ', ') .. (#hits > 12 and string.format(' (+%d more)', #hits - 12) or '')
  end
  -- One module entry: a module name or {name, quality?}: {name, quality}; "empty" or false: false; "keep": 'keep'.
  local function entry_of(entry, where)
    if entry == false or entry == 'empty' then return false end
    if entry == 'keep' then return 'keep' end
    local name, quality = entry, 'normal'
    if type(entry) == 'table' then name, quality = entry.name, entry.quality or 'normal' end
    local item = type(name) == 'string' and prototypes.item[name]
    if not (item and item.type == 'module') then
      local like = modules_like(name)
      error(string.format('%snot a module: %s%s', where or '', tostring(name), like ~= '' and '; modules like it: ' .. like or ''), 0)
    end
    if not prototypes.quality[quality] then error('unknown quality ' .. tostring(quality), 0) end
    return {name=name, quality=quality}
  end
  local SLOT_FORMS = 'modules is a list of module names (or {name, count?, quality?}) the machine ends up holding, a map of names to counts {"efficiency-module": 3}, a list '
    .. 'with "keep" and "empty" entries (slot by slot), or numbered slots {"1": "speed-module", "3": "empty"}; [] or false empties the slots'
  -- modules (see the top): {kind='set', list={{name, quality}...}} or {kind='slots', at={[i]={name, quality}|false|'keep'},
  -- n (the last slot named), rest ('empty' past a list, 'keep' for numbered slots)}.
  function M.parse(v)
    if v == false then return {kind='set', list={}} end
    if type(v) == 'string' then v = {v} end
    if type(v) ~= 'table' then error(SLOT_FORMS, 0) end
    -- A map of module names to counts ({"efficiency-module": 3}; Sol, shift17 19:06: 8 queued steps wrote it so) is
    -- that list: the names in order, each count times.
    local named_keys, other_keys = {}, false
    for k in pairs(v) do
      if type(k) == 'string' and not k:match('^%d+$') then named_keys[#named_keys+1] = k else other_keys = true end
    end
    if #named_keys > 0 then
      if other_keys then error('modules: a map of module names to counts, or numbered slots, not both; ' .. SLOT_FORMS, 0) end
      table.sort(named_keys)
      local list = {}
      for _, k in ipairs(named_keys) do
        local n = v[k]
        if type(n) ~= 'number' or n < 1 or n ~= math.floor(n) or n > 16 then
          error(string.format('modules: %s: a count is a whole number 1..16 (a map of module names to counts); %s', k, SLOT_FORMS), 0)
        end
        list[#list+1] = {name=k, count=n}
      end
      v = list
    end
    local numbered, listed, top = false, false, 0
    for k in pairs(v) do
      if type(k) == 'number' then listed = true; top = math.max(top, k)
      elseif type(k) == 'string' and k:match('^%d+$') then numbered = true
      else error(string.format('modules: %s is not a slot number; %s', tostring(k), SLOT_FORMS), 0) end
    end
    if numbered and listed then error('modules: a list or numbered slots, not both', 0) end
    if top > #v then error('modules: a list entry is missing (null): "empty" leaves a slot empty, "keep" as it is', 0) end
    if numbered then
      local at, n = {}, 0
      for k, entry in pairs(v) do
        local i = tonumber(k)
        if i < 1 or i > 64 then error(string.format('modules: slot %s is not a slot number 1..64', k), 0) end
        if type(entry) == 'table' and (entry.count or 1) ~= 1 then error(string.format('modules: one module a slot (no count) in slot %d', i), 0) end
        at[i] = entry_of(entry, string.format('slot %d: ', i))
        n = math.max(n, i)
      end
      return {kind='slots', at=at, n=n, rest='keep'}
    end
    local out, slotted = {}, false
    for i, entry in ipairs(v) do
      if entry == false or entry == 'empty' or entry == 'keep' then slotted = true; out[#out+1] = entry_of(entry)
      else
        local count = type(entry) == 'table' and entry.count or 1
        if type(count) ~= 'number' or count < 1 or count ~= math.floor(count) or count > 16 then error('a modules entry\'s count is a whole number 1..16', 0) end
        local m = entry_of(entry)
        for _ = 1, count do out[#out+1] = m end
      end
      if #out > 64 then error('modules lists at most 64 slots', 0) end
    end
    if slotted then
      local at = {}
      for i, m in ipairs(out) do at[i] = m end
      return {kind='slots', at=at, n=#out, rest='empty'}
    end
    return {kind='set', list=out}
  end
  -- The modules a want names (for the checks): {name, quality} per module, keep and empty left out.
  function M.named(want)
    local out = {}
    if want.kind == 'set' then for _, m in ipairs(want.list) do out[#out+1] = m end
    else for i = 1, want.n do local m = want.at[i]; if type(m) == 'table' then out[#out+1] = m end end end
    return out
  end

  -- Whether module item m goes in a machine of proto making recipe (a prototype, or nil): nil, or why not.
  local BONUS_DOWN = {consumption=true, pollution=true}
  function M.why_not(proto, recipe, m, machine_text)
    local item = prototypes.item[m.name]
    local cat = try(function() return item.category end)
    local pc = try(function() return proto.allowed_module_categories end)
    local rc = recipe and try(function() return recipe.allowed_module_categories end)
    local function cats(t)
      local list = {}
      for c in pairs(t) do list[#list+1] = c end
      table.sort(list)
      return table.concat(list, ', ')
    end
    if pc and not pc[cat] then return string.format('%s (%s) does not go in %s: it takes %s modules', m.name, cat, machine_text, cats(pc)) end
    if rc and not rc[cat] then return string.format('%s (%s) does not go in %s: the recipe %s takes %s modules', m.name, cat, machine_text, recipe.name, cats(rc)) end
    local pe = try(function() return proto.allowed_effects end) or {}
    local re = recipe and (try(function() return recipe.allowed_effects end) or {})
    for eff, v in pairs(try(function() return item.module_effects end) or {}) do
      local bonus = BONUS_DOWN[eff] and v < 0 or not BONUS_DOWN[eff] and v > 0
      if bonus then
        if not pe[eff] then return string.format('%s does not go in %s: it allows no %s', m.name, machine_text, eff) end
        if re and not re[eff] then return string.format('%s does not go in %s: its recipe %s allows no %s', m.name, machine_text, recipe.name, eff) end
      end
    end
    return nil
  end

  -- What a machine (or ghost) is: its prototype, recipe, slot count, module inventory index and the text naming it.
  local function machine(e)
    local ghost = e.type == 'entity-ghost'
    local proto = ghost and e.ghost_prototype or e.prototype
    local recipe = try(function() local r = e.get_recipe(); return r and r.prototype end)
    local inv = not ghost and try(function() return e.get_module_inventory() end)
    local slots = inv and #inv or try(function() return proto.module_inventory_size end) or 0
    local index = inv and inv.index or defines.inventory[GHOST_INVENTORY[proto.type] or 'crafter_modules']
    local text = string.format('%s%s %s%s', ghost and 'the ghost of ' or '', proto.name, at(e.position), recipe and ' making ' .. recipe.name or '')
    return {ghost=ghost, proto=proto, recipe=recipe, inv=inv, slots=slots, index=index, text=text}
  end
  -- The module requests in a plan list for one inventory, per slot: {[stack]={name, quality}}.
  local function plan_slots(plans, index)
    local out = {}
    for _, p in ipairs(plans or {}) do
      for _, r in ipairs(p.items and p.items.in_inventory or {}) do
        if r.inventory == index then out[r.stack] = {name=p.id.name, quality=p.id.quality or 'normal'} end
      end
    end
    return out
  end
  -- A plan list with this inventory's rows replaced by slots ({[stack]={name, quality}}).
  local function replan(plans, index, slots)
    local out = {}
    for _, p in ipairs(plans or {}) do
      local rows = {}
      for _, r in ipairs(p.items and p.items.in_inventory or {}) do if r.inventory ~= index then rows[#rows+1] = r end end
      local other = p.items and p.items.grid_count
      if #rows > 0 or other then out[#out+1] = {id=p.id, items={in_inventory=#rows > 0 and rows or nil, grid_count=other}} end
    end
    local by, order = {}, {}
    local stacks = {}
    for stack in pairs(slots) do stacks[#stacks+1] = stack end
    table.sort(stacks)
    for _, stack in ipairs(stacks) do
      local m = slots[stack]
      local k = key(m.name, m.quality)
      if not by[k] then by[k] = {id={name=m.name, quality=m.quality}, items={in_inventory={}}}; order[#order+1] = k end
      table.insert(by[k].items.in_inventory, {inventory=index, stack=stack, count=1})
    end
    for _, k in ipairs(order) do out[#out+1] = by[k] end
    return out
  end
  local function same(a, b) return (a and b and a.name == b.name and (a.quality or 'normal') == (b.quality or 'normal')) or (not a and not b) end
  -- The modules of {[stack]={name, quality}} in slot order, counted.
  local function list_of(slots)
    local stacks, out = {}, {}
    for stack in pairs(slots) do stacks[#stacks+1] = stack end
    table.sort(stacks)
    for _, stack in ipairs(stacks) do out[#out+1] = slots[stack] end
    return tally(out)
  end

  -- Who brings requested modules and takes the old ones: on a platform its hub; else the construction robots of a
  -- network whose construction area covers the machine. wanted: the requested modules counted; removed: the ones
  -- coming out, counted (nil: none). Says what the hub or network holds of each against what is wanted, its idle
  -- construction robots, and whether a storage chest takes the removed ones: on 2.0.77 a swap went ahead with no room
  -- (the old modules rode in a robot), while a removal alone waited until a storage chest had room.
  local COVER_SEARCH = 120
  function M.carrier(e, wanted, removed)
    local removing = removed ~= nil and #removed > 0
    local surface, force, pos = e.surface, e.force, e.position
    local function holdings(count_of)
      local held, short = {}, {}
      for _, w in ipairs(wanted) do
        local n = count_of(w) or 0
        held[#held+1] = string.format('%s %d (%d wanted)', label(w.name, w.quality), n, w.count)
        if n < w.count then short[#short+1] = label(w.name, w.quality) end
      end
      local text = #held > 0 and ' (it holds ' .. table.concat(held, ', ') .. ')' or ''
      if #short > 0 then text = text .. string.format('; none comes for %s until it holds %s', table.concat(short, ', '), #short == 1 and 'it' or 'them') end
      return text
    end
    local verb = #wanted > 0 and (removing and 'bring them and take the old ones out' or 'bring them') or 'take them out'
    local plat = try(function() return surface.platform end)
    if plat then
      local hub = try(function() return plat.hub end)
      local verbs = #wanted > 0 and (removing and 'brings them and takes the old ones out' or 'brings them') or 'takes them out'
      return 'the platform hub ' .. verbs .. holdings(function(w) return hub and try(function() return hub.get_item_count{name=w.name, quality=w.quality} end) end)
    end
    local net
    for _, r in ipairs(try(function() return surface.find_entities_filtered{type='roboport', force=force, position=pos, radius=COVER_SEARCH} end) or {}) do
      local cell = try(function() return r.logistic_cell end)
      local cr = cell and try(function() return cell.construction_radius end) or 0
      if cr > 0 and math.abs(pos.x - r.position.x) <= cr and math.abs(pos.y - r.position.y) <= cr then
        net = try(function() return cell.logistic_network end)
        if net then break end
      end
    end
    if not net then return 'no roboport\'s construction area covers it: no robot comes until one does' end
    local text = string.format('construction robots of logistic network %s %s%s; %d of %d construction robots idle',
      tostring(try(function() return net.network_id end)), verb,
      holdings(function(w) return try(function() return net.get_item_count{name=w.name, quality=w.quality} end) end),
      try(function() return net.available_construction_robots end) or 0, try(function() return net.all_construction_robots end) or 0)
    if (try(function() return net.all_construction_robots end) or 0) == 0 then
      text = text .. string.format('; network %s has no construction robots: nothing is brought until it has some', tostring(try(function() return net.network_id end)))
    end
    if removing then
      local stores = try(function() return net.storages end) or {}
      local no_room = {}
      for _, m in ipairs(removed) do
        local room = false
        for _, st in ipairs(stores) do
          if try(function() return st.can_insert{name=m.name, quality=m.quality} end) then room = true; break end
        end
        if not room then no_room[#no_room+1] = label(m.name, m.quality) end
      end
      if #no_room > 0 then
        text = text .. string.format('; no storage chest has room for %s: %s', table.concat(no_room, ', '),
          #wanted > 0 and 'the old ones ride in a robot until one has' or 'no robot takes them out until one has')
      end
    end
    return text
  end

  -- The module each slot is to hold: {name, quality}, false (none) or 'keep'. A list (kind set) leaves the modules a
  -- slot holds or has coming (cur) where the list names them, then fills the other slots in slot order.
  local function targets(want, cur, slots)
    local slot = {}
    if want.kind == 'slots' then
      for i = 1, slots do
        local m = want.at[i]
        if m == nil then m = want.rest == 'keep' and 'keep' or false end
        slot[i] = m
      end
      return slot
    end
    local left = {}
    for _, m in ipairs(want.list) do left[#left+1] = m end
    for i = 1, slots do
      if cur[i] then
        for j, m in ipairs(left) do
          if same(cur[i], m) then slot[i] = m; table.remove(left, j); break end
        end
      end
    end
    local j = 1
    for i = 1, slots do
      if slot[i] == nil then slot[i] = left[j] or false; j = j + 1 end
    end
    return slot
  end
  -- A built machine's module item request, if any: (proxy, insert plan, removal plan).
  local function request_of(e)
    local proxy = try(function() return e.item_request_proxy end)
    if not (proxy and proxy.valid) then return nil, {}, {} end
    return proxy, try(function() return proxy.insert_plan end) or {}, try(function() return proxy.removal_plan end) or {}
  end
  -- Each slot as a line: what it holds and what is on its way in or out ("2 speed-module-2 (efficiency-module
  -- requested; speed-module-2 coming out)"); a ghost's slots by its requests ("1 speed-module (requested)").
  function M.by_slot(e)
    local mc = machine(e)
    if mc.slots == 0 then return nil end
    local out = {}
    if mc.ghost then
      local plan = plan_slots(try(function() return e.insert_plan end), mc.index)
      for i = 1, mc.slots do
        local m = plan[i - 1]
        out[i] = m and string.format('%d %s (requested)', i, label(m.name, m.quality)) or string.format('%d empty', i)
      end
      return out
    end
    local _, ins, rem = request_of(e)
    ins, rem = plan_slots(ins, mc.index), plan_slots(rem, mc.index)
    for i = 1, mc.slots do
      local st = mc.inv[i]
      local text = string.format('%d %s', i, st.valid_for_read and label(st.name, st.quality.name) or 'empty')
      local notes = {}
      if ins[i - 1] then notes[#notes+1] = label(ins[i - 1].name, ins[i - 1].quality) .. ' requested' end
      if rem[i - 1] then notes[#notes+1] = label(rem[i - 1].name, rem[i - 1].quality) .. ' coming out' end
      out[i] = text .. (#notes > 0 and ' (' .. table.concat(notes, '; ') .. ')' or '')
    end
    return out
  end

  -- Sets one machine's modules. p: the player, bot or remote proxy; e: the machine or its ghost; want: M.parse's
  -- result; near: the character sees it (configure_target); by: nil, 'hand' or 'robots'.
  -- The checks set makes before it changes anything: the machine's slots, and each module named against the machine
  -- and its recipe (a place_ghosts dry run makes them on the prototype: d17 batch18 A3).
  function M.check(proto, recipe, slots, want, text)
    assert(slots > 0, string.format('%s has no module slots', text))
    local plural = slots == 1 and '' or 's'
    if want.kind == 'set' and #want.list > slots then
      error(string.format('%s has %d module slot%s; %d given', text, slots, plural, #want.list), 0)
    end
    if want.kind == 'slots' and want.n > slots then
      error(string.format('%s has %d module slot%s; slot %d named', text, slots, plural, want.n), 0)
    end
    for _, w in ipairs(M.named(want)) do
      local why = M.why_not(proto, recipe, w, text)
      if why then error(why, 0) end
    end
  end
  function M.set(p, e, want, near, by)
    local mc = machine(e)
    M.check(mc.proto, mc.recipe, mc.slots, want, mc.text)
    local row = {name=e.type == 'entity-ghost' and e.ghost_name or e.name, position={x=e.position.x, y=e.position.y}, ghost=mc.ghost or nil}
    -- A ghost: its insert plan's module rows, slot by slot.
    if mc.ghost then
      assert(by ~= 'hand', 'a ghost takes modules as requests: by=hand needs a built machine')
      local plans = try(function() return e.insert_plan end) or {}
      local before = plan_slots(plans, mc.index)
      local slot = targets(want, setmetatable({}, {__index=function(_, i) return before[i - 1] or false end}), mc.slots)
      local slots = {}
      for i = 1, mc.slots do
        local m = slot[i]
        if m == 'keep' then m = before[i - 1] end
        if m then slots[i - 1] = m end
      end
      e.insert_plan = replan(plans, mc.index, slots)
      row.by = 'ghost'
      row.before = M.text(list_of(before))
      row.requested = M.text(list_of(slots))
      row.by_slot = M.by_slot(e)
      row.note = 'the robots that build it bring them'
      return row
    end
    local inv = mc.inv
    local now = {}
    for i = 1, mc.slots do now[i] = inv[i].valid_for_read and {name=inv[i].name, quality=inv[i].quality.name} or false end
    row.before = M.text(tally(now))
    local reach = near and try(function() return p.can_reach_entity(e) end)
    local hand = by == 'hand' or (by == nil and reach)
    if by == 'hand' and not reach then error(api.out_of_reach and api.out_of_reach(p, e) or 'entity is out of reach', 0) end
    local proxy, old_ins, old_rem = request_of(e)
    local pend_ins, pend_rem = plan_slots(old_ins, mc.index), plan_slots(old_rem, mc.index)
    if hand then
      local slot = targets(want, now, mc.slots)
      local main = p.get_main_inventory()
      local change, out_of, need = {}, {}, {}
      for i = 1, mc.slots do
        if slot[i] ~= 'keep' and not same(now[i], slot[i]) then
          change[#change+1] = i
          if now[i] then out_of[key(now[i].name, now[i].quality)] = (out_of[key(now[i].name, now[i].quality)] or 0) + 1 end
          if slot[i] then
            local k = key(slot[i].name, slot[i].quality)
            need[k] = need[k] or {name=slot[i].name, quality=slot[i].quality, n=0}
            need[k].n = need[k].n + 1
          end
        end
      end
      if #change == 0 then row.by = 'hand'; row.unchanged = true; row.after = row.before; row.by_slot = M.by_slot(e); return row end
      local short = {}
      for k, x in pairs(need) do
        local held = main.get_item_count{name=x.name, quality=x.quality}
        if held + (out_of[k] or 0) < x.n then
          short[#short+1] = string.format('%s: %d needed, you hold %d', label(x.name, x.quality), x.n - (out_of[k] or 0), held)
        end
      end
      if #short > 0 then
        table.sort(short)
        error(string.format('not enough modules in your inventory for %s (%s); by="robots" requests them instead', mc.text, table.concat(short, '; ')), 0)
      end
      for _, i in ipairs(change) do
        local w = slot[i]
        if w and not inv[i].can_set_stack{name=w.name, quality=w.quality, count=1} then
          error(string.format('the game refuses %s in slot %d of %s', label(w.name, w.quality), i, mc.text), 0)
        end
      end
      -- The old ones out first (to the inventory, else spilled at the character's feet), then the new ones in.
      local returned, spilled = {}, {}
      for _, i in ipairs(change) do
        local st = inv[i]
        if st.valid_for_read then
          local name, quality = st.name, st.quality.name
          local moved = main.insert{name=name, quality=quality, count=st.count}
          returned[#returned+1] = {name=name, quality=quality}
          if moved < st.count then
            spilled[#spilled+1] = {name=name, quality=quality}
            p.surface.spill_item_stack{position=p.position, stack={name=name, quality=quality, count=st.count - moved}, enable_looted=true, allow_belts=false}
          end
          st.clear()
        end
      end
      for _, i in ipairs(change) do
        local w = slot[i]
        if w then
          main.remove{name=w.name, quality=w.quality, count=1}
          inv[i].set_stack{name=w.name, quality=w.quality, count=1}
        end
      end
      -- Robot requests on the slots set by hand go (they would undo it).
      if proxy then
        local dropped = false
        for _, i in ipairs(change) do
          if pend_ins[i - 1] or pend_rem[i - 1] then pend_ins[i - 1], pend_rem[i - 1], dropped = nil, nil, true end
        end
        if dropped then
          local ni, nr = replan(old_ins, mc.index, pend_ins), replan(old_rem, mc.index, pend_rem)
          if #ni == 0 and #nr == 0 then proxy.destroy() else proxy.insert_plan = ni; proxy.removal_plan = nr end
          row.note = 'the robot requests on the slots set were cleared'
        end
      end
      local after = {}
      for i = 1, mc.slots do after[i] = inv[i].valid_for_read and {name=inv[i].name, quality=inv[i].quality.name} or false end
      row.by = 'hand'
      row.after = M.text(tally(after))
      row.returned = #returned > 0 and M.text(tally(returned)) .. ' (to your inventory)' or nil
      row.spilled = #spilled > 0 and M.text(tally(spilled)) .. ' (no room: on the ground at your feet)' or nil
      row.by_slot = M.by_slot(e)
      return row
    end
    -- An item request on the built machine, slot by slot: the new modules in, the old ones out. A slot's module is
    -- what it will hold once the requests on it are done (cur), so a list leaves a module on its way in where it goes.
    local cur = {}
    for i = 1, mc.slots do
      if pend_ins[i - 1] then cur[i] = pend_ins[i - 1]
      elseif pend_rem[i - 1] then cur[i] = false
      else cur[i] = now[i] end
    end
    local slot = targets(want, cur, mc.slots)
    local ins, rem, changed = {}, {}, false
    for i = 1, mc.slots do
      if slot[i] == 'keep' then
        ins[i - 1], rem[i - 1] = pend_ins[i - 1], pend_rem[i - 1]
      elseif not same(now[i], slot[i]) then
        if slot[i] then ins[i - 1] = slot[i] end
        if now[i] then rem[i - 1] = now[i] end
        if not (same(pend_ins[i - 1], slot[i] or nil) and same(pend_rem[i - 1], now[i] or nil)) then changed = true end
      elseif pend_ins[i - 1] or pend_rem[i - 1] then changed = true
      end
    end
    local new_ins, new_rem = replan(old_ins, mc.index, ins), replan(old_rem, mc.index, rem)
    row.by = try(function() return e.surface.platform end) and 'hub' or 'robots'
    if not next(ins) and not next(rem) then
      row.unchanged = true; row.after = row.before
      if proxy then
        if #new_ins == 0 and #new_rem == 0 then proxy.destroy() else proxy.insert_plan = new_ins; proxy.removal_plan = new_rem end
        if next(pend_ins) or next(pend_rem) then row.note = 'its module requests were cleared: the slots hold that already' end
      end
      row.by_slot = M.by_slot(e)
      return row
    end
    if proxy then
      proxy.insert_plan = new_ins
      proxy.removal_plan = new_rem
    else
      proxy = e.surface.create_entity{name='item-request-proxy', position=e.position, force=e.force, target=e, modules=new_ins, removal_plan=new_rem}
      assert(proxy, 'the game made no item request for ' .. mc.text)
    end
    row.unchanged = not changed or nil
    row.requested = next(ins) and M.text(list_of(ins)) or nil
    row.removing = next(rem) and M.text(list_of(rem)) or nil
    row.by_slot = M.by_slot(e)
    row.note = M.carrier(e, list_of(ins), next(rem) and list_of(rem) or nil)
    -- Plainly (Sol, d15: three such requests read as installed modules): nothing is in the slots yet.
    if row.requested or row.removing then
      row.pending = string.format('nothing installed or removed yet: %s%s%s is a request for robots (pending until one arrives)',
        row.requested and row.requested or '', row.requested and row.removing and '; ' or '', row.removing and 'taking out ' .. row.removing or '')
    end
    return row
  end

  -- What inspect adds to modules: the requests on a machine (its item request) or ghost (its insert plan).
  function M.requests(e)
    local mc = try(function() return machine(e) end)
    if not mc or mc.slots == 0 then return nil end
    local ins, rem
    if mc.ghost then ins = plan_slots(try(function() return e.insert_plan end), mc.index)
    else
      local proxy = try(function() return e.item_request_proxy end)
      if proxy and proxy.valid then
        ins = plan_slots(try(function() return proxy.insert_plan end), mc.index)
        rem = plan_slots(try(function() return proxy.removal_plan end), mc.index)
      end
    end
    local out = {}
    if ins and next(ins) then out.requested = M.text(list_of(ins)) end
    if rem and next(rem) then out.removing = M.text(list_of(rem)) end
    return next(out) and out or nil
  end
  return M
end
