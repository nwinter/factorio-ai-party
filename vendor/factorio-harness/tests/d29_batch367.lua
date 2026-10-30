-- A joining peer restores storage but none of the server's module upvalues.
-- Both camera reports turned Resolute back ten ticks late after budget cache loss.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function copy(v,seen)
  if type(v)~='table' or v.lua_object then return v end
  seen=seen or {}; if seen[v] then return seen[v] end
  local out={}; seen[v]=out
  for k,x in pairs(v) do out[copy(k,seen)]=copy(x,seen) end
  return out
end
local pl={lua_object=true,index=49,name='Resolute',valid=true,space_connection={name='edge-shattered'}}
local p={force={platforms={pl}}}
local leg={from='solar-system-edge',to='shattered-planet',back=false}
local value,launches,err,ready=10000,0,nil,nil
local function peer(st)
  local reads={budget=0,launch=0,state=0}
  local C=require('conditions'){
    state=function() reads.state=reads.state+1; return st end,
    leg=function() return leg end,
    return_budget=function()
      reads.budget=reads.budget+1
      if err then error(err,0) end
      return {binds={name='rocket',out_km_max=value},window_budgets=ready and {next_ready_tick=ready} or nil}
    end,
    launch_count=function()
      reads.launch=reads.launch+1
      return {total=launches,launched=launches,landed=0,in_flight=launches,loaded=0,line='launches '..launches}
    end}
  eq(reads.state,0,'on_load construction must not touch storage')
  return C,reads
end
local function budget()
  return {['until']='budget_below',platform='Resolute',km=5000,turnaround={km=0}}
end

-- Two distinct conditions in one all/any must retain independent read clocks.
local st={guard={['until']='any',conditions={budget(),budget()}},launch={['until']='launches_at_least',platform='Resolute',n=1,window=60}}
local server,sreads=peer(st)
game={tick=1000}
eq(server.check(p,st.guard.conditions[1]),false)
game.tick=1010; eq(server.check(p,st.guard.conditions[2]),false)
eq(server.check(p,st.launch),false)
local saved=copy(st)
local client,creads=peer(saved)
value,launches=0,1
game.tick=1020
local sm,ss=server.check(p,st.guard)
local cm,cs=client.check(p,saved.guard)
eq(sm,false); eq(cm,sm,'joining peer must use the saved budget, not a fresh one'); eq(cs,ss)
eq(creads.budget,0,'no early budget read on join')
eq(client.check(p,saved.launch),server.check(p,st.launch),'launch count survives join')
eq(creads.launch,0,'no early launch count on join')
game.tick=1069; eq(client.check(p,saved.launch),false)
game.tick=1070; eq(client.check(p,saved.launch),true); eq(server.check(p,st.launch),true)
eq(creads.launch,1); eq(saved.launch.evidence.tick,st.launch.evidence.tick)
game.tick=1599; eq(client.check(p,saved.guard),false); eq(server.check(p,st.guard),false)
game.tick=1600
eq(client.check(p,saved.guard),true); eq(server.check(p,st.guard),true)
eq(creads.budget,1); eq(saved.guard.conditions[1].evidence.tick,st.guard.conditions[1].evidence.tick)
eq(saved.guard.conditions[1].evidence.tick,1600)
eq(client.check(p,saved.guard.conditions[2]),false,'second condition keeps its own deadline')
game.tick=1610; eq(client.check(p,saved.guard.conditions[2]),true); eq(creads.budget,2)
-- The caches do not become condition arguments exposed by queue_status or reused plans.
eq(st.guard.conditions[1].budget_read,nil); eq(st.guard.conditions[1].budget_kept,nil)
print('d29_batch367: restored budget/launch caches keep independent clocks, decisions and evidence: ok')

-- Cached failures also survive loading, then expire; a new leg still invalidates immediately.
st={c=budget()}; server,sreads=peer(st)
game.tick=2000; err='budget unavailable'; eq(server.check(p,st.c),false)
saved=copy(st); client,creads=peer(saved); err=nil
game.tick=2001
cm,cs=client.check(p,saved.c); eq(cm,false); assert(cs:find('budget unavailable',1,true)); eq(creads.budget,0)
game.tick=2600; eq(client.check(p,saved.c),true); eq(creads.budget,1)
saved=copy(st); client,creads=peer(saved)
leg={from='shattered-planet',to='solar-system-edge',back=true}
game.tick=2002; eq(client.check(p,saved.c),true); eq(creads.budget,1,'new leg invalidates a restored failure')
saved.c.turnaround.margin=0.2; client.check(p,saved.c); eq(creads.budget,2,'changed arguments invalidate')
pl.space_location={name='solar-system-edge'}; eq(client.check(p,saved.c),false)
pl.space_location=nil; client.check(p,saved.c); eq(creads.budget,3,'a stop clears the saved read')
print('d29_batch367: restored failures expire; leg, arguments and stop still invalidate: ok')

-- Strong storage keys must not retain completed/abandoned conditions forever.
game.tick=4000
for _=1,40 do client.check(p,budget()) end
game.tick=4600; client.check(p,saved.c)
local kept=saved.condition_reads.budget.by
local count=0; for c in pairs(kept) do count=count+1; eq(c,saved.c) end
eq(count,1,'expired condition reads released without a Lua GC dependency')
print('d29_batch367: expired condition keys are pruned deterministically: ok')

-- A read can observe a turn/stop before freight's next sample. A cold module must
-- retain that newer boundary instead of accepting an older matching segment.
do
  local W=dofile('mod/agent-harness_0.1.0/budgetwindows.lua')
  local st={}
  local l={from='edge',to='shattered',back=false}
  local seg={kind='leg',from='edge',to='shattered',start=100}
  eq(W.leg(pl,l,seg,200,st).start_tick,100)
  W.stopped(pl,300,st)
  eq(W.leg(pl,l,seg,400,st).start_tick,400)
  local restored=copy(st)
  local cold=dofile('mod/agent-harness_0.1.0/budgetwindows.lua')
  eq(cold.leg(pl,l,seg,500,restored).start_tick,W.leg(pl,l,seg,500,st).start_tick)
  eq(cold.leg(pl,l,seg,500,restored).start_tick,400,'saved post-stop boundary survives stale freight')
  W.stopped(pl,600,st); restored=copy(st)
  cold=dofile('mod/agent-harness_0.1.0/budgetwindows.lua')
  eq(cold.leg(pl,l,seg,700,restored).start_tick,700,'saved stop still invalidates')
  st={}; eq(W.leg(pl,l,nil,800,st).start_tick,800)
  cold=dofile('mod/agent-harness_0.1.0/budgetwindows.lua')
  eq(cold.leg(pl,l,nil,900,copy(st)).start_tick,800,'unrecorded leg keeps first observation')
end
print('d29_batch367: window boundaries and pending stops survive loading: ok')

-- When no scheduled stop is reachable, freight infers direction from movement.
-- Both peers need the same previous observation before the next sample.
do
  prototypes={space_connection={}}
  local conn={name='edge-shattered',from={name='edge'},to={name='shattered'},length=4000000}
  local ship={index=49,name='Resolute',valid=true,space_connection=conn,distance=0.4,speed=1,
    schedule={current=1,records={{station='nowhere'}}},last_visited_space_location={name='edge'}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  eq(F.leg(ship).back,false)
  local restored=copy(st)
  local cold=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return restored end}
  ship.distance=0.39
  eq(cold.leg(ship).back,F.leg(ship).back,'restored direction observation')
  eq(cold.leg(ship).to,F.leg(ship).to,'repeated observation agrees')
end
print('d29_batch367: movement history survives loading: ok')
