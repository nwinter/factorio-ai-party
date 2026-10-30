-- d29 batch364 SW: explicit same-leg measurements; one item must corroborate across the requested windows.
local D=require('budgetrates')
local M={}
local KEYS={[60]='last_1_min',[180]='last_3_min',[300]='last_5_min',[600]='last_10_min',leg='whole_leg'}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
function M.config(windows,required,missing)
  if windows==nil then assert(required==nil and missing==nil,'require/missing need windows'); return nil end
  assert(type(windows)=='table' and #windows>=1 and #windows<=5,'windows: 1..5 distinct entries, 60, 180, 300, 600 seconds or "leg"')
  local seen,list={},{}
  for k,v in pairs(windows) do
    assert(type(k)=='number' and k==math.floor(k) and k>=1 and k<=#windows,'windows must be a dense list')
    assert(KEYS[v],'windows entries are 60, 180, 300, 600 seconds or "leg"')
    assert(not seen[v],'windows contains a duplicate: '..tostring(v)); seen[v]=true
  end
  for i=1,#windows do assert(windows[i]~=nil,'windows must be a dense list'); list[i]=windows[i] end
  required=required==nil and 'all' or required
  assert(required=='all' or (finite(required) and required==math.floor(required) and required>=1 and required<=#list),
    'require is "all" or a count from 1 to the number of windows')
  missing=missing==nil and 'binding' or missing
  assert(missing=='binding' or missing=='pending','missing is "binding" or "pending"')
  return {windows=list,require=required,needed=required=='all' and #list or required,missing=missing}
end
function M.arguments(c)
  local ta=c.turnaround
  if c.windows~=nil or c.require~=nil or c.missing~=nil then
    assert(ta.windows==nil and ta.require==nil and ta.missing==nil,'set windows/require/missing on budget_below or inside turnaround, not both')
    local cfg=M.config(c.windows,c.require,c.missing)
    ta=D.copy(ta); ta.windows=cfg.windows; ta.require=cfg.require; ta.missing=cfg.missing
    return ta,cfg
  end
  return ta,M.config(ta.windows,ta.require,ta.missing)
end
-- No tick sampler. Freight's matching segment supplies the initial boundary; subsequent reads also key by the
-- platform object/name, connection, endpoints and direction, like batch360. An observed stop invalidates it.
-- A first-observed boundary can be newer than freight's segment. It is history, not a rebuildable cache:
-- joining peers must restore it, including a stop observed before freight's next sample (d29 batch367).
local standalone={}  -- module fixtures; runtime callers pass storage's state
local function records(state)
  if not state then return standalone end
  state.budget_window_legs=state.budget_window_legs or {}
  return state.budget_window_legs
end
function M.stopped(pl,now,state) records(state)[pl.index or pl]={platform=pl,stopped_tick=now} end
function M.leg(pl,l,segment,now,state)
  local legs=records(state)
  local key=pl.index or pl
  local old=legs[key]
  local connection=pl.space_connection and pl.space_connection.name
  local matching=segment and segment.kind=='leg' and not segment['end'] and finite(segment.start)
    and segment.from==l.from and segment.to==l.to
  local changed=old and (old.platform~=pl or old.name~=pl.name or old.connection~=connection
    or old.from~=l.from or old.to~=l.to or old.back~=l.back or old.stopped_tick)
  local start=matching and segment.start or (old and not changed and old.start_tick or now)
  if changed and (not matching or segment.start<=(old.start_tick or old.stopped_tick or now)) then start=now end
  if old and not changed then start=math.max(old.start_tick,start) end
  local r={platform=pl,name=pl.name,connection=connection,from=l.from,to=l.to,back=l.back,start_tick=start}
  legs[key]=r
  return {platform=pl.name,connection=connection,from=l.from,to=l.to,back=l.back,start_tick=start,
    basis=matching and start==segment.start and 'matching recorded flight segment' or 'current direction first observed at this read'}
end
local function availability(window,s,leg,now)
  if not leg or not finite(leg.start_tick) then return 'current-leg boundary unavailable' end
  local ready
  if window~='leg' then
    -- Native windows include a weighted oldest bucket. Wait until that entire bucket is on this leg too.
    local width=window==60 and 12 or 120
    ready=math.ceil(leg.start_tick/width)*width+window*60+1
    if now<ready then return 'full '..window..'s of same-leg data not yet available (no shorter fallback)',ready end
  end
  if window=='leg' and s and not s.unavailable and not s.partial and finite(s.start_tick)
    and s.start_tick>=leg.start_tick and s.rate_minutes==0 then
    return 'no elapsed counter interval on this leg yet',s.start_tick+1
  end
  if not s or s.unavailable or not finite(s.made) or not finite(s.used) or not finite(s.rate_minutes) or s.rate_minutes<=0 then
    return s and s.unavailable or 'no measured counter interval for this window'
  end
  local first=s.oldest_bucket and s.oldest_bucket.start_tick or s.start_tick
  if not finite(first) or first<leg.start_tick then return 'counter interval starts before this leg boundary',ready end
  if window=='leg' and s.partial then return 'whole-leg departure counters are partial; awaiting a fully recorded leg' end
  if window~='leg' and s.rate_minutes*60<window then return 'counter interval shorter than the named window (no fallback)',ready end
end
-- The same stock, geometry, selected items, margin, reserves and caller allowance; only eligible rates differ.
function M.build(cfg,items,o,budget)
  local result={windows=D.copy(cfg.windows),require=cfg.require,missing=cfg.missing,needed=cfg.needed,
    leg=D.copy(o.leg),selected_items={},budgets={}}
  local names={}
  for _,it in ipairs(items) do if not o.selected or o.selected[it.name] then names[it.name]=true end end
  for name in pairs(o.selected or {}) do names[name]=true end
  for name in pairs(names) do result.selected_items[#result.selected_items+1]=name end
  table.sort(result.selected_items)
  for _,window in ipairs(cfg.windows) do
    local known,unknown,missing,seen={},{},{},{}
    local function absent(name,why,source,ready)
      local selected=names[name]
      local basis={window=source and source.window or (window=='leg' and 'whole leg' or tostring(window)..'s'),
        unavailable=why,eligible_tick=ready,leg_start_tick=o.leg and o.leg.start_tick}
      unknown[#unknown+1]={name=name,unavailable=why,eligible_tick=ready,not_selected=not selected or nil,
        rate_basis=basis,excluded_rate_basis=D.copy(source)}
      if selected then
        missing[#missing+1]={name=name,reason=why,eligible_tick=ready}
        if ready and ready>o.now and (not result.next_ready_tick or ready<result.next_ready_tick) then result.next_ready_tick=ready end
      end
    end
    for _,it in ipairs(items) do
      seen[it.name]=true
      local s=it.windows and it.windows[KEYS[window]]
      local why,ready=availability(window,s,o.leg,o.now)
      if why then absent(it.name,why,s,ready)
      else
        local m,u=s.made/s.rate_minutes,s.used/s.rate_minutes
        known[#known+1]={name=it.name,stock=it.stock,scope=it.scope,made=m,used=u,made10=m,used10=u,
          from=s.window,window=s.window,rate_candidates={phase=s,recent=s}}
      end
    end
    for name in pairs(names) do if not seen[name] then absent(name,'selected item absent from the budget read') end end
    local rows,binds=budget(known,o)
    for _,r in ipairs(rows) do
      if not r.not_selected and r.rate_basis.budget_net_used>0 and r.out_km_max==nil then
        r.budget_unavailable='no planning speed for a measured deficit'
        missing[#missing+1]={name=r.name,reason=r.budget_unavailable}
      end
    end
    for _,r in ipairs(unknown) do rows[#rows+1]=r end
    result.budgets[#result.budgets+1]={window=window,items=rows,missing_items=missing,
      binds=binds and {name=binds.name,out_km_max=binds.out_km_max,spare_km=binds.spare_km} or nil}
  end
  return result
end
function M.evaluate(report,cfg,km)
  local by,names={},{}
  for _,name in ipairs(report and report.selected_items or {}) do names[name]=true end
  for _,w in ipairs(report and report.budgets or {}) do
    local rows={}; for _,r in ipairs(w.items or {}) do if not r.not_selected then rows[r.name]=r; names[r.name]=true end end
    by[w.window]=rows
  end
  if not next(names) then names['unavailable budget items']=true end
  local ordered={}; for name in pairs(names) do ordered[#ordered+1]=name end; table.sort(ordered)
  local out={require=cfg.require,missing=cfg.missing,needed=cfg.needed,threshold_km=km,total=#cfg.windows,
    leg=D.copy(report and report.leg),items={},windows={},binding_items={},met=false,pending=false}
  for _,window in ipairs(cfg.windows) do out.windows[#out.windows+1]={window=window,nets={},binding_items={},pending_items={}} end
  local lines={}
  for _,name in ipairs(ordered) do
    local item={name=name,binding_windows=0,pending_windows=0,windows={}}
    local parts={}
    for i,window in ipairs(cfg.windows) do
      local r=by[window] and by[window][name]
      local why=not r and 'item/window absent from the budget read' or r.unavailable or r.budget_unavailable
      local pending=why and cfg.missing=='pending' or false
      local bound=why and cfg.missing=='binding' or not why and r.out_km_max~=nil and r.out_km_max<km or false
      local state=pending and 'pending' or bound and 'binding' or 'clear'
      local n=r and not r.unavailable and r.rate_basis and r.rate_basis.net_per_min or nil
      local row={window=window,name=name,state=state,bound=bound,pending=pending,net_per_min=n,net_sign='made - used',
        unavailable=why,eligible_tick=r and r.eligible_tick,out_km_max=r and r.out_km_max}
      item.windows[#item.windows+1]=row; out.windows[i].nets[#out.windows[i].nets+1]=D.copy(row)
      if bound then item.binding_windows=item.binding_windows+1; out.windows[i].binding_items[#out.windows[i].binding_items+1]=name end
      if pending then item.pending_windows=item.pending_windows+1; out.windows[i].pending_items[#out.windows[i].pending_items+1]=name end
      local label=window=='leg' and 'leg' or tostring(window)..'s'
      row.line=label..': '..state..(finite(n) and string.format(' NET %+g/min',n) or ' NET unknown')
        ..(why and '; missing='..cfg.missing..': '..why..(row.eligible_tick and '; eligible from tick '..row.eligible_tick or '; ready tick unknown') or '')
        ..(r and r.out_km_max and string.format('; at most %g km farther',r.out_km_max) or '')
      parts[#parts+1]=row.line
    end
    item.met=item.binding_windows>=cfg.needed
    item.pending=not item.met and item.binding_windows+item.pending_windows>=cfg.needed
    if item.met then out.met=true; out.binding_items[#out.binding_items+1]=name end
    if item.pending then out.pending=true end
    item.line=name..': '..item.binding_windows..'/'..#cfg.windows..' windows bind; '..table.concat(parts,' | ')
    out.items[#out.items+1]=item; lines[#lines+1]=item.line
  end
  if out.met then out.pending=false end
  out.line=string.format('same item must bind in %s windows under %g km; full same-leg windows only, no fallback; missing=%s; %s. ',
    tostring(cfg.require),km,cfg.missing,out.met and ('met by '..table.concat(out.binding_items,', ')) or out.pending and 'pending (not met)' or 'not met')..table.concat(lines,' || ')
  return out
end
return M
