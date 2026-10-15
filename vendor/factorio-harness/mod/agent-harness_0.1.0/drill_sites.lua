-- Candidate centres for one depleted drill. No moves or marks; bounded live
-- reads, and the game's manual placement check with existing entities present.
return function(api)
  local M={}
  local MAX_ORE,MAX_CHECKS=1024,128
  local function pos(p) return {x=p.x,y=p.y} end
  function M.read(p,a)
    if a.surface then p=api.on_surface(p,a.surface) end
    assert(a.position,'drill_sites requires position of a depleted drill')
    local e=api.entity(p,a)
    assert(e.type=='mining-drill' and e.force==p.force,'position must name a mining drill of ours')
    assert(e.status==defines.entity_status.no_minable_resources and not (e.mining_target and e.mining_target.valid),
      'drill does not report no_minable_resources with no mining target')
    local origin=e.position
    local radius=api.integer(a.radius,16,2,24,'radius')
    local limit=api.integer(a.limit,3,1,8,'limit')
    local mem=(api.state().push_drills or {})[p.force.name] or {}
    local remembered=e.unit_number and mem[e.unit_number]
    if remembered and a.resource then assert(a.resource==remembered,'resource differs from the drill\'s last observed mining target '..remembered) end
    local resource=remembered or a.resource
    local proto=e.prototype
    local r=proto.mining_drill_radius
    assert(type(r)=='number' and r>0 and r<=16,'unsupported drill mining radius')
    local w,h=proto.tile_width,proto.tile_height
    if e.direction==4 or e.direction==12 then w,h=h,w end
    local out={surface=p.surface.name,drill=e.name,position=pos(origin),direction=e.direction,
      footprint={width=w,height=h},mining_radius=r,resource=resource,
      resource_source=remembered and 'last observed mining target' or resource and 'supplied in this call' or nil,
      radius=radius,sites={},placement_check='manual, with existing entities still present',tick=game.tick}
    if not resource then out.line='prior resource not recorded; no sites evaluated'; return out end
    local ore=type(resource)=='string' and prototypes.entity[resource]
    assert(ore and ore.type=='resource','resource must name a resource entity')
    assert(not proto.resource_categories or proto.resource_categories[ore.resource_category], 'drill cannot mine resource '..resource)
    local surface=p.surface
    local visibility={}
    local function seen(x,y)
      local cx,cy=math.floor(x/32),math.floor(y/32)
      local key=cx..','..cy
      if visibility[key]==nil then visibility[key]=p.force.is_chunk_visible(surface,{x=cx,y=cy}) end
      return visibility[key]
    end
    local function visible_box(x,y,half)
      for cx=math.floor((x-half)/32),math.floor((x+half)/32) do
        for cy=math.floor((y-half)/32),math.floor((y+half)/32) do if not seen(cx*32,cy*32) then return false end end
      end
      return true
    end
    -- A dense patch shrinks the bounded search before any resource entities are
    -- traversed. The actual radius and any reduction are explicit in the reply.
    local search=radius
    local found
    repeat
      local left,top=origin.x-search-r-1,origin.y-search-r-1
      local right,bottom=origin.x+search+r+1,origin.y+search+r+1
      found={}
      local taken={}
      for cx=math.floor(left/32),math.floor(right/32) do
        for cy=math.floor(top/32),math.floor(bottom/32) do
          if #found<=MAX_ORE and seen(cx*32,cy*32) then
            -- Hidden chunks do not affect the result or its density limit.
            for _,o in ipairs(surface.find_entities_filtered{type='resource',name=resource,
              area={{math.max(left,cx*32),math.max(top,cy*32)},{math.min(right,(cx+1)*32),math.min(bottom,(cy+1)*32)}},limit=MAX_ORE+1}) do
              local point=not taken[o] and o.valid and o.position
              if point and seen(point.x,point.y) then
                taken[o]=true;found[#found+1]={entity=o,position=point}
                if #found>MAX_ORE then break end
              end
            end
          end
        end
      end
      if #found<=MAX_ORE then break end
      search=math.floor(search/2)
    until search<2
    out.searched_radius=search
    out.radius_reduced=search<radius or nil
    if #found>MAX_ORE then out.truncated=true; out.line='resource read reached its 1024-tile limit; no sites evaluated'; return out end
    -- Sparse tile map; summed-area tables make every candidate's amount a
    -- constant-time read, including large drills over dense patches.
    local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
    local amounts,counts={},{}
    for _,o in ipairs(found) do
      local x,y=math.floor(o.position.x),math.floor(o.position.y)
      x0,y0,x1,y1=math.min(x0,x),math.min(y0,y),math.max(x1,x),math.max(y1,y)
      amounts[y]=amounts[y] or {}; counts[y]=counts[y] or {}
      amounts[y][x]=(amounts[y][x] or 0)+o.entity.amount; counts[y][x]=(counts[y][x] or 0)+1
    end
    -- Crop the prefix tables and candidate bounds to the observed ore. Sparse
    -- patches need no empty 60x60 table or visibility checks for empty centres.
    if #found==0 then
      out.checks=0;out.line='no observed '..resource..' in the searched area';return out
    end
    for y=y0,y1 do
      local ar,cr=amounts[y] or {},counts[y] or {}
      local ap,cp=amounts[y-1] or {},counts[y-1] or {}
      amounts[y],counts[y]=ar,cr
      local asum,csum=0,0
      for x=x0,x1 do
        asum,csum=asum+(ar[x] or 0),csum+(cr[x] or 0)
        ar[x],cr[x]=asum+(ap[x] or 0),csum+(cp[x] or 0)
      end
    end
    local function under(t,x,y)
      local l,top=math.max(x0,math.ceil(x-r-0.5)),math.max(y0,math.ceil(y-r-0.5))
      local right,bottom=math.min(x1,math.floor(x+r-0.5)),math.min(y1,math.floor(y+r-0.5))
      if l>right or top>bottom then return 0 end
      local last,above=t[bottom] or {},t[top-1] or {}
      return (last[right] or 0)-(last[l-1] or 0)-(above[right] or 0)+(above[l-1] or 0)
    end
    local candidates={}
    local fx,fy=w%2/2,h%2/2
    local visible_radius=math.max(r,w/2,h/2)
    for x=math.max(math.ceil(origin.x-search-fx),math.ceil(x0+.5-r-fx)),math.min(math.floor(origin.x+search-fx),math.floor(x1+.5+r-fx)) do
      for y=math.max(math.ceil(origin.y-search-fy),math.ceil(y0+.5-r-fy)),math.min(math.floor(origin.y+search-fy),math.floor(y1+.5+r-fy)) do
        local px,py=x+fx,y+fy
        local d=((px-origin.x)^2+(py-origin.y)^2)^0.5
        if d<=search then
          local amount=under(amounts,px,py)
          if amount>0 and visible_box(px,py,visible_radius) then candidates[#candidates+1]={position={x=px,y=py},distance=d,amount=amount,tiles=under(counts,px,py)} end
        end
      end
    end
    table.sort(candidates,function(a,b)
      if a.distance~=b.distance then return a.distance<b.distance end
      if a.position.x~=b.position.x then return a.position.x<b.position.x end
      return a.position.y<b.position.y
    end)
    local checks,examined=0,0
    -- A drill (or a drill's ghost) already on the footprint (Astra, d15 15:11: on Fulgora the manual placement check
    -- passed three spots each covered by a working drill): the spot is skipped and named, before the engine check.
    local occupied={}
    local function occupant(c)
      local x,y=c.position.x,c.position.y
      for _,o in ipairs(surface.find_entities_filtered{area={{x-w/2+0.05,y-h/2+0.05},{x+w/2-0.05,y+h/2-0.05}},type={'mining-drill','entity-ghost'},limit=8}) do
        if o.valid and o~=e and (o.type=='mining-drill' or o.ghost_type=='mining-drill') then return o end
      end
    end
    local box=e.bounding_box
    local bw,bh=box and box.right_bottom.x-box.left_top.x,box and box.right_bottom.y-box.left_top.y
    for _,c in ipairs(candidates) do
      if checks>=MAX_CHECKS or #out.sites>=limit then break end
      examined=examined+1
      -- Same drill and facing: translating its actual collision box into itself
      -- is already an occupied placement. Avoid repeated expensive engine checks
      -- of the drill's own footprint before the nearest free candidate.
      local overlaps=bw and bh and math.abs(c.position.x-origin.x)<bw and math.abs(c.position.y-origin.y)<bh
      local o=not overlaps and occupant(c)
      if o then
        checks=checks+1
        occupied[#occupied+1]=string.format('(%g,%g): %s%s (%g,%g)',c.position.x,c.position.y,o.type=='entity-ghost' and 'ghost of ' or '',
          o.type=='entity-ghost' and o.ghost_name or o.name,o.position.x,o.position.y)
      elseif not overlaps then
        checks=checks+1
        if surface.can_place_entity{name=e.name,position=c.position,direction=e.direction,quality=e.quality,force=p.force,
            build_check_type=defines.build_check_type.manual} then out.sites[#out.sites+1]=c end
      end
    end
    out.checks=checks
    if #occupied>0 then
      out.occupied=#occupied
      out.occupied_by={}
      for i=1,math.min(3,#occupied) do out.occupied_by[i]=occupied[i] end
    end
    out.truncated=examined<#candidates and #out.sites<limit or nil
    out.line=string.format('%s (%g,%g): %d %s sites within %d tiles; amounts in the %.1f-tile mining radius; nearest first%s',
      e.name,origin.x,origin.y,#out.sites,resource,search,r,out.truncated and '; placement check limit reached' or '')
      ..(#occupied>0 and string.format('; %d nearer spot%s left out: a drill stands there (%s)',#occupied,#occupied==1 and '' or 's',table.concat(out.occupied_by,'; ')) or '')
    return out
  end
  function M.group(force,g)
    if not g.drill or not g.ore or g.ore=='unknown' then return nil end
    local surface=game.surfaces[g.surface];if not surface then return nil end
    local q=g.drill.position
    if not force.is_chunk_visible(surface,{x=math.floor(q.x/32),y=math.floor(q.y/32)}) then return nil end
    local st=api.state();st.drill_site_cache=st.drill_site_cache or {entries={},order={}}
    local cache=st.drill_site_cache
    local key=force.name..'|'..g.key..'|'..tostring(g.drill.unit_number)..'|'..g.ore
    local old=cache.entries[key]
    if old and game.tick-old.tick<3600 then return old end
    local p={force=force,surface=surface,position=q,__remote=true}
    local result=M.read(p,{position=q,name=g.drill.name,unit_number=g.drill.unit_number,resource=g.ore,radius=24,limit=1})
    local out={tick=game.tick,drill=result.drill,origin=result.position,radius=result.searched_radius or result.radius,
      site=result.sites[1],truncated=result.truncated,radius_reduced=result.radius_reduced}
    if not cache.entries[key] then
      if #cache.order>=128 then cache.entries[table.remove(cache.order,1)]=nil end
      cache.order[#cache.order+1]=key
    end
    cache.entries[key]=out;return out
  end
  M.schema={position='required: depleted mining drill of ours',surface='optional surface name (default yours)',
    resource='optional resource entity name when the last mining target was not recorded; a recorded target must match',
    radius='2..24 (default 16); reduced on dense patches to keep the resource read at 1024 tiles',limit='1..8 sites (default 3)',
    returns='drill, position, direction, footprint, mining_radius, resource and resource_source, searched_radius, radius_reduced, sites [{position, distance, amount, tiles}], checks, truncated, occupied and occupied_by (spots left out because a drill or a drill ghost stands on them, the first 3 named), line; visible mining areas only, same resource, sorted by distance; amount and tiles cover the mining area; engine manual placement check uses this drill size/direction/quality with existing entities present; sites are alternatives, not a simultaneous layout'}
  return M
end
