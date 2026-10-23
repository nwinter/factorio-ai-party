-- Factory awareness for status: science and plate rates, research ETA, machine
-- states, fuel and power starvation, the character's inventory, and how much
-- of the factory still runs through the character's hands. Numbers only: what
-- the production GUI, the machines' status icons and the inventory show.
-- The entity survey is cached because status is polled several times a second.
local flameroil=require('flameroil')
local snapfail=require('snapfail')
return function(api)
  local M={}
  local CACHE_TICKS,MINUTE,HAND_MINUTES,HOARD_TICKS,ETA_SAMPLES=600,3600,10,36000,12
  local LOW_FREE,HOARD_SHARE,LOW_AMMO=5,0.25,5
  local SURVEY_TYPES={'assembling-machine','furnace','mining-drill','lab','boiler','inserter','burner-generator','reactor','ammo-turret','fluid-turret'}
  -- Flamer oil under a quarter is low (shift 5: the outer flame line held 19.9 oil and burnt out before anyone saw).
  local LOW_OIL=0.25
  -- Spoilable fuel (Sol, shift13 16:50: biochambers starved with 20 nutrients loaded, the batch rotting within
  -- seconds; on a copy of world n most biochambers held nutrients 85-99% spoiled): the burners whose fuel spoils within
  -- ROT_SOON ticks, and the one whose fuel spoils first (its stack's spoil_tick).
  local ROT_SOON=3600
  local SPOILS={}
  -- (d22 batch110 BT1: a closure a stack was garbage each survey) the reads first_spoil protects, as pcall(f, stack)
  local function spoil_ticks_of(st) return st.prototype.get_spoil_ticks() end
  local function spoil_tick_of(st) return st.spoil_tick end
  local function first_spoil(inv)
    local best,item
    for i=1,#inv do
      local st=inv[i]
      if st.valid_for_read then
        local name=st.name
        if SPOILS[name]==nil then
          local ok,t=pcall(spoil_ticks_of,st)
          SPOILS[name]=ok and type(t)=='number' and t>0 or false
        end
        if SPOILS[name] then
          local ok,tick=pcall(spoil_tick_of,st)
          if ok and type(tick)=='number' and tick>0 and (not best or tick<best) then best,item=tick,name end
        end
      end
    end
    return best,item
  end
  M.first_spoil=first_spoil
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
    local first,eta,basis=samples[1],nil,nil
    if api.research_rate then
      -- The lab throughput research.lua measures every 10 s: the last minute's, longer when it had no progress (Grok
      -- 03:20: an ETA from old samples said 2 hours when the finish was under 40 minutes).
      local rate,ticks,fell_back=api.research_rate(force.name)
      local work=(tech.research_unit_count or 0)*(tech.research_unit_energy or 0)
      if rate and rate>0 and work>0 then
        eta=(1-progress)*work/rate
        basis=' (rate of the last '..duration(ticks)..(fell_back and ': none in the last 1m' or '')..')'
      end
    elseif first and game.tick>first.tick and progress>first.progress then
      eta=(1-progress)*(game.tick-first.tick)/(progress-first.progress)
    end
    local line=string.format('%s %d%%',tech.name,math.floor(progress*100))..(eta and ' eta '..duration(eta)..(basis or '') or '')
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
  -- (d22 batch93 BC1, viewer Aurora 13:13: "the belt warning lists only 4 of 11 locations") every place a warning counts
  -- is kept (up to LIST_MAX a kind) and status {list: KIND, page?} pages them (LIST_PAGE a page); a warning that shows
  -- fewer than it counts says how many more and that call.
  local LIST_MAX,LIST_PAGE=500,50
  M.LIST_KINDS={belts_stuck='belts that point into a belt they cannot feed',belts_unpaired='unpaired undergrounds',
    no_fuel='burners with no fuel',last_fuel='burners burning their last fuel',ammo_empty='ammo turrets with no ammo',ammo_low='ammo turrets low on ammo'}
  local function more(shown,total,kind)
    if total<=shown then return '' end
    return string.format(', +%d more (status {list: "%s"} lists all %d)',total-shown,kind,total)
  end
  local function first(t,n) local o={} for i=1,math.min(#t,n) do o[i]=t[i] end return o end
  local function at_pos(p) return string.format('(%s,%s)',p.x,p.y) end
  local function at(e) return at_pos(e.position) end
  -- (BT1) the find ahead of a belt end: one filter table, its position and force set for each find (the engine reads
  -- it during the call and keeps nothing).
  local AHEAD_POS={x=0,y=0}
  local AHEAD={position=AHEAD_POS,radius=0.3,type=BELT_TYPES,limit=1}
  -- One underground or transport belt into the belt tally b.
  -- p: its position when the caller has it (the band's read; a belt does not move).
  local function belt_one(b,surface,force,e,kind,p)
    if e.valid==false then return end  -- gone since the job's find (a slice a tick)
    if kind=='underground-belt' then
      if not e.neighbours then b.unpaired[#b.unpaired+1]=e.belt_to_ground_type..' '..at_pos(p or e.position) end
    elseif #e.belt_neighbours.outputs==0 then
      local s=STEP[e.direction]
      p=p or e.position
      local ahead
      if s then
        AHEAD_POS.x,AHEAD_POS.y=p.x+s[1],p.y+s[2]; AHEAD.force=force
        ahead=surface.find_entities_filtered(AHEAD)[1]
      end
      if ahead then b.stuck[#b.stuck+1]=at_pos(p)..' into '..ahead.name else b.ends[#b.ends+1]=at_pos(p) end
    end
  end
  local function belts_done(b,warnings,detail)
    local unpaired,stuck,ends=b.unpaired,b.stuck,b.ends
    local function list(t,kind)
      table.sort(t)
      return table.concat(first(t,MAX_LISTED),', ')..more(MAX_LISTED,#t,kind)
    end
    if #unpaired>0 then warnings[#warnings+1]=string.format('belts: %d unpaired undergrounds: %s',#unpaired,list(unpaired,'belts_unpaired')) end
    if #stuck>0 then warnings[#warnings+1]=string.format('belts: %d belts point into a belt they cannot feed: %s',#stuck,list(stuck,'belts_stuck')) end
    table.sort(ends)
    local listed={}
    for i=1,math.min(#ends,16) do listed[i]=ends[i] end
    return #ends>0 and (#ends..' line ends') or nil,detail and listed or nil
  end
  -- The survey in pieces: an accumulator, one entity at a time into it, then
  -- the summary (survey() all at once; the background job in slices).
  local function acc_new()
    return {machines={},order={},fuel={},fuel_order={},labs=0,missing={},lab_count=0,powered=0,starved=0,unpowered=0,unconnected=0,
      turrets={},turret_order={},flamers={},flamer_order={}}
  end
  -- The engine's status names by id, as runtime.lua's entity_status_names (built on first use).
  local STATUS_NAMES
  local function status_names()
    if not STATUS_NAMES then
      STATUS_NAMES={}
      for name,value in pairs(defines.entity_status or {}) do STATUS_NAMES[value]=name end
    end
    return STATUS_NAMES
  end
  -- (BT1) what the last-fuel line reads, as pcall(f, e): no closure a burner
  local function max_usage(e) return e.prototype.get_max_energy_usage(e.quality) end
  local function base_usage(e) return e.prototype.energy_usage or 0 end
  -- What runtime.lua machine_status (api.status_name) reads for a burner burnt.stuck finds stopped (burnt.lua M.UNUSABLE,
  -- M.STATE).
  local STUCK_UNUSABLE,STUCK_STATE='fuel_unusable','burnt_result_full'
  -- One entity into the accumulator. t: its type when the caller read it (the job's slice does).
  -- (d22 batch110 BT1, survey.slice 33 KB a call on a copy of the live world) each read once: e.position (a new table
  -- each read) when a line needs it, the burner and its inventory once, burnt.stuck once a burner (it was read twice:
  -- for the status name and the fuel part), the status name only for the machine counts (the one place it is used).
  -- The status name is what api.status_name (runtime.lua machine_status) gives, without its reads: a machine with no
  -- burner reads its engine status name (burnt.stuck finds nothing without a burner; it made two closures to find
  -- that), a burner one burnt.stuck's state when it is stopped, else its engine status name.
  -- p: its position when the caller has it (the band's read: none of the survey's types moves).
  local function acc_entity(a,e,tech,t,p)
    local machines,order,fuel,fuel_order,missing=a.machines,a.order,a.fuel,a.fuel_order,a.missing
    local turrets,turret_order,flamers,flamer_order=a.turrets,a.turret_order,a.flamers,a.flamer_order
    local status_ids=defines.entity_status
      if t or e.valid then
        t=t or e.type
        local name,estatus,burner,pos=e.name,e.status,e.burner,p
        local binv=burner and burner.inventory
        -- Stopped by a full burnt-result slot (burnt.lua), whatever the status reads: read once for the fuel part and
        -- the status name.
        local stuck=binv and api.burnt_stuck and api.burnt_stuck(e)
        if MACHINE_TYPES[t] then
          local status
          if not burner then status=status_names()[estatus]
          elseif binv and api.burnt_stuck then status=stuck and (stuck.unusable and STUCK_UNUSABLE or STUCK_STATE) or status_names()[estatus]
          else status=api.status_name(e) end
          status=status or 'unknown'
          local m=machines[name]
          if not m then m={type=t,total=0,counts={},positions={}}; machines[name]=m; order[#order+1]=name end
          m.total=m.total+1; m.counts[status]=(m.counts[status] or 0)+1
          if status~='working' then
            local list=m.positions[status] or {}; m.positions[status]=list
            if #list<16 then pos=pos or e.position; list[#list+1]={x=pos.x,y=pos.y} end
          end
        end
        if binv then
          local f=fuel[name]
          if not f then f={type=t,total=0,empty=0,low=0}; fuel[name]=f; fuel_order[#fuel_order+1]=name end
          f.total=f.total+1
          if estatus==status_ids.no_fuel then
            f.empty=f.empty+1
            -- where (D1, Gemini 16:51 and 18:24: 'heating-tower 2/2 no_fuel' named no place)
            f.empty_at=f.empty_at or {}
            if #f.empty_at<LIST_MAX then pos=pos or e.position; f.empty_at[#f.empty_at+1]=string.format('(%g,%g)',pos.x,pos.y) end
          elseif binv.is_empty() and (burner.remaining_burning_fuel or 0)>0 then
            f.low=f.low+1
            -- Each burner on its last fuel, where and about how long it burns on (Luna 04:51: two biochambers low, one
            -- named): at its full draw, the time the fuel left in it lasts.
            f.last=f.last or {}
            if #f.last<LIST_MAX then
              local usage=0
              local ok,u=pcall(max_usage,e)
              if ok then usage=u end
              if usage<=0 then ok,u=pcall(base_usage,e); if ok then usage=u end end
              local s=usage>0 and burner.remaining_burning_fuel/usage/60 or nil
              pos=pos or e.position
              f.last[#f.last+1]=string.format('(%g,%g)%s',pos.x,pos.y,s and string.format(' %ds left',math.floor(s+0.5)) or '')
            end
          end
          if stuck then
            f.stuck=(f.stuck or 0)+1
            if not f.stuck_at then
              pos=pos or e.position
              f.stuck_at={at=at_pos(pos),burnt=stuck.unusable and ('its fuel slot holds '..stuck.fuel..', which it does not burn') or stuck.burnt}
            end
          end
          local tick,item=first_spoil(binv)
          if tick then
            if tick-game.tick<ROT_SOON then f.rot=(f.rot or 0)+1 end
            if not f.first or tick<f.first.tick then pos=pos or e.position; f.first={tick=tick,item=item,at=at_pos(pos)} end
          end
        else
          local buffer=e.electric_buffer_size
          if buffer and buffer>0 and t~='boiler' then
            a.powered=a.powered+1
            -- each kind's first places by name (D1, Gemini: 'machines low_power' named none)
            local kind
            if estatus==status_ids.low_power then a.starved=a.starved+1; kind='low_power'
            -- no_power without a network id: no pole reaches it.
            elseif estatus==status_ids.no_power then
              if e.electric_network_id then a.unpowered=a.unpowered+1; kind='no_power' else a.unconnected=a.unconnected+1; kind='unconnected' end
            end
            if kind then
              a.power_at=a.power_at or {}
              local list=a.power_at[kind] or {}; a.power_at[kind]=list
              if #list<6 then pos=pos or e.position; list[#list+1]=string.format('%s (%g,%g)',name,pos.x,pos.y) end
            end
          end
        end
        if t=='ammo-turret' then
          local tt=turrets[name]
          if not tt then tt={total=0,empty=0,low=0,empty_at={},low_at={}}; turrets[name]=tt; turret_order[#turret_order+1]=name end
          local inv=e.get_inventory(defines.inventory.turret_ammo)
          local n=inv and inv.get_item_count() or 0
          tt.total=tt.total+1
          -- Where to go: the first few empty and low turrets by position (the text made only for a turret listed).
          if n==0 then
            tt.empty=tt.empty+1
            if #tt.empty_at<LIST_MAX then pos=pos or e.position; tt.empty_at[#tt.empty_at+1]=string.format('(%g,%g)',pos.x,pos.y) end
          elseif n<LOW_AMMO then
            tt.low=tt.low+1
            if #tt.low_at<LIST_MAX then pos=pos or e.position; tt.low_at[#tt.low_at+1]=string.format('(%g,%g)',pos.x,pos.y) end
          end
        elseif t=='fluid-turret' then
          -- all it holds, its own buffer too (flameroil.lua; Astra, shift11 16:36: fluidbox[1] alone read all 12 dry)
          local ok,amount,cap,fluid=pcall(flameroil.read,e)
          if ok then
            local ft=flamers[name]
            if not ft then ft={total=0,dry=0,low=0,dry_at={},low_at={},rows={}}; flamers[name]=ft; flamer_order[#flamer_order+1]=name end
            ft.total=ft.total+1
            pos=pos or e.position
            ft.rows[#ft.rows+1]={amount=amount,fluid=fluid,position=pos}
            local at=string.format('(%g,%g)',pos.x,pos.y)
            if amount<1 then ft.dry=ft.dry+1; if #ft.dry_at<6 then ft.dry_at[#ft.dry_at+1]=at end
            elseif type(cap)=='number' and cap>0 and amount/cap<LOW_OIL then
              ft.low=ft.low+1; if #ft.low_at<6 then ft.low_at[#ft.low_at+1]=at..' '..math.floor(100*amount/cap+0.5)..'%' end
            end
          end
        end
        if t=='lab' then
          a.lab_count=a.lab_count+1
          if tech and estatus==status_ids.missing_science_packs then
            local inv=e.get_inventory(defines.inventory.lab_input)
            local count=inv and inv.get_item_count  -- (BT1: the method read once a lab, not once a pack)
            for _,ingredient in ipairs(tech.research_unit_ingredients) do
              if count and count(ingredient.name)==0 then missing[ingredient.name]=(missing[ingredient.name] or 0)+1 end
            end
            a.labs=a.labs+1
          end
        end
      end
  end
  -- The summary from a filled accumulator and belt tally (b).
  local function acc_done(a,b,force,surface)
    local machines,order,fuel,fuel_order,missing=a.machines,a.order,a.fuel,a.fuel_order,a.missing
    local turrets,turret_order,flamers,flamer_order=a.turrets,a.turret_order,a.flamers,a.flamer_order
    local powered,starved,unpowered,unconnected,lab_count=a.powered,a.starved,a.unpowered,a.unconnected,a.lab_count
    local labs={n=a.labs}
    local warnings={}
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
    -- (BC1) every place, by kind: the warning shows the first 6 (8 burning their last fuel) of each entity name
    local lists={belts_stuck={},belts_unpaired={},no_fuel={},last_fuel={},ammo_empty={},ammo_low={}}
    local counts={belts_stuck=#b.stuck,belts_unpaired=#b.unpaired,no_fuel=0,last_fuel=0,ammo_empty=0,ammo_low=0}
    local cut={}
    for _,name in ipairs(fuel_order) do
      local f=fuel[name]
      for _,x in ipairs(f.empty_at or {}) do if #lists.no_fuel<LIST_MAX then lists.no_fuel[#lists.no_fuel+1]=name..' '..x end end
      for _,x in ipairs(f.last or {}) do if #lists.last_fuel<LIST_MAX then lists.last_fuel[#lists.last_fuel+1]=name..' '..x end end
      counts.no_fuel=counts.no_fuel+f.empty; counts.last_fuel=counts.last_fuel+f.low
      if f.empty>0 or f.low>0 or (f.rot or 0)>0 or (f.stuck or 0)>0 then
        local ea,la=f.empty_at and first(f.empty_at,6),f.last and first(f.last,8)
        if f.empty>#(ea or {}) then cut.no_fuel=true end
        if f.low>#(la or {}) then cut.last_fuel=true end
        fuel_parts[#fuel_parts+1]=string.format('%s %d/%d no_fuel',name,f.empty,f.total)
          ..(ea and ' at '..table.concat(ea,' ')..(f.empty>#ea and string.format(' +%d more',f.empty-#ea) or '') or '')..(f.low>0 and ', '..f.low..' burning their last fuel'
          ..(la and ' ('..table.concat(la,', ')..(f.low>#la and string.format(', +%d more',f.low-#la) or '')..')' or '') or '')
          ..((f.stuck or 0)>0 and string.format(', %d stopped by a full burnt-result slot or unusable fuel (the first at %s: %s)',f.stuck,f.stuck_at.at,f.stuck_at.burnt) or '')
          ..(f.first and (f.rot or 0)>0 and string.format(', fuel spoils within %ds in %d (the first: %s in %s at %s)',ROT_SOON/60,f.rot,f.first.item,
            duration(math.max(0,f.first.tick-game.tick)),f.first.at) or '')
      end
    end
    local where=surface and surface.valid and ' on '..surface.name or ''
    local fuel_more={}
    if cut.no_fuel then fuel_more[#fuel_more+1]=string.format('status {list: "no_fuel"} lists all %d with no fuel',counts.no_fuel) end
    if cut.last_fuel then fuel_more[#fuel_more+1]=string.format('status {list: "last_fuel"} all %d on their last fuel',counts.last_fuel) end
    if #fuel_parts>0 then warnings[#warnings+1]='fuel'..where..': '..table.concat(fuel_parts,'; ')..(#fuel_more>0 and '; '..table.concat(fuel_more,', ') or '') end
    table.sort(turret_order)
    local ammo_parts={}
    for _,name in ipairs(turret_order) do
      local t=turrets[name]
      for _,x in ipairs(t.empty_at) do if #lists.ammo_empty<LIST_MAX then lists.ammo_empty[#lists.ammo_empty+1]=name..' '..x end end
      for _,x in ipairs(t.low_at) do if #lists.ammo_low<LIST_MAX then lists.ammo_low[#lists.ammo_low+1]=name..' '..x end end
      counts.ammo_empty=counts.ammo_empty+t.empty; counts.ammo_low=counts.ammo_low+t.low
      if t.empty+t.low>0 then
        local ea,la=first(t.empty_at,6),first(t.low_at,6)
        if t.empty>#ea then cut.ammo_empty=true end
        if t.low>#la then cut.ammo_low=true end
        ammo_parts[#ammo_parts+1]=string.format('%s %d/%d empty',name,t.empty,t.total)
          ..(t.empty>0 and ' at '..table.concat(ea,' ')..(t.empty>#ea and string.format(' +%d more',t.empty-#ea) or '') or '')
          ..(t.low>0 and ', '..t.low..' below '..LOW_AMMO..' at '..table.concat(la,' ')..(t.low>#la and string.format(' +%d more',t.low-#la) or '') or '')
      end
    end
    local ammo_more={}
    if cut.ammo_empty then ammo_more[#ammo_more+1]=string.format('status {list: "ammo_empty"} lists all %d empty',counts.ammo_empty) end
    if cut.ammo_low then ammo_more[#ammo_more+1]=string.format('status {list: "ammo_low"} all %d low',counts.ammo_low) end
    if #ammo_parts>0 then warnings[#warnings+1]='ammo: '..table.concat(ammo_parts,'; ')..(#ammo_more>0 and '; '..table.concat(ammo_more,', ') or '')..'; rearm radius=R walks every turret below count' end
    table.sort(flamer_order)
    local oil_parts={}
    for _,name in ipairs(flamer_order) do
      local t=flamers[name]
      if t.dry+t.low>0 then
        oil_parts[#oil_parts+1]=string.format('%s %s; %d/%d dry',name,flameroil.summary(t.rows,1),t.dry,t.total)
          ..(t.dry>0 and ' at '..table.concat(t.dry_at,' ')..(t.dry>#t.dry_at and string.format(' +%d more',t.dry-#t.dry_at) or '') or '')
          ..(t.low>0 and ', '..t.low..' below '..math.floor(LOW_OIL*100)..'% at '..table.concat(t.low_at,', ')..(t.low>#t.low_at and string.format(', +%d more',t.low-#t.low_at) or '') or '')
      end
    end
    if #oil_parts>0 then warnings[#warnings+1]='flamer oil: '..table.concat(oil_parts,'; ')..'; fh call flamers shows each one and what is in its arc' end
    -- Only when something lacks power: 'power: 3 of 78 machines low_power; 1 unconnected'.
    if starved+unpowered+unconnected>0 then
      local parts={}
      for _,c in ipairs{{starved,'low_power'},{unpowered,'no_power'},{unconnected,'unconnected'}} do
        if c[1]>0 then
          local at=a.power_at and a.power_at[c[2]]
          parts[#parts+1]=(#parts==0 and c[1]..' of '..powered..' machines ' or c[1]..' ')..c[2]
            ..(at and ': '..table.concat(at,', ')..(c[1]>#at and string.format(', +%d more',c[1]-#at) or '') or '')
        end
      end
      warnings[#warnings+1]='power'..where..': '..table.concat(parts,'; ')..' (fh call power lists them)'
    end
    local packs={}
    for name,n in pairs(missing) do packs[#packs+1]=name..' ('..n..' labs)' end
    table.sort(packs)
    if #packs>0 then warnings[#warnings+1]=string.format('labs: %d/%d missing packs: %s',labs.n,lab_count,table.concat(packs,', ')) end
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
    local belt_ends,end_positions=belts_done(b,warnings,true)
    for _,k in ipairs({'belts_stuck','belts_unpaired'}) do
      local src=k=='belts_stuck' and b.stuck or b.unpaired
      for i=1,math.min(#src,LIST_MAX) do lists[k][i]=src[i] end
    end
    local factory={belt_ends=belt_ends,science=#science>0 and table.concat(science,', ')..' /min (1m|10m)' or nil,
      research=research_line(force,warnings,lab_count),
      plates=#plates>0 and table.concat(plates,', ')..' /min (1m|10m)' or nil,
      hand=hand_line(stats)}
    if end_positions and #end_positions>0 then detail.belt_ends=end_positions end
    return {tick=game.tick,surface=surface.index,factory=factory,machines=summary,positions=detail,warnings=warnings,lists=lists,list_counts=counts,
      digest={tick=game.tick,machines=machines,fuel=fuel,belts={ends=#b.ends,unpaired=#b.unpaired,misdirected=#b.stuck}}}
  end
  -- All at once (machines=true, a surface's first survey, tests without the job).
  local function survey(p)
    local force,surface=p.force,p.surface
    local a,tech=acc_new(),force.current_research
    for _,e in ipairs(surface.find_entities_filtered{force=force,type=SURVEY_TYPES}) do acc_entity(a,e,tech) end
    local b={unpaired={},stuck={},ends={}}
    for _,e in pairs(surface.find_entities_filtered{force=force,type='underground-belt'}) do belt_one(b,surface,force,e,'underground-belt') end
    for _,e in pairs(surface.find_entities_filtered{force=force,type='transport-belt'}) do belt_one(b,surface,force,e,'transport-belt') end
    return acc_done(a,b,force,surface)
  end
  -- The background survey (task-statuscost, 01:15 on world n: survey.summary
  -- 60 ms in a full status): per force and surface someone read in the last
  -- KEEP_TICKS, a job started when the survey is CACHE_TICKS old; each step
  -- finds one type (the survey's types, undergrounds, belts) and then reads
  -- SLICE of them a tick; the last step makes the summary. Its state is in
  -- storage, so every peer runs the same.
  -- Operator 04:00 (survey.tick 50-57 ms in a game second every 10 s): one walk of every type at once, a band a step
  -- (walk.lua), SLICE entities read a step, one step every few ticks so a survey spreads over BG_TICKS, now 30 s.
  local SLICE,KEEP_TICKS,BG_TICKS=150,18000,1800
  local WALK_TYPES={}
  for _,t in ipairs(SURVEY_TYPES) do WALK_TYPES[#WALK_TYPES+1]=t end
  WALK_TYPES[#WALK_TYPES+1]='underground-belt'; WALK_TYPES[#WALK_TYPES+1]='transport-belt'
  local walk=api.walk or require('walk'){state=api.state}
  -- A call timed as its own profile part while the operator profile runs (runtime M.timed); else just the call.
  local function timed(label,fn,...)
    if api.timed then return api.timed(label,fn,...) end
    return fn(...)
  end
  local step_do
  -- (d22 batch110 BT1, survey.tick 19.9 KB a tick on a copy of the live world) the job allocates little of its own: the
  -- cache's keys go in one table kept between ticks, a step's profile label is a constant, the band's filter is one
  -- table with its force set for the find (walk.band copies it), and the force and surface come from a cache of the
  -- objects (game.forces[...] and game.get_surface make a new object each read), each checked valid before use.
  local KEYS,KEYS_N={},0
  local LABEL_DONE,LABEL_SLICE,LABEL_BAND='survey.done','survey.slice','survey.band'
  local BAND_FILTER={type=WALK_TYPES}
  local FORCES,SURFACES={},{}
  local POS,POS_LIST={},{}
  local function force_named(name)
    local f=FORCES[name]
    if f and f.valid then return f end
    f=game.forces[name]; FORCES[name]=f
    return f
  end
  local function surface_at(index)
    local s=SURFACES[index]
    if s and s.valid then return s end
    s=game.get_surface(index); SURFACES[index]=s
    return s
  end
  function M.tick(tick)
    local st=api.state()
    st.survey_bg=true
    local cache=st.survey_cache or {}
    st.survey_cache=cache
    st.survey_jobs=st.survey_jobs or {}
    st.survey_read=st.survey_read or {}
    local keys,n=KEYS,0
    for key in pairs(cache) do n=n+1; keys[n]=key end
    for i=n+1,KEYS_N do keys[i]=nil end
    KEYS_N=n
    table.sort(keys)
    for i=1,n do
      local key=keys[i]
      -- A step that fails ends its job (noted in survey_errors and on the survey, snapfail.lua); the survey keeps the tick
      -- it was taken at and the next job starts BG_TICKS after the failure.
      local ok,err=pcall(M.step,st,cache,key,tick)
      if not ok then
        st.survey_jobs[key]=nil
        st.survey_errors={count=((st.survey_errors or {}).count or 0)+1,last=tostring(err),tick=tick}
        if cache[key] then cache[key].refresh_failed=snapfail.failed(err,tick) end
      end
    end
  end
  function M.step(st,cache,key,tick)
    local entry=cache[key]
    if entry then
      local job=st.survey_jobs[key]
      local read=st.survey_read[key]
      if not job and (not read or tick-read>=KEEP_TICKS) then
        if tick-entry.tick>=KEEP_TICKS then cache[key]=nil; st.survey_read[key]=nil end
      elseif not job and tick-snapfail.since(entry.tick,entry.refresh_failed)>=BG_TICKS then
        local force_name,index=key:match('^(.*)/(%d+)$')
        st.survey_steps=st.survey_steps or {}
        st.survey_jobs[key]={start=tick,force=force_name,surface=tonumber(index),a=acc_new(),b={unpaired={},stuck={},ends={}},
          steps=0,every=walk.every(st.survey_steps[key],BG_TICKS)}
      elseif job and walk.due(job,tick,BG_TICKS) then
        job.steps=job.steps+1
        -- (each kind of step its own profile part, survey.<kind>: operator 18:12, survey.tick 66 ms in one game second)
        timed(job.done and LABEL_DONE or job.list and LABEL_SLICE or LABEL_BAND,step_do,st,cache,key,job)
      end
    end
  end
  step_do=function(st,cache,key,job)
    local force=force_named(job.force)
    local surface=force and surface_at(job.surface)
    if not (force and surface) then st.survey_jobs[key]=nil
    elseif job.done then
      -- (a survey taken since the job started, a forced read, is newer: the job's is dropped)
      if not snapfail.older(job.start,cache[key] and cache[key].tick) then
        local entry2=acc_done(job.a,job.b,force,surface)
        entry2.tick=job.start
        entry2.digest.tick=job.start
        cache[key]=entry2
      end
      st.survey_steps[key]=job.steps
      st.survey_jobs[key]=nil
    elseif not job.list then
      job.walk=job.walk or walk.start(surface)
      job.tech=job.tech or force.current_research
      BAND_FILTER.force,BAND_FILTER.area,BAND_FILTER.position=force,nil,nil  -- (only force and type, whatever a walk set)
      -- The positions the band read, list[i]'s in pos[i] (walk.band's out_pos; a walk without it returns none): one
      -- table a key kept between bands, used only for the list it was filled with (after a load the list is another
      -- table, and the slice reads e.position as before).
      local pos=POS[key] or {}
      POS[key]=pos
      local list,filled=walk.band(job.walk,surface,BAND_FILTER,pos)
      POS_LIST[key]=filled==pos and list or nil
      if list then job.list,job.i=list,1 else job.done=true end
    else
      local list,a,b,tech=job.list,job.a,job.b,job.tech
      local pos=POS_LIST[key]==list and POS[key] or nil
      local n=#list
      local last=math.min(n,job.i+SLICE-1)
      for i=job.i,last do
        local e=list[i]
        local t=e.valid and e.type
        local p=pos and pos[i]
        if t=='underground-belt' or t=='transport-belt' then belt_one(b,surface,force,e,t,p) elseif t then acc_entity(a,e,tech,t,p) end
      end
      job.i=last+1
      if job.i>n then job.list,job.i=nil,nil; POS_LIST[key]=nil end
    end
  end

  -- `machines=true` adds the positions of every non-working machine (up to 16
  -- per status) and forces a fresh survey.
  -- One entry per force and surface, shared by every agent there (shift03: one
  -- entry per force, so agents on Nauvis, Vulcanus and a platform took turns
  -- replacing it and nearly every status rescanned).
  function M.summary(p,detail)
    local st=api.state()
    local cache=st.survey_cache or {}
    st.survey_cache=cache
    local key=p.force.name..'/'..p.surface.index
    local entry=cache[key]
    -- With the background job running (M.tick) a status reads the last finished survey.
    if detail or not entry or (not st.survey_bg and game.tick-entry.tick>=CACHE_TICKS) then
      entry=survey(p); cache[key]=entry
    end
    st.survey_read=st.survey_read or {}
    st.survey_read[key]=game.tick
    local inv,warnings=M.inventory(p)
    warnings=warnings or {}
    for _,w in ipairs(entry.warnings) do warnings[#warnings+1]=w end
    return {inv=inv,factory=entry.factory,machines=next(entry.machines) and entry.machines or nil,
      machine_positions=detail and entry.positions or nil,warnings=#warnings>0 and warnings or nil,
      as_of=entry.tick<game.tick and entry.tick or nil,age_s=entry.tick<game.tick and math.floor((game.tick-entry.tick)/60) or nil,
      refresh_failed=snapfail.line('the factory survey',entry.tick,entry.refresh_failed)}
  end
  -- status {list: KIND, page?} (BC1): every place a factory warning counts, from the survey the warnings come from (the
  -- last finished one; a first status on this surface takes one), LIST_PAGE a page.
  function M.list(p,kind,page)
    local kinds={}
    for k in pairs(M.LIST_KINDS) do kinds[#kinds+1]=k end
    table.sort(kinds)
    assert(type(kind)=='string' and M.LIST_KINDS[kind],'list is one of '..table.concat(kinds,', '))
    assert(page==nil or (type(page)=='number' and page>=1 and page==math.floor(page)),'page is 1 or more')
    page=page or 1
    local st=api.state()
    local cache=st.survey_cache or {}
    st.survey_cache=cache
    local key=p.force.name..'/'..p.surface.index
    local entry=cache[key]
    if not (entry and entry.lists) then entry=survey(p); cache[key]=entry end
    st.survey_read=st.survey_read or {}
    st.survey_read[key]=game.tick
    local rows=entry.lists[kind] or {}
    local count=entry.list_counts and entry.list_counts[kind] or #rows
    local pages=math.max(1,math.ceil(#rows/LIST_PAGE))
    local shown={}
    for i=(page-1)*LIST_PAGE+1,math.min(#rows,page*LIST_PAGE) do shown[#shown+1]=rows[i] end
    local out={list=kind,what=M.LIST_KINDS[kind],surface=p.surface.name,count=count,rows=shown,page=page,pages=pages,
      as_of=entry.tick<game.tick and entry.tick or nil,age_s=entry.tick<game.tick and math.floor((game.tick-entry.tick)/60) or nil}
    if page<pages then out.next=string.format('status {list: "%s", page: %d}',kind,page+1) end
    if count>#rows then out.note=string.format('the survey keeps the first %d of %d',#rows,count) end
    local from,to=(page-1)*LIST_PAGE+1,math.min(#rows,page*LIST_PAGE)
    out.line=string.format('%s on %s: %d%s',M.LIST_KINDS[kind],p.surface.name,count,
      #shown>0 and string.format('; %d-%d of them (page %d of %d)%s: %s',from,to,page,pages,out.next and ', next: '..out.next or '',table.concat(shown,', '))
      or (count==0 and '' or string.format('; page %d of %d is past them',page,pages)))
    return out
  end
  return M
end
