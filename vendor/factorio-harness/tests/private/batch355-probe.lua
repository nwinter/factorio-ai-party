-- Private-copy wrapper only. The host runner wraps a bundled runtime with this function; never deploy to n.
return function(runtime)
  local dispatch=runtime.dispatch
  local function snapshot()
    local f=game.forces.player
    local out={current=f.current_research and f.current_research.name or false,progress=f.research_progress,
      queue={},levels={},saved={},researched={},targets=storage.agent_harness.research_targets or false,
      pending=storage.agent_harness.research_plan or false}
    for i,t in ipairs(f.research_queue or {}) do out.queue[i]=t.name end
    for n,t in pairs(f.technologies) do out.levels[n]=t.level; out.saved[n]=t.saved_progress; out.researched[n]=t.researched end
    return helpers.json_to_table(helpers.table_to_json(out))
  end
  local function canonical(v)
    if type(v)~='table' then return tostring(v) end
    local keys,out={},{}
    for k in pairs(v) do keys[#keys+1]=k end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    for _,k in ipairs(keys) do out[#out+1]=tostring(k)..'='..canonical(v[k]) end
    return '{'..table.concat(out,'|')..'}'
  end
  runtime.dispatch=function(req)
    assert(game.tick_paused,'private batch355 probe requires paused ticks')
    local a=req.args or {}
    if req.action=='batch355_native' then
      local f=game.forces['batch355-native'] or game.create_force('batch355-native')
      local t=f.technologies['low-density-structure-productivity']
      local rows={}
      local multiplier=game.difficulty_settings.technology_price_multiplier
      for _,m in ipairs({0.001,1,1.25,2.5}) do
        game.difficulty_settings.technology_price_multiplier=m
        for _,level in ipairs({1,2,3,15,16,17}) do
          t.level=level+1
          local calculated=runtime.research_cost.units(t,level)
          t.level=level
          rows[#rows+1]={level=level,multiplier=m,raw=helpers.evaluate_expression(t.research_unit_count_formula,{L=level,l=level}),
            calculated=calculated,native=t.research_unit_count,equal=calculated==t.research_unit_count}
        end
      end
      game.difficulty_settings.technology_price_multiplier=multiplier
      return {native=rows}
    elseif req.action=='batch355_fixture' then
      local f=game.forces.player
      local t=f.technologies['low-density-structure-productivity']
      storage.agent_harness.research_targets={player={[t.name]=18}}
      f.research_queue={}
      t.level=15
      if a.saved then t.saved_progress=0.375; f.research_queue={'processing-unit-productivity',t.name,t.name,t.name}
      else f.research_queue={t.name,t.name,t.name}; f.research_progress=0.75 end
      return {fixture=a.saved and 'saved LDS15, then LDS16/17' or 'active LDS15, then LDS16/17',before=snapshot()}
    end
    local before=snapshot()
    local profiler=game.create_profiler()
    local ok,result=pcall(dispatch,req)
    profiler.stop()
    log{'','B355 ',req.id or '?',' ',req.action,' ',profiler}
    local after=snapshot()
    local equal={}
    for k,v in pairs(before) do equal[k]=canonical(v)==canonical(after[k]); assert(equal[k],'query changed '..k) end
    if not ok then result={refused=tostring(result)} end
    result.batch355_proof={equal=equal,before=before,after=after,query_time='server log: B355 '..(req.id or '?')}
    return result
  end
  return runtime
end
