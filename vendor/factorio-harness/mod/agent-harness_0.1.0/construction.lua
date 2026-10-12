-- Continuous belt placement using ordinary player movement and cursor building.
-- State is plain save-persistent data; no coroutine, host polling, or teleport.
return function(api)
  local M={}
  local names={[0]='north',[4]='east',[8]='south',[12]='west'}
  function M.plan(p,a)
    assert(type(a.points)=='table' and #a.points>=2 and #a.points<=64,'points requires 2..64 tile-centred waypoints')
    local item=a.item or 'transport-belt'
    local prototype=prototypes.item[item]
    assert(prototype and prototype.place_result and prototype.place_result.type=='transport-belt','build_path requires a transport belt item')
    local points={}
    for _,value in ipairs(a.points) do
      local pos=api.position(value)
      assert(pos.x%1==0.5 and pos.y%1==0.5,'waypoints must be tile centres (x.5, y.5)')
      assert(api.distance(p.position,pos)<=512,'path is farther than 512 tiles')
      points[#points+1]=pos
    end
    local cells,seen={},{}
    local function add(pos,direction)
      assert(#cells<512,'path exceeds 512 tiles')
      local key=pos.x..':'..pos.y
      assert(not seen[key],'path revisits a tile')
      seen[key]=true; cells[#cells+1]={position=pos,direction=direction}
    end
    local final_direction
    for i=1,#points-1 do
      local from,to=points[i],points[i+1]
      local dx,dy=to.x-from.x,to.y-from.y
      assert((dx==0)~=(dy==0),'segments must be nonzero and axis aligned')
      local length=math.abs(dx)+math.abs(dy)
      assert(length<=512,'path segment exceeds 512 tiles')
      local sx,sy=dx/length,dy/length
      local direction=dx>0 and 4 or dx<0 and 12 or dy>0 and 8 or 0
      for n=0,length-1 do add({x=from.x+sx*n,y=from.y+sy*n},direction) end
      final_direction=direction
    end
    if a.end_direction then
      local found
      for value,name in pairs(names) do if name==a.end_direction then found=value end end
      assert(found,'invalid end_direction'); final_direction=found
    end
    add(points[#points],final_direction)
    return {kind='build_path',cells=cells,next_index=api.integer(a.start_index,1,1,#cells,'start_index'),
      item=item,entity_name=prototype.place_result.name,quality=a.quality or 'normal',placed=0,skipped=0,
      until_tick=game.tick+api.integer(a.ticks,3600,1,36000,'ticks')}
  end
  function M.tick(p,action)
    if p.permission_group and not p.permission_group.allows_action(defines.input_action.start_walking) then
      action.error='permission denied: start_walking'; return 'build_failed'
    end
    local progressed=false
    for _=1,4 do
      local cell=action.cells[action.next_index]
      if not cell then return 'path_built' end
      if not api.visible(p,cell.position) or api.distance(p.position,cell.position)>p.build_distance then break end
      local existing
      for _,e in pairs(p.surface.find_entities_filtered{position=cell.position,radius=0.1,type='transport-belt'}) do
        if e.valid then existing=e; break end
      end
      if existing then
        if existing.name~=action.entity_name or existing.direction~=cell.direction or existing.force~=p.force
          or (existing.quality and existing.quality.name or 'normal')~=action.quality then
          action.error='existing belt differs in type, direction, force, or quality'; return 'build_failed'
        end
        action.skipped=action.skipped+1
      else
        local ok,result=pcall(api.build,p,{item=action.item,position=cell.position,direction=names[cell.direction],quality=action.quality})
        if not ok then action.error=tostring(result); return 'build_failed' end
        if result.consumed~=1 then action.error='native build did not consume one belt; inspect target before resuming'; return 'build_failed' end
        action.placed=action.placed+1
      end
      action.next_index=action.next_index+1; progressed=true; action.approaches=0
    end
    local cell=action.cells[action.next_index]
    if not cell then return 'path_built' end
    -- Far from the next tile (the start, or a resume elsewhere): walk there
    -- with the pathfinder as move_to does; steer directly only along the line.
    if action.nav or api.distance(p.position,cell.position)>p.build_distance+1 then
      if not action.nav then
        action.approaches=(action.approaches or 0)+1
        if action.approaches>3 then action.error='could not get within reach of tile '..action.next_index; return 'blocked' end
        action.nav={position=cell.position,tolerance=math.max(1,p.build_distance-1),max_stalls=6,replans=0,stalled=0,last_position=p.position}
        api.request_path(p,action.nav)
      end
      local outcome=api.navigate(p,action.nav)
      if not outcome then return end
      action.nav=nil; action.best_gap=nil
      p.walking_state={walking=false,direction=0}
      if outcome~='arrived' and outcome~='arrived_near' then
        action.error=string.format('could not walk to tile %d (%s,%s): %s',action.next_index,cell.position.x,cell.position.y,outcome); return 'blocked'
      end
      return
    end
    -- Progress means a tile placed or half a tile closer to the next one;
    -- moving in place (a belt carrying the character back) does not count.
    local gap=api.distance(p.position,cell.position)
    if progressed or not action.best_gap or gap<action.best_gap-0.5 then action.best_gap=gap; action.best_tick=game.tick end
    if game.tick-action.best_tick>=120 then action.error='walking made no progress for 120 ticks'; return 'blocked' end
    api.steer(p,cell.position,action)
  end
  -- Ghost construction by hand: visit ghosts in nearest-neighbour order and
  -- place each from inventory through the same cursor build as `build`, which
  -- revives the ghost with its recipe and settings.
  -- Ghost construction works like a player: build everything already in
  -- reach, then walk to the stand point (off every footprint) that brings the
  -- most remaining ghosts into reach, near the nearest unbuilt ghost.
  local MAX_GHOSTS,PER_TICK,STAND_TRIES=1024,4,3
  local BELTS={'transport-belt','underground-belt','splitter','loader','loader-1x1','linked-belt'}
  local compass={}
  for name,value in pairs(api.directions) do compass[value]=name end
  -- Building reaches build_distance; hand-mining trees, rocks and marked
  -- entities only resource_reach_distance, so their stand points sit closer.
  local function reach(p,rec)
    if rec and rec.mine then return (p.resource_reach_distance or 2.7)-0.2 end
    return p.build_distance-0.5
  end
  -- A tree or rock to hand-mine, once per entity; trees and rocks that block
  -- ghosts are also listed (action.blockers, reported with the outcome).
  local MAX_BLOCKERS=32
  local function add_mine(action,e,ghost)
    action.seen=action.seen or {}
    local key=e.name..':'..e.position.x..','..e.position.y
    if action.seen[key] then return false end
    action.seen[key]=true
    action.pending[#action.pending+1]={ghost=e,mine=true,tries=0,stand_fails=0}
    if ghost then
      action.blockers=action.blockers or {}
      if #action.blockers<MAX_BLOCKERS then
        action.blockers[#action.blockers+1]={name=e.name,position={x=e.position.x,y=e.position.y},entity=e,
          ghost=ghost.ghost_name,at={x=ghost.position.x,y=ghost.position.y}}
      end
    end
    return true
  end
  function M.plan_ghosts(p,a,box)
    local pending={}
    local action={kind='construct',pending=pending,built=0,mined=0,gone=0,missing={},failed={},seen={}}
    local function add(e,ghost) add_mine(action,e,ghost) end
    -- Tile ghosts (landfill, paths) are placed like tiles from the cursor;
    -- trees and rocks do not block them.
    for _,e in pairs(p.surface.find_entities_filtered{area=box,type={'entity-ghost','tile-ghost'},force=p.force}) do
      if e.valid and api.known(p,e) then
        local obstacles=e.type=='tile-ghost' and {} or M.mark_obstacles(p,e)
        pending[#pending+1]={ghost=e,tries=0,stand_fails=0,obstacles=#obstacles>0 and obstacles or nil}
        for _,o in ipairs(obstacles) do add(o,e) end
      end
    end
    -- Entities marked for deconstruction are mined by hand, as a player
    -- clears marks without robots; contents go to the inventory.
    for _,e in pairs(p.surface.find_entities_filtered{area=box,to_be_deconstructed=true}) do
      if e.valid and e.type~='entity-ghost' and (e.force==p.force or e.force.name=='neutral') and e.minable and api.known(p,e) then
        add(e)
      end
    end
    assert(#pending<=MAX_GHOSTS,'more than '..MAX_GHOSTS..' ghosts; construct a smaller area')
    action.until_tick=game.tick+api.integer(a.ticks,36000,1,216000,'ticks')
    return action
  end
  -- Returns the owned item that places this ghost, or nil and the item wanted.
  local function item_for(p,g,quality)
    local inv,wanted=p.get_main_inventory(),nil
    for _,stack in ipairs(g.ghost_prototype.items_to_place_this or {}) do
      wanted=wanted or stack.name
      if inv.get_item_count{name=stack.name,quality=quality}>=(stack.count or 1) then return stack.name end
    end
    return nil,wanted or g.ghost_name
  end
  function M.remaining(action)
    local n=0
    for _,rec in ipairs(action.pending or {}) do if rec.ghost.valid then n=n+1 end end
    return n
  end
  local function footprint(g)
    local b=g.bounding_box
    if b then return b.left_top,b.right_bottom end
    return {x=g.position.x-0.5,y=g.position.y-0.5},{x=g.position.x+0.5,y=g.position.y+0.5}
  end
  local function on_footprint(g,pos,margin)
    local lt,rb=footprint(g)
    return pos.x>lt.x-margin and pos.x<rb.x+margin and pos.y>lt.y-margin and pos.y<rb.y+margin
  end
  -- The box the built entity will take: its collision box at the ghost
  -- (what the engine checks), else the ghost's own box.
  local function placement_box(g)
    local proto=g.ghost_prototype
    if proto and proto.collision_box then return M.box(proto,g.position,g.direction) end
    local lt,rb=footprint(g)
    return {left_top=lt,right_bottom=rb}
  end
  -- Whether an entity's box reaches the given box (edges touching count).
  local function touches(e,box,margin)
    local b=e.bounding_box
    if not b then return true end -- no box to compare: the area search found it
    local l,t,r,btm=b.left_top.x,b.left_top.y,b.right_bottom.x,b.right_bottom.y
    return l<=box.right_bottom.x+margin and r>=box.left_top.x-margin and t<=box.right_bottom.y+margin and btm>=box.left_top.y-margin
  end
  -- Trees and rocks under a ghost get deconstruction marks, as the game marks
  -- them when a player places ghosts over them. Any whose box reaches the
  -- placement box counts, edges touching included (request #167: tree-08s
  -- whose collision box only met a belt ghost's edge were missed by a search
  -- inside the footprint, and construct ended with the ghost still blocked).
  -- margin widens that (a build that failed looks a little further).
  -- Returns every marked obstacle and how many were newly marked.
  function M.mark_obstacles(p,g,margin)
    margin=margin or 0.01
    local found,marked={},0
    local box=placement_box(g)
    local area={left_top={x=box.left_top.x-1.5,y=box.left_top.y-1.5},right_bottom={x=box.right_bottom.x+1.5,y=box.right_bottom.y+1.5}}
    for _,e in pairs(p.surface.find_entities_filtered{area=area,type=((script and script.active_mods['space-age']) and {'tree','plant','simple-entity'} or {'tree','simple-entity'}),force='neutral'}) do
      if e.valid and e.minable and touches(e,box,margin) then
        -- The engine takes a LuaPlayer or nothing: a bot or map-view proxy
        -- here fails with "Invalid PlayerIdentification".
        if not e.to_be_deconstructed() and e.order_deconstruction(p.force,api.real(p)) then marked=marked+1 end
        if e.to_be_deconstructed() then found[#found+1]=e end
      end
    end
    return found,marked
  end
  -- The area an entity of this prototype covers at pos, turned for east/west.
  function M.box(proto,pos,direction)
    local b=proto.collision_box or {left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}
    local l,t,r,btm=b.left_top.x,b.left_top.y,b.right_bottom.x,b.right_bottom.y
    if direction==4 or direction==12 then l,t,r,btm=-btm,l,-t,r end
    return {left_top={x=pos.x+l,y=pos.y+t},right_bottom={x=pos.x+r,y=pos.y+btm}}
  end
  -- Remnants (tree stumps, biter corpses, ruins: type corpse) never stop a
  -- player's build, the game removes them under the new entity; a script
  -- build or revive is refused by them (shake3: "placement blocked by
  -- tree-08-stump" right after mining the tree). So they go first. A
  -- character corpse holds items and stays.
  function M.clear_remnants(surface,proto,pos,direction)
    local n=0
    for _,e in pairs(surface.find_entities_filtered{area=M.box(proto,pos,direction),type='corpse'}) do
      if e.valid and e.type=='corpse' then e.destroy(); n=n+1 end
    end
    return n
  end
  -- True when the footprint holds only trees, rocks and remnants: what a
  -- ghost may go over, since place_ghosts marks the trees and rocks,
  -- construct mines them, and the build clears the remnants.
  local OBSTACLE={tree=true,plant=true,['simple-entity']=true}
  function M.only_obstacles(surface,proto,pos,direction)
    local any=false
    for _,e in pairs(surface.find_entities_filtered{area=M.box(proto,pos,direction)}) do
      if e.valid and e.type=='corpse' then any=true
      elseif e.valid and e.type~='resource' then
        -- Neutral only: mark_obstacles leaves a force's own plants (Gleba farms) alone.
        if not (OBSTACLE[e.type] and e.minable and (e.force==nil or e.force.name=='neutral')) then return false end
        any=true
      end
    end
    return any
  end
  function M.in_box(pos,box)
    return pos.x>box.left_top.x and pos.x<box.right_bottom.x and pos.y>box.left_top.y and pos.y<box.right_bottom.y
  end
  -- When the agent's own character is the only thing in a footprint (shake3:
  -- Grok's most common error), where to step so the build can go ahead: the
  -- nearest free spot just off the footprint that keeps the position in build
  -- reach, not on a belt. Returns {to, box (what the character must leave)},
  -- or nil when anything else is in the way or no spot fits.
  function M.aside(p,proto,pos,direction)
    local c=p.character
    if not (c and c.valid) then return nil end
    local box=M.box(proto,pos,direction)
    local mine=false
    for _,e in pairs(p.surface.find_entities_filtered{area=box}) do
      if e.valid then
        if e==c then mine=true
        elseif e.type~='resource' and e.type~='corpse' then return nil end
      end
    end
    if not mine then return nil end
    -- The character is 0.4 wide: its centre must be 0.2 off the box.
    local leave={left_top={x=box.left_top.x-0.22,y=box.left_top.y-0.22},right_bottom={x=box.right_bottom.x+0.22,y=box.right_bottom.y+0.22}}
    local m,here=0.45,p.position
    local l,t,r,b=box.left_top.x-m,box.left_top.y-m,box.right_bottom.x+m,box.right_bottom.y+m
    local spots={{x=l,y=here.y},{x=r,y=here.y},{x=here.x,y=t},{x=here.x,y=b},{x=l,y=t},{x=r,y=t},{x=l,y=b},{x=r,y=b}}
    table.sort(spots,function(u,v) return api.distance(here,u)<api.distance(here,v) end)
    for _,s in ipairs(spots) do
      if api.distance(s,pos)<=p.build_distance-0.5 and p.surface.can_place_entity{name=c.name,position=s,force=p.force}
        and p.surface.count_entities_filtered{area={{s.x-0.4,s.y-0.4},{s.x+0.4,s.y+0.4}},type=BELTS,limit=1}==0 then
        return {to=s,box=leave}
      end
    end
  end
  local function obstructed(rec)
    for _,o in ipairs(rec.obstacles or {}) do if o.valid then return o end end
  end
  -- The character (radius ~0.2) standing on a ghost blocks its placement.
  local function can_stand(p,action,pos)
    for _,rec in ipairs(action.pending) do
      local g=rec.ghost
      if g.valid and g.type~='tile-ghost' and math.abs(g.position.x-pos.x)<6 and math.abs(g.position.y-pos.y)<6 and on_footprint(g,pos,0.3) then return false end
    end
    -- Belts carry a standing character off its stand point.
    if p.surface.count_entities_filtered{area={{pos.x-0.4,pos.y-0.4},{pos.x+0.4,pos.y+0.4}},type=BELTS,limit=1}>0 then return false end
    return p.surface.can_place_entity{name=p.character and p.character.name or 'character',position=pos,force=p.force}
  end
  -- A ghost that failed once is retried only after the character moved, since
  -- the usual cause is the character itself or an entity it was about to clear.
  local function buildable(p,rec)
    local g=rec.ghost
    if rec.mine then return p.can_reach_entity(g) and api.visible(p,g.position) end
    return api.distance(p.position,g.position)<=reach(p) and api.visible(p,g.position) and not obstructed(rec)
      and not (rec.blocked_at and api.distance(p.position,rec.blocked_at)<1)
      and (g.type=='tile-ghost' or not on_footprint(g,p.position,0.2))
  end
  -- Honest completion: ghosts skipped for lack of items or failures mean the
  -- area is not done, whatever else was built.
  local function finished(action)
    return (next(action.missing) or #action.failed>0) and 'incomplete' or 'constructed'
  end
  local function drop(action,i) action.pending[i]=action.pending[#action.pending]; action.pending[#action.pending]=nil end
  local function fail(action,rec,err)
    local g=rec.ghost
    action.failed[#action.failed+1]={name=g.valid and (rec.mine and g.name or g.ghost_name) or nil,position=rec.position or rec.ghost.position,error=err}
  end
  -- Candidates ring the target at two radii plus the in-reach point on the
  -- straight line toward the character. Coverage wins; walking distance only
  -- breaks ties (16 tiles, the ring's diameter, is worth one ghost).
  local function stand_point(p,action,target)
    local g,r=target.ghost,reach(p,target)
    local far=target.mine and r or r-1.5
    local candidates={}
    local dx,dy=p.position.x-g.position.x,p.position.y-g.position.y
    local d=math.sqrt(dx*dx+dy*dy)
    if d>0 then candidates[1]={x=g.position.x+dx/d*math.min(far,d),y=g.position.y+dy/d*math.min(far,d)} end
    for k=0,15 do
      local angle=k*math.pi/8
      for _,radius in ipairs{far,far/2} do
        candidates[#candidates+1]={x=g.position.x+math.cos(angle)*radius,y=g.position.y+math.sin(angle)*radius}
      end
    end
    local best,best_score
    for _,c in ipairs(candidates) do
      local ok=not (target.blocked_at and api.distance(c,target.blocked_at)<1.5)
      for _,bad in ipairs(target.bad_stands or {}) do if api.distance(c,bad)<1.5 then ok=false end end
      if ok and can_stand(p,action,c) then
        local cover=0
        for _,rec in ipairs(action.pending) do
          if rec.ghost.valid and api.distance(c,rec.ghost.position)<=reach(p,rec)-(rec.mine and 0 or 1) then cover=cover+1 end
        end
        local score=cover-api.distance(p.position,c)/16
        if not best_score or score>best_score then best,best_score=c,score end
      end
    end
    return best
  end
  local function stop(p) p.walking_state={walking=false,direction=0} end
  local function index_of(action,rec)
    for i,r in ipairs(action.pending) do if r==rec then return i end end
  end
  -- One entity is mined at a time; the character stands still meanwhile.
  local function tick_mining(p,action)
    local m=action.mining
    local rec=m.rec
    local e=rec.ghost
    if not e.valid then action.mining=nil; action.gone=action.gone+1; drop(action,index_of(action,rec)); return end
    if game.tick<m.done_tick then return true end
    action.mining=nil
    if p.mine_entity(e,false) and not e.valid then action.mined=action.mined+1; drop(action,index_of(action,rec)); return end
    fail(action,rec,'inventory_full'); drop(action,index_of(action,rec))
    return 'inventory_full'
  end
  function M.tick_ghosts(p,action)
    if not action.pending then return 'interrupted' end -- started by an older bundle
    if action.mining then
      local busy=tick_mining(p,action)
      if busy=='inventory_full' then stop(p); return 'inventory_full' end
      if busy then stop(p); return end
    end
    -- Deconstruction cancelled meanwhile: leave those entities alone.
    if game.tick%30==0 then
      for i=#action.pending,1,-1 do
        local rec=action.pending[i]
        if rec.mine and rec.ghost.valid and not rec.ghost.to_be_deconstructed() then drop(action,i) end
      end
    end
    local placed,waiting=0,false
    for i=#action.pending,1,-1 do
      local rec=action.pending[i]
      local g=rec.ghost
      if not g.valid then action.gone=action.gone+1; drop(action,i)
      elseif rec.mine then
        if not action.mining and buildable(p,rec) then action.mining={rec=rec,done_tick=game.tick+api.hand_mining_ticks(p,g)} end
      elseif buildable(p,rec) then
        if placed>=PER_TICK then waiting=true; break end
        local quality=g.quality and g.quality.name or 'normal'
        local item,wanted=item_for(p,g,quality)
        if not item then
          -- Items still in the hand-crafting queue are awaited, not missing.
          if api.crafting_count(p,wanted)==0 then action.missing[wanted]=(action.missing[wanted] or 0)+1; drop(action,i) end
        else
          rec.position=g.position
          local tile=g.type=='tile-ghost'
          local ok,err=pcall(api.build,p,{item=item,quality=quality,position=g.position,direction=not tile and compass[g.direction] or nil})
          placed=placed+1
          if ok and not g.valid then action.built=action.built+1; drop(action,i)
          else
            -- A tree or rock the build could not get past: mark and mine that
            -- one, then build again (no try spent on it).
            local fresh=0
            for _,o in ipairs(not tile and M.mark_obstacles(p,g,0.3) or {}) do
              if add_mine(action,o,g) then
                fresh=fresh+1
                rec.obstacles=rec.obstacles or {}
                rec.obstacles[#rec.obstacles+1]=o
              end
            end
            if fresh>0 then rec.blocked_at=nil; goto next_ghost end
            rec.tries=rec.tries+1
            if rec.tries>=2 then fail(action,rec,ok and 'ghost remained' or api.reason(err)); drop(action,i)
            else rec.blocked_at={x=p.position.x,y=p.position.y} end
          end
        end
      end
      ::next_ghost::
    end
    if #action.pending==0 then stop(p); return finished(action) end
    -- Everything in reach gets built (or mined) before taking another step.
    if placed>0 or waiting or action.mining then stop(p); return end
    local nav=action.nav
    if nav and not (nav.target and nav.target.ghost.valid) then
      -- Target built on the way: keep heading there while the stand point
      -- still covers other ghosts, rather than re-planning mid-walk.
      local covered
      for _,rec in ipairs(action.pending) do
        if rec.ghost.valid and api.distance(nav.position,rec.ghost.position)<=reach(p,rec)-(rec.mine and 0 or 1) then covered=rec; break end
      end
      -- No stand point left: drop the walk too, or the next tick indexes a nil target.
      nav.target=covered
      if not covered then action.nav=nil; nav=nil end
    end
    if nav then
      local outcome=api.navigate(p,nav)
      if not outcome then return end
      local target=nav.target
      action.nav=nil
      if outcome~='arrived' or not buildable(p,target) then
        target.bad_stands=target.bad_stands or {}
        target.bad_stands[#target.bad_stands+1]=nav.position
        target.stand_fails=target.stand_fails+1
        if target.stand_fails>=STAND_TRIES then
          for i,rec in ipairs(action.pending) do if rec==target then fail(action,rec,'unreachable'); drop(action,i); break end end
        end
      end
      stop(p); return
    end
    -- Walk toward the nearest ghost that still has an item in inventory.
    -- Deferred: ghosts under uncleared trees/rocks (their mining comes
    -- first) and ghosts whose item is being hand-crafted (awaited last, in
    -- reach where the character stands).
    local deferred={}
    action.awaiting_craft=nil
    while #action.pending>0 do
      local best,bd,later,ld
      for i,rec in ipairs(action.pending) do
        local d=rec.ghost.valid and api.distance(p.position,rec.ghost.position)
        if d then
          if deferred[rec]=='craft' then if not ld or d<ld then later,ld=i,d end
          elseif not deferred[rec] and (not bd or d<bd) then best,bd=i,d end
        end
      end
      local rec=action.pending[best or later]
      if not rec then
        -- Only ghosts whose obstacles could not be mined remain.
        for i=#action.pending,1,-1 do
          local o=obstructed(action.pending[i])
          if o then fail(action,action.pending[i],string.format('blocked by %s at (%g,%g), which could not be mined',o.name,o.position.x,o.position.y)); drop(action,i) end
        end
        break
      end
      local g=rec.ghost
      local item,wanted=true,nil
      if not best then
        if buildable(p,rec) then action.awaiting_craft=true; stop(p); return end
      elseif not rec.mine then item,wanted=item_for(p,g,g.quality and g.quality.name or 'normal') end
      if not rec.mine and obstructed(rec) then deferred[rec]='blocked'
      elseif not item and api.crafting_count(p,wanted)>0 then deferred[rec]='craft'
      elseif not item then action.missing[wanted]=(action.missing[wanted] or 0)+1; drop(action,best)
      else
        local stand=stand_point(p,action,rec)
        if not stand then fail(action,rec,'no free stand point in reach'); drop(action,best or later)
        else
          -- Stalls re-path at once and give up after a few, since another
          -- stand point is usually a better answer than pushing on.
          action.nav={position=stand,tolerance=rec.mine and 0.4 or 1,target=rec,max_stalls=6,replan_every=1,replans=0,stalled=0,last_position=p.position}
          if api.distance(p.position,stand)>reach(p) then api.request_path(p,action.nav) end
          return
        end
      end
    end
    if #action.pending==0 then stop(p); return finished(action) end
  end
  return M
end
