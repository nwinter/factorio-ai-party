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
      or not (type(p)=='table' and rawget(p,'__remote')) and p.position and ((pos.x-p.position.x)^2+(pos.y-p.position.y)^2)<=32^2
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
  -- (d26 batch242 HP, Astra #2454: an Aquilo beacon retrofit crossed a dense heat trunk; deconstruct named 815 cut-off
  -- parts only after marking, rerouting took several reads, and moving a heating tower took the only heater of the
  -- water pipe at (3.5,1.5)) heat_budget {remove | remove_area, build}: a read of what proposed removals and builds do
  -- to the heat networks there, nothing removed or built. Read on a copy of world n's 13:07 save (2.0.77, Aquilo):
  -- - heat-network links are the prototypes' connection points (dryrun.lua heat_points): every heat pipe and heat
  --   interface on its 4 sides; a heating tower (3x3) only at the middle tile of each side; a nuclear reactor at 12
  --   points; a heat exchanger at its back. Against the engine's heat_neighbours: 868 of 873 heat entities in Astra's
  --   area alike, the other 5 at the read box's edge (neighbours outside it);
  -- - freezing: a surface whose planet requires heating (entities_require_heating); an entity with heating_energy > 0
  --   freezes unless a heat pipe or reactor at 30 C or more touches it, a side or a corner (M.RULE): 417 of 418 such
  --   entities there as the game had them frozen or not (67 warmed through a corner only, none frozen).
  -- Built parts link by the engine's heat_neighbours, planned ones by their connection points. Bounded: PREVIEW_NODES
  -- parts walked, PATH_TILES tiles a path search visits, PATH_BOX tiles across its box.
  -- (cp2, operator: world n ran about 1.7x the copy for such reads today; a call on Astra's network at most about 15 ms
  -- on the copy) the boxes round the changes, the freeze read and the path search kept small
  local PREVIEW_NODES,PREVIEW_REMOVE,PREVIEW_BUILD,FREEZE_BOX,PATH_VISITS,PATH_BOX,PATH_MARGIN,PATHS,PATH_COMPONENTS=4000,256,64,32,600,32,12,3,2
  local FREEZE_READ,FREEZE_MARGIN=60,12  -- freezable entities read a preview, the nearest the changes first
  local FREEZABLE  -- the entity names with heating_energy above 0 (read once)
  M.PREVIEW_NODES,M.PATH_VISITS,M.PATH_BOX=PREVIEW_NODES,PATH_VISITS,PATH_BOX
  local function tkey(x,y) return (x+524288)*1048576+(y+524288) end
  local function heats(proto) return HEATERS[proto.type] and buffer(proto) ~= nil end
  local function at(pos) return string.format('(%g,%g)',pos.x,pos.y) end
  -- per prototype name, read once: {heat (has a heat buffer or heat energy source), source (a reactor or heat
  -- interface), consumer (a heat energy source: heat exchangers and other heat users)}
  local KINDS={}
  local function kind(proto)
    local k=KINDS[proto.name]
    if not k then
      k={heat=buffer(proto)~=nil,source=proto.type=='reactor' or proto.type=='heat-interface',heater=heats(proto),
        consumer=try(function() return proto.heat_energy_source_prototype end)~=nil}
      KINDS[proto.name]=k
    end
    return k
  end
  -- a heat entity: one with a heat buffer or a heat energy source (heat pipes, reactors, heating towers, heat
  -- interfaces, heat exchangers)
  local HEAT_TYPES={'heat-pipe','reactor','heat-interface','boiler'}
  local SIDES={{1,0},{-1,0},{0,1},{0,-1}}
  function M.preview(p,surface,a)
    local force=p.force
    local timed=api.timed or function(_,f,...) return f(...) end
    local required=try(function() return surface.planet.prototype.entities_require_heating end) or false
    local function seen(pos) return try(function() return force.is_chunk_visible(surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)}) end) end
    -- the removals: entities of ours at positions, or in an area (optionally by name)
    local removed,gone={},{}
    local function remove(e)
      if e.valid and e.unit_number and not gone[e.unit_number] and e.type~='character' and e.type~='entity-ghost' then
        assert(#removed<PREVIEW_REMOVE,'remove: at most '..PREVIEW_REMOVE..' entities a preview')
        gone[e.unit_number]=true; removed[#removed+1]=e
      end
    end
    for i,pos in ipairs(a.remove or {}) do
      local q=api.position(pos)
      assert(seen(q),'remove['..i..'] '..at(q)..': in no chunk our force sees now')
      local found=surface.find_entities_filtered{position=q,force=force}
      assert(#found>0,'remove['..i..']: no entity of ours at '..at(q))
      for _,e in ipairs(found) do remove(e) end
    end
    if a.remove_area~=nil then
      local ar=a.remove_area
      local lt,rb=api.position(ar.left_top or ar[1]),api.position(ar.right_bottom or ar[2])
      assert(seen(lt) and seen(rb),'remove_area: in no chunk our force sees now')
      for _,e in ipairs(surface.find_entities_filtered{area={lt,rb},force=force,name=a.remove_names}) do remove(e) end
    end
    -- the builds: {name, position, direction}
    local planned={}
    assert(a.build==nil or (type(a.build)=='table' and #a.build<=PREVIEW_BUILD),'build: 1..'..PREVIEW_BUILD..' {name, position, direction}')
    for i,b in ipairs(a.build or {}) do
      local name=type(b)=='table' and (b.name or b.entity)
      local proto=type(name)=='string' and prototypes.entity[name]
      assert(proto,'build['..i..']: name must be an entity name')
      local pos=api.position(b.position)
      local dir=b.direction==nil and 0 or api.direction and api.direction(b.direction)
      assert(type(dir)=='number','build['..i..']: direction must be a compass name or 0..15')
      planned[#planned+1]={planned=true,index=i,name=name,proto=proto,position=pos,direction=dir,k=kind(proto)}
    end
    assert(#removed+#planned>0,'heat_budget preview: remove, remove_area or build names what changes')
    -- the box of the changes, and the path box: it with PATH_MARGIN tiles round it, at most PATH_BOX across
    local x0,y0,x1,y1
    local function grow(pos) x0=math.min(x0 or pos.x,pos.x);y0=math.min(y0 or pos.y,pos.y);x1=math.max(x1 or pos.x,pos.x);y1=math.max(y1 or pos.y,pos.y) end
    for _,e in ipairs(removed) do grow(e.position) end
    for _,r in ipairs(planned) do grow(r.position) end
    local bx0,by0,bx1,by1=math.floor(x0)-PATH_MARGIN,math.floor(y0)-PATH_MARGIN,math.ceil(x1)+PATH_MARGIN,math.ceil(y1)+PATH_MARGIN
    if bx1-bx0>PATH_BOX then local m=math.floor((x0+x1)/2); bx0,bx1=m-PATH_BOX/2,m+PATH_BOX/2 end
    if by1-by0>PATH_BOX then local m=math.floor((y0+y1)/2); by0,by1=m-PATH_BOX/2,m+PATH_BOX/2 end
    local function inbox(pos) return pos.x>=bx0 and pos.x<bx1 and pos.y>=by0 and pos.y<by1 end
    -- the heat networks touching the changes, walked by the engine's links (built) up to PREVIEW_NODES
    local nodes,index={}, {}
    -- (cp2) each name's kind and prototype read once a call, not a prototype object a part
    local by_name={}
    local function add(e,u)
      u=u or e.unit_number
      if #nodes>=PREVIEW_NODES or index[u] then return end
      local name=e.name
      local pk=by_name[name]
      if not pk then local proto=e.prototype; pk={proto=proto,k=kind(proto)}; by_name[name]=pk end
      if not pk.k.heat then return end
      local n={e=e,proto=pk.proto,name=name,unit=u,k=pk.k}
      nodes[#nodes+1]=n; index[u]=n
    end
    -- (cp2) walked network by network from each seed, so the walk gives the components before as it goes
    local before,before_of={}, {}
    timed('heat.walk',function()
      for _,s0 in ipairs(surface.find_entities_filtered{area={{x0-4,y0-4},{x1+5,y1+5}},force=force,type=HEAT_TYPES}) do
        local start=#nodes+1
        if not index[s0.unit_number] then add(s0) end
        if nodes[start] then
          local c={nodes={},sources=0,consumers={}}
          before[#before+1]=c
          local k=start
          while nodes[k] do
            local n=nodes[k]; k=k+1
            local links={}
            for _,o in ipairs(n.e.heat_neighbours) do
              local u=o.unit_number
              if u then
                local m=index[u]
                if not m then add(o,u); m=index[u] end
                if m then links[#links+1]=m end
              end
            end
            n.links=links
            before_of[n]=c; c.nodes[#c.nodes+1]=n
            if n.k.source then c.sources=c.sources+1 end
            if n.k.consumer then c.consumers[#c.consumers+1]=n end
          end
        end
      end
    end)
    local capped=#nodes>=PREVIEW_NODES
    -- positions only where needed: in the path box (planned links, path starts and goals)
    local points={}
    local function point_index(n)
      n.points=api.heat_points(n.proto,n.position,n.direction)
      for _,c in ipairs(n.points) do local k=tkey(c.x,c.y); local l=points[k]; if not l then l={}; points[k]=l end; l[#l+1]={n=n,c=c} end
    end
    timed('heat.points',function()
      -- (cp2) the walked parts in the path box, from one find there: positions read only for those
      for _,e in ipairs(surface.find_entities_filtered{area={{bx0,by0},{bx1,by1}},force=force,type=HEAT_TYPES}) do
        local n=index[e.unit_number]
        if n and not gone[n.unit] then n.position=e.position; n.direction=e.direction; point_index(n) end
      end
    end)
    local live_planned={}
    for _,r in ipairs(planned) do if r.k.heat then point_index(r); live_planned[#live_planned+1]=r end end
    for _,r in ipairs(live_planned) do
      r.links={}
      for _,c in ipairs(r.points) do
        for _,o in ipairs(points[tkey(c.tx,c.ty)] or {}) do
          if o.n~=r and o.c.tx==c.x and o.c.ty==c.y then
            r.links[#r.links+1]=o.n
            if not o.n.planned then o.n.extra=o.n.extra or {}; o.n.extra[#o.n.extra+1]=r end
          end
        end
      end
    end
    -- components: before (built, every link) and after (without the removed, with the planned)
    local function components(after)
      local comp,list={},{}
      local function visit(n)
        local c={nodes={},sources=0,consumers={}}
        list[#list+1]=c
        local q,k={n},1
        comp[n]=c
        while q[k] do
          local x=q[k]; k=k+1
          c.nodes[#c.nodes+1]=x
          if x.k.source then c.sources=c.sources+1 end
          if x.k.consumer then c.consumers[#c.consumers+1]=x end
          for _,o in ipairs(x.links) do
            if not comp[o] and not (after and o.unit and gone[o.unit]) then comp[o]=c; q[#q+1]=o end
          end
          if after and x.extra then for _,o in ipairs(x.extra) do if not comp[o] then comp[o]=c; q[#q+1]=o end end end
        end
      end
      for _,n in ipairs(nodes) do if not comp[n] and not (after and gone[n.unit]) then visit(n) end end
      if after then for _,r in ipairs(live_planned) do if not comp[r] then visit(r) end end end
      return comp,list
    end
    local after
    timed('heat.components',function()
      local _
      _,after=components(true)
    end)
    local function where(n) local q=n.position; if not q then q=n.e.position; n.position=q end; return q end
    local function summary(c)
      local names={}
      for _,n in ipairs(c.nodes) do names[n.name]=(names[n.name] or 0)+1 end
      local parts={}
      for k,v in pairs(names) do parts[#parts+1]=v..' '..k end
      table.sort(parts)
      return string.format('%d parts (%s), %s, a part at %s',#c.nodes,table.concat(parts,', '),
        c.sources>0 and c.sources..' heat source'..(c.sources==1 and '' or 's') or 'no heat source',at(where(c.nodes[1])))
    end
    local out={preview=true,surface=surface.name,removed=#removed,planned=#planned}
    out.before={}; for _,c in ipairs(before) do out.before[#out.before+1]=summary(c) end
    out.after={}; for _,c in ipairs(after) do out.after[#out.after+1]=summary(c) end
    -- components that lose every source: parts that had one before and have none after
    local lost={}
    for _,c in ipairs(after) do
      if c.sources==0 then
        for _,n in ipairs(c.nodes) do local b=n.unit and before_of[n]; if b and b.sources>0 then lost[#lost+1]=c; break end end
      end
    end
    local lost_of={}
    for _,c in ipairs(lost) do for _,x in ipairs(c.nodes) do lost_of[x]=true end end
    -- the heat-network consumers (heat exchangers and other heat users) in them, cut from every source
    out.unheated={}
    for _,c in ipairs(lost) do
      local cons={}
      for _,n in ipairs(c.consumers) do if #cons<8 then cons[#cons+1]=n.name..' '..at(where(n)) end end
      out.unheated[#out.unheated+1]={component=summary(c),consumers=#cons>0 and cons or nil,consumers_count=#c.consumers}
    end
    -- freezing: entities with heating_energy (the game's freezable ones) in the freeze box (the changes with
    -- FREEZE_MARGIN tiles round them, at most FREEZE_BOX across), each against the heaters touching it (one find of the
    -- heaters there; a walked one by its network after, one not walked by its temperature: its network is unchanged)
    -- (cp2) only a removal takes heat away (a build adds it): the freeze box and its order come from the removals
    if required and #removed>0 then
      local warm_after={}
      for _,c in ipairs(after) do if c.sources>0 then for _,n in ipairs(c.nodes) do warm_after[n]=true end end end
      local rows,kw,beyond,unread={}, {}, 0, 0
      timed('heat.freeze',function()
        if not FREEZABLE then
          FREEZABLE={}
          for name,pr in pairs(prototypes.entity) do if (try(function() return pr.heating_energy end) or 0)>0 then FREEZABLE[#FREEZABLE+1]=name end end
        end
        -- the heaters' tiles: built heat pipes and reactors walked, and planned ones
        local htile={}
        local function mark(n,proto,pos,dir)
          if proto.type=='heat-pipe' then  -- 1x1: its tile from its position
            local k=tkey(math.floor(pos.x),math.floor(pos.y)); local l=htile[k]; if not l then l={}; htile[k]=l end; l[#l+1]=n
            return
          end
          local b=box(proto,pos,dir)
          for x=b.l,b.r do for y=b.t,b.b do local k=tkey(x,y); local l=htile[k]; if not l then l={}; htile[k]=l end; l[#l+1]=n end end
        end
        local rx0,ry0,rx1,ry1
        local cells,cell_list={}, {}
        for _,e in ipairs(removed) do
          local q=e.position
          rx0=math.min(rx0 or q.x,q.x);ry0=math.min(ry0 or q.y,q.y);rx1=math.max(rx1 or q.x,q.x);ry1=math.max(ry1 or q.y,q.y)
          local ck=tkey(math.floor(q.x/8),math.floor(q.y/8))
          if not cells[ck] then cells[ck]=true; cell_list[#cell_list+1]={x=math.floor(q.x/8)*8+4,y=math.floor(q.y/8)*8+4} end
        end
        local cx,cy=(rx0+rx1)/2,(ry0+ry1)/2
        local h=FREEZE_BOX/2
        local lx0,ly0,lx1,ly1=math.max(rx0-FREEZE_MARGIN,cx-h),math.max(ry0-FREEZE_MARGIN,cy-h),math.min(rx1+FREEZE_MARGIN,cx+h),math.min(ry1+FREEZE_MARGIN,cy+h)
        local in_box=0
        for _,e in ipairs(surface.find_entities_filtered{area={{lx0-2,ly0-2},{lx1+2,ly1+2}},force=force,type={'heat-pipe','reactor'}}) do
          local n=index[e.unit_number]
          if not n then
            -- a heater of a network the changes do not touch: as it is now
            n={name=e.name,position=e.position,e=e,unit=e.unit_number,outside=true}
          else
            n.position=n.position or e.position
            if n.k and lost_of[n] then in_box=in_box+1 end
          end
          mark(n,e.prototype,e.position,e.type=='heat-pipe' and 0 or e.direction)
        end
        local lost_parts=0
        for _,c in ipairs(lost) do lost_parts=lost_parts+#c.nodes end
        beyond=lost_parts>in_box and 1 or 0
        for _,r in ipairs(live_planned) do if heats(r.proto) then mark(r,r.proto,r.position,r.direction) end end
        local cands=surface.find_entities_filtered{area={{lx0,ly0},{lx1,ly1}},force=force,name=FREEZABLE}
        if #cands>FREEZE_READ then
          unread=#cands-FREEZE_READ
          local d={}
          -- the nearest a removal first (by the 8-tile cells the removals are in)
          for _,c in ipairs(cands) do
            local q=c.position
            local best
            for _,cl in ipairs(cell_list) do local v=(q.x-cl.x)^2+(q.y-cl.y)^2; if not best or v<best then best=v end end
            d[c]=best
          end
          table.sort(cands,function(u,v) return d[u]<d[v] end)
        end
        local stamp=0
        for i=1,math.min(#cands,FREEZE_READ) do
          local c=cands[i]
          if c.unit_number and not gone[c.unit_number] then
            local bb=c.bounding_box
            local b={l=math.floor(bb.left_top.x+0.01),t=math.floor(bb.left_top.y+0.01),r=math.ceil(bb.right_bottom.x-0.01)-1,b=math.ceil(bb.right_bottom.y-0.01)-1}
            local warm_before,warm_now,hit=nil,nil,false
            stamp=stamp+1
            for x=b.l-1,b.r+1 do
              for y=b.t-1,b.b+1 do
                local l=htile[tkey(x,y)]
                if l then for _,n in ipairs(l) do
                  if n.stamp~=stamp then
                    n.stamp=stamp
                    if n.planned then
                      if warm_after[n] then warm_now=warm_now or n end
                    elseif n.outside then
                      local t=n.temp
                      if t==nil then t=try(function() return n.e.temperature end) or 0; n.temp=t end
                      if t>=30 then warm_before=warm_before or n; warm_now=warm_now or n end
                    else
                      if gone[n.unit] or not warm_after[n] then hit=true end
                      local t=n.temp
                      if t==nil then t=try(function() return n.e.temperature end) or 0; n.temp=t end
                      if t>=30 then warm_before=warm_before or n end
                      if not gone[n.unit] and warm_after[n] then warm_now=warm_now or n end
                    end
                  end
                end end
              end
            end
            if hit and warm_before and not warm_now then
              kw[c.name]=kw[c.name] or math.floor((c.prototype.heating_energy or 0)*60/100+0.5)/10
              rows[#rows+1]=string.format('%s %s%s: heated now by %s %s (%d C); after: no heater at 30 C or more in a component with a heat source touches it',
                c.name,at(c.position),try(function() return c.frozen end) and ' (frozen now)' or '',warm_before.name,at(warm_before.position),
                math.floor(warm_before.temp+0.5))
            end
          end
        end
        out.freeze_box=string.format('(%g,%g)-(%g,%g)',lx0,ly0,lx1,ly1)
      end)
      if #rows>0 then out.freeze_count=#rows; out.freeze={}; for i=1,math.min(#rows,32) do out.freeze[i]=rows[i] end
        if #rows>32 then out.freeze[#out.freeze+1]=(#rows-32)..' more' end end
      local why={}
      if beyond>0 then why[#why+1]='cut-off parts reach past freeze_box (the removals with '..FREEZE_MARGIN..' tiles round them, at most '..FREEZE_BOX..' across): entities beside them there not read' end
      if unread>0 then why[#why+1]=unread..' more entities with heating_energy in freeze_box not read (the '..FREEZE_READ..' nearest a removal read)' end
      out.freeze_unread=#why>0 and table.concat(why,'; ') or nil
      local k={} for n,v in pairs(kw) do k[#k+1]=string.format('%s %g kW',n,v) end
      table.sort(k)
      out.freeze_rule=string.format('%s requires heating (its planet\'s entities_require_heating): an entity with heating_energy above 0 (%s) freezes unless %s',
        surface.name,#k>0 and table.concat(k,', ') or 'none here',M.RULE)
    end
    -- free-tile heat-pipe paths, in the path box, from each unheated component back to a component with a heat source
    if #lost>0 then
      timed('heat.paths',function()
        local pipe=prototypes.entity['heat-pipe']
        local layers={}
        for l in pairs(try(function() return pipe.collision_mask.layers end) or {}) do layers[#layers+1]=l end
        -- taken: every entity's tiles in the box (the removed ones' too: a removal clears room for something else),
        -- and the planned builds'
        local taken={}
        for _,e in ipairs(surface.find_entities_filtered{area={{bx0,by0},{bx1,by1}}}) do
          local t=e.type
          if t~='character' and t~='corpse' and t~='item-entity' then
            local b=e.bounding_box
            local l,tp,r,bt=math.floor(b.left_top.x+0.01),math.floor(b.left_top.y+0.01),math.ceil(b.right_bottom.x-0.01)-1,math.ceil(b.right_bottom.y-0.01)-1
            if l==r and tp==bt then taken[tkey(l,tp)]=true
            else for x=l,r do for y=tp,bt do taken[tkey(x,y)]=true end end end
          end
        end
        for _,r in ipairs(planned) do
          local b=box(r.proto,r.position,r.direction)
          for x=b.l,b.r do for y=b.t,b.b do taken[tkey(x,y)]=true end end
        end
        local by_name={}
        local function free(x,y)
          if x<bx0 or x>=bx1 or y<by0 or y>=by1 then return false end
          if taken[tkey(x,y)] then return false end
          local t=surface.get_tile(x,y)
          local nm=t.name
          local v=by_name[nm]
          if v==nil then
            v=true
            for _,l in ipairs(layers) do if t.collides_with(l) then v=false; break end end
            by_name[nm]=v
          end
          return v
        end
        -- goals: free tiles a heat pipe on which joins a component with a source (its parts in the box)
        local goal={}
        for _,d in ipairs(after) do
          if d.sources>0 then
            for _,n in ipairs(d.nodes) do
              for _,pt in ipairs(n.points or {}) do if free(pt.tx,pt.ty) then goal[tkey(pt.tx,pt.ty)]=true end end
            end
          end
        end
        local budget=PATH_VISITS
        out.paths={}
        for ci,c in ipairs(lost) do
          if ci>PATH_COMPONENTS then out.paths_unread=(#lost-PATH_COMPONENTS)..' more unheated components: no path search'; break end
          local from,q,k={}, {}, 1
          for _,n in ipairs(c.nodes) do
            for _,pt in ipairs(n.points or {}) do
              local key=tkey(pt.tx,pt.ty)
              if not from[key] and free(pt.tx,pt.ty) then from[key]={x=pt.tx,y=pt.ty}; q[#q+1]=from[key] end
            end
          end
          local found,visits={},0
          while q[k] and #found<PATHS and budget>0 do
            local t=q[k]; k=k+1; visits=visits+1; budget=budget-1
            if goal[tkey(t.x,t.y)] then
              local far=true
              for _,f in ipairs(found) do if math.abs(f.goal.x-t.x)+math.abs(f.goal.y-t.y)<3 then far=false end end
              if far then
                local tiles,s={},t
                while s do tiles[#tiles+1]=s; s=s.prev end
                found[#found+1]={goal=t,tiles=tiles}
              end
            end
            for _,d in ipairs(SIDES) do
              local nx,ny=t.x+d[1],t.y+d[2]
              local key=tkey(nx,ny)
              if not from[key] and free(nx,ny) then from[key]={x=nx,y=ny,prev=t}; q[#q+1]=from[key] end
            end
          end
          local list={}
          for _,f in ipairs(found) do
            local n=#f.tiles
            local start,stop=f.tiles[n],f.tiles[1]
            local tl={}
            for i=n,1,-1 do if #tl<48 then tl[#tl+1]=string.format('(%g,%g)',f.tiles[i].x+0.5,f.tiles[i].y+0.5) end end
            list[#list+1]=string.format('%d heat pipe%s from (%g,%g) to (%g,%g): %s%s',n,n==1 and '' or 's',start.x+0.5,start.y+0.5,stop.x+0.5,stop.y+0.5,
              table.concat(tl,' '),n>48 and ' ...' or '')
          end
          out.paths[#out.paths+1]={component=summary(c),paths=#list>0 and list or nil,
            none=#list==0 and string.format('no free-tile path to a component with a heat source in the box (%d tiles searched; %d left of %d for the read)',visits,budget,PATH_VISITS) or nil}
        end
        out.path_box=string.format('(%d,%d)-(%d,%d)',bx0,by0,bx1,by1)
      end)
    end
    -- each removed or planned heat entity's connection points against its heating border
    out.connections={}
    local function conn(name,proto,pos,dir,planned_)
      if #out.connections>=16 or not buffer(proto) then return end
      local pts=api.heat_points(proto,pos,dir)
      local tiles={}
      for _,c in ipairs(pts) do tiles[#tiles+1]=string.format('(%g,%g)',c.tx+0.5,c.ty+0.5) end
      local b=box(proto,pos,dir)
      out.connections[#out.connections+1]=string.format('%s %s%s: joins heat entities with a connection back on %s; %s',name,at(pos),planned_ and ' (planned)' or '',
        #tiles>0 and table.concat(tiles,' ') or 'no tile',heats(proto) and string.format('warms entities touching (%d,%d)-(%d,%d), its border, corners included',b.l-1,b.t-1,b.r+1,b.b+1)
        or 'warms no neighbour (a heat exchanger does not)')
    end
    for _,e in ipairs(removed) do conn(e.name,e.prototype,e.position,e.direction) end
    for _,r in ipairs(planned) do conn(r.name,r.proto,r.position,r.direction,true) end
    if #out.connections==0 then out.connections=nil end
    if #out.unheated==0 then out.unheated=nil; out.none='no part of a heat network loses its last heat source' end
    out.capped=capped and string.format('the network read stopped at %d parts: components past it are not read',PREVIEW_NODES) or nil
    out.note='a read: nothing removed or built. Components are the heat networks touching the changes, built ones by the game\'s heat links, planned ones by their heat connection points; a heat source is a reactor (nuclear reactor, heating tower) or a heat interface. A planned heat pipe starts at 15 C and warms from its component. Paths: in path_box (the changes with '..PATH_MARGIN..' tiles round them, at most '..PATH_BOX..' across), over free tiles (nothing built, planned or ghosted there, nor the removed ones\' tiles; a tile a heat pipe can stand on), shortest first, at most '..PATHS..' a component, '..PATH_VISITS..' tiles searched a read'
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
