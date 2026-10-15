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
    for i=1,math.min(#keys,MAX_SURFACES) do
      local g=groups[keys[i]]
      table.sort(g.ends,function(x,y) return x.position.y<y.position.y or x.position.y==y.position.y and x.position.x<y.position.x end)
      out[#out+1]=g
    end
    return {tick=game.tick,surfaces=out,research_use=api.use_lines and api.use_lines(force) or nil,
      more_surfaces=#keys>MAX_SURFACES and #keys-MAX_SURFACES or nil,
      old_end_observations=old,scope='completed cached planetary surveys; belt endpoints observed by trace in the last 5 game minutes (at most 128 remembered); no new scan'}
  end
  return M
end
