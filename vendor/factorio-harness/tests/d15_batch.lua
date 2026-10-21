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
    drop=function(p,a) return {dropped={'rocket-fuel*200'},partial={sent='rocket-fuel*200',stayed='rocket-fuel*200',why='a cargo pod holds 10 slots and the list takes 2 pods; without full only pod 1 goes'}} end,
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
  -- batch28 A2 (Astra: a drop sent 200 of 400 rocket fuel and the remote queue went on): a partial step fails, unless
  -- its args say partial: true
  h.queue_cancel(p,{})
  h.queue_submit(p,{steps={{action='drop',args={}},{action='craft'}}})
  tick(); q=h.queue_status(p)
  eq(q.paused,true,'a partial drop pauses the plan')
  has(q.history[#q.history].result.reason,'drop partial: sent rocket-fuel*200; rocket-fuel*200 stayed (a cargo pod holds 10 slots and the list takes 2 pods; without full only pod 1 goes); partial: true lets a queue go on')
  h.queue_cancel(p,{})
  h.queue_submit(p,{steps={{action='drop',args={partial=true}},{action='craft'}}})
  tick(); q=h.queue_status(p)
  eq(q.paused,false); eq(q.history[#q.history-1].ok,true)

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

-- 8 (Astra): wait_until platform_built: no tile ghost (with entities, no entity ghost) left on the platform. ------
do
  local counts={['tile-ghost']=3,['entity-ghost']=1}
  local pl={valid=true,name='Starling',surface={count_entities_filtered=function(f) return counts[f.type] end}}
  local p={force={platforms={pl}}}
  local C=require('conditions'){position=function(v) return v end,known=function() return true end}
  local c={['until']='platform_built',platform='Starling'}
  C.validate(c)
  local met,saw=C.check(p,c); eq(met,false); eq(saw,'platform Starling: 3 tile ghosts left')
  counts['tile-ghost']=0; eq((C.check(p,c)),true)
  met,saw=C.check(p,{['until']='platform_built',platform='Starling',entities=true}); eq(met,false); eq(saw,'platform Starling: 0 tile ghosts left, 1 entity ghost')
  assert(not pcall(C.validate,{['until']='platform_built'}))
  assert(not pcall(C.check,p,{['until']='platform_built',platform='Nope'}))
end
print('d15_batch platform_built: ok')

-- 22 (Astra): change pending steps while the active one runs: mode pending, queue_edit by id (edit, delete, move). ---
do
  game={tick=0}
  local state,active={},{}
  local players={[1]={index=1}}
  local s=require('scheduler'){state=function() return state end,player=function(i) return players[i] end,
    handlers={long=function(p) active[p.index]=game.tick+100; return {} end,craft=function() return {} end},
    busy=function(p) return active[p.index]~=nil end,stop=function(p) active[p.index]=nil end,stop_index=function(i) active[i]=nil end,
    condition=function() return false end,validate_condition=function() end}
  local h,p=s.handlers,players[1]
  local function tick() game.tick=game.tick+1; for i,t in pairs(active) do if game.tick>=t then active[i]=nil end end; s.tick() end
  h.queue_submit(p,{steps={{action='long'},{action='craft',label='a'},{action='craft',label='b'},{action='craft',label='c'}}})
  tick(); eq(h.queue_status(p).active.action,'long')
  local q=h.queue_status(p,{pending='all'})
  local ida,idc=q.pending[1].id,q.pending[3].id
  q=h.queue_edit(p,{id=idc,to=1}); eq(q.pending[1].label,'c'); eq(active[1]~=nil,true)
  q=h.queue_edit(p,{id=ida}); eq(h.queue_status(p).pending_count,2)
  q=h.queue_edit(p,{id=idc,steps={{action='craft',label='c2'}}}); eq(h.queue_status(p,{pending='all'}).pending[1].label,'c2')
  local ok,err=pcall(h.queue_edit,p,{id=h.queue_status(p).active.id}); assert(not ok); has(err,'it is the active step')
  q=h.queue_submit(p,{mode='pending',steps={{action='craft',label='z'}}})
  eq(q.active.action,'long'); eq(#q.pending,1); eq(q.pending[1].label,'z'); has(q.submission,'pending replaced: 2 dropped, 1 queued')
  eq(active[1]~=nil,true,'the active step goes on')
  h.queue_cancel(p,{})
end
print('d15_batch queue_edit id: ok')


-- Blockers 7 (d15 trajectory analysis): a courier round that moves nothing says so and counts as idle. ---------------
do
  game={tick=0}
  local state,active={},{}
  local players={[1]={index=1}}
  local moved=0
  local s=require('scheduler'){state=function() return state end,player=function(i) return players[i] end,
    handlers={transfer=function() return {transferred=moved} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,
    condition=function() return false end,validate_condition=function() end}
  local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; s.tick() end end
  s.handlers.queue_repeat(players[1],{name='coal-run',interval_ticks=60,steps={{action='transfer',args={}}}})
  tick(3)
  local q=state.queues[1]
  eq(q.empty_rounds,1)
  local h=q.history[#q.history]
  eq(h.action,'round'); eq(h.result.line,'queue coal-run round 1 moved nothing (1 item-moving step; 1 round in a row)')
  eq(s.round_news(1)[1],'queue coal-run round 1 moved nothing (1 item-moving step; 1 round in a row)')
  local I=require('idle'){state=function() return state end}
  eq((I.busy(state,1)),false,'the loop counts as idle')
  moved=5; tick(70)
  eq(q.empty_rounds,nil); eq((I.busy(state,1)),true,'a round that moved something: busy again')
end
print('d15_batch empty rounds: ok')

-- Ship endurance (Astra, d15: Wayfarer was lost at Aquilo after its rockets, fuel and repair packs ran out): a route's
-- legs at the platform's speed and each resource's stock, rates and when it runs out. ----------------------------------
do
  defines={flow_precision_index={ten_minutes=2,five_seconds=0},inventory={hub_main=1,turret_ammo=1,assembling_machine_input=2}}
  local function loc(sp) return {solar_power_in_space=sp} end
  prototypes={item={rocket={type='ammo'},['firearm-magazine']={type='ammo'},['repair-pack']={type='repair-tool'},['iron-plate']={type='item'}},
    fluid={['thruster-fuel']={},['thruster-oxidizer']={}},
    space_location={nauvis=loc(100),fulgora=loc(120),aquilo=loc(60)},
    space_connection={a={from={name='nauvis'},to={name='fulgora'},length=15000},b={from={name='fulgora'},to={name='aquilo'},length=30000}}}
  -- per minute: made, used (the statistics give 10-minute counts)
  local items={rocket={0,10},['firearm-magazine']={20,5},['repair-pack']={0,1}}
  local fluids={['thruster-fuel']={400,500}}
  local function stats(t) return {get_flow_count=function(a) local r=t[a.name]; assert(a.count and a.precision_index==2); return r and (a.category=='input' and r[1] or r[2])*10 or 0 end} end
  local hub=setmetatable({get_contents=function() return {{name='rocket',count=120},{name='firearm-magazine',count=50},{name='repair-pack',count=40},{name='iron-plate',count=9}} end,
    count_empty_stacks=function() return 12 end},{__len=function() return 50 end})
  local turret={get_inventory=function() return {get_contents=function() return {{name='rocket',count=30}} end} end}
  local thruster={fluidbox={{name='thruster-fuel',amount=10000},{name='thruster-oxidizer',amount=8000}}}
  local pole={electric_network_statistics={output_counts={['solar-panel']=1},input_counts={thruster=1,['ammo-turret']=1},
    get_flow_count=function(a) return a.category=='output' and 1000 or 500 end}}
  local force={get_item_production_statistics=function() return stats(items) end,get_fluid_production_statistics=function() return stats(fluids) end}
  -- an assembler making firearm magazines from 4 iron plates a craft; the hub holds 9 plates
  local asm={get_recipe=function() return {name='firearm-magazine',products={{name='firearm-magazine',amount=1}},ingredients={{type='item',name='iron-plate',amount=4}}} end,
    get_inventory=function() return {get_contents=function() return {} end} end}
  local surface={find_entities_filtered=function(f)
    if f.type=='ammo-turret' then return {turret} elseif f.type=='electric-pole' then return {pole} elseif f.type=='assembling-machine' then return {asm}
    elseif type(f.type)=='table' then return {thruster} end
    return {} end}
  local pl={name='Wayfarer',surface=surface,force=force,hub={get_inventory=function() return hub end},space_location={name='nauvis'},speed=0,
    schedule={current=1,records={{station='nauvis'},{station='fulgora'},{station='aquilo'}}}}
  -- the last leg (10 minutes): freight.lua's ammunition counts at its ends: rockets 10/min used, magazines 20 made and 5 used a minute
  local leg,segs=nil,{{kind='leg',from='fulgora',to='nauvis',start=0,['end']=36000,ammo0={rocket={made=0,used=0},['firearm-magazine']={made=0,used=0}},
    ammo1={rocket={made=0,used=100},['firearm-magazine']={made=200,used=50}}},{kind='stop',at='nauvis',start=36000}}
  local E=require('endurance'){platform=function() return pl end,leg=function() return leg end,segments=function() return segs end}
  local r=E.read({},{platform='Wayfarer'})
  eq(r.route,'schedule'); eq(r.speed_km_per_min,1500); has(r.speed_from,'the last leg fulgora->nauvis')
  eq(#r.legs,3); eq(r.legs[1].minutes,10); eq(r.legs[2].minutes,20); eq(r.legs[3].none,true,'aquilo->nauvis has no connection')
  eq(r.total_minutes,30)
  has(r.lines[1],'nauvis->fulgora 15000 km, 10m00s; fulgora->aquilo 30000 km, 20m00s; aquilo->nauvis ? km, time unknown (no space connection between them); in all 30m00s')
  local by={}; for _,x in ipairs(r.resources) do by[x.name]=x end
  eq(by['iron-plate'],nil,'only ammunition, repair packs and thruster fluids')
  eq(by.rocket.stock,150,'hub and turrets'); eq(by.rocket.lasts_min,15); eq(by.rocket.runs_out_on,'fulgora->aquilo')
  has(by.rocket.line,'rocket: 150 now, made 0/min, used 10/min (over the last leg fulgora->nauvis, 10m00s); lasts 15m00s at that rate (runs out on fulgora->aquilo); at the route\'s end about 0')
  -- made 20/min from 9 iron plates at 4 a craft: 2 more, then 5/min used alone (Astra, d15 15:39)
  local fm=by['firearm-magazine']
  eq(fm.ingredient_limited.more,2); eq(fm.ingredient_limited.item,'iron-plate'); eq(fm.at_end,-98); eq(fm.lasts_min,10.4); eq(fm.runs_out_on,'fulgora->aquilo')
  has(fm.line,'ingredient-limited: the ingredients aboard make at most 2 more now (iron-plate 9 aboard, 4 a craft)')
  -- stopped: no flight rate for repair packs (not in the leg counts) or the thruster fluids, and nothing projected
  eq(by['repair-pack'].flight_rate,'unknown'); eq(by['repair-pack'].lasts_min,nil); eq(by['repair-pack'].at_end,nil)
  has(by['repair-pack'].line,'repair-pack: 40 now; flight use unknown: stopped, and no finished leg on record for it (at the stop, last 10 min: made 0/min, used 1/min)')
  eq(by['thruster-fuel'].stock,10000); eq(by['thruster-fuel'].flight_rate,'unknown'); eq(by['thruster-fuel'].at_end,nil)
  has(by['thruster-fuel'].line,'flight use unknown: stopped; the thrusters burn only in flight')
  eq(by['thruster-oxidizer'].stock,8000); eq(by['thruster-oxidizer'].lasts_min,nil)
  eq(r.hub_slots,'12 of 50 free'); eq(r.power,'makes 60 kW, draws 60 kW now'); eq(r.solar_power,'nauvis 100%, fulgora 120%, aquilo 60%')
  -- flying: the rest of the leg first, at the speed now; the schedule from its current stop round to it
  leg={from='nauvis',to='fulgora',left_km=6000}
  pl.space_location,pl.speed,pl.space_connection,pl.schedule.current=nil,25/60,{},2
  r=E.read({},{platform='Wayfarer'})
  eq(r.speed_from,'now'); eq(r.legs[1].now,true); eq(r.legs[1].minutes,4)
  eq(r.legs[2].from,'fulgora'); eq(r.legs[2].to,'aquilo'); eq(r.legs[4].to,'fulgora'); eq(#r.legs,4)
  by={}; for _,x in ipairs(r.resources) do by[x.name]=x end
  eq(by['thruster-fuel'].lasts_min,100,'flying: the last 10 minutes'); eq(by['thruster-fuel'].rate_from,'last 10 min, flying')
  eq(by['repair-pack'].lasts_min,40); eq(by['rocket'].rate_from,'last 10 min, flying')
  -- a given route; an unknown place is refused; stopped with no finished leg: times unknown
  leg,pl.speed,pl.space_connection,pl.space_location,segs=nil,0,nil,{name='nauvis'},{}
  r=E.read({},{platform='Wayfarer',route={'fulgora','nauvis'}})
  eq(r.route,'given'); eq(#r.legs,2); eq(r.total_minutes,nil); has(r.speed_from,'unknown'); has(r.lines[1],'time unknown')
  eq(by.rocket.lasts_min,15)
  local ok,err=pcall(E.read,{},{platform='Wayfarer',route={'mars'}})
  assert(not ok and tostring(err):find('unknown space location mars',1,true),err)
  prototypes,defines=nil,nil
end
print('d15_batch endurance: ok')

-- Artillery (Grok, d15 14:07): the spawners and worms in range nearest first, the automatic targeting switch, and the
-- targeting remote's flare. ---------------------------------------------------------------------------------------
do
  defines={inventory={artillery_turret_ammo=1,artillery_wagon_ammo=2}}
  local cannon={attack_parameters={range=224,min_range=32}}
  local force={artillery_range_modifier=0.25,technologies={artillery={researched=false}},is_chunk_charted=function(s,c) return c.x<20 end}
  local made={}
  local enemies={{name='biter-spawner',position={x=100,y=0}},{name='small-worm-turret',position={x=10,y=0}},{name='spitter-spawner',position={x=60,y=0}},
    {name='biter-spawner',position={x=800,y=0}}}
  local surface
  local function piece(x,shells,auto)
    return {valid=true,name='artillery-turret',type='artillery-turret',position={x=x,y=0},force=force,artillery_auto_targeting=auto,prototype={guns={c=cannon}},
      get_inventory=function() return {get_contents=function() return shells>0 and {{name='artillery-shell',count=shells}} or {} end} end,
      surface=nil}
  end
  local a1,a2=piece(0,5,true),piece(1000,0,true)
  surface={name='nauvis',find_entities_filtered=function(f)
    if f.force=='enemy' then
      local out={}
      for _,e in ipairs(enemies) do if math.sqrt((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)<=f.radius then out[#out+1]=e end end
      return out
    end
    return {a2,a1}
  end,create_entity=function(spec) made[#made+1]=spec; return {valid=true} end}
  a1.surface,a2.surface=surface,surface
  local held=0
  local A=require('artillery'){position=function(v) return v end,held=function() return held end}
  local p={surface=surface,position={x=0,y=0},force=force}
  local r=A.read(p,{})
  eq(r.count,2); eq(r.artillery[1].position.x,0,'nearest you first'); eq(r.artillery[1].range,280,'224 with a 25% bonus')
  eq(r.artillery[1].in_range,2,'the worm inside the minimum range and the spawner past the range are left out')
  eq(r.artillery[1].nearest[1].name,'spitter-spawner'); eq(r.artillery[1].nearest[1].distance,60)
  has(r.lines[1],'artillery-turret (0,0): 5 shells; automatic targeting on; range 280 (minimum 32), a flare within 280; 2 enemy spawners and worms in range, the nearest spitter-spawner (60,0) 60 tiles away')
  eq(r.artillery[2].in_range,0,'a spawner on an uncharted chunk is left out'); has(r.lines[2],'no shells')
  -- the switch, read back
  local c=A.configure(a1,false)
  eq(a1.artillery_auto_targeting,false); eq(c.auto_targeting,false); eq(c.auto_targeting_before,true); has(c.line,'automatic targeting off')
  local ok,err=pcall(A.configure,{type='ammo-turret',name='gun-turret',position={x=1,y=1}},false)
  assert(not ok and err:find('is a ammo-turret',1,true),err)
  -- the remote: neither held nor researched, refused; researched, a flare and the pieces that reach it
  ok,err=pcall(A.remote,p,{item='artillery-targeting-remote',position={x=200,y=0}},{type='artillery-remote',flare='artillery-flare'})
  assert(not ok and err:find('not researched',1,true),err); eq(#made,0)
  force.technologies.artillery.researched=true
  local u=A.remote(p,{item='artillery-targeting-remote',position={x=200,y=0}},{type='artillery-remote',flare='artillery-flare'})
  eq(#made,1); eq(made[1].name,'artillery-flare'); eq(made[1].position.x,200)
  eq(#u.in_range,1); has(u.line,'flare at (200,0); in range with shells: artillery-turret (0,0) 200 tiles, in its automatic range too, 5 shells')
  eq(u.out_of_range,1); eq(u.by,'shortcut (artillery researched)')
  ok,err=pcall(A.remote,p,{item='artillery-targeting-remote',position={x=900,y=0}},{type='artillery-remote',flare='artillery-flare'})
  assert(not ok and err:find('not charted',1,true),err)
  defines=nil
end
print('d15_batch artillery: ok')
