-- SW: explicit same-leg, per-item corroboration, including Astra/Sol's 18:52 clarifications.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local D=require('budgetrates'); local W=require('budgetwindows'); local E=require('endurance'){}
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn); assert(not ok); has(tostring(e),x) end
local function rate(seconds,m,u,now) now=now or 100000; return D.rate(seconds..'s',now-seconds*60,now,m,u) end
local cfg=W.config({60,180,300,'leg'},'all')
local o={v=3000,flown_km=20000,back_km=100000,out_km=5000,margin=.2,reserve={rocket=2540},selected={rocket=true},now=100000,leg={start_tick=0}}
local function fixture(deficit)
 return {{name='rocket',stock=2600,made=20,used=10,made10=0,used10=50,within_step=true,
  windows={last_1_min=rate(60,0,50),last_3_min=rate(180,deficit and 0 or 100,50),
   last_5_min=rate(300,deficit and 0 or 100,50),last_10_min=rate(600,deficit and 0 or 200,100),whole_leg=rate(1000,deficit and 0 or 200,100)}},
  {name='repair-pack',stock=100,made=0,used=0,made10=0,used10=0,windows={whole_leg={unavailable='no departure baseline'}}}}
end
local function report(items,options,config) return W.build(config or cfg,items,options or o,E.return_budget) end
local items=fixture(false); items[1].within_step=nil
local rows,b=E.return_budget(items,o); assert(b.out_km_max<5000,'default short deficit still binds')
local r=report(items); local check=W.evaluate(r,cfg,5000)
eq(check.met,false); eq(check.items[1].binding_windows,1)
for _,x in ipairs{'same item','full same-leg windows only','rocket: 1/4','60s: binding NET -50/min','180s: clear NET +','300s: clear NET +','leg: clear NET +'} do has(check.line,x) end
eq(r.budgets[1].items[1].rate_basis.start_tick,96400); eq(r.budgets[1].items[1].rate_basis.made,0); eq(r.budgets[1].items[1].rate_basis.used,50)
eq(r.budgets[1].items[2].not_selected,true)
eq(W.evaluate(report(fixture(true)),cfg,5000).met,true)
eq(W.evaluate(r,W.config(cfg.windows,1),5000).met,true); eq(W.evaluate(r,W.config(cfg.windows,2),5000).met,false)
local partial=fixture(false); partial[1].windows.last_3_min=rate(180,0,50)
eq(W.evaluate(report(partial),W.config(cfg.windows,2),5000).met,true)
partial[1].windows.last_1_min=rate(60,0,0)
eq(W.evaluate(report(partial),cfg,5000).items[1].windows[1].state,'clear')
eq(report(fixture(true)).budgets[1].items[1].net_used,50,'explicit mode does not zero within_step deficits')
-- Missing may bind or remain pending, never clear or turn into zero. Unselected missing rows do not count.
local missing=fixture(true); missing[1].windows.last_3_min=nil; missing[1].windows.last_5_min={unavailable='counter reset',net_per_min=0}
missing[1].windows.whole_leg=rate(0,0,0)
check=W.evaluate(report(missing),cfg,5000); eq(check.met,true); eq(check.items[1].binding_windows,4)
has(check.line,'missing=binding'); has(check.line,'NET unknown'); eq(check.items[1].windows[3].net_per_min,nil)
local pending=W.config(cfg.windows,'all','pending')
check=W.evaluate(report(missing,o,pending),pending,5000)
eq(check.met,false); eq(check.pending,true); eq(check.items[1].pending_windows,3); has(check.line,'ready tick unknown')
eq(W.evaluate(report(missing,o,pending),W.config(cfg.windows,1,'pending'),5000).met,true)
eq(W.evaluate(nil,cfg,5000).met,true); eq(W.evaluate(nil,pending,5000).pending,true)
local missing_item=D.copy(o); missing_item.selected={['railgun-ammo']=true}
eq(W.evaluate(report(items,missing_item),cfg,5000).met,true)
local no_speed=D.copy(o); no_speed.v=nil
check=W.evaluate(report(fixture(true),no_speed,pending),pending,5000)
eq(check.met,false); eq(check.pending,true); has(check.line,'no planning speed'); has(check.line,'NET -50/min')
local allowance=D.copy(o); allowance.allowance={km=100000,items={rocket=10}}
local allowed=report(items,allowance).budgets[1].items[1]
eq(allowed.reserve,2540); eq(allowed.usable,50); eq(allowed.allowance,10); eq(allowed.out_km_max,-8800)
-- Different binding items in different windows never satisfy all (or a count) together.
local split=fixture(false); local second=D.copy(split[1]); second.name='railgun-ammo'; second.stock=1
split[1].windows.last_1_min=rate(60,0,50); split[1].windows.last_3_min=rate(180,100,0)
second.windows.last_1_min=rate(60,100,0); second.windows.last_3_min=rate(180,0,50)
split[2]=second
local both=D.copy(o); both.selected={rocket=true,['railgun-ammo']=true}
local two=W.config({60,180},'all')
check=W.evaluate(report(split,both,two),two,5000); eq(check.met,false)
eq(check.windows[1].binding_items[1],'rocket'); eq(check.windows[2].binding_items[1],'railgun-ammo')
eq(W.evaluate(report(split,both,two),W.config({60,180},2),5000).met,false)
eq(W.evaluate(report(split,both,two),W.config({60,180},1),5000).met,true)
print('d29_batch364: short deficit, all deficits, missing policies, counts and same-item corroboration: ok')
-- 600 seconds means a full same-leg ten minutes, including the oldest native bucket; never a shorter fallback.
local long=W.config({60,300,600},'all','pending')
local young=D.copy(o); young.leg={start_tick=1000}; young.now=10000
check=W.evaluate(report(fixture(true),young,long),long,5000)
eq(check.met,false); eq(check.pending,true); eq(check.items[1].windows[3].eligible_tick,37081)
has(check.line,'eligible from tick 37081'); has(check.line,'no shorter fallback')
local only600=W.config({600},'all','pending')
local grow=fixture(true); young.now=37080; grow[1].windows.last_10_min=D.native('last 10 min',37080,10,0,100)
eq(W.evaluate(report(grow,young,only600),only600,5000).pending,true)
young.now=37081; grow[1].windows.last_10_min=D.native('last 10 min',37081,10,0,100)
eq(W.evaluate(report(grow,young,only600),only600,5000).met,true)
-- A mislabeled shorter interval or an old-leg/partial whole-leg baseline remains unavailable even after warmup.
grow[1].windows.last_10_min=rate(300,0,100,37081)
check=W.evaluate(report(grow,young,only600),only600,5000); eq(check.pending,true); has(check.line,'shorter than the named window')
local whole=W.config({'leg'},'all','pending'); grow[1].windows.whole_leg=rate(1000,0,100)
young.leg.start_tick=50000; young.now=100000
check=W.evaluate(report(grow,young,whole),whole,5000); eq(check.pending,true); has(check.line,'before this leg boundary')
young.leg.start_tick=0; grow[1].windows.whole_leg.partial=true
eq(W.evaluate(report(grow,young,whole),whole,5000).pending,true)
-- Direction/connection/platform changes and stops key the boundary, before freight has caught up.
local pl={index=77,name='Resolute',space_connection={name='edge'}}
local leg={from='aquilo',to='solar-system-edge',back=false}
local seg={kind='leg',from=leg.from,to=leg.to,start=1000}
eq(W.leg(pl,leg,seg,10000).start_tick,1000)
leg={from='solar-system-edge',to='aquilo',back=true}
eq(W.leg(pl,leg,seg,20000).start_tick,20000); eq(W.leg(pl,leg,seg,21000).start_tick,20000)
seg={kind='leg',from=leg.from,to=leg.to,start=20040}
eq(W.leg(pl,leg,seg,22000).start_tick,20040)
leg.back=false; eq(W.leg(pl,leg,seg,25000).start_tick,25000)
W.stopped(pl,26000); eq(W.leg(pl,leg,seg,27000).start_tick,27000)
pl.space_connection={name='other'}; eq(W.leg(pl,leg,seg,28000).start_tick,28000)
pl.name='Renamed'; eq(W.leg(pl,leg,seg,29000).start_tick,29000)
pl={index=77,name='Renamed',space_connection={name='other'}}; eq(W.leg(pl,leg,seg,30000).start_tick,30000)
seg.start=31000; eq(W.leg(pl,leg,seg,32000).start_tick,31000)
print('d29_batch364: full 60/300/600 coverage, bucket eligibility ticks, no cross-leg or shorter samples: ok')
-- Validation and caller normalization.
eq(W.config(nil,nil),nil); eq(W.config({60},nil).missing,'binding')
for _,bad in ipairs{{},{60,60},{120},{60,'180'},{[1]=60,[3]=300},{60,180,300,600,'leg',60}} do fails(function() W.config(bad,'all') end,'windows') end
for _,bad in ipairs{0,5,1.5,'any',false} do fails(function() W.config(cfg.windows,bad) end,'require') end
for _,bad in ipairs{'ignore',false,0} do fails(function() W.config({60},'all',bad) end,'missing') end
fails(function() W.config(nil,'all') end,'need windows')
fails(function() E.read({}, {platform='Resolute',turnaround={km=1,windows={60,60}}}) end,'windows')
local c={['until']='budget_below',platform='Resolute',km=5000,turnaround={km=25000},windows=cfg.windows,require='all',missing='pending'}
local args=W.arguments(c); eq(args.windows[1],60); eq(c.turnaround.windows,nil); args.windows[1]=300; eq(c.windows[1],60)
local conflict=D.copy(c); conflict.turnaround.missing='binding'; fails(function() W.arguments(conflict) end,'not both')
-- Predicate: default unchanged, window/missing changes key the cache, readiness refreshes before ten seconds.
game={tick=100000}; pl={valid=true,name='Resolute',space_connection={name='edge-shattered'}}
local p={force={platforms={pl}}}; local reads=0; local payload; local current=items; local refresh=false
local C=require('conditions'){
 leg=function() return {from='solar-system-edge',to='shattered-planet',back=false} end,
 return_budget=function(_,_,ta)
  reads=reads+1; local rows,bind=E.return_budget(current,o)
  payload={items=rows,binds=bind,window_budgets=ta.windows and report(current,o,W.config(ta.windows,ta.require,ta.missing))}
  if refresh then payload.window_budgets.next_ready_tick=game.tick+30 end
  return payload
 end}
