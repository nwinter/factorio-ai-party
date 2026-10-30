-- d29 batch363 RW: provenance beside the conservative budget, never an input to its arithmetic.
-- No tick work. Statistics graph samples, leg counter snapshots, and stock/conditions at reads only.
local Q = require('qflow')
local M = {}
local function try(f) local ok,v=pcall(f); if ok then return v end end
function M.copy(t)
  if type(t)~='table' then return t end
  local r={}; for k,v in pairs(t) do r[k]=M.copy(v) end; return r
end
function M.rate(label, first, last, made, used, minutes)
  local r={window=label,start_tick=first,end_tick=last,made=made,used=used,net=made-used,net_sign='made - used'}
  minutes=minutes or (last-first)/3600
  r.rate_minutes=minutes
  if minutes>0 then r.made_per_min=made/minutes; r.used_per_min=used/minutes; r.net_per_min=(made-used)/minutes end
  return r
end
-- The unsliced count interpolates the oldest of 300 completed buckets and adds the current partial bucket.
-- Sample 1 changes on the tick after a bucket boundary (verified on Factorio 2.0.77).
function M.native(label, now, minutes, made, used)
  local width=minutes*3600/300
  local boundary=math.floor((now-1)/width)*width
  local r=M.rate(label,now-1-minutes*3600,now-1,made,used,minutes)
  r.read_tick=now; r.bucket_ticks=width
  r.oldest_bucket={start_tick=boundary-minutes*3600,end_tick=boundary-minutes*3600+width,weight=1-(now-1-boundary)/width}
  r.current_bucket={start_tick=boundary,read_tick=now}
  r.note='engine interpolated window (nominal endpoints); oldest bucket weighted, current partial included; counts can be fractional, not exact event deltas'
  return r
