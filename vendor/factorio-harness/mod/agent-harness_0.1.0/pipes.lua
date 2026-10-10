-- Fluid connections and pipe routing. A plain pipe joins every neighbour
-- whose connection points at its tile, so the router lays plain pipe only
-- where nothing foreign connects, and passes beside or across other pipes,
-- machines and belts with pipe-to-ground pairs (open on one side, joined
-- underground). Plans only; the caller places the result as ghosts.
local heap=require('heap')
return function(api)
  local M={}
  local DIRS={0,4,8,12}
  local STEP={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  local NAME={[0]='north',[4]='east',[8]='south',[12]='west'}
  local LETTER={[0]='N',[4]='E',[8]='S',[12]='W'}
  local FLOW={input='in',output='out',['input-output']='io'}
  local MARGIN,MAX_SPAN,MAX_EXPANSIONS=16,200,20000
  -- Surveyed beyond the search box: connections and underground reach of
  -- entities outside it still land inside.
  local PAD=12
  -- Costs in pipe tiles: pipes have no direction, the small turn cost only
  -- keeps lines straight; a pipe-to-ground pair wins where it saves detours.
  local TURN_COST,UNDERGROUND_COST=0.1,3
  local function opposite(d) return (d+8)%16 end
  local function axis(d) return d%8==0 and 'v' or 'h' end
  local function key(x,y) return x..','..y end
  local function tile(pos) return math.floor(pos.x or pos[1]),math.floor(pos.y or pos[2]) end
  local function centre(x,y) return {x=x+0.5,y=y+0.5} end
  local function label(e) return e.type=='entity-ghost' and e.ghost_name..'(ghost)' or e.name end
  local function toward(x,y,tx,ty)
    if x==tx then return ty<y and 0 or ty>y and 8 or nil end
    if y==ty then return tx>x and 4 or 12 end
  end
  local function each_tile(b,fn)
    for y=math.floor(b.left_top.y),math.ceil(b.right_bottom.y)-1 do
      for x=math.floor(b.left_top.x),math.ceil(b.right_bottom.x)-1 do fn(x,y) end
    end
  end

  -- Fluidbox prototypes with pipe connections, including a fluid energy source's.
  local function boxes(proto)
    local ok,list=pcall(function() return proto.fluidbox_prototypes end)
    local out={}
    for _,b in ipairs(ok and list or {}) do out[#out+1]=b end
    local has,source=pcall(function() return proto.fluid_energy_source_prototype end)
    local box=has and source and source.fluid_box
    if box and not (box.index and out[box.index]) then out[#out+1]=box end
    return out
  end
  local function volume(box)
    local ok,v=pcall(function() return box.volume end)
    if not (ok and v) then ok,v=pcall(function() return box.get_volume() end) end
    return ok and v or 0
  end

  -- World connections from the prototype, for ghosts as for built entities:
  -- one position per cardinal facing, the direction rotated with the entity,
  -- and a mirrored entity flipped across its facing axis.
  local function defined(e)
    local proto=e.type=='entity-ghost' and e.ghost_prototype or e.prototype
    local d=STEP[e.direction or 0] and e.direction or 0
    local ok,mirrored=pcall(function() return e.mirroring end)
    local out={}
    for i,box in ipairs(boxes(proto)) do
      local fluid=box.filter and box.filter.name
      for _,c in ipairs(box.pipe_connections or {}) do
        local kind=c.connection_type or 'normal'
        local cd=(c.direction+d)%16
        local rel=c.positions and c.positions[d/4+1] or c.position
        if kind~='linked' and STEP[cd] and rel then
          local rx,ry=rel.x or rel[1],rel.y or rel[2]
          if ok and mirrored then
            if d%8==0 then rx,cd=-rx,(16-cd)%16 else ry,cd=-ry,(24-cd)%16 end
          end
          local x,y=tile{x=e.position.x+rx,y=e.position.y+ry}
          out[#out+1]={box=i,flow=c.flow_direction or 'input-output',kind=kind,x=x,y=y,dir=cd,
            tx=x+STEP[cd][1],ty=y+STEP[cd][2],reach=c.max_underground_distance,fluid=fluid}
        end
      end
    end
    return out
  end
  -- What the engine reports for a built entity: positions, the fluid held
  -- and what each connection is joined to.
  local function engine(e)
    if e.type=='entity-ghost' then return nil end
    local ok,fb=pcall(function() return e.fluidbox end)
    if not ok or not fb then return nil end
    local out={}
    for i=1,#fb do
      local has,conns=pcall(fb.get_pipe_connections,i)
      local fluid=fb[i] and fb[i].name
      if not fluid then local okl,locked=pcall(fb.get_locked_fluid,i); fluid=okl and locked or nil end
      for _,c in ipairs(has and conns or {}) do
        local x,y=tile(c.position)
        local tx,ty=tile(c.target_position)
        local cd=toward(x,y,tx,ty)
        -- The target is a LuaFluidBox in 2.0 (a LuaEntity in later docs).
        local target=c.target
        if target and target.object_name=='LuaFluidBox' then target=target.owner end
        out[#out+1]={box=i,flow=c.flow_direction or 'input-output',kind=c.connection_type or 'normal',x=x,y=y,dir=cd,
          tx=tx,ty=ty,fluid=fluid,target=target}
      end
    end
    return out
  end
  -- Engine and prototype views together: the prototype adds reach, and
  -- connections a machine only opens for some recipes.
  function M.connections(e)
    local list,seen=engine(e) or {},{}
    for _,c in ipairs(list) do seen[c.kind..key(c.x,c.y)..','..tostring(c.dir)]=c end
    for _,c in ipairs(defined(e)) do
      local same=seen[c.kind..key(c.x,c.y)..','..c.dir]
      if same then same.reach=same.reach or c.reach else list[#list+1]=c end
    end
    return list
  end

  -- scan fields=fluids: per fluidbox "fluid amount/capacity" and its
  -- connections as "flow x,y=entity there", underground ones as "flow uS".
  local function round(v) return string.format('%g',math.floor(v*10+0.5)/10) end
  local function neighbour(e,c,ghosts_only)
    for _,o in pairs(e.surface.find_entities_filtered{position=centre(c.tx,c.ty),force=e.force,type=ghosts_only and 'entity-ghost' or nil}) do
      for _,oc in ipairs(M.connections(o)) do
        if oc.kind=='normal' and oc.x==c.tx and oc.y==c.ty and oc.tx==c.x and oc.ty==c.y then return label(o) end
      end
    end
  end
  function M.fluids(e)
    local ghost=e.type=='entity-ghost'
    local proto=ghost and e.ghost_prototype or e.prototype
    local conns=engine(e)
    local ok,fb=pcall(function() return e.fluidbox end)
    if ghost or not ok then fb=nil end
    local count=fb and #fb or #boxes(proto)
    if count==0 then return nil end
    local defs=boxes(proto)
    local parts={}
    for i=1,count do
      local fluid,amount,capacity,filter
      if not fb then
        fluid,amount,capacity=defs[i] and defs[i].filter and defs[i].filter.name,0,defs[i] and volume(defs[i]) or 0
      else
        local f=fb[i]
        local okc,cap=pcall(fb.get_capacity,i)
        fluid,amount,capacity=f and f.name,f and f.amount or 0,okc and cap or 0
        -- An empty box a recipe has fixed to one fluid says which.
        if not f then
          local okf,flt=pcall(fb.get_filter,i)
          filter=okf and flt and flt.name or nil
        end
      end
      local words={}
      for _,c in ipairs(conns or defined(e)) do
        if c.box==i then
          fluid=fluid or c.fluid
          local flow=FLOW[c.flow] or c.flow
          if c.kind=='underground' then
            local t=c.target
            words[#words+1]=flow..' u'..(LETTER[c.dir] or '')..(t and string.format(' %g,%g=%s',t.position.x,t.position.y,label(t)) or '')
          else
            local t=c.target and label(c.target) or neighbour(e,c,not ghost)
            words[#words+1]=string.format('%s %g,%g',flow,c.tx+0.5,c.ty+0.5)..(t and '='..t or '')
          end
        end
      end
      local head=fluid and fluid..' '..round(amount)..'/'..round(capacity) or 'empty'..(filter and ' ('..filter..' only)' or '')..'/'..round(capacity)
      -- Pipes and tanks share a segment: its extent, flagged past the limit.
      local sb=fb and M.segment_box(e,i)
      if sb then
        local limit=M.extent_limit()
        head=head..' extent '..M.span(sb)..(M.span(sb)>limit and ' > limit '..limit..': flow stops, add a pump' or '')
      end
      parts[#parts+1]=head..(#words>0 and ' '..table.concat(words,' ') or '')
    end
    return table.concat(parts,' | ')
  end
  -- Fluid segment extent. The engine stops all flow into a segment whose
  -- extent (the larger side, in tiles, of its bounding box) passes the limit
  -- (tested: 320 tiles flows, 321 freezes); a pump starts a new segment.
  local SEGMENT_TYPES={pipe=true,['pipe-to-ground']=true,['storage-tank']=true,['infinity-pipe']=true}
  function M.extent_limit()
    local ok,v=pcall(function() return prototypes.utility_constants.default_pipeline_extent end)
    return ok and type(v)=='number' and v or 320
  end
  -- {left,top,right,bottom} in tile coordinates, inclusive.
  local function tile_box(bb)
    return {math.floor(bb.left_top.x),math.floor(bb.left_top.y),math.floor(bb.right_bottom.x),math.floor(bb.right_bottom.y)}
  end
  local function span(b) return math.max(b[3]-b[1]+1,b[4]-b[2]+1) end
  M.span=span
  function M.segment_box(e,i)
    if not (e and e.valid and SEGMENT_TYPES[e.type]) then return nil end
    local ok,bb=pcall(function() return e.fluidbox.get_fluid_segment_extent_bounding_box(i or 1) end)
    return ok and bb and tile_box(bb) or nil
  end
  local function grow(b,x,y)
    if not b then return {x,y,x,y} end
    return {math.min(b[1],x),math.min(b[2],y),math.max(b[3],x),math.max(b[4],y)}
  end
  local function union(a,b)
    if not a then return b and {b[1],b[2],b[3],b[4]} end
    if not b then return {a[1],a[2],a[3],a[4]} end
    return {math.min(a[1],b[1]),math.min(a[2],b[2]),math.max(a[3],b[3]),math.max(a[4],b[4])}
  end
  -- The segment an ordered route makes with the segments it joins at its
  -- ends, and pumps cutting it into parts within the limit. A pump takes two
  -- plain pipe tiles in a straight run with plain pipe on the same line
  -- before and after it, and faces the flow (from -> to).
  function M.pump_plan(entities,from_box,to_box,limit)
    local n=#entities
    local tiles={}
    for i,e in ipairs(entities) do local x,y=tile(e.position); tiles[i]={x=x,y=y,plain=e.direction==nil} end
    local total=union(from_box,to_box)
    for _,t in ipairs(tiles) do total=grow(total,t.x,t.y) end
    local out={extent=total and span(total) or 0,limit=limit}
    if out.extent<=limit then return out end
    local function spot(k) -- pump on tiles k,k+1
      local a,b,c,d=tiles[k-1],tiles[k],tiles[k+1],tiles[k+2]
      if not (a and b and c and d and a.plain and b.plain and c.plain and d.plain) then return false end
      local dx,dy=b.x-a.x,b.y-a.y
      return math.abs(dx)+math.abs(dy)==1 and c.x-b.x==dx and c.y-b.y==dy and d.x-c.x==dx and d.y-c.y==dy
    end
    out.pumps={}
    local cur,start,best=from_box and union(from_box,nil) or nil,1,nil
    local i=1
    while i<=n do
      local test=grow(cur,tiles[i].x,tiles[i].y)
      if i==n then test=union(test,to_box) end
      if span(test)>limit then
        if not best then out.unsplittable=string.format('no straight run of 4 plain pipes to hold a pump between tiles %d and %d of the route',start,i); return out end
        local a,b=tiles[best],tiles[best+1]
        out.pumps[#out.pumps+1]={position={x=(a.x+b.x)/2+0.5,y=(a.y+b.y)/2+0.5},direction=NAME[b.x>a.x and 4 or b.x<a.x and 12 or b.y>a.y and 8 or 0],tiles={best,best+1}}
        start=best+2; cur=nil; best=nil
        for k=start,i-1 do cur=grow(cur,tiles[k].x,tiles[k].y) end
      else
        cur=test
        if i-1>=start and spot(i-1) then best=i-1 end
        i=i+1
      end
    end
    return out
  end
  -- Every segment of ours over the limit on this surface (at most `limit`).
  function M.overlong(p,max)
    local limit,seen,out=M.extent_limit(),{},{}
    for _,e in pairs(p.surface.find_entities_filtered{type={'pipe','pipe-to-ground','storage-tank'},force=p.force}) do
      local ok,id=pcall(function() return e.fluidbox.get_fluid_segment_id(1) end)
      if ok and id and not seen[id] then
        seen[id]=true
        local b=M.segment_box(e,1)
        if b and span(b)>limit then
          local f=e.fluidbox[1]
          out[#out+1]={extent=span(b),box=b,fluid=f and f.name,at=e.position}
          if #out>=(max or 4) then break end
        end
      end
    end
    return out,limit
  end
  -- Entity summaries of pumps and underground pipes show their ends the way
  -- inserters show pickup and drop.
  function M.hint(e,out)
    for _,c in ipairs(engine(e) or defined(e)) do
      if c.kind=='underground' then
        if c.target then out.paired_with=c.target.position else out.unpaired=true end
      elseif c.kind=='normal' then
        local pos=centre(c.tx,c.ty)
        if c.flow=='input' then out.input=pos elseif c.flow=='output' then out.output=pos else out.opens=pos end
      end
    end
  end

  -- Every entity name with pipe connections, collected once.
  local fluid_names
  local function names()
    if not fluid_names then
      fluid_names={}
      for name,proto in pairs(prototypes.entity) do
        for _,box in ipairs(boxes(proto)) do
          if #(box.pipe_connections or {})>0 then fluid_names[#fluid_names+1]=name; break end
        end
      end
    end
    return fluid_names
  end
  -- Our fluid entities and ghosts around the search box: the tiles each
  -- occupies, the tiles its connections point at, and underground reach.
  local function survey(p,box)
    local s={occupant={},targets={},spanned={},ghosts={}}
    local area={left_top={x=box.left-PAD,y=box.top-PAD},right_bottom={x=box.right+1+PAD,y=box.bottom+1+PAD}}
    local list=names()
    local found={}
    if #list>0 then
      for _,filter in ipairs{{name=list},{ghost_name=list}} do
        filter.area,filter.force=area,p.force
        for _,e in pairs(p.surface.find_entities_filtered(filter)) do if e.valid then found[#found+1]=e end end
      end
    end
    -- Any ghost holds its tiles: a pipe ghost there would replace it.
    for _,g in pairs(p.surface.find_entities_filtered{area=area,type='entity-ghost',force=p.force}) do
      if g.valid then each_tile(g.bounding_box,function(x,y) s.ghosts[key(x,y)]=true end) end
    end
    local unders,at={},{}
    for _,e in ipairs(found) do
      local entry={name=label(e),position=e.position,conns=M.connections(e)}
      each_tile(e.bounding_box,function(x,y) s.occupant[key(x,y)]=entry end)
      for _,c in ipairs(entry.conns) do
        if c.kind=='normal' and c.dir then
          local k=key(c.tx,c.ty)
          s.targets[k]=s.targets[k] or {}
          table.insert(s.targets[k],{entry=entry,conn=c})
        elseif c.kind=='underground' and c.dir then
          unders[#unders+1]=c; at[key(c.x,c.y)]=at[key(c.x,c.y)] or {}
          table.insert(at[key(c.x,c.y)],c)
        end
      end
    end
    -- An underground end reaches along its axis to its partner (the nearest
    -- end facing back) or, unpaired, its full distance; one of ours on those
    -- tiles and that axis could pair with it.
    for _,u in ipairs(unders) do
      local st,reach=STEP[u.dir],u.reach or PAD
      local stop=reach
      for k=1,reach do
        local paired=false
        for _,o in ipairs(at[key(u.x+st[1]*k,u.y+st[2]*k)] or {}) do paired=paired or o.dir==opposite(u.dir) end
        if paired then stop=k; break end
      end
      for k=0,stop do s.spanned[axis(u.dir)..key(u.x+st[1]*k,u.y+st[2]*k)]=true end
    end
    return s
  end

  local function kinds(name,undergrounds)
    local pipe=prototypes.entity[name]
    assert(pipe and pipe.type=='pipe','pipe must be a pipe entity')
    local under=undergrounds and prototypes.entity[name..'-to-ground']
    if not (under and under.type=='pipe-to-ground') then return pipe end
    -- Its open side and reach come from its fluid box, facing north.
    local open,down,reach
    for _,box in ipairs(boxes(under)) do
      for _,c in ipairs(box.pipe_connections or {}) do
        if (c.connection_type or 'normal')=='normal' then open=c.direction
        elseif c.connection_type=='underground' then down,reach=c.direction,c.max_underground_distance end
      end
    end
    if not reach then local ok,r=pcall(function() return under.max_underground_distance end); reach=ok and r or nil end
    assert(open and down==opposite(open) and reach and reach>0,under.name..' has no straight underground connection')
    return pipe,{name=under.name,open=open,reach=reach}
  end

  function M.plan(p,a)
    local pipe,under=kinds(a.pipe or 'pipe',a.undergrounds~=false)
    local fx,fy=tile(api.position(a.from))
    local tx,ty=tile(api.position(a.to))
    assert(math.abs(tx-fx)+math.abs(ty-fy)<=MAX_SPAN,'from and to must be within '..MAX_SPAN..' tiles (manhattan); give waypoints')
    assert(fx~=tx or fy~=ty,'from and to are the same tile')
    local box={left=math.min(fx,tx)-MARGIN,top=math.min(fy,ty)-MARGIN,right=math.max(fx,tx)+MARGIN,bottom=math.max(fy,ty)+MARGIN}
    local s=survey(p,box)

    local charted,free={},{}
    local function passable(x,y)
      if x<box.left or x>box.right or y<box.top or y>box.bottom then return false end
      local k=key(x,y)
      if free[k]==nil then
        local pos=centre(x,y)
        local c=api.chunk_of(pos)
        local ck=key(c.x,c.y)
        if charted[ck]==nil then charted[ck]=p.force.is_chunk_charted(p.surface,c) end
        free[k]=charted[ck] and not s.occupant[k] and not s.ghosts[k] and p.surface.can_place_entity{name=pipe.name,position=pos,direction=0,
          force=p.force,build_check_type=defines.build_check_type.manual_ghost} or false
      end
      return free[k]
    end
    -- A plain pipe may go where every connection aimed at the tile belongs
    -- to an entity it is meant to join.
    local function only(x,y,j1,j2)
      for _,t in ipairs(s.targets[key(x,y)] or {}) do
        if t.entry~=j1 and t.entry~=j2 then return false end
      end
      return true
    end
    local function fluid_of(entry)
      for _,c in ipairs(entry.conns) do if c.fluid then return c.fluid end end
    end
    -- An end is a free tile (joining the one entity whose connection points
    -- at it, if any) or an existing pipe-like entity, joined at any free
    -- connection tile of its own. `toward` points from the tile to the join.
    local function ends(label_,x,y)
      local here=s.occupant[key(x,y)]
      if here then
        local normal,box_seen,oneway,single=0,nil,false,true
        for _,c in ipairs(here.conns) do
          if c.kind=='normal' then normal=normal+1 end
          if c.flow~='input-output' then oneway=true end
          if box_seen and box_seen~=c.box then single=false end
          box_seen=c.box
        end
        assert(normal==1 or single and not oneway,label_..' holds '..here.name..' with several or one-way fluid connections; give the free tile at the one to join (scan fields=fluids lists them)')
        local list={}
        for _,c in ipairs(here.conns) do
          if c.kind=='normal' and c.dir and passable(c.tx,c.ty) and only(c.tx,c.ty,here) then
            list[#list+1]={x=c.tx,y=c.ty,toward=opposite(c.dir),join=here,fluid=fluid_of(here)}
          end
        end
        assert(#list>0,label_..' holds '..here.name..' but no tile at its connections is free of other connections')
        return list
      end
      assert(passable(x,y),label_..' is blocked or not charted')
      local join,toward,fluid
      for _,t in ipairs(s.targets[key(x,y)] or {}) do
        assert(not join or join==t.entry,label_..' is where both '..(join and join.name or '')..' and '..t.entry.name..' connect; a pipe there would join them')
        join,toward,fluid=t.entry,opposite(t.conn.dir),fluid or t.conn.fluid
      end
      return {{x=x,y=y,toward=toward,join=join,fluid=fluid}}
    end
    local starts=ends('from',fx,fy)
    local goals,goal_list={},ends('to',tx,ty)
    for _,g in ipairs(goal_list) do goals[key(g.x,g.y)]=g end
    local ff,tf=starts[1].fluid,goal_list[1].fluid
    assert(not (ff and tf and ff~=tf),'from carries '..tostring(ff)..' but to carries '..tostring(tf)..'; the route would mix them')

    -- A hop may not cross a tile where a foreign underground reaches on its
    -- axis, nor pass beneath lava or space (Space Age).
    local solid={}
    local function clear(x,y,d,k)
      x,y=x+STEP[d][1]*k,y+STEP[d][2]*k
      local tk=key(x,y)
      if solid[tk]==nil then
        local ok,layers=pcall(function() return p.surface.get_tile(x,y).prototype.collision_mask.layers end)
        solid[tk]=not (ok and layers and (layers.lava_tile or layers.empty_space))
      end
      return solid[tk] and not s.spanned[axis(d)..tk]
    end
    -- Distance plus the last pipe, plus a turn unless a goal lies straight
    -- ahead: tight enough that open ground does not expand as a rectangle.
    local function h(x,y,din)
      local best=math.huge
      for _,g in ipairs(goal_list) do
        local dx,dy=g.x-x,g.y-y
        local ahead=din<0 or dx==0 and dy==0 or dx*STEP[din][1]>=0 and dy*STEP[din][2]>=0 and (dx==0 or dy==0)
        best=math.min(best,math.abs(dx)+math.abs(dy)+1+(ahead and 0 or TURN_COST))
      end
      return best
    end
    -- States carry a direction, so a path could come back over its own
    -- tiles to turn a hop; such paths are dropped.
    local function used(n,x,y)
      while n do
        for _,st in ipairs(n.place or {}) do if st.x==x and st.y==y then return true end end
        n=n.parent
      end
      return false
    end
    -- Checked once per popped node: its tile and what its step placed.
    local function overlaps(node)
      for _,st in ipairs(node.place or {}) do if used(node.parent,st.x,st.y) then return true end end
      return not node.done and used(node,node.x,node.y)
    end
    local open,best,expansions={},{},0
    for _,st in ipairs(starts) do
      heap.push(open,{x=st.x,y=st.y,din=st.join and opposite(st.toward) or -1,allow=st.join,start=st,g=0,f=h(st.x,st.y,st.join and opposite(st.toward) or -1)})
    end
    local goal
    while #open>0 do
      local node=heap.pop(open)
      local sk=not node.done and node.x..','..node.y..','..node.din
      if overlaps(node) then
        if sk and best[sk]==node.g then best[sk]=nil end
      elseif node.done then goal=node; break
      elseif not best[sk] or node.g<=best[sk] then
        best[sk]=-1 -- closed
        expansions=expansions+1
        if expansions>MAX_EXPANSIONS then break end
        local function relax(x,y,din,g,place)
          local k=x..','..y..','..din
          if best[k] and (best[k]<0 or best[k]<=g) then return end
          best[k]=g
          heap.push(open,{x=x,y=y,din=din,g=g,f=g+h(x,y,din),parent=node,place=place})
        end
        local function finish(g,place,at) heap.push(open,{done=true,g=g,f=g,parent=node,place=place,goal=at}) end
        local here=goals[key(node.x,node.y)]
        if here then
          -- The last pipe joins the route to the end's entity, if any.
          if only(node.x,node.y,node.allow,here.join) then finish(node.g+1,{{kind='pipe',x=node.x,y=node.y}},here) end
        else
          if only(node.x,node.y,node.allow) then
            for _,d in ipairs(DIRS) do
              if node.din<0 or d~=opposite(node.din) then
                local nx,ny=node.x+STEP[d][1],node.y+STEP[d][2]
                if passable(nx,ny) then relax(nx,ny,d,node.g+1+((node.din>=0 and d~=node.din) and TURN_COST or 0),{{kind='pipe',x=node.x,y=node.y}}) end
              end
            end
          end
          -- A pipe-to-ground pair: open toward where the line came from,
          -- surfacing k tiles on, open onward. A free end stays plain pipe,
          -- open to whatever connects there later.
          if under and (node.din>=0) then
            for _,d in ipairs(DIRS) do
              if d==node.din and clear(node.x,node.y,d,0) then
                for k=1,under.reach do
                  if not clear(node.x,node.y,d,k) then break end
                  local ex,ey=node.x+STEP[d][1]*k,node.y+STEP[d][2]*k
                  if passable(ex,ey) then
                    local hop={{kind='entry',x=node.x,y=node.y,dir=d},{kind='exit',x=ex,y=ey,dir=d}}
                    local g=node.g+k+1+UNDERGROUND_COST
                    local at=goals[key(ex,ey)]
                    if at then
                      if at.toward==d then finish(g,hop,at) end
                    elseif passable(ex+STEP[d][1],ey+STEP[d][2]) then relax(ex+STEP[d][1],ey+STEP[d][2],d,g,hop) end
                  end
                end
              end
            end
          end
        end
      end
    end
    assert(goal,expansions>MAX_EXPANSIONS and 'no route found within the search budget; give a nearer waypoint'
      or 'no route: blocked, uncharted, or boxed in by foreign fluid connections (search spans '..MARGIN..' tiles around from and to)')

    -- Walk back to the start, then describe.
    local steps,first={},goal
    local n=goal
    while n do
      if n.place then for i=#n.place,1,-1 do table.insert(steps,1,n.place[i]) end end
      first=n; n=n.parent
    end
    local function heading(i)
      local s1,s2=steps[i],steps[i+1]
      if not s2 then s1,s2=steps[i-1],steps[i] end
      if not s1 then return goal.goal.toward or first.start.toward and opposite(first.start.toward) or 4 end
      local dx,dy=s2.x-s1.x,s2.y-s1.y
      return dx>0 and 4 or dx<0 and 12 or dy>0 and 8 or 0
    end
    -- A hop over another of this route's hops on the same line would pair wrongly.
    for i,a1 in ipairs(steps) do
      if a1.kind=='entry' then
        for j,a2 in ipairs(steps) do
          if j>i and a2.kind=='entry' and axis(a1.dir)==axis(a2.dir) then
            local b1,b2=steps[i+1],steps[j+1]
            local line=axis(a1.dir)=='v' and a1.x==a2.x or axis(a1.dir)=='h' and a1.y==a2.y
            local lo1,hi1=math.min(a1.x+a1.y,b1.x+b1.y),math.max(a1.x+a1.y,b1.x+b1.y)
            local lo2,hi2=math.min(a2.x+a2.y,b2.x+b2.y),math.max(a2.x+a2.y,b2.x+b2.y)
            assert(not (line and lo1<=hi2 and lo2<=hi1),'the route would hop over its own underground pipe; route in two legs via a waypoint')
          end
        end
      end
    end
    local entities,words,pipes_,pairs_={},{},0,0
    local last_word
    for i,st in ipairs(steps) do
      if st.kind=='pipe' then
        pipes_=pipes_+1
        entities[i]={name=pipe.name,position=centre(st.x,st.y)}
        local letter=LETTER[heading(i)]
        if last_word and last_word.letter==letter then last_word.n=last_word.n+1
        else last_word={letter=letter,n=1}; words[#words+1]=last_word end
      else
        local side=st.kind=='entry' and opposite(st.dir) or st.dir
        entities[i]={name=under.name,position=centre(st.x,st.y),direction=NAME[(side-under.open)%16]}
        if st.kind=='entry' then
          pairs_=pairs_+1
          local exit=steps[i+1]
          words[#words+1]={text='u'..LETTER[st.dir]..(math.abs(exit.x-st.x)+math.abs(exit.y-st.y))}
          last_word=nil
        end
      end
    end
    local text={}
    for _,w in ipairs(words) do text[#text+1]=w.text or (w.letter..w.n) end
    local items={[pipe.name]=pipes_>0 and pipes_ or nil}
    if pairs_>0 then items[under.name]=pairs_*2 end
    local joins
    for side,e in pairs{from=first.start,to=goal.goal} do
      if e.join then joins=joins or {}; joins[side]={name=e.join.name,position=e.join.position,fluid=e.fluid} end
    end
    return {route=table.concat(text,' '),tiles=#steps,pipes=pipes_,undergrounds=pairs_,items=items,entities=entities,joins=joins}
  end
  return M
end
