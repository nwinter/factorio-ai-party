-- Freezing and heat-network connections are separate engine facts. Freezable
-- machines have no heat_neighbours even while an adjacent pipe warms them.
return function(api)
  local M={}
  local function try(f) local ok,v=pcall(f);if ok then return v end end
  local function buffer(p) return try(function() return p.heat_buffer_prototype or p.heat_energy_source_prototype end) end
  local function box(p,pos,dir)
    local b=api.footprint(p,pos,dir)
    return {l=math.floor(b.left_top.x),t=math.floor(b.left_top.y),r=math.ceil(b.right_bottom.x)-1,b=math.ceil(b.right_bottom.y)-1}
  end
  local function touches(a,b) return a.l<=b.r+1 and a.r>=b.l-1 and a.t<=b.b+1 and a.b>=b.t-1 end
  local function visible(p,pos)
    return try(function() return p.force.is_chunk_visible(p.surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)}) end)
      or p.position and ((pos.x-p.position.x)^2+(pos.y-p.position.y)^2)<=32^2
  end
  local function facts(p,proto,pos,dir,planned)
    local energy=try(function() return proto.heating_energy end) or 0
    local heat=buffer(proto)
    if energy==0 and not heat then return nil end
    local required=try(function() return p.surface.planet.prototype.entities_require_heating end) or false
    local out={surface_requires_heating=required,demand_kw=energy*60/1000,minimum_heater_temperature=30,
      heating_border_tiles=1,heaters={},heat_neighbours={}}
    if heat then
      out.thermal_mass_mj_per_c=heat.specific_heat/1000000
      out.max_temperature=heat.max_temperature;out.min_working_temperature=heat.min_working_temperature
      out.max_transfer_mw=heat.max_transfer*60/1000000
    end
    if not required or energy==0 then return out end
    local b=box(proto,pos,dir)
    local here=visible(p,pos)
    out.heaters_unread=not here and 'placement is not currently visible' or nil
    local list=here and p.surface.find_entities_filtered{area={{b.l-1,b.t-1},{b.r+2,b.b+2}},
      force=p.force,type={'heat-pipe','reactor','boiler','heat-interface','entity-ghost'},limit=65} or {}
    out.heater_read_capped=#list==65 or nil
    for _,e in ipairs(list) do
      local ghost=e.type=='entity-ghost'
      local pr=ghost and e.ghost_prototype or e.prototype
      if e.valid and buffer(pr) and visible(p,e.position) and touches(b,box(pr,e.position,e.direction)) then
        local temp=not ghost and try(function() return e.temperature end) or nil
        out.heaters[#out.heaters+1]={name=ghost and e.ghost_name or e.name,position={x=e.position.x,y=e.position.y},
          ghost=ghost or nil,temperature=temp,at_least_30c=temp and temp>=30 or false}
      end
    end
    for _,r in ipairs(planned or {}) do
      if r.proto and r.pos and buffer(r.proto) and touches(b,box(r.proto,r.pos,r.dir)) then
        out.heaters[#out.heaters+1]={name=r.name,position=r.pos,planned_index=r.index,planned=true}
      end
    end
    table.sort(out.heaters,function(a,b) return a.position.y<b.position.y or a.position.y==b.position.y and a.position.x<b.position.x end)
    return out
  end
  function M.inspect(p,e)
    local ghost=e.type=='entity-ghost'
    local proto=ghost and e.ghost_prototype or e.prototype
    local out=facts(p,proto,e.position,e.direction)
    if not out then return nil end
    out.ghost=ghost or nil
    if not ghost then
      out.freezable=e.is_freezable;out.frozen=e.frozen
      out.temperature=try(function() return e.temperature end)
      if buffer(proto) then
        for _,n in ipairs(e.heat_neighbours or {}) do
          if n.valid and visible(p,n.position) then
            out.heat_neighbours[#out.heat_neighbours+1]={name=n.name,position={x=n.position.x,y=n.position.y},temperature=n.temperature}
          end
        end
      end
      if out.frozen then
        local built,warm=0,0
        for _,h in ipairs(out.heaters) do if not h.ghost then built=built+1;if h.at_least_30c then warm=warm+1 end end end
        out.reason=built==0 and 'frozen; no built heat buffer observed touching the one-tile border'
          or warm==0 and 'frozen; all observed adjacent heat buffers are below 30 C'
          or 'frozen; adjacent heat buffers at or above 30 C are listed at their current temperature'
      else out.reason=out.freezable and 'not frozen' or 'not freezable on this surface' end
    end
    return out
  end
  function M.plan(p,recs)
    local rows,more={},0
    for _,r in ipairs(recs) do
      if r.proto and r.pos then
        if #rows>=64 then more=more+1
        else
          local out=facts(p,r.proto,r.pos,r.dir,recs)
          if out then out.index=r.index;out.name=r.name;out.position=r.pos;out.proposed=true;rows[#rows+1]=out end
        end
      end
    end
    return #rows>0 and rows or nil,more>0 and more or nil
  end
  return M
end