C.validate(c)
local default=D.copy(c); default.windows=nil; default.require=nil; default.missing=nil; eq(C.check(p,default),true)
local met,saw=C.check(p,c); eq(met,false); has(saw,'1/4 windows'); eq(reads,2)
c.require=1; eq(C.check(p,c),true); eq(reads,3)
eq(#c.evidence.return_budget.items,2); eq(#c.evidence.return_budget.window_budgets.budgets,4)
eq(c.evidence.window_check.scope,'budget_below km'); eq(c.evidence.window_check.items[1].windows[1].net_per_min,-50)
payload.window_budgets.budgets[1].items[1].rate_basis.made=999
eq(c.evidence.return_budget.window_budgets.budgets[1].items[1].rate_basis.made,0)
c.require='all'; current=fixture(true); eq(C.check(p,c),true); eq(reads,4)
c.km=-100000; eq(C.check(p,c),false); eq(reads,4); eq(c.evidence,nil)
c.km=5000; c.windows={180,300,'leg'}; eq(C.check(p,c),true); eq(reads,5)
c.turnaround.windows=c.windows; c.turnaround.require=c.require; c.turnaround.missing=c.missing
c.windows=nil; c.require=nil; c.missing=nil; eq(C.check(p,c),true); eq(reads,5)
refresh=true; c.turnaround.missing='binding'; eq(C.check(p,c),true); eq(reads,6)
game.tick=game.tick+29; C.check(p,c); eq(reads,6)
game.tick=game.tick+1; C.check(p,c); eq(reads,7,'read at eligibility tick, before cache expiry')
print('d29_batch364: validation, dispatch, option cache keys, readiness refresh and detached evidence: ok')
current=fixture(true); current[1].windows.last_3_min=nil; refresh=false; c.turnaround.missing='pending'
met,saw=C.check(p,c); eq(met,false); has(saw,'pending (not met)'); eq(c.evidence,nil)
-- Guard status states the same-item/full-leg rule; composite firing retains the check and every source row.
current=fixture(true); c.turnaround.missing='binding'
local state={active={}}; local player={index=1,valid=true,force=p.force}
local eta=require('waiteta'){}
local S=require('scheduler'){state=function() return state end,player=function() return player end,handlers={},
 busy=function() return false end,stop=function() end,stop_index=function() end,claim=function() end,direct_action=function() end,
 condition=function(p,cond)
  if cond['until']=='all' then cond.conditions[1].evidence={progress=.1,tick=game.tick}; return C.check(p,cond.conditions[2]) end
  return C.check(p,cond)
 end,validate_condition=function(cond) return cond end,wait_info=function(out,record) return eta.info(out,record) end,outcome=function() return 'done' end}
S.handlers.queue_submit(player,{steps={{action='wait_ticks',args={ticks=1000}}},guards={{when=D.copy(c)}}})
local revision=S.handlers.queue_status(player,{}).revision
local baseline=S.handlers.queue_edit(player,{expected_revision=revision,guards={replace={}}}).guards[1].baseline
has(baseline,'same item'); has(baseline,'full same-leg'); has(baseline,'missing=binding')
S.handlers.queue_submit(player,{mode='replace',steps={{action='wait_ticks',args={ticks=1000}}},guards={{when={['until']='all',conditions={{['until']='platform_progress'},D.copy(c)}}}}})
for _=1,30 do game.tick=game.tick+1; S.tick() end
local evidence
for _,h in ipairs(S.handlers.queue_status(player,{history='all'}).history) do if h.action=='guard' then evidence=h.result.evidence end end
assert(evidence); eq(evidence.progress,.1)
local member=evidence.budget_conditions[1]
eq(member.window_check.met,true); eq(member.window_check.binding_items[1],'rocket')
eq(#member.return_budget.items,2); eq(#member.return_budget.window_budgets.budgets,3)
eq(member.return_budget.window_budgets.budgets[1].items[1].rate_basis.used,50)
print('d29_batch364: pending predicate, guard description and complete composite receipt: ok')
