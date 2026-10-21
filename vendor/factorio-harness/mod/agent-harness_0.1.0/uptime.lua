-- uptime {positions, seconds?} (d20 batch53 M3, Sol #1304: the surface's production and a working snapshot disagreed in
-- short supply gaps; which science machine lost time, and why, took dozens of reads). Crafting machines watched over a
-- window as a player watching them sees them: each one's status once a second (the GUI's status line), the ingredients
-- short of one craft in its input at each sample that reads short of ingredients, and the crafts it finished (each
-- craft a player sees finish; the game's products_finished count, read at the start and the end). One watch an agent,
-- up to MAX machines, sampled in the background; uptime {} reads it, so far or done. Left out (said in the reply): what
-- happens between samples (a stop shorter than a second may not be seen), the exact ticks in each status (shares are
-- of samples), and why an ingredient is short upstream.
-- (d20 batch54 N2, viewer Aurora: "Sampling every 60 ticks can miss a 20-tick pulse entirely") sample k comes at
-- start + 60 k + (7 k mod 60) ticks, a phase 7 ticks later each second, so 60 samples meet every tick of a second once
-- and a machine working 20 ticks of every 60 reads a third of the time whatever its phase; the last at the window's end.
-- (d20 batch55 P4, Sol #1393: an EM plant read 106 crafts in 161 s, 153% of its 25.8/min, while working all the time)
-- products_finished counts every completion, the productivity bar's too. The base crafts come from it with the bar:
-- base x (1 + productivity) = completions + bar at the end - bar at the start (bonus_progress, 0..1); crafts are the
-- base ones against the full-speed craft rate, completions against that rate with productivity.
-- (d20 batch55 P7, Astra #1426: a crusher on advanced-carbonic with +40% asteroid productivity read 20.3 crafts/min,
-- "106%" of 19.2, productivity 0) the productivity is the game's sum, the machine's and the recipe's research, capped
-- (craftrate.productivity). The bar fills with crafting progress (2.0.77: 3 bar a craft at +300%, partway through a craft
-- too), so the split counts the craft in progress at both ends: base x (1 + p) = completions + bar1 - bar0 - p x
-- (progress1 - progress0). Productivity is read each sample; one that changed, or could not be read, makes the base
-- crafts unknown (said so, with the completions).
-- (d20 batch55 P8, Sol #1439: a biolab was refused as not a crafting machine) labs and biolabs too: the status samples
-- (working, missing science packs, no power, as the lab GUI shows), the packs held at each sample, and what was used.
-- 2.0.77 keeps no count per lab; a pack in a lab loses durability as it researches (the private copy: a biolab drained
-- 0.099 of each pack in 123 ticks, the research progress gained times its 50% drain) and is gone at 0, and a spoiled
-- pack's result goes to the lab's trash slot. Used is the durability drained between samples: a pack put in or taken
-- out whole changes the held durability by whole packs, so the drain is the change modulo a pack while a lab cannot
-- drain a whole pack between samples (its researching speed with its bonus, the research's unit time, the lab's drain
-- rate); otherwise that interval is unknown, and so is one where a spoilable pack spoiled (spoil results counted
-- apart). The force's research progress on its current technology and the surface's science packs used up (the
-- production statistics, whole packs, every lab there) are given beside, for all labs.
return function(api)
  local M = {}
  M.MAX, M.EVERY, M.STEP = 16, 60, 7
  local function next_at(job)
    local k = job.samples
    return math.min(job.start + M.EVERY * k + (M.STEP * k) % M.EVERY, job.until_tick)
  end
  local CRAFT = {['assembling-machine']=true, furnace=true, ['rocket-silo']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function store() local s = api.state(); s.uptime = s.uptime or {}; return s.uptime end
  local function input_inv(e)
    local which = e.type == 'furnace' and defines.inventory.furnace_source or defines.inventory.assembling_machine_input
    return try(function() return e.get_inventory(which) end)
  end
  -- (d20 batch58 T1, Sol #1453: a rare quality-module-3 recipe holding rare circuits read every ingredient short, least
  -- 0) a recipe runs at a quality and takes its item ingredients at that quality; get_item_count(name) counts normal
  -- ones only (2.0.77, the private copy: 40 uncommon plates read 0 by name, 40 with the quality). Fluids have none.
  local function quality_name(q) return type(q) == 'string' and q or q and try(function() return q.name end) or 'normal' end
  local function recipe_of(e)
    local ok, r, q = pcall(function() return e.get_recipe() end)
    if not ok then r, q = nil, nil end
    if not r and e.type == 'furnace' then
      local prev = try(function() return e.previous_recipe end)
      local n = prev and (type(prev.name) == 'table' and prev.name.name or prev.name)
      r, q = n and try(function() return e.force.recipes[n] end), prev and prev.quality
    end
    return r, r and quality_name(q) or nil
  end
  local function qlabel(name, q) return q and q ~= 'normal' and string.format('%s (%s)', name, q) or name end
  local function finished(e) return try(function() return e.products_finished end) or 0 end
  local function bar(e) return try(function() return e.bonus_progress end) or 0 end
  local function progress(e) return try(function() return e.crafting_progress end) or 0 end
  local function pct(v) return math.floor(v * 100 + 0.5) end
  -- Base crafts and productivity completions in `done` completions, the bar from b0 to b1 and the craft in progress
  -- from c0 to c1 at productivity prod.
  function M.split(done, b0, b1, prod, c0, c1)
    local base = done
    if prod and prod > 0 then base = math.floor((done + (b1 or 0) - (b0 or 0) - prod * ((c1 or 0) - (c0 or 0))) / (1 + prod) + 0.5) end
    base = math.max(0, math.min(done, base))
    return base, done - base
  end
  -- The productivity craftrate read (the game's sum, capped) and its parts.
  function M.keep_prod(m, rt)
    if not rt then return end
    m.prod, m.prod_machine, m.prod_research = rt.productivity, rt.productivity_machine, rt.productivity_research
  end
  local function prod_text(m)
    local t = string.format('productivity +%d%%', pct(m.prod or 0))
    if m.prod_research then
      t = t .. string.format(': the machine\'s +%d%%, research +%d%%', pct(m.prod_machine or 0), pct(m.prod_research))
      if (m.prod_machine or 0) + m.prod_research > m.prod + 0.0005 then t = t .. ', capped' end
    end
    return t
  end
  -- Labs. The packs a lab holds: {name: {n, d (durability held, in packs' durability), q (any above normal quality)}}.
  local durability = {}
  local function max_of(name)
    if durability[name] == nil then durability[name] = try(function() return prototypes.item[name].get_durability() end) or 1 end
    return durability[name]
  end
  local function lab_packs(e)
    local out, order = {}, {}
    local inv = try(function() return e.get_inventory(defines.inventory.lab_input) end)
    for i = 1, inv and #inv or 0 do
      local st = inv[i]
      if st.valid_for_read then
        local o = out[st.name]
        if not o then o = {n=0, d=0}; order[#order+1] = st.name end
        local q = try(function() return st.quality.name end) or 'normal'
        local max = max_of(st.name)
        o.n = o.n + st.count
        o.d = o.d + (st.count - 1) * max + (try(function() return st.durability end) or max)
        if q ~= 'normal' then o.q = true end
        out[st.name] = o
      end
    end
    return out, order
  end
  local function lab_trash(e)
    local out = {}
    local inv = try(function() return e.get_inventory(defines.inventory.lab_trash) end)
    for _, it in ipairs(inv and try(function() return inv.get_contents() end) or {}) do out[it.name] = (out[it.name] or 0) + it.count end
    return out
  end
  -- The most of a pack a lab can drain in `ticks`: its researching speed with its bonus (the force's lab speed in it)
  -- over the research's unit time, times the most of a pack a unit takes and the lab's drain rate.
  local function lab_most(e, ticks)
    local r = try(function() return e.force.current_research end)
    if not r then return 0 end
    local speed = (try(function() return e.prototype.get_researching_speed(e.quality) end) or 1) * (1 + (try(function() return e.speed_bonus end) or 0))
    local energy = try(function() return r.research_unit_energy end) or 0
    if energy <= 0 then return nil end
    local amount = 1
    for _, i in ipairs(try(function() return r.research_unit_ingredients end) or {}) do amount = math.max(amount, i.amount or 1) end
    local drain = (try(function() return e.prototype.science_pack_drain_rate_percent end) or 100) / 100
    return speed * ticks / energy * amount * drain * 1.05
  end
  local function spoils(name)
    return (try(function() return prototypes.item[name].get_spoil_ticks() end) or 0) > 0
  end
  function M.sample_lab(m, e)
    m.n = (m.n or 0) + 1
    local now, order = lab_packs(e)
    local trash = lab_trash(e)
    local rose = false
    for n, c in pairs(trash) do
      local d = c - (m.trash_last[n] or 0)
      if d > 0 then m.spoiled[n] = (m.spoiled[n] or 0) + d; rose = true end
    end
    m.trash_last = trash
    local ticks = m.last_tick and game.tick - m.last_tick
    local most = ticks and ticks > 0 and lab_most(e, ticks)
    for _, name in ipairs(order) do
      local o = now[name]
      if not m.packs[name] then m.packs[name] = {n=0, d=0, least=m.n > 1 and 0 or o.n, most=0, empty=m.n - 1, used=0, unknown=0, intervals=0}; m.order[#m.order+1] = name end
    end
    for _, name in ipairs(m.order) do
      local pk, o = m.packs[name], now[name] or {n=0, d=0}
      pk.least, pk.most = math.min(pk.least, o.n), math.max(pk.most, o.n)
      if o.n == 0 then pk.empty = pk.empty + 1 end
      if ticks and ticks > 0 then
        pk.intervals = pk.intervals + 1
        local max, why = max_of(name), nil
        if o.q or pk.q then why = 'packs above normal quality'
        elseif rose and o.n < pk.n and spoils(name) then why = 'packs spoiled'
        elseif not most or most >= max then why = 'it could use a whole pack between samples' end
        if why then pk.unknown = pk.unknown + 1; pk.why = pk.why or why
        else
          local used = (pk.d - o.d) % max
          if used > max - 1e-6 then used = 0 end
          pk.used = pk.used + used
        end
      end
      pk.n, pk.d, pk.q = o.n, o.d, o.q
    end
    m.last_tick = game.tick
  end
  -- The force's research: progress on its current technology, in units, sample to sample.
  local function research_now(force)
    local r = try(function() return force.current_research end)
    return r and {name=r.name, level=try(function() return r.level end), progress=try(function() return force.research_progress end) or 0,
      units=try(function() return r.research_unit_count end) or 0} or {}
  end
  function M.sample_research(job)
    local rs = job.research
    local force = game.forces[rs.force]
    if not force then return end
    local now = research_now(force)
    local last = rs.last
    if now.name == last.name and now.level == last.level then
      if now.name then rs.units = rs.units + (now.progress - last.progress) * now.units end
    elseif now.name == last.name then
      -- an infinite technology's next level
      rs.units = rs.units + (1 - last.progress) * last.units + now.progress * now.units
      rs.finished[#rs.finished+1] = string.format('%s level %s', last.name, tostring(last.level))
    else
      local done = last.name and try(function() return force.technologies[last.name].researched end)
      if done then rs.units = rs.units + (1 - last.progress) * last.units; rs.finished[#rs.finished+1] = last.name end
      rs.changes[#rs.changes+1] = string.format('%s -> %s%s', last.name or 'none', now.name or 'none', done and ' (finished)' or '')
    end
    rs.last = now
  end
  function M.sample(job)
    job.samples = job.samples + 1
    if job.research then M.sample_research(job) end
    for _, m in ipairs(job.machines) do
      local e = m.e
      if not (e and e.valid) then m.gone = m.gone or game.tick
      elseif m.lab then
        local st = api.status_name and api.status_name(e) or 'unknown'
        m.status[st] = (m.status[st] or 0) + 1
        M.sample_lab(m, e)
      else
        local st = api.status_name and api.status_name(e) or 'unknown'
        m.status[st] = (m.status[st] or 0) + 1
        local r, rq = recipe_of(e)
        local rn = r and r.name or 'none'
        -- an idle furnace reads no recipe: the last one seen is kept
        if rn ~= 'none' and (rn ~= m.recipe or rq ~= m.recipe_quality) then
          if m.recipe ~= 'none' then m.recipe_changed = m.recipe_changed or (qlabel(m.recipe, m.recipe_quality) .. ' -> ' .. qlabel(rn, rq)) end
          m.recipe, m.recipe_quality = rn, rq
          if not m.full_cpm and api.craftrate then local rt = try(function() return api.craftrate(e) end); m.full_cpm = rt and rt.crafts_per_min or nil; if m.prod == nil then M.keep_prod(m, rt) end end
        end
        local pr = r and m.prod ~= nil and api.productivity and try(function() return api.productivity(e, r) end)
        if pr and math.abs(pr.total - m.prod) > 0.0005 then m.prod_changed = m.prod_changed or string.format('+%d%% -> +%d%%', pct(m.prod), pct(pr.total)) end
        if st == 'item_ingredient_shortage' or st == 'fluid_ingredient_shortage' then
          local inv = input_inv(e)
          for _, ing in ipairs(r and try(function() return r.ingredients end) or {}) do
            local have
            if ing.type == 'fluid' then have = try(function() return e.get_fluid_count(ing.name) end) or 0
            else have = inv and try(function() return inv.get_item_count({name=ing.name, quality=rq or 'normal'}) end) or 0 end
            if have < (ing.amount or 0) then
              local key = ing.type == 'fluid' and ing.name or qlabel(ing.name, rq)
              local s = m.short[key] or {samples=0, least=have, need=ing.amount}
              s.samples = s.samples + 1
              if have < s.least then s.least = have end
              m.short[key] = s
            end
          end
        end
      end
    end
  end
  local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
  local function status_parts(m, samples)
    local states, parts = {}, {}
    for k, n in pairs(m.status) do states[#states+1] = {k, n} end
    table.sort(states, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
    for _, s in ipairs(states) do parts[#parts+1] = string.format('%s %d%%', (s[1]:gsub('_', ' ')), math.floor(s[2] / math.max(1, samples) * 100 + 0.5)) end
    return parts
  end
  function M.lab_row(job, m, secs)
    local packs, used, held, unknown = {}, {}, {}, {}
    for _, name in ipairs(m.order) do
      local pk = m.packs[name]
      local n = r2(pk.used / max_of(name))
      packs[#packs+1] = {name=name, used=n, held_least=pk.least, held_most=pk.most, empty_samples=pk.empty > 0 and pk.empty or nil,
        unknown_intervals=pk.unknown > 0 and pk.unknown or nil, of_intervals=pk.intervals, unknown_why=pk.why}
      used[#used+1] = string.format('%s %s%g', name, pk.unknown > 0 and 'at least ' or '', n)
      held[#held+1] = string.format('%s %s', name, pk.most == 0 and 'none' or pk.least == pk.most and tostring(pk.least) or pk.least .. '-' .. pk.most)
        .. (pk.empty > 0 and pk.most > 0 and string.format(' (none in %d sample%s)', pk.empty, pk.empty == 1 and '' or 's') or '')
      if pk.unknown > 0 then unknown[#unknown+1] = string.format('%s in %d of %d intervals (%s)', name, pk.unknown, pk.intervals, pk.why) end
    end
    local spoiled = {}
    for n, c in pairs(m.spoiled) do spoiled[#spoiled+1] = string.format('%s %d', n, c) end
    table.sort(spoiled)
    local parts = status_parts(m, job.samples)
    local row = {kind='lab', name=m.name, position=m.position, samples=m.status, working_share=job.samples > 0 and math.floor((m.status.working or 0) / job.samples * 100 + 0.5) or nil,
      packs=packs, spoil_results=#spoiled > 0 and spoiled or nil, gone=m.gone and 'removed' or nil}
    row.line = string.format('%s %s: %s; %s%s%s%s', m.name, at(m.position), #parts > 0 and table.concat(parts, ', ') or 'no sample yet',
      #packs > 0 and string.format('packs used in %ds (durability drained): %s; held at the samples: %s', math.floor(secs + 0.5), table.concat(used, ', '), table.concat(held, ', ')) or 'held no science packs',
      #unknown > 0 and '; used unknown for ' .. table.concat(unknown, '; ') or '',
      #spoiled > 0 and '; spoil results in its trash: ' .. table.concat(spoiled, ', ') or '', m.gone and '; removed during the watch' or '')
    return row
  end
  -- The force's research and the surface's packs used up, for every lab: nil without a lab in the watch.
  function M.research_result(job)
    local rs = job.research
    if not rs then return nil end
    local research = {technology=rs.last.name, units=r2(rs.units), finished=#rs.finished > 0 and rs.finished or nil, changed=#rs.changes > 0 and rs.changes or nil}
    research.line = string.format('the force\'s research gained %g units%s while the watch ran (every lab of the force)%s', research.units,
      rs.last.name and ' on ' .. rs.last.name or '', #rs.finished > 0 and '; finished: ' .. table.concat(rs.finished, ', ') or '')
    local used, words = {}, {}
    local surface = game.surfaces[job.pack_stats.surface]
    local stats = surface and try(function() return game.forces[rs.force].get_item_production_statistics(surface) end)
    for _, name in ipairs(job.pack_stats.names) do
      local n = stats and try(function() return stats.get_output_count(name) end)
      local d = n and n - (job.pack_stats.counts[name] or 0)
      if d and d > 0 then used[name] = d; words[#words+1] = string.format('%s %d', name, d) end
    end
    return research, {by_pack=used, line=string.format('science packs used up on %s while the watch ran (the production statistics: whole packs, every lab there): %s',
      job.pack_stats.surface, #words > 0 and table.concat(words, ', ') or 'none')}
  end
  function M.result(job, done)
    local secs = (game.tick - job.start) / 60
    local rows, lines = {}, {}
    for _, m in ipairs(job.machines) do
      if m.lab then
        local row = M.lab_row(job, m, secs)
        rows[#rows+1] = row
        lines[#lines+1] = row.line
        goto next_machine
      end
      do
      local e = m.e
      local now = e and e.valid and finished(e) or m.last_finished
      if e and e.valid then m.last_finished, m.last_bar, m.last_progress = now, bar(e), progress(e) end
      local done = math.max(0, (now or m.finished0) - m.finished0)
      local unknown
      if m.prod == nil then unknown = 'its productivity could not be read'
      elseif m.prod_changed then unknown = 'its productivity changed during the watch (' .. m.prod_changed .. ')'
      elseif m.recipe_changed and m.prod > 0 then unknown = 'its recipe changed during the watch' end
      local crafts, bonus
      if not unknown then crafts, bonus = M.split(done, m.bar0, m.last_bar, m.prod, m.progress0, m.last_progress) end
      local states, parts = {}, {}
      for k, n in pairs(m.status) do states[#states+1] = {k, n} end
      table.sort(states, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
      local share = {}
      for _, s in ipairs(states) do
        share[s[1]] = s[2]
        parts[#parts+1] = string.format('%s %d%%', (s[1]:gsub('_', ' ')), math.floor(s[2] / math.max(1, job.samples) * 100 + 0.5))
      end
      local short = {}
      for n, s in pairs(m.short) do short[#short+1] = string.format('%s short in %d sample%s (least %g of %g a craft)', n, s.samples, s.samples == 1 and '' or 's', s.least, s.need) end
      table.sort(short)
      local function pm(n) return secs > 0 and math.floor(n / secs * 600 + 0.5) / 10 or 0 end
      local cpm, dpm = crafts and pm(crafts), pm(done)
      local prod = m.prod or 0
      local full_done = m.full_cpm and math.floor(m.full_cpm * (1 + prod) * 10 + 0.5) / 10 or nil
      local row = {name=m.name, position=m.position, recipe=m.recipe, recipe_quality=m.recipe ~= 'none' and (m.recipe_quality or 'normal') or nil, crafts=crafts, crafts_per_min=cpm, full_speed_per_min=m.full_cpm,
        completions=done, bonus_completions=bonus, completions_per_min=dpm, full_speed_completions_per_min=prod > 0 and full_done or nil,
        productivity=prod > 0 and prod or nil, productivity_research=m.prod_research, crafts_unknown=unknown and 'base crafts unknown: ' .. unknown or nil, working_share=job.samples > 0 and math.floor((share.working or 0) / job.samples * 100 + 0.5) or nil,
        samples=share, short=#short > 0 and short or nil, recipe_changed=m.recipe_changed, gone=m.gone and 'removed' or nil}
      local made
      if unknown then
        made = string.format('%d completion%s in %ds (%g/min against %s/min at full speed, %s); base crafts unknown: %s', done, done == 1 and '' or 's', math.floor(secs + 0.5), dpm,
          full_done and string.format('%g', full_done) or '?', prod_text(m), unknown)
      else
        made = string.format('%d craft%s in %ds (%g/min%s)%s', crafts, crafts == 1 and '' or 's', math.floor(secs + 0.5), cpm,
          m.full_cpm and m.full_cpm > 0 and string.format(', %d%% of its %g/min at full speed', math.floor(cpm / m.full_cpm * 100 + 0.5), m.full_cpm) or '',
          prod > 0 and string.format(' and %d productivity completion%s (%s): %d completions, %g/min against %s/min at full speed', bonus, bonus == 1 and '' or 's',
            prod_text(m), done, dpm, full_done and string.format('%g', full_done) or '?') or '')
      end
      row.line = string.format('%s %s %s: %s; %s%s%s', m.name, at(m.position), qlabel(m.recipe, m.recipe_quality), made,
        #parts > 0 and table.concat(parts, ', ') or 'no sample yet', #short > 0 and '; ' .. table.concat(short, '; ') or '',
        m.gone and '; removed during the watch' or m.recipe_changed and '; recipe changed: ' .. m.recipe_changed or '')
      rows[#rows+1] = row
      lines[#lines+1] = row.line
      end
      ::next_machine::
    end
    local research, used_up = M.research_result(job)
    return {done=done or nil, research=research, packs_used_up=used_up, watching=not done or nil, seconds=math.floor(secs + 0.5), of_seconds=job.seconds, samples=job.samples, every_ticks=M.EVERY, phase_step_ticks=M.STEP,
      started_tick=job.start, machines=rows, lines=lines,
      left_out='status once a second at a phase 7 ticks later each second (60 samples meet every tick of a second once): a stop shorter than a second may not be seen and shares are of samples, not exact ticks; completions are the machine\'s finished count (productivity\'s included), crafts the base ones from it and its productivity bar (a craft in progress at either end is not counted); why an ingredient is short upstream is not read (supply or trace for that)' .. (job.research and '; a lab\'s packs used are their durability drained between samples (a pack moved partly used, or spoil results taken out within a second, are not seen); research and packs used up are the force\'s and the surface\'s, not one lab\'s' or '')}
  end
  function M.tick(tick)
    local all = api.state().uptime
    if not all then return end
    for _, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        M.sample(job)
        job.next_tick = next_at(job)
        if tick >= job.until_tick then
          job.result = M.result(job, true)
          for _, m in ipairs(job.machines) do m.e = nil end
        end
      end
    end
  end
  function M.handler(p, a)
    if a.positions == nil and a.position == nil then
      local job = store()[p.index]
      assert(job, 'no uptime watch yet: uptime {positions, seconds?}')
      return job.result or M.result(job, false)
    end
    local list = a.positions or {a.position}
    assert(type(list) == 'table' and #list >= 1 and #list <= M.MAX, 'positions: 1..' .. M.MAX .. ' crafting machines {x,y}')
    local seconds = a.seconds == nil and 600 or a.seconds
    assert(type(seconds) == 'number' and seconds >= 10 and seconds <= 3600 and seconds == math.floor(seconds), 'seconds: 10..3600 (default 600)')
    local q = a.surface ~= nil and api.on_surface(p, a.surface) or a.platform ~= nil and api.on_platform(p, a.platform) or p
    local machines, labs = {}, nil
    for _, pos in ipairs(list) do
      local e = api.remote_entity(q, {position=pos})
      assert(CRAFT[e.type] or e.type == 'lab', string.format('%s %s is not a crafting machine or a lab (an assembler, furnace, chemical plant, biochamber, lab, biolab, ...)', e.name, at(e.position)))
      if e.type == 'lab' then
        machines[#machines+1] = {lab=true, e=e, name=e.name, position={x=e.position.x, y=e.position.y}, status={}, packs={}, order={}, spoiled={}, trash_last=lab_trash(e)}
        labs = labs or {force=e.force, surface=e.surface.name, names={}, seen={}}
        for _, n in ipairs(try(function() return e.prototype.lab_inputs end) or {}) do
          if not labs.seen[n] then labs.seen[n] = true; labs.names[#labs.names+1] = n end
        end
        goto next_position
      end
      do
      local r, rq = recipe_of(e)
      local rates = api.craftrate and try(function() return api.craftrate(e) end)
      local m = {e=e, name=e.name, position={x=e.position.x, y=e.position.y}, recipe=r and r.name or 'none', recipe_quality=rq, finished0=finished(e),
        bar0=bar(e), progress0=progress(e), status={}, short={}, full_cpm=rates and rates.crafts_per_min or nil}
      M.keep_prod(m, rates)
      machines[#machines+1] = m
      end
      ::next_position::
    end
    local replaced = store()[p.index] and not store()[p.index].result
    local job = {start=game.tick, until_tick=game.tick + seconds * 60, next_tick=game.tick, seconds=seconds, samples=0, machines=machines}
    if labs then
      job.research = {force=labs.force.name, last=research_now(labs.force), units=0, finished={}, changes={}}
      local stats = try(function() return labs.force.get_item_production_statistics(game.surfaces[labs.surface]) end)
      job.pack_stats = {surface=labs.surface, names=labs.names, counts={}}
      for _, n in ipairs(labs.names) do job.pack_stats.counts[n] = stats and try(function() return stats.get_output_count(n) end) or 0 end
    end
    store()[p.index] = job
    M.sample(job)
    job.next_tick = next_at(job)
    local lines = {}
    for _, m in ipairs(machines) do
      if m.lab then
        local held = {}
        for _, name in ipairs(m.order) do held[#held+1] = string.format('%s %d', name, m.packs[name].n) end
        lines[#lines+1] = string.format('%s %s: holds %s', m.name, at(m.position), #held > 0 and table.concat(held, ', ') or 'no science packs')
      else lines[#lines+1] = string.format('%s %s %s: %d completions so far (the game\'s count, productivity\'s included)', m.name, at(m.position), qlabel(m.recipe, m.recipe_quality), m.finished0) end
    end
    return {watching=true, seconds=seconds, machines=#machines, baseline=lines, replaced=replaced and 'your earlier watch, still running, was replaced' or nil,
      line=string.format('watching %d machine%s for %ds, a status sample a second at a phase 7 ticks later each second: uptime {} reads it so far, and in full once done', #machines, #machines == 1 and '' or 's', seconds)}
  end
  M.schema = {uptime = {positions='1..16 crafting machines or labs {x,y} (an assembler, furnace, chemical plant, biochamber, lab, biolab, ...; in sight or by remote view)', position='or one',
    seconds='optional 10..3600 (default 600): how long to watch', surface='optional planet name (by remote view)', platform='optional platform name',
    returns='a watch, one an agent (a new one replaces it): the start returns baseline (each machine\'s completions so far) and line; uptime {} reads it so far (watching) or done: per machine crafts (base crafts finished in the window), crafts_per_min against full_speed_per_min (its recipe at its speed), completions (the game\'s count: crafts and productivity completions), bonus_completions, completions_per_min against full_speed_completions_per_min (with its productivity), productivity (the game\'s sum: the machine\'s with modules and beacons, and the recipe\'s research, capped at the recipe\'s maximum), productivity_research, crafts_unknown (base crafts and bonus_completions left out when productivity changed during the watch or could not be read, or the recipe changed), working_share (% of samples working), samples by status (the GUI\'s status line, once a second), recipe_quality (the quality its recipe runs at), short (each ingredient under one craft in its input at the samples that read short of ingredients, items counted at the recipe\'s quality and named with it: how many samples, the least held), recipe_changed, gone; a lab\'s row (kind lab): samples by status (working, missing science packs, no power, ...), working_share, packs [{name, used (packs: their durability drained between samples; 2.0.77 keeps no count per lab), held_least, held_most, empty_samples, unknown_intervals, of_intervals, unknown_why (a lab that could use a whole pack between samples, a spoilable pack spoiled, packs above normal quality)}], spoil_results (what spoiled packs left in its trash); with a lab, research {technology, units (the force\'s progress gained, every lab), finished, changed, line} and packs_used_up {by_pack, line} (the surface\'s production statistics: whole packs, every lab there); lines; left_out (what the watch does not see). Read only'}}
  return M
end
