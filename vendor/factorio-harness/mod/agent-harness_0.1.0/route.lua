-- Belt routing: the cheapest belt line from one tile to another around
-- obstacles, hopping them with underground pairs, and arriving either on an
-- empty tile or into an existing belt straight, as a curve, or by side-load
-- onto a chosen lane. Plans only; the caller places the result as ghosts.
-- Long routes (Sol, operator 07:52: a 600-tile Gleba seed return planned by
-- hand): a weighted A* over tiles in a window of MARGIN tiles around each leg
-- (from, via points, to), up to MAX_LEG tiles a leg, within a budget of
-- placement checks. Trees, rocks and wild plants are passed over at a cost
-- (place_ghosts marks them, construct mines them); water and Gleba wetland
-- only with landfill=true (tile ghosts under the belts); cliffs and buildings
-- never. An underground pair hops anything but lava and empty space.
-- return=true lays a second line beside it, the other way.
local heap=require('heap')
return function(api)
  local M={}
  local DIRS={0,4,8,12}
  local STEP={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  local NAME={[0]='north',[4]='east',[8]='south',[12]='west'}
  local LETTER={[0]='N',[4]='E',[8]='S',[12]='W'}
  local BELT_TYPES={'transport-belt','underground-belt','splitter','loader','loader-1x1','lane-splitter','linked-belt'}
  local MARGIN,MAX_LEG,MAX_POINTS,MAX_CHECKS,MAX_EXPANSIONS=24,1000,16,40000,200000
  -- Costs in belt tiles: turns are slightly dearer than straights, an
  -- underground pair wins only where it saves real detours, a tree or plant
  -- to clear costs a little, a tile to landfill more; the return line pays to
  -- leave the side of the first; WEIGHT trades the shortest line for speed.
  M.TUNE={turn=0.5,underground=6,clear=1.5,fill=4,away=2,weight=1.5}
  local UNDER={lava_tile=true,empty_space=true}  -- tiles an underground cannot pass under (underpass.lua)
  local function opposite(d) return (d+8)%16 end
  local function cw(d) return (d+4)%16 end
  local function ccw(d) return (d+12)%16 end
  local function key(x,y) return x..','..y end
  local function tile(pos) return math.floor(pos.x),math.floor(pos.y) end
  local function centre(x,y) return {x=x+0.5,y=y+0.5} end
  local function fmt(x,y) return string.format('(%g,%g)',x+0.5,y+0.5) end

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
  -- Belts surveyed a chunk at a time, when a tile in it is first looked at
  -- (a long route crosses few chunks of a big base): a border tile wide, so a
  -- belt next door that outputs into the chunk is known.
  local function survey(p)
    local s={feeds={},at={},undergrounds={},seen={},done={}}
    local function add(e)
      local id=e.unit_number or (belt_name(e)..'@'..e.position.x..','..e.position.y)
      if s.seen[id] then return end
      s.seen[id]=true
      local x,y=tile(e.position)
      if belt_type(e)~='splitter' then s.at[key(x,y)]=e end
      for _,t in ipairs(outputs(e)) do
        local k=key(t[1],t[2])
        s.feeds[k]=s.feeds[k] or {}
        table.insert(s.feeds[k],{x=x,y=y,direction=e.direction,entity=e})
      end
      if belt_type(e)=='underground-belt' then s.undergrounds[key(x,y)]={name=belt_name(e),direction=e.direction} end
    end
    function s.ensure(x,y)
      local cx,cy=math.floor(x/32),math.floor(y/32)
      local k=cx..','..cy
      if s.done[k] then return end
      s.done[k]=true
      local area={left_top={x=cx*32-1,y=cy*32-1},right_bottom={x=cx*32+33,y=cy*32+33}}
      for _,e in pairs(p.surface.find_entities_filtered{area=area,type=BELT_TYPES,force=p.force}) do if e.valid then add(e) end end
      for _,e in pairs(p.surface.find_entities_filtered{area=area,ghost_type=BELT_TYPES,force=p.force}) do if e.valid then add(e) end end
    end
    return s
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

  -- The tiles a route may use, read once each: 'free'; 'clear' (only trees,
  -- rocks or wild plants in the way: a ghost goes over them and marks them);
  -- 'fill' (water or wetland a tile item makes buildable, with landfill=true;
  -- fills[k] says which item); false (blocked, outside the window, taken by
  -- or fed by one of our belts, uncharted). taken: tiles the route itself
  -- holds (the return line keeps off the first).
  local function tiles(p,a,belt,s,budget)
    local t={kinds={},fills={},taken={},fed={},charted={},budget=budget,box=nil}
    local stands=api.tiles and api.tiles.stands_fn(p.surface,belt) or function() return true end
    local fixes=api.tile_fixes
    local only_obstacles=api.only_obstacles
    local function charted(x,y)
      local c=api.chunk_of(centre(x,y))
      local ck=key(c.x,c.y)
      if t.charted[ck]==nil then t.charted[ck]=p.force.is_chunk_charted(p.surface,c) end
      return t.charted[ck]
    end
    t.is_charted=charted
    local function check(x,y,forced)
      budget.checks=budget.checks+1
      return p.surface.can_place_entity{name=belt.name,position=centre(x,y),direction=0,force=p.force,
        build_check_type=defines.build_check_type.manual_ghost,forced=forced or nil}
    end
    function t.kind(x,y,is_start)
      local b=t.box
      if b and (x<b.left or x>b.right or y<b.top or y>b.bottom) then return false end
      local k=key(x,y)
      if t.taken[k] or t.fed[k] then return false end
      s.ensure(x,y)
      if s.feeds[k] and not is_start then return false end
      -- can_place_entity accepts a belt over one of ours (a rotate or
      -- fast-replace), but that ghost is never built: the tile is taken.
      if s.at[k] then return false end
      local v=t.kinds[k]
      if v==nil then
        v=false
        if charted(x,y) then
          if check(x,y) and stands(x,y) then v='free'
          elseif fixes or only_obstacles then
            local pos=centre(x,y)
            if check(x,y,true) then
              local list=fixes and fixes(p.surface,p.force,belt,pos,0) or nil
              if list and #list>0 then
                local item
                for _,f in ipairs(list) do item=item or f.item; if not f.item then item=false; break end end
                if item and a.landfill then v='fill'; t.fills[k]=item end
              else v='clear' end
            elseif only_obstacles and only_obstacles(p.surface,belt,pos,0) then v='clear' end
          end
        end
        t.kinds[k]=v
      end
      return v
    end
    -- What an underground can not pass under, read by tile name once.
    local under={}
    function t.passes_under(x,y)
      local ok,tl=pcall(function() return p.surface.get_tile(x,y) end)
      local name=ok and tl and tl.name
      if not name then return true end
      if under[name]==nil then
        local okl,layers=pcall(function() return tl.prototype.collision_mask.layers end)
        local blocked=false
        for layer in pairs(okl and layers or {}) do if UNDER[layer] then blocked=true end end
        under[name]=not blocked
      end
      return under[name]
    end
    return t
  end

  -- One leg: from the start nodes to goal, a weighted A* inside box. goal:
  -- {x,y} reached at any heading (a via point), {target, allowed} (feeding an
  -- existing belt), or {x,y,last=true} (the free last tile). extra(x,y): an
  -- added cost per tile (the return line off the first's side).
  local function leg(ctx,starts,goal,box,extra)
    local t,s,underground,reach,TUNE=ctx.t,ctx.s,ctx.underground,ctx.reach,M.TUNE
    local budget=ctx.budget
    t.box=box
    local tx,ty=goal.x,goal.y
    local function h(x,y,din)
      local dx,dy=tx-x,ty-y
      local d=math.abs(dx)+math.abs(dy)
      if din>=0 then
        local sx,sy=STEP[din][1],STEP[din][2]
        -- a heading off the goal's axis, or away from it, needs a turn or two
        if (dx~=0 and dy~=0) or dx*sx+dy*sy<0 or (dx==0 and sx~=0) or (dy==0 and sy~=0) then d=d+TUNE.turn end
      end
      return d
    end
    local function cost(x,y)
      local v=t.kind(x,y)
      local c=v=='clear' and TUNE.clear or v=='fill' and TUNE.fill or 0
      return extra and c+extra(x,y) or c
    end
    -- A hop may not pass over an underground of the same kind on its axis
    -- (that one would pair with our entrance instead), nor over lava or space.
    local function hop_clear(x,y,d,k)
      for i=1,k-1 do
        local hx,hy=x+STEP[d][1]*i,y+STEP[d][2]*i
        s.ensure(hx,hy)
        local u=s.undergrounds[key(hx,hy)] or ctx.planned_under[key(hx,hy)]
        if u and u.name==underground.name and (u.direction==d or u.direction==opposite(d)) then return false end
        if not t.passes_under(hx,hy) then return false end
      end
      return true
    end
    local open,best,nearest={},{},nil
    for _,st in ipairs(starts) do
      heap.push(open,{x=st.x,y=st.y,din=st.din,g=st.g or 0,f=TUNE.weight*h(st.x,st.y,st.din),start=true})
    end
    local target,allowed=goal.target,goal.allowed
    while #open>0 do
      local node=heap.pop(open)
      if node.goal then return node end
      local sk=node.x..','..node.y..','..node.din
      if not best[sk] or node.g<=best[sk] then
        best[sk]=-1 -- closed
        budget.expansions=budget.expansions+1
        if budget.expansions>MAX_EXPANSIONS or budget.checks>MAX_CHECKS then ctx.nearest=nearest; return nil,'budget' end
        local hn=h(node.x,node.y,-1)
        if not nearest or hn<nearest.h then nearest={x=node.x,y=node.y,h=hn} end
        if not target and node.x==tx and node.y==ty and not node.start then
          if goal.last then
            local d=ctx.to_direction or (node.din>=0 and node.din or 4)
            return {parent=node,place={{kind='belt',x=tx,y=ty,direction=d}},din=d,incoming=node.din}
          end
          return node
        end
        local function relax(x,y,din,g,place,is_goal)
          local k=x..','..y..','..din
          if is_goal then heap.push(open,{goal=true,parent=node,place=place,g=g,f=g,din=din}); return end
          if best[k] and (best[k]<0 or best[k]<=g) then return end
          best[k]=g
          heap.push(open,{x=x,y=y,din=din,g=g,f=g+TUNE.weight*h(x,y,din),parent=node,place=place})
        end
        for _,d in ipairs(DIRS) do
          if node.din<0 or d~=opposite(node.din) then
            -- A belt here pointing d.
            local nx,ny=node.x+STEP[d][1],node.y+STEP[d][2]
            local g=node.g+1+((node.din>=0 and d~=node.din) and TUNE.turn or 0)
            local place={{kind='belt',x=node.x,y=node.y,direction=d}}
            if target and nx==tx and ny==ty then
              if allowed[d] then relax(nx,ny,d,g,place,true) end
            elseif t.kind(nx,ny) then relax(nx,ny,d,g+cost(nx,ny),place) end
            -- An underground pair: entered straight, exit k tiles on.
            if underground and (node.din<0 or d==node.din) then
              for k=2,reach do
                local ex,ey=node.x+STEP[d][1]*k,node.y+STEP[d][2]*k
                if target and ex==tx and ey==ty then break end
                if not hop_clear(node.x,node.y,d,k) then break end
                if t.kind(ex,ey) and not (not target and ex==tx and ey==ty) then
                  local ox,oy=ex+STEP[d][1],ey+STEP[d][2]
                  local hop={{kind='input',x=node.x,y=node.y,direction=d},{kind='output',x=ex,y=ey,direction=d}}
                  local gg=node.g+k+1+TUNE.underground+cost(ex,ey)
                  if target and ox==tx and oy==ty then
                    if allowed[d] then relax(ox,oy,d,gg,hop,true) end
                  elseif t.kind(ox,oy) then relax(ox,oy,d,gg+cost(ox,oy),hop) end
                end
              end
            end
          end
        end
      end
    end
    ctx.nearest=nearest
    return nil,'none'
  end

  -- What stands around (x,y) that a belt cannot go over, each kind once, for a failed search.
  local function blockers_near(p,x,y)
    local kinds,order={},{}
    local ok,list=pcall(function() return p.surface.find_entities_filtered{area={{x-3,y-3},{x+4,y+4}},limit=64} end)
    for _,e in ipairs(ok and list or {}) do
      if e.valid and e.type~='character' and e.type~='resource' and e.type~='entity-ghost' and e.type~='tile-ghost' and e.type~='item-entity' then
        if not kinds[e.name] then kinds[e.name]={at=e.position,n=0}; order[#order+1]=e.name end
        kinds[e.name].n=kinds[e.name].n+1
      end
    end
    local tl={}
    for dx=-2,2 do for dy=-2,2 do
      local okt,t=pcall(function() return p.surface.get_tile(x+dx,y+dy) end)
      local name=okt and t and t.name
      if name and not tl[name] then tl[name]=true; tl[#tl+1]=name end
    end end
    local names={}
    for i=1,math.min(6,#order) do
      local k=kinds[order[i]]
      names[i]=string.format('%s (%g,%g)%s',order[i],k.at.x,k.at.y,k.n>1 and ' and '..(k.n-1)..' more' or '')
    end
    return names,tl
  end

  -- The steps of a found leg, start to goal.
  local function walk_back(node)
    local steps={}
    local n=node
    while n do
      if n.place then for i=#n.place,1,-1 do table.insert(steps,1,n.place[i]) end end
      n=n.parent
    end
    return steps
  end
  -- Steps -> entities, the route text (E12 uE4 S3), counts.
  local function describe(steps,belt,underground,t,line)
    local entities,words,belts,pairs_,clear,fill={},{},0,0,0,{}
    local last_word
    for i,st in ipairs(steps) do
      local name=st.kind=='belt' and belt.name or underground.name
      entities[i]={name=name,position=centre(st.x,st.y),direction=NAME[st.direction],type=st.kind~='belt' and st.kind or nil,line=line}
      local k=key(st.x,st.y)
      if t.kinds[k]=='clear' then clear=clear+1 end
      if t.kinds[k]=='fill' then fill[t.fills[k]]=(fill[t.fills[k]] or 0)+1 end
      if st.kind=='belt' then
        belts=belts+1
        local letter=LETTER[st.direction]
        if last_word and last_word.letter==letter then last_word.n=last_word.n+1
        else last_word={letter=letter,n=1}; words[#words+1]=last_word end
      elseif st.kind=='input' then
        pairs_=pairs_+1
        local exit=steps[i+1]
        words[#words+1]={text='u'..LETTER[st.direction]..(math.abs(exit.x-st.x)+math.abs(exit.y-st.y))}
        last_word=nil
      end
    end
    -- A hop over one of the route's own undergrounds on its axis would pair wrongly.
    for i,st in ipairs(steps) do
      if st.kind=='input' then
        local e=steps[i+1]
        for _,o in ipairs(steps) do
          if o~=st and o~=e and o.kind~='belt' and (o.direction==st.direction or o.direction==opposite(st.direction))
            and (st.x==e.x and o.x==st.x and (o.y-st.y)*(o.y-e.y)<0 or st.y==e.y and o.y==st.y and (o.x-st.x)*(o.x-e.x)<0) then
            error('the route would hop over its own underground; route in two legs via a waypoint',0)
          end
        end
      end
    end
    local text={}
    for _,w in ipairs(words) do text[#text+1]=w.text or (w.letter..w.n) end
    return {entities=entities,route=table.concat(text,' '),tiles=#steps,belts=belts,undergrounds=pairs_,clear=clear,fill=fill}
  end

  function M.plan(p,a)
    local belt,underground=tier(a.belt or 'transport-belt')
    if a.undergrounds==false then underground=nil end
    local reach=underground and underground.max_underground_distance or 0
    assert(a.landfill==nil or type(a.landfill)=='boolean','landfill must be true or false')
    assert(a['return']==nil or type(a['return'])=='boolean','return must be true or false')
    assert(a.return_side==nil or a.return_side=='left' or a.return_side=='right','return_side must be left or right')
    local fx,fy=tile(api.position(a.from))
    local tx,ty=tile(api.position(a.to))
    -- The points in order: from, via points, to; each leg at most MAX_LEG tiles.
    local points={{x=fx,y=fy}}
    if a.via~=nil then
      assert(type(a.via)=='table' and #a.via>=1 and #a.via<=MAX_POINTS,'via is 1..'..MAX_POINTS..' {x,y} points passed in order')
      for _,v in ipairs(a.via) do local vx,vy=tile(api.position(v)); points[#points+1]={x=vx,y=vy} end
    end
    points[#points+1]={x=tx,y=ty}
    for i=2,#points do
      local d=math.abs(points[i].x-points[i-1].x)+math.abs(points[i].y-points[i-1].y)
      assert(d<=MAX_LEG,string.format('%s to %s is %d tiles; each leg (from, via points, to) is at most %d tiles (manhattan): add via points',
        fmt(points[i-1].x,points[i-1].y),fmt(points[i].x,points[i].y),d,MAX_LEG))
    end
    assert(a.lane==nil or a.lane=='left' or a.lane=='right','lane must be left or right')
    local to_direction=a.to_direction and api.directions[a.to_direction]
    assert(a.to_direction==nil or STEP[to_direction or -1],'to_direction must be north, east, south or west')
    local budget={checks=0,expansions=0}
    local s=survey(p)
    local t=tiles(p,a,belt,s,budget)
    local ctx={t=t,s=s,underground=underground,reach=reach,budget=budget,planned_under={},to_direction=to_direction}

    -- The start: a free tile, or the tile an existing belt end outputs into.
    local start_din,extends=-1,nil
    s.ensure(fx,fy)
    local first=s.at[key(fx,fy)]
    if first then
      local kind=belt_type(first)
      assert(kind=='transport-belt' or kind=='underground-belt' and underground_kind(first)~='input','from holds a belt that cannot be extended; start on a free tile or a belt end')
      extends={x=first.position.x,y=first.position.y}
      start_din=first.direction
      fx,fy=fx+STEP[start_din][1],fy+STEP[start_din][2]
      points[1]={x=fx,y=fy}
    end

    -- The goal: an empty `to` gets the last belt; an existing belt at `to`
    -- is fed from a neighbour, straight or from a side.
    s.ensure(tx,ty)
    local target=s.at[key(tx,ty)]
    local allowed
    if target then
      local kind=belt_type(target)
      local d=target.direction
      if kind=='transport-belt' or kind=='lane-splitter' then
        allowed={[d]=true,[cw(d)]=true,[ccw(d)]=true}
        if a.lane then
          local ld=a.lane=='left' and cw(d) or ccw(d)
          allowed={[ld]=true}
          assert(arrival(target,ld,s.feeds).mode=='side_load','to has no input from behind: a side feed would turn it into a curve, not load one lane')
        end
      elseif kind=='underground-belt' and underground_kind(target)=='input' then
        assert(not a.lane,'lane needs a plain belt at to')
        allowed={[d]=true}
      else error('to holds '..belt_name(target)..'; it can be fed only at a plain belt or an underground entrance') end
    else
      assert(not a.lane,'lane needs an existing belt at to')
    end

    local function window(ax,ay,bx,by) return {left=math.min(ax,bx)-MARGIN,top=math.min(ay,by)-MARGIN,right=math.max(ax,bx)+MARGIN,bottom=math.max(ay,by)+MARGIN} end
    t.box=window(fx,fy,fx,fy)
    if not t.kind(fx,fy,true) then
      error(t.is_charted(fx,fy) and 'the start tile is blocked'..(a.landfill and '' or ' (water or wetland: landfill=true lays tile ghosts under the belts)') or 'the start tile is not charted',0)
    end
    if not target then
      assert(fx~=tx or fy~=ty,'from and to are the same tile')
      t.box=window(tx,ty,tx,ty)
      assert(t.kind(tx,ty),'to is blocked, not charted, or fed by another belt')
    else
      -- The last belt stands on a neighbour of `to`; say which if none can.
      t.box=window(tx,ty,tx,ty)
      local closed={}
      for d in pairs(allowed) do
        local ax,ay=tx-STEP[d][1],ty-STEP[d][2]
        if (ax==fx and ay==fy) or t.kind(ax,ay) then closed=nil; break end
        local c=centre(ax,ay)
        closed[#closed+1]=string.format('%g,%g %s',c.x,c.y,s.feeds[key(ax,ay)] and 'is fed by another belt' or 'is blocked or not charted')
      end
      assert(not closed,closed and 'no way into to: '..table.concat(closed,'; '))
    end
    -- Via points must take a belt (they fail at once, before any search).
    for i=2,#points-1 do
      local v=points[i]
      t.box=window(v.x,v.y,v.x,v.y)
      if not t.kind(v.x,v.y) then
        error(string.format('via point %d %s is %s',i-1,fmt(v.x,v.y),t.is_charted(v.x,v.y) and 'blocked or fed by another belt' or 'not charted'),0)
      end
    end

    local function fail(why,goal_pt,from_pt)
      local text={why}
      local c=ctx.nearest
      if c then
        text[#text+1]=string.format('the nearest tile reached is %s, %d tiles from %s',fmt(c.x,c.y),c.h,fmt(goal_pt.x,goal_pt.y))
        local names,tl=blockers_near(p,c.x,c.y)
        if #names>0 then text[#text+1]='near it: '..table.concat(names,', ') end
        if #tl>0 then text[#text+1]='tiles there: '..table.concat(tl,', ') end
      end
      local ok,line=pcall(function() return api.tiles and api.tiles.line_tiles(p.surface,p.force,belt,centre(from_pt.x,from_pt.y),centre(goal_pt.x,goal_pt.y)) end)
      if ok and line then text[#text+1]=line end
      text[#text+1]=string.format('the search keeps within %d tiles of each leg\'s ends; %d placement checks, %d expansions',MARGIN,budget.checks,budget.expansions)
      error('no route: '..table.concat(text,'; '),0)
    end

    -- The legs, each from where the last ended (with its heading).
    local steps,legs={},{}
    local starts={{x=fx,y=fy,din=start_din,g=0}}
    for i=2,#points do
      local pt=points[i]
      local last=i==#points
      local goal=last and target and {x=tx,y=ty,target=target,allowed=allowed} or {x=pt.x,y=pt.y,last=last}
      local prev=starts[1]
      local node,why=leg(ctx,starts,goal,window(prev.x,prev.y,pt.x,pt.y))
      if not node then
        fail(why=='budget' and string.format('the search budget (%d placement checks, %d expansions) ran out on the leg to %s',MAX_CHECKS,MAX_EXPANSIONS,fmt(pt.x,pt.y))
          or string.format('no way through on the leg to %s',fmt(pt.x,pt.y)),pt,prev)
      end
      local legsteps=walk_back(node)
      for _,st in ipairs(legsteps) do steps[#steps+1]=st end
      legs[#legs+1]=#legsteps
      if not last then starts={{x=node.x,y=node.y,din=node.din,g=0}} end
      ctx.goal_din=node.din
    end
    local main=describe(steps,belt,underground,t)
    local items={[belt.name]=main.belts}
    if main.undergrounds>0 then items[underground.name]=main.undergrounds*2 end
    for item,n in pairs(main.fill) do items[item]=(items[item] or 0)+n end
    local out={route=main.route,tiles=main.tiles,belts=main.belts,undergrounds=main.undergrounds,items=items,entities=main.entities,extends=extends,
      legs=#legs>1 and legs or nil,over_trees_or_plants=main.clear>0 and main.clear or nil,landfill=next(main.fill) and main.fill or nil}
    if target then
      out.arrival=arrival(target,ctx.goal_din,s.feeds)
      out.arrival.into={x=target.position.x,y=target.position.y}
    else
      out.arrival={mode='end',direction=NAME[steps[#steps].direction]}
    end

    -- The return line (return=true): from beside the last belt back to beside
    -- the first, on one side of the line (return_side, else whichever side
    -- starts and ends free), keeping to the first's side where it can.
    if a['return'] then
      local first_dir,last_dir=steps[1].direction,steps[#steps].direction
      local endx,endy=steps[#steps].x,steps[#steps].y
      local beginx,beginy=steps[1].x,steps[1].y
      local near={}
      for _,st in ipairs(steps) do
        t.taken[key(st.x,st.y)]=true
        if st.kind~='belt' then ctx.planned_under[key(st.x,st.y)]={name=underground.name,direction=st.direction} end
      end
      -- The line's last belt outputs one tile on: the return line keeps off it.
      local ls=steps[#steps]
      if not target then t.fed[key(ls.x+STEP[ls.direction][1],ls.y+STEP[ls.direction][2])]=true end
      for _,st in ipairs(steps) do for dx=-1,1 do for dy=-1,1 do near[key(st.x+dx,st.y+dy)]=true end end end
      local function away(x,y) return near[key(x,y)] and 0 or M.TUNE.away end
      local sides=a.return_side and {a.return_side} or {'right','left'}
      local tried={}
      local found
      for _,side in ipairs(sides) do
        local turn=side=='right' and cw or ccw
        local sx,sy=endx+STEP[turn(last_dir)][1],endy+STEP[turn(last_dir)][2]
        local gx,gy=beginx+STEP[turn(first_dir)][1],beginy+STEP[turn(first_dir)][2]
        local box={left=math.huge,top=math.huge,right=-math.huge,bottom=-math.huge}
        for _,st in ipairs(steps) do
          box.left,box.top=math.min(box.left,st.x-MARGIN),math.min(box.top,st.y-MARGIN)
          box.right,box.bottom=math.max(box.right,st.x+MARGIN),math.max(box.bottom,st.y+MARGIN)
        end
        t.box=box
        if not t.kind(sx,sy) then tried[#tried+1]=string.format('%s: its first tile %s is blocked or taken',side,fmt(sx,sy))
        elseif not t.kind(gx,gy) then tried[#tried+1]=string.format('%s: its last tile %s is blocked or taken',side,fmt(gx,gy))
        elseif sx==gx and sy==gy then tried[#tried+1]=side..': the line is too short for a return line'
        else
          ctx.to_direction=nil
          local node,why=leg(ctx,{{x=sx,y=sy,din=-1,g=0}},{x=gx,y=gy,last=true},box,away)
          if node then
            local rsteps=walk_back(node)
            -- Its last belt must not feed the first line or another belt: it turns away if it would.
            local lst=rsteps[#rsteps]
            local function feeds_into(d)
              local nx,ny=lst.x+STEP[d][1],lst.y+STEP[d][2]
              s.ensure(nx,ny)
              return t.taken[key(nx,ny)] or s.at[key(nx,ny)]
            end
            if feeds_into(lst.direction) then
              for _,d in ipairs({cw(lst.direction),ccw(lst.direction)}) do
                if not feeds_into(d) and d~=opposite(node.incoming or lst.direction) then lst.direction=d; break end
              end
            end
            found={steps=rsteps,side=side,from={x=sx+0.5,y=sy+0.5},to={x=gx+0.5,y=gy+0.5}}
            break
          end
          tried[#tried+1]=string.format('%s: %s',side,why=='budget' and 'the search budget ran out' or 'no way through')
        end
      end
      if not found then error('no return line: '..table.concat(tried,'; '),0) end
      local r=describe(found.steps,belt,underground,t,'return')
      out['return']={route=r.route,tiles=r.tiles,belts=r.belts,undergrounds=r.undergrounds,side=found.side,from=found.from,to=found.to,
        over_trees_or_plants=r.clear>0 and r.clear or nil,landfill=next(r.fill) and r.fill or nil}
      items[belt.name]=items[belt.name]+r.belts
      if r.undergrounds>0 then items[underground.name]=(items[underground.name] or 0)+r.undergrounds*2 end
      for item,n in pairs(r.fill) do items[item]=(items[item] or 0)+n end
      for _,e in ipairs(r.entities) do out.entities[#out.entities+1]=e end
    end
    out.cost={placement_checks=budget.checks,expansions=budget.expansions}
    return out
  end
  return M
end
