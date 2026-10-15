-- Map memory contains plain snapshots, never entity references read under fog.
-- A census sighting registers a chunk; one registered visible chunk is refreshed
-- each second. Explicit reads refresh at most four chunks, then use memory.
return function(api)
  local M={}
  local BELT={['transport-belt']=true,['underground-belt']=true,splitter=true,['linked-belt']=true}
  local TYPES={'transport-belt','underground-belt','splitter','linked-belt','entity-ghost'}
  local function key(x,y) return x..','..y end
  local function id(f,s,x,y) return f.name..'|'..s.name..'|'..key(x,y) end
  local function store()
    local s=api.state();s.belt_memory=s.belt_memory or {chunks={},order={},next=1};return s.belt_memory
  end
  local function register(f,s,x,y)
    local m=store();local k=id(f,s,x,y)
    if not m.chunks[k] then
      if #m.order>=256 then local old=table.remove(m.order,1);m.chunks[old]=nil end
      m.order[#m.order+1]=k;m.chunks[k]={force=f.name,surface=s.name,x=x,y=y}
    end
    return m.chunks[k]
  end
  function M.observe(e)
    local t=e.type=='entity-ghost' and e.ghost_type or e.type
    if BELT[t] then
      local x,y=math.floor(e.position.x/32),math.floor(e.position.y/32)
      if e.force.is_chunk_visible(e.surface,{x=x,y=y}) then register(e.force,e.surface,x,y) end
    end
  end
  local function visible(c,f,s,p)
    if f.is_chunk_visible(s,{x=c.x,y=c.y}) then return true end
    if not (p and p.position) then return false end
    for _,x in ipairs({c.x*32+.5,c.x*32+31.5}) do
      for _,y in ipairs({c.y*32+.5,c.y*32+31.5}) do
        if (x-p.position.x)^2+(y-p.position.y)^2>32^2 then return false end
      end
    end
    return true
  end
  local function refresh(c,f,s,p)
    if not visible(c,f,s,p) then return false end
    local list=s.find_entities_filtered{area={{c.x*32,c.y*32},{(c.x+1)*32,(c.y+1)*32}},type=TYPES,force=f,limit=1025}
    if #list>1024 then c.capped=true;return false end
    local tiles={}
    for _,e in ipairs(list) do
      local ghost=e.type=='entity-ghost'
      local t=ghost and e.ghost_type or e.type
      if e.valid and BELT[t] then
        local row={name=ghost and e.ghost_name or e.name,position={x=e.position.x,y=e.position.y},direction=e.direction,ghost=ghost or nil,type=t}
        if t=='underground-belt' and not ghost then
          row.belt_to_ground_type=e.belt_to_ground_type
          local other=e.neighbours
          if other and other.valid and (f.is_chunk_visible(s,{x=math.floor(other.position.x/32),y=math.floor(other.position.y/32)})
            or p and p.position and (other.position.x-p.position.x)^2+(other.position.y-p.position.y)^2<=32^2) then
            row.paired_with={x=other.position.x,y=other.position.y}
          end
        end
        local b=e.bounding_box
        for x=math.floor(b.left_top.x),math.ceil(b.right_bottom.x)-1 do
          for y=math.floor(b.left_top.y),math.ceil(b.right_bottom.y)-1 do
            if math.floor(x/32)==c.x and math.floor(y/32)==c.y then
              local k=key(x,y);if not tiles[k] or not ghost then tiles[k]=row end
            end
          end
        end
      end
    end
    c.tiles=tiles;c.tick=game.tick;c.capped=nil
    return true
  end
  function M.tick(tick)
    if tick%60~=0 then return end
    local m=store();if #m.order==0 then return end
    m.next=(m.next-1)%#m.order+1
    local c=m.chunks[m.order[m.next]];m.next=m.next+1
    local f,s=game.forces[c.force],game.surfaces[c.surface]
    if f and s then refresh(c,f,s) end
  end
  local function line(a)
    local points={api.position(a.from)}
    if a.via then assert(type(a.via)=='table' and #a.via<=16,'via takes at most 16 positions');for _,p in ipairs(a.via) do points[#points+1]=api.position(p) end end
    points[#points+1]=api.position(a.to)
    local tiles,seen={},{}
    for i=2,#points do
      local x,y=math.floor(points[i-1].x),math.floor(points[i-1].y)
      local tx,ty=math.floor(points[i].x),math.floor(points[i].y)
      assert(x==tx or y==ty,'each belt line leg must be horizontal or vertical; use via for corners')
      local dx,dy=tx>x and 1 or tx<x and -1 or 0,ty>y and 1 or ty<y and -1 or 0
      while true do
        local k=key(x,y)
        if not seen[k] then tiles[#tiles+1]={x=x,y=y};seen[k]=true;assert(#tiles<=512,'belt line exceeds 512 tiles') end
        if x==tx and y==ty then break end;x=x+dx;y=y+dy
      end
    end
    return tiles
  end
  function M.read(p,a)
    local wanted=line(a)
    local f,s=p.force,p.surface
    local chunks,refreshed={},0
    for _,t in ipairs(wanted) do
      local x,y=math.floor(t.x/32),math.floor(t.y/32);local k=key(x,y)
      if not chunks[k] then
        local c=register(f,s,x,y);chunks[k]=c
        if refreshed<4 and visible(c,f,s,p) then refreshed=refreshed+1;refresh(c,f,s,p) end
      end
    end
    local covered={}
    for _,c in pairs(chunks) do
      for _,r in pairs(c.tiles or {}) do
        if r.paired_with then
          local x,y=math.floor(r.position.x),math.floor(r.position.y)
          local tx,ty=math.floor(r.paired_with.x),math.floor(r.paired_with.y)
          local end_chunk=chunks[key(math.floor(tx/32),math.floor(ty/32))]
          local partner=end_chunk and end_chunk.tiles and end_chunk.tiles[key(tx,ty)]
          local contradicted=end_chunk and end_chunk.tick and end_chunk.tick>=c.tick and
            (not partner or partner.ghost or partner.type~='underground-belt' or not partner.paired_with or
              math.floor(partner.paired_with.x)~=x or math.floor(partner.paired_with.y)~=y)
          if not contradicted and (x==tx or y==ty) and math.abs(x-tx)+math.abs(y-ty)<=32 then
            local dx,dy=tx>x and 1 or tx<x and -1 or 0,ty>y and 1 or ty<y and -1 or 0
            while x~=tx or y~=ty do x=x+dx;y=y+dy;if x~=tx or y~=ty then covered[key(x,y)]=c.tick end end
          end
        end
      end
    end
    local out={surface=s.name,tiles=#wanted,missing={},ghosts={},unknown={},belts=0,underground=0,observations={},checked_tick=game.tick,
      memory='last observed layout only; fogged tiles are not queried; unrecorded tiles are unknown, not missing'}
    for _,c in pairs(chunks) do out.observations[#out.observations+1]={chunk={x=c.x,y=c.y},tick=c.tick,current=c.tick==game.tick,capped=c.capped} end
    table.sort(out.observations,function(a,b) return a.chunk.y<b.chunk.y or a.chunk.y==b.chunk.y and a.chunk.x<b.chunk.x end)
    for _,t in ipairs(wanted) do
      local c=chunks[key(math.floor(t.x/32),math.floor(t.y/32))];local r=c.tiles and c.tiles[key(t.x,t.y)]
      local row={position={x=t.x+0.5,y=t.y+0.5},observed_tick=c.tick,current=c.tick==game.tick}
      if r then
        if r.ghost then row.name=r.name;row.direction=r.direction;out.ghosts[#out.ghosts+1]=row else out.belts=out.belts+1 end
      elseif covered[key(t.x,t.y)] then out.underground=out.underground+1
      elseif not c.tick then out.unknown[#out.unknown+1]=row
      else out.missing[#out.missing+1]=row end
    end
    return out
  end
  return M
end
