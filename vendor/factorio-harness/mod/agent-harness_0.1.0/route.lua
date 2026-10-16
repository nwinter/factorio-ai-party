-- Belt routing: the cheapest belt line from one tile to another around
-- obstacles, hopping them with underground pairs, and arriving either on an
-- empty tile or into an existing belt straight, as a curve, or by side-load
-- onto a chosen lane. Plans only; the caller places the result as ghosts.
-- Long routes (Sol, operator 07:52: a 600-tile Gleba seed return planned by
-- hand): a weighted A* over tiles in a window of MARGIN tiles around each leg
-- (from, via points, to), up to MAX_LEG tiles a leg, within a budget of
-- placement checks. Trees, rocks and wild plants are passed over at a cost
-- (place_ghosts marks them, construct mines them); water and Gleba wetland
-- only with landfill=true (tile ghosts under the belts); cliffs are passed
-- over as trees are (the ghost marks them, one cliff-explosives each);
-- buildings never. An underground pair hops anything but lava and empty space.
-- return=true lays a second line beside it, the other way.
local heap=require('heap')
return function(api)
  local M={}
  local DIRS={0,4,8,12}
  local STEP={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  local NAME={[0]='north',[4]='east',[8]='south',[12]='west'}
  local LETTER={[0]='N',[4]='E',[8]='S',[12]='W'}
  local BELT_TYPES={'transport-belt','underground-belt','splitter','loader','loader-1x1','lane-splitter','linked-belt'}
  local MARGIN,MAX_LEG,MAX_POINTS=24,1000,16
  M.BUDGET={checks=8000,expansions=8000,total_checks=12000,total_expansions=13000}
  -- Belts and undergrounds one call lays, the return line's included.
  local MAX_ENTITIES=2048
  -- An existing chain followed from from to its open end (Haiku 06:20: a coal line past 256 tiles was refused twice).
  M.CHAIN=4096
  local RETURN_STEP,RETURN_NEAR,LEG_CAP,RETURN_SLACK,RETURN_SHORT=12,6,{600,1500},2,24
  -- A leg still searching after POCKET_AFTER expansions checks whether its
  -- goal is closed in (up to POCKET tiles around it).
  local POCKET_AFTER,POCKET=1000,600
  local LOOP=32
  -- Costs in belt tiles: turns are slightly dearer than straights, an
  -- underground pair wins only where it saves real detours, a tree or plant
  -- to clear costs a little, a tile to landfill more; the return line pays to
  -- leave the side of the first; WEIGHT trades the shortest line for speed.
  -- (A 690-tile Gleba line on a test server: weight 1.5 took 8759 placement
  -- checks and 5728 expansions; weight 2 with underground 9 took 6136 and
  -- 2546 for as many undergrounds.)
  M.TUNE={turn=0.5,underground=9,clear=1.5,fill=4,away=1,weight=2}
  local UNDER={lava_tile=true,empty_space=true}  -- tiles an underground cannot pass under (underpass.lua)
  local function opposite(d) return (d+8)%16 end
  local function cw(d) return (d+4)%16 end
  local function ccw(d) return (d+12)%16 end
  -- Tile keys are numbers: a string key costs a number-to-string conversion
  -- (about 16 us each on a test server, against 0.2 us for a number).
  local function key(x,y) return (x+2097152)*4194304+(y+2097152) end
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
      if belt_type(e)=='underground-belt' then s.undergrounds[key(x,y)]={name=belt_name(e),direction=e.direction,kind=underground_kind(e)} end
    end
    function s.ensure(x,y)
      local cx,cy=math.floor(x/32),math.floor(y/32)
      local k=key(cx,cy)
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
  local function tiles(p,a,belt,s,budget,danger)
    local t={kinds={},fills={},taken={},fed={},charted={},budget=budget,box=nil,danger=danger}
    local stands=api.tiles and api.tiles.stands_fn(p.surface,belt) or function() return true end
    local tile_info=api.tile_info
    local only_obstacles=api.only_obstacles
    local info_cache={}
    local function info(x,y)
      local ok,tl=pcall(function() return p.surface.get_tile(x,y) end)
      local name=ok and tl and tl.name
      return name and tile_info(p.force,belt,name,info_cache) or {collides=false}
    end
    local function charted(x,y)
      local cx,cy=math.floor(x/32),math.floor(y/32)
      local ck=key(cx,cy)
      local v=t.charted[ck]
      if v==nil then v=p.force.is_chunk_charted(p.surface,{x=cx,y=cy}); t.charted[ck]=v end
      return v
    end
    t.is_charted=charted
    local function check(x,y,forced)
      budget.checks=budget.checks+1
      return p.surface.can_place_entity{name=belt.name,position=centre(x,y),direction=0,force=p.force,
        build_check_type=defines.build_check_type.manual_ghost,forced=forced or nil}
    end
    local kinds,taken,fed,feeds,at=t.kinds,t.taken,t.fed,s.feeds,s.at
    function t.kind(x,y,is_start)
      local b=t.box
      if b and (x<b.left or x>b.right or y<b.top or y>b.bottom) then return false end
      local k=key(x,y)
      if taken[k] or fed[k] or (danger and danger(x,y)) then return false end
      local v=kinds[k]
      if v==nil then
        -- (its chunk's belts surveyed first: feeds and at are then known here)
        s.ensure(x,y)
        v=false
        -- can_place_entity accepts a belt over one of ours (a rotate or
        -- fast-replace), but that ghost is never built: the tile is taken.
        if not at[k] and charted(x,y) then
          if check(x,y) and stands(x,y) then v='free'
          elseif tile_info or only_obstacles then
            -- Water or wetland (the tile kind collides, no tile ghost laid yet): only with landfill, where an
            -- unlocked item makes it buildable and nothing else refuses the forced ghost.
            local ti=tile_info and info(x,y) or {collides=false}
            if ti.collides and not stands(x,y) then
              if a.landfill and ti.item and check(x,y,true) then v='fill'; t.fills[k]=ti.item end
            elseif check(x,y,true) then
              -- A cliff (Haiku 09:22: cliffs on every belt line): routed round unless cliffs=true (marked, one cliff
              -- explosive each); an underground pair still passes under it.
              local okc,nc=pcall(function() return p.surface.count_entities_filtered{area={{x,y},{x+1,y+1}},type='cliff',limit=1} end)
              local cliff=not a.cliffs and okc and nc>0
              v=not cliff and 'clear' or false
            elseif only_obstacles and only_obstacles(p.surface,belt,centre(x,y),0) then v='clear' end
          end
        end
        kinds[k]=v
      end
      if v and feeds[k] and not is_start then return false end
      return v
    end
    -- What an underground can not pass under: by tile name once, by tile once.
    local under,under_at={},{}
    function t.passes_under(x,y)
      if danger and danger(x,y) then return false end
      local k=key(x,y)
      local v=under_at[k]
      if v~=nil then return v end
      local ok,tl=pcall(function() return p.surface.get_tile(x,y) end)
      local name=ok and tl and tl.name
      if not name then v=true
      else
        if under[name]==nil then
          local okl,layers=pcall(function() return tl.prototype.collision_mask.layers end)
          local blocked=false
          for layer in pairs(okl and layers or {}) do if UNDER[layer] then blocked=true end end
          under[name]=not blocked
        end
        v=under[name]
      end
      under_at[k]=v
      return v
    end
    return t
  end

  -- Whether an underground pair entered at (x,y) heading d may exit k tiles on:
  -- a hop may not pass over an underground of the same kind on its axis (that
  -- one would pair with our entrance instead), nor over lava or space. (How
  -- far a hop may reach is worked out once per tile and heading.)
  local function hop_clear(ctx,x,y,d,k)
    local ck=key(x,y)*16+d
    local n=ctx.clear_to[ck]
    if n==nil then
      local s,reach=ctx.s,ctx.reach
      n=reach
      for i=1,reach-1 do
        local hx,hy=x+STEP[d][1]*i,y+STEP[d][2]*i
        s.ensure(hx,hy)
        local hk=key(hx,hy)
        local u=s.undergrounds[hk] or ctx.planned_under[hk]
        if (u and u.name==ctx.underground.name and (u.direction==d or u.direction==opposite(d))) or not ctx.t.passes_under(hx,hy) then n=i; break end
      end
      ctx.clear_to[ck]=n
    end
    return k<=n
  end

  -- Whether a new pair entered at (x,y) heading d (or leaving there, ends
  -- 'output') leaves other pairs of its kind on the axis as they are: the
  -- nearest one behind an entrance may only be an exit heading d, the
  -- nearest one past an exit only an entrance heading d.
  local function pair_alone(ctx,x,y,d,ends)
    local ck=key(x,y)*32+d*2+(ends=='output' and 1 or 0)
    local v=ctx.alone[ck]
    if v==nil then
      local s=ctx.s
      local dir=ends=='output' and d or opposite(d)
      local want=ends=='output' and 'input' or 'output'
      v=true
      for i=1,ctx.reach do
        local hx,hy=x+STEP[dir][1]*i,y+STEP[dir][2]*i
        s.ensure(hx,hy)
        local hk=key(hx,hy)
        local u=s.undergrounds[hk] or ctx.planned_under[hk]
        if u and u.name==ctx.underground.name and (u.direction==d or u.direction==opposite(d)) then
          v=u.direction==d and u.kind==want
          break
        end
      end
      ctx.alone[ck]=v
    end
    return v
  end

  -- Whether the goal (x,y) is closed in: the tiles from which a line could
  -- still reach it (a belt on the tile before it, or an underground pair whose
  -- exit is there; headings ignored), gathered back from it up to POCKET
  -- tiles. The count when they run out first, without touching a tile the
  -- search has reached (reached(x,y)); else nil.
  local function closed_in(ctx,gx,gy,reached)
    local t=ctx.t
    local seen,queue,head={[key(gx,gy)]=true},{{x=gx,y=gy}},1
    local function add(x,y)
      local k=key(x,y)
      if seen[k] then return false end
      seen[k]=true
      if reached(x,y) then return true end
      queue[#queue+1]={x=x,y=y}
      return false
    end
    while head<=#queue do
      if #queue>POCKET then return nil end
      local y=queue[head]; head=head+1
      for _,d in ipairs(DIRS) do
        local sx,sy=STEP[d][1],STEP[d][2]
        local px,py=y.x-sx,y.y-sy
        if t.kind(px,py) then
          if add(px,py) then return nil end
          if ctx.underground then
            for k=2,ctx.reach do
              local zx,zy=px-sx*k,py-sy*k
              if not hop_clear(ctx,zx,zy,d,k) then break end
              if t.kind(zx,zy) and add(zx,zy) then return nil end
            end
          end
        end
      end
    end
    return #queue-1
  end
  local function closed_text(what,n)
    return string.format('%s is closed in: %s',what,n==0 and 'no tile next to it can take the belt that would feed it'
      or string.format('a line can reach it from only %d tile%s around it',n,n==1 and '' or 's'))
  end

  -- One leg: from the start nodes to goal, a weighted A* inside box. goal:
  -- {x,y} reached at any heading (a via point), {target, allowed} (feeding an
  -- existing belt), {x,y,last=true} (the free last tile), or {x,y,accept}
  -- (any node accept(node) takes; x,y guide the search). extra(x,y): an
  -- added cost per tile (the return line off the first's side).
  local function leg(ctx,starts,goal,box,extra,cap)
    local t,s,underground,reach,TUNE=ctx.t,ctx.s,ctx.underground,ctx.reach,M.TUNE
    local budget,kind,W,TURN=ctx.budget,t.kind,TUNE.weight,TUNE.turn
    t.box=box
    local tx,ty=goal.x,goal.y
    local function h(x,y,din)
      local dx,dy=tx-x,ty-y
      local d=math.abs(dx)+math.abs(dy)
      if din>=0 then
        local sx,sy=STEP[din][1],STEP[din][2]
        -- a heading off the goal's axis, or away from it, needs a turn or two
        if (dx~=0 and dy~=0) or dx*sx+dy*sy<0 or (dx==0 and sx~=0) or (dy==0 and sy~=0) then d=d+TURN end
      end
      return d
    end
    local function cost(v,x,y)
      local c=v=='clear' and TUNE.clear or v=='fill' and TUNE.fill or 0
      return extra and c+extra(x,y) or c
    end
    local open,best,nearest={},{},nil
    for _,st in ipairs(starts) do
      heap.push(open,{x=st.x,y=st.y,din=st.din,g=st.g or 0,f=W*h(st.x,st.y,st.din),start=true})
    end
    local target,allowed=goal.target,goal.allowed
    -- A node is reached from its parent by a belt there pointing din, or by
    -- an underground pair entered there with its exit hop tiles on (walk_back
    -- lays them out).
    local node
    -- A line never crosses itself: a move's tiles may not be on the last LOOP
    -- tiles of the path to this node (a search state is a tile and a heading,
    -- so a loop back onto a tile looks new: world n copy 09:29, a return line
    -- left an underground exit at (60,36) heading west and came back round to
    -- enter one there heading north).
    local function on_path(n,x,y)
      local i=0
      while n and i<LOOP do
        if n.x==x and n.y==y then return true end
        if n.hop and n.x-STEP[n.din][1]==x and n.y-STEP[n.din][2]==y then return true end
        n=n.parent; i=i+1
      end
      return false
    end
    local function reached(x,y)
      local k=key(x,y)*16+1
      return best[k] or best[k+1] or best[k+5] or best[k+9] or best[k+13]
    end
    local pocket_at=goal.accept and -1 or budget.expansions+POCKET_AFTER
    -- An accepted node ends the leg; a last one gets the last belt.
    local fallback,fallback_at
    local function finish(nd)
      if not goal.last then return nd end
      local d=nd.din>=0 and nd.din or 4
      return {parent=nd,place={{kind='belt',x=nd.x,y=nd.y,direction=d}},din=d,incoming=nd.din}
    end
    local cap_at=cap and budget.expansions+cap or math.huge
    local function relax(x,y,din,g,hop,is_goal)
      if is_goal then heap.push(open,{goal=true,parent=node,din=din,hop=hop,g=g,f=g}); return end
      local k=key(x,y)*16+din+1
      local b=best[k]
      if b and (b<0 or b<=g) then return end
      best[k]=g
      heap.push(open,{x=x,y=y,din=din,g=g,f=g+W*h(x,y,din),parent=node,hop=hop})
    end
    while #open>0 do
      node=heap.pop(open)
      if node.goal then return node end
      local sk=key(node.x,node.y)*16+node.din+1
      if not best[sk] or node.g<=best[sk] then
        best[sk]=-1 -- closed
        budget.expansions=budget.expansions+1
        if budget.expansions>ctx.limit.expansions or budget.checks>ctx.limit.checks then
          if fallback then return finish(fallback) end
          ctx.nearest=nearest; return nil,'budget'
        end
        if budget.expansions>cap_at then
          if fallback then return finish(fallback) end
          ctx.nearest=nearest; return nil,'cap'
        end
        if budget.expansions==pocket_at then
          ctx.closed=closed_in(ctx,tx,ty,reached)
          if ctx.closed then ctx.nearest=nearest; return nil,'closed' end
        end
        local hn=h(node.x,node.y,-1)
        if not nearest or hn<nearest.h then nearest={x=node.x,y=node.y,h=hn,node=node} end
        if fallback and budget.expansions>=fallback_at then return finish(fallback) end
        if goal.accept then
          if not node.start and goal.accept(node) then
            -- (with prefer: the goal tile itself if the search reaches it within
            -- prefer more expansions, else the first tile accepted)
            if not goal.prefer or (node.x==tx and node.y==ty) then return finish(node) end
            if not fallback then fallback,fallback_at=node,budget.expansions+goal.prefer end
          end
        elseif not target and node.x==tx and node.y==ty and not node.start then
          if goal.last then
            local d=ctx.to_direction or (node.din>=0 and node.din or 4)
            return {parent=node,place={{kind='belt',x=tx,y=ty,direction=d}},din=d,incoming=node.din}
          end
          return node
        end
        for _,d in ipairs(DIRS) do
          if node.din<0 or d~=opposite(node.din) then
            -- A belt here pointing d.
            local sx,sy=STEP[d][1],STEP[d][2]
            local nx,ny=node.x+sx,node.y+sy
            local g=node.g+1+((node.din>=0 and d~=node.din) and TURN or 0)
            local ahead_free=false
            if target and nx==tx and ny==ty then
              if allowed[d] then relax(nx,ny,d,g,nil,true) end
            else
              local v=kind(nx,ny)
              if v and not on_path(node,nx,ny) then relax(nx,ny,d,g+cost(v,nx,ny)) end
              ahead_free=v=='free'
            end
            -- An underground pair: entered straight, exit k tiles on. Never
            -- over a free first tile: a belt there and a shorter pair cost the same.
            if underground and not ahead_free and (node.din<0 or d==node.din) then
              for k=2,reach do
                local ex,ey=node.x+sx*k,node.y+sy*k
                if target and ex==tx and ey==ty then break end
                if not hop_clear(ctx,node.x,node.y,d,k) then break end
                local ve=not (not target and ex==tx and ey==ty) and kind(ex,ey)
                if ve and (on_path(node,ex,ey) or not (pair_alone(ctx,node.x,node.y,d,'input') and pair_alone(ctx,ex,ey,d,'output'))) then ve=false end
                if ve then
                  local ox,oy=ex+sx,ey+sy
                  local gg=node.g+k+1+TUNE.underground+cost(ve,ex,ey)
                  if target and ox==tx and oy==ty then
                    if allowed[d] then relax(ox,oy,d,gg,k,true) end
                  else
                    local vo=kind(ox,oy)
                    if vo and not on_path(node,ox,oy) then relax(ox,oy,d,gg+cost(vo,ox,oy),k) end
                  end
                end
              end
            end
          end
        end
      end
    end
    if fallback then return finish(fallback) end
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

  -- A planned leg's tiles are taken for the legs after it, and its
  -- undergrounds count on their hop axes.
  local function take(ctx,list)
    local under=false
    for _,st in ipairs(list) do
      ctx.t.taken[key(st.x,st.y)]=true
      if st.kind~='belt' then ctx.planned_under[key(st.x,st.y)]={name=ctx.underground.name,direction=st.direction,kind=st.kind}; under=true end
    end
    if under then ctx.clear_to,ctx.alone={},{} end
  end

  local function untake(ctx,list,keep_taken,keep_under)
    for _,st in ipairs(list) do
      local k=key(st.x,st.y)
      if not keep_taken[k] then ctx.t.taken[k]=nil end
      if not keep_under[k] then ctx.planned_under[k]=nil end
    end
    ctx.clear_to,ctx.alone={},{}
  end

  -- The steps of a found leg, start to goal.
  local function walk_back(node)
    local back={}
    local n=node
    while n do
      local p=n.parent
      if n.place then for i=#n.place,1,-1 do back[#back+1]=n.place[i] end
      elseif p and n.hop then
        back[#back+1]={kind='output',x=p.x+STEP[n.din][1]*n.hop,y=p.y+STEP[n.din][2]*n.hop,direction=n.din}
        back[#back+1]={kind='input',x=p.x,y=p.y,direction=n.din}
      elseif p then back[#back+1]={kind='belt',x=p.x,y=p.y,direction=n.din} end
      n=p
    end
    local steps={}
    for i=#back,1,-1 do steps[#steps+1]=back[i] end
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
    -- One entity a tile (a loop longer than LOOP would put two there).
    local used={}
    for _,st in ipairs(steps) do
      local k=key(st.x,st.y)
      if used[k] then error('the route would cross itself at '..fmt(st.x,st.y)..'; route it in legs by via points',0) end
      used[k]=true
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
    local danger,avoid_note,margin,hazard_cost,guide
    if api.route_guard then danger,avoid_note,margin,hazard_cost,guide=api.route_guard(p,a.avoid_enemies)
    else assert(a.avoid_enemies==nil or a.avoid_enemies==false,'enemy clearance is unavailable') end
    margin=math.max(MARGIN,margin or MARGIN)
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
    local t=tiles(p,a,belt,s,budget,danger)
    local ctx={t=t,s=s,underground=underground,reach=reach,budget=budget,planned_under={},to_direction=to_direction,clear_to={},alone={},
      limit={checks=M.BUDGET.checks,expansions=M.BUDGET.expansions}}

    -- Follow the existing, directed chain to its open end. These tiles are
    -- reused, never rotated/replaced. A side input follows the receiving belt.
    local start_din,extends=-1,nil
    local existing,seen={},{}
    while true do
      assert(t.is_charted(fx,fy),'from chain tile '..fmt(fx,fy)..' is not charted')
      if danger then
        local why=danger(fx,fy)
        assert(not why,'from chain tile '..fmt(fx,fy)..' is inside enemy clearance: '..tostring(why))
      end
      s.ensure(fx,fy)
      local first=s.at[key(fx,fy)]
      if not first then break end
      local kind,d=belt_type(first),first.direction
      assert(not seen[key(fx,fy)],'from chain loops at '..fmt(fx,fy)..'; no open end')
      assert(#existing<M.CHAIN,'from chain exceeds '..M.CHAIN..' existing belt tiles at '..fmt(fx,fy)..': give from nearer its open end')
      assert(STEP[d],'from chain tile '..fmt(fx,fy)..' has no cardinal belt direction')
      local input=kind=='underground-belt' and underground_kind(first)=='input'
      assert(kind=='transport-belt' or kind=='underground-belt',
        'from chain tile '..fmt(fx,fy)..' holds '..belt_name(first)..'; no single belt output to follow')
      if start_din>=0 then
        assert(start_din~=opposite(d),'from chain blocked at '..fmt(fx,fy)..': '..belt_name(first)..' faces '..NAME[d]..' against incoming '..NAME[start_din]..' (opposing outputs)')
        assert(not input or start_din==d,'from chain blocked at '..fmt(fx,fy)..': underground entrance accepts a straight input only')
      end
      extends=extends or {x=first.position.x,y=first.position.y}
      existing[#existing+1]={name=belt_name(first),position=centre(fx,fy),direction=NAME[d]}
      seen[key(fx,fy)]=true
      if fx==tx and fy==ty then
        assert(not a.via and not a['return'] and not a.lane,'from already connects to to; via, return and lane require a new segment')
        return {route='',tiles=0,belts=0,undergrounds=0,items={},entities={},extends=extends,existing=existing,connected=true,
          arrival={mode='connected',into=centre(tx,ty)},cost=budget}
      end
      if input then
        local ok,exit=pcall(function() return first.neighbours end)
        assert(ok and exit and exit.valid and exit.force==p.force and underground_kind(exit)=='output',
          'from chain blocked at '..fmt(fx,fy)..': underground entrance has no paired exit of ours')
        local ex,ey=tile(exit.position)
        if danger then
          local length=math.abs(ex-fx)+math.abs(ey-fy)
          for n=1,length do
            local why=danger(fx+STEP[d][1]*n,fy+STEP[d][2]*n)
            assert(not why,'from underground span at '..fmt(fx+STEP[d][1]*n,fy+STEP[d][2]*n)..' is inside enemy clearance: '..tostring(why))
          end
        end
        fx,fy=ex,ey
      else fx,fy=fx+STEP[d][1],fy+STEP[d][2] end
      start_din=d
    end
    points[1]={x=fx,y=fy}
    local next_point=points[2]
    assert(math.abs(fx-next_point.x)+math.abs(fy-next_point.y)<=MAX_LEG,'the open end '..fmt(fx,fy)..' is more than '..MAX_LEG..' tiles from the next route point')

    if danger then
      for i,v in ipairs(points) do
        local why=danger(v.x,v.y)
        if why then error(string.format('%s %s is inside enemy clearance: %s',i==1 and 'from' or i==#points and 'to' or 'via '..(i-1),fmt(v.x,v.y),why),0) end
      end
    end

    local automatic=0
    if guide then
      local guided={points[1]}
      for i=2,#points do
        local prev,pt=points[i-1],points[i]
        local vias=guide(centre(prev.x,prev.y),centre(pt.x,pt.y))
        for j=1,math.max(0,#vias-1) do
          local vx,vy=tile(vias[j])
          local free
          for radius=0,4 do
            for dx=-radius,radius do for dy=-radius,radius do
              if not free and (math.abs(dx)==radius or math.abs(dy)==radius) and t.kind(vx+dx,vy+dy) then free={x=vx+dx,y=vy+dy} end
            end end
            if free then break end
          end
          assert(free,'no buildable tile near automatic enemy-clearance waypoint '..fmt(vx,vy))
          local last=guided[#guided]
          if free.x~=last.x or free.y~=last.y then guided[#guided+1]=free; automatic=automatic+1 end
          assert(automatic<=64,'enemy clearance requires more than 64 automatic waypoints')
        end
        guided[#guided+1]=pt
      end
      points=guided
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
      else error('to '..fmt(tx,ty)..' holds '..belt_name(target)..'; it can be fed only at a plain belt or an underground entrance') end
    else
      assert(not a.lane,'lane needs an existing belt at to')
    end

    local function window(ax,ay,bx,by) return {left=math.min(ax,bx)-margin,top=math.min(ay,by)-margin,right=math.max(ax,bx)+margin,bottom=math.max(ay,by)+margin} end
    -- Why an end or via tile takes no belt: what holds it, or its tile.
    local function blocked_text(x,y)
      local hazard=danger and danger(x,y)
      if hazard then return 'inside enemy clearance: '..hazard end
      if not t.is_charted(x,y) then return 'not charted' end
      local k=key(x,y)
      if s.at[k] then return 'taken by our '..belt_name(s.at[k]) end
      if s.feeds[k] then return 'fed by another belt' end
      local ok,tl=pcall(function() return p.surface.get_tile(x,y) end)
      local name=ok and tl and tl.name
      local ti=name and api.tile_info and api.tile_info(p.force,belt,name,{})
      if ti and ti.collides then
        return name..(a.landfill and (ti.item and '' or ' (no tile item makes it buildable)') or ' (landfill=true lays tile ghosts under the belts)')
      end
      local okf,list=pcall(function() return p.surface.find_entities_filtered{area={{x,y},{x+1,y+1}},limit=8} end)
      local names={}
      for _,e in ipairs(okf and list or {}) do
        if e.valid and e.type~='character' and e.type~='resource' and e.type~='item-entity' then names[#names+1]=e.name end
      end
      return 'blocked'..(#names>0 and ' by '..table.concat(names,', ') or '')
    end
    t.box=window(fx,fy,fx,fy)
    if not t.kind(fx,fy,true) then error('the start tile '..fmt(fx,fy)..' is '..blocked_text(fx,fy),0) end
    if not target then
      assert(fx~=tx or fy~=ty,'from and to are the same tile')
      t.box=window(tx,ty,tx,ty)
      if not t.kind(tx,ty) then error('to '..fmt(tx,ty)..' is '..blocked_text(tx,ty),0) end
    else
      -- The last belt stands on a neighbour of `to`; say which if none can.
      t.box=window(tx,ty,tx,ty)
      local closed={}
      for d in pairs(allowed) do
        local ax,ay=tx-STEP[d][1],ty-STEP[d][2]
        if (ax==fx and ay==fy) or t.kind(ax,ay) then closed=nil; break end
        local c=centre(ax,ay)
        closed[#closed+1]=string.format('%g,%g is %s',c.x,c.y,blocked_text(ax,ay))
      end
      assert(not closed,closed and 'no way into to: '..table.concat(closed,'; '))
    end
    -- Via points must take a belt (they fail at once, before any search).
    for i=2,#points-1 do
      local v=points[i]
      t.box=window(v.x,v.y,v.x,v.y)
      if not t.kind(v.x,v.y) then
        error(string.format('via point %d %s is %s',i-1,fmt(v.x,v.y),blocked_text(v.x,v.y)),0)
      end
    end

    local function fail(why,goal_pt,from_pt,closed)
      local text={why}
      local c=ctx.nearest
      if closed then
        local names,tl=blockers_near(p,goal_pt.x,goal_pt.y)
        if #names>0 then text[#text+1]='near it: '..table.concat(names,', ') end
        if #tl>0 then text[#text+1]='tiles there: '..table.concat(tl,', ') end
      elseif c then
        text[#text+1]=string.format('the nearest tile reached is %s, %d tiles from %s',fmt(c.x,c.y),c.h,fmt(goal_pt.x,goal_pt.y))
        local names,tl=blockers_near(p,c.x,c.y)
        if #names>0 then text[#text+1]='near it: '..table.concat(names,', ') end
        if #tl>0 then text[#text+1]='tiles there: '..table.concat(tl,', ') end
      end
      local focus=c or goal_pt
      local blocked={}
      for _,d in ipairs(DIRS) do
        local x,y=focus.x+STEP[d][1],focus.y+STEP[d][2]
        if not t.kind(x,y) then blocked[#blocked+1]=fmt(x,y)..' '..blocked_text(x,y) end
      end
      if #blocked>0 then text[#text+1]='blocked adjacent tiles: '..table.concat(blocked,', ') end
      local ok,line=pcall(function() return api.tiles and api.tiles.line_tiles(p.surface,p.force,belt,centre(from_pt.x,from_pt.y),centre(goal_pt.x,goal_pt.y)) end)
      if ok and line then text[#text+1]=line end
      text[#text+1]=string.format('the search keeps within %d tiles of each leg\'s ends; %d placement checks, %d expansions',margin,budget.checks,budget.expansions)
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
        local name=last and 'to '..fmt(pt.x,pt.y) or string.format('via point %d %s',i-2,fmt(pt.x,pt.y))
        fail(why=='budget' and string.format('the search budget (%d placement checks, %d expansions) ran out on the leg to %s',M.BUDGET.checks,M.BUDGET.expansions,fmt(pt.x,pt.y))
          or why=='closed' and closed_text(name,ctx.closed)
          or string.format('no way through on the leg to %s',fmt(pt.x,pt.y)),pt,prev,why=='closed')
      end
      local legsteps=walk_back(node)
      for _,st in ipairs(legsteps) do steps[#steps+1]=st end
      legs[#legs+1]=#legsteps
      if not last then take(ctx,legsteps) end
      if not last then starts={{x=node.x,y=node.y,din=node.din,g=0}} end
      ctx.goal_din=node.din
    end
    local main=describe(steps,belt,underground,t)
    assert(main.tiles<=MAX_ENTITIES,string.format('the line needs %d belts and undergrounds; one call lays at most %d (split it into parts by from and to)',main.tiles,MAX_ENTITIES))
    local items={[belt.name]=main.belts}
    if main.undergrounds>0 then items[underground.name]=main.undergrounds*2 end
    for item,n in pairs(main.fill) do items[item]=(items[item] or 0)+n end
    -- A long chain followed: its first and last tiles and the count (the reply stays short).
    local shown=existing
    if #existing>8 then shown={existing[1],existing[2],existing[3],existing[#existing-2],existing[#existing-1],existing[#existing]} end
    local out={route=main.route,tiles=main.tiles,belts=main.belts,undergrounds=main.undergrounds,items=items,entities=main.entities,extends=extends,existing=#existing>0 and shown or nil,
      existing_count=#existing>8 and #existing or nil,
      legs=#legs>1 and legs or nil,over_trees_or_plants=main.clear>0 and main.clear or nil,landfill=next(main.fill) and main.fill or nil}
    -- What the line passes over and the ghosts mark for mining (Haiku 09:22: the trees to mine, listed): trees, rocks and
    -- (with cliffs=true) cliffs on its tiles.
    if main.clear>0 then
      local by,first,seen2,nseen={},{},{},0
      for _,e in ipairs(main.entities) do
        local ex,ey=tile(e.position)
        if t.kinds[key(ex,ey)]=='clear' then
          local okf,found=pcall(function() return p.surface.find_entities_filtered{area={{ex,ey},{ex+1,ey+1}},type={'tree','simple-entity','cliff','plant'},limit=8} end)
          for _,o in ipairs(okf and found or {}) do
            local ok=o.valid and o.unit_number or (o.position.x..','..o.position.y)
            if not seen2[ok] then
              seen2[ok]=true; nseen=nseen+1
              by[o.type]=(by[o.type] or 0)+1
              if #first<12 then first[#first+1]=string.format('%s (%g,%g)',o.name,o.position.x,o.position.y) end
            end
          end
        end
      end
      local parts={}
      for _,k in ipairs({'tree','simple-entity','plant','cliff'}) do if by[k] then parts[#parts+1]=by[k]..' '..({tree='trees',['simple-entity']='rocks',plant='plants',cliff='cliffs'})[k] end end
      if #parts>0 then out.to_mine=table.concat(parts,', ')..': '..table.concat(first,', ')..(nseen>#first and ', ...' or '') end
    end
    if target then
      out.arrival=arrival(target,ctx.goal_din,s.feeds)
      out.arrival.into={x=target.position.x,y=target.position.y}
    else
      out.arrival={mode='end',direction=NAME[steps[#steps].direction]}
    end

    -- The return line (return=true): from beside the last belt back to beside
    -- the first, on one side of the line (return_side, else whichever side
    -- starts and ends free). It follows the row beside the first line on that
    -- side: short legs between free tiles of that row RETURN_STEP tiles apart,
    -- each searched within RETURN_NEAR tiles (then MARGIN) of its ends; tiles
    -- off the row cost more, and it may cross under the first line by an
    -- underground pair. A leg that finds no way even so ends the row: the rest
    -- is one search over the whole window.
    if a['return'] then
      local first_dir,last_dir=steps[1].direction,steps[#steps].direction
      local endx,endy=steps[#steps].x,steps[#steps].y
      local beginx,beginy=steps[1].x,steps[1].y
      take(ctx,steps)
      -- The line's last belt outputs one tile on: the return line keeps off it.
      local ls=steps[#steps]
      if not target then t.fed[key(ls.x+STEP[ls.direction][1],ls.y+STEP[ls.direction][2])]=true end
      -- The first line's tiles in order (those under its underground pairs too),
      -- each with the heading it is entered by (din) and left by (d).
      local path={}
      for i,st in ipairs(steps) do
        if st.kind=='output' then
          local prev=steps[i-1]
          for j=1,math.abs(st.x-prev.x)+math.abs(st.y-prev.y)-1 do
            path[#path+1]={x=prev.x+STEP[st.direction][1]*j,y=prev.y+STEP[st.direction][2]*j,d=st.direction}
          end
        end
        path[#path+1]={x=st.x,y=st.y,d=st.direction}
      end
      for i,pt in ipairs(path) do pt.din=i>1 and path[i-1].d or pt.d end
      -- The row beside it on one side, from beside its last tile back to
      -- beside its first (an outer corner adds its diagonal tile).
      local function row(turn)
        -- index: row tile -> its place in the row; band: that, and the tile
        -- one further out -> the place of the row tile beside it.
        local r,index,band={},{},{}
        local function add(x,y,back,ox,oy)
          local k=key(x,y)
          if index[k] or t.taken[k] then return end
          r[#r+1]={x=x,y=y,back=back}; index[k]=#r; band[k]=#r
          local k2=key(x+ox,y+oy)
          if not band[k2] and not t.taken[k2] then band[k2]=#r end
        end
        for i=#path,1,-1 do
          local pt=path[i]
          local u,v=STEP[turn(pt.d)],STEP[turn(pt.din)]
          add(pt.x+u[1],pt.y+u[2],pt.d,u[1],u[2])
          if pt.d~=pt.din then
            add(pt.x+u[1]+v[1],pt.y+u[2]+v[2],pt.d,u[1]+v[1],u[2]+v[2])
            add(pt.x+v[1],pt.y+v[2],pt.din,v[1],v[2])
          end
        end
        return r,index,band
      end
      local wide={left=math.huge,top=math.huge,right=-math.huge,bottom=-math.huge}
      for _,st in ipairs(steps) do
        wide.left,wide.top=math.min(wide.left,st.x-margin),math.min(wide.top,st.y-margin)
        wide.right,wide.bottom=math.max(wide.right,st.x+margin),math.max(wide.bottom,st.y+margin)
      end
      local function near(ax,ay,bx,by,m) return {left=math.min(ax,bx)-m,top=math.min(ay,by)-m,right=math.max(ax,bx)+m,bottom=math.max(ay,by)+m} end
      local taken0={}
      for k in pairs(t.taken) do taken0[k]=true end
      local planned0={}
      for k,v in pairs(ctx.planned_under) do planned0[k]=v end
      local sides=a.return_side and {a.return_side} or {'right','left'}
      -- A side whose tiles beside both ends are free goes first.
      if #sides==2 then
        t.box=wide
        local function exact(side)
          local turn=side=='right' and cw or ccw
          return t.kind(endx+STEP[turn(last_dir)][1],endy+STEP[turn(last_dir)][2]) and t.kind(beginx+STEP[turn(first_dir)][1],beginy+STEP[turn(first_dir)][2])
        end
        if not exact('right') and exact('left') then sides={'left','right'} end
      end
      local tried={}
      local found,partial
      for si,side in ipairs(sides) do
        -- What is left of the budget, shared by the sides still to try.
        local share=#sides-si+1
        ctx.limit={checks=budget.checks+math.floor((M.BUDGET.total_checks-budget.checks)/share),
          expansions=budget.expansions+math.floor((M.BUDGET.total_expansions-budget.expansions)/share)}
        local turn=side=='right' and cw or ccw
        local sx,sy=endx+STEP[turn(last_dir)][1],endy+STEP[turn(last_dir)][2]
        local gx,gy=beginx+STEP[turn(first_dir)][1],beginy+STEP[turn(first_dir)][2]
        local why
        t.box=wide
        -- Its ends: the tile beside the line's end, else the free tile nearest
        -- it within RETURN_SLACK (a pole or chest beside the first belt in a
        -- built-up base); it may end on any free tile that near its last tile.
        -- (on this side of the line: n is the side, (ax,ay) the line's tile)
        local function near_free(x,y,ax,ay,n)
          if t.kind(x,y) then return x,y end
          local bx,by,bd
          for dx=-RETURN_SLACK,RETURN_SLACK do for dy=-RETURN_SLACK,RETURN_SLACK do
            local cx,cy=x+dx,y+dy
            local dd=math.abs(dx)+math.abs(dy)
            if (not bd or dd<bd) and (cx-ax)*n[1]+(cy-ay)*n[2]>=1 and t.kind(cx,cy) then bx,by,bd=cx,cy,dd end
          end end
          return bx,by
        end
        local ssx,ssy=near_free(sx,sy,endx,endy,STEP[turn(last_dir)])
        local egx,egy=near_free(gx,gy,beginx,beginy,STEP[turn(first_dir)])
        if not ssx then why=string.format('its first tile %s and the tiles within %d of it are blocked or taken',fmt(sx,sy),RETURN_SLACK)
        elseif not egx then why=string.format('its last tile %s and the tiles within %d of it are blocked or taken',fmt(gx,gy),RETURN_SLACK)
        elseif sx==gx and sy==gy then why='the line is too short for a return line'
        else
          sx,sy=ssx,ssy
          local r,index,band=row(turn)
          local function off_row(x,y) return index[key(x,y)] and 0 or M.TUNE.away end
          -- A stop: a tile of the row from j on (or the one beside it further
          -- out), reached heading the return line's way, with a free tile to go
          -- on to; the search heads for the first free row tile from j.
          local function stop(j)
            local f=j
            t.box=wide
            while f<#r-1 and not t.kind(r[f].x,r[f].y) do f=f+1 end
            return {x=r[f].x,y=r[f].y,accept=function(nd)
              local at=band[key(nd.x,nd.y)]
              if not (at and at>=j and at<#r and nd.din~=r[at].back) then return false end
              for _,d in ipairs(DIRS) do
                if d~=opposite(nd.din) and t.kind(nd.x+STEP[d][1],nd.y+STEP[d][2]) then return true end
              end
              return false
            end}
          end
          local done,parts,cur,ri=false,{},{x=sx,y=sy,din=-1,g=0},1
          local en=STEP[turn(first_dir)]
          local the_end={x=egx,y=egy,last=true,prefer=300,accept=function(nd)
            return math.max(math.abs(nd.x-gx),math.abs(nd.y-gy))<=RETURN_SLACK and (nd.x-beginx)*en[1]+(nd.y-beginy)*en[2]>=1
          end}
          local node,w=nil,nil
          local aim  -- (the goal of the last search)
          ctx.to_direction=nil
          while true do
            local j=ri+RETURN_STEP
            local last=the_end
            local tries=j<#r and {{j,RETURN_NEAR,LEG_CAP[1]},{j,margin,LEG_CAP[2]},{j+2*RETURN_STEP,margin,LEG_CAP[2]}}
              or {{#r,RETURN_NEAR,LEG_CAP[1]},{#r,margin,LEG_CAP[2]}}
            local goal
            node=nil
            for _,tr in ipairs(tries) do
              goal=tr[1]<#r and stop(tr[1]) or last
              aim=goal
              node,w=leg(ctx,{cur},goal,near(cur.x,cur.y,goal.x,goal.y,tr[2]),off_row,tr[3])
              if node or w=='budget' then break end
            end
            if not node then break end
            local part=walk_back(node)
            parts[#parts+1]={cur=cur,ri=ri,steps=part}
            if goal.last then done=true; break end
            take(ctx,part)
            cur,ri={x=node.x,y=node.y,din=node.din,g=0},band[key(node.x,node.y)]
          end
          if not done and w~='budget' then
            -- The row has no way on: back one leg, then the rest in one search
            -- over the window; failing that, the whole line in one search.
            local back=table.remove(parts)
            if back then untake(ctx,back.steps,taken0,planned0); cur=back.cur end
            aim=the_end
            node,w=leg(ctx,{cur},the_end,wide,nil)
            if node then parts[#parts+1]={steps=walk_back(node)}; done=true
            elseif w~='budget' and #parts>0 then
              for _,pt in ipairs(parts) do untake(ctx,pt.steps,taken0,planned0) end
              parts={}
              node,w=leg(ctx,{{x=sx,y=sy,din=-1,g=0}},the_end,wide,nil)
              if node then parts[1]={steps=walk_back(node)}; done=true end
            end
          end
          -- Short of its end (a built-up base around the first belt): the line up
          -- to the nearest tile a search for its end reached, when that is near.
          local short
          local c=ctx.nearest
          if not done and aim==the_end and c and c.node and not c.node.start and c.h<=RETURN_SHORT then
            local nd=c.node
            local d=nd.din>=0 and nd.din or 4
            node={parent=nd,place={{kind='belt',x=nd.x,y=nd.y,direction=d}},din=d,incoming=nd.din}
            parts[#parts+1]={steps=walk_back(node)}
            short={tiles=c.h,of={x=gx+0.5,y=gy+0.5}}
            done=true
          end
          local rsteps={}
          for _,pt in ipairs(parts) do for _,st in ipairs(pt.steps) do rsteps[#rsteps+1]=st end end
          if not done then
            node=nil
            local c=ctx.nearest
            why=(w=='budget' and 'the search budget ran out' or 'no way through')
              ..(c and string.format(' (the nearest tile reached is %s, %d tiles from its last tile %s)',fmt(c.x,c.y),c.h,fmt(gx,gy)) or '')
          end
          if node then
            -- Its last belt must not feed the first line or another belt: it turns away if it would.
            local lst=rsteps[#rsteps]
            local mine={}
            for _,st in ipairs(rsteps) do mine[key(st.x,st.y)]=true end
            local function feeds_into(d)
              local nx,ny=lst.x+STEP[d][1],lst.y+STEP[d][2]
              s.ensure(nx,ny)
              return taken0[key(nx,ny)] or mine[key(nx,ny)] or s.at[key(nx,ny)]
            end
            if feeds_into(lst.direction) then
              for _,d in ipairs({cw(lst.direction),ccw(lst.direction)}) do
                if not feeds_into(d) and d~=opposite(node.incoming or lst.direction) then lst.direction=d; break end
              end
            end
            -- Where it passes under the first line.
            local crossings=0
            for i,st in ipairs(rsteps) do
              if st.kind=='input' then
                local e=rsteps[i+1]
                local dx,dy=STEP[st.direction][1],STEP[st.direction][2]
                for j=1,math.abs(e.x-st.x)+math.abs(e.y-st.y)-1 do
                  if taken0[key(st.x+dx*j,st.y+dy*j)] then crossings=crossings+1; break end
                end
              end
            end
            -- Its tiles with no tile of the first line next to them.
            local apart=0
            for _,st in ipairs(rsteps) do
              local by=false
              for dx=-1,1 do for dy=-1,1 do if taken0[key(st.x+dx,st.y+dy)] then by=true end end end
              if not by then apart=apart+1 end
            end
            found={steps=rsteps,side=side,from={x=sx+0.5,y=sy+0.5},to={x=lst.x+0.5,y=lst.y+0.5},crossings=crossings,apart=apart,short=short}
          end
        end
        if found and not found.short then break end
        -- (a line short of its end waits for the other side's)
        if found then
          if not partial or found.short.tiles<partial.short.tiles then partial=found end
          found=nil
          why='it ends short of its last tile'
        end
        tried[#tried+1]=side..': '..why
        -- (the next side starts from the first line alone)
        for k in pairs(t.taken) do if not taken0[k] then t.taken[k]=nil end end
        for k in pairs(ctx.planned_under) do if not planned0[k] then ctx.planned_under[k]=nil end end
        ctx.clear_to,ctx.alone={},{}
      end
      found=found or partial
      if not found then error('no return line: '..table.concat(tried,'; '),0) end
      local r=describe(found.steps,belt,underground,t,'return')
      out['return']={route=r.route,tiles=r.tiles,belts=r.belts,undergrounds=r.undergrounds,side=found.side,from=found.from,to=found.to,
        crossings=found.crossings>0 and found.crossings or nil,apart=found.apart>0 and found.apart or nil,
        short_of=found.short and string.format('it ends at %s, %d tiles from its last tile %s (no way nearer within the budget)',fmt(found.to.x-0.5,found.to.y-0.5),found.short.tiles,fmt(found.short.of.x-0.5,found.short.of.y-0.5)) or nil,
        over_trees_or_plants=r.clear>0 and r.clear or nil,landfill=next(r.fill) and r.fill or nil}
      items[belt.name]=items[belt.name]+r.belts
      if r.undergrounds>0 then items[underground.name]=(items[underground.name] or 0)+r.undergrounds*2 end
      for item,n in pairs(r.fill) do items[item]=(items[item] or 0)+n end
      for _,e in ipairs(r.entities) do out.entities[#out.entities+1]=e end
      assert(#out.entities<=MAX_ENTITIES,string.format('the line and its return line need %d belts and undergrounds; one call lays at most %d (split it into parts by from and to)',#out.entities,MAX_ENTITIES))
    end
    out.avoid_enemies=avoid_note
    out.avoidance_waypoints=automatic>0 and automatic or nil
    out.cost={placement_checks=budget.checks,expansions=budget.expansions,hazard_chunks=hazard_cost and hazard_cost.chunks or nil}
    return out
  end
  return M
end
