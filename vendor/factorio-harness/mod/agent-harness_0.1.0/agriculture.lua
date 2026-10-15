-- Crop towers in the background census, plus the positions of our recorded losses.
return function(api)
  local M = {}
  local function key(pos) return pos.x .. ',' .. pos.y end
  local function memories(force, surface)
    local st = api.state()
    st.crop_losses = st.crop_losses or {}
    local id = force.name .. '|' .. surface.name
    st.crop_losses[id] = st.crop_losses[id] or {}
    return st.crop_losses[id]
  end
  function M.died(e, cause)
    if not (e and e.valid and e.type == 'agricultural-tower') then return end
    local list = memories(e.force, e.surface)
    local k = key(e.position)
    list[k] = {name=e.name, position={x=e.position.x,y=e.position.y}, state='destroyed', lost_tick=game.tick, cause=cause}
    local n, oldest, tick = 0, nil, math.huge
    for id, row in pairs(list) do n=n+1; if row.lost_tick < tick then oldest, tick=id,row.lost_tick end end
    if n > 256 then list[oldest]=nil end
  end
  function M.read(p, a)
    assert(a.surface == nil or type(a.surface) == 'string', 'surface must be a surface name')
    local s = p.surface
    if a.surface then s = game.get_surface(a.surface) end
    assert(s, 'unknown surface ' .. tostring(a.surface))
    local list, as_of = api.towers(p.force, s)
    local rows, occupied = {}, {}
    local losses = memories(p.force, s)
    for _, e in ipairs(list) do
      if e.valid and e.force == p.force and e.surface == s
        and p.force.is_chunk_visible(s,{x=math.floor(e.position.x/32),y=math.floor(e.position.y/32)}) then
        local ghost = e.type == 'entity-ghost'
        local k = key(e.position)
        local row = {name=ghost and e.ghost_name or e.name, position={x=e.position.x,y=e.position.y},
          state=ghost and 'ghost' or 'built', unit_number=e.unit_number}
        if ghost and losses[k] then row.lost_tick=losses[k].lost_tick; row.cause=losses[k].cause end
        if not ghost then
          losses[k]=nil
          for name, value in pairs(defines.entity_status or {}) do if e.status == value then row.status=name end end
          local inv = e.get_inventory(defines.inventory.agricultural_tower_input)
          row.seeds = inv and inv.get_contents() or {}
        end
        rows[#rows+1]=row; occupied[k]=true
      end
    end
    for k, row in pairs(losses) do if not occupied[k] then rows[#rows+1]=row end end
    table.sort(rows,function(x,y) if x.position.x ~= y.position.x then return x.position.x < y.position.x end return x.position.y < y.position.y end)
    for _, row in ipairs(rows) do
      row.line = string.format('%s (%g,%g): %s%s%s', row.name,row.position.x,row.position.y,row.state,
        row.status and ', ' .. row.status or '', row.lost_tick and ', lost at tick ' .. row.lost_tick or '')
    end
    return {surface=s.name,towers=rows,as_of=as_of,pending=as_of == nil or nil,
      history='up to 256 recorded tower deaths per force/surface since this history was installed; rebuilt positions show the current tower'}
  end
  return M
end
