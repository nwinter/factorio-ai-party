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
    local out={surface=p.surface.name,drill=e.name,position=pos(e.position),direction=e.direction,
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
      found=surface.find_entities_filtered{type='resource',name=resource,
        area={{e.position.x-search-r-1,e.position.y-search-r-1},{e.position.x+search+r+1,e.position.y+search+r+1}},limit=MAX_ORE+1}
      if #found<=MAX_ORE then break end
      search=math.floor(search/2)
    until search<2
    out.searched_radius=search
    out.radius_reduced=search<radius or nil
    if #found>MAX_ORE then out.truncated=true; out.line='resource read reached its 1024-tile limit; no sites evaluated'; return out end
    -- Sparse tile map; summed-area tables make every candidate's amount a
    -- constant-time read, including large drills over dense patches.
    local x0,y0=math.floor(e.position.x-search-r-1),math.floor(e.position.y-search-r-1)
    local x1,y1=math.ceil(e.position.x+search+r+1),math.ceil(e.position.y+search+r+1)
    local amounts,counts={},{}
    for _,o in ipairs(found) do
      if o.valid and seen(o.position.x,o.position.y) then
        local x,y=math.floor(o.position.x),math.floor(o.position.y)
        amounts[y]=amounts[y] or {}; counts[y]=counts[y] or {}
        amounts[y][x]=(amounts[y][x] or 0)+o.amount; counts[y][x]=(counts[y][x] or 0)+1
      end
    end
    local function at(t,x,y) return t[y] and t[y][x] or 0 end
    for y=y0,y1 do
      amounts[y]=amounts[y] or {}; counts[y]=counts[y] or {}
      for x=x0,x1 do
        for _,t in ipairs{amounts,counts} do t[y][x]=at(t,x,y)+at(t,x-1,y)+at(t,x,y-1)-at(t,x-1,y-1) end
      end
    end
    local function under(t,x,y)
      local l,top=math.ceil(x-r-0.5),math.ceil(y-r-0.5)
      local right,bottom=math.floor(x+r-0.5),math.floor(y+r-0.5)
      return at(t,right,bottom)-at(t,l-1,bottom)-at(t,right,top-1)+at(t,l-1,top-1)
    end
    local candidates={}
    local fx,fy=w%2/2,h%2/2
    for x=math.ceil(e.position.x-search-fx),math.floor(e.position.x+search-fx) do
      for y=math.ceil(e.position.y-search-fy),math.floor(e.position.y+search-fy) do
        local px,py=x+fx,y+fy
        local d=((px-e.position.x)^2+(py-e.position.y)^2)^0.5
        if d<=search and visible_box(px,py,math.max(r,w/2,h/2)) then
          local amount=under(amounts,px,py)
          if amount>0 then candidates[#candidates+1]={position={x=px,y=py},distance=d,amount=amount,tiles=under(counts,px,py)} end
        end
      end
    end
    table.sort(candidates,function(a,b)
      if a.distance~=b.distance then return a.distance<b.distance end
      if a.position.x~=b.position.x then return a.position.x<b.position.x end
      return a.position.y<b.position.y
    end)
    local checks=0
    for _,c in ipairs(candidates) do
      if checks>=MAX_CHECKS or #out.sites>=limit then break end
      checks=checks+1
      if surface.can_place_entity{name=e.name,position=c.position,direction=e.direction,quality=e.quality,force=p.force,
          build_check_type=defines.build_check_type.manual} then
        out.sites[#out.sites+1]=c
      end
    end
    out.checks=checks
    out.truncated=checks<#candidates and #out.sites<limit or nil
    out.line=string.format('%s (%g,%g): %d %s sites within %d tiles; amounts in the %.1f-tile mining radius; nearest first%s',
      e.name,e.position.x,e.position.y,#out.sites,resource,search,r,out.truncated and '; placement check limit reached' or '')
    return out
  end
  M.schema={position='required: depleted mining drill of ours',surface='optional surface name (default yours)',
    resource='optional resource entity name when the last mining target was not recorded; a recorded target must match',
    radius='2..24 (default 16); reduced on dense patches to keep the resource read at 1024 tiles',limit='1..8 sites (default 3)',
    returns='drill, position, direction, footprint, mining_radius, resource and resource_source, searched_radius, radius_reduced, sites [{position, distance, amount, tiles}], checks, truncated, line; visible mining areas only, same resource, sorted by distance; amount and tiles cover the mining area; engine manual placement check uses this drill size/direction/quality with existing entities present; sites are alternatives, not a simultaneous layout'}
  return M
end
