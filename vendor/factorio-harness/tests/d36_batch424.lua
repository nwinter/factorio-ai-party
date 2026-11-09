-- Aurora: real budget predicate -> scheduler -> lane summaries, including endurance geometry failures.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
prototypes={item={},space_location={aquilo={},['solar-system-edge']={},['shattered-planet']={}},space_connection={}}
for _,shape in ipairs{'single','all','any'} do
  for _,failure in ipairs{'geometry','route','empty'} do
    game={tick=1000}
    local state,reads,actions={},0,0
    local pl={name='Asterion',valid=true,surface={},speed=1,space_connection={name='edge-shattered'}}
    local player={index=1,force={platforms={pl}}}
    local leg={from='solar-system-edge',to='shattered-planet',back=false,flown=0.1,length=4000000,left_km=3600000}
    local mode=failure
    local E=require('endurance'){
      platform=function() return pl end,
      leg=function() if mode=='geometry' then return {} end return leg end,
      path=function() return nil end}
    local C=require('conditions'){
      state=function() return state end,leg=function() return leg end,
      return_budget=function(p,name,ta)
        reads=reads+1
        if mode=='empty' then return nil end
        if mode=='good' then return {binds={name='rocket',out_km_max=10000}} end
        if mode=='unbound' then return {} end
        if mode=='met' then return {binds={name='rocket',out_km_max=100}} end
        return E.read(p,{platform=name,turnaround=ta}).return_budget
      end}
    local make=require('scheduler')
    local api={state=function() return state end,player=function() return player end,
      handlers={circuit_set=function() actions=actions+1; return {} end},
      busy=function() return false end,stop=function() end,stop_index=function() end,
      validate_condition=C.validate,condition=C.check}
    local lanes=require('queue_lanes'){scheduler=make(api),factory=make,base=api,is_read=function() return false end}
    local h,lane=lanes.handlers,'platform:Asterion'
    local c={['until']='budget_below',platform=pl.name,km=5000,turnaround={km=5000,back_to='aquilo'}}
    local when=c
    if shape~='single' then when={['until']=shape,conditions={
      {['until']='tick_at_least',tick=shape=='all' and 0 or 1000000},c}} end
    h.queue_submit(player,{lane=lane,steps={{action='wait_ticks',args={ticks=50000}}},
      guards={{when=when,steps={{action='circuit_set',args={platform=pl.name,position={x=0,y=0},switch_off=true}}}}}})
    local function tick(n) for _=1,n do game.tick=game.tick+1; lanes.tick() end end
    local function status() return h.queue_status(player,{lane=lane,history=0}) end
    tick(30)
    local st=status(); local e=st.guards[1].read_error
    assert(e and e.checks>=2 and not e.cleared_tick)
    local expected=failure=='geometry' and 'flies no connection now' or failure=='route' and 'turnaround.back_to: no way' or 'read returned no budget'
    has(st.guard_read_errors,st.guards[1].id..': read error since tick '..e.first_tick..' ('..e.checks..' checks):')
    has(st.guard_read_errors,expected); has(st.guards[1].saw,expected)
    eq(h.queue_status(player,{}).lanes.platforms.Asterion.guard_read_errors,st.guard_read_errors)
    eq(lanes.lanes(1).platforms.Asterion.guard_read_errors,st.guard_read_errors)
    eq(reads,1); eq(actions,0)
    -- A repaired source cannot clear a cached error early or cause additional reads.
    mode='good'; tick(e.first_tick+599-game.tick)
    assert(status().guard_read_errors); eq(reads,1); eq(actions,0)
    tick(1); st=status()
    eq(reads,2); eq(st.guard_read_errors,nil); assert(st.guards[1].read_error.cleared_tick)
    eq(lanes.lanes(1).platforms.Asterion.guard_read_errors,nil); eq(actions,0)
    -- Facts stay ordinary not-met and stops/no-leg do not call return_budget.
    pl.space_location={name='aquilo'}; tick(10)
    st=status(); has(st.guards[1].saw,'stopped at aquilo'); eq(st.guard_read_errors,nil); eq(reads,2)
    pl.space_location=nil; local flying=leg; leg=nil; tick(10)
    st=status(); has(st.guards[1].saw,'no flight leg'); eq(st.guard_read_errors,nil); eq(reads,2)
    leg=flying; mode='unbound'; tick(10)
    st=status(); has(st.guards[1].saw,'no item used faster'); eq(st.guard_read_errors,nil); eq(reads,3)
    -- A later failure starts a new error run; holding it preserves the guard and hold.
    mode='empty'; tick(600); st=status(); assert(st.guards[1].read_error.first_tick>e.first_tick)
    h.queue_pause(player,{lane=lane})
    local q=state['lane_queues|Asterion'][1]; local held=q.held; assert(q.paused and held)
    local before=reads; tick(610)
    eq(q.held,held); eq(q.paused,true); eq(actions,0); eq(reads,before); eq(#status().guards,1)
    -- A valid met budget still fires the original action after explicit resume.
    mode='met'; h.queue_resume(player,{lane=lane}); tick(20)
    eq(actions,1); eq(#(status().guards or {}),0)
  end
end
print('d36_batch424: real predicate errors/empty reads, geometry/route failures, cache recovery, facts, actions and holds: ok')
