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
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  -- (d20 batch58 T2, Astra #1461: a 20-furnace bank took two 16-machine windows) up to 64 machines, or the crafting
  -- machines in an area (up to AREA_SIDE tiles a side, optionally of one recipe), with per-recipe totals beside the rows.
  -- A reply's numbers are what its encoding pays for (the private copy: helpers.table_to_json took 23 ms for 64 rows of
  -- 15 fields and 0.07 ms for 64 lines of text): above ROWS machines the rows are left out and lines carries each one;
  -- group rows up to GROUP_ROWS groups, flow rows up to FLOW_ROWS.
  M.MAX, M.EVERY, M.STEP, M.AREA_SIDE, M.ITEMS, M.ROWS, M.GROUP_ROWS, M.FLOW_ROWS = 64, 60, 7, 200, 8, 16, 8, 10
  local function next_at(job)
    local k = job.samples
    return math.min(job.start + M.EVERY * k + (M.STEP * k) % M.EVERY, job.until_tick)
  end
  local CRAFT = {['assembling-machine']=true, furnace=true, ['rocket-silo']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- the operator profiler's parts (profile_ticks): uptime.area, uptime.machines, uptime.flows, uptime.sample
  local function timed(label, fn, ...) if api.timed then return api.timed(label, fn, ...) end return fn(...) end
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
  -- (d24 batch201 QN1, Astra #2302: two silos read 19 completions in 600 s while Aquilo's statistics counted 879 rocket
  -- parts) a rocket silo's products_finished counts rockets, not parts (silo.lua's parts made): on a copy of world n
  -- (2.0.77) it went up by one in the tick rocket_parts went 50 -> 0 (create_rocket), the silo built parts through every
  -- launch phase, and a full productivity bar added its part to rocket_parts; over 9466 ticks the two Aquilo silos'
  -- finished x 50 + rocket_parts rose 113 + 160 and the surface's rocket-part produced 273. So a silo's completions are
  -- rocket parts: finished rockets x the parts a rocket takes, plus rocket_parts (it never drops at a launch). parts=
  -- false keeps the game's count (a watch begun before this counted it so).
  local function finished(e, parts)
    if parts and e.type == 'rocket-silo' then
      local fin = try(function() return e.products_finished end)
      if not fin then return 0 end
      local req = try(function() return e.prototype.rocket_parts_required end) or 1
      return fin * req + (try(function() return e.rocket_parts end) or 0)
    end
    return try(function() return e.products_finished end) or 0
  end
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
  -- (d20 batch58 T3, Sol #1460) the outputs a machine finished, by quality, as its output slot shows them: between two
  -- samples the completions (products_finished) times each product's amount must equal what its output slot gained,
  -- every quality gaining or level, for the gain to be the products made; otherwise products were taken out (or spoiled)
  -- in between and that interval is unknown. A recipe with a product by chance or in a range has no fixed amount: unknown.
  local function output_inv(e)
    if e.type == 'rocket-silo' then return nil end
    local which = e.type == 'furnace' and defines.inventory.furnace_result or defines.inventory.assembling_machine_output
    return try(function() return e.get_inventory(which) end)
  end
  local function fixed_products(r)
    local out = {}
    for _, pr in ipairs(r and try(function() return r.products end) or {}) do
      if pr.type ~= 'fluid' then
        if not pr.amount or (pr.probability or 1) ~= 1 or (pr.extra_count_fraction or 0) ~= 0 or (pr.ignored_by_productivity or 0) ~= 0 then return nil end
        out[#out+1] = {name=pr.name, amount=pr.amount}
      end
    end
    return #out > 0 and out or nil
  end
  local function output_counts(e, products)
    local inv = output_inv(e)
    local contents = inv and try(function() return inv.get_contents() end)
    if not contents then return nil end
    local want, out = {}, {}
    for _, pr in ipairs(products) do want[pr.name] = true; out[pr.name] = {} end
    for _, it in ipairs(contents) do
      if want[it.name] then local q = quality_name(it.quality); out[it.name][q] = (out[it.name][q] or 0) + it.count end
    end
    return out
  end
  function M.sample_outputs(m, e, r)
    local products = m.products
    if products == nil then products = fixed_products(r) or false; m.products = products end
    if not products then return end
    local now, fin = output_counts(e, products), finished(e)
    if not now then m.products = false; return end
    if m.out_last then
      local done = fin - m.out_fin
      if done > 0 then
        m.out_intervals = (m.out_intervals or 0) + 1
        local ok = true
        for _, pr in ipairs(products) do
          local gain = 0
          for q, n in pairs(now[pr.name]) do local d = n - (m.out_last[pr.name][q] or 0); if d < 0 then ok = false end; gain = gain + d end
          for q, n in pairs(m.out_last[pr.name]) do if not now[pr.name][q] and n > 0 then ok = false end end
          if gain ~= done * pr.amount then ok = false end
        end
        if ok then
          m.outputs = m.outputs or {}
          for _, pr in ipairs(products) do
            local t = m.outputs[pr.name] or {}
            for q, n in pairs(now[pr.name]) do local d = n - (m.out_last[pr.name][q] or 0); if d > 0 then t[q] = (t[q] or 0) + d end end
            m.outputs[pr.name] = t
          end
        else m.out_unknown = (m.out_unknown or 0) + 1 end
      end
    end
    m.out_last, m.out_fin = now, fin
  end
  local QORDER = {normal=1, uncommon=2, rare=3, epic=4, legendary=5}
  local function by_quality(t)
    local qs = {}
    for q in pairs(t) do qs[#qs+1] = q end
    table.sort(qs, function(x, y) return (QORDER[x] or 9) < (QORDER[y] or 9) or ((QORDER[x] or 9) == (QORDER[y] or 9) and x < y) end)
    return qs
  end
  local function outputs_text(m)
    if not m.products or not m.out_intervals then return nil end
    local words = {}
    for _, pr in ipairs(m.products) do
      local t, parts = (m.outputs or {})[pr.name] or {}, {}
      for _, q in ipairs(by_quality(t)) do parts[#parts+1] = string.format('%s %d', q, t[q]) end
      words[#words+1] = string.format('%s %s', pr.name, #parts > 0 and table.concat(parts, ', ') or 'none')
    end
    return string.format('outputs by quality in its output slot: %s%s', table.concat(words, '; '),
      (m.out_unknown or 0) > 0 and string.format(' (%d of %d intervals with completions unknown: products taken out or spoiled between samples)', m.out_unknown, m.out_intervals) or '')
  end
  function M.prod_now(e, r)
    if api.productivity_now then return api.productivity_now(e, r) end
    local pr = api.productivity and api.productivity(e, r)
    return pr and pr.total
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
  -- (d20 batch79 AO1, Astra #1845: five machines read 3 low_power samples of 601 with no way to tell when) per machine,
  -- each status other than working: its first and last sample tick and the longest run of samples in a row; and the
  -- last CHANGES status changes with their ticks
  M.CHANGES = 8
  local QUIET = {working=true, normal=true}
  local function note_status(m, st, tick)
    if st ~= m.prev then
      if m.prev then
        local c = m.changes or {}
        c[#c+1] = {tick, m.prev, st}
        if #c > M.CHANGES then table.remove(c, 1) end
        m.changes = c
      end
      m.prev, m.run = st, 0
    end
    m.run = m.run + 1
    if not QUIET[st] then
      local runs = m.runs or {}
      m.runs = runs
      local r = runs[st]
      if not r then r = {first=tick, longest=0}; runs[st] = r end
      r.last = tick
      if m.run > r.longest then r.longest = m.run end
    end
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
        note_status(m, st, game.tick)
        M.sample_lab(m, e)
      else
        local st = api.status_name and api.status_name(e) or 'unknown'
        m.status[st] = (m.status[st] or 0) + 1
        note_status(m, st, game.tick)
        local r, rq = recipe_of(e)
        local rn = r and r.name or 'none'
        -- an idle furnace reads no recipe: the last one seen is kept
        if rn ~= 'none' and (rn ~= m.recipe or rq ~= m.recipe_quality) then
          if m.recipe ~= 'none' then m.recipe_changed = m.recipe_changed or (qlabel(m.recipe, m.recipe_quality) .. ' -> ' .. qlabel(rn, rq)) end
          m.recipe, m.recipe_quality = rn, rq
          if not m.full_cpm and api.craftrate then local rt = try(function() return api.craftrate(e) end); m.full_cpm = rt and rt.crafts_per_min or nil; if m.prod == nil then M.keep_prod(m, rt) end end
        end
        if r and r.name == m.recipe and not m.recipe_changed then M.sample_outputs(m, e, r) end
        -- the machine's figure and the recipe's research, capped (craftrate.productivity), read without a table a sample
        if r and m.prod ~= nil and not m.prod_changed then
          local ok, total = pcall(M.prod_now, e, r)
          if ok and total and math.abs(total - m.prod) > 0.0005 then m.prod_changed = string.format('+%d%% -> +%d%%', pct(m.prod), pct(total)) end
        end
        if st == 'item_ingredient_shortage' or st == 'fluid_ingredient_shortage' then
          local inv = input_inv(e)
          for _, ing in ipairs(r and try(function() return r.ingredients end) or {}) do
            local have
            if ing.type == 'fluid' then have = try(function() return e.get_fluid_count(ing.name) end) or 0
            else have = inv and try(function() return inv.get_item_count({name=ing.name, quality=rq or 'normal'}) end) or 0 end
            if have < (ing.amount or 0) then
              local key = ing.type == 'fluid' and ing.name or qlabel(ing.name, rq)
              local s = m.short[key] or {samples=0, least=have, need=ing.amount, first=game.tick}
              s.samples, s.last = s.samples + 1, game.tick
              if have < s.least then s.least = have end
              m.short[key] = s
            end
          end
        end
      end
    end
    -- (d20 batch70 AF1) when it was last read, and whether anything is left to read (measures.lua: the idle count)
    local live = #job.machines == 0
    for _, m in ipairs(job.machines) do if not m.gone then live = true; break end end
    job.sampled, job.all_gone = game.tick, not live or nil
  end
  local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
  -- (AO1) a machine's statuses other than working: status_runs {status = {samples, first_tick, last_tick, first_s,
  -- last_s, longest_run}}, changes (its last status changes, 'tick: from -> to'; only with such a status) and the
  -- line's part; nil for a machine that only worked
  function M.timing(job, m)
    if not m.runs then return nil end
    local list = {}
    for st, r in pairs(m.runs) do list[#list+1] = {st=st, r=r, n=m.status[st] or 0} end
    table.sort(list, function(x, y) return x.n > y.n or (x.n == y.n and x.st < y.st) end)
    local runs, parts = {}, {}
    local function sec(t) return math.floor((t - job.start) / 60 + 0.5) end
    for _, x in ipairs(list) do
      local r = x.r
      runs[x.st] = {samples=x.n, first_tick=r.first, last_tick=r.last, first_s=sec(r.first), last_s=sec(r.last), longest_run=r.longest}
      parts[#parts+1] = r.first == r.last and string.format('%s at %d s (tick %d)', (x.st:gsub('_', ' ')), sec(r.first), r.first)
        or string.format('%s from %d s to %d s (ticks %d-%d), at most %d sample%s in a row', (x.st:gsub('_', ' ')), sec(r.first), sec(r.last), r.first, r.last,
          r.longest, r.longest == 1 and '' or 's')
    end
    local changes
    for _, c in ipairs(m.changes or {}) do
      changes = changes or {}
      changes[#changes+1] = string.format('%d: %s -> %s', c[1], c[2], c[3])
    end
    return {status_runs=runs, changes=changes, text='when: ' .. table.concat(parts, '; ')}
  end
  -- a status's share of the samples; (AO1) one that rounds to 0% gives its count too
  local function share_text(st, n, samples)
    local v = math.floor(n / math.max(1, samples) * 100 + 0.5)
    return string.format('%s %d%%%s', (st:gsub('_', ' ')), v, v == 0 and n > 0 and string.format(' (%d of %d samples)', n, samples) or '')
  end
  M.share_text = share_text
  local function status_parts(m, samples)
    local states, parts = {}, {}
    for k, n in pairs(m.status) do states[#states+1] = {k, n} end
    table.sort(states, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
    for _, s in ipairs(states) do parts[#parts+1] = share_text(s[1], s[2], samples) end
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
    local tm = M.timing(job, m)
    local row = {kind='lab', name=m.name, position=m.position, samples=m.status, working_share=job.samples > 0 and math.floor((m.status.working or 0) / job.samples * 100 + 0.5) or nil,
      packs=packs, spoil_results=#spoiled > 0 and spoiled or nil, gone=m.gone and 'removed' or nil, status_runs=tm and tm.status_runs, changes=tm and tm.changes}
    row.line = string.format('%s %s: %s%s; %s%s%s%s', m.name, at(m.position), #parts > 0 and table.concat(parts, ', ') or 'no sample yet', tm and '; ' .. tm.text or '',
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
      local n = stats and job.pack_stats.q and try(function() return qflow.count(stats, name, 'output') end)
      local d = n and n - (job.pack_stats.counts[name] or 0)
      if d and d > 0 then used[name] = d; words[#words+1] = string.format('%s %d', name, d) end
    end
    return research, {by_pack=used, line=string.format('science packs used up on %s while the watch ran (the production statistics: whole packs, every lab there): %s',
      job.pack_stats.surface, #words > 0 and table.concat(words, ', ') or 'none')}
  end
  -- (d24 batch182 QY1, Astra #2044: "Physical recipe 2 out plus 0.5 bonus, 1 seed returned => 260 gross/156 net. Does
  -- native production statistics or supply made already subtract ignored seed?") An item a recipe gives or takes with
  -- ignored_by_stats (pentapod-egg's own recipe takes 1 egg and gives 2; barrels, kovarex, fish breeding, coal
  -- liquefaction, fluoroketone, an item recycled into itself): what the crafts put out (gross: amount a craft, and per
  -- productivity completion the amount past ignored_by_productivity), took in, gave back (the amount on both sides), net,
  -- and what the production statistics count of it (made: the amount past ignored_by_stats, a productivity completion's
  -- whole; used: the ingredient past its ignored_by_stats). Measured on a private copy of world n's shift70 save, Gleba's
  -- six breeders at +50% over 66 s: 109 crafts and 54 productivity completions, 272 eggs out, 109 back in, 163 net; the
  -- statistics counted 163 made, and used 166 = 138 agricultural science crafts + 28 eggs a heating tower burned.
  local function mean(p) return (p.amount or (((p.amount_min or 0) + (p.amount_max or 0)) / 2)) * (p.probability or 1) + (p.extra_count_fraction or 0) end
  local function num(n) return math.floor(n * 10 + 0.5) / 10 end
  local plain = {}   -- recipe names with no ignored_by_stats item (a prototype read is 40-200 us)
  function M.returned(recipe_name, crafts, bonus)
    if not recipe_name or not crafts or plain[recipe_name] then return nil end
    local r = try(function() return prototypes.recipe[recipe_name] end)
    if not r then return nil end
    local by, order = {}, {}
    local function row(name)
      if not by[name] then by[name] = {item=name, out=0, ['in']=0, made=0, used=0, per_craft_out=0, per_bonus_out=0, per_craft_in=0, ignored_out=0, ignored_in=0}; order[#order+1] = name end
      return by[name]
    end
    local any = {}
    for _, p in ipairs(try(function() return r.products end) or {}) do
      if (p.ignored_by_stats or 0) > 0 then any[p.name] = true end
    end
    for _, i in ipairs(try(function() return r.ingredients end) or {}) do
      if (i.ignored_by_stats or 0) > 0 then any[i.name] = true end
    end
    if not next(any) then plain[recipe_name] = true; return nil end
    for _, p in ipairs(r.products or {}) do
      if any[p.name] then
        local x, a = row(p.name), mean(p)
        local extra = math.max(0, a - (p.ignored_by_productivity or 0))
        x.per_craft_out, x.per_bonus_out, x.ignored_out = x.per_craft_out + a, x.per_bonus_out + extra, x.ignored_out + (p.ignored_by_stats or 0)
        x.out = x.out + crafts * a + bonus * extra
        x.made = x.made + crafts * math.max(0, a - (p.ignored_by_stats or 0)) + bonus * extra
      end
    end
    for _, i in ipairs(r.ingredients or {}) do
      if any[i.name] then
        local x = row(i.name)
        x.per_craft_in, x.ignored_in = x.per_craft_in + (i.amount or 0), x.ignored_in + (i.ignored_by_stats or 0)
        x['in'] = x['in'] + crafts * (i.amount or 0)
        x.used = x.used + crafts * math.max(0, (i.amount or 0) - (i.ignored_by_stats or 0))
      end
    end
    local out = {}
    for _, name in ipairs(order) do
      local x = by[name]
      local back = math.min(x.ignored_out, x.per_craft_out, x.ignored_in, x.per_craft_in)   -- given back: ignored on both sides
      local res = {item=name, out=num(x.out), ['in']=num(x['in']), returned=back > 0 and num(crafts * back) or nil, net=num(x.out - x['in']),
        statistics_made=num(x.made), statistics_used=num(x.used)}
      local parts = {}
      if x.per_craft_out > 0 then parts[#parts+1] = string.format('%g out (%g a craft%s)', res.out, num(x.per_craft_out),
        bonus > 0 and string.format(', %g a productivity completion', num(x.per_bonus_out)) or '') end
      if x.per_craft_in > 0 then parts[#parts+1] = string.format('%g in (%g a craft)', res['in'], num(x.per_craft_in)) end
      res.line = string.format('%s: %s%s, net %g; the production statistics count %g made and %g used of it for these crafts (ignored_by_stats: %s)',
        name, table.concat(parts, ' and '), back > 0 and string.format(', %g of them returned (the %g a craft it takes back in)', res.returned, num(back)) or '', res.net,
        res.statistics_made, res.statistics_used,
        back > 0 and string.format('the returned %g a craft on neither side%s', num(back), res.statistics_used == 0 and res.statistics_made == res.net and ', so made is the net' or '')
          or (x.ignored_out > 0 and string.format('%g a craft out not counted made', num(x.ignored_out)) or string.format('%g a craft in not counted used', num(x.ignored_in))))
      out[#out+1] = res
    end
    return out
  end
  -- Totals by recipe (and its quality) over the crafting machines in the watch: completions and crafts (crafts when
  -- every machine's are known), their rates against the summed full-speed rates, and status shares of all their samples.
  function M.groups(rows, job, secs)
    local by, order = {}, {}
    for _, row in ipairs(rows) do
      if not row.kind and row.recipe ~= 'none' then
        local key = qlabel(row.recipe, row.recipe_quality)
        local g = by[key]
        if not g then g = {recipe=row.recipe, recipe_quality=row.recipe_quality, machines=0, completions=0, crafts=0, unknown=0, full=0, full_done=0, samples={}, n=0}; by[key] = g; order[#order+1] = key end
        g.machines = g.machines + 1
        g.completions = g.completions + row.completions
        if row.crafts then g.crafts = g.crafts + row.crafts else g.unknown = g.unknown + 1 end
        g.full = g.full + (row.full_speed_per_min or 0)
        g.full_done = g.full_done + (row.full_speed_completions_per_min or row.full_speed_per_min or 0)
        for k, n in pairs(row.samples or {}) do g.samples[k] = (g.samples[k] or 0) + n; g.n = g.n + n end
      end
    end
    if #order == 0 or #rows < 2 then return nil end
    local function pm(n) return secs > 0 and math.floor(n / secs * 600 + 0.5) / 10 or 0 end
    local out, lines = {}, {}
    for _, key in ipairs(order) do
      local g = by[key]
      local parts = status_parts({status=g.samples}, g.n)
      local shares = {}
      for k, n in pairs(g.samples) do shares[k] = math.floor(n / math.max(1, g.n) * 100 + 0.5) end
      local row = {recipe=g.recipe, recipe_quality=g.recipe_quality, machines=g.machines, completions=g.completions, completions_per_min=pm(g.completions),
        full_speed_completions_per_min=math.floor(g.full_done * 10 + 0.5) / 10, crafts=g.unknown == 0 and g.crafts or nil, crafts_per_min=g.unknown == 0 and pm(g.crafts) or nil,
        full_speed_per_min=math.floor(g.full * 10 + 0.5) / 10, crafts_unknown_machines=g.unknown > 0 and g.unknown or nil, status_shares=shares}
      row.line = string.format('%s on %d machine%s: %d completions in %ds (%g/min against %g/min at full speed)%s; %s', key, g.machines, g.machines == 1 and '' or 's',
        g.completions, math.floor(secs + 0.5), row.completions_per_min, row.full_speed_completions_per_min,
        g.unknown == 0 and string.format(', %d crafts (%g/min against %g/min)', g.crafts, row.crafts_per_min, row.full_speed_per_min)
          or string.format(', base crafts unknown on %d of them', g.unknown),
        #parts > 0 and 'samples ' .. table.concat(parts, ', ') or 'no sample yet')
      row.returned = g.unknown == 0 and M.returned(g.recipe, g.crafts, g.completions - g.crafts) or nil
      for _, x in ipairs(row.returned or {}) do row.line = row.line .. '; ' .. x.line end
      out[#out+1] = row
      lines[#lines+1] = row.line
    end
    return out, lines
  end
  -- (d20 batch58 T3, Sol #1460) items produced and consumed on the watch's surface by quality, from the production
  -- statistics (the game keeps them by quality in 2.0.77: on the private copy an uncommon gear recipe's 9 crafts read 9
  -- uncommon gears produced and 20 uncommon plates consumed; the name alone counts normal ones): the counts at the start
  -- and now, every machine and hand on the surface. An item named without a quality is read at every quality.
  local function qualities()
    local out = {}
    for name, q in pairs(prototypes.quality or {}) do
      if name ~= 'quality-unknown' and not try(function() return q.hidden end) then out[#out+1] = name end
    end
    table.sort(out, function(x, y) return (QORDER[x] or 9) < (QORDER[y] or 9) or ((QORDER[x] or 9) == (QORDER[y] or 9) and x < y) end)
    return out
  end
  local function flow_stats(force, surface)
    return try(function() return force.get_item_production_statistics(surface) end)
  end
  function M.flows_start(force, surface, items)
    assert(type(items) == 'table' and #items >= 1 and #items <= M.ITEMS, 'items: 1..' .. M.ITEMS .. ' items, a name ("iron-gear-wheel", every quality) or {name, quality}')
    local stats = flow_stats(force, surface)
    assert(stats, 'no production statistics for ' .. surface.name)
    local rows, recent = {}, {}
    for _, it in ipairs(items) do
      local name, quality = it, nil
      if type(it) == 'table' then name, quality = it.name, it.quality end
      assert(type(name) == 'string' and prototypes.item[name], 'items: ' .. tostring(name) .. ' is not an item')
      assert(quality == nil or (type(quality) == 'string' and prototypes.quality[quality]), 'items: quality ' .. tostring(quality) .. ' is not a quality')
      for _, q in ipairs(quality and {quality} or qualities()) do
        local id = {name=name, quality=q}
        local r = {name=name, quality=q, produced0=try(function() return stats.get_input_count(id) end) or 0, consumed0=try(function() return stats.get_output_count(id) end) or 0}
        r.named = quality ~= nil
        rows[#rows+1] = r
        local function last(cat, idx) return try(function() return stats.get_flow_count{name=id, category=cat, precision_index=idx, count=true} end) or 0 end
        local p10, c10 = last('input', defines.flow_precision_index.ten_minutes), last('output', defines.flow_precision_index.ten_minutes)
        if quality or p10 > 0 or c10 > 0 then recent[#recent+1] = string.format('%s: produced %d, consumed %d', qlabel(name, q), math.floor(p10 + 0.5), math.floor(c10 + 0.5)) end
      end
    end
    return {force=force.name, surface=surface.name, rows=rows},
      string.format('the production statistics on %s, the last 10 minutes: %s', surface.name, #recent > 0 and table.concat(recent, '; ') or 'none of them at any quality')
  end
  function M.flows_result(job, secs)
    local f = job.flows
    if not f then return nil end
    local surface, force = game.surfaces[f.surface], game.forces[f.force]
    local stats = surface and force and flow_stats(force, surface)
    local rows, words = {}, {}
    local function pm(n) return secs > 0 and math.floor(n / secs * 600 + 0.5) / 10 or 0 end
    for _, r in ipairs(f.rows) do
      local id = {name=r.name, quality=r.quality}
      local p = stats and try(function() return stats.get_input_count(id) end)
      local c = stats and try(function() return stats.get_output_count(id) end)
      if p and c then
        local dp, dc = p - r.produced0, c - r.consumed0
        if r.named or dp > 0 or dc > 0 then
          rows[#rows+1] = {name=r.name, quality=r.quality, produced=dp, consumed=dc, net=dp - dc, produced_per_min=pm(dp), consumed_per_min=pm(dc)}
          words[#words+1] = string.format('%s produced %d (%g/min), consumed %d (%g/min)', qlabel(r.name, r.quality), dp, pm(dp), dc, pm(dc))
        end
      else words[#words+1] = qlabel(r.name, r.quality) .. ' unknown (the statistics could not be read)' end
    end
    return {surface=f.surface, rows=rows, line=string.format('production statistics on %s in %ds (every machine and hand there): %s', f.surface, math.floor(secs + 0.5),
      #words > 0 and table.concat(words, '; ') or 'none of them produced or consumed at any quality')}
  end
  -- (QN1) the watched silos' parts beside the surface's production statistics of their product over the watch.
  function M.silo_result(job, secs)
    local st = job.silo_stats
    if not st then return nil end
    local made, n = 0, 0
    for _, m in ipairs(job.machines) do
      if m.parts and m.recipe == st.item then
        local e = m.e
        local now = e and e.valid and finished(e, true) or m.last_finished or m.finished0
        made, n = made + math.max(0, now - m.finished0), n + 1
      end
    end
    local surface, force = game.surfaces[st.surface], game.forces[st.force]
    local stats = surface and force and flow_stats(force, surface)
    local c = stats and try(function() return qflow.count(stats, st.item, 'input') end)
    local produced = c and c - st.n0 or nil
    return {item=st.item, surface=st.surface, silos=n, silos_made=made, statistics_produced=produced,
      line=string.format('%s: the %d watched silo%s made %d in %ds; the production statistics on %s counted %s produced (every silo there, productivity\'s included)',
        st.item, n, n == 1 and '' or 's', made, math.floor(secs + 0.5), st.surface, produced and tostring(produced) or 'unknown (could not be read)')}
  end
  -- (d25 batch214 QZ1) one crafting machine's row and line, secs into the watch (M.result's, and a page's of read: true)
  function M.machine_row(job, m, secs)
    local e = m.e
    local now = e and e.valid and finished(e, m.parts) or m.last_finished
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
      parts[#parts+1] = share_text(s[1], s[2], job.samples)
    end
    local short = {}
    for n, s in pairs(m.short) do
      short[#short+1] = string.format('%s short in %d sample%s (least %g of %g a craft%s)', n, s.samples, s.samples == 1 and '' or 's', s.least, s.need,
        s.first and (s.first == s.last and string.format('; tick %d', s.first) or string.format('; ticks %d-%d', s.first, s.last)) or '')
    end
    table.sort(short)
    local function pm(n) return secs > 0 and math.floor(n / secs * 600 + 0.5) / 10 or 0 end
    local cpm, dpm = crafts and pm(crafts), pm(done)
    local prod = m.prod or 0
    local full_done = m.full_cpm and math.floor(m.full_cpm * (1 + prod) * 10 + 0.5) / 10 or nil
    local row = {name=m.name, position=m.position, recipe=m.recipe, recipe_quality=m.recipe ~= 'none' and (m.recipe_quality or 'normal') or nil, crafts=crafts, crafts_per_min=cpm, full_speed_per_min=m.full_cpm,
      completions=done, bonus_completions=bonus, completions_per_min=dpm, full_speed_completions_per_min=prod > 0 and full_done or nil,
      productivity=prod > 0 and prod or nil, productivity_research=m.prod_research, crafts_unknown=unknown and 'base crafts unknown: ' .. unknown or nil, working_share=job.samples > 0 and math.floor((share.working or 0) / job.samples * 100 + 0.5) or nil,
      samples=share, short=#short > 0 and short or nil, recipe_changed=m.recipe_changed, gone=m.gone and 'removed' or nil,
      outputs_by_quality=m.products and m.out_intervals and (m.outputs or {}) or nil, outputs_unknown_intervals=m.products and (m.out_unknown or 0) > 0 and m.out_unknown or nil,
      outputs_intervals=m.products and m.out_intervals or nil}
    row.returned = crafts and M.returned(m.recipe, crafts, bonus or 0) or nil
    if m.parts then row.completions_are = 'rocket parts: a silo\'s products_finished counts rockets, so completions are finished rockets x the parts a rocket takes plus rocket_parts (it does not drop at a launch); productivity\'s parts included'
    elseif e and e.valid and e.type == 'rocket-silo' then row.completions_are = 'rockets (the watch began before parts were counted: products_finished, one a rocket)' end
    local tm = M.timing(job, m)
    if tm then row.status_runs, row.changes = tm.status_runs, tm.changes end
    local otext = outputs_text(m)
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
    for _, x in ipairs(row.returned or {}) do made = made .. '; ' .. x.line end
    row.line = string.format('%s %s %s: %s; %s%s%s%s%s', m.name, at(m.position), qlabel(m.recipe, m.recipe_quality), made,
      #parts > 0 and table.concat(parts, ', ') or 'no sample yet', tm and '; ' .. tm.text or '', #short > 0 and '; ' .. table.concat(short, '; ') or '', otext and '; ' .. otext or '',
      m.gone and '; removed during the watch' or m.recipe_changed and '; recipe changed: ' .. m.recipe_changed or '')
    return row
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
      local row = M.machine_row(job, m, secs)
      rows[#rows+1] = row
      lines[#lines+1] = row.line
      end
      ::next_machine::
    end
    local research, used_up = M.research_result(job)
    local silo_stats = M.silo_result(job, secs)
    if silo_stats then lines[#lines+1] = silo_stats.line end
    local groups, group_lines = M.groups(rows, job, secs)
    local flows = M.flows_result(job, secs)
    if group_lines or flows then
      local all = {}
      for _, l in ipairs(group_lines or {}) do all[#all+1] = l end
      for _, l in ipairs(lines) do all[#all+1] = l end
      if flows then all[#all+1] = flows.line end
      lines = all
    end
    local machine_rows
    if #rows > M.ROWS then
      machine_rows = string.format('left out above %d machines (each one is in lines); a watch of %d or fewer gives them', M.ROWS, M.ROWS)
      rows = nil
    end
    if groups and #groups > M.GROUP_ROWS then groups = nil end
    if flows and #flows.rows > M.FLOW_ROWS then flows.rows = nil end
    return {done=done or nil, groups=groups, group_lines=group_lines, flows=flows, silo_statistics=silo_stats, research=research, packs_used_up=used_up, machine_rows=machine_rows, watching=not done or nil, seconds=math.floor(secs + 0.5), of_seconds=job.seconds, samples=job.samples, every_ticks=M.EVERY, phase_step_ticks=M.STEP,
      started_tick=job.start, machines=rows, lines=lines,
      left_out='status once a second at a phase 7 ticks later each second (60 samples meet every tick of a second once): a stop shorter than a second may not be seen and shares are of samples, not exact ticks; completions are the machine\'s finished count (productivity\'s included): crafts finished, not items, each giving the recipe\'s products once (a productivity completion the amount past ignored_by_productivity: 1 pentapod-egg of 2), crafts the base ones from it and its productivity bar (a craft in progress at either end is not counted); returned (a recipe that gives or takes an item with ignored_by_stats) is figured from the crafts and the recipe: out, in, the amount given back, net, and what the production statistics count; why an ingredient is short upstream is not read (supply or trace for that); outputs by quality are what each output slot gained over intervals whose gain matched the completions (products taken out between samples make an interval unknown)' .. (job.research and '; a lab\'s packs used are their durability drained between samples (a pack moved partly used, or spoil results taken out within a second, are not seen); research and packs used up are the force\'s and the surface\'s, not one lab\'s' or '')}
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
          job.ended_tick = tick  -- (QZ1) a page read of it counts to here
          for _, m in ipairs(job.machines) do m.e = nil end
        end
      end
    end
  end
  -- (d25 batch219 QAD1, Sol #2394: Astra's queue configured modules on two of Sol's 13 machines at tick 64293983;
  -- mixed.lua split Sol's watch there, twice on that tick, and the window before it was kept only as a part's lines,
  -- out of the 3 parts kept after more edits; uptime@64263843/sol could not be read) mixed.lua closes the watch at an
  -- edit it starts again after: the old watch is done at that tick with its final (as one done at its end, its
  -- machines' counts frozen there), kept whole on the new one as a segment (new.segments, oldest first), and read by
  -- its id or segment_start as a done watch. At most SEGMENTS, their machines together at most SEGMENT_MACHINES; past
  -- that the second oldest goes (the first, the watch as begun, is kept), segments_dropped counting them.
  M.SEGMENTS, M.SEGMENT_MACHINES = 4, 128
  function M.close(job, new, tick, why)
    job.result = M.result(job, true)
    job.ended_tick = tick
    for _, m in ipairs(job.machines) do m.e = nil end
    job.closed_by, job.next_tick = why, math.huge
    local segs, dropped = job.segments or {}, job.segments_dropped or 0
    job.segments, job.segments_dropped = nil, nil
    segs[#segs+1] = job
    local held = 0
    for _, g in ipairs(segs) do held = held + #g.machines end
    while #segs > 2 and (#segs > M.SEGMENTS or held > M.SEGMENT_MACHINES) do
      held = held - #segs[2].machines
      table.remove(segs, 2)
      dropped = dropped + 1
    end
    if new then new.segments, new.segments_dropped = segs, dropped > 0 and dropped or nil end
    job.result.segment_start = job.start
    return job.result
  end
  -- The segments a watch keeps, for its reads.
  function M.segment_rows(job, i)
    if not job.segments or #job.segments == 0 then return nil end
    local rows = {}
    for k, g in ipairs(job.segments) do
      rows[k] = {id=api.watch_id and i and api.watch_id('uptime', g, i) or string.format('uptime@%d', g.start), segment_start=g.start, ended_tick=g.ended_tick,
        seconds=math.floor((g.ended_tick - g.start) / 60 + 0.5), samples=g.samples, machines=#g.machines, closed_by=g.closed_by}
    end
    return rows
  end
  M.SEG_NOTE = 'segments: the windows an edit to what the watch measures (see mixed) closed before this one began, each kept whole as a done watch: uptime {read: true, id} or {read: true, segment_start} reads one in pages; at most ' .. M.SEGMENTS .. ', their machines together at most ' .. M.SEGMENT_MACHINES .. '; past that the second oldest goes first (the first window is kept; segments_dropped counts them)'
  -- The crafting machines of ours in an area (up to AREA_SIDE tiles a side), optionally of one recipe (and quality), at
  -- most MAX; a found one still has to be in sight (remote_entity).
  function M.in_area(q, a)
    local ar = a.area
    local lt, rb = type(ar) == 'table' and (ar.left_top or ar[1]), type(ar) == 'table' and (ar.right_bottom or ar[2])
    local x0, y0 = lt and (lt.x or lt[1]), lt and (lt.y or lt[2])
    local x1, y1 = rb and (rb.x or rb[1]), rb and (rb.y or rb[2])
    assert(type(x0) == 'number' and type(y0) == 'number' and type(x1) == 'number' and type(y1) == 'number' and x1 > x0 and y1 > y0,
      'area: {left_top={x,y}, right_bottom={x,y}}')
    assert(x1 - x0 <= M.AREA_SIDE and y1 - y0 <= M.AREA_SIDE, 'area: at most ' .. M.AREA_SIDE .. ' tiles a side')
    assert(a.recipe == nil or type(a.recipe) == 'string', 'recipe: a recipe name')
    local found = q.surface.find_entities_filtered{area={{x0, y0}, {x1, y1}}, type={'assembling-machine', 'furnace', 'rocket-silo'}, force=q.force, limit=4 * M.MAX}
    local out = {}
    for _, e in ipairs(found) do
      local r, rq = recipe_of(e)
      if not a.recipe or (r and r.name == a.recipe and (a.quality == nil or rq == a.quality)) then out[#out+1] = {position=e.position, unit_number=e.unit_number} end
    end
    assert(#out >= 1, string.format('no crafting machine of ours%s in that area', a.recipe and ' on ' .. a.recipe or ''))
    assert(#out <= M.MAX and #found < 4 * M.MAX, string.format('%s crafting machines%s in that area: at most %d (a smaller area, or name a recipe)',
      #found < 4 * M.MAX and tostring(#out) or 'more than ' .. #out, a.recipe and ' on ' .. a.recipe or '', M.MAX))
    return out
  end
  -- (d25 batch200 QM2) a new watch's seconds: the handler's check and a queue step's (runtime.lua step_ranges)
  M.SECONDS = {10, 3600}
  function M.starts(a) return a.read ~= true and (a.positions ~= nil or a.position ~= nil or a.area ~= nil or a.items ~= nil) end
  -- (d25 batch214 QZ1, Sol #2379: a 600 s watch of 20 machines gave machine_rows as a string above 16, so per-machine
  -- shortage counters could not be compared) read: true reads a watch in pages of structured rows, never starting or
  -- replacing one: yours, or by id (status work's "uptime@START") any agent's; positions picks machines of it. Checked
  -- with no world at submit and in dry_run (runtime.lua step_checks, step_ranges) as here.
  M.PAGE_MAX = M.MAX
  M.READ_NOT = {'seconds', 'area', 'items', 'position', 'surface', 'platform', 'recipe', 'quality', 'reason'}
  M.ID_LEN, M.AGENT_LEN = 96, 64
  M.MATCH = 2   -- a position picks the machine whose centre is nearest, within this many tiles on each axis
  function M.check_read(a)
    if a.read == nil then
      assert(a.id == nil and a.agent == nil and a.segment_start == nil, 'id, agent and segment_start go with read: true (uptime {read: true, id}); uptime {} reads yours whole')
      return
    end
    assert(a.read == true, 'read: true reads a watch in pages (uptime {} reads yours whole)')
    for _, k in ipairs(M.READ_NOT) do
      assert(a[k] == nil, string.format('read: true takes id, agent, segment_start, positions, page, page_size and details; %s goes with a new watch', k))
    end
    assert(a.id == nil or type(a.id) == 'string' and #a.id <= M.ID_LEN and (a.id:match('^uptime@%d+$') or a.id:match('^uptime@%d+/[^%s/]+$')),
      'id: a watch\'s id as status work gives it, "uptime@START_TICK/AGENT" (or "uptime@START_TICK" when one watch began on that tick)')
    assert(a.agent == nil or type(a.agent) == 'string' and #a.agent >= 1 and #a.agent <= M.AGENT_LEN, 'agent: an agent\'s name, up to ' .. M.AGENT_LEN .. ' characters: that agent\'s watch')
    local function whole(k, lo, hi)
      local v = a[k]
      assert(v == nil or type(v) == 'number' and v == math.floor(v) and v >= lo and v <= hi, string.format('%s: %d..%d', k, lo, hi))
    end
    whole('page', 1, M.PAGE_MAX)
    assert(a.segment_start == nil or type(a.segment_start) == 'number' and a.segment_start >= 0 and a.segment_start == math.floor(a.segment_start), 'segment_start: a segment\'s start tick (segments lists them)')
    whole('page_size', 1, M.ROWS)
    assert(a.details == nil or type(a.details) == 'boolean', 'details: true or false')
    if a.positions ~= nil then
      assert(type(a.positions) == 'table' and #a.positions >= 1 and #a.positions <= M.MAX, 'positions: 1..' .. M.MAX .. ' {x,y} of machines in the watch')
      for _, q in ipairs(a.positions) do
        assert(type(q) == 'table' and type(q.x or q[1]) == 'number' and type(q.y or q[2]) == 'number', 'positions: each {x,y}')
      end
    end
  end
  -- (d25 batch215 QZ3, Sol #2388: Sol's 13-machine and Astra's 41-machine watches began on tick 63906911, and its id
  -- gave Sol's own) The watch read: yours; by id (uptime@START_TICK/AGENT, measures.id) any agent's; by agent that
  -- agent's. An id with no agent reads the one watch begun on that tick, and two or more are refused, each named.
  local function norm(n) return (n:lower():gsub('^@', ''):gsub('^pog%-', '')) end
  local function id_of(job, i) return api.watch_id and api.watch_id('uptime', job, i) or string.format('uptime@%d', job.start) end
  local function find(p, a)
    local all = store()
    if a.id == nil and a.agent == nil then return all[p.index], p.index end
    local tick, who
    if a.id then
      local t, w = a.id:match('^uptime@(%d+)/?(.*)$')
      tick, who = tonumber(t), w ~= '' and norm(w) or nil
    end
    local want = a.agent and norm(a.agent)
    local hits, kept, gone = {}, {}, {}
    for i, job in pairs(all) do
      if type(job) == 'table' and job.start then
        local name = api.who_index and api.who_index(i)
        local mine = (not who or name and norm(name) == who) and (not want or name and norm(name) == want)
        -- (QAD1) a watch and the segments it keeps; (QR) the agent's kept watches and their segments
        local list = {{job}}
        for _, g in ipairs(job.segments or {}) do list[#list+1] = {g, job} end
        for _, k in ipairs(job.kept or {}) do
          list[#list+1] = {k, nil, job}
          for _, g in ipairs(k.segments or {}) do list[#list+1] = {g, k} end
        end
        for _, x in ipairs(list) do
          local w = x[1]
          local r = {job=w, i=i, id=id_of(w, i), n=#(w.machines or {}), of=x[2], by=x[3]}
          kept[#kept+1] = r
          if (not tick or w.start == tick) and mine and (tick or w == job) then hits[#hits+1] = r end
        end
        for _, d in ipairs(job.kept_dropped or {}) do
          if tick and d.start == tick and mine then gone[#gone+1] = d end
        end
      end
    end
    local function names(list)
      table.sort(list, function(x, y) return x.id < y.id end)
      local out = {}
      for _, r in ipairs(list) do out[#out+1] = string.format('%s (%d machine%s)', r.id, r.n, r.n == 1 and '' or 's') end
      return table.concat(out, ', ')
    end
    if #hits > 1 then
      error(string.format('%s: %d watches began on tick %d: %s; give one of these ids, or agent', a.id, #hits, tick, names(hits)), 0)
    end
    if #hits == 0 then
      local what = a.id and a.agent and a.id .. ' of agent ' .. a.agent or a.id or 'of agent ' .. a.agent
      local d = gone[#gone]
      if d then
        error(string.format('uptime watch %s (%d machine%s) was dropped at tick %d, when %s began: %s; kept: %s', d.id, d.machines, d.machines == 1 and '' or 's',
          d.tick, d.by, d.why, #kept > 0 and names(kept) or 'none'), 0)
      end
      error(string.format('no uptime watch %s is kept; kept: %s', what, #kept > 0 and names(kept) or 'none'), 0)
    end
    return hits[1].job, hits[1].i, hits[1].of, hits[1].by
  end
  -- (d26 batch225 QR, Sol #2413: Astra's 41-machine uptime@65848202/astra could not be read once Astra began
  -- uptime@65920807, and Sol needed its shortage timing) a new watch keeps the agent's previous one as a done watch:
  -- finished at that tick as close does if it was still running, its entity refs let go, never sampled again, read by
  -- its id. new.kept (oldest first) carries those kept before. At most KEPT, their machines (their segments' included)
  -- together at most KEPT_MACHINES; past that the oldest goes (the newest is always kept), each drop logged on
  -- new.kept_dropped (the last DROPPED) so a read of its id says when and why. A watch begun on the same tick holds
  -- nothing and is not kept. A split (mixed.lua, old.splitting) carries the kept ones on; close keeps the old one as a
  -- segment.
  M.KEPT, M.KEPT_MACHINES, M.DROPPED = 4, 96, 8
  local function held(w)
    local n = #(w.machines or {})
    for _, g in ipairs(w.segments or {}) do n = n + #(g.machines or {}) end
    return n
  end
  function M.keep(old, new, i, tick)
    if type(old) ~= 'table' or not old.start then return nil end
    local kept, log = old.kept or {}, old.kept_dropped or {}
    old.kept, old.kept_dropped = nil, nil
    new.kept, new.kept_dropped = #kept > 0 and kept or nil, #log > 0 and log or nil
    if old.splitting or old.start == tick then return nil end
    if not old.result then
      old.result = M.result(old, true)
      old.ended_tick, old.next_tick = tick, math.huge
      old.closed_by = string.format('finished %ds early: a new watch began', math.floor((old.until_tick - tick) / 60 + 0.5))
    end
    for _, m in ipairs(old.machines or {}) do m.e = nil end
    -- its final's lines and rows are what a page read makes again from its machines (45% of a 41-machine watch's 52 KB
    -- serpent line on the copy): left out; groups, flows, research and silo figures stay
    old.result.lines, old.result.machines, old.result.group_lines = nil, nil, nil
    old.ended_tick = old.ended_tick or old.until_tick
    old.id, old.kept_tick = id_of(old, i), tick
    kept[#kept+1] = old
    local n, out = 0, {}
    for _, w in ipairs(kept) do n = n + held(w) end
    while #kept > 1 and (#kept > M.KEPT or n > M.KEPT_MACHINES) do
      local why = #kept > M.KEPT and string.format('more than %d watches kept', M.KEPT) or string.format('the kept watches\' machines over %d', M.KEPT_MACHINES)
      local w = table.remove(kept, 1)
      n = n - held(w)
      local d = {id=id_of(w, i), start=w.start, ended_tick=w.ended_tick, machines=held(w), tick=tick, by=id_of(new, i), why=why}
      out[#out+1], log[#log+1] = d, d
    end
    while #log > M.DROPPED do table.remove(log, 1) end
    new.kept, new.kept_dropped = kept, #log > 0 and log or nil
    return out
  end
  -- The watches an agent's watch keeps, and those dropped, for its reads.
  function M.kept_rows(job, i)
    local rows, gone
    for k, w in ipairs(job.kept or {}) do
      rows = rows or {}
      rows[k] = {id=id_of(w, i), started_tick=w.start, ended_tick=w.ended_tick, seconds=math.floor(((w.ended_tick or w.until_tick) - w.start) / 60 + 0.5), samples=w.samples,
        machines=#(w.machines or {}), segments=w.segments and #w.segments > 0 and #w.segments or nil, closed_by=w.closed_by, kept_tick=w.kept_tick}
    end
    for k, d in ipairs(job.kept_dropped or {}) do
      gone = gone or {}
      gone[k] = {id=d.id, machines=d.machines, dropped_tick=d.tick, by=d.by, why=d.why}
    end
    return rows, gone
  end
  M.KEPT_NOTE = 'kept: your earlier watches, each done (one still running finished when the next began), read by uptime {read: true, id} in pages; at most ' .. M.KEPT .. ', their machines (their segments\' included) together at most ' .. M.KEPT_MACHINES .. '; past that the oldest goes first (the newest is always kept); kept_dropped lists the last ' .. M.DROPPED .. ' dropped, with when and why'
  local function kept_text(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do out[#out+1] = string.format('%s (%d machine%s)', r.id, r.machines, r.machines == 1 and '' or 's') end
    return table.concat(out, ', ')
  end
  function M.read(p, a)
    M.check_read(a)
    local job, owner, of, by = find(p, a)
    assert(job, 'no uptime watch yet: uptime {positions, seconds?}')
    if a.segment_start ~= nil and not of then
      local g, have = nil, {}
      for _, x in ipairs(job.segments or {}) do have[#have+1] = tostring(x.start); if x.start == a.segment_start then g = x end end
      assert(g, string.format('segment_start: no segment of that watch starts at tick %d (%s)', a.segment_start, #have > 0 and 'kept: ' .. table.concat(have, ', ') or 'it keeps none'))
      job, of = g, job
    end
    local done = job.result ~= nil
    if done and owner == p.index and not of then job.read_tick = job.read_tick or game.tick end
    local to = done and (job.ended_tick or job.until_tick) or game.tick
    local secs = (to - job.start) / 60
    -- the machines asked for, in the watch's order
    local picked, not_found = {}, {}
    if a.positions then
      local want = {}
      for _, q in ipairs(a.positions) do
        local x, y = q.x or q[1], q.y or q[2]
        local best, bd
        for i, m in ipairs(job.machines) do
          local dx, dy = math.abs(m.position.x - x), math.abs(m.position.y - y)
          if dx <= M.MATCH and dy <= M.MATCH and (not bd or dx + dy < bd) then best, bd = i, dx + dy end
        end
        if best then want[best] = true else not_found[#not_found+1] = {x=x, y=y} end
      end
      for i in ipairs(job.machines) do if want[i] then picked[#picked+1] = i end end
    else for i in ipairs(job.machines) do picked[i] = i end end
    local size = a.page_size or M.ROWS
    local pages = math.max(1, math.ceil(#picked / size))
    local page = a.page or 1
    local rows, lines = {}, {}
    for k = (page - 1) * size + 1, math.min(#picked, page * size) do
      local i = picked[k]
      local m = job.machines[i]
      local row = m.lab and M.lab_row(job, m, secs) or M.machine_row(job, m, secs)
      row.index = i
      if not m.lab then
        local sc
        for n, x in pairs(m.short) do
          sc = sc or {}
          sc[n] = {samples=x.samples, least=x.least, need=x.need, first_tick=x.first, last_tick=x.last}
        end
        row.short_counts = sc
      end
      lines[#lines+1] = row.line
      if not a.details then row.line = nil end
      rows[#rows+1] = row
    end
    local who = owner ~= p.index and api.who_index and api.who_index(owner) or nil
    local id = id_of(job, owner)
    local out = {read=true, id=id, agent=who, done=done or nil, watching=not done or nil, started_tick=job.start, until_tick=job.until_tick, to_tick=to,
      sampled_tick=job.sampled, samples=job.samples, every_ticks=M.EVERY, seconds=math.floor(secs + 0.5), of_seconds=job.seconds,
      machines_total=#job.machines, matched=#picked, page=page, pages=pages, page_size=size, machines=rows, lines=a.details and lines or nil,
      not_found=#not_found > 0 and not_found or nil}
    -- (QAD1) a segment: the window an edit closed, done there; a watch: the segments it keeps
    if of then out.segment = {segment_start=job.start, ended_tick=job.ended_tick, closed_by=job.closed_by, of=id_of(of, owner)}; out.done, out.watching = true, nil
    else out.segments, out.segments_dropped = M.segment_rows(job, owner), job.segments_dropped; out.segments_note = out.segments and M.SEG_NOTE or nil end
    -- (QR) a kept watch: done, kept since the next began; the watch now: the ones it keeps
    if by then out.kept_watch = {kept_tick=job.kept_tick, ended_tick=job.ended_tick, closed_by=job.closed_by, by=id_of(by, owner)}
    elseif not of then out.kept, out.kept_dropped = M.kept_rows(job, owner); out.kept_note = (out.kept or out.kept_dropped) and M.KEPT_NOTE or nil end
    local state = of and string.format('closed at tick %d by %s, kept on %s', job.ended_tick, tostring(job.closed_by), out.segment.of)
      or by and string.format('done at tick %d%s; kept since %s began', job.ended_tick, job.closed_by and ', ' .. job.closed_by or '', out.kept_watch.by)
      or done and 'done' or 'watching'
    out.line = string.format('uptime %s %s%s (%s, %d samples to tick %s): page %d of %d, machines %d-%d of %d%s%s',
      of and 'segment' or 'watch', id, who and ' of ' .. who or '', state, job.samples, tostring(job.sampled), page, pages, #rows > 0 and (page - 1) * size + 1 or 0, (page - 1) * size + #rows, #picked,
      a.positions and string.format(' picked by positions from its %d', #job.machines) or '',
      #not_found > 0 and string.format('; %d position%s no machine of it (within %d tiles)', #not_found, #not_found == 1 and ' matches' or 's match', M.MATCH) or '')
    if page > pages then out.line = out.line .. string.format('; page %d is past the last (%d)', page, pages) end
    return out
  end
  function M.handler(p, a)
    if a.read ~= nil then return M.read(p, a) end
    M.check_read(a)
    if a.positions == nil and a.position == nil and a.area == nil and a.items == nil then
      -- (d20 batch62 X2, Sol #1529) the watch so far is read where it was started: surface and platform go with a new watch
      assert(a.surface == nil and a.platform == nil, 'surface and platform go with positions, position, area or items (a new watch there); uptime {} reads your watch where it began')
      local job = store()[p.index]
      assert(job, 'no uptime watch yet: uptime {positions, seconds?}')
      if job.result then job.read_tick = game.tick end  -- its final read (measures.lua)
      local r = job.result or M.result(job, false)
      local segs = M.segment_rows(job, p.index)
      local kept, gone = M.kept_rows(job, p.index)
      if not segs and not kept and not gone then return r end
      local out = {}
      for k, v in pairs(r) do out[k] = v end
      if segs then out.segments, out.segments_dropped, out.segments_note = segs, job.segments_dropped, M.SEG_NOTE end
      if kept or gone then out.kept, out.kept_dropped, out.kept_note = kept, gone, M.KEPT_NOTE end
      return out
    end
    local seconds = a.seconds == nil and 600 or a.seconds
    assert(type(seconds) == 'number' and seconds >= M.SECONDS[1] and seconds <= M.SECONDS[2] and seconds == math.floor(seconds), string.format('seconds: %d..%d (default 600)', M.SECONDS[1], M.SECONDS[2]))
    local reason = api.reason and api.reason(a.reason)  -- (d20 batch70 AF1) its own reason to wait (measures.lua)
    local q = a.surface ~= nil and api.on_surface(p, a.surface) or a.platform ~= nil and api.on_platform(p, a.platform) or p
    local list = a.positions or a.position and {a.position} or (a.area and timed('uptime.area', M.in_area, q, a)) or {}
    assert(type(list) == 'table' and (#list >= 1 or a.items) and #list <= M.MAX, 'positions: 1..' .. M.MAX .. ' crafting machines or labs {x,y} (or area {left_top, right_bottom} with recipe; or items alone)')
    local machines, labs = {}, nil
    -- machines alike (a bank: the same name, quality, recipe, speed and productivity) share one craftrate read
    local rate_of = {}
    timed('uptime.machines', function()
    for _, pos in ipairs(list) do
      local e = api.remote_entity(q, {position=pos.position or pos, unit_number=pos.unit_number})
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
      local key = r and table.concat({e.name, quality_name(try(function() return e.quality end)), r.name, rq or 'normal', tostring(try(function() return e.crafting_speed end)),
        tostring(try(function() return e.productivity_bonus end))}, '|')
      local rates = key and rate_of[key]
      if rates == nil then rates = api.craftrate and try(function() return api.craftrate(e) end) or false; if key then rate_of[key] = rates end end
      rates = rates or nil
      local m = {e=e, name=e.name, position={x=e.position.x, y=e.position.y}, recipe=r and r.name or 'none', recipe_quality=rq, finished0=finished(e, true), parts=e.type == 'rocket-silo' or nil,
        bar0=bar(e), progress0=progress(e), status={}, short={}, full_cpm=rates and rates.crafts_per_min or nil}
      M.keep_prod(m, rates)
      machines[#machines+1] = m
      end
      ::next_position::
    end
    end)
    local replaced = store()[p.index] and not store()[p.index].result
    local job = {start=game.tick, until_tick=game.tick + seconds * 60, next_tick=game.tick, seconds=seconds, samples=0, machines=machines, reason=reason}
    local flows_line
    if a.items then job.flows, flows_line = timed('uptime.flows', M.flows_start, q.force, q.surface, a.items) end
    if labs then
      job.research = {force=labs.force.name, last=research_now(labs.force), units=0, finished={}, changes={}}
      local stats = try(function() return labs.force.get_item_production_statistics(game.surfaces[labs.surface]) end)
      -- (PX1) every quality (q: counted so; a watch begun before has no packs used figure)
      job.pack_stats = {surface=labs.surface, names=labs.names, counts={}, q=true}
      for _, n in ipairs(labs.names) do job.pack_stats.counts[n] = stats and try(function() return qflow.count(stats, n, 'output') end) or 0 end
    end
    -- (QN1) silos: the surface's production statistics of their product, to set beside the parts they made
    for _, m in ipairs(machines) do
      if m.parts and m.recipe ~= 'none' and not job.silo_stats then
        local stats = flow_stats(q.force, q.surface)
        local n = stats and try(function() return qflow.count(stats, m.recipe, 'input') end)
        if n then job.silo_stats = {force=q.force.name, surface=q.surface.name, item=m.recipe, n0=n} end
      end
    end
    local old = store()[p.index]
    local dropped = M.keep(old, job, p.index, game.tick)
    store()[p.index] = job
    timed('uptime.sample', M.sample, job)
    job.next_tick = next_at(job)
    local lines = {}
    for _, m in ipairs(machines) do
      if m.lab then
        local held = {}
        for _, name in ipairs(m.order) do held[#held+1] = string.format('%s %d', name, m.packs[name].n) end
        lines[#lines+1] = string.format('%s %s: holds %s', m.name, at(m.position), #held > 0 and table.concat(held, ', ') or 'no science packs')
      elseif m.parts then lines[#lines+1] = string.format('%s %s %s: %d rocket parts so far (finished rockets x the parts a rocket takes, plus those of the one building; productivity\'s included)', m.name, at(m.position), qlabel(m.recipe, m.recipe_quality), m.finished0)
      else lines[#lines+1] = string.format('%s %s %s: %d completions so far (the game\'s count, productivity\'s included)', m.name, at(m.position), qlabel(m.recipe, m.recipe_quality), m.finished0) end
    end
    -- (QR) what is kept and what this start dropped
    local kept = M.kept_rows(job, p.index)
    local was = kept and old and kept[#kept].id == id_of(old, p.index) and kept[#kept].id or nil
    local line = #machines == 0 and string.format('watching the production statistics of %d item%s for %ds: uptime {} reads them so far, and in full once done', #a.items, #a.items == 1 and '' or 's', seconds)
      or string.format('watching %d machine%s for %ds, a status sample a second at a phase 7 ticks later each second: uptime {} reads it so far, and in full once done', #machines, #machines == 1 and '' or 's', seconds)
    if kept then line = line .. '; kept, read by uptime {read: true, id}: ' .. kept_text(kept) end
    local gone = {}
    for _, d in ipairs(dropped or {}) do gone[#gone+1] = {id=d.id, machines=d.machines, why=d.why} end
    if #gone > 0 then line = line .. '; dropped: ' .. kept_text(gone) .. ' (' .. gone[1].why .. ')' end
    return {watching=true, id=id_of(job, p.index), seconds=seconds, machines=#machines, baseline=lines, items_recent=flows_line,
      replaced=replaced and was and string.format('your earlier watch, still running, was finished at this tick and kept as %s', was) or replaced and 'your earlier watch, still running, was replaced' or nil,
      kept=kept, dropped=#gone > 0 and gone or nil, kept_note=kept and M.KEPT_NOTE or nil, line=line}
  end
  M.schema = {uptime = {reason='optional text, up to 200 characters: your own reason to wait for it, shown with the watch in your sleep line, sleep_check and the operator\'s idle check', positions='1..64 crafting machines or labs {x,y} (an assembler, furnace, chemical plant, biochamber, lab, biolab, ...; in sight or by remote view); with read: true, the machines of the watch to read (each the nearest centre within 2 tiles)', position='or one',
    area='or {left_top={x,y}, right_bottom={x,y}} (up to 200 tiles a side): the crafting machines of ours in it, up to 64', recipe='optional with area: only those on this recipe', quality='optional with recipe: its quality',
    items='optional 1..8 items, a name (read at every quality) or {name, quality}: their production statistics on the surface by quality over the watch (alone, with no machines, a statistics-only watch)',
    seconds='optional 10..3600 (default 600): how long to watch',
    read='true: read a watch in pages without starting or replacing it (yours; with id or agent any agent\'s): read, id, agent (another\'s), done or watching, started_tick, until_tick, to_tick (the end, or now), sampled_tick (its last sample), samples, seconds, machines_total, matched, page, pages, page_size, machines (the page\'s rows as uptime {} gives them, with index (its place in the watch) and short_counts {ingredient: {samples, least, need, first_tick, last_tick}}; line only with details), lines (with details), not_found, segment (reading a segment: segment_start, ended_tick, closed_by, of: the watch keeping it) or segments, kept_watch (reading a kept watch: kept_tick, ended_tick, closed_by, by: the watch begun then) or kept and kept_dropped, line; a queue step and dry_run check it',
    id='with read: a watch\'s id as the start and status work give it, "uptime@START_TICK/AGENT"; "uptime@START_TICK" reads the one watch begun on that tick (two or more: refused, each id named)',
    agent='with read: an agent\'s name: that agent\'s watch (with id, the id must be its)',
    segment_start='with read: the start tick of a segment the watch keeps (segments lists them; its id reads it too): that closed window, done at the edit, in pages', page='with read: 1.. (default 1)', page_size='with read: 1..16 machines a page (default 16)',
    details='with read: true adds each row\'s line and lines', surface='optional planet name (by remote view)', platform='optional platform name',
    returns='a watch, one an agent (a new one keeps the last one done, readable by its id): the start returns id, baseline (each machine\'s completions so far), kept, dropped (what that start dropped) and line; uptime {} reads it so far (watching) or done: per machine crafts (base crafts finished in the window), crafts_per_min against full_speed_per_min (its recipe at its speed), completions (the game\'s count: crafts and productivity completions), bonus_completions, completions_per_min against full_speed_completions_per_min (with its productivity), productivity (the game\'s sum: the machine\'s with modules and beacons, and the recipe\'s research, capped at the recipe\'s maximum), productivity_research, crafts_unknown (base crafts and bonus_completions left out when productivity changed during the watch or could not be read, or the recipe changed), working_share (% of samples working), samples by status (the GUI\'s status line, once a second), recipe_quality (the quality its recipe runs at), short (each ingredient under one craft in its input at the samples that read short of ingredients, items counted at the recipe\'s quality and named with it: how many samples, the least held), recipe_changed, gone; status_runs (each status other than working the machine read: {samples, first_tick, last_tick, first_s, last_s (seconds into the watch), longest_run (samples in a row)}; its line\'s when: part) and changes (its last 8 status changes, \'tick: from -> to\'), only for a machine that read such a status; short gives the ticks of its first and last short sample; a share that rounds to 0% gives its count (d20 batch79 AO1); a lab\'s row (kind lab, with status_runs and changes too): samples by status (working, missing science packs, no power, ...), working_share, packs [{name, used (packs: their durability drained between samples; 2.0.77 keeps no count per lab), held_least, held_most, empty_samples, unknown_intervals, of_intervals, unknown_why (a lab that could use a whole pack between samples, a spoilable pack spoiled, packs above normal quality)}], spoil_results (what spoiled packs left in its trash); with a lab, research {technology, units (the force\'s progress gained, every lab), finished, changed, line} and packs_used_up {by_pack, line} (the surface\'s production statistics: whole packs, every lab there); machine_rows (above 16 machines the rows above are left out and lines has each machine; group rows up to 8 groups, flow rows up to 10), groups (with 2 or more machines: per recipe and quality, machines, completions and completions_per_min against full_speed_completions_per_min, crafts and crafts_per_min against full_speed_per_min when every machine\'s are known, status_shares of all their samples, line) and group_lines; returned on a machine row and a group (a recipe that gives or takes an item with ignored_by_stats, pentapod-egg\'s own): per such item out, in, returned (the amount on both sides), net, statistics_made and statistics_used (the returned amount on neither side: made is the net), and its line; outputs_by_quality per machine ({product: {quality: count}} its output slot gained over the intervals whose gain matched its completions; outputs_unknown_intervals of outputs_intervals with completions: products taken out or spoiled between samples, or none when a product comes by chance or in a range); items_recent at the start (the statistics\' last 10 minutes) and flows {surface, rows [{name, quality, produced, consumed, net, produced_per_min, consumed_per_min}], line} (the production statistics over the watch: every machine and hand on the surface); a rocket silo\'s completions are rocket parts (completions_are: finished rockets x the parts a rocket takes plus rocket_parts, productivity\'s included), with silo_statistics {item, surface, silos, silos_made, statistics_produced, line} (the parts the watched silos made beside the surface\'s production statistics of them); lines; left_out (what the watch does not see); segments [{id, segment_start, ended_tick, seconds, samples, machines, closed_by}] (the windows an edit to what it measures closed before this one began, each kept whole: uptime {read: true, id} reads one), segments_dropped, segments_note; kept [{id, started_tick, ended_tick, seconds, samples, machines, segments, closed_by, kept_tick}] (your earlier watches, each done: uptime {read: true, id} reads one), kept_dropped [{id, machines, dropped_tick, by, why}], kept_note. Read only'}}
  return M
end
