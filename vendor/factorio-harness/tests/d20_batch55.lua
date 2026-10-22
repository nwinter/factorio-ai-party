-- Run from repository root: lua tests/d20_batch55.lua
-- d20 batch55 P1 (viewer Aurora, shift47 13:59: "Could factory snapshots retain their capture time after refresh errors
-- and reject older background results?"). The survey, threat's chart, game_alerts, the census and networks are tested
-- in their own files (tests/survey.lua, threat.lua, pushalerts.lua, census.lua, networks.lua); here snapfail.lua and
-- the ground watch.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
game={tick=0}

-- snapfail: the failure kept, the next try counted from it, an older result dropped, the reply's line.
do
  local S=require('snapfail')
  local f=S.failed('survey.lua:1: boom\nstack', 1000)
  eq(f.tick,1000); eq(f.error,'survey.lua:1: boom stack','one line')
  eq(#S.failed(string.rep('x',500),1).error,200,'bounded')
  eq(S.since(400,nil),400); eq(S.since(400,f),1000); eq(S.since(1200,f),1200,'a read since the failure')
  eq(S.older(500,600),true,'a job started before the read it would replace'); eq(S.older(700,600),false); eq(S.older(500,nil),false)
  game.tick=1600
  eq(S.line('the survey',400,f),'the last refresh of the survey failed 10s ago (survey.lua:1: boom stack); the survey is from 20s ago')
  eq(S.line('the survey',400,nil),nil); eq(S.line('the survey',1200,f),nil,'a failure before the read held is not its')
end
print('d20_batch55 snapfail: ok')

-- The ground watch (status alerts, reply hints): a pass that fails keeps the watch's tick, the alerts say its age and
-- the failure, the next pass starts WATCH_EVERY after it; a pass finishing after a newer watch (a force's first,
-- made in a reply) never replaces it.
do
  local st,boom={},nil
  local force={name='player'}
  local surface={index=1,name='nauvis',valid=true,count_entities_filtered=function() return 0 end,find_entities_filtered=function() return {} end}
  game.surfaces={surface}; game.forces={player=force}
  game.get_surface=function(i) return i==1 and surface or nil end
  local bands=0
  local G=dofile('mod/agent-harness_0.1.0/ground.lua'){state=function() return st end,distance=function() return 0 end,
    walk={every=function() return 1 end,due=function() return true end,start=function() return {} end,
      band=function(w) if boom then error(boom) end; bands=bands+1; if not w.went then w.went=true; return {} end end}}
  local function pass() repeat game.tick=game.tick+1; G.watch_tick(game.tick) until not (st.ground_jobs or {}).player end
  game.tick=10000
  G.watch_tick(game.tick); assert(st.ground_jobs.player,'a pass'); pass()
  local w=st.ground_watch.player
  eq(w.tick,10000,'the pass\'s start')
  game.tick=10000+1800; G.watch_tick(game.tick); assert(st.ground_jobs.player,'the next pass')
  boom='band read broke'
  game.tick=game.tick+1; G.watch_tick(game.tick)
  eq(st.ground_jobs.player,nil,'the pass ended'); eq(st.ground_errors.count,1)
  eq(st.ground_watch.player,w); eq(w.tick,10000,'the watch keeps its tick')
  local failed_at=game.tick
  game.tick=game.tick+600
  local lines=G.alerts({force=force})
  eq(#lines,1)
  eq(lines[1],string.format('the last refresh of the ground watch failed 10s ago (%s); the ground watch is from %ds ago',w.refresh_failed.error,
    math.floor((game.tick-10000)/60)))
  assert(w.refresh_failed.error:find('band read broke',1,true))
  boom=nil
  game.tick=failed_at+1799; G.watch_tick(game.tick); eq(st.ground_jobs.player,nil,'no pass within WATCH_EVERY of the failure')
  game.tick=game.tick+1; G.watch_tick(game.tick); assert(st.ground_jobs.player,'the pass after it')
  local start=st.ground_jobs.player.start
  -- the force's watch read at once in a reply (as before its first pass) while this pass runs
  st.ground_watch.player=nil; st.ground_bg=nil
  game.tick=game.tick+1
  local newer=G.watch(force)
  eq(newer.tick,game.tick); eq(G.alerts({force=force}),nil,'no pile, no failure')
  pass()
  assert(start<newer.tick)
  eq(st.ground_watch.player,newer,'the pass\'s older watch was dropped')
  -- Without a newer watch the next pass replaces it as before.
  game.tick=newer.tick+1800; G.watch_tick(game.tick); pass()
  assert(st.ground_watch.player~=newer and st.ground_watch.player.tick>newer.tick,'the next pass replaced it')
  game.surfaces,game.forces,game.get_surface=nil,nil,nil
end
print('d20_batch55 ground watch: ok')

-- P2 (viewer Aurora 14:37): checks with their last observed result, stale when their area changed since the run, their
-- blueprint was pasted there again or past their stale age; run when added and on request only.
do
  local st={}
  local force={name='player'}
  local ents={}
  local finds=0
  local surface={index=1,name='nauvis'}
  surface.find_entities_filtered=function(f)
    finds=finds+1
    assert(f.area and f.force==force,'one find over the area, ours')
    local out={}
    for _,e in ipairs(ents) do
      local q=e.position
      if e.valid and q.x>=f.area[1][1] and q.x<=f.area[2][1] and q.y>=f.area[1][2] and q.y<=f.area[2][2] then out[#out+1]=e end
    end
    return out
  end
  game.get_surface=function(i) return i==1 and surface or nil end
  local unit=100
  local function put(name,x,y,d,ghost)
    unit=unit+1
    local e={valid=true,name=ghost and 'entity-ghost' or name,ghost_name=ghost and name or nil,type=ghost and 'entity-ghost' or 'assembling-machine',
      unit_number=unit,position={x=x,y=y},direction=d or 0,prototype={supports_direction=true}}
    ents[#ents+1]=e
    return e
  end
  local met,saw=true,'met: 400 iron-plate'
  local C=dofile('mod/agent-harness_0.1.0/checks.lua'){state=function() return st end,position=function(q) return {x=q.x or q[1],y=q.y or q[2]} end,
    who=function(p) return p.name end,condition=function(p,c) return met,saw end,validate=function(c) assert(c['until'],'until') end,
    item_exists=function(id) return id==12 end}
  local sol={name='sol',surface=surface,force=force}
  local astra={name='astra',surface=surface,force=force}
  game.tick=50000
  for i=1,4 do put('assembling-machine-2',i*4,0) end
  -- A condition check over an area, with a board item: run when added.
  local r=C.handler(sol,{add={name='iron in the mall chest',condition={['until']='item_count',item='iron-plate',at_least=400},item=12,position={x=8,y=0},radius=10}})
  eq(r.added,1); eq(r.check.state,'pass'); eq(r.check.result,'pass'); eq(r.check.result_tick,50000); eq(r.check.by,'sol'); eq(r.check.saw,'met: 400 iron-plate')
  eq(r.check.line,'check #1 iron in the mall chest (sol, board #12, condition item_count): pass at tick 50000, 0s ago, by sol: met: 400 iron-plate')
  game.tick=50600
  r=C.handler(sol,{})
  eq(r.count,1); eq(r.checks[1].state,'pass'); eq(r.checks[1].compared,'area compared now')
  -- Something built, turned and removed in its area since: stale, naming what.
  local new=put('inserter',6,2)
  ents[1].direction=4
  ents[4].valid=false
  r=C.handler(astra,{id=1})
  eq(r.check.state,'stale'); eq(r.check.result,'pass','the last result kept')
  eq(r.check.stale_why[1],'since that run, in its area: 1 built, 1 removed, 1 turned (assembling-machine-2 (16,0) removed, assembling-machine-2 (4,0) turned, inserter (6,2) built)')
  -- Run again: the result now, not stale.
  met,saw=false,'not yet: 120 iron-plate'
  game.tick=51000
  r=C.handler(astra,{run=1})
  eq(r.was,'pass'); eq(r.check.state,'fail'); eq(r.check.by,'astra'); eq(r.check.result_tick,51000); eq(#r.check.history,2)
  eq(C.handler(sol,{id=1}).check.state,'fail')
  -- Past its stale age (default 30 game minutes).
  game.tick=51000+108001
  r=C.handler(sol,{id=1})
  eq(r.check.state,'stale'); eq(r.check.stale_why[1],'run 30m ago, past its stale age of 30m')
  -- The board item's view lists it (no area read).
  local before=finds
  local lines=C.item_lines(12)
  eq(#lines,1); eq(finds,before,'no find for the item view'); assert(lines[1]:find('area not compared in this read',1,true),lines[1])
  -- A blueprint check: the last placement of a library blueprint, each entity built where the paste put it.
  game.tick=200000
  ents={}
  local rec={surface=1,count=3,box={l=30,t=-2,r=42,b=2},entities={{name='assembling-machine-2',x=32,y=0,d=0},{name='assembling-machine-2',x=36,y=0,d=0},{name='inserter',x=40,y=0,d=4}}}
  C.placed(sol,'mall row',rec)
  put('assembling-machine-2',32,0); put('assembling-machine-2',36,0,0,true)
  local nofit=pcall(C.handler,sol,{add={name='x',blueprint='other'}})
  eq(nofit,false,'no placement of that blueprint remembered')
  r=C.handler(sol,{add={name='mall row built',blueprint='mall row'}})
  eq(r.check.state,'fail')
  eq(r.check.saw,'1 of 3 built as placed; 1 still a ghost; 1 missing; first: assembling-machine-2 (36,0) a ghost, inserter (40,0) missing')
  ents[2].valid=false; put('assembling-machine-2',36,0); put('inserter',40,0,8)
  r=C.handler(sol,{run=r.added})
  eq(r.check.saw,'2 of 3 built as placed; 1 facing otherwise; first: inserter (40,0) facing otherwise')
  ents[#ents].direction=4
  r=C.handler(sol,{run=r.ran})
  eq(r.check.state,'pass'); eq(r.check.saw,'3 of 3 built as placed')
  local id=r.ran
  -- Pasted there again: stale until run, and the run reads the new placement.
  game.tick=200600
  C.placed(astra,'mall row',{surface=1,count=1,box={l=30,t=-2,r=34,b=2},entities={{name='assembling-machine-2',x=32,y=0,d=4}}})
  r=C.handler(sol,{id=id})
  eq(r.check.state,'stale'); eq(r.check.stale_why[1],'blueprint mall row pasted there again by astra 0s ago')
  r=C.handler(sol,{run=id})
  eq(r.check.state,'fail'); eq(r.check.saw,'0 of 1 built as placed; 1 facing otherwise; first: assembling-machine-2 (32,0) facing otherwise')
  -- Listing: yours by default, all, by item; remove.
  eq(C.handler(astra,{}).count,0); eq(C.handler(astra,{all=true}).count,2); eq(C.handler(astra,{item=12}).count,1)
  eq(C.handler(astra,{remove=1}).removed,1); eq(C.handler(sol,{all=true}).count,1)
  -- Nothing runs in the background: the module has no tick.
  eq(C.tick,nil)
  game.get_surface=nil
end
print('d20_batch55 P2 checks: ok')

-- P4 (Sol #1393: Fulgora's EM plant (-41,81) read 106 crafts in 161 s, 39.4/min, "153%" of 25.8/min, working all the
-- time; inspect: 25.8 crafts/min, productivity 54%). products_finished counts the productivity bar's completions too:
-- uptime gives base crafts against the craft rate and completions against the rate with productivity, the working
-- share apart. A one-product recipe at 54%, 25.8 crafts a minute, working throughout.
do
  game={tick=2000}
  defines={inventory={assembling_machine_input=2,furnace_source=2}}
  local st={}
  local recipe={name='supercapacitor',ingredients={}}
  local base,bonus_bar,done=0,0.3,500
  local m={valid=true,name='electromagnetic-plant',type='assembling-machine',position={x=-41,y=81},products_finished=done,bonus_progress=bonus_bar,
    status='working',get_recipe=function() return recipe end,get_inventory=function() return {get_item_count=function() return 0 end} end}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() return m end,
    status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=25.8,productivity=0.54} end}
  U.handler({index=1},{positions={{x=-41,y=81}},seconds=161})
  -- the game's model: each craft adds 0.54 to the bar; a full bar is one more completion
  local per_tick,progress=25.8/3600,0
  for t=2001,2000+161*60 do
    game.tick=t
    progress=progress+per_tick
    if progress>=1 then
      progress=progress-1; base=base+1; done=done+1; bonus_bar=bonus_bar+0.54
      if bonus_bar>=1 then bonus_bar=bonus_bar-1; done=done+1 end
    end
    m.products_finished,m.bonus_progress=done,bonus_bar
    U.tick(t)
  end
  local row=U.handler({index=1},{}).machines[1]
  eq(row.completions,done-500); eq(row.crafts,base,'the base crafts'); eq(row.bonus_completions,done-500-base)
  eq(row.crafts,69); eq(row.bonus_completions,37)
  eq(row.crafts_per_min,25.7); eq(row.full_speed_per_min,25.8); eq(row.completions_per_min,39.5); eq(row.full_speed_completions_per_min,39.7)
  eq(row.productivity,0.54); eq(row.working_share,100)
  assert(row.line:find('69 crafts in 161s (25.7/min, 100% of its 25.8/min at full speed) and 37 productivity completions (productivity +54%): 106 completions, 39.5/min against 39.7/min at full speed; working 100%',1,true),row.line)
  -- the split alone: no productivity, every completion a craft
  eq(select(2,U.split(10,0,0,nil)),0); eq(U.split(10,0.2,0.9,0.5),7)
  defines=nil
end
print('d20_batch55 P4 uptime crafts and productivity completions: ok')

-- P5 (Sol #1400: Edge5 lost a railgun turret in one shot while every other turret was fed, so the ammo_below guard
-- did not fire; ghosts_waiting with platform was refused on the remote lane). platform_loss: met on the first new loss
-- on the platform since the guard began, saying what; ghosts_waiting with platform; both on the remote lanes.
do
  defines={inventory={turret_ammo=7}}
  prototypes={item={['railgun-ammo']={}},quality={normal={}}}
  local st={}
  game={tick=1000}
  local function rail(x,y,n)
    local e={valid=true,name='railgun-turret',type='ammo-turret',position={x=x,y=y},force={name='player'},surface={name='platform-7'}}
    e.get_inventory=function() return {get_item_count=function() return n end,get_contents=function() return {{name='railgun-ammo',count=n}} end} end
    return e
  end
  local guns={rail(-6,-12,10),rail(0,-14,10),rail(6,-12,10)}
  local ghosts=0
  local deck={name='platform-7',find_entities_filtered=function(f)
      local out={}
      for _,e in ipairs(guns) do if e.valid then out[#out+1]=e end end
      return out
    end,
    count_entities_filtered=function(f) return ghosts end}
  local edge={valid=true,name='Edge5',surface=deck}
  local force={name='player',platforms={edge}}
  local sol={position={x=0,y=0},surface={name='nauvis'},force=force}
  local L=dofile('mod/agent-harness_0.1.0/lostlog.lua'){state=function() return st end,position=function(v) return v end}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
    losses_since=function(f,s,since,names,max) return L.since(f,s,since,names,max) end}
  -- a loss before the guard began does not count
  L.died({force={name='player'},surface={name='platform-7'},name='solar-panel',position={x=3,y=3}},'small-metallic-asteroid')
  game.tick=1200
  local guard_ammo={['until']='ammo_below',platform='Edge5',count=1}
  local guard_loss={['until']='platform_loss',platform='Edge5'}
  C.validate(guard_ammo); C.validate(guard_loss)
  -- the guards as check_guards reads them: no wait record, the condition kept in the queue
  eq((C.check(sol,guard_ammo)),false,'every turret fed')
  local met,saw=C.check(sol,guard_loss)
  eq(met,false); eq(saw,'platform Edge5: nothing of ours lost since tick 1200'); eq(guard_loss.loss_since,1200,'kept on the condition')
  -- a loss on another surface: not this platform's
  game.tick=1300
  L.died({force={name='player'},surface={name='nauvis'},name='stone-wall',position={x=1,y=1}},'small-biter')
  eq((C.check(sol,guard_loss)),false)
  -- one railgun turret, fed, destroyed in one shot; the other two still armed
  game.tick=1400
  guns[2].valid=false
  L.died(guns[2],'big-metallic-asteroid')
  game.tick=1410
  eq((C.check(sol,guard_ammo)),false,'the armed turrets: ammo_below does not fire')
  met,saw=C.check(sol,guard_loss)
  eq(met,true); eq(saw,'platform Edge5: 1 of ours lost since tick 1200: railgun-turret (0,-14) by big-metallic-asteroid 0s ago')
  -- names and at_least
  local named={['until']='platform_loss',platform='Edge5',names={'thruster'},since_tick=1200}
  C.validate(named)
  eq((C.check(sol,named)),false,'not of those names')
  local two={['until']='platform_loss',platform='Edge5',at_least=2,since_tick=999}
  met,saw=C.check(sol,two)
  eq(met,true); eq(saw,'platform Edge5: 2 of ours lost since tick 999: railgun-turret (0,-14) by big-metallic-asteroid 0s ago, solar-panel (3,3) by small-metallic-asteroid 6s ago')
  -- a wait step keeps its start on its record
  local rec={}
  eq((C.check(sol,{['until']='platform_loss',platform='Edge5'},nil,rec)),false); eq(rec.loss_since,1410)
  -- ghosts_waiting with platform
  ghosts=0
  eq((C.check(sol,{['until']='ghosts_waiting',platform='Edge5'})),false)
  ghosts=1
  met,saw=C.check(sol,{['until']='ghosts_waiting',platform='Edge5'})
  eq(met,true); eq(saw,'platform Edge5: 1 ghost')
  fails(function() C.validate({['until']='ghosts_waiting',platform='Edge5',radius=8}) end,'no position or radius')
  fails(function() C.validate({['until']='platform_loss'}) end,'platform_loss requires platform')
  fails(function() C.validate({['until']='platform_loss',platform='Edge5',since_tick=99999}) end,'since_tick is a game tick up to now')
  -- the remote lanes take both, as waits and as guards' when
  local lanes=dofile('mod/agent-harness_0.1.0/queue_lanes.lua')
  local checked
  local function factory(api) checked=api.check_step; return {handlers={},schema={queue_submit={}}} end
  pcall(lanes,{scheduler={handlers={},schema={queue_submit={}}},base={player=function() end,busy=function() end},factory=factory,is_read=function() return false end})
  assert(checked,'the lane check')
  checked('wait_until',{['until']='platform_loss',platform='Edge5'})
  checked('wait_until',{['until']='ghosts_waiting',platform='Edge5'})
  fails(function() checked('wait_until',{['until']='ghosts_waiting'}) end,'ghosts_waiting with platform')
  defines,prototypes=nil,nil
end
print('d20_batch55 P5 platform_loss: ok')

-- P6 (Grok #1413: a science rocket in flight to Kestrel IVa; its hub request read "holds 0 lacks 500" until the pod
-- landed, and the silo launched a magazine rocket for Swiftlet). A request counts what rockets launched to the hub
-- carry (the hub requester point's deliveries, the GUI's in-transit count); one they cover reads on_the_way.
do
  game={tick=38631343}
  defines={inventory={hub_main=1},logistic_member_index={space_platform_hub_requester=0}}
  prototypes={item={['agricultural-science-pack']={weight=1000,stack_size=200},['firearm-magazine']={weight=5000,stack_size=200}},utility_constants={rocket_lift_weight=1000000}}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return {} end}
  local net={network_id=3,get_item_count=function(name,member) local n=name=='agricultural-science-pack' and 600 or 300; if member=='storage' then return 0 end return n end}
  local function hub(held,way,filters)
    return {valid=true,get_inventory=function() return {count_empty_stacks=function() return 30 end} end,get_item_count=function(n) return held[n] or 0 end,
      get_logistic_point=function(i) eq(i,0); return {targeted_items_deliver=way} end,
      get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=filters} end} end}
  end
  local kestrel=hub({},{{name='agricultural-science-pack',quality='normal',count=500}},{{value={name='agricultural-science-pack'},min=500,import_from='gleba',minimum_delivery_count=500}})
  local swiftlet=hub({['firearm-magazine']=246},{},{{value={name='firearm-magazine'},min=700,import_from='gleba',minimum_delivery_count=100}})
  local force={platforms={{valid=true,name='Kestrel IVa',space_location={name='gleba'},hub=kestrel},{valid=true,name='Swiftlet',space_location={name='gleba'},hub=swiftlet}},logistic_networks={gleba={net}}}
  local e={surface={name='gleba',planet={name='gleba'}},position={x=65.5,y=14.5}}
  local way=S.on_the_way(kestrel)
  eq(way['agricultural-science-pack@normal'],500)
  local rows=S.request_rows(e,force,net)
  eq(#rows,2)
  eq(rows[1].platform,'Swiftlet'); eq(rows[1].flag,'matched'); eq(rows[1].on_the_way,0); eq(rows[1].lacks,454)
  eq(rows[2].platform,'Kestrel IVa'); eq(rows[2].flag,'on_the_way'); eq(rows[2].holds,0); eq(rows[2].on_the_way,500); eq(rows[2].lacks,0)
  assert(rows[2].line:find('on_the_way: Kestrel IVa asks agricultural-science-pack 500 (holds 0, 500 on the way in rockets launched to it, lacks 0), what is on the way covers it: the game launches for it again once those land',1,true),rows[2].line)
  eq(rows[2].elsewhere,nil)
  -- part on the way: the rest lacks, flagged as before
  kestrel.get_logistic_point=function() return {targeted_items_deliver={{name='agricultural-science-pack',quality='normal',count=200}}} end
  rows=S.request_rows(e,force,net)
  local k
  for _,r in ipairs(rows) do if r.platform=='Kestrel IVa' then k=r end end
  eq(k.on_the_way,200); eq(k.lacks,300); eq(k.flag,'matched')
  defines,prototypes=nil,nil
end
print('d20_batch55 P6 requests count what is on the way: ok')

-- P7 (Astra #1426: a crusher on advanced-carbonic with +40% asteroid productivity read 20.3 crafts/min against 19.2,
-- productivity 0, "106%"). 2.0.77's LuaEntity.productivity_bonus leaves out the recipe's research (the private copy: 0
-- at +40%, the bar filling 0.4 a craft); the game adds the two, capped at the recipe's maximum (+300%). The bar fills
-- with crafting progress. A recipe with research productivity and none from modules.
do
  game={tick=5000}
  defines={inventory={assembling_machine_input=2,furnace_source=2}}
  local CR=dofile('mod/agent-harness_0.1.0/craftrate.lua'){}
  local force={recipes={['advanced-carbonic-asteroid-crushing']={productivity_bonus=0.4}}}
  local recipe={name='advanced-carbonic-asteroid-crushing',energy=5,ingredients={{name='carbonic-asteroid-chunk',amount=1}},
    products={{name='carbon',amount=5},{name='sulfur',amount=2},{name='carbonic-asteroid-chunk',amount=1,probability=0.05}},prototype={maximum_productivity=3}}
  local m={valid=true,name='crusher',type='assembling-machine',position={x=-6,y=9},force=force,prototype={},productivity_bonus=0,crafting_speed=3.84,
    products_finished=200,bonus_progress=0.7,crafting_progress=0.5,status='working',get_recipe=function() return recipe end,
    get_inventory=function() return {get_item_count=function() return 0 end} end}
  -- inspect's rate: the research in, the machine's own 0
  local rt=CR.machine(m)
  eq(rt.productivity,0.4); eq(rt.productivity_machine,0); eq(rt.productivity_research,0.4); eq(rt.crafts_per_min,46.1)
  eq(rt.products[1].per_min,322.6,'carbon 46.08 x 5 x 1.4')
  assert(rt.line:find('productivity +40% (research +40%)',1,true),rt.line)
  -- the cap: +350% research makes +300%
  force.recipes[recipe.name].productivity_bonus=3.5
  local pr=CR.productivity(m,recipe); eq(pr.total,3); eq(pr.capped,true)
  rt=CR.machine(m); eq(rt.productivity,3)
  assert(rt.line:find('productivity +300% (research +350%, capped at the recipe\'s +300%)',1,true),rt.line)
  force.recipes[recipe.name].productivity_bonus=0.4
  -- uptime over 495 s, working throughout, starting and ending partway through a craft
  local st={}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() return m end,
    status_name=function(e) return e.status end,craftrate=function(e) return CR.machine(e) end,productivity=function(e,r) return CR.productivity(e,r) end}
  local function run(seconds,at_tick)
    local base=0
    for t=game.tick+1,game.tick+seconds*60 do
      game.tick=t
      local p=m.productivity_bonus+force.recipes[recipe.name].productivity_bonus
      local step=m.crafting_speed/recipe.energy/60
      m.crafting_progress=m.crafting_progress+step; m.bonus_progress=m.bonus_progress+p*step
      if m.crafting_progress>=1 then m.crafting_progress=m.crafting_progress-1; base=base+1; m.products_finished=m.products_finished+1 end
      while m.bonus_progress>=1 do m.bonus_progress=m.bonus_progress-1; m.products_finished=m.products_finished+1 end
      if at_tick and t==at_tick[1] then at_tick[2]() end
      U.tick(t)
    end
    return base
  end
  U.handler({index=1},{position={x=-6,y=9},seconds=495})
  local base=run(495)
  local row=U.handler({index=1},{}).machines[1]
  eq(row.crafts,base,'the base crafts'); eq(row.crafts,380); eq(row.bonus_completions,row.completions-base); eq(row.bonus_completions,152)
  eq(row.productivity,0.4); eq(row.productivity_research,0.4); eq(row.full_speed_per_min,46.1); eq(row.full_speed_completions_per_min,64.5); eq(row.crafts_unknown,nil)
  assert(row.line:find('380 crafts in 495s (46.1/min, 100% of its 46.1/min at full speed) and 152 productivity completions (productivity +40%: the machine\'s +0%, research +40%): 532 completions',1,true),row.line)
  -- the craft in progress: 5 crafts and 0.9 of a sixth at +300% fill 17.7 bar, 17 completions and 0.7 left; without
  -- the progress term the split would read 6
  eq(U.split(22,0,0.7,3,0,0.9),5); eq(U.split(22,0,0.7,3),6)
  -- research finishing during the watch: the base crafts unknown, the completions kept
  U.handler({index=1},{position={x=-6,y=9},seconds=60})
  run(60,{game.tick+1800,function() force.recipes[recipe.name].productivity_bonus=0.5 end})
  row=U.handler({index=1},{}).machines[1]
  eq(row.crafts,nil); eq(row.bonus_completions,nil); eq(row.crafts_per_min,nil); assert(row.completions>0)
  eq(row.crafts_unknown,'base crafts unknown: its productivity changed during the watch (+40% -> +50%)')
  assert(row.line:find(': '..row.completions..' completions in 60s (',1,true) and row.line:find('base crafts unknown: its productivity changed during the watch (+40% -> +50%); working 100%',1,true),row.line)
  -- productivity that cannot be read
  local st2={}
  local U2=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st2 end,remote_entity=function() return m end,
    status_name=function(e) return e.status end,craftrate=function() return nil end}
  U2.handler({index=1},{position={x=-6,y=9},seconds=10})
  eq(U2.handler({index=1},{}).machines[1].crafts_unknown,'base crafts unknown: its productivity could not be read')
  defines=nil
end
print('d20_batch55 P7 uptime and rates with research productivity: ok')

-- P8 (Sol #1439: uptime refused a biolab as not a crafting machine). Labs and biolabs: status samples, the packs held,
-- what was used (2.0.77 keeps no count per lab: each pack's durability drained between samples, modulo a whole pack put
-- in or taken out, while a lab cannot drain a whole pack between samples), spoil results apart, and the force's research
-- and the surface's packs used up beside. A lab missing the electromagnetic pack, with agricultural packs that spoil; a
-- biolab with every pack, fed by an inserter.
do
  game={tick=10000}
  defines={inventory={assembling_machine_input=2,furnace_source=2,lab_input=2,lab_trash=8}}
  local PACKS={'automation-science-pack','logistic-science-pack','military-science-pack','chemical-science-pack','utility-science-pack','space-science-pack','electromagnetic-science-pack'}
  prototypes={item={}}
  for _,n in ipairs(PACKS) do prototypes.item[n]={get_durability=function() return 1 end,get_spoil_ticks=function() return 0 end} end
  prototypes.item['agricultural-science-pack']={get_durability=function() return 1 end,get_spoil_ticks=function() return 216000 end}
  local stats={}
  local tech={name='tesla-weapons',level=1,research_unit_count=1500,research_unit_energy=3600,research_unit_ingredients={}}
  for _,n in ipairs(PACKS) do tech.research_unit_ingredients[#tech.research_unit_ingredients+1]={name=n,amount=1} end
  local force={name='player',current_research=tech,research_progress=0.2433,technologies={['tesla-weapons']={researched=false}},
    get_item_production_statistics=function() return {get_output_count=function(n) return stats[n] or 0 end} end}
  game.forces={player=force}; game.surfaces={nauvis={name='nauvis'}}
  local function lab(name,pos,speed,drain,held)
    local slots={}
    for _,h in ipairs(held) do slots[#slots+1]={name=h[1],count=h[2],durability=1,quality={name='normal'},valid_for_read=true} end
    local trash={}
    local e={valid=true,name=name,type='lab',position=pos,force=force,surface=game.surfaces.nauvis,speed_bonus=1.9,quality='normal',slots=slots,trash=trash,
      prototype={lab_inputs=PACKS,science_pack_drain_rate_percent=drain,get_researching_speed=function() return speed end}}
    e.get_inventory=function(i)
      if i==8 then return {get_contents=function() local o={} for n,c in pairs(trash) do o[#o+1]={name=n,count=c} end return o end} end
      return setmetatable({},{__len=function() return #slots end,__index=function(_,k) return slots[k] end})
    end
    return e
  end
  local L=lab('lab',{x=100.5,y=-63.5},1,100,{{'automation-science-pack',10},{'logistic-science-pack',10},{'military-science-pack',10},{'chemical-science-pack',10},
    {'utility-science-pack',10},{'space-science-pack',10},{'agricultural-science-pack',3}})
  local B=lab('biolab',{x=96.5,y=-56.5},2,50,{{'automation-science-pack',2},{'logistic-science-pack',2},{'military-science-pack',2},{'chemical-science-pack',2},
    {'utility-science-pack',2},{'space-science-pack',2},{'electromagnetic-science-pack',2}})
  local function has_all(e) local got={} for _,s in ipairs(e.slots) do if s.count>0 then got[s.name]=true end end for _,n in ipairs(PACKS) do if not got[n] then return false end end return true end
  local function status(e) return has_all(e) and 'working' or 'missing_science_packs' end
  L.status_fn,B.status_fn=status,status
  local st={}
  local at={[1]=L,[2]=B}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function(_,q) return q.position.x>99 and L or B end,
    status_name=function(e) return status(e) end}
  local start=U.handler({index=1},{positions={{x=100.5,y=-63.5},{x=96.5,y=-56.5}},seconds=60})
  eq(start.baseline[1],'lab (100.5,-63.5): holds automation-science-pack 10, logistic-science-pack 10, military-science-pack 10, chemical-science-pack 10, utility-science-pack 10, space-science-pack 10, agricultural-science-pack 3')
  -- the game: a working lab drains each pack speed x (1 + bonus) / unit time x drain a tick; a pack at 0 is gone and
  -- counted used up; research gains the same units; every 5 s the biolab's inserter puts 2 fresh packs in where one is under 2
  local drained,used_up,units=0,0,0
  for t=10001,10000+60*60 do
    game.tick=t
    for _,e in ipairs({L,B}) do
      if has_all(e) then
        local per=e.prototype.get_researching_speed()*(1+e.speed_bonus)/tech.research_unit_energy
        units=units+per; force.research_progress=force.research_progress+per/tech.research_unit_count
        for _,s in ipairs(e.slots) do
          if s.count>0 and s.name~='agricultural-science-pack' then
            local d=per*e.prototype.science_pack_drain_rate_percent/100
            if e==B and s.name=='automation-science-pack' then drained=drained+d end
            s.durability=s.durability-d
            if s.durability<=1e-12 then s.count=s.count-1; s.durability=1; stats[s.name]=(stats[s.name] or 0)+1; if e==B and s.name=='automation-science-pack' then used_up=used_up+1 end end
          end
        end
      end
    end
    if t%300==0 then for _,s in ipairs(B.slots) do if s.count<2 then s.count=s.count+2 end end end
    -- the agricultural packs spoil at 30 s: spoilage in the lab's trash
    if t==10000+1800 then L.slots[7].count=0; L.slots[7].valid_for_read=false; L.trash.spoilage=3 end
    U.tick(t)
  end
  local out=U.handler({index=1},{})
  local l,b=out.machines[1],out.machines[2]
  eq(l.kind,'lab'); eq(l.samples.missing_science_packs,61); eq(l.working_share,0)
  eq(l.packs[1].used,0); eq(l.packs[1].held_least,10)
  eq(l.packs[7].name,'agricultural-science-pack'); eq(l.packs[7].unknown_intervals,1); eq(l.packs[7].unknown_why,'packs spoiled'); eq(l.packs[7].held_least,0)
  eq(l.spoil_results[1],'spoilage 3')
  assert(l.line:find('lab (100.5,-63.5): missing science packs 100%; when: missing science packs from 0 s to 60 s (ticks 10000-13600), at most 61 samples in a row; packs used in 60s (durability drained): automation-science-pack 0,',1,true),l.line)
  assert(l.line:find('agricultural-science-pack 0-3 (none in 31 samples); used unknown for agricultural-science-pack in 1 of 60 intervals (packs spoiled); spoil results in its trash: spoilage 3',1,true),l.line)
  eq(b.working_share,100); eq(b.samples.working,61)
  local function r2(v) return math.floor(v*100+0.5)/100 end
  eq(b.packs[1].used,r2(drained),'the biolab\'s drain, through the inserter\'s refills'); eq(b.packs[1].used,2.9); eq(b.packs[1].unknown_intervals,nil); eq(b.packs[1].held_least,1); eq(b.packs[1].held_most,3)
  assert(b.line:find('biolab (96.5,-56.5): working 100%; packs used in 60s (durability drained): automation-science-pack 2.9,',1,true),b.line)
  eq(out.research.units,r2(units)); eq(out.research.technology,'tesla-weapons')
  eq(out.packs_used_up.by_pack['automation-science-pack'],used_up); eq(used_up,2)
  assert(out.packs_used_up.line:find('science packs used up on nauvis while the watch ran (the production statistics: whole packs, every lab there): automation-science-pack 2',1,true),out.packs_used_up.line)
  assert(out.left_out:find('research and packs used up are the force\'s and the surface\'s, not one lab\'s',1,true))
  -- a lab fast enough to use a whole pack between samples: unknown, not a guess
  tech.research_unit_energy=60
  U.handler({index=1},{positions={{x=96.5,y=-56.5}},seconds=10})
  for t=game.tick+1,game.tick+600 do game.tick=t; U.tick(t) end
  b=U.handler({index=1},{}).machines[1]
  -- 9 of the 10 intervals are 67 ticks (5.8 / 60 x 67 x 0.5 = 3.2 packs at most); the one at the phase's wrap is 7 (0.34)
  eq(b.packs[1].unknown_intervals,9); eq(b.packs[1].of_intervals,10); eq(b.packs[1].unknown_why,'it could use a whole pack between samples')
  -- an assembler is still a crafting machine; a chest is neither
  fails(function() local c={valid=true,name='iron-chest',type='container',position={x=1,y=1}}
    dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return {} end,remote_entity=function() return c end}.handler({index=1},{position={x=1,y=1}}) end,'is not a crafting machine or a lab')
  defines,prototypes=nil,nil
end
print('d20_batch55 P8 uptime for labs and biolabs: ok')
