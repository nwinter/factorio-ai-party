-- Machine rates over a set of our entities: the maximum rate each machine runs
-- at with its recipe, modules, beacons, quality and fuel, as the Rate
-- Calculator selection tool reports it. The per-machine formulas are ported
-- from RateCalculator v3.3.8 (Factorio 2.0), (c) Caleb Heuer (raiguard),
-- MIT License, https://codeberg.org/raiguard/RateCalculator
-- Electric power is the pseudo-item "power" in watts.
--
-- `bottleneck` builds on it with what the calculator does not model: machine
-- status by recipe, missing ingredients, inserter feed/output capacity, and
-- belt tier capacity against the area's outside needs.
return function(api)
  local M={}
  local MAX_INT53=2^53

  local function new_set(force,surface)
    local research=force.current_research
    return {rates={},errors={},force=force,surface=surface,
      research=research and {ingredients=research.research_unit_ingredients,units_per_second=60/research.research_unit_energy,
        speed_modifier=force.laboratory_speed_modifier} or nil}
  end
  local function err(set,name) set.errors[name]=(set.errors[name] or 0)+1 end
  local function add(set,category,kind,name,quality,amount,machine,temperature)
    local path=kind..'/'..name..'/'..quality..(temperature and '@'..temperature or '')
    local r=set.rates[path]
    if not r then
      r={type=kind,name=name,quality=quality,temperature=temperature,produced=0,consumed=0,producers={},consumers={}}
      set.rates[path]=r
    end
    local produced=category=='output'
    r[produced and 'produced' or 'consumed']=r[produced and 'produced' or 'consumed']+amount
    local counts=produced and r.producers or r.consumers
    counts[machine]=(counts[machine] or 0)+1
  end
  local function fluid_of(fluidbox,index)
    local f=fluidbox.get_filter(index) or fluidbox[index]
    return f and prototypes.fluid[f.name]
  end

  local function burner(set,e)
    local proto,b=e.prototype,e.burner
    local burning=b.currently_burning
    local name,quality
    if burning then name,quality=burning.name.name,burning.quality.name
    else
      local item=b.inventory.get_contents()[1]
      if item then name,quality=item.name,item.quality end
    end
    if not name then err(set,'no_fuel'); return end
    local fuel=prototypes.item[name]
    local usage=proto.get_max_energy_usage(e.quality)*(e.consumption_bonus+1)
    local per_second=usage*60/proto.burner_prototype.effectivity/fuel.fuel_value
    add(set,'input','item',name,quality,per_second,e.name)
    if fuel.burnt_result then add(set,'output','item',fuel.burnt_result.name,quality,per_second,e.name) end
  end

  local function electric(set,e)
    local proto=e.prototype
    if e.type=='electric-energy-interface' then
      if e.power_production>0 then add(set,'output','item','power','normal',e.power_production*60,e.name) end
      if e.power_usage>0 then add(set,'input','item','power','normal',e.power_usage*60,e.name) end
      return
    end
    local source=proto.electric_energy_source_prototype
    local usage=proto.get_max_energy_usage(e.quality) or 0
    if usage>0 and usage<MAX_INT53 then
      local amount=usage*(e.consumption_bonus+1)
      if usage~=source.drain then amount=amount+source.drain end
      add(set,'input','item','power','normal',amount*60,e.name)
      if e.status==defines.entity_status.no_power then err(set,'no_power') end
    end
    local production=proto.get_max_energy_production(e.quality)
    if production>0 and production<MAX_INT53 then
      if e.type=='solar-panel' then
        production=production*e.surface.solar_power_multiplier*e.surface.get_property('solar-power')
          /prototypes.surface_property['solar-power'].default_value
      end
      add(set,'output','item','power','normal',production*60,e.name)
    end
  end

  local function fluid_source(set,e)
    local proto=e.prototype
    local source=proto.fluid_energy_source_prototype
    local fluidbox=e.fluidbox
    local fluid=fluid_of(fluidbox,e.type=='boiler' and #fluidbox or 1)
    if not fluid then err(set,'no_input_fluid'); return end
    local usage=proto.get_max_energy_usage(e.quality)*(e.consumption_bonus+1)
    local value
    if source.scale_fluid_usage then
      if source.burns_fluid and fluid.fuel_value>0 then
        value=usage/(fluid.fuel_value/60)/source.effectivity
      else
        local current=fluidbox[#fluidbox]
        local warmth=current and current.temperature-fluid.default_temperature or 0
        if warmth>0 then value=usage/(warmth*fluid.heat_capacity)/source.effectivity*60 end
      end
    else
      value=source.fluid_usage_per_tick/source.effectivity*60
    end
    if value then add(set,'input','fluid',fluid.name,'normal',value,e.name) end
  end

  local function crafter(set,e)
    local recipe,quality=e.get_recipe()
    if not recipe and e.type=='furnace' and e.previous_recipe then
      recipe=set.force.recipes[e.previous_recipe.name.name]; quality=e.previous_recipe.quality
    end
    if not recipe then err(set,'no_recipe'); return end
    local q=quality and quality.name or 'normal'
    local duration=recipe.energy/e.crafting_speed
    for _,ingredient in pairs(recipe.ingredients) do
      add(set,'input',ingredient.type,ingredient.name,ingredient.type=='item' and q or 'normal',ingredient.amount/duration,e.name)
    end
    local productivity=1+math.min(e.productivity_bonus+recipe.productivity_bonus,recipe.prototype.maximum_productivity)
    for _,product in pairs(recipe.products) do
      if product.type~='research-progress' then
        local high,low=product.amount_max or product.amount,product.amount_min or product.amount
        local expected=(product.probability or 1)*0.5*(high+low)+(product.extra_count_fraction or 0)
        local fixed=math.min(expected,product.ignored_by_productivity or 0)
        add(set,'output',product.type,product.name,product.type=='item' and q or 'normal',
          (fixed+(expected-fixed)*productivity)/duration,e.name,product.temperature)
      end
    end
  end

  local function boiler(set,e)
    local proto,fluidbox=e.prototype,e.fluidbox
    local input=fluid_of(fluidbox,1)
    if not input then err(set,'no_input_fluid'); return end
    local function usage(fluid,index)
      local minimum=fluidbox.get_prototype(index).minimum_temperature or fluid.default_temperature
      return proto.get_max_energy_usage(e.quality)/((proto.target_temperature-minimum)*fluid.heat_capacity)*60
    end
    add(set,'input','fluid',input.name,'normal',usage(input,1),e.name)
    if proto.boiler_mode=='heat-water-inside' then
      add(set,'output','fluid',input.name,'normal',usage(input,1),e.name,input.max_temperature); return
    end
    local output=fluid_of(fluidbox,2)
    if output then add(set,'output','fluid',output.name,'normal',usage(output,2),e.name) end
  end

  local function lab(set,e)
    local research=set.research
    if not research then err(set,'no_research'); return end
    local inputs={}
    for _,name in ipairs(e.prototype.lab_inputs) do inputs[name]=true end
    for _,ingredient in pairs(research.ingredients) do
      if not inputs[ingredient.name] then err(set,'incompatible_packs'); return end
    end
    -- speed_bonus includes the force's lab bonus additively; the game
    -- applies it multiplicatively (as RateCalculator notes).
    local speed=e.prototype.get_researching_speed(e.quality)*(e.speed_bonus+1-research.speed_modifier)*(research.speed_modifier+1)
    local units=research.units_per_second*speed*e.prototype.science_pack_drain_rate_percent/100
    for _,ingredient in ipairs(research.ingredients) do
      add(set,'input','item',ingredient.name,'normal',ingredient.amount*units/prototypes.item[ingredient.name].get_durability(),e.name)
    end
  end

  local function drill(set,e)
    local proto=e.prototype
    local radius=(proto.get_mining_drill_radius and proto.get_mining_drill_radius(e.quality) or proto.mining_drill_radius)+0.01
    local found=e.surface.find_entities_filtered{type='resource',area={left_top={x=e.position.x-radius,y=e.position.y-radius},right_bottom={x=e.position.x+radius,y=e.position.y+radius}}}
    local categories=proto.resource_categories or {}
    local has_fluidbox=next(proto.fluidbox_prototypes)~=nil
    local resources,total={},0
    for _,r in ipairs(found) do
      local rp=r.prototype
      local mineable=rp.mineable_properties
      if categories[rp.resource_category] and (has_fluidbox or not mineable.required_fluid) then
        total=total+1
        local data=resources[r.name]
        if data then data.count=data.count+1
        else
          data={count=1,products=mineable.products,mining_time=mineable.mining_time,fluid=mineable.required_fluid,fluid_amount=mineable.fluid_amount}
          if rp.infinite_resource then data.mining_time=data.mining_time/(r.amount/rp.normal_resource_amount) end
          resources[r.name]=data
        end
      end
    end
    if total==0 then err(set,'no_resources'); return end
    local speed=proto.mining_speed*(e.speed_bonus+1)
    local productivity=e.productivity_bonus+1
    for _,data in pairs(resources) do
      local cycles=speed/data.mining_time*data.count/total
      -- Ten mining operations per unit of required fluid amount; productivity
      -- does not apply to it.
      if data.fluid then add(set,'input','fluid',data.fluid,'normal',data.fluid_amount/10*cycles,e.name) end
      for _,product in pairs(data.products or {}) do
        local amount=product.amount or (product.amount_min+product.amount_max)/2
        add(set,'output',product.type,product.name,'normal',amount*(product.probability or 1)*cycles*productivity,e.name,product.temperature)
      end
    end
  end

  local function entity_rates(set,e)
    local t,proto=e.type,e.prototype
    if t=='burner-generator' or t=='generator' then
      add(set,'output','item','power','normal',proto.get_max_power_output(e.quality)*60,e.name)
    elseif proto.electric_energy_source_prototype then electric(set,e)
    elseif proto.fluid_energy_source_prototype then fluid_source(set,e)
    elseif proto.heat_energy_source_prototype then
      add(set,'input','item','heat','normal',proto.get_max_energy_usage(e.quality)*(1+e.consumption_bonus)*60,e.name)
    end
    if e.burner then burner(set,e) end
    if t=='assembling-machine' or t=='furnace' or t=='rocket-silo' then crafter(set,e)
    elseif t=='boiler' then boiler(set,e)
    elseif t=='lab' then lab(set,e)
    elseif t=='generator' then
      local fluid=fluid_of(e.fluidbox,1)
      if fluid then add(set,'input','fluid',fluid.name,'normal',proto.get_fluid_usage_per_tick(e.quality)*60,e.name)
      else err(set,'no_input_fluid') end
    elseif t=='mining-drill' then drill(set,e)
    elseif t=='offshore-pump' then
      local fluid=e.fluidbox[1]
      if fluid then add(set,'output','fluid',fluid.name,'normal',proto.get_pumping_speed(e.quality)*60,e.name) end
    elseif t=='reactor' then
      add(set,'output','item','heat','normal',proto.get_max_energy_usage(e.quality)*(1+e.neighbour_bonus)*(1+e.consumption_bonus)*60,e.name)
    end
  end
  local RATE_TYPES={'assembling-machine','furnace','rocket-silo','mining-drill','lab','boiler','generator','burner-generator',
    'offshore-pump','reactor','solar-panel','electric-energy-interface','inserter','beacon','radar','lamp','pump','roboport',
    'electric-turret','accumulator','agricultural-tower','asteroid-collector'}

  -- The entities `area` or `positions` pick out: ours only.
  function M.select(p,a,types)
    local found={}
    if a.area then
      local lt,rb=api.position(a.area.left_top),api.position(a.area.right_bottom)
      assert(rb.x>lt.x and rb.y>lt.y and rb.x-lt.x<=192 and rb.y-lt.y<=192,'area must be nonempty and at most 192x192')
      found=p.surface.find_entities_filtered{area={left_top=lt,right_bottom=rb},force=p.force,type=types}
    else
      assert(type(a.positions)=='table' and #a.positions>=1 and #a.positions<=64,'area or positions (1..64) is required')
      local seen={}
      for _,pos in ipairs(a.positions) do
        local e=p.surface.find_entities_filtered{position=api.position(pos),radius=0.5,force=p.force,type=types,limit=1}[1]
        assert(e,'no machine of ours at '..pos.x..','..pos.y)
        if not seen[e] then seen[e]=true; found[#found+1]=e end
      end
    end
    return found
  end

  local function round(v)
    local r=math.abs(v)>=100 and math.floor(v+0.5) or math.floor(v*100+0.5)/100
    return math.tointeger and math.tointeger(r) or r -- 2 not 2.0 under Lua 5.3+
  end
  local function counts(t)
    local list={}
    for name,n in pairs(t) do list[#list+1]=name..' x'..n end
    table.sort(list)
    return #list>0 and table.concat(list,', ') or nil
  end
  local function watts(w)
    if w>=1e6 then return round(w/1e6)..' MW' end
    return round(w/1e3)..' kW'
  end
  -- Rows per item: produced, consumed, net at full speed, and the machines.
  function M.compute(p,entities,per)
    local set=new_set(p.force,p.surface)
    for _,e in ipairs(entities) do if e.valid then entity_rates(set,e) end end
    local scale=per=='second' and 1 or 60
    local rows,power={},nil
    for _,r in pairs(set.rates) do
      if r.name=='power' or r.name=='heat' then
        power=power or {}
        power[r.name]={produced=r.produced>0 and watts(r.produced) or nil,consumed=r.consumed>0 and watts(r.consumed) or nil}
      else
        local label=r.name..(r.quality~='normal' and ' ('..r.quality..')' or '')..(r.temperature and ' '..r.temperature..'C' or '')
        rows[#rows+1]={item=label,type=r.type~='item' and r.type or nil,produced=r.produced>0 and round(r.produced*scale) or nil,
          consumed=r.consumed>0 and round(r.consumed*scale) or nil,net=round((r.produced-r.consumed)*scale),
          by=counts(r.producers),into=counts(r.consumers),raw_net=(r.produced-r.consumed)*scale}
      end
    end
    table.sort(rows,function(x,y) return x.item<y.item end)
    return {rows=rows,power=power,errors=next(set.errors) and set.errors or nil,machines=#entities}
  end

  function M.rates(p,a)
    assert(a.per==nil or a.per=='second' or a.per=='minute','per must be second or minute')
    local out=M.compute(p,M.select(p,a,RATE_TYPES),a.per)
    for _,row in ipairs(out.rows) do row.raw_net=nil end
    out.per=a.per or 'minute'
    return out
  end

  -- Inserter throughput: one swing per revolution of its arm, stack sized by
  -- its prototype and the force's bonuses; an estimate (extension time and
  -- belt pickup make real inserters a little slower).
  local function inserter_rate(e)
    local proto,force=e.prototype,e.force
    local stack=1+(proto.inserter_stack_size_bonus or 0)
    if proto.uses_inserter_stack_size_bonus~=false then
      stack=stack+(proto.bulk and force.bulk_inserter_capacity_bonus or force.inserter_stack_size_bonus)
    end
    if (e.inserter_stack_size_override or 0)>0 then stack=math.min(stack,e.inserter_stack_size_override) end
    return proto.get_inserter_rotation_speed(e.quality)*60*stack
  end
  local STATUS_SKIP={working=true,normal=true}
  function M.bottleneck(p,a)
    local machines=M.select(p,a,{'assembling-machine','furnace','mining-drill','lab'})
    local rates=M.compute(p,machines,'minute')
    local groups,order,limits={},{},{}
    local by_machine={}
    for _,e in ipairs(machines) do
      local recipe=(e.type=='assembling-machine' or e.type=='furnace') and e.get_recipe()
      local key=e.name..(recipe and ' '..recipe.name or '')
      local g=groups[key]
      if not g then g={machine=key,count=0,statuses={}}; groups[key]=g; order[#order+1]=key end
      g.count=g.count+1
      local status=api.status_name(e) or 'unknown'
      g.statuses[status]=(g.statuses[status] or 0)+1
      if recipe then
        by_machine[e.unit_number]={entity=e,recipe=recipe,demand=0,supply=0,output=0,take=0,group=g}
        -- Missing ingredients read from the machine's input slots, as its GUI shows.
        if status=='item_ingredient_shortage' or status=='fluid_ingredient_shortage' then
          local inv=e.get_inventory(e.type=='furnace' and defines.inventory.furnace_source or defines.inventory.assembling_machine_input)
          for _,ingredient in pairs(recipe.ingredients) do
            local have=ingredient.type=='item' and inv and inv.get_item_count(ingredient.name) or nil
            if have and have<ingredient.amount then g.short=g.short or {}; g.short[ingredient.name]=(g.short[ingredient.name] or 0)+1 end
          end
        end
      end
    end
    -- Inserters feeding and emptying each machine, against its full-speed need.
    local waiting_source,waiting_space=0,0
    local inserters={}
    if a.area then inserters=M.select(p,a,{'inserter'})
    elseif #machines>0 then
      -- Around the picked machines: an inserter reaches at most a few tiles.
      local lt,rb={x=math.huge,y=math.huge},{x=-math.huge,y=-math.huge}
      for _,e in ipairs(machines) do
        lt.x,lt.y=math.min(lt.x,e.position.x-6),math.min(lt.y,e.position.y-6)
        rb.x,rb.y=math.max(rb.x,e.position.x+6),math.max(rb.y,e.position.y+6)
      end
      inserters=p.surface.find_entities_filtered{area={left_top=lt,right_bottom=rb},force=p.force,type='inserter'}
    end
    for _,i in ipairs(inserters) do
      local status=api.status_name(i)
      if status=='waiting_for_source_items' then waiting_source=waiting_source+1 end
      if status=='waiting_for_space_in_destination' then waiting_space=waiting_space+1 end
      local rate=inserter_rate(i)
      local into=i.drop_target and by_machine[i.drop_target.unit_number]
      local from=i.pickup_target and by_machine[i.pickup_target.unit_number]
      if into then into.supply=into.supply+rate end
      if from then from.take=from.take+rate end
    end
    for _,m in pairs(by_machine) do
      local e,recipe=m.entity,m.recipe
      local duration=recipe.energy/e.crafting_speed
      for _,ingredient in pairs(recipe.ingredients) do
        if ingredient.type=='item' then m.demand=m.demand+ingredient.amount/duration end
      end
      local productivity=1+math.min(e.productivity_bonus+recipe.productivity_bonus,recipe.prototype.maximum_productivity)
      for _,product in pairs(recipe.products) do
        if product.type=='item' then m.output=m.output+(product.amount or ((product.amount_min+product.amount_max)/2))*(product.probability or 1)*productivity/duration end
      end
      local pos=string.format('(%s,%s)',e.position.x,e.position.y)
      if m.supply>0 and m.supply<m.demand*0.99 then
        limits[#limits+1]=string.format('%s %s: input inserters %s/s < needs %s/s',m.group.machine,pos,round(m.supply),round(m.demand))
      end
      if m.take>0 and m.take<m.output*0.99 then
        limits[#limits+1]=string.format('%s %s: output inserters %s/s < makes %s/s',m.group.machine,pos,round(m.take),round(m.output))
      end
    end
    table.sort(limits)
    local rows={}
    table.sort(order)
    for _,key in ipairs(order) do
      local g=groups[key]
      local parts={}
      for status,n in pairs(g.statuses) do parts[#parts+1]=n..' '..status end
      table.sort(parts)
      local short
      if g.short then
        local list={}
        for name,n in pairs(g.short) do list[#list+1]=name..' ('..n..')' end
        table.sort(list); short=table.concat(list,', ')
      end
      local idle=0
      for status,n in pairs(g.statuses) do if not STATUS_SKIP[status] then idle=idle+n end end
      rows[#rows+1]={machines=g.machine..' x'..g.count,status=table.concat(parts,', '),short=short,idle=idle>0 and idle or nil}
    end
    -- What the area needs from outside at full speed, against belt capacity.
    local belt_capacity
    if a.area then
      for _,b in ipairs(M.select(p,a,{'transport-belt'})) do
        local per_minute=b.prototype.belt_speed*60*8*60*(1+(p.force.belt_stack_size_bonus or 0))
        if not belt_capacity or per_minute>belt_capacity.per_minute then belt_capacity={belt=b.name,per_minute=round(per_minute)} end
      end
    end
    local needs={}
    for _,r in ipairs(rates.rows) do
      if r.raw_net<-0.001 and not r.type then
        local over=belt_capacity and -r.raw_net>belt_capacity.per_minute
        needs[#needs+1]=string.format('%s %s/min',r.item,round(-r.raw_net))..(over and ' (over one '..belt_capacity.belt..')' or '')
      end
    end
    return {groups=rows,limits=#limits>0 and limits or nil,needs=#needs>0 and needs or nil,
      inserters=#inserters>0 and string.format('%d inserters: %d waiting for source items, %d waiting for space',#inserters,waiting_source,waiting_space) or nil,
      belt_capacity=belt_capacity and belt_capacity.belt..' '..belt_capacity.per_minute..'/min' or nil,
      errors=rates.errors,note='rates are full-speed maxima; limits compare inserter estimates with machine need'}
  end
  return M
end
