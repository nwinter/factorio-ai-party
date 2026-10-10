-- Belt routing: the cheapest belt line from one tile to another around
-- obstacles, hopping them with underground pairs, and arriving either on an
-- empty tile or into an existing belt straight, as a curve, or by side-load
-- onto a chosen lane. Plans only; the caller places the result as ghosts.
local heap=require('heap')
return function(api)
  local M={}
  local DIRS={0,4,8,12}
  local STEP={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  local NAME={[0]='north',[4]='east',[8]='south',[12]='west'}
  local LETTER={[0]='N',[4]='E',[8]='S',[12]='W'}
  local BELT_TYPES={'transport-belt','underground-belt','splitter','loader','loader-1x1','lane-splitter','linked-belt'}
  local MARGIN,MAX_SPAN,MAX_EXPANSIONS=16,200,60000
  -- Costs in belt tiles: turns are slightly dearer than straights, and an
  -- underground pair only wins where it saves real detours.
  local TURN_COST,UNDERGROUND_COST=0.5,3
  local function opposite(d) return (d+8)%16 end
  local function cw(d) return (d+4)%16 end
  local function ccw(d) return (d+12)%16 end
  local function key(x,y) return x..','..y end
  local function tile(pos) return math.floor(pos.x),math.floor(pos.y) end
  local function centre(x,y) return {x=x+0.5,y=y+0.5} end

  -- Our belt-like entities and ghosts: which tiles each outputs into, and
  -- which undergrounds sit where (a hop must not pass over one on its axis).
  local function belt_type(e) return e.type=='entity-ghost' and e.ghost_type or e.type end
  local function belt_name(e) return e.type=='entity-ghost' and e.ghost_name or e.name end
  local function underground_kind(e)
    local ok,kind=pcall(function() return e.belt_to_ground_type end)
    return ok and kind or nil
  end
  local function outputs(e)
    local kind,d=belt_type(e),e.direction
    local x,y=e.position.x,e.position.y
    local s=STEP[d]
    if not s then return {} end
    if kind=='splitter' then
      local side=STEP[cw(d)]
      return {{math.floor(x-side[1]*0.5+s[1]),math.floor(y-side[2]*0.5+s[2])},{math.floor(x+side[1]*0.5+s[1]),math.floor(y+side[2]*0.5+s[2])}}
    end
    -- An underground entrance outputs below ground; an unknown kind is
    -- treated as an exit so the route keeps clear of it.
    if kind=='underground-belt' and underground_kind(e)=='input' then return {} end
    if kind=='linked-belt' then return {} end
    return {{math.floor(x+s[1]),math.floor(y+s[2])}}
  end
  local function survey(p,box)
    local feeds,at,undergrounds={},{},{}
    local area={left_top={x=box.left,y=box.top},right_bottom={x=box.right+1,y=box.bottom+1}}
    local found={}
    for _,e in pairs(p.surface.find_entities_filtered{area=area,type=BELT_TYPES,force=p.force}) do found[#found+1]=e end
    for _,e in pairs(p.surface.find_entities_filtered{area=area,ghost_type=BELT_TYPES,force=p.force}) do found[#found+1]=e end
    for _,e in ipairs(found) do
      if e.valid then
        local x,y=tile(e.position)
        if belt_type(e)~='splitter' then at[key(x,y)]=e end
        for _,t in ipairs(outputs(e)) do
          local k=key(t[1],t[2])
          feeds[k]=feeds[k] or {}
          table.insert(feeds[k],{x=x,y=y,direction=e.direction,entity=e})
        end
        if belt_type(e)=='underground-belt' then undergrounds[key(x,y)]={name=belt_name(e),direction=e.direction} end
      end
    end
    return feeds,at,undergrounds
  end

  local function tier(name)
    local belt=prototypes.entity[name]
    assert(belt and belt.type=='transport-belt','belt must be a transport belt entity')
    local ok,related=pcall(function() return belt.related_underground_belt end)
    local underground=ok and related or nil
    if not underground then
      local guess=prototypes.entity[(name:gsub('transport%-belt','underground-belt'))]
      underground=guess and guess.type=='underground-belt' and guess or nil
    end
    return belt,underground
  end

  -- How a feed moving `d_in` into the target belt `e` arrives.
  local function arrival(e,d_in,feeds)
    local t=e.direction
    if d_in==t then return {mode='straight'} end
    local x,y=tile(e.position)
    local behind,other=false,false
    for _,f in ipairs(feeds[key(x,y)] or {}) do
      if f.direction==t and f.x==x-STEP[t][1] and f.y==y-STEP[t][2] then behind=true end
      if f.direction==opposite(d_in) then other=true end
    end
    -- A lone side input turns the target into a curve instead.
    if not behind and not other then return {mode='curve'} end
    return {mode='side_load',lane=d_in==cw(t) and 'left' or 'right'}
  end

  function M.plan(p,a)
    local belt,underground=tier(a.belt or 'transport-belt')
    if a.undergrounds==false then underground=nil end
    local reach=underground and underground.max_underground_distance or 0
    local fx,fy=tile(api.position(a.from))
    local tx,ty=tile(api.position(a.to))
    assert(math.abs(tx-fx)+math.abs(ty-fy)<=MAX_SPAN,'from and to must be within '..MAX_SPAN..' tiles (manhattan)')
    assert(a.lane==nil or a.lane=='left' or a.lane=='right','lane must be left or right')
    local to_direction=a.to_direction and api.directions[a.to_direction]
    assert(a.to_direction==nil or STEP[to_direction or -1],'to_direction must be north, east, south or west')
    local box={left=math.min(fx,tx)-MARGIN,top=math.min(fy,ty)-MARGIN,right=math.max(fx,tx)+MARGIN,bottom=math.max(fy,ty)+MARGIN}
    local feeds,at,undergrounds=survey(p,box)

    -- The start: a free tile, or the tile an existing belt end outputs into.
    local start_din,extends=-1,nil
    local first=at[key(fx,fy)]
    if first then
      local kind=belt_type(first)
      assert(kind=='transport-belt' or kind=='underground-belt' and underground_kind(first)~='input','from holds a belt that cannot be extended; start on a free tile or a belt end')
      extends={x=first.position.x,y=first.position.y}
      start_din=first.direction
      fx,fy=fx+STEP[start_din][1],fy+STEP[start_din][2]
    end

    -- The goal: an empty `to` gets the last belt; an existing belt at `to`
    -- is fed from a neighbour, straight or from a side.
    local target=at[key(tx,ty)]
    local allowed
    if target then
      local kind=belt_type(target)
      local t=target.direction
      if kind=='transport-belt' or kind=='lane-splitter' then
        allowed={[t]=true,[cw(t)]=true,[ccw(t)]=true}
        if a.lane then
          local d=a.lane=='left' and cw(t) or ccw(t)
          allowed={[d]=true}
          assert(arrival(target,d,feeds).mode=='side_load','to has no input from behind: a side feed would turn it into a curve, not load one lane')
        end
      elseif kind=='underground-belt' and underground_kind(target)=='input' then
        assert(not a.lane,'lane needs a plain belt at to')
        allowed={[t]=true}
      else error('to holds '..belt_name(target)..'; it can be fed only at a plain belt or an underground entrance') end
    else
      assert(not a.lane,'lane needs an existing belt at to')
    end

    local charted,free={},{}
    local function passable(x,y,is_start)
      if x<box.left or x>box.right or y<box.top or y>box.bottom then return false end
      local k=key(x,y)
      if feeds[k] and not is_start then return false end
      -- can_place_entity accepts a belt over one of ours (a rotate or
      -- fast-replace), but that ghost is never built: the tile is taken.
      if at[k] then return false end
      if free[k]==nil then
        local pos=centre(x,y)
        local c=api.chunk_of(pos)
        local ck=key(c.x,c.y)
        if charted[ck]==nil then charted[ck]=p.force.is_chunk_charted(p.surface,c) end
        free[k]=charted[ck] and p.surface.can_place_entity{name=belt.name,position=pos,direction=0,force=p.force,
          build_check_type=defines.build_check_type.manual_ghost} or false
      end
      return free[k]
    end
    assert(passable(fx,fy,true),'the start tile is blocked or not charted')
    if not target then
      assert(fx~=tx or fy~=ty,'from and to are the same tile')
      assert(passable(tx,ty),'to is blocked, not charted, or fed by another belt')
    else
      -- The last belt stands on a neighbour of `to`; say which if none can.
      local closed={}
      for d in pairs(allowed) do
        local ax,ay=tx-STEP[d][1],ty-STEP[d][2]
        if (ax==fx and ay==fy) or passable(ax,ay) then closed=nil; break end
        local c=centre(ax,ay)
        closed[#closed+1]=string.format('%g,%g %s',c.x,c.y,feeds[key(ax,ay)] and 'is fed by another belt' or 'is blocked or not charted')
      end
      assert(not closed,closed and 'no way into to: '..table.concat(closed,'; '))
    end
    -- A hop may not pass over an underground of the same kind on its axis:
    -- that one would pair with our entrance instead.
    local function hop_clear(x,y,d,k)
      for i=1,k-1 do
        local u=undergrounds[key(x+STEP[d][1]*i,y+STEP[d][2]*i)]
        if u and u.name==underground.name and (u.direction==d or u.direction==opposite(d)) then return false end
      end
      return true
    end

    local function h(x,y) return math.abs(x-tx)+math.abs(y-ty) end
    local open,best,expansions={},{},0
    heap.push(open,{x=fx,y=fy,din=start_din,g=0,f=h(fx,fy)})
    local goal
    while #open>0 do
      local node=heap.pop(open)
      if node.goal then goal=node; break end
      local sk=node.x..','..node.y..','..node.din
      if not best[sk] or node.g<=best[sk] then
        best[sk]=-1 -- closed
        expansions=expansions+1
        if expansions>MAX_EXPANSIONS then break end
        if not target and node.x==tx and node.y==ty then
          local d=to_direction or (node.din>=0 and node.din or 4)
          goal={parent=node,place={{kind='belt',x=tx,y=ty,direction=d}}}
          break
        end
        local function relax(x,y,din,g,place,is_goal)
          local k=x..','..y..','..din
          if is_goal then heap.push(open,{goal=true,parent=node,place=place,g=g,f=g,din=din}); return end
          if best[k] and (best[k]<0 or best[k]<=g) then return end
          best[k]=g
          heap.push(open,{x=x,y=y,din=din,g=g,f=g+h(x,y),parent=node,place=place})
        end
        for _,d in ipairs(DIRS) do
          if node.din<0 or d~=opposite(node.din) then
            -- A belt here pointing d.
            local nx,ny=node.x+STEP[d][1],node.y+STEP[d][2]
            local g=node.g+1+((node.din>=0 and d~=node.din) and TURN_COST or 0)
            local place={{kind='belt',x=node.x,y=node.y,direction=d}}
            if target and nx==tx and ny==ty then
              if allowed[d] then relax(nx,ny,d,g,place,true) end
            elseif passable(nx,ny) then relax(nx,ny,d,g,place) end
            -- An underground pair: entered straight, exit k tiles on.
            if underground and (node.din<0 or d==node.din) then
              for k=2,reach do
                local ex,ey=node.x+STEP[d][1]*k,node.y+STEP[d][2]*k
                if target and ex==tx and ey==ty then break end
                if not hop_clear(node.x,node.y,d,k) then break end
                if passable(ex,ey) and not (not target and ex==tx and ey==ty) then
                  local ox,oy=ex+STEP[d][1],ey+STEP[d][2]
                  local hop={{kind='input',x=node.x,y=node.y,direction=d},{kind='output',x=ex,y=ey,direction=d}}
                  local gg=node.g+k+1+UNDERGROUND_COST
                  if target and ox==tx and oy==ty then
                    if allowed[d] then relax(ox,oy,d,gg,hop,true) end
                  elseif passable(ox,oy) then relax(ox,oy,d,gg,hop) end
                end
              end
            end
          end
        end
      end
    end
    assert(goal,expansions>MAX_EXPANSIONS and 'no route found within the search budget; give a nearer waypoint'
      or 'no route: blocked, uncharted, or boxed in by belts feeding the way (search spans '..MARGIN..' tiles around from and to)')

    -- Walk back to the start, then describe.
    local steps={}
    local n=goal
    while n do
      if n.place then for i=#n.place,1,-1 do table.insert(steps,1,n.place[i]) end end
      n=n.parent
    end
    local entities,words,belts,pairs_={},{},0,0
    local last_word
    for i,s in ipairs(steps) do
      local name=s.kind=='belt' and belt.name or underground.name
      entities[i]={name=name,position=centre(s.x,s.y),direction=NAME[s.direction],type=s.kind~='belt' and s.kind or nil}
      if s.kind=='belt' then
        belts=belts+1
        local letter=LETTER[s.direction]
        if last_word and last_word.letter==letter then last_word.n=last_word.n+1
        else last_word={letter=letter,n=1}; words[#words+1]=last_word end
      elseif s.kind=='input' then
        pairs_=pairs_+1
        local exit=steps[i+1]
        words[#words+1]={text='u'..LETTER[s.direction]..(math.abs(exit.x-s.x)+math.abs(exit.y-s.y))}
        last_word=nil
      end
    end
    -- A hop over one of our own route's undergrounds on its axis would pair wrongly.
    for i,s in ipairs(steps) do
      if s.kind=='input' then
        local e=steps[i+1]
        for _,o in ipairs(steps) do
          if o~=s and o~=e and o.kind~='belt' and (o.direction==s.direction or o.direction==opposite(s.direction))
            and (s.x==e.x and o.x==s.x and (o.y-s.y)*(o.y-e.y)<0 or s.y==e.y and o.y==s.y and (o.x-s.x)*(o.x-e.x)<0) then
            error('the route would hop over its own underground; route in two legs via a waypoint')
          end
        end
      end
    end
    local text={}
    for _,w in ipairs(words) do text[#text+1]=w.text or (w.letter..w.n) end
    local items={[belt.name]=belts}
    if pairs_>0 then items[underground.name]=pairs_*2 end
    local out={route=table.concat(text,' '),tiles=#steps,belts=belts,undergrounds=pairs_,items=items,entities=entities,extends=extends}
    if target then
      out.arrival=arrival(target,goal.din,feeds)
      out.arrival.into={x=target.position.x,y=target.position.y}
    else
      out.arrival={mode='end',direction=NAME[steps[#steps].direction]}
    end
    return out
  end
  return M
end
