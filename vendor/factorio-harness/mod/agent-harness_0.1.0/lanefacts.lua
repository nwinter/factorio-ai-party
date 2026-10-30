-- Native lane contents/connections and controls on the visible part of a trace.
-- No throughput estimate or diagnosis: a full lane is not necessarily stationary.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function ref(e) return {entity=e.name, position=e.position, unit_number=e.unit_number} end
  local function side(k) return k % 2 == 1 and 'left' or 'right' end
  function M.controls(e)
    local C = api.circuits and api.circuits()
    local c = C and try(function() return C.conditions(e) end)
    if not c then return nil end
    if c.enable then
      local wired = false
      for _, w in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
        if try(function() return e.get_circuit_network(w) end) then wired = true end
      end
      c.enable_ignored = not wired or nil
    end
    c.lines = C.condition_parts and try(function() return C.condition_parts(e, c) end) or nil
    return c
  end
  function M.lane(e, k)
    local l = try(function() return e.get_transport_line(k) end)
    if not l then return nil end
    local row = {index=k, side=side(k), contents=try(function() return l.get_contents() end),
      can_insert_at_back=try(function() return l.can_insert_at_back() end)}
    local stacks = try(function() return l.get_detailed_contents() end)
    if stacks then
      row.stacks, row.items = #stacks, 0
      for _, it in ipairs(stacks) do
        local st = it.stack
        if st and st.valid_for_read then
          row.items = row.items + (st.count or 1)
          if not row.front or it.position < row.front.position then
            row.front = {name=st.name, quality=try(function() return st.quality.name end), count=st.count, position=it.position}
          end
        end
      end
    end
    return row
  end
  function M.inserter(e, belt)
    local row = ref(e)
    row.status = api.status_name(e)
    row.pickup_position, row.drop_position = e.pickup_position, e.drop_position
    row.pickup_from_left_lane = try(function() return e.pickup_from_left_lane end)
    row.pickup_from_right_lane = try(function() return e.pickup_from_right_lane end)
    row.target_pickup_count = try(function() return e.inserter_target_pickup_count end)
    row.use_filters = try(function() return e.use_filters end)
    row.filter_mode = try(function() return e.inserter_filter_mode end)
    row.filters = {}
    for k=1,try(function() return e.filter_slot_count end) or 0 do
      local f=try(function() return e.get_filter(k) end)
      if f then row.filters[#row.filters+1]=f end
    end
    local h = try(function() return e.held_stack end)
    if h and h.valid_for_read then row.held = {name=h.name, count=h.count} end
    row.controls = M.controls(e)
    if belt and api.lane_near then
      local near = api.lane_near(belt, e.position)
      row.pickup_belt = ref(belt)
      row.near_lane, row.far_lane = near and side(near), near and side(3-near)
    end
    row.pickup_target = e.pickup_target and ref(e.pickup_target) or nil
    row.drop_target = e.drop_target and ref(e.drop_target) or nil
    return row
  end
  function M.read(routes, idx_of, visible)
    local out = {belts={}, inserters={}, side_loads={}, note='lane sides face belt travel; near/far is relative to the inserter; pickup switches are native permissions, not an observed pickup order; can_insert_at_back is the native line read, not a motion measurement'}
    local seen, arms, joins = {}, {}, {}
    local function add_arm(i, belt)
      if visible and not visible(i.position) then return end
      if not arms[i.unit_number] then arms[i.unit_number] = true; out.inserters[#out.inserters+1] = M.inserter(i, belt) end
    end
    for _, route in ipairs(routes) do
      for _, e in ipairs(route.tiles or {}) do
        if e.valid and not seen[e.unit_number] then
          seen[e.unit_number] = true
          local row = ref(e)
          row.status, row.controls, row.lanes = api.status_name(e), M.controls(e), {}
          for k=1,e.get_max_transport_line_index() do row.lanes[#row.lanes+1] = M.lane(e,k) end
          out.belts[#out.belts+1] = row
          local idx = idx_of(e)
          for _, a in ipairs(idx.by_pick[e.unit_number] or {}) do if a.e.valid then add_arm(a.e,e) end end
          for _, a in ipairs(idx.by_drop[e.unit_number] or {}) do if a.e.valid then add_arm(a.e,a.pick and api.is_belt(a.pick) and a.pick or nil) end end
          -- Disabled inserters can have unset native targets; their pickup/drop points remain visible.
          local b = try(function() return e.bounding_box end)
          if b then
            for x=math.floor(b.left_top.x),math.ceil(b.right_bottom.x)-1 do
              for y=math.floor(b.left_top.y),math.ceil(b.right_bottom.y)-1 do
                local key=x..','..y
                for _, a in ipairs((idx.by_pick_tile or {})[key] or {}) do if a.e.valid then add_arm(a.e,e) end end
                for _, a in ipairs((idx.by_drop_tile or {})[key] or {}) do if a.e.valid then add_arm(a.e,a.pick and api.is_belt(a.pick) and a.pick or nil) end end
              end
            end
          end
          -- Count source lanes connected to each destination lane using native line connections.
          for _, b in ipairs(try(function() return e.belt_neighbours.inputs end) or {}) do
            if b.valid and (not visible or visible(b.position)) and b.type ~= 'splitter' and e.type ~= 'splitter' then
              local dest = {}
              for k=1,2 do
                for _, l in ipairs(try(function() return b.get_transport_line(k).output_lines end) or {}) do
                  for j=1,2 do
                    if try(function() return l.line_equals(e.get_transport_line(j)) end) then dest[j] = dest[j] or {}; dest[j][k] = true end
                  end
                end
              end
              for j, src in pairs(dest) do
                local key = b.unit_number .. ':' .. e.unit_number .. ':' .. j
                if src[1] and src[2] and not joins[key] then
                  joins[key] = true
                  local source = ref(b)
                  source.status, source.controls = api.status_name(b), M.controls(b)
                  out.side_loads[#out.side_loads+1] = {from=source, into=ref(e), source_lanes={M.lane(b,1),M.lane(b,2)}, destination_lane=M.lane(e,j), source_lane_count=2, destination_lane_count=1}
                end
              end
            end
          end
        end
      end
    end
    return out
  end
  return M
end
