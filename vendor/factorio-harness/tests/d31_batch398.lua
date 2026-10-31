-- BW: schedule departure precedes freight's periodic baseline (Astra #2836).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local W=require('budgetwindows'); local D=require('budgetrates'); local E=require('endurance'){}
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local pl={index=398,valid=true,name='Asterion',space_connection={name='aquilo-solar-system-edge'}}
local p={force={platforms={pl}}}
local leg={from='aquilo',to='solar-system-edge',back=false}
local previous={kind='leg',from=leg.from,to=leg.to,start=92500000}
local segments={previous}; local state={}; local reads=0
local cfg=W.config({60,300},'all','pending')
local c={['until']='budget_below',platform=pl.name,km=1000,turnaround={km=0},windows=cfg.windows,missing='pending'}
local function report(ta)
  local config=W.config(ta.windows,ta.require,ta.missing)
  local o={v=3000,flown_km=0,back_km=0,out_km=0,margin=0,reserve={},now=game.tick,
    selected={rocket=true},leg=W.leg(pl,leg,segments[#segments],game.tick,state)}
  local items={{name='rocket',stock=10000,windows={
    last_1_min=D.rate('60s',game.tick-3601,game.tick-1,0,34),
    last_5_min=D.rate('300s',game.tick-18001,game.tick-1,0,459)}}}
  return {window_budgets=W.build(config,items,o,E.return_budget)}
end
local function conditions()
  return require('conditions'){
    state=function() return state end,leg=function() return leg end,segments=function() return segments end,
    return_budget=function(_,_,ta) reads=reads+1; return report(ta) end}
end
local C=conditions()
game={tick=92572000}
local met,saw=C.check(p,c)
eq(met,false); has(saw,'60s: clear NET -34/min'); has(saw,'300s: clear NET -91.8/min')
-- Same route/key after a stop the guard did not observe.
previous['end']=92572500; segments[#segments+1]={kind='stop',start=92572500,at='aquilo'}
game.tick=92572880 -- departure schedule at 92572871; new segment at 92572920.
met,saw=C.check(p,c)
eq(met,false); has(saw,'60s: pending NET unknown'); has(saw,'300s: pending NET unknown')
has(saw,'aquilo->solar-system-edge'); has(saw,'current-leg baseline'); has(saw,'ready tick unknown')
eq(reads,2)
local r=report({windows=cfg.windows,missing='pending'}).window_budgets
eq(r.leg.start_tick,92572880,'previous departure must not survive missing current baseline')
eq(r.leg.baseline_pending,true); eq(r.next_ready_tick,nil)
eq(r.budgets[1].items[1].rate_basis.net_per_min,nil)
eq(W.evaluate(r,W.config(cfg.windows,'all','binding'),1000).met,true,'missing=binding still meets')
-- No baseline remains unavailable even once the fixed windows have elapsed.
game.tick=92572880+18001
r=report({windows=cfg.windows,missing='pending'}).window_budgets
eq(r.leg.start_tick,92572880); eq(W.evaluate(r,cfg,1000).pending,true)
-- Return to fixture time, restore conditions as on join, then install the baseline.
game.tick=92572919; C=conditions(); C.check(p,c); eq(reads,2,'pending cache survives module reload')
segments[#segments]['end']=92572920
segments[#segments+1]={kind='leg',from=leg.from,to=leg.to,start=92572920}
game.tick=92572920
met,saw=C.check(p,c); eq(met,false); eq(reads,3,'baseline invalidates before 600 ticks')
has(saw,'eligible from tick 92576521'); has(saw,'eligible from tick 92590921')
game.tick=92572921; C.check(p,c); eq(reads,3,'same-leg cache retained')
game.tick=92576520; C.check(p,c)
local before=reads
game.tick=92576521; met,saw=C.check(p,c); eq(reads,before+1); has(saw,'60s: clear NET -34/min'); has(saw,'300s: pending')
game.tick=92590921; met,saw=C.check(p,c); eq(met,false); has(saw,'300s: clear NET -91.8/min')
before=reads; game.tick=92590922; C.check(p,c); eq(reads,before)
-- Same-key baseline loss invalidates a fresh clear cache immediately.
segments[#segments]['end']=game.tick
met,saw=C.check(p,c); eq(reads,before+1); has(saw,'60s: pending'); has(saw,'ready tick unknown')
leg={from='solar-system-edge',to='aquilo',back=true}; game.tick=92590923
met,saw=C.check(p,c); eq(met,false); has(saw,'solar-system-edge->aquilo'); has(saw,'300s: pending')
segments[#segments+1]={kind='leg',from=leg.from,to=leg.to,start=92590924}; game.tick=92590924
before=reads; C.check(p,c); eq(reads,before+1)
-- An observed stop rejects a segment predating this departure.
W.stopped(pl,92591000,state)
r=W.leg(pl,leg,segments[#segments],92591001,state)
eq(r.baseline_pending,true); eq(r.start_tick,92591001)
-- Without explicit windows the historical cache behavior remains unchanged.
local default={['until']='budget_below',platform=pl.name,km=1000,turnaround={km=0}}
local normal_reads=0
local normal=require('conditions'){leg=function() return leg end,segments=function() error('default must not inspect segments') end,
  return_budget=function() normal_reads=normal_reads+1; return {binds={name='rocket',out_km_max=2000}} end}
eq(normal.check(p,default),false); game.tick=game.tick+1; eq(normal.check(p,default),false); eq(normal_reads,1)
-- First-tick startup with a legacy saved boundary/cache, before any periodic flight sample.
state={}; segments={previous}; leg={from=previous.from,to=previous.to,back=false}
previous['end']=nil; game.tick=92572870; C=conditions(); C.check(p,c)
local cached=state.condition_reads.budget.by[c]
cached.baseline_checked=nil; cached.segment_start=nil -- pre-fix persisted cache shape
previous['end']=92572871; segments[#segments+1]={kind='stop',start=92572871}
game.tick=92572871; before=reads
met,saw=C.check(p,c); eq(met,false); eq(reads,before+1); has(saw,'60s: pending')
eq(state.budget_window_legs[pl.index].start_tick,92572871)
local whole=W.config({'leg'},'all','pending')
local options={leg=W.leg(pl,leg,nil,game.tick,state),now=game.tick,selected={rocket=true}}
local pending_leg=W.build(whole,{{name='rocket',windows={whole_leg=D.rate('leg',92500000,game.tick,0,100)}}},options,E.return_budget)
eq(W.evaluate(pending_leg,whole,1000).pending,true,'whole-leg also waits for this departure baseline')
print('d31_batch398: departure pending, missing policies, baseline arrival/loss, reload, eligibility, leg change and same-leg/default cache: ok')
