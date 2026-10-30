-- Underground belt connections after the request's placeable ghosts are built.
-- Reads only each end's tunnel corridor, including existing ghosts, and caches
-- those ends and tile masks for this call. No entities are created or rotated.
return function(api)
  local M = {}
  local STEP = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
  local function key(p) return p.x..','..p.y end
  local function at(p) return string.format('(%g,%g)',p.x,p.y) end
  local function toward(e) return (e.dir+(e.kind=='output' and 8 or 0))%16 end
  function M.check(p,recs,details)
    local planned,ends,known,tiles = {},{},{},{}
    local function make(name,pos,dir,kind,extra)
      local e=extra or {}
      e.name,e.pos,e.dir,e.kind=name,pos,dir,kind
      e.reach=prototypes.entity[name].max_underground_distance or 0
      return e
    end
    for _,r in ipairs(recs) do
      if r.proto and r.proto.type=='underground-belt' and r.pos and r.status~='blocked' and not r.refused then
        local e=make(r.name,r.pos,r.dir,r.ug_type or 'input',{index=r.copy and (r.copy..'.'..r.index) or r.index})
        if r.status=='exists' then
          local f={position=r.pos,name=r.name,force=p.force}
          local o=p.surface.find_entities_filtered(f)[1]
          if not o then f.name=nil; f.ghost_name=r.name; o=p.surface.find_entities_filtered(f)[1] end
          if o then e.dir,e.kind=o.direction,o.belt_to_ground_type end
        end
        planned[key(r.pos)]=e; ends[#ends+1]=e
      end
    end
    if #ends==0 then return nil end
    local function visible(pos) return not api.charted or api.charted(p,pos) end
    local function existing(o)
      if not o.valid or not visible(o.position) then return nil end
      local ghost=o.type=='entity-ghost'
      local name=ghost and o.ghost_name or o.name
      local k=key(o.position)
      if planned[k] then return planned[k] end
      if not known[k] then known[k]=make(name,o.position,o.direction,o.belt_to_ground_type,{source=ghost and 'ghost' or 'built'}) end
      return known[k]
    end
    local nearest={}
    local function next_end(e)
      if nearest[e] then return nearest[e].other,nearest[e].why end
      local d=toward(e); local step=STEP[d]
      if not step then nearest[e]={why='non-cardinal direction'}; return nil,'non-cardinal direction' end
      local x,y=e.pos.x,e.pos.y
      local ex,ey=x+step[1]*e.reach,y+step[2]*e.reach
      local area={left_top={x=math.min(x,ex)-0.1,y=math.min(y,ey)-0.1},right_bottom={x=math.max(x,ex)+0.1,y=math.max(y,ey)+0.1}}
      local candidates={}
      for _,o in pairs(p.surface.find_entities_filtered{area=area,name=e.name,force=p.force}) do
        local q=existing(o); if q then candidates[#candidates+1]=q end
      end
      for _,o in pairs(p.surface.find_entities_filtered{area=area,ghost_name=e.name,force=p.force}) do
        local q=existing(o); if q then candidates[#candidates+1]=q end
      end
      for k=1,e.reach do
        local q=planned[key({x=x+step[1]*k,y=y+step[2]*k})]
        if q then candidates[#candidates+1]=q end
      end
      local other,dist=nil,e.reach+1
      for _,q in ipairs(candidates) do
        local dx,dy=q.pos.x-x,q.pos.y-y
        local k=dx*step[1]+dy*step[2]
        if q~=e and q.name==e.name and q.dir%8==e.dir%8 and dx*step[2]==dy*step[1] and k>0 and k<dist then other,dist=q,k end
      end
      local why
      for k=1,math.min(e.reach,dist-1) do
        local pos={x=x+step[1]*k,y=y+step[2]*k}
        if not visible(pos) then other=nil; why='tunnel reaches an uncharted tile at '..at(pos); break end
        local tk=key(pos); local tile=tiles[tk]
        if tile==nil then
          local t=p.surface.get_tile(math.floor(pos.x),math.floor(pos.y))
          local l=t.prototype.collision_mask.layers
          tile=(l.lava_tile or l.empty_space) and t.name or false; tiles[tk]=tile
        end
        if tile then other=nil; why='cannot pass under '..tile..' at '..at(pos); break end
      end
      nearest[e]={other=other,why=why}
      return other,why
    end
    local out={checked=#ends,paired=0,unpaired=0,external=0,flow_mismatch=0,rows={}}
    for _,e in ipairs(ends) do
      local q,why=next_end(e)
      local paired=q and toward(q)==(toward(e)+8)%16 and next_end(q)==e
      local row={index=e.index,name=e.name,position=e.pos,type=e.kind}
      local label=string.format('#%s %s %s %s',e.index,e.name,e.kind,at(e.pos))
      if paired then
        row.partner={index=q.index,name=q.name,position=q.pos,type=q.kind,source=q.index and 'request' or q.source}
        row.flow=e.dir==q.dir and e.kind~=q.kind
        row.status=row.flow and 'paired' or 'flow_mismatch'
        if row.flow then out.paired=out.paired+1 else out.flow_mismatch=out.flow_mismatch+1 end
        if not q.index then out.external=out.external+1 end
        row.line=label..': would pair with '..(q.index and ('request #'..q.index) or (q.source..' outside request'))..' '..q.name..' '..q.kind..' '..at(q.pos)
          ..(row.flow and '' or '; the two ends do not carry flow in the same direction')
      else
        out.unpaired=out.unpaired+1; row.status='unpaired'
        row.line=label..': unpaired; '..(why or (q and ('nearest same-tier end '..q.name..' '..q.kind..' '..at(q.pos)..' does not pair back') or ('no same-tier partner within '..e.reach..' tiles')))
      end
      if details or not paired or not row.flow or not q.index then out.rows[#out.rows+1]=row end
    end
    if #out.rows==0 then out.rows=nil end
    return out
  end
  return M
end
