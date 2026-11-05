-- Astra #2898: guard-1015 from shift140/edge-guard-verified.json, with/without its repair.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local copy=require('budgetrates').copy
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function refused(fn,x) local ok,e=pcall(fn); assert(not ok,'unexpected acceptance'); has(e,x) end
game={tick=114950150}
prototypes={item={rocket={},['railgun-ammo']={},['firearm-magazine']={}},space_location={aquilo={},['solar-system-edge']={}}}
local C=require('conditions'){}
local make=require('scheduler')
local state={}; local player={index=1}; local broken=false; local reads=0
local api={state=function() return state end,player=function() return player end,handlers={},
  busy=function() return false end,stop=function() end,stop_index=function() end,
  validate_condition=C.validate,condition=function() reads=reads+1; if broken then error('fixture read unavailable',0) end return false,'not yet' end}
local lanes=require('queue_lanes'){scheduler=make(api),factory=make,base=api,is_read=function() return false end}
local h=lanes.handlers
local guard={scope='plan',['goto']='recover',when={['until']='all',conditions={
  {['until']='platform_progress',platform='Asterion',from='aquilo',to='solar-system-edge',at_least=0.000001},
  {['until']='budget_below',platform='Asterion',km=5000,turnaround={km=5000,back_to='aquilo',margin=0.5,
    reserve={rocket=5000,['railgun-ammo']=1500,['firearm-magazine']=700},items={'rocket','railgun-ammo','firearm-magazine'}},
    windows={180,300},require='all',missing='pending'}}}}
local lane='platform:Asterion'
local function submit(g)
  return h.queue_submit(player,{lane=lane,mode='replace',steps={{action='wait_ticks',args={ticks=50000},label='recover'}},guards={g}})
end
local function status() return h.queue_status(player,{lane=lane,history=0}) end
local function edit(g)
  local st=status(); g=copy(g); g.id=st.guards[1].id
  return h.queue_edit(player,{lane=lane,expected_revision=st.revision,guards={replace={g}}})
end
local invalid=copy(guard); invalid.when.conditions[2].turnaround.km=nil
refused(function() submit(invalid) end,'turnaround.km | turnaround.fraction')
submit(copy(guard))
local before=status(); local id=before.guards[1].id
refused(function() edit(invalid) end,'turnaround.km | turnaround.fraction')
assert(status().revision==before.revision and status().guards[1].id==id,'rejected edit changed the queue')
edit(guard)
local accepted=status().guards[1].when.conditions[2]
assert(accepted.km==5000 and accepted.turnaround.km==5000 and accepted.turnaround.margin==0.5)
assert(accepted.turnaround.reserve.rocket==5000 and accepted.windows[2]==300 and accepted.missing=='pending')
local fraction=copy(guard); fraction.when.conditions[2].turnaround.km=nil; fraction.when.conditions[2].turnaround.fraction=0.5
submit(copy(fraction)); edit(fraction)
assert(status().guards[1].when.conditions[2].turnaround.fraction==0.5)
-- Every static turnaround requirement is shared with the direct endurance read.
local E=require('endurance'){}
for _,case in ipairs({{'km',-1},{'fraction',0},{'back_to','absent'},{'speed_floor',0},{'margin',3},
  {'reserve',-1},{'reserve',{rocket=-1}},{'items',{}},{'items',{'absent'}},
  {'return_allowance',{}},{'windows',{42}}}) do
  local bad=copy(guard); local ta=bad.when.conditions[2].turnaround
  if case[1]=='fraction' then ta.km=nil end
  ta[case[1]]=case[2]
  local fragment=case[1]=='windows' and 'windows' or 'turnaround.'..case[1]
  refused(function() submit(bad) end,fragment)
  refused(function() edit(bad) end,fragment)
  refused(function() E.read(player,{platform='Asterion',turnaround=ta}) end,fragment)
end
local both=copy(guard); both.when.conditions[2].turnaround.fraction=0.5
refused(function() submit(both) end,'turnaround.km | turnaround.fraction')
refused(function() edit(both) end,'turnaround.km | turnaround.fraction')
-- Persistent errors stay prominent with history suppressed and in the list of all lanes.
broken=true
local function tick(n) for _=1,n do game.tick=game.tick+1; lanes.tick() end end
tick(30)
local st=status(); local e=st.guards[1].read_error
assert(e.checks>=2 and not e.cleared_tick)
has(st.guards[1].saw,'fixture read unavailable')
has(st.guard_read_errors,st.guards[1].id..': read error since tick '..e.first_tick)
has(st.guard_read_errors,'fixture read unavailable')
has(h.queue_status(player,{}).lanes.platforms.Asterion.guard_read_errors,st.guard_read_errors)
local prior=reads; status(); lanes.lanes(1); assert(reads==prior,'status performed a condition read')
broken=false; tick(10)
assert(status().guard_read_errors==nil and status().guards[1].read_error.cleared_tick)
assert(lanes.lanes(1).platforms.Asterion.guard_read_errors==nil)
broken=true; tick(10)
assert(status().guards[1].read_error.first_tick>e.first_tick,'new failure must start a new run')
print('d36_batch423: guard submit/edit, shared turnaround validation, persistent/recovered read error summaries: ok')
