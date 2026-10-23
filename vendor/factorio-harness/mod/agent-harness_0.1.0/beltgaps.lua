-- Published memory contains plain snapshots. Pending refresh references are
-- processed only while visible, at most 128 entities per call/background step.
-- A hidden pending refresh is discarded without reading its entities.
return function(api)
  local M={}
  local BELT={['transport-belt']=true,['underground-belt']=true,splitter=true,['linked-belt']=true}
  local TYPES={'transport-belt','underground-belt','splitter','linked-belt','entity-ghost'}
  local key=require('numtext').pair  -- x..','..y, fast (numtext; d21 batch73 AI)
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
  -- Each engine field read once (d16 perf: the census observes every belt it reads; a position is a new table at
  -- every read).
  function M.observe(e,p)
    local t=e.type
    if t=='entity-ghost' then t=e.ghost_type end
    if BELT[t] then
      local pos=e.position
      local x,y=math.floor(pos.x/32),math.floor(pos.y/32)
      local f,s=e.force,e.surface
      if f.is_chunk_visible(s,{x=x,y=y}) or p and p.position and
        (pos.x-p.position.x)^2+(pos.y-p.position.y)^2<=32^2 then
        local c=register(f,s,x,y)
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
  local function item_count(e) return e.get_item_count() end
  -- (d22 batch110 BT1: beltgaps.tick made 84 KB of garbage a call on a copy of world n, a new row, position and
  -- bounding box for each belt of the chunk read) whether an entity of this name stands on one tile only: its
  -- prototype's collision box inside its tile whichever way it faces (left and top in [-0.5, 0.5), right and bottom in
  -- (-0.5, 0.5]); one placed on a tile's centre then covers that tile alone, the tile its bounding box gives. By name,
  -- once (prototypes do not change while the game runs).
  local one_tile_names={}
  local function collision_box(name) return prototypes.entity[name].collision_box end
  local function one_tile(name)
    local v=one_tile_names[name]
    if v==nil then
      local ok,b=pcall(collision_box,name)
      v=false
      if ok and b then
        local lt,rb=b.left_top or b[1],b.right_bottom or b[2]
        local x0,y0,x1,y1=lt and (lt.x or lt[1]),lt and (lt.y or lt[2]),rb and (rb.x or rb[1]),rb and (rb.y or rb[2])
        v=type(x0)=='number' and type(y0)=='number' and type(x1)=='number' and type(y1)=='number'
          and x0>=-0.5 and x0<0.5 and y0>=-0.5 and y0<0.5 and x1>-0.5 and x1<=0.5 and y1>-0.5 and y1<=0.5
      end
      one_tile_names[name]=v
    end
    return v
  end
  -- reuse (a refresh read in one step, BT1): a built one-tile belt that stands as its row says (the same type, name,
  -- place and direction) has that row brought up to date in place, with the same fields a new row would get (as
  -- observe_seen does), instead of a new row and position.
  function M.remember(c,e,tiles,p,pos,reuse)
    local et=e.type
    local ghost=et=='entity-ghost';local t=ghost and e.ghost_type or et
    pos=pos or e.position
    local user=e.last_user
    local name,dir=ghost and e.ghost_name or e.name,e.direction
    local tx,ty=math.floor(pos.x),math.floor(pos.y)
    local old=c.tiles and c.tiles[key(tx,ty)]
    local single=not ghost and t~='splitter' and pos.x-tx==0.5 and pos.y-ty==0.5 and one_tile(name)
    local row
    if reuse and single and old and not old.ghost and old.type==t and old.name==name and old.direction==dir
      and old.position.x==pos.x and old.position.y==pos.y then
      row=old
      row.tick,row.by=game.tick,user and user.name or nil
    else
      row={name=name,position={x=pos.x,y=pos.y},direction=dir,ghost=ghost or nil,type=t,tick=game.tick,by=user and user.name or nil}
    end
    if not ghost then
      local ok,n=pcall(item_count,e)
      row.carried_tick=ok and n>0 and game.tick or old and old.carried_tick
      row.items=ok and n or nil
    end
    if t=='underground-belt' and not ghost then
      row.belt_to_ground_type=e.belt_to_ground_type
      local other=e.neighbours
      local op=other and other.valid and other.position
      local paired=nil
      if op and (e.force.is_chunk_visible(e.surface,{x=math.floor(op.x/32),y=math.floor(op.y/32)})
        or p and p.position and (op.x-p.position.x)^2+(op.y-p.position.y)^2<=32^2) then
        paired={x=op.x,y=op.y}
      end
      row.paired_with=paired
    end
    c.tiles=c.tiles or {};tiles=tiles or c.tiles
    if single then
      -- (BT1) the one tile its bounding box covers, without reading the box
      if math.floor(tx/32)==c.x and math.floor(ty/32)==c.y then
        local k=key(tx,ty)
        tiles[k]=row
        if c.cuts then c.cuts[k]=nil end
      end
      return
    end
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
  -- (d21 batch73 AI) observe() for the census: its type and position read, its chunk (cx, cy) in sight; ctx is the
  -- census step's ({belt = {}, force, surface}): each chunk's memory registered once a step.
  -- A one-tile belt seen as it was (same name, place and direction) has its row brought up to date where it is: the same
  -- fields as remember() gives it, without a new row, position and bounding box each pass.
  function M.observe_seen(e,t,pos,cx,cy,ctx)
    local ghost=t=='entity-ghost'
    if ghost then t=e.ghost_type end
    if not BELT[t] then return end
    local ck=cx*1048576+cy
    local c=ctx.belt[ck]
    if not c then c=register(ctx.force,ctx.surface,cx,cy);ctx.belt[ck]=c end
    if not ghost and t~='splitter' and c.tiles then
      local k=key(math.floor(pos.x),math.floor(pos.y))
      local old=c.tiles[k]
      if old and not old.ghost and old.type==t and old.position.x==pos.x and old.position.y==pos.y and old.name==e.name
        and old.direction==e.direction then
        local user=e.last_user
        old.tick=game.tick;old.by=user and user.name or nil
        local ok,n=pcall(item_count,e)
        old.carried_tick=ok and n>0 and game.tick or old.carried_tick
        old.items=ok and n or nil
        if t=='underground-belt' then
          old.belt_to_ground_type=e.belt_to_ground_type
          local other=e.neighbours
          local op=other and other.valid and other.position
          if op and e.force.is_chunk_visible(e.surface,{x=math.floor(op.x/32),y=math.floor(op.y/32)}) then
            old.paired_with={x=op.x,y=op.y}
          else old.paired_with=nil end
        end
        if c.cuts then c.cuts[k]=nil end
        return
      end
    end
    M.remember(c,e,nil,nil,pos)
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
    -- (BT1) a refresh read whole in this one call: its rows brought up to date in place (M.remember reuse); no reader
    -- sees the memory between its find and its end, and no sighting comes after its find
    local reuse=false
    if not job then
      local list=s.find_entities_filtered{area={{c.x*32,c.y*32},{(c.x+1)*32,(c.y+1)*32}},type=TYPES,force=f,limit=1025}
      if #list>1024 then c.capped=true;return false,0 end
      job={list=list,next=1,tiles={},tick=game.tick};c.pending=job
      reuse=#list<=(budget or 128)
    end
    local used=0
    while job.next<=#job.list and used<(budget or 128) do
      local e=job.list[job.next];job.next=job.next+1;used=used+1
      if e.valid then
        local et=e.type
        local t=et=='entity-ghost' and e.ghost_type or et
        if BELT[t] then M.remember(c,e,job.tiles,p,nil,reuse) end
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
  local DIRS={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  -- A leg that is not straight (Haiku: belt_gaps refused a route with corners) follows the belt as remembered from its
  -- start: each belt's direction, an underground entrance to its exit; across a gap (no belt remembered there) it goes
  -- on the way the belt went while that nears the end, else turns toward it. A belt that runs the other way is
  -- followed from the leg's end. Returns the tiles and the underground tiles passed, or nil.
  local function follow(f,s,from,to)
    local m=store()
    local function row(x,y)
      local c=m.chunks[id(f,s,math.floor(x/32),math.floor(y/32))]
      return c and c.tiles and c.tiles[key(x,y)]
    end
    local x,y=math.floor(from.x),math.floor(from.y)
    local tx,ty=math.floor(to.x),math.floor(to.y)
    -- No belt remembered where it starts: nothing to follow.
    if not row(x,y) then return nil end
    local tiles,under,seen,d,gap={},{},{},nil,0
    for _=1,512 do
      local k=key(x,y)
      if seen[k] then return nil end
      seen[k]=true; tiles[#tiles+1]={x=x,y=y}
      if x==tx and y==ty then return tiles,under end
      local r=row(x,y)
      if r and r.type=='underground-belt' and r.belt_to_ground_type=='input' and r.paired_with then
        local px,py=math.floor(r.paired_with.x),math.floor(r.paired_with.y)
        local dx,dy=px>x and 1 or px<x and -1 or 0,py>y and 1 or py<y and -1 or 0
        while x~=px or y~=py do x=x+dx; y=y+dy; if x~=px or y~=py then under[key(x,y)]=true end end
        d=DIRS[r.direction]
      else
        if r and DIRS[r.direction] then d=DIRS[r.direction]; gap=0
        else
          -- more than 32 tiles with no belt remembered: not this belt any more
          gap=gap+1
          if gap>32 then return nil end
          -- a gap: on the way the belt went while that nears the end, else toward it
          local gx,gy=tx>x and 1 or tx<x and -1 or 0,ty>y and 1 or ty<y and -1 or 0
          if not (d and ((d[1]~=0 and d[1]==gx) or (d[2]~=0 and d[2]==gy))) then
            d=gx~=0 and (gy==0 or math.abs(tx-x)>=math.abs(ty-y)) and {gx,0} or {0,gy}
          end
        end
        x=x+d[1]; y=y+d[2]
      end
    end
    return nil
  end
  local function line(a,f,s,prepare)
    local points={api.position(a.from)}
    if a.via then assert(type(a.via)=='table' and #a.via<=16,'via takes at most 16 positions');for _,p in ipairs(a.via) do points[#points+1]=api.position(p) end end
    points[#points+1]=api.position(a.to)
    local tiles,seen,under,followed={},{},{},nil
    local function add(t) local k=key(t.x,t.y); if not seen[k] then tiles[#tiles+1]=t;seen[k]=true;assert(#tiles<=512,'belt line exceeds 512 tiles') end end
    for i=2,#points do
      local x,y=math.floor(points[i-1].x),math.floor(points[i-1].y)
      local tx,ty=math.floor(points[i].x),math.floor(points[i].y)
      if x==tx or y==ty then
        local dx,dy=tx>x and 1 or tx<x and -1 or 0,ty>y and 1 or ty<y and -1 or 0
        while true do
          add({x=x,y=y})
          if x==tx and y==ty then break end;x=x+dx;y=y+dy
        end
      else
        if prepare then prepare(points[i-1],points[i]) end
        local list,u=follow(f,s,points[i-1],points[i])
        if not list then
          local back,ub=follow(f,s,points[i],points[i-1])
          if back then list,u={},ub; for j=#back,1,-1 do list[#list+1]=back[j] end end
        end
        assert(list,string.format('the leg (%g,%g) to (%g,%g) is not horizontal or vertical, and no belt remembered at either end leads to the other within 512 tiles (gaps up to 32 tiles crossed); via supplies corner positions',
          points[i-1].x,points[i-1].y,points[i].x,points[i].y))
        for _,t in ipairs(list) do add(t) end
        for k in pairs(u) do under[k]=true end
        followed=(followed or 0)+1
      end
    end
    return tiles,under,followed
  end
  function M.read(p,a)
    local f,s=p.force,p.surface
    -- Before following a leg round corners, the chunks round it are read as for a straight one (at most 4 refreshed).
    local prepared=0
    local function prepare(from,to)
      for cx=math.floor(math.min(from.x,to.x)/32),math.floor(math.max(from.x,to.x)/32) do
        for cy=math.floor(math.min(from.y,to.y)/32),math.floor(math.max(from.y,to.y)/32) do
          local c=register(f,s,cx,cy)
          if prepared<4 and visible(c,f,s,p) and not c.tick then prepared=prepared+1; refresh(c,f,s,p,128) end
        end
      end
    end
    local wanted,under_followed,followed=line(a,f,s,prepare)
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
      followed=followed and string.format('%d leg%s not straight: followed the remembered belt round its corners (gaps crossed toward the end)',followed,followed==1 and '' or 's') or nil,
      memory='last completed layout only; pending refreshes are disclosed; fogged tiles are not queried; unrecorded tiles are unknown, not missing'}
    for _,c in pairs(chunks) do out.observations[#out.observations+1]={chunk={x=c.x,y=c.y},tick=c.tick,current=c.tick==game.tick,capped=c.capped,pending=c.pending and {read=c.pending.next-1,total=#c.pending.list} or nil} end
    table.sort(out.observations,function(a,b) return a.chunk.y<b.chunk.y or a.chunk.y==b.chunk.y and a.chunk.x<b.chunk.x end)
    for _,t in ipairs(wanted) do
      local c=chunks[key(math.floor(t.x/32),math.floor(t.y/32))];local r=c.tiles and c.tiles[key(t.x,t.y)]
      local row={position={x=t.x+0.5,y=t.y+0.5},observed_tick=c.tick,current=c.tick==game.tick}
      if r then
        if r.ghost then row.name=r.name;row.direction=r.direction;out.ghosts[#out.ghosts+1]=row else out.belts=out.belts+1 end
      elseif covered[key(t.x,t.y)] or under_followed[key(t.x,t.y)] then out.underground=out.underground+1
      elseif not c.tick then out.unknown[#out.unknown+1]=row
      else
        -- what stands on a missing tile now, in sight (Sonnet: a pole on the line's tile)
        if api.blocker and #out.missing<32 and visible(c,f,s,p) then
          local blk=api.blocker(s,row.position)
          if blk then row.blocked_by={name=blk.name,position=blk.position,force=blk.force and blk.force.name};row.line=api.blocker_text(blk,'on ('..row.position.x..','..row.position.y..')') end
        end
        out.missing[#out.missing+1]=row
      end
    end
    -- (d20 batch53 M1, Sol #932) the stretches standing only as ghosts: breaks until built, with their materials and
    -- robot coverage; a tile missing, under ground or not recorded parts two stretches
    if #out.ghosts>0 then
      local seq={}
      for _,t in ipairs(wanted) do
        local c=chunks[key(math.floor(t.x/32),math.floor(t.y/32))];local r=c.tiles and c.tiles[key(t.x,t.y)]
        seq[#seq+1]={position={x=t.x+0.5,y=t.y+0.5},ghost=r and r.ghost or false,name=r and r.name}
      end
      local okb,GB=pcall(require,'ghostbreaks')
      if okb then out.ghost_breaks,out.ghost_line=GB().breaks(seq,s,f) end
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
            -- what stands there now, in sight (Sonnet: a pole on the line's tile)
            local f,s=game.forces[c.force],game.surfaces[c.surface]
            local blk=api.blocker and f and s and f.is_chunk_visible(s,{x=c.x,y=c.y}) and api.blocker(s,v.position)
            text[#text+1]=string.format('(%g,%g), carried items at tick %d, missing at tick %d%s',v.position.x,v.position.y,v.carried_tick,v.tick,
              blk and '; '..api.blocker_text(blk,'there now') or '')
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
