-- SW: a quota-OFF minute can be a deficit while longer windows show surplus.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local D=require('budgetrates')
local W=require('budgetwindows')
local E=require('endurance'){}
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn); assert(not ok); has(tostring(e),x) end
local function rate(seconds,m,u) return D.rate(seconds..'s',100000-seconds*60,100000,m,u) end
local cfg=W.config({60,180,300,'leg'},'all')
local o={v=3000,flown_km=20000,back_km=100000,out_km=5000,margin=.2,reserve={rocket=2540},selected={rocket=true}}
local function fixture(deficit)
  return {{name='rocket',stock=2600,made=20,used=10,made10=0,used10=50,within_step=true,
    windows={last_1_min=rate(60,0,50),last_3_min=rate(180,deficit and 0 or 100,50),
      last_5_min=rate(300,deficit and 0 or 100,50),whole_leg=rate(1000,deficit and 0 or 200,100)}},
    {name='repair-pack',stock=100,made=0,used=0,made10=0,used10=0,windows={whole_leg={unavailable='no departure baseline'}}}}
end
local function report(items,options,config) return W.build(config or cfg,items,options or o,E.return_budget) end
local items=fixture(false); items[1].within_step=nil
local rows,b=E.return_budget(items,o)
assert(b.out_km_max<5000,'default short deficit still binds')
local r=report(items)
local check=W.evaluate(r,cfg,5000)
eq(check.met,false); eq(check.binding_windows,1)
for _,part in ipairs{'60s: binding','180s: not binding','300s: not binding','leg: not binding','rocket NET -50/min','rocket NET +'} do has(check.line,part) end
eq(r.budgets[1].items[1].rate_basis.start_tick,96400)
eq(r.budgets[1].items[1].rate_basis.made,0); eq(r.budgets[1].items[1].rate_basis.used,50)
eq(r.budgets[1].items[2].not_selected,true)
eq(W.evaluate(report(fixture(true)),cfg,5000).met,true)
-- Count semantics, measured zero, and a deficit never zeroed by within_step or a cap.
eq(W.evaluate(r,W.config(cfg.windows,1),5000).met,true)
eq(W.evaluate(r,W.config(cfg.windows,2),5000).met,false)
local partial=fixture(false); partial[1].windows.last_3_min=rate(180,0,50)
eq(W.evaluate(report(partial),W.config(cfg.windows,2),5000).met,true)
partial[1].windows.last_1_min=rate(60,0,0)
eq(W.evaluate(report(partial),cfg,5000).windows[1].bound,false)
eq(report(fixture(true)).budgets[1].items[1].net_used,50,'explicit mode keeps the measured deficit even within a batch')
-- No data binds; the rate stays unknown, including a zero-duration source.
local missing=fixture(false); missing[1].windows.last_3_min=nil
missing[1].windows.last_5_min={unavailable='counter reset',net_per_min=0}
missing[1].windows.whole_leg=rate(0,0,0)
check=W.evaluate(report(missing),cfg,5000)
eq(check.met,true); eq(check.binding_windows,4)
has(check.line,'missing data counts as binding'); has(check.line,'rocket NET unknown')
eq(check.windows[3].nets[1].net_per_min,nil)
eq(W.evaluate(nil,cfg,5000).met,true)
local missing_item=D.copy(o); missing_item.selected={['railgun-ammo']=true}
eq(W.evaluate(report(items,missing_item),cfg,5000).met,true)
local no_speed=D.copy(o); no_speed.v=nil
check=W.evaluate(report(fixture(true),no_speed),cfg,5000)
eq(check.met,true); has(check.line,'no planning speed'); has(check.line,'rocket NET -50/min')
-- Same reserve, margin, selection and caller allowance formula for each window.
local allowance=D.copy(o); allowance.allowance={km=100000,items={rocket=10}}
local allowed=report(items,allowance).budgets[1].items[1]
eq(allowed.reserve,2540); eq(allowed.usable,50); eq(allowed.allowance,10)
eq(allowed.out_km_max,-8800) -- ((50-10)/50*3000 - 20000)/2
-- Invalid configs rejected at submission; normalization never mutates the caller.
eq(W.config(nil,nil),nil); eq(W.config({60},nil).require,'all')
for _,bad in ipairs{{},{60,60},{120},{60,'180'},{[1]=60,[3]=300},{60,180,300,'leg',60}} do fails(function() W.config(bad,'all') end,'windows') end
for _,bad in ipairs{0,5,1.5,'any',false} do fails(function() W.config(cfg.windows,bad) end,'require') end
fails(function() W.config(nil,'all') end,'require needs windows')
local c={['until']='budget_below',platform='Resolute',km=5000,turnaround={km=25000},windows=cfg.windows,require='all'}
local args=W.arguments(c); eq(args.windows[1],60); eq(c.turnaround.windows,nil)
args.windows[1]=300; eq(c.windows[1],60)
local both=D.copy(c); both.turnaround.windows={60}; fails(function() W.arguments(both) end,'not both')
print('d29_batch364: short deficit/long surplus, all deficits, counts, unknowns and unchanged budget inputs: ok')
-- Predicate integration: default unchanged; normalized options key the cache; evidence detached.
game={tick=100000}
local pl={valid=true,name='Resolute',space_connection={name='edge-shattered'}}
local p={force={platforms={pl}}}; local reads=0; local payload
local current=items
local C=require('conditions'){
 leg=function() return {from='solar-system-edge',to='shattered-planet',back=false} end,
 return_budget=function(_,_,ta)
   reads=reads+1
   local rows,bind=E.return_budget(current,o)
   payload={items=rows,binds=bind,window_budgets=ta.windows and report(current,o,W.config(ta.windows,ta.require))}
   return payload
 end}
