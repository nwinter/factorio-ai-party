-- Published memory contains plain snapshots. Pending refresh references are
-- processed only while visible, at most 128 entities per call/background step.
-- A hidden pending refresh is discarded without reading its entities.
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
  function M.observe(e,p)
    local t=e.type=='entity-ghost' and e.ghost_type or e.type
    if BELT[t] then
      local x,y=math.floor(e.position.x/32),math.floor(e.position.y/32)
      if e.force.is_chunk_visible(e.surface,{x=x,y=y}) or p and p.position and
        (e.position.x-p.position.x)^2+(e.position.y-p.position.y)^2<=32^2 then
        local c=register(e.force,e.surface,x,y)
        M.remember(c,e)
      end
    end
  end
  local function visible(c,f,s,p)
    if f.is_chunk_visible(s,{x=c.x,y=c.y}) then return true end
    if not (p and p.position) or type(p)=='table' and rawget(p,'__remote') then return false end
    for _,x in ipairs({c.x*32+.5,c.x*32+31.5}) do
      for _,y in ipairs({c.y*32+.5,c.y*32+31.5}) do
        if (x-p.position.x)^2+(y-p.position.y)^2>32^2 then return false end
      end
    end
    return true
  end
  -- Each belt's previous item observation survives an empty sample. Missing
  -- tiles become alerts only after a later visible chunk snapshot confirms it.
  function M.remember(c,e,tiles,p)
    local ghost=e.type=='entity-ghost';local t=ghost and e.ghost_type or e.type
    local row={name=ghost and e.ghost_name or e.name,position={x=e.position.x,y=e.position.y},direction=e.direction,
      ghost=ghost or nil,type=t,tick=game.tick,by=e.last_user and e.last_user.name or nil}
    local old=c.tiles and c.tiles[key(math.floor(e.position.x),math.floor(e.position.y))]
    if not ghost then
      local ok,n=pcall(function() return e.get_item_count() end)
      row.carried_tick=ok and n>0 and game.tick or old and old.carried_tick
      row.items=ok and n or nil
    end
    if t=='underground-belt' and not ghost then
      row.belt_to_ground_type=e.belt_to_ground_type
      local other=e.neighbours
      if other and other.valid and (e.force.is_chunk_visible(e.surface,{x=math.floor(other.position.x/32),y=math.floor(other.position.y/32)})
        or p and p.position and (other.position.x-p.position.x)^2+(other.position.y-p.position.y)^2<=32^2) then
        row.paired_with={x=other.position.x,y=other.position.y}
      end
    end
    c.tiles=c.tiles or {};tiles=tiles or c.tiles
    local b=e.bounding_box
    for x=math.floor(b.left_top.x),math.ceil(b.right_bottom.x)-1 do
      for y=math.floor(b.left_top.y),math.ceil(b.right_bottom.y)-1 do
        if math.floor(x/32)==c.x and math.floor(y/32)==c.y then
          local k=key(x,y)
          -- A ghost can overlap a built belt. Only a complete visible refresh
          -- establishes that the real belt is absent; keep its prior observation.
          if not tiles[k] or not ghost or tiles[k].ghost then tiles[k]=row end
          if not ghost and c.cuts then c.cuts[k]=nil end
        end
      end
    end
  end
  local function compare(c,tiles,tick)
    c.cuts=c.cuts or {}
    for k,r in pairs(c.tiles or {}) do
      if r.carried_tick and not r.ghost and (not tiles[k] or tiles[k].ghost) then
        c.cuts[k]=c.cuts[k] or {position={x=tonumber(k:match('^(.-),'))+.5,y=tonumber(k:match(',(.*)$'))+.5},carried_tick=r.carried_tick,tick=tick,by=r.by}
      end
    end
    for k in pairs(c.cuts) do if tiles[k] and not tiles[k].ghost then c.cuts[k]=nil end end
  end
  local function refresh(c,f,s,p,budget)
    if not visible(c,f,s,p) then c.pending=nil;return false,0 end
    local job=c.pending
    if not job then
      local list=s.find_entities_filtered{area={{c.x*32,c.y*32},{(c.x+1)*32,(c.y+1)*32}},type=TYPES,force=f,limit=1025}
      if #list>1024 then c.capped=true;return false,0 end
      job={list=list,next=1,tiles={},tick=game.tick};c.pending=job
    end
    local used=0
    while job.next<=#job.list and used<(budget or 128) do
      local e=job.list[job.next];job.next=job.next+1;used=used+1
      if e.valid then
        local t=e.type=='entity-ghost' and e.ghost_type or e.type
        if BELT[t] then M.remember(c,e,job.tiles,p) end
      end
    end
    if job.next<=#job.list then return false,used end
    -- Explicit sightings during a multi-step refresh are newer than its find.
    for k,r in pairs(c.tiles or {}) do if r.tick and r.tick>job.tick then job.tiles[k]=r end end
    compare(c,job.tiles,job.tick)
    c.tiles=job.tiles;c.tick=job.tick;c.capped=nil;c.pending=nil
    return true,used
  end
  function M.tick(tick)
    if tick%15~=0 then return end
    local m=store();if #m.order==0 then return end
    m.next=(m.next-1)%#m.order+1
    local c=m.chunks[m.order[m.next]]
    local f,s=game.forces[c.force],game.surfaces[c.surface]
    if f and s then refresh(c,f,s) else c.pending=nil end
    if not c.pending then m.next=m.next+1 end
  end
  local function line(a)
    local points={api.position(a.from)}
    if a.via then assert(type(a.via)=='table' and #a.via<=16,'via takes at most 16 positions');for _,p in ipairs(a.via) do points[#points+1]=api.position(p) end end
    points[#points+1]=api.position(a.to)
    local tiles,seen={},{}
    for i=2,#points do
      local x,y=math.floor(points[i-1].x),math.floor(points[i-1].y)
      local tx,ty=math.floor(points[i].x),math.floor(points[i].y)
      assert(x==tx or y==ty,'each belt line leg must be horizontal or vertical; via supplies corner positions')
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
    local chunks,refreshed,budget={},0,128
    for _,t in ipairs(wanted) do
      local x,y=math.floor(t.x/32),math.floor(t.y/32);local k=key(x,y)
      if not chunks[k] then
        local c=register(f,s,x,y);chunks[k]=c
        if refreshed<4 and budget>0 and visible(c,f,s,p) then
          refreshed=refreshed+1;local _,used=refresh(c,f,s,p,budget);budget=budget-used
        elseif not visible(c,f,s,p) then c.pending=nil end
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
      memory='last completed layout only; pending refreshes are disclosed; fogged tiles are not queried; unrecorded tiles are unknown, not missing'}
    for _,c in pairs(chunks) do out.observations[#out.observations+1]={chunk={x=c.x,y=c.y},tick=c.tick,current=c.tick==game.tick,capped=c.capped,pending=c.pending and {read=c.pending.next-1,total=#c.pending.list} or nil} end
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
  function M.alert_groups(force)
    local out={}
    for _,k in ipairs(store().order) do
      local c=store().chunks[k]
      if c.force==force.name and next(c.cuts or {}) then
        local g={key='belt_cut|'..k,kind='belt_cut',surface=c.surface,n=0,names={},by={},at={},center={x=c.x*32+16,y=c.y*32+16}}
        local points={};for _,v in pairs(c.cuts) do points[#points+1]=v end
        table.sort(points,function(a,b) return a.position.y<b.position.y or a.position.y==b.position.y and a.position.x<b.position.x end)
        local text={}
        for _,v in ipairs(points) do
          g.n=g.n+1;g.rank=math.max(g.rank or 0,v.tick)
          if v.by then g.by[v.by]=(g.by[v.by] or 0)+1 end
          if #text<8 then
            g.at[#g.at+1]=v.position
            text[#text+1]=string.format('(%g,%g), carried items at tick %d, missing at tick %d',v.position.x,v.position.y,v.carried_tick,v.tick)
          end
        end
        g.rank=g.rank*1025+g.n
        g.line=string.format('belt cut: %d formerly carrying belt tiles missing: %s%s; layout last observed tick %d',g.n,table.concat(text,'; '),g.n>8 and '; +'..(g.n-8)..' more' or '',c.tick or 0)
        out[#out+1]=g
      end
    end
    return out
  end
  function M.trace(p,a)
    local q=api.position(a.position);local m=store()
    local out={by='last seen memory',current=false,surface=p.surface.name,layout={},
      memory='recorded belt layout and item counts only; current state and lane routing are unknown'}
    local seen={}
    for _=1,512 do
      local x,y=math.floor(q.x),math.floor(q.y);local k=key(x,y)
      if seen[k] then out.stop='remembered layout loops';break end;seen[k]=true
      local c=m.chunks[id(p.force,p.surface,math.floor(x/32),math.floor(y/32))]
      local r=c and c.tiles and c.tiles[k]
      if not r then out.stop='no recorded belt at ('..(x+.5)..','..(y+.5)..')';break end
      if a.name and #out.layout==0 and r.name~=a.name then return nil end
      if a.unit_number then return nil end
      local tick=r.tick or c.tick
      out.layout[#out.layout+1]={name=r.name,position=r.position,direction=r.direction,ghost=r.ghost,
        observed_tick=tick,age_ticks=game.tick-tick,items=r.items,paired_with=r.paired_with}
      out.observed_tick=math.min(out.observed_tick or tick,tick)
      if r.ghost or r.type=='splitter' or r.type=='linked-belt' then out.stop='recorded '..r.type..'; lane routing not recorded';break end
      if r.type=='underground-belt' and r.belt_to_ground_type=='input' then
        if not r.paired_with then out.stop='underground partner not recorded';break end
        q=r.paired_with
      else
        local d=({[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}})[r.direction]
        if not d then out.stop='direction not recorded';break end
        q={x=r.position.x+d[1],y=r.position.y+d[2]}
      end
    end
    if #out.layout==0 then return nil end
    out.stop=out.stop or '512-tile memory limit';out.age_ticks=game.tick-out.observed_tick;out.age_s=out.age_ticks/60
    return out
  end
  return M
end
