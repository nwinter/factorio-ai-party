-- Freezing and heat-network connections are separate engine facts. Freezable
-- machines have no heat_neighbours even while an adjacent pipe warms them.
-- What heats a neighbour (d15, Sol shift17 10:50: a heat exchanger at 431 C was listed as a heater, and the turbine
-- and assembler beside it stayed frozen; checked on a private 2.0.77 Space Age server, sources held at a set
-- temperature on Aquilo): heat pipes and reactor-type entities (nuclear reactor, heating tower) at 30 C or more that
-- touch the machine (a side or a corner; one empty tile between: no heat). A heat exchanger does not, at 431 C or
-- 600 C. 29.9 C does not; 30 C does. A frozen machine thaws a few to about 30 s after a heater warms it (a 68 C heat
-- pipe beside a chemical plant: frozen at 10 s, thawed by 30 s). The game's changelog: "Added heating_radius to
-- ReactorPrototype and HeatPipePrototype".
return function(api)
  local M={}
  local HEATERS={['heat-pipe']=true,reactor=true}
  M.RULE='heated by a heat pipe, nuclear reactor or heating tower at 30 C or more touching it (a side or a corner); '..
    'a heat exchanger does not heat its neighbours; a frozen machine thaws a few to about 30 s after a heater warms it'
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
      heating_border_tiles=1,heaters={},heat_neighbours={},heater_rule=required and energy>0 and M.RULE or nil}
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
      force=p.force,type={'heat-pipe','reactor','entity-ghost'},limit=65} or {}
    out.heater_read_capped=#list==65 or nil
    for _,e in ipairs(list) do
      local ghost=e.type=='entity-ghost'
      local pr=ghost and e.ghost_prototype or e.prototype
      if e.valid and HEATERS[pr.type] and buffer(pr) and visible(p,e.position) and touches(b,box(pr,e.position,e.direction)) then
        local temp=not ghost and try(function() return e.temperature end) or nil
        out.heaters[#out.heaters+1]={name=ghost and e.ghost_name or e.name,position={x=e.position.x,y=e.position.y},
          ghost=ghost or nil,temperature=temp,at_least_30c=temp and temp>=30 or false}
      end
    end
    for _,r in ipairs(planned or {}) do
      if r.proto and r.pos and HEATERS[r.proto.type] and buffer(r.proto) and touches(b,box(r.proto,r.pos,r.dir)) then
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
        out.reason=built==0 and 'frozen; no built heater (heat pipe, nuclear reactor, heating tower) touches it'
          or warm==0 and 'frozen; every heater touching it is below 30 C'
          or 'frozen; a heater at 30 C or more touches it (listed); a frozen machine thaws a few to about 30 s after it is warmed'
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
  -- What removing entities does to heat (Sol, shift19: twice reclaiming "spare" heat pipes froze an ammonia
  -- underground pipe and the only steam turbine, and all Aquilo power collapsed). Read from the built entities now:
  --   cut_off: heat-network parts (engine heat_neighbours links) whose part of the network keeps no nuclear reactor or
  --     heating tower once the removed ones are gone, where it held one before; they keep their heat and cool;
  --   freeze (a surface whose entities need heating): freezable entities touching a removed heater (heat pipe,
  --     reactor, heating tower) that had a heater at 30 C or more touching them, and keep none (lost), or keep only
  --     cut-off ones (cools).
  local NODES,CANDIDATES,SHOW=2000,64,8
  -- heat_budget {position, add_pipes?} (Sol, d15 22:55: 21 new heat pipes caused a 10-minute brownout on Aquilo): the
  -- heat network of the entity at position, walked by its heat connections (at most MAX_PARTS): each part's
  -- temperature and heat capacity (its heat buffer's specific heat), the mean weighted by capacity, the lowest and
  -- highest, the heat stored above 30 C (what keeps neighbours from freezing); with add_pipes N, the mean once N new
  -- heat pipes, each starting at its buffer's default temperature, share that heat (no heat made or used meanwhile).
  -- (about the belt walk's cost per element on a copy of world n: 1000 parts stay under the 20 ms rule)
  local MAX_PARTS=1000
  function M.budget(p,e,add)
    assert(add==nil or (type(add)=='number' and add>=0 and add<=5000 and add==math.floor(add)),'add_pipes is 0..5000 heat pipes')
    assert(try(function() return e.temperature end),e.name..' has no heat buffer (a heat pipe, reactor, heating tower or heat exchanger has)')
    local seen,queue,head={[e.unit_number or 0]=true},{e},1
    local cap,sum,above,lo,hi,kinds=0,0,0,nil,nil,{}
    while head<=#queue and #queue<=MAX_PARTS do
      local x=queue[head]; head=head+1
      local t=try(function() return x.temperature end)
      local c=try(function() return x.prototype.heat_buffer_prototype.specific_heat end)
        or try(function() return x.prototype.heat_energy_source_prototype.specific_heat end) or 0
      if t then
        cap=cap+c; sum=sum+c*t; above=above+c*math.max(0,t-30)
        if not lo or t<lo.t then lo={t=t,e=x} end
        if not hi or t>hi.t then hi={t=t,e=x} end
        kinds[x.name]=(kinds[x.name] or 0)+1
      end
      for _,n in ipairs(try(function() return x.heat_neighbours end) or {}) do
        local u=n.unit_number or 0
        if n.valid and not seen[u] then seen[u]=true; queue[#queue+1]=n end
      end
    end
    local mean=cap>0 and sum/cap or 0
    local parts={}
    for n,c in pairs(kinds) do parts[#parts+1]=c..' '..n end
    table.sort(parts)
    local function at(x) return string.format('%s (%g,%g)',x.name,x.position.x,x.position.y) end
    local out={parts=#queue,capped=#queue>MAX_PARTS and string.format('more than %d parts: the first %d read',MAX_PARTS,MAX_PARTS) or nil,mean_c=math.floor(mean*10+0.5)/10,
      lowest=lo and string.format('%.1f C at %s',lo.t,at(lo.e)),highest=hi and string.format('%.1f C at %s',hi.t,at(hi.e)),
      capacity_mj_per_c=math.floor(cap/1e5+0.5)/10,stored_above_30_mj=math.floor(above/1e5+0.5)/10}
    out.line=string.format('heat network of %d parts (%s): mean %.1f C, lowest %s, highest %s; heat capacity %.1f MJ per C; %.1f MJ stored above 30 C',
      #queue,table.concat(parts,', '),mean,out.lowest or '?',out.highest or '?',cap/1e6,above/1e6)
    if add and add>0 then
      local pipe=prototypes.entity['heat-pipe']
      local hb=pipe and try(function() return pipe.heat_buffer_prototype end)
      local c=hb and hb.specific_heat or 1000000
      local t0=hb and try(function() return hb.default_temperature end) or 15
      local after=(sum+add*c*t0)/(cap+add*c)
      out.after_c=math.floor(after*10+0.5)/10
      out.line=out.line..string.format('; %d new heat pipes, each %.1f MJ per C starting at %g C, take the mean to %.1f C (%.1f C lower) when they share this heat, with no heat made or used meanwhile',
        add,c/1e6,t0,after,mean-after)
    end
    return out
  end
  function M.loss(surface,force,removed)
    local gone,parts={},{}
    for _,e in ipairs(removed or {}) do
      if e.valid and e.unit_number then
        gone[e.unit_number]=true
        if buffer(e.prototype) then parts[#parts+1]=e end
      end
    end
    if #parts==0 then return nil end
    local function source(e) return e.type=='reactor' end
    local function links(e) return try(function() return e.heat_neighbours end) or {} end
    -- The network of e, with or without the removed parts: {list, source}; capped at NODES.
    local function walk(start,skip,seen)
      local list,has,queue,k={},false,{start},1
      seen[start.unit_number]=true
      while queue[k] and #list<NODES do
        local e=queue[k];k=k+1
        list[#list+1]=e
        if source(e) and not (skip and gone[e.unit_number]) then has=true end
        for _,n in ipairs(links(e)) do
          if n.valid and n.unit_number and not seen[n.unit_number] and not (skip and gone[n.unit_number]) then seen[n.unit_number]=true;queue[#queue+1]=n end
        end
      end
      return {list=list,source=has,capped=queue[k]~=nil or nil}
    end
    local before,cut,capped={},{},nil
    local seen_before={}
    for _,e in ipairs(parts) do
      if not seen_before[e.unit_number] then
        local w=walk(e,false,seen_before)
        for _,x in ipairs(w.list) do before[x.unit_number]=w.source end
        capped=capped or w.capped
      end
    end
    local seen_after,cut_by={},{}
    for _,e in ipairs(parts) do
      if before[e.unit_number] then
        for _,n in ipairs(links(e)) do
          if n.valid and n.unit_number and not gone[n.unit_number] and not seen_after[n.unit_number] then
            local w=walk(n,true,seen_after)
            capped=capped or w.capped
            if not w.source then for _,x in ipairs(w.list) do cut[x.unit_number]=x;cut_by[x.name]=(cut_by[x.name] or 0)+1 end end
          end
        end
      end
    end
    local out={}
    local ncut=0
    for _ in pairs(cut) do ncut=ncut+1 end
    if ncut>0 then
      local names={}
      for n,c in pairs(cut_by) do names[#names+1]={n,c} end
      table.sort(names,function(x,y) return x[2]>y[2] or x[2]==y[2] and x[1]<y[1] end)
      for i,v in ipairs(names) do names[i]=v[2]..' '..v[1] end
      local first
      for _,x in pairs(cut) do if not first or x.position.y<first.position.y or x.position.y==first.position.y and x.position.x<first.position.x then first=x end end
      out.cut_off=string.format('%d heat-network part%s cut off from every nuclear reactor and heating tower (%s; first at (%g,%g)); they keep their heat and cool',
        ncut,ncut==1 and '' or 's',table.concat(names,', '),first.position.x,first.position.y)
      out.cut_off_count=ncut
    end
    -- Freezing: only where entities need heating.
    local required=try(function() return surface.planet.prototype.entities_require_heating end)
    if required then
      local cands,seen={},{}
      local more=0
      -- beside the removed heaters, and beside the cut-off ones (they cool)
      local beside={}
      for _,h in ipairs(parts) do beside[#beside+1]=h end
      for _,h in pairs(cut) do if #beside<NODES then beside[#beside+1]=h end end
      for _,h in ipairs(beside) do
        if HEATERS[h.type] and #cands<CANDIDATES then
          local b=box(h.prototype,h.position,h.direction)
          for _,c in ipairs(surface.find_entities_filtered{area={{b.l-1,b.t-1},{b.r+2,b.b+2}},force=force} or {}) do
            if c.valid and c.unit_number and not gone[c.unit_number] and not seen[c.unit_number] and c.type~='entity-ghost'
              and (try(function() return c.prototype.heating_energy end) or 0)>0 then
              seen[c.unit_number]=true
              if #cands<CANDIDATES then cands[#cands+1]=c else more=more+1 end
            end
          end
        end
      end
      local rows={}
      for _,c in ipairs(cands) do
        local b=box(c.prototype,c.position,c.direction)
        local warm_gone,warm_kept,warm_cut,warm_cut_first={},0,0,nil
        for _,h in ipairs(surface.find_entities_filtered{area={{b.l-1,b.t-1},{b.r+2,b.b+2}},force=force,type={'heat-pipe','reactor'}} or {}) do
          if h.valid and touches(b,box(h.prototype,h.position,h.direction)) then
            local t=try(function() return h.temperature end) or 0
            if t>=30 then
              if gone[h.unit_number] then warm_gone[#warm_gone+1]=h
              elseif cut[h.unit_number] then warm_cut=warm_cut+1;warm_cut_first=warm_cut_first or h
              else warm_kept=warm_kept+1 end
            end
          end
        end
        if #warm_gone+warm_cut>0 and warm_kept==0 then
          local h=warm_cut_first or warm_gone[1]
          local frozen=try(function() return c.frozen end)
          rows[#rows+1]=string.format('%s (%g,%g)%s: %s (%s (%g,%g) %d C)',c.name,c.position.x,c.position.y,frozen and ' (frozen now)' or '',
            warm_cut>0 and 'keeps only heaters cut off from every reactor and heating tower, which cool' or 'loses its last heater at 30 C or more',
            h.name,h.position.x,h.position.y,math.floor((try(function() return h.temperature end) or 0)+0.5))
        end
      end
      if #rows>0 then
        out.freeze_count=#rows
        out.freeze={}
        for i=1,math.min(SHOW,#rows) do out.freeze[i]=rows[i] end
        if #rows>SHOW then out.freeze[#out.freeze+1]=string.format('%d more',#rows-SHOW) end
      end
      if more>0 then out.freeze_unread=more..' more freezable entities beside the removed heaters not read' end
    end
    if capped then out.network_capped='a heat network read stopped at '..NODES..' parts' end
    if not next(out) then return {none='no entity loses its last heater at 30 C or more and no heat-network part is cut off'} end
    out.rule=required and out.freeze and M.RULE or nil
    return out
  end
  return M
end
