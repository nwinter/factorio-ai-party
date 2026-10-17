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
    -- A tree or rock in the way being mined (M.clear): the character stands still until it is taken.
    if action.mining then
      local outcome=M.mine_tick(p,action)
      if outcome then return outcome end
      if action.mining then return end
    end
    -- The pathfinder walk to one out of reach (M.clear).
    if action.nav and action.nav.clearing then
      local e=action.nav.entity
      if e and e.valid then return M.clear(p,action,e) end
      action.nav=nil; p.walking_state={walking=false,direction=0}
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
        -- Trees, rocks and wild plants on the tile are mined first, as a player clears them by hand.
        local o=M.in_the_way(p,action,cell,0.01)
        if o then return M.clear(p,action,o) end
        local ok,result=pcall(api.build,p,{item=action.item,position=cell.position,direction=names[cell.direction],quality=action.quality})
        if not ok then
          -- One the first look missed (its box only near the tile's edge): a wider look, once a tile.
          o=action.wider~=action.next_index and M.in_the_way(p,action,cell,0.3)
          action.wider=action.next_index
          if o then return M.clear(p,action,o) end
          action.error=tostring(result); return 'build_failed'
        end
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
    if game.tick-action.best_tick>=120 then
      -- A tree or rock across the walk (the character off the line, steering to the next tile): cleared the same way.
      local o=M.walk_obstacle(p,cell.position)
      if o then return M.clear(p,action,o) end
      action.error='walking made no progress for 120 ticks'; return 'blocked'
    end
    api.steer(p,cell.position,action)
  end
  -- Ghost construction by hand: visit ghosts in nearest-neighbour order and
  -- place each from inventory through the same cursor build as `build`, which
  -- revives the ghost with its recipe and settings.
  -- Ghost construction works like a player: build everything already in
  -- reach, then walk to the stand point (off every footprint) that brings the
  -- most remaining ghosts into reach, near the nearest unbuilt ghost.
  local MAX_GHOSTS,PER_TICK,STAND_TRIES,LOOK_EVERY=1024,4,3,10
  local BELTS={'transport-belt','underground-belt','splitter','loader','loader-1x1','linked-belt'}
  local compass={}
  for name,value in pairs(api.directions) do compass[value]=name end
  -- Building reaches build_distance; hand-mining trees, rocks and marked
  -- entities only resource_reach_distance, so their stand points sit closer.
  local function reach(p,rec)
    if rec and rec.tile then return api.tilemine.reach(p)-0.5 end
    if rec and rec.mine then return (p.resource_reach_distance or 2.7)-0.2 end
    return p.build_distance-0.5
  end
  -- A pending entry's position, read from the engine once: ghosts, trees and
  -- marked entities do not move, and a tick reads every entry's position
  -- (shift01: a 255-ghost construct cost ~100 ms a tick in engine reads).
  local function pos_of(rec)
    local q=rec.pos
    if not q then local gp=rec.ghost.position; q={x=gp.x,y=gp.y}; rec.pos=q end
    return q
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
  function M.plan_ghosts(p,a,box,ghosts)
    local pending={}
    local action={kind='construct',pending=pending,built=0,mined=0,gone=0,missing={},failed={},seen={}}
    -- avoid_enemies as move_to's (default on; false: none): the walks go round, and a ghost inside a worm's or
    -- spawner's own reach is left out unless unsafe_goal (C2: Opus's second death, building next to a big worm).
    local mode=a.avoid_enemies~=false and api.avoid_mode and api.avoid_mode(a.avoid_enemies) or nil
    -- By default worms and spawners only: building in an area under attack is what defending it takes (on a copy of
    -- world n, Opus's construct begun inside attack #4338 found no leg out of it and read every ghost unreachable).
    if mode and a.avoid_enemies==nil then mode.attacks=nil end
    action.avoid_mode=mode
    local inside_n,inside_by,checked=0,{},0
    local function add(e,ghost) add_mine(action,e,ghost) end
    -- Tile ghosts (landfill, paths) are placed like tiles from the cursor;
    -- the trees and rocks a tile collides with go first (M.tile_obstacles).
    local tiles={}
    for _,e in pairs(ghosts or p.surface.find_entities_filtered{area=box,type={'entity-ghost','tile-ghost'},force=p.force}) do
      local danger
      if e.valid and mode and not a.unsafe_goal and api.goal_inside and checked<400 then
        checked=checked+1
        local ok,c=pcall(api.goal_inside,p,e.position,mode)
        if ok and c then
          danger=true; inside_n=inside_n+1
          local k=string.format('%s (%g,%g) %s %g',c.m.name,math.floor(c.m.x+0.5),math.floor(c.m.y+0.5),c.m.spawner and 'sight' or 'range',c.m.range)
          inside_by[k]=(inside_by[k] or 0)+1
        end
      end
      if e.valid and not danger and api.known(p,e) then
        local obstacles=e.type=='tile-ghost' and M.tile_obstacles(p,e) or M.mark_obstacles(p,e)
        pending[#pending+1]={ghost=e,tries=0,stand_fails=0,obstacles=#obstacles>0 and obstacles or nil}
        if e.type=='tile-ghost' then tiles[math.floor(e.position.x)..','..math.floor(e.position.y)]=pending[#pending] end
        for _,o in ipairs(obstacles) do add(o,e) end
      end
    end
    -- An entity ghost over tile ghosts (landfill under a pole on wetland) waits
    -- for them: the tiles go down first.
    if next(tiles) then
      for _,rec in ipairs(pending) do
        local g=rec.ghost
        if g.type=='entity-ghost' then
          local b=M.box(g.ghost_prototype,g.position,g.direction)
          for x=math.floor(b.left_top.x+0.01),math.ceil(b.right_bottom.x-0.01)-1 do
            for y=math.floor(b.left_top.y+0.01),math.ceil(b.right_bottom.y-0.01)-1 do
              local t=tiles[x..','..y]
              if t then rec.under=rec.under or {}; rec.under[#rec.under+1]=t end
            end
          end
        end
      end
    end
    -- Entities marked for deconstruction are mined by hand, as a player
    -- clears marks without robots; contents go to the inventory.
    -- (a tile's deconstruction mark, a deconstructible-tile-proxy, is mined as its tile below: Sol 15:38, mined as an
    -- entity it ended the construct inventory_full with 73 free slots)
    -- A marked cliff goes only with cliff explosives (no hand can mine one; Sol, shift14 21:18: construct failed on 4
    -- marked cliffs, "the engine would not mine cliff-gleba (98,14.5) by hand"): left, and named in last.cliffs.
    for _,e in pairs(p.surface.find_entities_filtered{area=box,to_be_deconstructed=true}) do
      if e.valid and e.type=='cliff' then
        action.cliffs=action.cliffs or {}
        if #action.cliffs<16 then action.cliffs[#action.cliffs+1]={name=e.name,position={x=e.position.x,y=e.position.y}} end
        action.ncliffs=(action.ncliffs or 0)+1
      elseif e.valid and e.type~='entity-ghost' and e.type~='deconstructible-tile-proxy' and (e.force==p.force or e.force.name=='neutral') and e.minable and api.known(p,e) then
        add(e)
      end
    end
    -- Tiles marked for deconstruction are mined by hand too (tilemine.lua; Sol, operator 15:30: landfill on a farm with
    -- no robots there): the tile under each goes back, the product to the inventory.
    if api.tilemine then
      for _,e in pairs(p.surface.find_entities_filtered{area=box,type='deconstructible-tile-proxy',force=p.force}) do
        if e.valid and e.type=='deconstructible-tile-proxy' and api.known(p,e) then
          local x,y=math.floor(e.position.x),math.floor(e.position.y)
          local key='tile:'..x..','..y
          if not action.seen[key] then
            action.seen[key]=true
            local ok,t=pcall(function() return p.surface.get_tile(x,y).name end)
            pending[#pending+1]={ghost=e,mine=true,tile={x=x,y=y},name=ok and t or 'tile',pos={x=x+0.5,y=y+0.5},tries=0,stand_fails=0}
          end
        end
      end
    end
    assert(#pending<=MAX_GHOSTS,'more than '..MAX_GHOSTS..' ghosts; construct a smaller area')
    action.until_tick=game.tick+api.integer(a.ticks,36000,1,216000,'ticks')
    if inside_n>0 then
      local parts={}
      for k,n in pairs(inside_by) do parts[#parts+1]=n..' in '..k end
      table.sort(parts)
      action.left_out=string.format('%d ghost%s left out, inside an enemy\'s reach the map shows: %s (unsafe_goal: true builds them; avoid_enemies: false checks none)',
        inside_n,inside_n==1 and '' or 's',table.concat(parts,'; ',1,math.min(#parts,6)))
    end
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
  -- Item and crafting checks for one tick, once per ghost name and quality
  -- (and per item being crafted), however many ghosts share them.
  local function tick_cache(p)
    local items,crafts={},{}
    local c={}
    function c.item(g,quality)
      local k=g.ghost_name..'/'..quality
      local hit=items[k]
      if not hit then
        local item,wanted=item_for(p,g,quality)
        hit={item=item,wanted=wanted}; items[k]=hit
      end
      return hit.item,hit.wanted
    end
    function c.crafting(item)
      local n=crafts[item]
      if not n then n=api.crafting_count(p,item); crafts[item]=n end
      return n
    end
    -- A build changes the inventory: forget the item answers.
    function c.spent() items={} end
    return c
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
  -- A ghost turned off the axes (2.0 rails take 16 directions, curves sit at
  -- their own angle): the engine's turned box, as a centre, half extents and
  -- angle, with the box around it. nil for anything square to the axes.
  local function turned_box(g)
    local ok,b=pcall(function() return g.bounding_box end)
    if not ok or not b or not b.orientation or b.orientation==0 or b.orientation==0.5 then return nil end
    local t=b.orientation*2*math.pi
    local c,sn=math.cos(t),math.sin(t)
    local cx,cy=(b.left_top.x+b.right_bottom.x)/2,(b.left_top.y+b.right_bottom.y)/2
    local hw,hl=(b.right_bottom.x-b.left_top.x)/2,(b.right_bottom.y-b.left_top.y)/2
    local ex,ey=math.abs(c)*hw+math.abs(sn)*hl,math.abs(sn)*hw+math.abs(c)*hl
    return {cx=cx,cy=cy,ux=c,uy=sn,vx=-sn,vy=c,hw=hw,hl=hl,left_top={x=cx-ex,y=cy-ey},right_bottom={x=cx+ex,y=cy+ey}}
  end
  -- Whether an entity's (square) box meets a turned box, by separating axes.
  local function meets_turned(tb,e,margin)
    local b=e.bounding_box
    if not b then return true end
    local bx,by=(b.left_top.x+b.right_bottom.x)/2,(b.left_top.y+b.right_bottom.y)/2
    local bw,bh=(b.right_bottom.x-b.left_top.x)/2+margin,(b.right_bottom.y-b.left_top.y)/2+margin
    for _,ax in ipairs({{1,0,nil},{0,1,nil},{tb.ux,tb.uy,tb.hw},{tb.vx,tb.vy,tb.hl}}) do
      local nx,ny=ax[1],ax[2]
      local reach=ax[3] or (nx==1 and (tb.right_bottom.x-tb.left_top.x)/2 or (tb.right_bottom.y-tb.left_top.y)/2)
      if math.abs((bx-tb.cx)*nx+(by-tb.cy)*ny)>reach+bw*math.abs(nx)+bh*math.abs(ny) then return false end
    end
    return true
  end
  -- Whether an entity's box reaches the given box (edges touching count).
  local function touches(e,box,margin)
    local b=e.bounding_box
    if not b then return true end -- no box to compare: the area search found it
    local l,t,r,btm=b.left_top.x,b.left_top.y,b.right_bottom.x,b.right_bottom.y
    return l<=box.right_bottom.x+margin and r>=box.left_top.x-margin and t<=box.right_bottom.y+margin and btm>=box.left_top.y-margin
  end
  -- build_path clears trees, rocks and wild plants in its way by hand as it
  -- goes (Sonnet 10:50: it stopped at every rock of a Vulcanus line, ~5 times
  -- a shift), one at a time, standing still for the hand-mining time, as a
  -- player does; what they give goes to the inventory. It still stops for
  -- buildings, water and cliffs (the build's own refusal).
  local CLEARABLE={tree=true,plant=true,['simple-entity']=true}
  local function clear_types()
    return (script and script.active_mods and script.active_mods['space-age']) and {'tree','plant','simple-entity'} or {'tree','simple-entity'}
  end
  local function clearable(e)
    return e.valid and CLEARABLE[e.type] and e.minable and (not e.force or e.force.name=='neutral')
  end
  -- The nearest one whose box meets the belt's on this tile (margin widens it).
  function M.in_the_way(p,action,cell,margin)
    local ep=prototypes.entity and prototypes.entity[action.entity_name]
    local box=M.box(ep or {},cell.position,cell.direction)
    local m=margin+0.1
    local area={left_top={x=box.left_top.x-m,y=box.left_top.y-m},right_bottom={x=box.right_bottom.x+m,y=box.right_bottom.y+m}}
    local best,bd
    for _,e in pairs(p.surface.find_entities_filtered{area=area,type=clear_types(),force='neutral'}) do
      if clearable(e) and touches(e,box,margin) then
        local d=api.distance(p.position,e.position)
        if not bd or d<bd then best,bd=e,d end
      end
    end
    return best
  end
  -- The nearest one across the character's next 3 tiles toward target.
  function M.walk_obstacle(p,target)
    local from=p.position
    local dx,dy=target.x-from.x,target.y-from.y
    local len=(dx*dx+dy*dy)^0.5
    if len<0.01 then return nil end
    local ux,uy=dx/len,dy/len
    local ahead=math.min(3,len)
    local tx,ty=from.x+ux*ahead,from.y+uy*ahead
    local area={left_top={x=math.min(from.x,tx)-1.5,y=math.min(from.y,ty)-1.5},right_bottom={x=math.max(from.x,tx)+1.5,y=math.max(from.y,ty)+1.5}}
    local best,bd
    for _,e in pairs(p.surface.find_entities_filtered{area=area,type=clear_types(),force='neutral'}) do
      if clearable(e) then
        local b=e.bounding_box
        local half=b and math.max(b.right_bottom.x-b.left_top.x,b.right_bottom.y-b.left_top.y)/2 or 0.5
        local ex,ey=e.position.x-from.x,e.position.y-from.y
        local along,across=ex*ux+ey*uy,math.abs(ex*uy-ey*ux)
        if along>-half and along<ahead+half and across<half+0.4 then
          local d=(ex*ex+ey*ey)^0.5
          if not bd or d<bd then best,bd=e,d end
        end
      end
    end
    return best
  end
  -- Mine e: in reach, start the hand-mining time; else walk next to it with
  -- the pathfinder (round the cliffs or buildings beside it; Vulcanus: a rock
  -- in a pocket of cliffs), then straight at it for the last steps (blocked
  -- after 120 ticks without getting half a tile closer).
  function M.clear(p,action,e)
    action.best_gap=nil
    if p.can_reach_entity(e) then
      action.nav=nil
      p.walking_state={walking=false,direction=0}
      action.mining={entity=e,done_tick=game.tick+api.hand_mining_ticks(p,e)}
      action.approach=nil
      return nil
    end
    local pos=e.position
    local nav=action.nav
    if not (nav and nav.clearing) then
      local a=action.approach
      if a and a.x==pos.x and a.y==pos.y then
        local d=api.distance(p.position,pos)
        if d<a.best-0.5 then a.best=d; a.tick=game.tick end
        if game.tick-a.tick>=120 then
          action.error=string.format('could not get within reach of %s at (%g,%g) in the way of tile %d to mine it: walking made no progress for 120 ticks',
            e.name,pos.x,pos.y,action.next_index)
          return 'blocked'
        end
        api.steer(p,pos,action)
        return nil
      end
      nav={position={x=pos.x,y=pos.y},tolerance=1.5,max_stalls=6,replans=0,stalled=0,last_position=p.position,clearing=true,entity=e}
      action.nav=nav
      api.request_path(p,nav)
    end
    local outcome=api.navigate(p,nav)
    if not outcome then return nil end
    action.nav=nil
    p.walking_state={walking=false,direction=0}
    if outcome~='arrived' and outcome~='arrived_near' then
      action.error=string.format('could not walk within reach of %s at (%g,%g) in the way of tile %d to mine it: %s',e.name,pos.x,pos.y,action.next_index,outcome)
      return 'blocked'
    end
    action.approach={x=pos.x,y=pos.y,best=api.distance(p.position,pos),tick=game.tick}
    return nil
  end
  -- The mining under way: done when its time is up (counted by name); an
  -- inventory with no room for what it gives ends the build (inventory_full).
  function M.mine_tick(p,action)
    local m=action.mining
    p.walking_state={walking=false,direction=0}
    local e=m.entity
    if not (e and e.valid) then action.mining=nil; return nil end
    if game.tick<m.done_tick then return nil end
    action.mining=nil
    local name,pos=e.name,e.position
    if p.mine_entity(e,false) and not e.valid then
      action.mined=(action.mined or 0)+1
      action.mined_names=action.mined_names or {}
      action.mined_names[name]=(action.mined_names[name] or 0)+1
      action.best_gap=nil
      return nil
    end
    local inv=p.get_main_inventory and p.get_main_inventory()
    if inv and inv.count_empty_stacks and inv.count_empty_stacks()>0 then
      action.error=string.format('mining %s at (%g,%g) did not take it',name,pos.x,pos.y)
      return 'build_failed'
    end
    action.error=string.format('inventory full: mining %s at (%g,%g) left it standing (no room for what it gives)',name,pos.x,pos.y)
    return 'inventory_full'
  end
  -- What build_path cleared: "big-volcanic-rock*2 tree-08*1", most first.
  function M.cleared_line(action)
    if not action.mined_names then return nil end
    local list={}
    for name,n in pairs(action.mined_names) do list[#list+1]={name=name,n=n} end
    table.sort(list,function(x,y) return x.n>y.n or (x.n==y.n and x.name<y.name) end)
    local parts={}
    for i,o in ipairs(list) do parts[i]=o.name..'*'..o.n end
    return table.concat(parts,' ')
  end
  -- Trees and rocks under a ghost get deconstruction marks, as the game marks
  -- them when a player places ghosts over them. Any whose box reaches the
  -- placement box counts, edges touching included (request #167: tree-08s
  -- whose collision box only met a belt ghost's edge were missed by a search
  -- inside the footprint, and construct ended with the ghost still blocked).
  -- margin widens that (a build that failed looks a little further).
  -- Cliffs under it get the mark too, as a player's ghost placement gives them
  -- once cliff explosives are researched (Sol 12:20: 6 belts over cliffs that
  -- nothing would ever clear); a marked cliff goes only with one explosive.
  -- Returns every marked obstacle, how many were newly marked, and the cliffs
  -- under it that carry the mark.
  function M.mark_obstacles(p,g,margin)
    margin=margin or 0.01
    local found,marked={},0
    local box=placement_box(g)
    -- A turned rail ghost: the trees and rocks its own turned box meets.
    local turned=turned_box(g)
    if turned then box={left_top=turned.left_top,right_bottom=turned.right_bottom} end
    local area={left_top={x=box.left_top.x-1.5,y=box.left_top.y-1.5},right_bottom={x=box.right_bottom.x+1.5,y=box.right_bottom.y+1.5}}
    for _,e in pairs(p.surface.find_entities_filtered{area=area,type=((script and script.active_mods['space-age']) and {'tree','plant','simple-entity'} or {'tree','simple-entity'}),force='neutral'}) do
      if e.valid and e.minable and touches(e,box,margin) and (not turned or meets_turned(turned,e,margin)) then
        -- The engine takes a LuaPlayer or nothing: a bot or map-view proxy
        -- here fails with "Invalid PlayerIdentification".
        if not e.to_be_deconstructed() and e.order_deconstruction(p.force,api.real(p)) then marked=marked+1 end
        if e.to_be_deconstructed() then found[#found+1]=e end
      end
    end
    local cliffs={}
    local tech=p.force.technologies and p.force.technologies['cliff-explosives']
    if tech and tech.researched then
      for _,e in ipairs(M.cliffs_under(p.surface,g,box,turned,margin)) do
        if not e.to_be_deconstructed() then pcall(e.order_deconstruction,p.force,api.real(p)) end
        if e.to_be_deconstructed() then cliffs[#cliffs+1]=e end
      end
    end
    return found,marked,cliffs
  end
  -- The cliffs a ghost stands over: the ones the engine finds in its own box whose collision mask meets the ghost's, as
  -- the dry run counts them (dryrun.lua). A cliff's box is turned (orientation 0.125 on Gleba's diagonals); read as
  -- square, the box of one that no ghost touched met a belt's, and placements marked cliffs the dry run had not listed
  -- (Sol, shift14 21:17: a belt_route marked (98,14.5), a place_ghosts (94,26.5) and (94,34.5); on a copy of world n a
  -- hand build fit on every tile next to them with them standing, and the engine found none in any ghost's box).
  function M.cliffs_under(surface,g,box,turned,margin)
    local mask=(pcall(function() return g.ghost_prototype.collision_mask.layers end)) and g.ghost_prototype.collision_mask.layers or nil
    local out={}
    for _,e in pairs(surface.find_entities_filtered{area=box,type='cliff'}) do
      local okm,el=pcall(function() return e.prototype.collision_mask.layers end)
      local meets=not mask or not okm
      if not meets then for layer in pairs(el) do if mask[layer] then meets=true; break end end end
      if e.valid and meets and (not turned or meets_turned(turned,e,margin or 0.01)) then out[#out+1]=e end
    end
    return out
  end
  -- Trees and rocks a tile ghost cannot go under (Sol, shift10: a slipstack on
  -- Gleba wetland kept landfill out). 2.0.77: Gleba's slipstack, cuttlepop,
  -- hairyclubnub and the stromatolites have ground_tile in their collision
  -- mask, so landfill (a ground_tile) collides with them; Nauvis trees do not,
  -- and tiles go in under them. Those on the tile are marked for
  -- deconstruction, as the game marks them for a player's tile ghost, and the
  -- tile waits until they are mined. Water-cane has ground_tile too but is not
  -- protected_from_tile_building: the tile takes it away (bots.lua
  -- place_tiles), so it is left standing. An edge that only touches the tile
  -- counts: the engine's tile check counted it on three sides of four.
  function M.tile_obstacles(p,g)
    local ok,tl=pcall(function() return g.ghost_prototype.collision_mask.layers end)
    if not ok or not tl then return {} end
    local x,y=math.floor(g.position.x),math.floor(g.position.y)
    local box={left_top={x=x,y=y},right_bottom={x=x+1,y=y+1}}
    local found={}
    for _,e in pairs(p.surface.find_entities_filtered{area={{x-1.5,y-1.5},{x+2.5,y+2.5}},type={'tree','plant','simple-entity'},force='neutral'}) do
      local okp,prot=pcall(function() return e.prototype.protected_from_tile_building end)
      if e.valid and e.minable and touches(e,box,0) and not (okp and prot==false) then
        local okm,el=pcall(function() return e.prototype.collision_mask.layers end)
        local hits=false
        for layer in pairs(okm and el or {}) do if tl[layer] then hits=true end end
        if hits then
          if not e.to_be_deconstructed() then e.order_deconstruction(p.force,api.real and api.real(p) or nil) end
          if e.to_be_deconstructed() then found[#found+1]=e end
        end
      end
    end
    return found
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
  -- The same read-only gate for place_ghosts and its dry run. Trees/rocks
  -- retain the existing fallback for engine checks that refuse soft obstacles.
  function M.ghost_placeable(surface, force, proto, pos, direction)
    return surface.can_place_entity{name=proto.name,position=pos,direction=direction,force=force,
      build_check_type=defines.build_check_type.manual_ghost,forced=true}
      or M.only_obstacles(surface,proto,pos,direction)
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
        -- The ghost of this entity on this centre is what the build revives.
        elseif e.type=='entity-ghost' and e.ghost_name==proto.name and math.abs(e.position.x-pos.x)<0.01 and math.abs(e.position.y-pos.y)<0.01 then
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
  -- live: the pending entries still valid.
  local function can_stand(p,live,pos)
    for _,rec in ipairs(live) do
      local q=pos_of(rec)
      if math.abs(q.x-pos.x)<6 and math.abs(q.y-pos.y)<6 and rec.ghost.type~='tile-ghost' and on_footprint(rec.ghost,pos,0.3) then return false end
    end
    -- Belts carry a standing character off its stand point.
    if p.surface.count_entities_filtered{area={{pos.x-0.4,pos.y-0.4},{pos.x+0.4,pos.y+0.4}},type=BELTS,limit=1}>0 then return false end
    return p.surface.can_place_entity{name=p.character and p.character.name or 'character',position=pos,force=p.force}
  end
  -- A ghost that failed once is retried only after the character moved, since
  -- the usual cause is the character itself or an entity it was about to clear.
  -- here: the character's position this tick.
  local function buildable(p,rec,here)
    local g,pos=rec.ghost,pos_of(rec)
    if rec.tile then return api.tilemine.in_reach(p,rec.tile.x,rec.tile.y) and api.visible(p,pos) end
    if rec.mine then
      -- Hand reach is to the entity's edge; nothing farther than this can be in it.
      return api.distance(here,pos)<=reach(p,rec)+4 and p.can_reach_entity(g) and api.visible(p,pos)
    end
    return api.distance(here,pos)<=reach(p) and api.visible(p,pos) and not obstructed(rec)
      and not (rec.blocked_at and api.distance(here,rec.blocked_at)<1)
      and (g.type=='tile-ghost' or not on_footprint(g,here,0.2))
  end
  -- Honest completion: ghosts skipped for lack of items or failures mean the
  -- area is not done, whatever else was built.
  local function finished(action)
    return (next(action.missing) or #action.failed>0) and 'incomplete' or 'constructed'
  end
  local function drop(action,i) action.pending[i].dropped=true; action.pending[i]=action.pending[#action.pending]; action.pending[#action.pending]=nil end
  -- Tile ghosts under this entity ghost still to be laid by this construct.
  local function awaits_tiles(rec)
    for _,t in ipairs(rec.under or {}) do if not t.dropped and t.ghost.valid then return true end end
    return false
  end
  local function fail(action,rec,err)
    local g=rec.ghost
    action.failed[#action.failed+1]={name=rec.tile and rec.name or g.valid and (rec.mine and g.name or g.ghost_name) or nil,
      position=rec.tile or rec.position or rec.ghost.position,error=err}
  end
  -- Candidates ring the target at two radii plus the in-reach point on the
  -- straight line toward the character. Coverage wins; walking distance only
  -- breaks ties (16 tiles, the ring's diameter, is worth one ghost).
  -- The valid entries and their reaches are read once per search, not once
  -- per candidate.
  local function stand_point(p,action,target,here)
    local gp,r=pos_of(target),reach(p,target)
    local far=target.mine and r or r-1.5
    local candidates={}
    local dx,dy=here.x-gp.x,here.y-gp.y
    local d=math.sqrt(dx*dx+dy*dy)
    if d>0 then candidates[1]={x=gp.x+dx/d*math.min(far,d),y=gp.y+dy/d*math.min(far,d)} end
    for k=0,15 do
      local angle=k*math.pi/8
      for _,radius in ipairs{far,far/2} do
        candidates[#candidates+1]={x=gp.x+math.cos(angle)*radius,y=gp.y+math.sin(angle)*radius}
      end
    end
    local live={}
    for _,rec in ipairs(action.pending) do if rec.ghost.valid then live[#live+1]=rec end end
    local build_reach,mine_reach=reach(p)-1,reach(p,{mine=true})
    local best,best_score
    for _,c in ipairs(candidates) do
      local ok=not (target.blocked_at and api.distance(c,target.blocked_at)<1.5)
      for _,bad in ipairs(target.bad_stands or {}) do if api.distance(c,bad)<1.5 then ok=false end end
      if ok and can_stand(p,live,c) then
        local cover=0
        for _,rec in ipairs(live) do
          if api.distance(c,pos_of(rec))<=(rec.mine and mine_reach or build_reach) then cover=cover+1 end
        end
        local score=cover-api.distance(here,c)/16
        if not best_score or score>best_score then best,best_score=c,score end
      end
    end
    return best
  end
  -- Drop the entries in a set, in one pass.
  local function drop_set(action,set)
    if next(set)==nil then return end
    local keep={}
    for _,rec in ipairs(action.pending) do if not set[rec] then keep[#keep+1]=rec else rec.dropped=true end end
    action.pending=keep
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
    if rec.tile then
      local row,why=api.tilemine.mine(p,rec.tile.x,rec.tile.y)
      if row then action.tiles_mined=(action.tiles_mined or 0)+1; drop(action,index_of(action,rec)); return end
      fail(action,rec,why); drop(action,index_of(action,rec))
      return why=='inventory_full' and 'inventory_full' or nil
    end
    if p.mine_entity(e,false) and not e.valid then action.mined=action.mined+1; drop(action,index_of(action,rec)); return end
    -- inventory_full only when a product has no room (Sol 15:38: said with 73 free slots); else the engine would not
    -- mine it by hand, named, and the rest goes on.
    local full
    local okp,prods=pcall(function() return e.prototype.mineable_properties.products end)
    for _,pr in ipairs(okp and prods or {}) do
      if (pr.type==nil or pr.type=='item') and not p.can_insert{name=pr.name,count=pr.amount or pr.amount_max or 1} then full=pr.name; break end
    end
    if full then
      fail(action,rec,'inventory_full: no room for '..full); drop(action,index_of(action,rec))
      return 'inventory_full'
    end
    fail(action,rec,string.format('the engine would not mine %s (%g,%g) by hand (a stump, remnant or the like)',e.name,e.position.x,e.position.y))
    drop(action,index_of(action,rec))
  end
  function M.tick_ghosts(p,action)
    if not action.pending then return 'interrupted' end -- started by an older bundle
    if action.mining then
      local busy=tick_mining(p,action)
      if busy=='inventory_full' then stop(p); return 'inventory_full' end
      if busy then stop(p); return end
    end
    -- Waiting in reach for a hand craft: look again every LOOK_EVERY ticks
    -- (a pipe takes 30 to craft), not on every tick.
    if action.awaiting_craft and game.tick<(action.next_look or 0) then return end
    -- Deconstruction cancelled meanwhile: leave those entities alone.
    if game.tick>=(action.next_marks or 0) then
      action.next_marks=game.tick+30
      local cancelled={}
      for _,rec in ipairs(action.pending) do
        -- (a tile's mark is its proxy: gone when cancelled)
        if rec.mine and not rec.tile and rec.ghost.valid and not rec.ghost.to_be_deconstructed() then cancelled[rec]=true end
      end
      drop_set(action,cancelled)
    end
    local here=p.position
    local cache=tick_cache(p)
    local placed,waiting=0,false
    for i=#action.pending,1,-1 do
      local rec=action.pending[i]
      local g=rec.ghost
      if not g.valid then action.gone=action.gone+1; drop(action,i)
      elseif rec.tile then
        if not action.mining and buildable(p,rec,here) then
          local info=api.tilemine.check(p,rec.tile.x,rec.tile.y)
          if info.why then fail(action,rec,info.why); drop(action,i)
          else action.mining={rec=rec,done_tick=game.tick+info.ticks} end
        end
      elseif rec.mine then
        if not action.mining and buildable(p,rec,here) then action.mining={rec=rec,done_tick=game.tick+api.hand_mining_ticks(p,g)} end
      elseif buildable(p,rec,here) and not (rec.under and awaits_tiles(rec)) then
        if placed>=PER_TICK then waiting=true; break end
        local quality=g.quality and g.quality.name or 'normal'
        local item,wanted=cache.item(g,quality)
        if not item then
          -- Items still in the hand-crafting queue are awaited, not missing.
          if cache.crafting(wanted)==0 then action.missing[wanted]=(action.missing[wanted] or 0)+1; drop(action,i) end
        else
          rec.position=pos_of(rec)
          local tile=g.type=='tile-ghost'
          -- A rail planner places several rails: name the ghost's.
          local ip=prototypes and prototypes.item and prototypes.item[item]
          local rails_ok,rails=pcall(function() return ip and ip.rails end)
          local planner=rails_ok and type(rails)=='table' and #rails>0
          local ok,err=pcall(api.build,p,{item=item,quality=quality,position=rec.position,direction=not tile and compass[g.direction] or nil,
            entity=planner and g.ghost_name or nil})
          placed=placed+1
          cache.spent()
          if ok and not g.valid then action.built=action.built+1; drop(action,i)
          else
            -- A tree or rock the build could not get past: mark and mine that
            -- one, then build again (no try spent on it).
            local fresh=0
            for _,o in ipairs(tile and M.tile_obstacles(p,g) or M.mark_obstacles(p,g,0.3)) do
              if add_mine(action,o,g) then
                fresh=fresh+1
                rec.obstacles=rec.obstacles or {}
                rec.obstacles[#rec.obstacles+1]=o
              end
            end
            if fresh>0 then rec.blocked_at=nil; goto next_ghost end
            rec.tries=rec.tries+1
            if rec.tries>=2 then fail(action,rec,ok and 'ghost remained' or api.reason(err)); drop(action,i)
            else rec.blocked_at={x=here.x,y=here.y} end
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
        if rec.ghost.valid and api.distance(nav.position,pos_of(rec))<=reach(p,rec)-(rec.mine and 0 or 1) then covered=rec; break end
      end
      -- No stand point left: drop the walk too, or the next tick indexes a nil target.
      nav.target=covered
      if not covered then action.nav=nil; nav=nil end
    end
    if nav then
      local outcome=api.navigate(p,nav)
      -- legs round the worms and spawners (C2): the next one starts where one ends
      if outcome and nav.foes and api.leg_done and api.leg_done(p,nav,outcome) then return end
      if not outcome then return end
      local target=nav.target
      action.nav=nil
      if outcome~='arrived' or not buildable(p,target,p.position) then
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
    -- reach where the character stands). One pass sorts every entry, with
    -- the item checks cached per item: shift01's 255 pipe ghosts awaiting
    -- their craft redid a full search per ghost on every tick, and the
    -- world ran at 9 ticks/s.
    action.awaiting_craft=nil
    local ready,crafting,missing={},{},{}
    for _,rec in ipairs(action.pending) do
      if rec.ghost.valid then
        local d=api.distance(here,pos_of(rec))
        if rec.mine then ready[#ready+1]={rec=rec,d=d}
        elseif not obstructed(rec) then
          local g=rec.ghost
          local item,wanted=cache.item(g,g.quality and g.quality.name or 'normal')
          if item then ready[#ready+1]={rec=rec,d=d}
          elseif cache.crafting(wanted)>0 then crafting[#crafting+1]={rec=rec,d=d}
          else missing[#missing+1]={rec=rec,d=d,wanted=wanted} end
        end
      end
    end
    local gone={}
    local function nearest(list)
      local best
      for _,c in ipairs(list) do if not gone[c.rec] and (not best or c.d<best.d) then best=c end end
      return best
    end
    while true do
      local best=nearest(ready)
      -- A ghost with no item and none crafting, nearer than the next walk
      -- (every one, when nothing is left to walk to), is reported missing.
      for _,m in ipairs(missing) do
        if not gone[m.rec] and (not best or m.d<best.d) then
          gone[m.rec]=true; action.missing[m.wanted]=(action.missing[m.wanted] or 0)+1
        end
      end
      local pick=best or nearest(crafting)
      if not pick then break end
      local rec=pick.rec
      if not best and buildable(p,rec,here) then
        drop_set(action,gone)
        action.awaiting_craft=true; action.next_look=game.tick+LOOK_EVERY
        stop(p); return
      end
      local stand=stand_point(p,action,rec,here)
      if stand then
        drop_set(action,gone)
        -- Stalls re-path at once and give up after a few, since another
        -- stand point is usually a better answer than pushing on.
        action.nav={position=stand,tolerance=rec.mine and 0.4 or 1,target=rec,max_stalls=6,replan_every=1,replans=0,stalled=0,last_position=here}
        if api.distance(here,stand)>reach(p) then
          -- move_to's enemy checks on the way (C2, Opus 22:50: a construct over a far area walked him through a big
          -- worm's range from (-290,-302), and he died at (-282,-190)): legs round the worms, spawners and attacks.
          if action.avoid_mode and api.avoid_start then api.avoid_start(p,action.nav,action.avoid_mode) end
          api.request_path(p,action.nav)
        end
        return
      end
      fail(action,rec,'no free stand point in reach'); gone[rec]=true
    end
    -- Only ghosts whose obstacles could not be mined remain.
    for _,rec in ipairs(action.pending) do
      local o=not gone[rec] and obstructed(rec)
      if o then
        fail(action,rec,string.format('blocked by %s at (%g,%g), which could not be mined',o.name,o.position.x,o.position.y)); gone[rec]=true
      end
    end
    drop_set(action,gone)
    if #action.pending==0 then stop(p); return finished(action) end
  end
  return M
end
