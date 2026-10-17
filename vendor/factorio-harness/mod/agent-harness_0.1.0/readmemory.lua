-- Plain, bounded observations. A hidden read never resolves a LuaEntity.
return function(api)
  local M={}
  local function copy(v,seen,budget)
    local t=type(v)
    if t=='string' or t=='number' or t=='boolean' then return v end
    if t~='table' then return nil end
    seen=seen or {};budget=budget or {n=0}
    if seen[v] then return nil end
    seen[v]=true;local out={}
    for k,x in pairs(v) do
      budget.n=budget.n+1;assert(budget.n<=16000,'observation exceeds memory limit')
      if type(k)=='string' or type(k)=='number' then out[k]=copy(x,seen,budget) end
    end
    seen[v]=nil;return out
  end
  local function store()
    local s=api.state();s.read_memory=s.read_memory or {entries={},slots={},next=1}
    local m=s.read_memory;m.read_entries=m.read_entries or {};m.read_slots=m.read_slots or {};m.read_next=m.read_next or 1;return m
  end
  local function key(p,q,kind) return p.force.name..'|'..p.surface.name..'|'..q.x..','..q.y..'|'..kind end
  local function put(p,q,kind,value,box)
    local m=store();local k=key(p,q,kind)
    local v=copy(value)
    -- Background sightings cannot evict detailed reads made by agents.
    local summary=kind=='summary'
    local entries,slots=summary and m.entries or m.read_entries,summary and m.slots or m.read_slots
    local cursor=summary and 'next' or 'read_next'
    if not entries[k] then
      local old=slots[m[cursor]];if old then entries[old]=nil end
      slots[m[cursor]]=k;m[cursor]=m[cursor]%(summary and 2048 or 256)+1
    end
    entries[k]={force=p.force.name,surface=p.surface.name,position=copy(q),kind=kind,value=v,box=copy(box),tick=game.tick}
  end
  function M.observe(e,p)
    if not e.valid or e.type=='character' or e.type=='resource' then return end
    p=p or {force=e.force,surface=e.surface}
    if not api.visible(p,e.position) then return end
    local v={name=e.name,type=e.type,position=copy(e.position),unit_number=e.unit_number,direction=e.direction,
      status_name=api.status_name(e),detail='last observed entity summary'}
    if e.type=='entity-ghost' then v.ghost_name=e.ghost_name end
    put(p,e.position,'summary',v,e.bounding_box)
    if api.belt_observe and e.surface and e.force and e.bounding_box then api.belt_observe(e,p) end
  end
  local function kind(action,a) return action=='trace' and ('trace:'..tostring(a.forward==true)..':'..tostring(a.all==true)) or 'inspect' end
  local function recall(p,a,action)
    local q=api.position(a.position);local best,rank
    local m=store()
    local direct=m.read_entries[key(p,q,kind(action,a))] or m.entries[key(p,q,kind(action,a))]
    if direct and ((a.name and a.name~=direct.value.name and a.name~=direct.value.entity and a.name~=direct.value.belt and a.name~=direct.value.ghost_name)
      or a.unit_number and a.unit_number~=direct.value.unit_number) then direct=nil end
    local candidates={}
    if direct then candidates[1]=direct
    else for _,pool in ipairs{m.read_entries,m.entries} do for _,r in pairs(pool) do candidates[#candidates+1]=r end end end
    for _,r in ipairs(candidates) do
      local v=r.value
      if r.force==p.force.name and r.surface==p.surface.name and (r.kind==kind(action,a) or r.kind=='summary')
        and (not a.name or a.name==v.name or a.name==v.entity or a.name==v.belt or a.name==v.ghost_name) and (not a.unit_number or a.unit_number==v.unit_number) then
        local b=r.box
        local hit=(r.position.x-q.x)^2+(r.position.y-q.y)^2<=0.5^2 or b and b.left_top and
          q.x>=b.left_top.x and q.y>=b.left_top.y and q.x<=b.right_bottom.x and q.y<=b.right_bottom.y
        local score=r.kind=='summary' and 1 or 2
        if hit and (not best or score>rank or score==rank and r.tick>best.tick) then best,rank=r,score end
      end
    end
    if not best then return nil end
    local out=copy(best.value)
    if action=='trace' and best.kind=='summary' then
      out={entity=out.name,position=out.position,summary=out,trace_unknown='no trace was recorded for this entity'}
    end
    out.by='last seen memory';out.observed_tick=best.tick;out.age_ticks=game.tick-best.tick;out.age_s=(game.tick-best.tick)/60
    out.current=false;out.in_reach=nil
    -- A sighting keeps no contents (Muse, shift18 12:46: a chest read "only basic info"): say why there is no holds.
    if best.kind=='summary' and action~='trace' then
      out.holds='unknown: its chunk is not in sight now (no radar or character of ours sees it), and the game shows an '..
        'entity\'s contents only in sight (remote view there shows the map as last charted); this is what was seen of it, with no inspect recorded'
    end
    out.memory='all fields are from the recorded observation; current state is unknown'
    return out
  end
  function M.read(p,a,action,live)
    if not a.position then return live(p,a) end
    local q=api.position(a.position)
    if api.visible(p,q) then
      local out=live(p,a)
      if type(out)=='table' then pcall(put,p,q,kind(action,a),out) end
      return out
    end
    local out=recall(p,a,action)
    if action=='trace' and (not out or out.trace_unknown) and api.belt_trace then out=api.belt_trace(p,a) or out end
    if not out then
      -- what the map says of the chunk (B1): never charted, or charted and out of sight with our last sight of it
      local g=api.ground_state and api.ground_state(p,q)
      error(string.format('no recorded %s observation at (%g,%g) on %s; %s',action,q.x,q.y,p.surface.name,g or 'current chunk not visible'),0)
    end
    return out
  end
  return M
end
