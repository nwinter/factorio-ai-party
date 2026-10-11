-- labs: the research line at a glance. One header line (research, progress,
-- ETA) and one line per group of adjacent labs: working count, packs the
-- labs lack, and why their feeders (inserters and the belts or chests they
-- take from) are not delivering. Bounded: 256 labs, 8 groups, read on demand.
return function(api)
  local M = {}
  local MAX_LABS, MAX_GROUPS, NEAR = 256, 8, 5.5
  M.schema = {labs = {position='optional charted centre (default character)', radius='1..256 (default 96)',
    returns='research line (name, progress, eta at the working labs) and per lab group: labs working, packs missing (labs lacking each), feeders idle/starved and why, what their belts/chests hold'}}
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
  function M.view(p, a)
    local centre = api.center(p, a)
    local radius = api.integer(a.radius, 96, 1, 256, 'radius')
    local force, surface = p.force, p.surface
    local tech = force.current_research
    local packs = {}
    for _, ing in ipairs(tech and tech.research_unit_ingredients or {}) do packs[#packs+1] = ing.name end
    local labs = surface.find_entities_filtered{position=centre, radius=radius, type='lab', force=force, limit=MAX_LABS}
    -- Groups: labs within NEAR tiles of one another (chains of adjacent labs).
    local group_of, groups = {}, {}
    for i, e in ipairs(labs) do
      if not group_of[i] then
        local g = {i}; group_of[i] = g; groups[#groups+1] = g
        local k = 1
        while k <= #g do
          local x = labs[g[k]].position
          for j, f in ipairs(labs) do
            if not group_of[j] and math.abs(f.position.x - x.x) <= NEAR and math.abs(f.position.y - x.y) <= NEAR then group_of[j] = g; g[#g+1] = j end
          end
          k = k + 1
        end
      end
    end
    table.sort(groups, function(x, y) return #x > #y end)
    local working, lines = 0, {}
    for gi, g in ipairs(groups) do
      local box = {left_top={x=math.huge, y=math.huge}, right_bottom={x=-math.huge, y=-math.huge}}
      local statuses, lacking, member = {}, {}, {}
      for _, i in ipairs(g) do
        local e = labs[i]; member[e.unit_number or i] = true
        local status = api.status_name(e) or 'unknown'
        statuses[status] = (statuses[status] or 0) + 1
        if status == 'working' then working = working + 1 end
        local inv = e.get_inventory(defines.inventory.lab_input)
        for _, name in ipairs(packs) do if inv and inv.get_item_count(name) == 0 then lacking[name] = (lacking[name] or 0) + 1 end end
        box.left_top.x = math.min(box.left_top.x, e.position.x - 3); box.left_top.y = math.min(box.left_top.y, e.position.y - 3)
        box.right_bottom.x = math.max(box.right_bottom.x, e.position.x + 3); box.right_bottom.y = math.max(box.right_bottom.y, e.position.y + 3)
      end
      if gi <= MAX_GROUPS then
        local parts = {string.format('labs %s-%s: %d/%d working', at({x=box.left_top.x+3, y=box.left_top.y+3}), at({x=box.right_bottom.x-3, y=box.right_bottom.y-3}), statuses.working or 0, #g)}
        for status, n in pairs(statuses) do if status ~= 'working' then parts[#parts+1] = n .. ' ' .. status end end
        local miss = {}
        for _, name in ipairs(packs) do if lacking[name] then miss[#miss+1] = short(name) .. ' (' .. lacking[name] .. ')' end end
        if #miss > 0 then parts[#parts+1] = 'lack ' .. table.concat(miss, ', ') end
        -- Feeders: inserters dropping into these labs; their sources say why.
        local feeders, idle, sources, chained = 0, {}, {}, 0
        for _, ins in pairs(surface.find_entities_filtered{area=box, type='inserter', force=force, limit=128}) do
          local ok, target = pcall(function() return ins.drop_target end)
          if ok and target and target.type == 'lab' and member[target.unit_number] then
            feeders = feeders + 1
            local src = ins.pickup_target
            if src and src.type == 'lab' then chained = chained + 1
            elseif src and not sources[src.unit_number or at(src.position)] then
              sources[src.unit_number or at(src.position)] = src; sources[#sources+1] = src
            end
            local status = api.status_name(ins) or 'unknown'
            if status ~= 'working' and status ~= 'waiting_for_target_to_be_built' and not (ins.held_stack and ins.held_stack.valid_for_read) then
              local why = status == 'waiting_for_source_items' and (src and 'source ' .. src.name .. ' ' .. at(src.position) .. ' has nothing the lab needs' or 'nothing to pick up from') or status
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
        if feeders == 0 then feed[1] = 'no inserters feed these labs (hand feed: feed radius=R)'
        elseif #absent > 0 and #sources > 0 then feed[#feed+1] = 'no ' .. table.concat(absent, ', ') .. ' on their ' .. #sources .. ' belts/chests' end
        if #carried > 0 then feed[#feed+1] = 'sources hold ' .. table.concat(carried, ', ') end
        lines[#lines+1] = table.concat(parts, ', ') .. '; feeders: ' .. table.concat(feed, '; ')
      end
    end
    local research
    if not tech then research = 'none: nothing queued (fh call research technology=NAME)'
    else
      local progress = force.research_progress or 0
      local names = {}
      for i, n in ipairs(packs) do names[i] = short(n) end
      research = string.format('%s %d%% needs %s', tech.name, math.floor(progress * 100), table.concat(names, '+'))
      local ok, speed = pcall(function() return labs[1] and labs[1].prototype.researching_speed or 1 end)
      speed = (ok and speed or 1) * (1 + (force.laboratory_speed_modifier or 0))
      if working > 0 and tech.research_unit_energy then
        local left = (1 - progress) * tech.research_unit_count * tech.research_unit_energy / 60 / speed / working
        research = research .. string.format(', eta %s at %d working labs', fmt(math.ceil(left)), working)
      else research = research .. ', stalled: no lab is working' end
    end
    return {research=research, labs=#labs .. (#labs >= MAX_LABS and '+' or '') .. ' in ' .. #groups .. ' groups' .. (#groups > MAX_GROUPS and ' (largest ' .. MAX_GROUPS .. ' shown)' or ''), groups=lines}
  end
  return M
end
