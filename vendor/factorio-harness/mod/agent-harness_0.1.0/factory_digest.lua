-- Operator-only factory digest. Completed surveys supply machine/fuel counts; trace remembers
-- the visible endpoint lane readings it already made. Research/use facts reuse the census,
-- engine counters and a small loadout read. No new surface scans. Missing is unknown.
return function(api)
  local M={operator={}}
  local MAX_ENDS,MAX_SURFACES,KEEP=128,16,18000
  function M.end_seen(force,surface,pos,lanes)
    if not (force and surface and pos) then return end
    local st=api.state()
    st.digest_ends=st.digest_ends or {}
    local key=force.name..'/'..surface.index..'/'..pos.x..','..pos.y
    local rows=st.digest_ends
    if not rows[key] then
      local count,oldest,at=0,nil,math.huge
      for k,row in pairs(rows) do
        count=count+1
        if row.tick<at or row.tick==at and (not oldest or k<oldest) then oldest,at=k,row.tick end
      end
      if count>=MAX_ENDS then rows[oldest]=nil end
    end
    rows[key]={force=force.name,surface=surface.index,tick=game.tick,position={x=pos.x,y=pos.y},lanes=lanes}
  end
  -- (d26 batch244, Astra #2455) the survey's machines short of an item ingredient, read again now (the first
  -- HELD_CHECKS of the digest, HELD_LINES worded a surface): still short with an input inserter off by its circuit or
  -- logistic condition while its source holds the item (supply.held_check): held_back {read, held, lines}.
  local HELD_CHECKS,HELD_LINES=24,2
  local function held_back(g,index,checks)
    if not (g.machines and api.held_check) or checks<=0 then return checks end
    local surface=game.get_surface(index)
    local names={}
    for name in pairs(g.machines) do names[#names+1]=name end
    table.sort(names)
    local read,held,lines=0,0,{}
    for _,name in ipairs(names) do
      for _,pos in ipairs((g.machines[name].positions or {}).item_ingredient_shortage or {}) do
        if checks<=0 then break end
        checks=checks-1
        local ok,e=pcall(surface.find_entity,name,pos)
        if ok and e and e.valid and api.status_name and api.status_name(e)=='item_ingredient_shortage' then
          read=read+1
          local okh,h,items=pcall(api.held_check,e)
          if okh and h then
            held=held+1
            if #lines<HELD_LINES then
              for _,item in ipairs(items) do
                if h[item] then
                  local okl,l=pcall(api.held_line,h[item],item)
                  lines[#lines+1]=string.format('%s (%g,%g) short of %s: %s',name,e.position.x,e.position.y,item,okl and l or 'an input inserter off by its condition')
                  break
                end
              end
            end
          end
        end
      end
    end
    if read>0 then g.held_back={read=read,held=held,lines=#lines>0 and lines or nil} end
    return checks
  end
  function M.operator.factory_digest(a)
    a=a or {}
    local force=game.forces[a.force or 'player']
    assert(force,'unknown force')
    local st=api.state()
    local groups,keys={},{}
    local function group(index)
      if groups[index] then return groups[index] end
      local surface=game.get_surface(index)
      if not surface or surface.platform then return nil end
      local g={surface=surface.name,ends={}}
      groups[index]=g;keys[#keys+1]=index
      return g
    end
    for key,entry in pairs(st.survey_cache or {}) do
      local name,index=key:match('^(.*)/(%d+)$')
      if name==force.name then
        local g=group(tonumber(index))
        if g then
          g.survey_tick=entry.digest and entry.digest.tick or entry.tick
          g.survey_age_s=math.max(0,math.floor((game.tick-g.survey_tick)/60))
          -- (d20 batch55 P1) its last background refresh failed: when and why (the survey keeps its tick)
          if entry.refresh_failed and entry.refresh_failed.tick>=g.survey_tick then g.refresh_failed=entry.refresh_failed end
          if entry.digest then g.machines=entry.digest.machines;g.fuel=entry.digest.fuel;g.belts=entry.digest.belts
          else g.survey_unknown='cached survey predates digest fields' end
        end
      end
    end
    local old=0
    for _,row in pairs(st.digest_ends or {}) do
      if row.force==force.name then
        if row.tick<=game.tick and game.tick-row.tick<=KEEP then
          local g=group(row.surface)
          if g then g.ends[#g.ends+1]={position=row.position,lanes=row.lanes,age_s=math.floor((game.tick-row.tick)/60)} end
        else old=old+1 end
      end
    end
    table.sort(keys,function(x,y) return groups[x].surface<groups[y].surface end)
    local out={}
    local checks=HELD_CHECKS
    for i=1,math.min(#keys,MAX_SURFACES) do
      local g=groups[keys[i]]
      table.sort(g.ends,function(x,y) return x.position.y<y.position.y or x.position.y==y.position.y and x.position.x<y.position.x end)
      checks=held_back(g,keys[i],checks)
      out[#out+1]=g
    end
    return {tick=game.tick,surfaces=out,research_use=api.use_lines and api.use_lines(force) or nil,
      more_surfaces=#keys>MAX_SURFACES and #keys-MAX_SURFACES or nil,
      old_end_observations=old,scope='completed cached planetary surveys; belt endpoints observed by trace in the last 5 game minutes (at most 128 remembered); held_back: the first 24 machines the surveys found short of an item, read again now (their feeders); no new scan'}
  end
  return M
end
