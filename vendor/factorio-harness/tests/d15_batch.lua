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

-- 1 (Sol): build/place_ghosts entries with settings {...}: read as an alias; setting keys at the top level refused. --
do
  local checked={}
  local E=require('entryset'){check=function(action,args)
    checked[#checked+1]=action
    if action=='configure' then for k in pairs(args) do assert(({recipe=1,modules=1,filters=1,filter_mode=1,use_filters=1})[k],'unknown argument '..k..' for configure') end end
  end,call=function() return {} end,position=function(v) return v end,reason=tostring}
  local entries={{item='biochamber',position={x=1,y=1},settings={recipe='bioflux',modules={'speed-module'},circuit={enable={}},requests={set={}},filters={'coal'}}}}
  eq(E.normalize(entries),1)
  local e=entries[1]
  eq(e.settings,nil); eq(e.recipe,'bioflux'); eq(e.configure.modules[1],'speed-module'); eq(e.configure.filters[1],'coal')
  assert(e.circuit.enable and e.requests.set,'circuit and requests moved')
  eq(E.any(entries),true)
  E.check(entries,{})
  -- an unknown key inside settings goes to configure, whose check refuses it by name
  local bad={{item='inserter',position={x=1,y=1},settings={colour='red'}}}
  E.normalize(bad)
  local ok,err=pcall(E.check,bad,{}); assert(not ok); has(err,'unknown argument colour for configure')
  -- setting keys at the entry's top level: refused with the corrected shape
  ok,err=pcall(E.normalize,{{item='assembling-machine-2',position={x=1,y=1},modules={'speed-module'}}},'builds entry')
  assert(not ok); has(err,'builds entry 1: modules is not an entry key; it goes in configure {modules = ...}')
  ok,err=pcall(E.normalize,{{name='inserter',position={x=1,y=1},settings={recipe='a'},recipe='b'}})
  assert(not ok); has(err,'settings.recipe conflicts with recipe')
  eq(E.normalize({{name='inserter',position={x=1,y=1}}}),0)
end
print('d15_batch settings: ok')

-- 4, 15 (Opus): fuel_budget: made/used per minute, groups with their burn and minutes left. ------------------------
do
  defines={entity_status={working=1,no_fuel=2,low_power=3},inventory={assembling_machine_input=2},flow_precision_index={ten_minutes=2}}
  prototypes={item={coal={fuel_value=4e6},['solid-fuel']={fuel_value=12e6},['petroleum-gas']={},['plastic-bar']={}},
    recipe={['plastic-bar']={name='plastic-bar',energy=1,ingredients={{type='item',name='coal',amount=1},{type='fluid',name='petroleum-gas',amount=20}}}}}
  local function inv(t) return {get_contents=function() local o={} for k,v in pairs(t) do o[#o+1]={name=k,count=v} end return o end} end
  -- a boiler: 1.8 MW = 30000 J/tick; coal 4 MJ: 27 coal/min working, effectivity 1
  local function boiler(coal,status)
    return {valid=true,type='boiler',name='boiler',status=status,burner={},prototype={max_energy_usage=30000,burner_prototype={effectivity=1}},
      get_fuel_inventory=function() return inv(coal>0 and {coal=coal} or {}) end}
  end
  local furnace={valid=true,type='furnace',name='stone-furnace',status=1,burner={},prototype={max_energy_usage=1500,burner_prototype={effectivity=1}},
    get_fuel_inventory=function() return inv({coal=5}) end}
  local plant={valid=true,type='assembling-machine',name='chemical-plant',status=1,crafting_speed=1,get_recipe=function() return {name='plastic-bar'} end,
    get_inventory=function() return inv({coal=6}) end}
  local users={boiler(54,1),boiler(27,1),boiler(0,2),furnace,plant}
  local F=require('fuelbudget'){fuel_users=function() return users,500 end,status_name=function(e) return e.status==1 and 'working' or 'no_fuel' end}
  local stats={get_flow_count=function(f) if f.name=='coal' then return f.category=='input' and 300 or 600 end return 0 end}
  game={tick=1000,get_surface=function() return nil end}
  local p={surface={index=1,name='nauvis'},force={name='player',get_item_production_statistics=function() return stats end}}
  local r=F.read(p,{})
  eq(r.as_of,500); eq(r.read,5)
  eq(r.items[1].item,'coal'); eq(r.items[1].made_per_min,30); eq(r.items[1].used_per_min,60)
  local by={}; for _,g in ipairs(r.groups) do by[g.group]=g end
  local b=by.boilers
  eq(b.machines,3); eq(b.working,2); eq(b.fuel[1].burn_per_min,54); eq(b.fuel[1].held,81); eq(b.fuel[1].minutes_left,1.5); eq(b.empty_fuel,1)
  has(b.line,'boilers: 3 (2 working, 1 no_fuel); coal: burns about 54/min, holds 81 (about 1.5 min at that rate); 1 with empty fuel slots')
  eq(by.furnaces.fuel[1].burn_per_min,1.4)
  local pl=by['recipe plastic-bar']; eq(pl.fuel[1].burn_per_min,60); eq(pl.fuel[1].held,6); eq(pl.fuel[1].minutes_left,0.1)
  eq(r.groups[1].group,'recipe plastic-bar','fewest minutes first')
  has(r.items[1].line,'the groups below burn about 115.4/min')
  -- kept 10 s
  users[1].valid=false; eq(F.read(p,{}).read,5)
end
print('d15_batch fuel_budget: ok')
