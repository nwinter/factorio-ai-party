-- d29 batch364 SW (Astra's Resolute40g): caller-selected corroboration across measured rate windows.
-- No gate state changes a rate. Unknown data binds conservatively; the default forecast is left intact.
local D=require('budgetrates')
local M={}
local KEYS={[60]='last_1_min',[180]='last_3_min',[300]='last_5_min',leg='whole_leg'}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
function M.config(windows,required)
  if windows==nil then assert(required==nil,'require needs windows'); return nil end
  assert(type(windows)=='table' and #windows>=1 and #windows<=4,'windows: 1..4 distinct entries, 60, 180, 300 seconds or "leg"')
  local seen,list={},{}
  for k,v in pairs(windows) do
    assert(type(k)=='number' and k==math.floor(k) and k>=1 and k<=#windows,'windows must be a dense list')
    assert(KEYS[v],'windows entries are 60, 180, 300 seconds or "leg"')
    assert(not seen[v],'windows contains a duplicate: '..tostring(v)); seen[v]=true
  end
  for i=1,#windows do assert(windows[i]~=nil,'windows must be a dense list'); list[i]=windows[i] end
  required=required==nil and 'all' or required
  assert(required=='all' or (finite(required) and required==math.floor(required) and required>=1 and required<=#list),
    'require is "all" or a count from 1 to the number of windows')
  return {windows=list,require=required,needed=required=='all' and #list or required}
end
function M.arguments(c)
  local ta=c.turnaround
  if c.windows~=nil or c.require~=nil then
    assert(ta.windows==nil and ta.require==nil,'set windows/require on budget_below or inside turnaround, not both')
    local cfg=M.config(c.windows,c.require)
    ta=D.copy(ta); ta.windows=cfg.windows; ta.require=cfg.require
    return ta,cfg
  end
  return ta,M.config(ta.windows,ta.require)
end
-- The same stock, geometry, selected items, margin, reserves and caller allowance; only the measured rates differ.
function M.build(cfg,items,o,budget)
  local result={windows=D.copy(cfg.windows),require=cfg.require,needed=cfg.needed,budgets={}}
  for _,window in ipairs(cfg.windows) do
    local known,unknown,missing,seen={},{},{},{}
    local function absent(name,why,source)
      local selected=not o.selected or o.selected[name]
      unknown[#unknown+1]={name=name,unavailable=why,not_selected=not selected or nil,rate_basis=D.copy(source)}
      if selected then missing[#missing+1]={name=name,reason=why} end
    end
    for _,it in ipairs(items) do
      seen[it.name]=true
      local s=it.windows and it.windows[KEYS[window]]
      if not s or s.unavailable or not finite(s.made) or not finite(s.used) or not finite(s.rate_minutes) or s.rate_minutes<=0 then
        absent(it.name,s and s.unavailable or 'no measured counter interval for this window',s)
      else
        local m,u=s.made/s.rate_minutes,s.used/s.rate_minutes
        known[#known+1]={name=it.name,stock=it.stock,scope=it.scope,made=m,used=u,made10=m,used10=u,
          from=s.window,window=s.window,rate_candidates={phase=s,recent=s}}
      end
    end
    for name in pairs(o.selected or {}) do if not seen[name] then absent(name,'selected item absent from the budget read') end end
    local rows,binds=budget(known,o)
    for _,r in ipairs(rows) do
      if not r.not_selected and r.rate_basis.budget_net_used>0 and r.out_km_max==nil then
        r.budget_unavailable='no planning speed for a measured deficit'
        missing[#missing+1]={name=r.name,reason=r.budget_unavailable}
      end
    end
    for _,r in ipairs(unknown) do rows[#rows+1]=r end
    result.budgets[#result.budgets+1]={window=window,items=rows,missing_items=missing,
      unavailable=#rows==0 and 'budget has no item rows' or nil,
      binds=binds and {name=binds.name,out_km_max=binds.out_km_max,spare_km=binds.spare_km} or nil}
  end
  return result
end
function M.evaluate(report,cfg,km)
  local by={}; for _,w in ipairs(report and report.budgets or {}) do by[w.window]=w end
  local out={require=cfg.require,needed=cfg.needed,threshold_km=km,binding_windows=0,total=#cfg.windows,windows={}}
  local lines={}
  for _,window in ipairs(cfg.windows) do
    local w=by[window]
    local unknown=not w or w.unavailable or #(w.missing_items or {})>0
    local b=w and w.binds
    local bound=not not (unknown or (b and finite(b.out_km_max) and b.out_km_max<km))
    local r={window=window,bound=bound,binds=D.copy(b),missing_items=D.copy(w and w.missing_items),
      unavailable=not w and 'window absent from the budget read' or w.unavailable,nets={}}
    local nets={}
    for _,it in ipairs(w and w.items or {}) do
      if not it.not_selected then
        local basis=it.rate_basis
        local n=not it.unavailable and basis and basis.net_per_min or nil
        r.nets[#r.nets+1]={name=it.name,net_per_min=n,net_sign='made - used',unavailable=it.unavailable or it.budget_unavailable,
          rate_basis=D.copy(basis),out_km_max=it.out_km_max}
        nets[#nets+1]=it.name..(finite(n) and string.format(' NET %+g/min',n) or ' NET unknown')
      end
    end
    local why={}
    for _,m in ipairs(w and w.missing_items or {}) do why[#why+1]=m.name..' ('..m.reason..')' end
    local label=window=='leg' and 'leg' or tostring(window)..'s'
    r.line=label..': '..(bound and 'binding' or 'not binding')
      ..(unknown and '; missing data counts as binding: '..(r.unavailable or table.concat(why,', ')) or '')
      ..(b and string.format('; %s at most %g km farther',b.name,b.out_km_max) or '')
      ..(#nets>0 and '; '..table.concat(nets,', ') or '')
    out.windows[#out.windows+1]=r; lines[#lines+1]=r.line
    if bound then out.binding_windows=out.binding_windows+1 end
  end
  out.met=out.binding_windows>=out.needed
  out.line=string.format('%d/%d windows bind under %g km (require %s): ',out.binding_windows,out.total,km,tostring(cfg.require))..table.concat(lines,' | ')
  return out
end
return M
