-- A no_safe_route diagnostic. It never drives the character: engine paths are
-- requested from virtual positions and every segment is checked against charted
-- hazards. Integer margins below the requested margin are tried in descending
-- order. A failed bounded search is not a proof that no route exists.
return function(api)
  local M={}
  local A=api.avoid
  M.MAX_REQUESTS,M.MAX_TICKS,M.MAX_HAZARDS=192,1800,32
  local function dist(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local function point(p) return {x=p.x,y=p.y} end
  local function finish(q,line)
    q.done=true; q.id=nil
    q.result=q.result or {requested_margin=q.requested,tested=q.tested,from=q.origin,to=q.goal}
    q.result.line=line
  end
  local function failed(q,why)
    q.tested[#q.tested+1]={margin=q.pad,reason=why}
    q.pad=q.pad-1; q.route=nil; q.path=nil; q.id=nil; q.closest=nil; q.gi=1; q.leg_from=nil
  end
  local function read(p,points,mode)
    local chunks=A.chunks_near(points,48+mode.pad)
    local missing=A.missing(p.surface,chunks)
    if #missing>0 then A.scan(p.surface,p.force,missing,A.CHUNKS_PER_TICK); return nil end
    return A.blobs(p.surface,chunks,mode)
  end
  function M.on_path(nav,event)
    local q=nav.margin_probe
    if not q or q.id~=event.id then return false end
    q.id=nil
    if event.try_again_later then q.retry=game.tick+30
    elseif not event.path or #event.path==0 then failed(q,'engine found no path for a diagnostic leg')
    else q.path=event.path end
    return true
  end
  -- The goals to verify: the leg's goal, and on a walk through via points (Opus, d15: the NE uranium route, 4 times) the
  -- via points after it and the final position, so a margin is verified for the rest of the chain.
  local function goals_of(nav,f)
    local out={point(f.goal)}
    local v=nav.via
    if v and v.index then
      for i=v.index+1,#v.points do out[#out+1]=point(v.points[i]) end
      if v.index<=#v.points and v.final then out[#out+1]=point(v.final) end
    end
    return out
  end
  -- The mode at the margin tried: a numeric margin (pad) or a {distance: N} (each worm and spawner N tiles away).
  local function mode_at(f,q)
    if q.distance then return {spawners=f.mode.spawners,attacks=f.mode.attacks,pad=0,distance=q.pad,strict=true} end
    return {spawners=f.mode.spawners,attacks=f.mode.attacks,pad=q.pad,strict=true}
  end
  function M.tick(p,nav)
    local f=nav.foes
    if not f or nav.vehicle then return false end
    local q=nav.margin_probe
    if not q then
      local dist_mode=f.mode.distance~=nil
      local goals=goals_of(nav,f)
      q={requested=dist_mode and f.mode.distance or f.mode.pad,distance=dist_mode or nil,
        pad=dist_mode and math.ceil(f.mode.distance)-1 or math.ceil(f.mode.pad)-1,origin=point(p.position),goal=goals[#goals],goals=goals,gi=1,
        since=game.tick,requests=0,tested={}}
      nav.margin_probe=q
    end
    if q.done then return false end
    if dist(p.position,q.origin)>0.25 then finish(q,'smaller-margin check stopped: character moved from the checked start'); return false end
    if game.tick-q.since>M.MAX_TICKS or q.requests>=M.MAX_REQUESTS then
      finish(q,'smaller-margin check reached its budget; no complete route verified'); return false
    end
    if q.pad<(q.distance and 4 or 0) then finish(q,'no complete route verified at the smaller '..(q.distance and 'distances' or 'integer margins')..' tested'); return false end
    if q.id or (q.retry and game.tick<q.retry) then return true end
    q.retry=nil
    local mode=mode_at(f,q)
    if not q.route then
      local start=q.leg_from or q.origin
      local target=q.goals[q.gi]
      local blobs=read(p,{start,target},mode)
      if not blobs then return true end
      local count=0
      for _,b in ipairs(blobs) do count=count+#b.members end
      if count>M.MAX_HAZARDS then finish(q,'smaller-margin check exceeds 32 nearby charted hazards; no complete route verified'); return false end
      local route=A.route(start,target,blobs,{},true)
      if not route then failed(q,'no geometric route found outside clearance'..(#q.goals>1 and ' (leg '..q.gi..' of the '..#q.goals..' left)' or '')); return true end
      q.route=route; q.leg=1; q.from=point(start)
      if q.gi==1 then q.via={}; q.length=0 end
    end
    if q.path then
      local pts={q.from}
      for _,w in ipairs(q.path) do pts[#pts+1]=w.position end
      local blobs=read(p,pts,mode)
      if not blobs then return true end
      local _,m=A.crossing(pts,blobs,{})
      if m then failed(q,'engine path crosses requested clearance of '..m.name); return true end
      local last=pts[#pts]
      if dist(last,q.route[q.leg])>0.35 then failed(q,'engine path ends short of diagnostic leg'); return true end
      for i=2,#pts do
        q.length=q.length+dist(pts[i-1],pts[i])
        for _,bl in ipairs(blobs) do for _,h in ipairs(bl.members) do
          local d=A.seg_dist(pts[i-1],pts[i],h)
          if not q.closest or d-h.range<q.closest.clearance then
            q.closest={name=h.name,position={x=h.x,y=h.y},nest=A.name(bl),distance=d,range=h.range,clearance=d-h.range}
          end
        end end
      end
      q.from=point(last); q.via[#q.via+1]=point(last); q.leg=q.leg+1; q.path=nil
      if q.leg>#q.route and q.gi<#q.goals then
        -- The next goal of the chain from here.
        q.gi=q.gi+1; q.leg_from=point(last); q.route=nil
        return true
      end
      if q.leg>#q.route then
        q.tested[#q.tested+1]={margin=q.pad,verified=true}
        local word=q.distance and 'distance' or 'integer margin'
        q.result={requested_margin=not q.distance and q.requested or nil,requested_distance=q.distance and q.requested or nil,
          largest_verified_margin=not q.distance and q.pad or nil,largest_verified_distance=q.distance and q.pad or nil,
          legs=#q.goals,tested=q.tested,closest=q.closest,from=q.origin,to=q.goal,via=q.via,length=q.length,
          method='engine paths, every segment checked against charted hazards; descending '..word..'s; '..(#q.goals>1 and 'every leg left in the chain' or 'remaining leg only')}
        local close=q.closest
        finish(q,string.format('largest smaller %s with a verified route: %g%s; %s (%g,%g) to (%g,%g)%s',word,q.pad,
          q.distance and string.format(' (avoid_enemies {distance: %g})',q.pad) or string.format(' (avoid_enemies %g)',q.pad),
          #q.goals>1 and string.format('the %d legs left in the via chain',#q.goals) or 'remaining leg',
          q.origin.x,q.origin.y,q.goal.x,q.goal.y,close and string.format('; closest clearance: %s at (%g,%g), %.2f tiles away (reach %g, clearance %.2f)',
            close.name,close.position.x,close.position.y,close.distance,close.range,close.clearance) or '; no charted hazard near the route'))
        return false
      end
    end
    local c=p.character
    local box=c.prototype.collision_box
    local h=0.35
    if box and box.left_top then h=math.max(h,math.abs(box.left_top.x),math.abs(box.left_top.y),math.abs(box.right_bottom.x),math.abs(box.right_bottom.y)) end
    q.id=p.surface.request_path{bounding_box={{-h,-h},{h,h}},collision_mask=c.prototype.collision_mask,
      start=q.from,goal=q.route[q.leg],radius=0.1,force=p.force,entity_to_ignore=c,can_open_gates=true,
      path_resolution_modifier=-2,pathfind_flags={prefer_straight_paths=true,cache=false}}
    api.paths()[q.id]=p.index; q.requests=q.requests+1
    return true
  end
  return M
end
