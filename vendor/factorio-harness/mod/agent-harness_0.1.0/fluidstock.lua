-- Fluid accounting: on 2.1 a segment includes every connected storage share.
-- Count each segment once, then independent stores. On 2.0 machine stores are
-- outside transport segment totals, including thruster tanks.
local M = {}
local PIPE = {pipe=true, ['pipe-to-ground']=true, ['storage-tank']=true, ['infinity-pipe']=true}
local function try(fn) local ok, v = pcall(fn); if ok then return v end end
M.types = {'pipe','pipe-to-ground','storage-tank','pump','offshore-pump','assembling-machine','furnace','rocket-silo',
  'mining-drill','boiler','generator','fluid-wagon','thruster','fusion-reactor','fusion-generator'}
local function name_of(f) return type(f)=='string' and f or f and f.name end
function M.new(fluid_boxes)
  fluid_boxes = fluid_boxes or function(e) return e.fluidbox end
  local stocks, segments, seen, tanks = {}, {}, {}, {}
  local A = {segments=segments}
  function A.stock(fluid)
    if not stocks[fluid] then
      stocks[fluid] = {native=A.native or nil,stored=0,capacity=0,thrusters={amount=0,capacity=0},pipes={amount=0,capacity=0},
        machines={amount=0,capacity=0},segments={},segments_count=0}
    end
    return stocks[fluid]
  end
  local function bump(fluid, kind, amount, capacity)
    local s = A.stock(fluid)
    s.stored, s.capacity = s.stored+amount, s.capacity+capacity
    s[kind].amount, s[kind].capacity = s[kind].amount+amount, s[kind].capacity+capacity
  end
  local function pipe(e, fb, i)
    local id = try(function() return fb.get_fluid_segment_id(i) end)
    if not id then return end
    local row = segments[id]
    if not row then
      local contents = try(function() return fb.get_fluid_segment_contents(i) end) or {}
      local f = next(contents) or name_of(try(function() return fb.get_locked_fluid(i) end))
      row = {id=id,fluid=f,amount=f and contents[f] or 0,capacity=fb.object_name=='HarnessFluidStorage' and fb.get_segment_capacity(i) or fb.get_capacity(i),
        at={name=e.name,position=e.position},tanks=0}
      segments[id] = row
      if f then
        bump(f,'pipes',row.amount,row.capacity)
        local s = A.stock(f)
        s.segments[#s.segments+1] = row; s.segments_count = s.segments_count+1
      end
    end
    if e.type=='storage-tank' and not tanks[e] then row.tanks=row.tanks+1; tanks[e]=true end
    return row
  end
  function A.add(e)
    if seen[e] then return end
    seen[e] = true
    local fb = fluid_boxes(e)
    if fb and fb.object_name=='HarnessFluidStorage' then
      A.native=true
      for i=1,#fb do
        local own=fb[i]
        local row=pipe(e,fb,i)
        local f=row and row.fluid or (own and own.name) or name_of(fb.get_filter(i))
        if not row then
          if f then bump(f,e.type=='thruster' and 'thrusters' or 'machines',own and own.amount or 0,fb.get_own_capacity(i)) end
        elseif f and not PIPE[e.type] then
          -- Segment totals include the machine's proportional share on 2.1. Allocate that share,
          -- without adding it again. Unseen members remain in the connected remainder.
          local amount=own and own.name==f and own.amount or 0
          local capacity=fb.get_own_capacity(i)
          bump(f,'pipes',-amount,-capacity)
          bump(f,e.type=='thruster' and 'thrusters' or 'machines',amount,capacity)
        end
        -- Read the exact neighbouring store, including a segment outside a near query's area.
        for _, cn in ipairs(fb.get_neighbours(i) or {}) do pipe(cn.entity,fluid_boxes(cn.entity),cn.index) end
      end
      return
    end
    for i=1,fb and #fb or 0 do
      if PIPE[e.type] then pipe(e,fb,i)
      else
        local own = fb[i]
        local f = own and own.name or name_of(try(function() return fb.get_locked_fluid(i) end))
          or name_of(try(function() return fb.get_filter(i) end))
        if f then bump(f,e.type=='thruster' and 'thrusters' or 'machines',own and own.amount or 0,fb.get_capacity(i)) end
        -- A near read can include a machine without a pipe anchor in its area.
        -- Read segment capacity only at a transport box, never at that machine.
        for _, cn in ipairs(try(function() return fb.get_connections(i) end) or {}) do
          local owner = try(function() return cn.owner end)
          if owner and PIPE[owner.type] then
            for j=1,#cn do pipe(owner,cn,j) end
          end
        end
      end
    end
  end
  function A.finish()
    for _, s in pairs(stocks) do table.sort(s.segments,function(a,b) return a.id<b.id end) end
    return A
  end
  return A
end
function M.read(surface,force,area,fluid_boxes)
  local cap, visible, entities = 4096, {}, {}
  local types=M.types
  if script and script.active_mods and (tonumber((script.active_mods.base or ''):match('^2%.(%d+)%.')) or 0)>=1 then
    types={};for _,t in ipairs(M.types) do types[#types+1]=t end;types[#types+1]='fluid-turret';types[#types+1]='infinity-pipe'
  end
  local found = surface.find_entities_filtered{force=force,position=area and area.position,radius=area and area.radius,
    type=types,limit=cap}
  local own = surface.platform and surface.platform.force==force
  local A = M.new(fluid_boxes)
  for _, e in ipairs(found) do
    local x,y = math.floor(e.position.x/32),math.floor(e.position.y/32)
    visible[x] = visible[x] or {}
    if visible[x][y]==nil then visible[x][y]=own or force.is_chunk_visible(surface,{x=x,y=y}) end
    if visible[x][y] then entities[#entities+1]=e; A.add(e) end
  end
  A.entities = entities
  A.counted = {found=#found,visible=#entities,limit=cap,limited=#found>=cap}
  return A.finish()
end
function M.line(fluid,s)
  local ids = {}; for _, row in ipairs(s.segments) do ids[#ids+1]=tostring(row.id) end
  return string.format('%s stock %g/%g: thrusters %g/%g; %s %g/%g; machines (including pumps) %g/%g; segment ids [%s]',
    fluid,s.stored,s.capacity,s.thrusters.amount,s.thrusters.capacity,s.native and 'connected remainder (including unseen members)' or 'pipes (segments)',s.pipes.amount,s.pipes.capacity,
    s.machines.amount,s.machines.capacity,table.concat(ids,','))
end
return M
