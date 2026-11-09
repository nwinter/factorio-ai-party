-- Explicit technology levels without writing LuaTechnology.level or the research queue.
local M = {}
local UINT_MAX = 4294967295

function M.units(t, level)
  local proto = t.prototype
  assert(type(level)=='number' and level==math.floor(level) and level>0 and level<=UINT_MAX,
    'level must be an integer in 1..4294967295')
  assert(level>=(proto.level or 1) and level<=(proto.max_level or proto.level or 1),
    'level is outside this technology prototype\'s range')
  assert(not proto.research_trigger, 'this technology has a research trigger, not a unit cost')
  if level==(t.level or 1) then return t.research_unit_count, 'native research_unit_count' end
  local formula = proto.research_unit_count_formula
  if not formula then return proto.research_unit_count or t.research_unit_count, 'native fixed count' end
  local raw = helpers.evaluate_expression(formula, {L=level, l=level})
  local multiplier = proto.ignore_tech_cost_multiplier and 1 or
    (game.difficulty_settings and game.difficulty_settings.technology_price_multiplier or 1)
  assert(raw==raw and raw>=0 and raw<UINT_MAX+1, 'level cost exceeds the supported uint32 range')
  -- Native 2.0.77: floor the formula BEFORE the multiplier, then floor again (private probe, batch355).
  local n = math.floor(raw) * multiplier
  assert(n<UINT_MAX+1, 'level cost exceeds the supported uint32 range')
  return math.max(1, math.floor(n)), 'engine formula, floored before multiplier, then floored again'
end

function M.summary(force, t, level)
  level = level or t.level or 1
  local full, source = M.units(t, level)
  local done = t.researched and level<=(t.level or 1) or level<(t.level or 1)
  local progress, origin = 0, 'not started'
  if done then progress,origin=1,'completed'
  elseif level==(t.level or 1) then
    if force.current_research and force.current_research.name==t.name then
      progress,origin=force.research_progress or 0,'current research'
    else progress,origin=t.saved_progress or 0,'saved progress' end
  end
  return {level=level,full_units=full,remaining_units=full*(1-progress),progress_fraction=progress,
    progress_source=origin,completed=done or false,unit_count_source=source}
end

-- The census supplies bounded entity lists. Never discover labs by scanning the map in this read.
function M.cohort(force, t, api)
  local out={labs=0,compatible=0,working=0,groups={},missing_surfaces={},basis='census lab membership; live status, speed, drain and productivity'}
  local groups, work, packs, visited = {}, 0, 0, 0
  for _,surface in pairs(game.surfaces or {}) do
    local labs,as_of,capped=api.labs_of(force,surface)
    if not labs then out.missing_surfaces[#out.missing_surfaces+1]=surface.name
    else
      out.as_of_tick=math.min(out.as_of_tick or as_of or game.tick,as_of or game.tick)
      if capped then out.incomplete=true end
      for _,e in ipairs(labs) do
        visited=visited+1
        if visited>256 then out.incomplete=true; break end
        if e.valid then
          out.labs=out.labs+1
          local inputs,compatible={},true
          for _,name in pairs(e.prototype.lab_inputs or {}) do inputs[name]=true end
          for _,ing in ipairs(t.research_unit_ingredients or {}) do if not inputs[ing.name] then compatible=false end end
          if compatible then
            out.compatible=out.compatible+1
            local r=api.lab_rate(e,force,t)
            local working=api.working(e)
            local quality=e.quality and e.quality.name or 'normal'
            local key=table.concat({surface.name,e.name,quality,r.speed,r.drain,r.productivity,tostring(working)},'|')
            local g=groups[key]
            if not g then
              g={surface=surface.name,name=e.name,quality=quality,labs=0,working=working,
                speed=r.speed,drain_percent=r.drain,productivity_bonus=r.productivity}
              groups[key]=g
            end
            g.labs=g.labs+1
            if working then
              out.working=out.working+1
              work=work+r.speed*(1+r.productivity)
              packs=packs+r.speed*r.drain/100
            end
          end
        end
      end
    end
  end
  local keys={}
  for k in pairs(groups) do keys[#keys+1]=k end
  table.sort(keys)
  for _,key in ipairs(keys) do
    out.groups[#out.groups+1]=groups[key]
  end
  table.sort(out.missing_surfaces)
  if #out.missing_surfaces>0 then out.incomplete=true end
  out.current_research=force.current_research and force.current_research.name or false
  if work>0 and not out.incomplete then out.pack_equivalents_per_nominal_unit=packs/work end
  out.assumption='working compatible labs keep these relative speeds, drain and productivity with all required packs supplied; fresh normal-quality full-durability pack equivalents, not inventory item counts'
  return out
end

function M.query(force,t,level,api)
  local out=M.summary(force,t,level)
  local rate,window,fallback,as_of=api.rate(force.name)
  out.rate={work_per_tick=rate,window_ticks=window,fallback=fallback or false,
    as_of_tick=as_of,age_ticks=as_of and game.tick-as_of or nil,
    current_research=force.current_research and force.current_research.name or false,
    basis='measured research progress, including productivity; one level alone, excludes queue wait and supply changes'}
  if out.remaining_units==0 then out.eta_seconds=0
  elseif rate and rate>0 then out.eta_seconds=out.remaining_units*t.research_unit_energy/rate/60 end
  out.eta=out.eta_seconds and api.minutes(out.eta_seconds*60) or 'unavailable: no measured positive research rate'
  out.nominal_packs_per_unit,out.nominal_packs_full,out.nominal_packs_remaining={},{},{}
  out.cohort=M.cohort(force,t,api)
  local ratio=out.cohort.pack_equivalents_per_nominal_unit
  if ratio then out.physical_packs_remaining={} end
  for _,ing in ipairs(t.research_unit_ingredients or {}) do
    out.nominal_packs_per_unit[ing.name]=ing.amount
    out.nominal_packs_full[ing.name]=out.full_units*ing.amount
    out.nominal_packs_remaining[ing.name]=out.remaining_units*ing.amount
    if ratio then out.physical_packs_remaining[ing.name]=out.remaining_units*ing.amount*ratio end
  end
  if not ratio then out.physical_demand='unavailable: no working compatible cohort or census incomplete' end
  return out
end
return M