C.validate(c)
local default=D.copy(c); default.windows=nil; default.require=nil
eq(C.check(p,default),true)
local met,saw=C.check(p,c); eq(met,false); has(saw,'1/4 windows'); eq(reads,2)
c.require=1; eq(C.check(p,c),true); eq(reads,3)
eq(#c.evidence.return_budget.items,2); eq(#c.evidence.return_budget.window_budgets.budgets,4)
eq(c.evidence.window_check.scope,'budget_below km'); eq(c.evidence.window_check.windows[1].nets[1].net_per_min,-50)
payload.window_budgets.budgets[1].items[1].rate_basis.made=999
eq(c.evidence.return_budget.window_budgets.budgets[1].items[1].rate_basis.made,0)
c.require='all'; current=fixture(true)
eq(C.check(p,c),true); eq(reads,4)
c.km=-100000; eq(C.check(p,c),false); eq(reads,4); eq(c.evidence,nil)
c.km=5000; c.windows={180,300,'leg'}; eq(C.check(p,c),true); eq(reads,5)
c.turnaround.windows=c.windows; c.turnaround.require=c.require; c.windows=nil; c.require=nil
eq(C.check(p,c),true); eq(reads,5,'equivalent nested options reuse cached read')
for _,bad in ipairs{both,{['until']='budget_below',platform='Resolute',km=5,turnaround={km=1},require=1}} do
  fails(function() C.validate(bad) end,bad==both and 'not both' or 'require needs windows')
end
print('d29_batch364: predicate dispatch, cache keys, saw and full detached evidence: ok')

-- The turnaround read validates the same options; different windows may bind on different items.
fails(function() E.read({}, {platform='Resolute',turnaround={km=1,windows={60,60}}}) end,'windows')
local different=fixture(true)
different[2]={name='railgun-ammo',stock=1,windows={last_1_min=rate(60,0,1),last_3_min=rate(180,0,1),last_5_min=rate(300,0,1),whole_leg=rate(1000,0,1)}}
different[1].windows.last_1_min=rate(60,100,0)
local both_selected=D.copy(o); both_selected.selected={rocket=true,['railgun-ammo']=true}
local mix=report(different,both_selected)
eq(mix.budgets[1].binds.name,'railgun-ammo')
eq(W.evaluate(mix,cfg,5000).met,true)
print('d29_batch364: turnaround validation and different binding items across windows: ok')
