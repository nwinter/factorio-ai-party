-- Factory awareness for status: science and plate rates, research ETA, machine
-- states, fuel and power starvation, the character's inventory, and how much
-- of the factory still runs through the character's hands. Numbers only: what
-- the production GUI, the machines' status icons and the inventory show.
-- The entity survey is cached because status is polled several times a second.
return function(api)
  local M={}
  local CACHE_TICKS,MINUTE,HAND_MINUTES,HOARD_TICKS,ETA_SAMPLES=600,3600,10,36000,12
  local LOW_FREE,HOARD_SHARE,LOW_AMMO=5,0.25,5
  local SURVEY_TYPES={'assembling-machine','furnace','mining-drill','lab','boiler','inserter','burner-generator','reactor','ammo-turret'}
  local MACHINE_TYPES={['assembling-machine']=true,furnace=true,['mining-drill']=true,lab=true,boiler=true}
  local PLATES={'iron-plate','copper-plate','steel-plate','stone-brick','plastic-bar'}
  local function round(v) return math.floor(v+0.5) end
  local function duration(ticks)
    local s=round(ticks/60)
    if s<60 then return s..'s' end
    if s<3600 then return math.floor(s/60)..'m'..(s%60>0 and s%60 ..'s' or '') end
    return math.floor(s/3600)..'h'..math.floor(s%3600/60)..'m'
  end
  local function short(name) return (name:gsub('%-science%-pack$','')) end

  -- Character inventory: always the free count; a warning when nearly full,
  -- and items that fill a quarter of it without being drawn down for 10 min.
  local function slot_use(inv)
    local slots,counts,order={},{},{}
    for i=1,#inv do
      local s=inv[i]
      if s.valid_for_read then
        if not slots[s.name] then order[#order+1]=s.name; slots[s.name]=0; counts[s.name]=0 end
        slots[s.name]=slots[s.name]+1; counts[s.name]=counts[s.name]+s.count
      end
    end
    table.sort(order,function(a,b) return slots[a]>slots[b] or (slots[a]==slots[b] and a<b) end)
    return slots,counts,order
  end
  -- Called once a minute: remembers since when each item has not decreased.
  function M.sample(p)
    local inv=p.get_main_inventory()
    if not inv then return end
    local seen=api.state().inventory_seen or {}
    api.state().inventory_seen=seen
    local old,now=seen[p.index] or {},{}
    local _,counts=slot_use(inv)
    for name,count in pairs(counts) do
      local prev=old[name]
      now[name]={count=count,since=(prev and count>=prev.count) and prev.since or game.tick}
    end
    seen[p.index]=now
  end
  function M.inventory(p)
    local inv=p.get_main_inventory()
    if not inv then return nil end
    local total,free=#inv,inv.count_empty_stacks()
    local warnings={}
    local slots,_,order=slot_use(inv)
    if free<=LOW_FREE then
      local top={}
      for i=1,math.min(3,#order) do top[i]=order[i]..' '..slots[order[i]] end
      warnings[#warnings+1]=string.format('inventory: %d/%d slots (%d free); most slots: %s',total-free,total,free,table.concat(top,', '))
    end
    local seen=(api.state().inventory_seen or {})[p.index] or {}
    for _,name in ipairs(order) do
      local since=seen[name] and seen[name].since
      if slots[name]>total*HOARD_SHARE and since and game.tick-since>=HOARD_TICKS then
        warnings[#warnings+1]=string.format('hoarding: %s %d/%d slots, not drawn down for %s',name,slots[name],total,duration(game.tick-since))
      end
    end
    return string.format('free=%d/%d',free,total),warnings
  end

  -- Hand work log: per-minute buckets of items the character fed into
  -- entities, collected from machines, and started crafting.
  function M.log_hand(kind,name,count)
    if count<=0 then return end
    local log=api.state().hand_log or {}
    api.state().hand_log=log
    local minute=math.floor(game.tick/MINUTE)
    local bucket=log[minute]
    if not bucket then
      bucket={fed={},collected={},crafted={}}; log[minute]=bucket
      for m in pairs(log) do if m<=minute-HAND_MINUTES then log[m]=nil end end
    end
    bucket[kind][name]=(bucket[kind][name] or 0)+count
  end
  local function hand_totals()
    local out={fed={},collected={},crafted={}}
    local minute=math.floor(game.tick/MINUTE)
    for m,bucket in pairs(api.state().hand_log or {}) do
      if m>minute-HAND_MINUTES then
        for kind,items in pairs(bucket) do
          for name,n in pairs(items) do out[kind][name]=(out[kind][name] or 0)+n end
        end
      end
    end
    return out
  end

  local function flow(stats,name,category,precision)
    return stats.get_flow_count{name=name,category=category,precision_index=precision}
  end
  -- Share of the last 10 minutes' factory flow that went through the hands:
  -- fed against consumed, collected and crafted against produced.
  local function hand_line(stats)
    local ten=defines.flow_precision_index.ten_minutes
    local totals,parts=hand_totals(),{}
    for _,spec in ipairs{{'fed','output'},{'collected','input'},{'crafted','input'}} do
      local rows={}
      for name,n in pairs(totals[spec[1]]) do
        local factory=flow(stats,name,spec[2],ten)*HAND_MINUTES
        local share=factory>0 and math.min(100,round(100*n/factory)) or nil
        rows[#rows+1]={name=name,n=n,text=name..' '..n..(share and ' ('..share..'%)' or '')}
      end
      table.sort(rows,function(a,b) return a.n>b.n or (a.n==b.n and a.name<b.name) end)
      local texts={}
      for i=1,math.min(4,#rows) do texts[i]=rows[i].text end
      if #texts>0 then parts[#parts+1]=spec[1]..' '..table.concat(texts,', ') end
    end
    return #parts>0 and table.concat(parts,'; ')..' (10m)' or nil
  end

  -- Research progress samples give an ETA from the actual lab throughput.
  local function research_line(force,warnings,labs)
    local tech=force.current_research
    local queue=force.research_queue or {}
    if not tech then
      if labs>0 then warnings[#warnings+1]=string.format('research idle: nothing queued (%d labs)',labs) end
      return nil
    end
    local all=api.state().research_samples or {}
    api.state().research_samples=all
    local samples=all[force.name] or {}
    if samples[1] and samples[1].name~=tech.name then samples={} end
    local progress=force.research_progress
    if not samples[#samples] or game.tick-samples[#samples].tick>=CACHE_TICKS then
      samples[#samples+1]={name=tech.name,tick=game.tick,progress=progress}
      while #samples>ETA_SAMPLES do table.remove(samples,1) end
    end
    all[force.name]=samples
    local first,eta=samples[1],nil
    if first and game.tick>first.tick and progress>first.progress then
      eta=(1-progress)*(game.tick-first.tick)/(progress-first.progress)
    end
    local line=string.format('%s %d%%',tech.name,math.floor(progress*100))..(eta and ' eta '..duration(eta) or '')
    local next_name=queue[2] and queue[2].name
    line=line..(next_name and ' next '..next_name or ' (queue ends)')
    if eta and eta<3600 and not next_name then
      warnings[#warnings+1]='research queue ends in '..duration(eta)..' with nothing next'
    end
    return line
  end

  -- What the belt GUI arrows show: underground ends with no partner, and belt
  -- ends pointing into a belt they cannot feed (its back, or head-on). Plain
  -- line ends are normal and only counted.
  local BELT_TYPES={'transport-belt','underground-belt','splitter','loader','loader-1x1','lane-splitter','linked-belt'}
  local STEP={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  local MAX_LISTED=4
  local function at(e) return string.format('(%s,%s)',e.position.x,e.position.y) end
  local function belts(surface,force,warnings,detail)
    local unpaired,stuck,ends={},{},{}
    for _,e in pairs(surface.find_entities_filtered{force=force,type='underground-belt'}) do
      if not e.neighbours then unpaired[#unpaired+1]=e.belt_to_ground_type..' '..at(e) end
    end
    for _,e in pairs(surface.find_entities_filtered{force=force,type='transport-belt'}) do
      if #e.belt_neighbours.outputs==0 then
        local s=STEP[e.direction]
        local ahead=s and surface.find_entities_filtered{position={x=e.position.x+s[1],y=e.position.y+s[2]},radius=0.3,type=BELT_TYPES,force=force,limit=1}[1]
        if ahead then stuck[#stuck+1]=at(e)..' into '..ahead.name else ends[#ends+1]=at(e) end
      end
    end
    local function list(t)
      table.sort(t)
      local shown={}
      for i=1,math.min(#t,MAX_LISTED) do shown[i]=t[i] end
      return table.concat(shown,', ')..(#t>MAX_LISTED and ', ...' or '')
    end
    if #unpaired>0 then warnings[#warnings+1]=string.format('belts: %d unpaired undergrounds: %s',#unpaired,list(unpaired)) end
    if #stuck>0 then warnings[#warnings+1]=string.format('belts: %d belts point into a belt they cannot feed: %s',#stuck,list(stuck)) end
    table.sort(ends)
    local listed={}
    for i=1,math.min(#ends,16) do listed[i]=ends[i] end
    return #ends>0 and (#ends..' line ends') or nil,detail and listed or nil
  end
  local function survey(p)
    local force,surface=p.force,p.surface
    local found=surface.find_entities_filtered{force=force,type=SURVEY_TYPES}
    local machines,order,warnings={},{},{}
    local fuel,fuel_order={},{}
    local labs,missing,lab_count={},{},0
    local powered,starved,unpowered=0,0,0
    local turrets,turret_order={},{}
    local tech=force.current_research
    local status_ids=defines.entity_status
    for _,e in ipairs(found) do
      if e.valid then
        local status=api.status_name(e) or 'unknown'
        if MACHINE_TYPES[e.type] then
          local m=machines[e.name]
          if not m then m={total=0,counts={},positions={}}; machines[e.name]=m; order[#order+1]=e.name end
          m.total=m.total+1; m.counts[status]=(m.counts[status] or 0)+1
          if status~='working' then
            local list=m.positions[status] or {}; m.positions[status]=list
            if #list<16 then list[#list+1]={x=e.position.x,y=e.position.y} end
          end
        end
        local burner=e.burner
        if burner and burner.inventory then
          local f=fuel[e.name]
          if not f then f={total=0,empty=0,low=0}; fuel[e.name]=f; fuel_order[#fuel_order+1]=e.name end
          f.total=f.total+1
          if e.status==status_ids.no_fuel then f.empty=f.empty+1
          elseif burner.inventory.is_empty() and (burner.remaining_burning_fuel or 0)>0 then f.low=f.low+1 end
        elseif e.electric_buffer_size and e.electric_buffer_size>0 and e.type~='boiler' then
          powered=powered+1
          if e.status==status_ids.low_power then starved=starved+1
          elseif e.status==status_ids.no_power then unpowered=unpowered+1 end
        end
        if e.type=='ammo-turret' then
          local t=turrets[e.name]
          if not t then t={total=0,empty=0,low=0,empty_at={},low_at={}}; turrets[e.name]=t; turret_order[#turret_order+1]=e.name end
          local inv=e.get_inventory(defines.inventory.turret_ammo)
          local n=inv and inv.get_item_count() or 0
          t.total=t.total+1
          -- Where to go: the first few empty and low turrets by position.
          local at=string.format('(%g,%g)',e.position.x,e.position.y)
          if n==0 then t.empty=t.empty+1; if #t.empty_at<6 then t.empty_at[#t.empty_at+1]=at end
          elseif n<LOW_AMMO then t.low=t.low+1; if #t.low_at<6 then t.low_at[#t.low_at+1]=at end end
        end
        if e.type=='lab' then
          lab_count=lab_count+1
          if tech and e.status==status_ids.missing_science_packs then
            local inv=e.get_inventory(defines.inventory.lab_input)
            for _,ingredient in ipairs(tech.research_unit_ingredients) do
              if inv and inv.get_item_count(ingredient.name)==0 then missing[ingredient.name]=(missing[ingredient.name] or 0)+1 end
            end
            labs[#labs+1]=e
          end
        end
      end
    end
    local summary,detail={},{}
    table.sort(order)
    for _,name in ipairs(order) do
      local m,parts=machines[name],{}
      local statuses={}
      for status in pairs(m.counts) do if status~='working' then statuses[#statuses+1]=status end end
      table.sort(statuses,function(a,b) return m.counts[a]>m.counts[b] or (m.counts[a]==m.counts[b] and a<b) end)
      for _,status in ipairs(statuses) do parts[#parts+1]=m.counts[status]..' '..status end
      summary[name]=string.format('%d/%d working',m.counts.working or 0,m.total)..(#parts>0 and ', '..table.concat(parts,', ') or '')
      if #statuses>0 then detail[name]=m.positions end
    end
    table.sort(fuel_order)
    local fuel_parts={}
    for _,name in ipairs(fuel_order) do
      local f=fuel[name]
      if f.empty>0 or f.low>0 then
        fuel_parts[#fuel_parts+1]=string.format('%s %d/%d no_fuel',name,f.empty,f.total)..(f.low>0 and ', '..f.low..' burning their last fuel' or '')
      end
    end
    if #fuel_parts>0 then warnings[#warnings+1]='fuel: '..table.concat(fuel_parts,'; ') end
    table.sort(turret_order)
    local ammo_parts={}
    for _,name in ipairs(turret_order) do
      local t=turrets[name]
      if t.empty+t.low>0 then
        ammo_parts[#ammo_parts+1]=string.format('%s %d/%d empty',name,t.empty,t.total)
          ..(t.empty>0 and ' at '..table.concat(t.empty_at,' ')..(t.empty>#t.empty_at and ' ...' or '') or '')
          ..(t.low>0 and ', '..t.low..' below '..LOW_AMMO..' at '..table.concat(t.low_at,' ')..(t.low>#t.low_at and ' ...' or '') or '')
      end
    end
    if #ammo_parts>0 then warnings[#warnings+1]='ammo: '..table.concat(ammo_parts,'; ')..'; rearm radius=R walks every turret below count' end
    if starved+unpowered>0 then
      warnings[#warnings+1]=string.format('power: %d/%d electric machines low_power',starved,powered)..(unpowered>0 and ', '..unpowered..' no_power' or '')
    end
    local packs={}
    for name,n in pairs(missing) do packs[#packs+1]=name..' ('..n..' labs)' end
    table.sort(packs)
    if #packs>0 then warnings[#warnings+1]=string.format('labs: %d/%d missing packs: %s',#labs,lab_count,table.concat(packs,', ')) end
    local stats=force.get_item_production_statistics(surface)
    local one,ten=defines.flow_precision_index.one_minute,defines.flow_precision_index.ten_minutes
    local science,plates={},{}
    local names={}
    for name in pairs(stats.output_counts) do
      local item=prototypes.item[name]
      if item and item.type=='tool' then names[#names+1]=name end
    end
    table.sort(names)
    for _,name in ipairs(names) do
      local a,b=flow(stats,name,'output',one),flow(stats,name,'output',ten)
      if a>0 or b>0 then science[#science+1]=string.format('%s %s|%s',short(name),round(a),round(b)) end
    end
    for _,name in ipairs(PLATES) do
      local a,b=flow(stats,name,'input',one),flow(stats,name,'input',ten)
      if a>0 or b>0 then plates[#plates+1]=string.format('%s %s|%s',name,round(a),round(b)) end
    end
    local belt_ends,end_positions=belts(surface,force,warnings,true)
    local factory={belt_ends=belt_ends,science=#science>0 and table.concat(science,', ')..' /min (1m|10m)' or nil,
      research=research_line(force,warnings,lab_count),
      plates=#plates>0 and table.concat(plates,', ')..' /min (1m|10m)' or nil,
      hand=hand_line(stats)}
    if end_positions and #end_positions>0 then detail.belt_ends=end_positions end
    return {tick=game.tick,surface=surface.index,factory=factory,machines=summary,positions=detail,warnings=warnings}
  end

  -- `machines=true` adds the positions of every non-working machine (up to 16
  -- per status) and forces a fresh survey.
  function M.summary(p,detail)
    local cache=api.state().survey_cache or {}
    api.state().survey_cache=cache
    local entry=cache[p.force.name]
    if detail or not entry or game.tick-entry.tick>=CACHE_TICKS or entry.surface~=p.surface.index then
      entry=survey(p); cache[p.force.name]=entry
    end
    local inv,warnings=M.inventory(p)
    warnings=warnings or {}
    for _,w in ipairs(entry.warnings) do warnings[#warnings+1]=w end
    return {inv=inv,factory=entry.factory,machines=next(entry.machines) and entry.machines or nil,
      machine_positions=detail and entry.positions or nil,warnings=#warnings>0 and warnings or nil,
      as_of=entry.tick<game.tick and entry.tick or nil}
  end
  return M
end
