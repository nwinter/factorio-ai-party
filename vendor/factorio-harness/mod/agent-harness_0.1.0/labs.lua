-- labs: the research line at a glance. One header line (research, progress,
-- ETA) and one line per group of adjacent labs: working count, packs the
-- labs lack, and why their feeders (inserters and the belts or chests they
-- take from) are not delivering. Bounded: 256 labs, 8 groups, read on demand.
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  local MAX_LABS, MAX_GROUPS, NEAR = 256, 8, 5.5
  M.schema = {labs = {surface='optional surface name: visible labs there, up to 256; position limits the read to an area',
    position='optional charted centre (default character without surface; with surface, all visible labs there)', radius='1..256 (default 96); on another surface requires position',
    returns='research line (name, progress, eta at the working labs: every lab of ours, research_labs per surface) and per lab group of the area: labs working, packs missing (labs lacking each), feeders idle/starved and why, what their belts/chests hold; lacking (up to 8 labs, one row each): the pack, each inserter dropping into the lab and its source (a chest: what it holds and asks of it; a lab: what it holds; a belt: what it carries), the logistic network of its requester or buffer chest (else at the lab) and what it holds of it, and the chest its robots would take it from; full_speed {labs, units_per_min, progress_per_min (with productivity), packs_per_min {pack: n}, line} and lab_rates (a line a lab, the first 64; lab_rates_more): the engine\'s figures at full supply for the current research: speed = researching speed at its quality x (1 + modules and beacons) x (1 + the force\'s lab speed), a unit in research_unit_energy / 60 / speed s, each pack amount x units a minute x drain (biolab 50%); productivity adds progress, not pack use; what they used is science {pack} (the 10-minute statistics)'}}
  local function short(name) return (name:gsub('%-science%-pack$', '')) end
  local function fmt(s)
    if s >= 3600 then return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s / 60) % 60) end
    return s >= 60 and string.format('%dm%02ds', math.floor(s / 60), s % 60) or s .. 's'
  end
  -- Item counts on a belt or in a chest, as name -> count.
  local function holds(e)
    local out = {}
    if e.type == 'transport-belt' or e.type == 'underground-belt' or e.type == 'splitter' then
      for i = 1, e.get_max_transport_line_index() do
        for k, v in pairs(e.get_transport_line(i).get_contents()) do
          local name, n = type(v) == 'table' and v.name or k, type(v) == 'table' and v.count or v
          out[name] = (out[name] or 0) + n
        end
      end
    else
      local ok, inv = pcall(e.get_output_inventory)
      if ok and inv then for _, s in pairs(inv.get_contents()) do out[s.name] = (out[s.name] or 0) + s.count end end
    end
    return out
  end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Why one lab lacks a pack (Luna 03:20: 4 of 43 labs had no military science while 8,754 packs sat in storage): each
  -- inserter dropping into it and its source (a chest: what it holds and asks of the pack; a lab: what that lab holds;
  -- a belt: what it carries), the logistic network there and what it holds of the pack, and the chest its robots would
  -- take it from (the network's pickup point for it).
  -- (d27 batch276 LN, Astra #2579) "there" is the feeding requester's (or buffer's) own network, as inspect reads it:
  -- the lab's centre was looked up, and the biolab (91.5,117.5) stands 29.7 tiles from roboport (62,121), outside its
  -- logistic range (25) and inside its construction range, while its requester (91.5,113.5) is in network #243 (2.0.77,
  -- a copy of world n: find_logistic_network_by_position at the lab gives none). Without such a chest: the lab's.
  local function lab_why(lab, name, surface, force, seen)
    local b = lab.bounding_box
    local feeds, chest = {}, nil
    for _, ins in pairs(try(function() return surface.find_entities_filtered{area={left_top={x=b.left_top.x-3, y=b.left_top.y-3}, right_bottom={x=b.right_bottom.x+3, y=b.right_bottom.y+3}}, type='inserter', force=force, limit=32} end) or {}) do
      if try(function() return ins.drop_target end) == lab then
        local src = try(function() return ins.pickup_target end)
        local text
        if not src then text = 'nothing to pick up from'
        elseif not seen(src) then text = src.name .. ' outside visible chunks'
        else
          local n = holds(src)[name] or 0
          text = string.format('%s %s holding %d', src.name, at(src.position), n)
          if src.type == 'logistic-container' then
            local asked
            for _, sec in pairs(try(function() return src.get_logistic_sections().sections end) or {}) do
              for _, f in pairs(try(function() return sec.filters end) or {}) do
                local v = f.value
                if v and (v.name == name) then asked = (asked or 0) + (f.min or 0) end
              end
            end
            local mode = try(function() return src.prototype.logistic_mode end)
            if mode == 'requester' or mode == 'buffer' then
              text = text .. (asked and string.format(', asking %d', asked) or ', no request for it')
              chest = chest or src
            end
          end
        end
        feeds[#feeds+1] = ins.name .. ' ' .. at(ins.position) .. ' from ' .. text
      end
    end
    local ln, where
    if chest then
      ln, where = try(function() return chest.logistic_network end), chest.position
    else
      ln, where = try(function() return surface.find_logistic_network_by_position(lab.position, force) end), lab.position
    end
    local net = ''
    if ln then
      local n = try(function() return ln.get_item_count(name) end) or 0
      local pick = n > 0 and try(function() return ln.select_pickup_point{name=name, position=where} end)
      local owner = pick and try(function() return pick.owner end)
      net = string.format('; %s logistic network #%s holds %d%s', chest and string.format("%s %s's", chest.name, at(chest.position)) or "the lab's",
        tostring(try(function() return ln.network_id end) or '?'), n,
        owner and string.format(', robots would take it from %s %s', owner.name, at(owner.position)) or '')
    elseif chest then net = string.format('; %s %s is in no logistic network', chest.name, at(chest.position))
    else net = '; no logistic network covers the lab' end
    return string.format('lab %s lacks %s: %s%s', at(lab.position), name, #feeds > 0 and 'fed by ' .. table.concat(feeds, ' | ') or 'no inserter drops into it', net)
  end
  M.lab_why = lab_why  -- (tests/d27_batch276.lua)
  -- (d27 batch291 LS, Sol #2638: a full-speed demand of 30 labs rebuilt from beacons by hand read 173.1, 158.34, 172.15)
  -- A lab's research rate as the engine runs it, at full supply. Measured on the iMac copy (2.0.77, world n's 30
  -- biolabs, one lab cut off from its inserters and filled, its packs' durability over about 11000 ticks): the speed is
  -- researching speed at its quality x (1 + its modules and beacons, effects.speed) x (1 + the force's
  -- laboratory_speed_modifier), the two bonuses multiplied: 2 x 1.67 x 3.5 used 5.845 of each pack a minute (11.69
  -- units, drain 50%), 2 x 1.3 x 3.5 used 4.550. The entity's speed_bonus is their sum (3.17), not what the engine
  -- multiplies by. A unit takes research_unit_energy ticks at speed 1; each pack's use is its amount a unit times
  -- science_pack_drain_rate_percent (biolab 50, lab 100). Productivity (productivity_bonus: modules and the force's
  -- laboratory_productivity_bonus) adds research progress, not pack use. Researching speed by quality: biolab 2, 2.6,
  -- 3.2, 3.8, 5; lab 1, 1.3, 1.6, 1.9, 2.5.
  local base_speed = {}
  function M.rate(e, force, tech)
    local q = try(function() return e.quality.name end) or 'normal'
    local key = e.name .. '@' .. q
    if base_speed[key] == nil then
      base_speed[key] = try(function() return e.prototype.get_researching_speed(q) end) or try(function() return e.prototype.researching_speed end) or 1
    end
    local base = base_speed[key]
    local bonus = try(function() return e.speed_bonus end) or 0
    local own = try(function() return e.effects and e.effects.speed end) or 0
    local lab_mod = try(function() return force.laboratory_speed_modifier end) or 0
    local drain = try(function() return e.prototype.science_pack_drain_rate_percent end) or 100
    local prod = try(function() return e.productivity_bonus end) or 0
    local speed = base * (1 + own) * (1 + lab_mod)
    local r = {speed=speed, base=base, speed_bonus=bonus, modules_beacons=own, force_lab_speed=lab_mod, drain=drain, productivity=prod}
    if tech and speed > 0 then
      local unit_s = (tech.research_unit_energy or 0) / 60 / speed
      r.unit_s = unit_s
      r.units_per_min = unit_s > 0 and 60 / unit_s or 0
      r.packs = {}
      for _, ing in ipairs(tech.research_unit_ingredients or {}) do r.packs[ing.name] = (ing.amount or 1) * r.units_per_min * drain / 100 end
    end
    return r
  end
  local function g3(x) return string.format('%.3g', x) end
  function M.rate_text(e, r)
    local parts = {string.format('%s %s: speed %s (researching speed %g x (1 + modules and beacons %s) x (1 + the force\'s lab speed %s))',
      e.name, at(e.position), g3(r.speed), r.base, g3(r.modules_beacons), g3(r.force_lab_speed))}
    if r.unit_s then
      local each
      for _, n in pairs(r.packs) do each = each and math.max(each, n) or n end
      parts[#parts+1] = string.format('a unit in %ss, %s units a minute; drain %d%%: %s of each pack a minute', g3(r.unit_s), g3(r.units_per_min), r.drain, g3(each or 0))
    end
    if r.productivity > 0 then parts[#parts+1] = string.format('productivity +%d%%', math.floor(r.productivity * 100 + 0.5)) end
    return table.concat(parts, '; ')
  end
  -- (d26 batch248 R1) every lab of ours, every surface, for the research line: {working, total, rows}
  local function all_labs(force)
    local out = {working=0, total=0, rows={}}
    for _, s in pairs(game.surfaces) do
      local list = api.census_typed and try(function() return api.census_typed(force, s, 'lab') end)
      if not list then list = try(function() return s.find_entities_filtered{type='lab', force=force, limit=MAX_LABS} end) or {} end
      if #list > 0 then
        local w = 0
        for _, e in ipairs(list) do
          if e.valid and api.status_name(e) == 'working' then w = w + 1 end
        end
        out.rows[#out.rows+1] = {surface=s.name, n=#list, working=w}
        out.working, out.total = out.working + w, out.total + #list
      end
    end
    table.sort(out.rows, function(x, y) return x.n > y.n end)
    return out
  end
  function M.view(p, a)
    local force, surface = p.force, p.surface
    if a.surface~=nil then
      assert(type(a.surface)=='string','surface must be a surface name')
      surface=game.get_surface(a.surface)
      assert(surface,'no surface '..a.surface)
    end
    local centre
    if a.position~=nil or a.surface==nil or a.radius~=nil then
      assert(surface==p.surface or a.position~=nil,'radius on another surface requires position')
      local view=setmetatable({surface=surface},{__index=p})
      centre=api.center(view,a)
    end
    local radius = api.integer(a.radius, 96, 1, 256, 'radius')
    local tech = force.current_research
    local packs = {}
    for _, ing in ipairs(tech and tech.research_unit_ingredients or {}) do packs[#packs+1] = ing.name end
    local found = surface.find_entities_filtered{position=centre, radius=centre and radius or nil, type='lab', force=force, limit=MAX_LABS}
    local labs, visible = {}, {}
    local platform=surface.platform
    local own_platform=platform and platform.force==force
    local function seen(e)
      if a.surface==nil or own_platform then return true end
      local cx,cy=math.floor(e.position.x/32),math.floor(e.position.y/32)
      visible[cx]=visible[cx] or {}
      if visible[cx][cy]==nil then visible[cx][cy]=force.is_chunk_visible(surface,{x=cx,y=cy}) end
      return visible[cx][cy]
    end
    for _,e in ipairs(found) do if seen(e) then labs[#labs+1]=e end end
    -- Groups: labs within NEAR tiles of one another (chains of adjacent labs).
    local group_of, groups, cells, positions = {}, {}, {}, {}
    for i,e in ipairs(labs) do
      local pos=e.position; positions[i]=pos
      local cx,cy=math.floor(pos.x/NEAR),math.floor(pos.y/NEAR)
      cells[cx]=cells[cx] or {}; cells[cx][cy]=cells[cx][cy] or {}
      local cell=cells[cx][cy]; cell[#cell+1]=i
    end
    for i, e in ipairs(labs) do
      if not group_of[i] then
        local g = {i}; group_of[i] = g; groups[#groups+1] = g
        local k = 1
        while k <= #g do
          local x = positions[g[k]]
          local cx,cy=math.floor(x.x/NEAR),math.floor(x.y/NEAR)
          for dy=-1,1 do for dx=-1,1 do
            for _,j in ipairs(cells[cx+dx] and cells[cx+dx][cy+dy] or {}) do
              local pos=positions[j]
              if not group_of[j] and math.abs(pos.x-x.x)<=NEAR and math.abs(pos.y-x.y)<=NEAR then group_of[j]=g; g[#g+1]=j end
            end
          end end
          k = k + 1
        end
      end
    end
    table.sort(groups, function(x, y) return #x > #y end)
    -- (LS) each lab's rate at full supply, the engine's figures; the aggregate below
    local rates, total = {}, {labs=0, units=0, progress=0, packs={}}
    for i, e in ipairs(labs) do
      local r = try(function() return M.rate(e, force, tech) end)
      rates[i] = r
      if r and r.units_per_min then
        total.labs = total.labs + 1; total.units = total.units + r.units_per_min; total.progress = total.progress + r.units_per_min * (1 + r.productivity)
        for name, n in pairs(r.packs) do total.packs[name] = (total.packs[name] or 0) + n end
      end
    end
    local working, lines = 0, {}
    local why_rows = {}
    for gi, g in ipairs(groups) do
      local box = {left_top={x=math.huge, y=math.huge}, right_bottom={x=-math.huge, y=-math.huge}}
      local statuses, lacking, member = {}, {}, {}
      for _, i in ipairs(g) do
        local e = labs[i]; member[e.unit_number or i] = true
        local status = api.status_name(e) or 'unknown'
        statuses[status] = (statuses[status] or 0) + 1
        if status == 'working' then working = working + 1 end
        local inv = e.get_inventory(defines.inventory.lab_input)
        for _, name in ipairs(packs) do
          if inv and inv.get_item_count(name) == 0 then
            lacking[name] = (lacking[name] or 0) + 1
            if #why_rows < 8 then why_rows[#why_rows+1] = {lab=e, name=name} end
          end
        end
        box.left_top.x = math.min(box.left_top.x, e.position.x - 3); box.left_top.y = math.min(box.left_top.y, e.position.y - 3)
        box.right_bottom.x = math.max(box.right_bottom.x, e.position.x + 3); box.right_bottom.y = math.max(box.right_bottom.y, e.position.y + 3)
      end
      if gi <= MAX_GROUPS then
        local parts = {string.format('labs %s-%s: %d/%d working', at({x=box.left_top.x+3, y=box.left_top.y+3}), at({x=box.right_bottom.x-3, y=box.right_bottom.y-3}), statuses.working or 0, #g)}
        for status, n in pairs(statuses) do if status ~= 'working' then parts[#parts+1] = n .. ' ' .. status end end
        local miss = {}
        for _, name in ipairs(packs) do if lacking[name] then miss[#miss+1] = short(name) .. ' (' .. lacking[name] .. ')' end end
        if #miss > 0 then parts[#parts+1] = 'lack ' .. table.concat(miss, ', ') end
        local gu, full = 0, nil
        for _, i in ipairs(g) do local r = rates[i]; if r and r.units_per_min then gu = gu + r.units_per_min end end
        if gu > 0 then
          local each = 0
          for _, i in ipairs(g) do local r = rates[i]; local m = 0; for _, n in pairs(r and r.packs or {}) do m = math.max(m, n) end; each = each + m end
          full = string.format('at full supply %s units a minute, %s of each pack a minute (the engine\'s figures)', g3(gu), g3(each))
        end
        -- Feeders: inserters dropping into these labs; their sources say why.
        local feeders, idle, sources, chained = 0, {}, {}, 0
        for _, ins in pairs(surface.find_entities_filtered{area=box, type='inserter', force=force, limit=128}) do
          local ok, target = pcall(function() return ins.drop_target end)
          if ok and target and target.type == 'lab' and member[target.unit_number] and seen(ins) then
            feeders = feeders + 1
            local src = ins.pickup_target
            local hidden=src and not seen(src)
            if hidden then src=nil end
            if src and src.type == 'lab' then chained = chained + 1
            elseif src and not sources[src.unit_number or at(src.position)] then
              sources[src.unit_number or at(src.position)] = src; sources[#sources+1] = src
            end
            local status = api.status_name(ins) or 'unknown'
            -- one holding part of its hand and waiting for more: a stack-inserter waits for a full hand (fixed in 2.0.77;
            -- d22 batch104 BN2, luna #1931)
            if status == 'waiting_for_more_items' then
              local full = api.wait_for_full_hand and api.wait_for_full_hand(ins)
              local why = full and 'hold part of a hand and wait for a full one (stack-inserter: its prototype\'s wait_for_full_hand, fixed in 2.0.77; hand_size sets the hand)'
                or 'hold part of a hand and wait for more items'
              idle[why] = (idle[why] or 0) + 1
            elseif status ~= 'working' and status ~= 'waiting_for_target_to_be_built' and not (ins.held_stack and ins.held_stack.valid_for_read) then
              local why = status == 'waiting_for_source_items' and (hidden and 'pickup target outside visible chunks'
                or src and 'source ' .. src.name .. ' ' .. at(src.position) .. ' has nothing the lab needs' or 'nothing to pick up from') or status
              idle[why] = (idle[why] or 0) + 1
            end
          end
        end
        local feed = {feeders .. ' inserters' .. (chained > 0 and ' (' .. chained .. ' lab-to-lab)' or '')}
        for why, n in pairs(idle) do feed[#feed+1] = n .. ' idle: ' .. why end
        -- What reaches the group: needed packs across its belts and chests.
        local seen = {}
        for i = 1, math.min(#sources, 16) do for name, n in pairs(holds(sources[i])) do seen[name] = (seen[name] or 0) + n end end
        local carried, absent = {}, {}
        for _, name in ipairs(packs) do
          if (seen[name] or 0) > 0 then carried[#carried+1] = short(name) .. ' ' .. seen[name] else absent[#absent+1] = short(name) end
        end
        if feeders == 0 then feed[1] = 'no visible inserters feed these labs'
        elseif #absent > 0 and #sources > 0 then feed[#feed+1] = 'no ' .. table.concat(absent, ', ') .. ' on their ' .. #sources .. ' belts/chests' end
        if #carried > 0 then feed[#feed+1] = 'sources hold ' .. table.concat(carried, ', ') end
        lines[#lines+1] = table.concat(parts, ', ') .. '; feeders: ' .. table.concat(feed, '; ') .. (full and '; ' .. full or '')
      end
    end
    local research, research_labs
    if not tech then research = 'none: nothing queued'
    else
      local progress = force.research_progress or 0
      local names = {}
      for i, n in ipairs(packs) do names[i] = short(n) end
      research = string.format('%s %d%% needs %s', tech.name, math.floor(progress * 100), table.concat(names, '+'))
      local every = all_labs(force)
      -- the ETA at research's measured rate (research {}'s done_in)
      local rate, ticks = (api.research_rate or function() end)(force.name)
      if every.working == 0 then research = research .. ', stalled: no lab is working'
      elseif rate and rate > 0 then
        research = research .. string.format(', eta %s at %d working labs (rate over the last %s)',
          fmt(math.ceil((1 - progress) * tech.research_unit_count * tech.research_unit_energy / rate / 60)), every.working, fmt(math.ceil(ticks / 60)))
      else research = research .. string.format(', %d working labs, %s', every.working, rate and 'no progress measured' or 'no rate measured yet') end
      local per = {}
      for _, r in ipairs(every.rows) do per[#per+1] = string.format('%s %d of %d', r.surface, r.working, r.n) end
      research_labs = string.format('%d of %d labs of ours working, every surface (%s); groups: %s', every.working, every.total,
        table.concat(per, ', '), centre and string.format('within %d tiles of %s on %s', radius, at(centre), surface.name) or surface.name)
    end
    local why = {}
    for _, r in ipairs(why_rows) do why[#why+1] = try(function() return lab_why(r.lab, r.name, surface, force, seen) end) end
    -- (LS) per lab (the first 64) and for all the visible labs read: the engine's figures at full supply, apart from
    -- what they used (science: the game's 10-minute statistics)
    local lab_rates, full_speed = {}, nil
    for i, e in ipairs(labs) do if i <= 64 and rates[i] then lab_rates[#lab_rates+1] = M.rate_text(e, rates[i]) end end
    if total.labs > 0 then
      local names, packs = {}, {}
      for name in pairs(total.packs) do names[#names+1] = name end
      table.sort(names)
      for _, name in ipairs(names) do packs[name] = math.floor(total.packs[name] * 100 + 0.5) / 100 end
      local each = {}
      for _, name in ipairs(names) do each[#each+1] = string.format('%s %s', short(name), g3(total.packs[name])) end
      full_speed = {labs=total.labs, units_per_min=math.floor(total.units * 100 + 0.5) / 100, progress_per_min=math.floor(total.progress * 100 + 0.5) / 100, packs_per_min=packs,
        line=string.format('the engine\'s figures at full supply: %d labs research %s units a minute (%s with productivity) of %s, using a minute %s; what they used: science {pack} (the 10-minute statistics)',
          total.labs, g3(total.units), g3(total.progress), tech.name, table.concat(each, ', '))}
    end
    return {surface=surface.name,position=centre,radius=centre and radius or nil,research=research,research_labs=research_labs,lacking=#why > 0 and why or nil,
      full_speed=full_speed, lab_rates=#lab_rates > 0 and lab_rates or nil, lab_rates_more=#labs > 64 and (#labs - 64) or nil,
      labs=#labs .. ' in ' .. #groups .. ' groups' .. (centre and string.format(' within %d tiles of %s', radius, at(centre)) or '')
        .. (#groups > MAX_GROUPS and ' (largest ' .. MAX_GROUPS .. ' shown)' or ''), groups=lines,
      limited=#found>=MAX_LABS and 'lab search reached 256 entities; counts cover the visible labs among those found' or nil}
  end

  -- science: one science pack's flow over the whole surface, counted the same
  -- way whoever asks and wherever they stand (shift07: Luna read "zero
  -- logistics on all belts/chests" while Grok said "the belt scan misses this
  -- chest"). The game's 10-minute statistics, the assemblers set to it, and
  -- every chest, belt, lab and agent holding it; reach (shift08: 31+ labs
  -- lacked chemical packs while stock sat on belts, assembler outputs and
  -- inserter hands): where else it sits and why it does not reach the labs.
  -- One pass for all packs through supply's scan (supply.lua: its bounds).
  M.schema.science = {all_surfaces='true: the compact read for each planet with labs of ours: surface, labs, working, lines', compact='true: one line a pack (made and used in 10 min, makers and their states, labs lacking), no holders or reach; the first line says the scope (this surface only, its labs, and the labs on other planets)', pack='optional item: a science pack (default: each pack the current research needs)', surface='optional surface name (default yours)',
    returns='research and per pack one line and its numbers, for the whole surface, the same for everyone: made and used in the last 10 min (the game\'s statistics), makers (crafters of any type set to it, Space Age ones too, by name: working and the other states; packs waiting in their output), held in chests, in landing pads and platform hubs, on belts and in labs (labs lacking it of those that need it), carried by agents, the largest holders with positions (chests, landing pads, hubs); reach: chests by kind, inserter hands, robots carrying it, the inserters taking from its makers and feeding the labs (by status, what the waiting ones\' sources hold), the logistic requesters for it per network (met, on the way, unmet with reasons), and the worst lab (position, what it lacks, its feeder\'s source, the nearest stock); chain: the pack\'s recipe tree from the step down, '
      .. 'following the ingredient most of a step\'s makers lack while most of them lack one and ending at the first step whose makers mostly do '
      .. 'not, each step with its makers and made and used per minute (10 min statistics) ("chemical-science-pack: 9 of 14 makers lack '
      .. 'advanced-circuit, made 12/min, used 30/min; advanced-circuit: ...; plastic-bar: 4 of 4 working, made 30/min, used 52/min"); '
      .. 'a step mined or pumped names its miners (mining drills, pumpjacks, offshore pumps), their states (working, output full, no resource left) '
      .. 'and what they put into ("stone: 7 electric-mining-drill (5 working, 2 output full) into 6 transport-belt, 1 wooden-chest"), a resource\'s '
      .. 'required fluid the step below it; '
      .. 'chain_tree: every step down to what nothing makes {item, depth, made_per_min, used_per_min, makers, '
      .. 'working, states, lacking {ingredient: makers}, miners, miner_states, outputs} (40 steps at most, chain_cut); counted (what the scan read); effective_research_units (spoilable packs, by quality: observed count, now, packs_per_unit, technology when used by the current research; remaining durability times fresh share, before productivity and lab drain bonuses)'}
  function M.science(p, a)
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    local force = p.force
    local tech = force.current_research
    local needed, packs = {}, {}
    for _, ing in ipairs(tech and tech.research_unit_ingredients or {}) do needed[ing.name] = true; packs[#packs+1] = ing.name end
    if a.pack ~= nil then
      assert(type(a.pack) == 'string' and prototypes.item[a.pack], 'pack must be an item name (automation-science-pack, logistic-science-pack, ...)')
      packs = {a.pack}
    end
    assert(#packs > 0, 'no research is running: name a pack (science {pack=logistic-science-pack})')
    -- The same read within 10 s is the same reply, with as_of (supply.lua reuse; task-statuscost).
    if api.supply.reuse then
      local key = string.format('science|%s|%s|%s|%s', tostring(surface.index or surface.name), force.name, table.concat(packs, ','), tech and tech.name or '')
      return api.supply.reuse(key, function() return M.science_fresh(surface, force, tech, needed, packs) end)
    end
    return M.science_fresh(surface, force, tech, needed, packs)
  end
  function M.science_fresh(surface, force, tech, needed, packs)
    local names = {}
    for _, name in ipairs(packs) do names[name] = true end
    local scan = api.supply.scan(surface, force, names, {packs=needed, science_value=true})
    local stats = force.get_item_production_statistics(surface)
    local function flow(name, category)
      local ok, n = pcall(qflow.flow, stats, name, category, defines.flow_precision_index.ten_minutes, true)
      return ok and math.floor(n + 0.5) or 0
    end
    -- Agents carrying it, wherever they are.
    local carried = {}
    for _, ag in ipairs(api.agents and api.agents() or {}) do
      local ok, c = pcall(function() local pl = api.lookup(ag.index); return pl and pl.character end)
      local inv = ok and c and c.valid and c.get_main_inventory()
      for _, name in ipairs(packs) do
        local n = inv and inv.get_item_count(name) or 0
        if n > 0 then carried[name] = carried[name] or {}; carried[name][#carried[name]+1] = ag.name .. ' ' .. n end
      end
    end
    local labs = scan.counted.labs or 0
    local out = {}
    for _, name in ipairs(packs) do
      local t = scan.items[name]
      local made, used = flow(name, 'input'), flow(name, 'output')
      local working, states, by_name = 0, {}, {}
      for _, m in ipairs(t.makers) do
        local status = api.status_name(m.e) or 'unknown'
        if status == 'working' then working = working + 1 else states[status] = (states[status] or 0) + 1 end
        by_name[m.e.name] = (by_name[m.e.name] or 0) + 1
      end
      local list = {}
      for status, n in pairs(states) do list[#list+1] = n .. ' ' .. status end
      table.sort(list)
      -- The machines counted, by name (Astra, 06:19: electromagnetic plants and the other Space Age crafters count too).
      local names = {}
      for name, n in pairs(by_name) do names[#names+1] = {name=name, n=n} end
      table.sort(names, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.name < y.name end)
      for i, x in ipairs(names) do names[i] = x.n .. ' ' .. x.name end
      -- Landing pads and platform hubs beside the chests, and among the largest holders (Sol, 23:03: chests 185 and
      -- the largest chests left out the landing pad's 766; Muse read it as 170 agricultural packs left).
      local chests, pads, hubs, rows = 0, 0, 0, {}
      for _, c in ipairs(t.chests) do
        if c.kind == 'pad' then pads = pads + c.n; rows[#rows+1] = c
        elseif c.kind == 'hub' then hubs = hubs + c.n; rows[#rows+1] = c
        elseif c.kind ~= 'vehicle' then chests = chests + c.n; rows[#rows+1] = c end
      end
      table.sort(rows, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.e.position.x < y.e.position.x end)
      local largest = {}
      for i = 1, math.min(3, #rows) do largest[i] = string.format('%s %s %d', at(rows[i].e.position), rows[i].e.name, rows[i].n) end
      local lacking = 0
      for _, u in ipairs(t.users) do if u.lab and u.has == 0 then lacking = lacking + 1 end end
      local line = string.format('%s: made %d, used %d in 10 min; makers %d (%s%d working%s%s); chests %d%s%s, belts %d, labs %d',
        short(name), made, used, #t.makers, #names > 0 and table.concat(names, ', ') .. '; ' or '', working, #list > 0 and ', ' .. table.concat(list, ', ') or '',
        t.outputs > 0 and '; ' .. t.outputs .. ' in their output' or '', chests, pads > 0 and ', landing pads ' .. pads or '',
        hubs > 0 and ', platform hubs ' .. hubs or '', t.belts, t.labs)
      if needed[name] then line = line .. string.format(' (%d of %d labs have none)', lacking, labs)
      else line = line .. ' (the current research does not use it)' end
      if carried[name] then line = line .. '; carried: ' .. table.concat(carried[name], ', ') end
      -- on our platforms stopped over this planet (d15 trajectory analysis: stock in orbit was never counted)
      local orbit = api.supply.orbit_stock and api.supply.orbit_stock(surface, force, name)
      if orbit then line = line .. '; ' .. orbit.line end
      if #largest > 0 then line = line .. '; largest holders: ' .. table.concat(largest, ', ') end
      -- Value comes from the same stack reads as the spoil spread, including
      -- labs' partially consumed packs. The surface scan's scope stays explicit.
      local values, freshness = {}, {}
      for _, r in ipairs(t.spread or {}) do
        local value = api.spoil and api.spoil.research_value(r, force)
        if value then
          value.item, value.count = r.key, r.count
          values[#values+1] = value
          freshness[#freshness+1] = r.key .. '*' .. r.count .. ': ' .. api.spoil.research_text(r, force)
        end
      end
      table.sort(values, function(x, y) return x.item < y.item end)
      table.sort(freshness)
      if #freshness > 0 then line = line .. '; observed stacks on ' .. surface.name .. ': ' .. table.concat(freshness, '; ') end
      -- The pack's recipe tree from the scan's crafters (supply.lua chain).
      local okc, chain = pcall(api.supply.chain, scan, force, surface, name)
      out[#out+1] = {pack=name, effective_research_units=#values > 0 and values or nil, made_10min=made, used_10min=used, makers=#t.makers, makers_working=working, makers_states=#list > 0 and list or nil,
        in_makers=t.outputs, chests=chests, landing_pads=pads > 0 and pads or nil, hubs=hubs > 0 and hubs or nil, belts=t.belts, labs=t.labs, labs_lacking=needed[name] and lacking or nil,
        carried=carried[name], largest=#largest > 0 and largest or nil, line=line, reach=api.supply.reach(t, scan, needed),
        chain=okc and chain and chain.line or nil, chain_tree=okc and chain and chain.tree or nil, chain_cut=okc and chain and chain.cut or nil}
    end
    local research = tech and string.format('%s %d%%', tech.name, math.floor((force.research_progress or 0) * 100)) or 'none'
    return {surface=surface.name, research=research, packs=out, counted=api.supply.counted(scan)}
  end
  return M
end
