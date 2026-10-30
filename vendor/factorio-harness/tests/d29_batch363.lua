-- d29 batch363 RW: a cap cycle has a short deficit and a whole-leg surplus; provenance changes no budget.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local D=require('budgetrates')
local E=require('endurance'){}
local function eq(a,b,m) assert(a==b,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
game={tick=83515120}
defines={flow_precision_index={one_minute=1,ten_minutes=2},wire_connector_id={circuit_red=1,circuit_green=2}}
prototypes={item={['firearm-magazine']={type='ammo'},rocket={type='ammo'}},quality={normal={level=0},rare={level=2}}}
local P=defines.flow_precision_index
local whole=D.rate('whole leg',83500140,83512604,276,154)
local recent=D.native('last 1 min',game.tick,1,0,51)
local windows={whole_leg=whole,last_1_min=recent,last_3_min=D.rate('last 3 min',83504280,83515080,200,100),last_5_min=D.rate('last 5 min',83497080,83515080,250,190)}
local item={name='firearm-magazine',stock=5000,made=whole.made_per_min,used=whole.used_per_min,made10=0,used10=51,windows=windows,
 rate_candidates={phase=whole,recent=recent}}
local options={v=3300,flown_km=17000,back_km=100000,margin=.2,reserve=3600}
local rows=E.return_budget({item,{name='rocket',stock=3000,made=0,used=1,made10=0,used10=1,
 rate_candidates={phase=recent,recent=recent},windows=windows}},options)
eq(rows[1].net_used,51); eq(rows[1].rate_basis.net,-51); eq(rows[1].windows.whole_leg.net,122)
local bare=D.copy(item); bare.windows=nil; bare.rate_candidates=nil
local old=E.return_budget({bare},options)
eq(rows[1].out_km_max,old[1].out_km_max,'conservative formula unchanged')
eq(E.budget_window((game.tick-83500140)/3600,P),P.one_minute)
eq(recent.start_tick,83511519); eq(recent.end_tick,83515119)
eq(recent.oldest_bucket.start_tick,83511516); eq(recent.oldest_bucket.end_tick,83511528); eq(recent.oldest_bucket.weight,.75)
eq(whole.start_tick,83500140); eq(whole.end_tick,83512604)
local phase=D.phase('moving phase',60,10,12); eq(phase.start_tick,nil); has(phase.endpoints_unavailable,'no contiguous window')
-- Graphs count every quality and 90/150 completed buckets, excluding the current partial bucket.
local st={get_input_count=function() return 1000 end,get_output_count=function() return 500 end,
 get_flow_count=function(a) return (type(a.name)=='table' and 2 or 1)*(a.category=='input' and 3 or 1) end}
local w=D.windows(st,'rocket',false,180121,P,function(cat) return cat=='input' and 12 or 20 end)
eq(w.last_3_min.start_tick,169320); eq(w.last_3_min.end_tick,180120); eq(w.last_3_min.made,810); eq(w.last_3_min.used,270)
eq(w.last_5_min.start_tick,162120); eq(w.last_5_min.made,1350); eq(w.last_1_min.net,-8)
eq(D.windows(st,'rocket',false,180120,P,function() return 0 end).last_3_min.end_tick,180000)
local leg={start=100,ammo0={rocket={made=10,used=5}}}
local wc=D.whole(leg,'rocket',st,false,3700,true)
eq(wc.made,1990); eq(wc.used,995); eq(wc.start_tick,100); eq(wc.end_tick,3700)
assert(D.whole(leg,'repair-pack',st,false,3700,false).unavailable)
-- Extrema are detached read snapshots, reset for another leg or reserve/margin/scope.
local store={}; local x=D.extrema(store,1,leg,'rocket',100,50,.2,'reaches',200)
local y=D.extrema(store,1,leg,'rocket',60,50,.2,'reaches',300)
eq(x.min,100); eq(y.min,60); eq(y.max,100); eq(y.min_tick,300); eq(y.samples,2); eq(y.continuous,false)
eq(D.extrema(store,1,leg,'rocket',50,100,.2,'reaches',400).samples,1)
eq(D.extrema(store,1,{start=500},'rocket',80,50,.2,'reaches',600).min,80)
-- Actual 2.0.77 control behavior condition shape: fields directly on circuit_condition.
local condition={first_signal={name='rocket'},constant=2400,comparator='<',fulfilled=false}
local cb={circuit_enable_disable=true,circuit_condition=condition}
local connected=true
local entity={name='turbo-transport-belt',unit_number=1,position={x=12.5,y=13.5},status=1,
 get_control_behavior=function() return cb end,get_circuit_network=function() return connected and {} or nil end}
local pl={force={},surface={find_entities_filtered=function() return {entity} end}}
local caps=D.gates(pl,{rocket=true},game.tick)
eq(caps.rocket.conditions[1].state,'off'); eq(caps.rocket.conditions[1].condition.constant,2400)
condition.fulfilled=true; eq(D.gates(pl,{rocket=true},game.tick).rocket.conditions[1].state,'on')
eq(caps.rocket.conditions[1].fulfilled,false)
connected=false; eq(D.gates(pl,{rocket=true},game.tick).rocket.conditions[1].state,'ignored (unwired)')
-- The warm scan retains references only: a newly configured condition on an existing entity is visible immediately.
entity.valid=true; pl.index=77
local finds=0; local entities={entity}
pl.surface.find_entities_filtered=function() finds=finds+1; return entities end
pl.surface.count_entities_filtered=function() return #entities end
cb.circuit_enable_disable=false; eq(#D.gates(pl,{rocket=true},game.tick).rocket.conditions,0)
cb.circuit_enable_disable=true; connected=true
eq(D.gates(pl,{rocket=true},game.tick).rocket.conditions[1].state,'on'); eq(finds,1)
local replacement={valid=true,name=entity.name,position=entity.position,status=1,get_circuit_network=entity.get_circuit_network,
 get_control_behavior=function() return cb end}
entity.valid=false; entities={replacement}
eq(D.gates(pl,{rocket=true},game.tick).rocket.conditions[1].state,'on'); eq(finds,2,'same-count replacement refreshes refs')
entities={}; eq(#D.gates(pl,{rocket=true},game.tick).rocket.conditions,0); eq(finds,3)
print('d29_batch363: short deficit/leg surplus, unchanged formula, endpoints, qualities, extrema and caps: ok')
-- Every row survives firing, including unselected and nonbinding items. No cache alias or stale evidence.
local payload={items=rows,binds={name='firearm-magazine',out_km_max=4086}}
local C=require('conditions'){return_budget=function() return payload end}
local c={['until']='budget_below',platform='Resolute',turnaround={km=25000},km=5000}
local met,saw=C.check({},c); eq(met,true); has(saw,'whole_leg: whole leg [83500140..83512604] made 276 used 154 NET +122'); has(saw,'rate used: last 1 min')
eq(#c.evidence.return_budget.items,2); eq(c.evidence.return_budget.items[2].rate_basis.window,'last 1 min')
payload.items[2].stock=999; eq(c.evidence.return_budget.items[2].stock,3000)
game.tick=game.tick+600; payload.binds=nil; eq(C.check({},c),false); eq(c.evidence,nil)
-- A progress member first in all must not hide the budget's snapshot in scheduler history.
payload.binds={name='firearm-magazine',out_km_max=4086}
local state={active={}}; local player={index=1,valid=true,force={}}
local W=require('waiteta'){}
local S=require('scheduler'){state=function() return state end,player=function() return player end,handlers={},
 busy=function() return false end,stop=function() end,stop_index=function() end,claim=function() end,direct_action=function() end,
 condition=function(p,cond)
   if cond['until']=='all' then cond.conditions[1].evidence={progress=.004,tick=game.tick}; return C.check(p,cond.conditions[2]) end
   return C.check(p,cond)
 end,validate_condition=function(cond) return cond end,wait_info=function(out,record) return W.info(out,record) end,outcome=function() return 'done' end}
S.handlers.queue_submit(player,{steps={{action='wait_ticks',args={ticks=1000}}},guards={{when={['until']='all',conditions={{['until']='platform_progress'},D.copy(c)}}}}})
for _=1,30 do game.tick=game.tick+1; S.tick() end
local evidence
for _,h in ipairs(S.handlers.queue_status(player,{history='all'}).history) do if h.action=='guard' then evidence=h.result.evidence end end
assert(evidence); eq(evidence.progress,.004); eq(#evidence.budget_conditions[1].return_budget.items,2)
eq(evidence.budget_conditions[1].return_budget.items[1].rate_basis.start_tick,83511519)
print('d29_batch363: full direct/composite guard evidence, independent snapshots and cleared stale evidence: ok')