end
function M.windows(stats,name,fluid,now,P,flow)
  if not stats then return {unavailable='production statistics unavailable'} end
  local out={}
  if P.one_minute then out.last_1_min=M.native('last 1 min',now,1,flow('input',P.one_minute),flow('output',P.one_minute)) end
  if not P.ten_minutes then return out end
  local sums={input={},output={}}
  for _,cat in ipairs({'input','output'}) do
    local total=0
    local names={name}
    if not fluid then
      names={}
      local count=cat=='input' and stats.get_input_count or stats.get_output_count
      for _,q in ipairs(Q.qualities()) do
        local id=q=='normal' and name or {name=name,quality=q}
        if count(id)>0 then names[#names+1]=id end
      end
    end
    local arg={category=cat,precision_index=P.ten_minutes,count=true}
    for i=1,150 do
      arg.sample_index=i
      for _,id in ipairs(names) do arg.name=id; total=total+stats.get_flow_count(arg) end
      if i==90 then sums[cat][3]=total end
    end
    sums[cat][5]=total
  end
  local last=math.floor((now-1)/120)*120
  for _,n in ipairs({3,5}) do
    local r=M.rate('last '..n..' min (completed 2 s buckets)',last-n*3600,last,sums.input[n],sums.output[n])
    r.bucket_ticks=120; r.age_ticks=now-last
    out['last_'..n..'_min']=r
  end
  return out
end
function M.whole(leg,name,stats,fluid,now,is_ammo)
  local baseline=leg and (fluid and leg.fuel0 or is_ammo and leg.ammo0)
  if not baseline then return {window='whole leg',unavailable='no departure counter baseline for this item'} end
  local a=baseline[name] or {made=0,used=0}
  local made,used
  if fluid then made=stats.get_input_count(name); used=stats.get_output_count(name)
  else made=Q.count(stats,name,'input'); used=Q.count(stats,name,'output') end
  if made<a.made or used<a.used then return {window='whole leg',unavailable='production counters reset since departure'} end
  local r=M.rate('whole leg',leg.start,now,made-a.made,used-a.used)
  r.partial=leg.partial or nil
  return r
end
function M.phase(label,minutes,made,used)
  return {window=label,rate_minutes=minutes,made=made*minutes,used=used*minutes,net=(made-used)*minutes,
    made_per_min=made,used_per_min=used,net_per_min=made-used,net_sign='made - used',
    endpoints_unavailable='moving intervals accumulated across legs, halved after two hours; no contiguous window',
    counts_basis='weighted phase production counts; budget_made_per_min/budget_used_per_min retain the existing rounded budget rates'}
end
function M.summary(r)
  if not r or r.unavailable then return 'unavailable' end
  return string.format('%s [%s..%s] made %g used %g NET %+g (%+g/min)',r.window or '?',
    r.start_tick and tostring(r.start_tick) or '?',r.end_tick and tostring(r.end_tick) or '?',r.made or 0,r.used or 0,r.net or 0,r.net_per_min or 0)
end
function M.line(r)
  local w=r.windows or {}; local p={}
  for _,k in ipairs({'whole_leg','last_1_min','last_3_min','last_5_min'}) do p[#p+1]=k..': '..M.summary(w[k]) end
  return 'rate used: '..M.summary(r.rate_basis)..'; '..table.concat(p,'; ')
end
-- Extrema of observed usable stock only. No interpolation, no claim about stock between reads or before installation.
function M.extrema(store,key,leg,name,value,reserve,margin,scope,now)
  local identity=tostring(leg and leg.start)..':'..tostring(leg and leg.from)..':'..tostring(leg and leg.to)
  local rec=store[key]
  if not rec or rec.leg~=identity then rec={leg=identity,items={}}; store[key]=rec end
  local k=name..':'..tostring(reserve)..':'..tostring(margin)..':'..tostring(scope)
  local x=rec.items[k]
  if not x then
    local n,oldest=0,nil
    for id,v in pairs(rec.items) do n=n+1; if not oldest or v.last_tick<rec.items[oldest].last_tick then oldest=id end end
    if n>=32 then rec.items[oldest]=nil end
  end
  if not x then x={min=value,max=value,min_tick=now,max_tick=now,first_tick=now,samples=0,leg_start_tick=leg and leg.start,
    coverage='reads only; unsampled stock and pre-installation extrema unknown',continuous=false}; rec.items[k]=x end
  if value<x.min then x.min=value; x.min_tick=now end
  if value>x.max then x.max=value; x.max_tick=now end
  if x.last_tick~=now then x.samples=x.samples+1 end
  x.last_tick=now
  return M.copy(x)
end
-- Conditions that explicitly reference a budget item, including belt caps. Do not infer that every condition is a cap,
-- or that an off gate guarantees later production. Only entity references/methods are cached, never conditions.
local GATE_TYPES={'assembling-machine','furnace','inserter','transport-belt','underground-belt','splitter','pump'}
local gate_entities={}
local function gate_list(pl,now)
  local key=pl.index
  local rec=key and gate_entities[key]
  if rec and rec.n==pl.surface.count_entities_filtered{type=GATE_TYPES,force=pl.force} then
    rec.tick=now; return rec.entities
  end
  local list={}
  for _,e in ipairs(pl.surface.find_entities_filtered{type=GATE_TYPES,force=pl.force}) do
    list[#list+1]={entity=e,read=e.get_control_behavior}
  end
  if key then
    for k,x in pairs(gate_entities) do if now-x.tick>36000 then gate_entities[k]=nil end end
    gate_entities[key]={entities=list,n=#list,tick=now}
  end
  return list
end
local function read_gates(pl,wanted,now)
  local out={}; for name in pairs(wanted) do out[name]={tick=now,conditions={},scope='item-referencing circuit/logistic enable conditions on machines, inserters, belts and pumps; indirect signals are not attributed'} end
  for _,entry in ipairs(gate_list(pl,now)) do
    local e=entry.entity
    local cb=entry.read()
    if cb then
      for _,kind in ipairs({'circuit','logistic'}) do
        local enabled=try(function() return kind=='circuit' and cb.circuit_enable_disable or kind=='logistic' and cb.connect_to_logistic_network end)
        local c=enabled and try(function() return kind=='circuit' and cb.circuit_condition or cb.logistic_condition end)
        local cond=c
        if cond then
          local matched={}
          for _,s in ipairs({cond.first_signal or {},cond.second_signal or {}}) do
            if wanted[s.name] and (s.type==nil or s.type=='item' or s.type=='fluid') then matched[s.name]=true end
          end
          for name in pairs(matched) do
            local connected=kind~='circuit' or try(function() return e.get_circuit_network(defines.wire_connector_id.circuit_red)~=nil or e.get_circuit_network(defines.wire_connector_id.circuit_green)~=nil end)
            local state=connected==false and 'ignored (unwired)' or c.fulfilled==true and 'on' or c.fulfilled==false and 'off' or 'unknown'
            local list=out[name].conditions
            list[#list+1]={entity=e.name,unit_number=e.unit_number,position=M.copy(e.position),kind=kind,condition=M.copy(cond),
              fulfilled=c.fulfilled,state=state,status=e.status,tick=now}
          end
        end
      end
    end
  end
  return out
end
function M.gates(pl,wanted,now)
  -- A cached entity method throws if its entity was removed. Refresh once on that path, including a same-count
  -- replacement, instead of a second 5000-entity valid-flag walk on every Resolute read.
  local ok,out=pcall(read_gates,pl,wanted,now)
  if ok then return out end
  if pl.index then gate_entities[pl.index]=nil end
  return read_gates(pl,wanted,now)
end
return M
