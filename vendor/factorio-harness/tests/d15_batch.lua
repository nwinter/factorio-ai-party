-- d15 batch (operator 07:50 round): queue outcomes with failed batch entries, replace stopping the active step.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- 11 (Astra): a place_ghosts or build step with failed entries fails; on_fail sees it. ---------------------------
do
  game={tick=0}
  local state,active={},{}
  local players={[1]={index=1}}
  local last={}
  local handlers={
    place_ghosts=function(p,a)
      if a.bad then return {placed=3,failed={{index=2,name='transport-belt',position={x=1.5,y=2.5},error='blocked by stone-furnace'}}} end
      return {placed=4}
    end,
    -- a walking build: the batch's result lands in last.result when the walk ends
    build=function(p,a) active[p.index]=game.tick+3; last[p.index]={outcome='done',result={built=1,failed=a.bad and {{index=2,item='inserter',position={x=4,y=4},error='nothing was placed'}} or nil}}; return {walking=true} end,
    long=function(p,a) active[p.index]=game.tick+100; return {accepted=true} end,
    craft=function() return {started=1} end,
  }
  local stopped=0
  local s=require('scheduler'){
    state=function() return state end,
    player=function(i) return players[i] end,
    handlers=handlers,
    busy=function(p,action) return active[p.index]~=nil end,
    stop=function(p) active[p.index]=nil; stopped=stopped+1 end,stop_index=function(i) active[i]=nil end,
    outcome=function(p) return last[p.index] and last[p.index].outcome end,
    completion=function(p) return last[p.index] end,
    condition=function() return false end,
    validate_condition=function() end,
  }
  local h,p=s.handlers,players[1]
  local function tick() game.tick=game.tick+1; for i,t in pairs(active) do if game.tick>=t then active[i]=nil end end; s.tick() end
  h.queue_submit(p,{steps={{action='place_ghosts',args={}},{action='place_ghosts',args={bad=true}},{action='craft'}}})
  tick()
  local q=h.queue_status(p)
  eq(q.paused,true,'failed entries pause the plan'); eq(q.pending_count,1)
  local e=q.history[#q.history]
  eq(e.ok,false); eq(e.result.entries_failed,1)
  has(e.result.reason,'place_ghosts: 1 entry failed (3 placed); first: #2 transport-belt (1.5,2.5): blocked by stone-furnace')
  eq(q.history[#q.history-1].ok,true,'a clean batch is ok')
  eq(q.plan.failed,1)
  -- on_fail=skip goes on, the entry still reads failed
  h.queue_cancel(p,{})
  h.queue_submit(p,{steps={{action='place_ghosts',args={bad=true},on_fail='skip'},{action='craft'}}})
  tick(); q=h.queue_status(p)
  eq(q.paused,false); eq(q.history[#q.history].action,'craft'); eq(q.history[#q.history-1].ok,false)
  -- a timed build: the completion's result is read
  h.queue_cancel(p,{})
  h.queue_submit(p,{steps={{action='build',args={bad=true}},{action='craft'}}})
  for _=1,5 do tick() end
  q=h.queue_status(p)
  eq(q.paused,true); has(q.history[#q.history].result.reason,'build: 1 entry failed (1 built); first: #2 inserter (4,4): nothing was placed')
  h.queue_cancel(p,{})
  h.queue_submit(p,{steps={{action='build',args={}},{action='craft'}}})
  for _=1,5 do tick() end
  q=h.queue_status(p); eq(q.paused,false); eq(q.history[#q.history].action,'craft'); eq(q.history[#q.history-1].ok,true)

  -- 12 (Sonnet): mode replace stops the active step of an ordinary plan, which is not run again.
  h.queue_cancel(p,{})
  h.queue_submit(p,{steps={{action='long'},{action='craft',label='old'}}})
  tick(); eq(h.queue_status(p).active.action,'long')
  local before=stopped
  q=h.queue_submit(p,{mode='replace',steps={{action='craft',label='new'}}})
  eq(stopped,before+1,'the running action is stopped'); eq(q.active,false); eq(#q.pending,1); eq(q.pending[1].label,'new')
  eq(active[1],nil)
  tick(); q=h.queue_status(p,{history='all',orders=true})
  local stopped_entry
  for _,x in ipairs(q.history) do if x.action=='long' and x.result.stopped_by=='replace' then stopped_entry=x end end
  assert(stopped_entry and stopped_entry.ok==false,'history says the step was stopped by replace')
  has(stopped_entry.result.reason,'stopped by queue_submit mode=replace')
  eq(q.history[#q.history].label,'new'); eq(q.pending_count,0)
  -- append leaves the active step running
  h.queue_submit(p,{steps={{action='long'}}}); tick()
  before=stopped
  q=h.queue_submit(p,{mode='append',steps={{action='craft'}}})
  eq(stopped,before); eq(q.active.action,'long')
  h.queue_cancel(p,{})
end

print('d15_batch: ok')

-- 13 (Muse, Grok): supply's belt lines: tiles holding the item joined into lines, ends and the tile with the most. ------
do
  prototypes={item={},fluid={}}
  local S=require('supply'){state=function() return {} end,integer=function(v,d) return v or d end}
  local t={belt_spots={}}
  local function b(x,y,n,dir,typ) t.belt_spots[#t.belt_spots+1]={x+.5,y+.5,n,dir or 4,typ or 'transport-belt'} end
  -- an east-flowing line x=0..9 on y=0, backed up at its east end; a 2-tile line elsewhere; a lone tile
  for x=0,9 do b(x,0,x<6 and 2 or 8) end
  b(40,40,3,8); b(40,41,3,8)
  b(-20,5,1)
  local lines=S.belt_lines(t,2)
  eq(lines[1],'44 on 10 belt tiles (0.5,0.5)-(9.5,0.5); most 8 at (6.5,0.5); out end (9.5,0.5) 8, in end (0.5,0.5) 2')
  eq(lines[2],'6 on 2 belt tiles (40.5,40.5)-(40.5,41.5); most 3 at (40.5,40.5); out end (40.5,41.5) 3, in end (40.5,40.5) 3')
  eq(lines[3],'1 more belt line holds 1')
  eq(S.belt_lines({belt_spots={}}),nil)
end
print('d15_batch belts: ok')

-- 13 (Grok): wait_until produced: what machines made since the wait began, by their products-finished counter. ------
do
  prototypes={item={['iron-gear-wheel']={}},recipe={['iron-gear-wheel']={name='iron-gear-wheel',products={{type='item',name='iron-gear-wheel',amount=1}}}},
    space_location={}}
  local force={name='player'}
  local m1={valid=true,unit_number=1,type='assembling-machine',position={x=10.5,y=20.5},products_finished=100,get_recipe=function() return {name='iron-gear-wheel'} end}
  local chest={valid=true,unit_number=2,type='container',position={x=10.5,y=20.5}}
  local p={force=force,surface={index=1,find_entities_filtered=function(f) if f.position.x==10.5 then return {m1,chest} end return {} end}}
  local C=require('conditions'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,known=function() return true end}
  local c={['until']='produced',item='iron-gear-wheel',at_least=5,positions={{x=10.5,y=20.5}}}
  C.validate(c)
  local rec={}
  local met,saw=C.check(p,c,true,rec)
  eq(met,false); eq(saw,'made 0 iron-gear-wheel (0 crafts) in 1 machine since the wait began (at least 5); 1 other entities on the tiles have no products counter')
  m1.products_finished=104; met,saw=C.check(p,c,true,rec); eq(met,false); has(saw,'made 4 iron-gear-wheel (4 crafts)')
  m1.products_finished=106; met=C.check(p,c,true,rec); eq(met,true)
  -- a new wait counts from its own start
  eq((C.check(p,c,true,{})),false)
  -- no record (a guard, an order's when): refused
  assert(not pcall(C.check,p,c,true,nil))
  assert(not pcall(C.validate,{['until']='produced',at_least=5}),'positions required')
  assert(not pcall(C.validate,{['until']='produced',positions={{1,1}}}),'at_least required')
  -- crafts without item
  local r2={}; C.check(p,{['until']='produced',at_least=1,positions={{x=10.5,y=20.5}}},true,r2)
  m1.products_finished=107; eq((C.check(p,{['until']='produced',at_least=1,positions={{x=10.5,y=20.5}}},true,r2)),true)
end
print('d15_batch produced: ok')
