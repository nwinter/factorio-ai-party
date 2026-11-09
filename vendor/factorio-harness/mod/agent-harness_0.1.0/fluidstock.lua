-- Native fluid accounting: transport segments once by id, plus each machine's
-- own boxes. Thrusters can expose a joined segment id/contents, but their tank
-- is outside that segment and get_capacity on the thruster is only its tank.
local M = {}
local PIPE = {pipe=true, ['pipe-to-ground']=true, ['storage-tank']=true}
local function try(fn) local ok, v = pcall(fn); if ok then return v end end
M.types = {'pipe','pipe-to-ground','storage-tank','pump','offshore-pump','assembling-machine','furnace','rocket-silo',
  'mining-drill','boiler','generator','fluid-wagon','thruster','fusion-reactor','fusion-generator'}
local function name_of(f) return type(f)=='string' and f or f and f.name end
function M.new()
  local stocks, segments, seen, tanks = {}, {}, {}, {}
  local A = {segments=segments}
  function A.stock(fluid)
    if not stocks[fluid] then
      stocks[fluid] = {stored=0,capacity=0,thrusters={amount=0,capacity=0},pipes={amount=0,capacity=0},
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
      row = {id=id,fluid=f,amount=f and contents[f] or 0,capacity=fb.get_capacity(i),
        at={name=e.name,position=e.position},tanks=0}
      segments[id] = row
      if f then
        bump(f,'pipes',row.amount,row.capacity)
        local s = A.stock(f)
        s.segments[#s.segments+1] = row; s.segments_count = s.segments_count+1
      end
    end
    if e.type=='storage-tank' and not tanks[e] then row.tanks=row.tanks+1; tanks[e]=true end
  end
  function A.add(e)
    if seen[e] then return end
    seen[e] = true
    local fb = e.fluidbox
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
function M.read(surface,force,area)
  local cap, visible, entities = 4096, {}, {}
  local found = surface.find_entities_filtered{force=force,position=area and area.position,radius=area and area.radius,
    type=M.types,limit=cap}
  local own = surface.platform and surface.platform.force==force
  local A = M.new()
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
  return string.format('%s stock %g/%g: thrusters %g/%g; pipes (segments) %g/%g; machines (including pumps) %g/%g; segment ids [%s]',
    fluid,s.stored,s.capacity,s.thrusters.amount,s.thrusters.capacity,s.pipes.amount,s.pipes.capacity,
    s.machines.amount,s.machines.capacity,table.concat(ids,','))
end
return M
