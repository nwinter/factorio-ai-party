-- Run from repository root: lua tests/d20_batch54.lua
-- d20 batch54 N1 (viewer Aurora, shift46 12:25: "Could fuel alerts show time since departure and compare the existing
-- 60/180-second samples? K2's warning cleared without edits").
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end

-- N1: the fuel outlook flying says how long since the platform left its stop and the engine's 60 and 180 s samples
-- side by side, with the part of each sample spent at the stop before it left.
do
  defines={flow_precision_index={one_minute=1},entity_status={working=1}}
  -- At the stop until 140 s (tanks full, nothing used or made), then 8000/min used and 1500/min made of each fluid.
  local DEP=140
  local function burned(t) return t>DEP and (t-DEP)*8000/60 or 0 end
  local function made(t) return t>DEP and (t-DEP)*1500/60 or 0 end
  local now=0
  local fb={{name='thruster-fuel',amount=25000},{name='thruster-oxidizer',amount=25000}}
  setmetatable(fb,{__len=function() return 2 end})
  fb.get_filter=function(i) return {name=i==1 and 'thruster-fuel' or 'thruster-oxidizer'} end
  local thruster={valid=true,type='thruster',fluidbox=fb}
  local surface={find_entities_filtered=function(f)
    if f.type=='thruster' or type(f.type)=='table' then return {thruster} end
    return {} end}
  local stats={get_output_count=function() return burned(now) end,get_input_count=function() return made(now) end,
    get_flow_count=function(a) return a.category=='input' and 1500 or 8000 end}
  local force={get_fluid_production_statistics=function() return stats end}
  local pl={index=4,name='Kestrel II',surface=surface,force=force,speed=50/60,space_connection={}}
  local store={}
  local EN=require('engine'){state=function() return store end}
  for t=0,180 do
    now=t
    local left=25000-math.max(0,burned(t)-made(t))
    fb[1].amount,fb[2].amount=left,left
    EN.sample(pl,t*60)
  end
  game={tick=180*60}
  local segs={{kind='stop',at='aquilo',start=0,['end']=DEP*60},{kind='leg',from='aquilo',to='gleba',start=DEP*60}}
  local E=require('endurance'){leg=function() return {from='aquilo',to='gleba',left_km=28000} end,segments=function() return segs end,
    engine=function(p) return EN.read(p) end}
  local o=E.fuel_outlook(pl)
  eq(o.short and o.short[1],"thruster-fuel",o.line)
  eq(o.since_departure_s,40)
  eq(o.samples[1].seconds,60); eq(o.samples[1].at_stop_s,20); eq(o.samples[2].seconds,180); eq(o.samples[2].at_stop_s,140)
  eq(o.samples[1].fluids['thruster-fuel'].used_per_min,5333); eq(o.samples[2].fluids['thruster-fuel'].used_per_min,1778)
  eq(o.since_line,'left aquilo 0m40s ago; samples last 60 s (20 s of it at the stop before it left): thruster-fuel used 5333/min, made 1000/min, '
    ..'thruster tanks 25000 -> 20667, thruster-oxidizer used 5333/min, made 1000/min, thruster tanks 25000 -> 20667 | last 180 s (140 s of it '
    ..'at the stop before it left): thruster-fuel used 1778/min, made 333/min, thruster tanks 25000 -> 20667, thruster-oxidizer used 1778/min, '
    ..'made 333/min, thruster tanks 25000 -> 20667')
  -- the outlook's own line stays as it was (platform_endurance and platform_digest read it)
  eq(o.line:find('left aquilo',1,true),nil)
  -- a leg first seen under way (the runtime loaded mid-flight): its start is when it was first seen, said so
  segs[2].partial=true
  has(E.fuel_outlook(pl).since_line,'under way 0m40s since first seen (the departure was before the runtime counted); samples last 60 s: ')
  segs[2].partial=nil
  -- stopped: no departure line
  segs[2]['end']=game.tick; segs[3]={kind='stop',at='gleba',start=game.tick}
  eq(E.since_departure(pl),nil)
  -- no engine samples yet
  segs[3]=nil; segs[2]['end']=nil
  local E2=require('endurance'){leg=function() return {from='aquilo',to='gleba',left_km=28000} end,segments=function() return segs end}
  eq(E2.since_departure(pl).line,'left aquilo 0m40s ago; no engine samples yet')
  defines,game=nil,nil
end
print('d20_batch54 N1 fuel alert since departure: ok')

-- N2 (viewer Aurora, shift47 13:26: "Sampling every 60 ticks can miss a 20-tick pulse entirely"): the pumps are read
-- once a second at a phase that moves 7 ticks a second; a pump working 20 ticks of every 60 reads a third of the time
-- in phase with the old once-a-second read (ticks 0-19) and out of it (ticks 30-49).
do
  defines={entity_status={working=1,no_input_fluid=2}}
  local tick=0
  local function pulse(from) return setmetatable({valid=true},{__index=function(_,k)
    if k=='status' then local ph=tick%60; return (ph>=from and ph<from+20) and 1 or 2 end end}) end
  local function run(from)
    local pumps={pulse(from)}
    local surface={find_entities_filtered=function(f) return f.type=='pump' and pumps or {} end}
    local pl={valid=true,index=1,name='Pulse',surface=surface,force={},speed=0}
    local st={}
    local EN=require('engine'){state=function() return st end}
    for t=0,181*60-1 do
      tick=t
      if t%60==0 then EN.sample(pl,t) end
      EN.pump_tick(t)
    end
    return EN.read(pl)
  end
  for _,from in ipairs({0,30}) do
    local r=run(from)
    eq(r.windows[1].pump_duty,33,'from tick '..from); eq(r.windows[1].pump_samples,60)
    has(r.lines[1],'1 pumps working 33% of the time (60 samples, one a second at a phase 7 ticks later each second: every tick of a second sampled once a minute)')
    eq(r.windows[2].pump_duty,33); eq(r.windows[2].pump_samples,180)
  end
  -- a pump that never works and one that always does
  local r=run(-100); eq(r.windows[1].pump_duty,0)
  r=run(-10); eq(r.windows[2].pump_duty,math.floor(10/60*100+0.5))
  -- before the first phase read of a second: not sampled yet, not "no pumps"
  local pumps={{valid=true,status=1}}
  local pl={valid=true,index=2,name='Fresh',surface={find_entities_filtered=function(f) return f.type=='pump' and pumps or {} end},force={},speed=0}
  local st={}
  local EN=require('engine'){state=function() return st end}
  EN.sample(pl,60); EN.sample(pl,120)
  has(EN.read(pl).lines[1],'; 1 pumps, not sampled yet')
  defines=nil
end
print('d20_batch54 N2 pump duty at moving phases: ok')

-- N3 (viewer Aurora, shift47 13:39: job cards from each agent's board_focus, with its age): a read of board_focus adds
-- rows with the fields, the tick it was set among them, for the stream's cards.
do
  game={tick=600,get_surface=function() return nil end}
  local st={}
  local items={[7]={id=7,kind='project',title='Aquilo heat',status='doing',owner='sol',notes={},created_tick=0,updated_tick=0,
    steps={{n=1,text='foundation',done_by='sol',done_tick=0},{n=2,text='heat pipes to the chest row'}}}}
  local P=dofile('mod/agent-harness_0.1.0/progress.lua'){state=function() return st end,items=function() return items end,
    owner_surface=function() return 'aquilo' end,total=function() return 0 end,since_request=function() return 60,3 end,
    waiting=function() return nil end,who=function(p) return p.name end,agents=function() return {{name='sol',index=3},{name='astra',index=1}} end,QUIET=72000,PROJECT_QUIET=108000}
  local r=P.focus({name='astra'},{})
  eq(r.focus[1],'no focus set'); eq(#r.rows,0); eq(r.tick,600)
  P.focus({name='sol'},{id=7,step=2,blocker='no heat pipes in the hub'})
  game.tick=600+5*3600
  r=P.focus({name='astra'},{})
  eq(#r.rows,1)
  local row=r.rows[1]
  eq(row.agent,'sol'); eq(row.id,7); eq(row.title,'Aquilo heat'); eq(row.step,'step 2 heat pipes to the chest row'); eq(row.tick,600)
  eq(row.blocker,'no heat pipes in the hub'); eq(row.verify,nil); eq(row.stalled,nil); eq(row.gone,nil)
  has(r.focus[1],'sol focus (set 5m00s ago): #7 Aquilo heat')
  items[7]=nil
  row=P.focus({name='astra'},{agent='sol'}).rows[1]
  eq(row.gone,true); eq(row.title,nil); eq(row.step,'step 2')
  game=nil
end
print('d20_batch54 N3 board_focus rows: ok')

-- N2 also in uptime (uptime.lua, d20 batch53 M3, merged into main after N2's checkpoint): its status samples were at
-- tick 7 of each second (runtime.lua called it at tick % 60 == 7); now sample k at start + 60 k + (7 k mod 60). A machine
-- working 20 ticks of every 60, from the old phase (ticks 0-19, sampled at 7: 100%) and out of it (ticks 30-49: 0%):
-- 33% either way over 60 s.
do
  defines={inventory={assembling_machine_input=2,furnace_source=2}}
  local function run(from)
    game={tick=0}
    local st={}
    local recipe={name='iron-gear-wheel',ingredients={{type='item',name='iron-plate',amount=2}}}
    local m=setmetatable({valid=true,name='assembling-machine-2',type='assembling-machine',position={x=0.5,y=0.5},products_finished=0,
      get_recipe=function() return recipe end,get_inventory=function() return {get_item_count=function() return 10 end} end},
      {__index=function(_,k) if k=='status' then local ph=game.tick%60; return (ph>=from and ph<from+20) and 'working' or 'waiting_for_space_in_destination' end end})
    local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() return m end,
      status_name=function(e) return e.status end}
    U.handler({index=1},{positions={{x=0.5,y=0.5}},seconds=60})
    for t=1,60*60 do game.tick=t; U.tick(t) end
    return U.handler({index=1},{})
  end
  for _,from in ipairs({0,30}) do
    local out=run(from)
    eq(out.done,true); eq(out.phase_step_ticks,7)
    -- 61 samples: the start's and 60 more, the last at the window's end (tick 3600, phase 0)
    eq(out.samples,61)
    local w=out.machines[1].samples.working
    assert(w==20 or w==21,'from '..from..': '..tostring(w))
    has(out.machines[1].line,'working 3')
  end
  has(run(0).left_out,'at a phase 7 ticks later each second')
  game,defines=nil,nil
end
print('d20_batch54 N2 uptime samples at moving phases: ok')

-- N4 (Sol, harness request #1389, shift47 ticks 38355977-38363365): load_silo on Aquilo's west silo.
-- (a) the gather began at 38355977 with the rocket building (36/50 parts, nothing aboard); robots the silo's automatic
-- requests had sent before the load switched them off put 3 decider combinators in, and the silo launched them at
-- 38357969; the load ended rocket_launched with nothing of its own aboard. A launch is this load's only when the rocket
-- held something of it.
do
  game={tick=38358146}
  prototypes={item={}}
  defines={inventory={rocket_silo_rocket=1},rocket_silo_status={rocket_ready=13}}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=-18.5,y=17.5},unit_number=9}
  local launched={tick=38357969,cargo='decider-combinator*3'}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){last_launch=function() return launched end}
  local function load(extra)
    local a={silo=silo,started_tick=38355977,launch_before=38354478,rows={},trips=1,items={},load={},loaded=0,taken=0,
      goals={{name='bulk-inserter',quality='normal',before=0,target=2},{name='decider-combinator',quality='normal',before=0,target=3},
        {name='fast-underground-belt',quality='normal',before=0,target=6}}}
    for k,v in pairs(extra or {}) do a[k]=v end
    return a
  end
  local action=load()
  local gone,passed=R.launch_check(action)
  eq(gone,nil)
  eq(passed,'a rocket launched 2 s ago (cargo: decider-combinator*3) held nothing of this load: it had loaded nothing and the rocket held none of the list when the load began; '
    ..'the load goes on for the silo\'s next rocket; that rocket carried decider-combinator 3 of this list (not counted toward it)')
  eq(action.launch_before,38357969)
  -- once passed, the same launch is not news again
  gone,passed=R.launch_check(action); eq(gone,nil); eq(passed,nil)
  -- the next rocket launched by another hand after this load put some in: this load's, it ends
  launched={tick=38359000,by='astra',cargo='bulk-inserter*2'}
  action.loaded=2; action.loaded_items={['bulk-inserter']=2}
  game.tick=38359060
  gone,passed=R.launch_check(action); eq(gone.tick,38359000); eq(passed,nil)
  -- the rocket held some of the list when the load began (counted toward its targets): this load's
  launched={tick=38357969,cargo='bulk-inserter 2'}
  local a2=load(); a2.goals[1].before=2
  gone=R.launch_check(a2); eq(gone and gone.tick,38357969)
  -- through the walk: the chest stop after the passed launch takes on (no rocket_launched), the row says why
  launched={tick=38357969,cargo='decider-combinator*3'}
  local took={}
  local R2=dofile('mod/agent-harness_0.1.0/rocketload.lua'){last_launch=function() return launched end,give_sources=function() return {} end,
    take=function(_,_,name,_,n) took[#took+1]=name..' '..n; return {transferred=n} end}
  local a3=load()
  local out=R2.walk_visit({},a3,{position={x=-16.5,y=-10.5},name='storage-chest'})
  eq(a3.final,nil); eq(out.stop,nil); eq(out.transferred,11)
  eq(table.concat(took,', '),'bulk-inserter 2, decider-combinator 3, fast-underground-belt 6')
  has(a3.rows[1].passed,'held nothing of this load'); eq(a3.rows[2].taken,11)
  game,prototypes,defines=nil,nil,nil
end
print('d20_batch54 N4a a launch under way before the load is not its own: ok')

-- (b) Sol's personal logistics: trash unrequested on and no personal request for the gathered items; robots took them
-- back from the trash slots on the walk and the rocket got 0. The dry run and the gather say so.
do
  local T=dofile('mod/agent-harness_0.1.0/trash.lua'){}
  local rp={enabled=true,trash_not_requested=true,filters={{name='speed-module-2',quality='normal',count=0,max_count=2},{name='long-handed-inserter',quality='normal',count=0}}}
  local p={character={valid=true,get_requester_point=function() return rp end}}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){trash=T}
  local list={{name='bulk-inserter',quality='normal',count=2},{name='assembling-machine-3',quality='normal',count=1},
    {name='speed-module-2',quality='normal',count=4},{name='long-handed-inserter',quality='normal',count=2}}
  local n=R.trash_note(p,list)
  eq(n.line,'your trash unrequested is on and no personal request names bulk-inserter, assembling-machine-3: what you carry of them the game moves to your trash slots, where logistic robots take it; '
    ..'your personal request max is under the load for speed-module-2 max 2 of the 4 this load carries: the rest goes to your trash slots')
  eq(#n.unrequested,2); eq(#n.over,1)
  -- trash unrequested off: only the max is said
  rp.trash_not_requested=false
  eq(R.trash_note(p,list).line,'your personal request max is under the load for speed-module-2 max 2 of the 4 this load carries: the rest goes to your trash slots')
  -- Sol's fix (personal requests with no max for each): nothing to say
  rp.trash_not_requested=true
  rp.filters={{name='bulk-inserter',count=0},{name='assembling-machine-3',count=0},{name='speed-module-2',count=0},{name='long-handed-inserter',count=0}}
  eq(R.trash_note(p,list),nil)
  -- personal logistics off: the game trashes nothing
  rp.enabled=false; rp.filters={}
  eq(R.trash_note(p,list),nil)
end
print('d20_batch54 N4b trash unrequested and the manifest: ok')

-- N5 (Sol, harness request #1390): Limestone-spare-unbuilt's pump duty cut from 10% to 5%: the engine read 48.9 km/s
-- over the last 60 s while platform_endurance kept 5940 km/min (the last leg's, about 99 km/s) and an ETA of 14m57s for
-- 88883 km, more than 3 min into the leg. A leg under way at its own measured speed once it has one.
do
  defines={entity_status={working=1},flow_precision_index={one_minute=1}}
  local pl={valid=true,index=9,name='Limestone-spare-unbuilt',speed=0,space_connection={},force={},
    surface={find_entities_filtered=function() return {} end}}
  local st={}
  local EN=require('engine'){state=function() return st end}
  -- the leg began at tick 0: 30 s speeding up to 49 km/s, then flat
  local function fly(t0,t1,at)
    for t=t0,t1,60 do pl.speed=at(t)/60; EN.sample(pl,t) end
  end
  fly(0,30*60,function(t) return 49*t/1800 end)
  -- 30 s in, still speeding up: the past leg's 99 km/s, said so
  game={tick=30*60}
  local v,by,own=EN.leg_speed(pl,30*60,99/60,'the last leg nauvis->vulcanus: 59400 km flown in 10m00s')
  eq(v,99/60); eq(own,false); eq(by,'the last leg nauvis->vulcanus: 59400 km flown in 10m00s (it speeds up now: 49 km/s)')
  fly(31*60,200*60,function() return 48.9 end)
  game={tick=200*60}
  v,by,own=EN.leg_speed(pl,200*60,99/60,'the last leg nauvis->vulcanus: 59400 km flown in 10m00s')
  eq(own,true); eq(math.floor(v*3600+0.5),2934); eq(by,'this leg: its last 60 s mean, 48.9 km/s (lowest 48.9, highest 48.9)')
  -- no past speed and in the first minute with no samples: the speed now
  local fresh={valid=true,index=10,name='Fresh',speed=0.5,space_connection={}}
  v,by,own=EN.leg_speed(fresh,600,nil,nil); eq(v,0.5); eq(by,'this leg: its speed now, 30 km/s'); eq(own,true)
  -- a leg flying faster than the last one, settled: its own
  v,by,own=EN.leg_speed(pl,200*60,30/60,'the last leg'); eq(own,true); eq(math.floor(v*60*10+0.5)/10,48.9)
  -- the platforms row's leg ETA (freight.lua leg) by the same rule: this leg's speed, said, not the cruise
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end,leg_speed=function(p,since,past,pby) return EN.leg_speed(p,since,past,pby) end}
  st.freight={[9]={cruise=99/60,segs={{kind='leg',from='vulcanus',to='nauvis',start=0}}}}
  pl.space_connection={from={name='vulcanus'},to={name='nauvis'},length=100000}; pl.distance=0.11117; pl.schedule={records={{station='nauvis'}},current=1}
  local leg=F.leg(pl)
  eq(leg.eta_from,nil); eq(leg.speed_from,'this leg: its last 60 s mean, 48.9 km/s (lowest 48.9, highest 48.9)')
  eq(math.floor(leg.eta_ticks/60+0.5),math.floor(88883/48.9+0.5))
  -- platform_endurance's fuel outlook and route speed, at this leg's speed, saying so
  local segs={{kind='leg',from='nauvis',to='vulcanus',start=-20*3600,['end']=-10*3600,km0=0,km1=59400},
    {kind='stop',at='vulcanus',start=-10*3600,['end']=0},{kind='leg',from='vulcanus',to='nauvis',start=0}}
  local E=require('endurance'){leg=function() return {from='vulcanus',to='nauvis',left_km=88883} end,segments=function() return segs end,
    leg_speed=function(p,since,past,pby) return EN.leg_speed(p,since,past,pby) end}
  local o=E.fuel_outlook(pl)
  has(o.line,'leg vulcanus->nauvis, 88883 km left, about 30m17s at 2934 km/min (this leg: its last 60 s mean, 48.9 km/s (lowest 48.9, highest 48.9))')
  eq(o.leg_left_min,30.3)
  -- without the engine's samples (an older runtime's api): the old rule, the last leg's while under 90% of it
  local E0=require('endurance'){leg=function() return {from='vulcanus',to='nauvis',left_km=88883} end,segments=function() return segs end}
  has(E0.fuel_outlook(pl).line,'about 14m57s at 5940 km/min (the last leg nauvis->vulcanus: 59400 km flown in 10m00s (it speeds up now, 2934 km/min))')
  game,defines=nil,nil
end
print('d20_batch54 N5 a leg at its own measured speed: ok')

-- N7 (Astra, harness request #1405): platform_delete as the platform GUI deletes (LuaSpacePlatform.destroy: the game
-- schedules it 18000 ticks ahead; cancel_deletion), with a dry run; a platform not empty or occupied refused unless
-- confirm is its name.
do
  game={tick=1000}
  defines={inventory={hub_main=1,hub_trash=2}}
  local cargo={{name='iron-plate',count=100,quality='normal'}}
  local hub={valid=true,get_inventory=function(id) return {get_contents=function() return id==1 and cargo or {} end} end}
  local char={valid=true,type='character',unit_number=5,position={x=2,y=2}}
  local chars={char}
  local surface={count_entities_filtered=function(f)
      if f.type and f.type[1]=='entity-ghost' then return 1 end
      if f.type=='cargo-pod' then return 0 end
      return 1+1+#chars+2 end,
    find_entities_filtered=function(f)
      if f.type=='character' then return chars end
      return {hub,{valid=true,name='gun-turret'},{valid=true,name='gun-turret'}} end,
    count_tiles_filtered=function() return 100 end}
  local pl={name='Bastion',surface=surface,hub=hub,scheduled_for_deletion=0}
  pl.destroy=function() pl.scheduled_for_deletion=18000 end
  pl.cancel_deletion=function() pl.scheduled_for_deletion=0 end
  local D=dofile('mod/agent-harness_0.1.0/platdelete.lua'){platform=function() return pl end,character_owner=function() return 'astra' end,
    incoming=function() return {rockets=1,lines={'a rocket from aquilo launched 5s ago (tick 700): repair-pack*50 (rising over aquilo)'}} end}
  local r=D.handler({},{platform='Bastion',dry_run=true})
  eq(r.hub_cargo,'iron-plate*100'); eq(r.entities,2); eq(r.entity_names,'gun-turret*2'); eq(r.ghosts,1); eq(r.foundation_tiles,100)
  eq(r.characters[1],'astra at (2,2)'); eq(r.occupied,true); eq(r.empty,false)
  has(r.line,'Bastion: would be refused without confirm: not empty (hub cargo, 2 entities besides the hub, cargo pods on their way or on it); occupied (astra at (2,2))')
  has(r.lines[4],'cargo pods on their way: a rocket from aquilo launched 5s ago')
  eq(pl.scheduled_for_deletion,0,'a dry run deletes nothing')
  local ok,err=pcall(D.handler,{},{platform='Bastion'})
  assert(not ok); has(err,'nothing deleted; confirm: "Bastion" deletes it with them')
  ok,err=pcall(D.handler,{},{platform='Bastion',confirm='bastion'}); assert(not ok,'confirm is the exact name')
  r=D.handler({},{platform='Bastion',confirm='Bastion'})
  eq(r.scheduled_ticks,18000); eq(r.due_tick,19000); has(r.line,'Bastion: scheduled for deletion in 300s (tick 19000), the game\'s own delay')
  ok,err=pcall(D.handler,{},{platform='Bastion',confirm='Bastion'}); assert(not ok); has(err,'scheduled for deletion already, in 300s')
  r=D.handler({},{platform='Bastion',cancel=true}); eq(r.cancelled,true); eq(pl.scheduled_for_deletion,0)
  -- emptied: no cargo, only the hub, no pods, nobody aboard: deleted without confirm
  cargo={}; chars={}
  surface.count_entities_filtered=function(f) if f.type then return 0 end return 1 end
  surface.find_entities_filtered=function(f) if f.type=='character' then return {} end return {hub} end
  D=dofile('mod/agent-harness_0.1.0/platdelete.lua'){platform=function() return pl end}
  r=D.handler({},{platform='Bastion',dry_run=true}); eq(r.empty,true); eq(r.occupied,false); has(r.line,'empty and unoccupied: platform_delete deletes it')
  r=D.handler({},{platform='Bastion'}); eq(r.scheduled_ticks,18000)
  game,defines=nil,nil
end
print('d20_batch54 N7 platform_delete: ok')

-- N9 (Sol #1427: a one-belt repair on Edge8 needed ghosts_waiting off while platform_loss and the ammo guard stayed;
-- a full-plan replace ran platform_schedule current 2 again, which failed and paused the queue with no guard).
-- queue_edit guards on a running platform-lane queue: ghosts_waiting removed, the active wait, the pending step and
-- the other guards' baselines kept; replace and add by id; refusals.
do
  defines={inventory={turret_ammo=7}}
  prototypes={item={['railgun-ammo']={}},quality={normal={}}}
  local st={}
  game={tick=1000}
  local function rail(x,y,n)
    local e={valid=true,name='railgun-turret',type='ammo-turret',position={x=x,y=y},force={name='player'},surface={name='platform-8'}}
    e.get_inventory=function() return {get_item_count=function() return n end,get_contents=function() return {{name='railgun-ammo',count=n}} end} end
    return e
  end
  local guns={rail(-6,-12,10),rail(6,-12,10)}
  local ghosts=0
  local deck={name='platform-8',find_entities_filtered=function() local out={} for _,e in ipairs(guns) do if e.valid then out[#out+1]=e end end return out end,
    count_entities_filtered=function() return ghosts end}
  local edge={valid=true,name='Edge8',surface=deck}
  local force={name='player',platforms={edge}}
  local sol={index=1,valid=true,position={x=0,y=0},surface={name='nauvis'},force=force}
  local L=dofile('mod/agent-harness_0.1.0/lostlog.lua'){state=function() return st end,position=function(v) return v end}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
    losses_since=function(f,s,since,names,max) return L.since(f,s,since,names,max) end}
  local arrived=false
  local function check(p,c,record)
    if c['until']=='platform_arrived' then return arrived,arrived and 'Edge8 at vulcanus' or 'Edge8 flying' end
    return C.check(p,c,nil,record)
  end
  local schedules={}
  local base={state=function() return st end,player=function() return sol end,
    handlers={platform_schedule=function(_,a) schedules[#schedules+1]=a.current; return {ok=true} end},
    condition=function(p,c) return check(p,c) end,wait_check=check,validate_condition=function(c) if c['until']~='platform_arrived' then C.validate(c) end end,
    busy=function() return false end,stop=function() end,stop_index=function() end}
  local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
  local S=dofile('mod/agent-harness_0.1.0/queue_lanes.lua'){scheduler=factory(base),factory=factory,base=base,is_read=function() return false end}
  local function run(n) for _=1,n do game.tick=game.tick+1; S.tick() end end
  local lane='platform:Edge8'
  local q=S.handlers.queue_submit(sol,{lane=lane,steps={{action='platform_schedule',args={platform='Edge8',current=2}},
      {action='wait_until',args={['until']='platform_arrived',platform='Edge8',timeout=54000}},
      {action='platform_schedule',args={platform='Edge8',current=3}}},
    guards={{when={['until']='ammo_below',platform='Edge8',count=1}},{when={['until']='platform_loss',platform='Edge8'}},
      {when={['until']='ghosts_waiting',platform='Edge8'}}}})
  eq(q.lane,lane)
  eq(q.guards[1].id,'guard-1'); eq(q.guards[3].id,'guard-3'); eq(q.guards[2].when.loss_since,1000,'counted from the submit')
  run(30)
  local lq=st['lane_queues|Edge8'][1]
  eq(#schedules,1); eq(lq.current.action,'wait_until'); local wait_id=lq.current.id
  -- the repair is planned at tick 2000: ghosts_waiting goes, the rest stays
  run(970)
  local rev=S.handlers.queue_status(sol,{lane=lane}).revision
  local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
  fails(function() S.handlers.queue_edit(sol,{lane=lane,expected_revision=rev,guards={remove={'guard-9'}}}) end,'guards.remove[1]: no guard guard-9; guards: guard-1 ammo_below, guard-2 platform_loss, guard-3 ghosts_waiting')
  fails(function() S.handlers.queue_edit(sol,{lane=lane,expected_revision=rev-1,guards={remove={'guard-3'}}}) end,'queue revision conflict')
  fails(function() S.handlers.queue_edit(sol,{lane=lane,guards={remove={'guard-3'}}}) end,'requires expected_revision')
  fails(function() S.handlers.queue_edit(sol,{lane=lane,expected_revision=rev,index=1,steps={},guards={remove={'guard-3'}}}) end,'guards edits the guards only')
  fails(function() S.handlers.queue_edit(sol,{lane=lane,expected_revision=rev,guards={add={{when={['until']='no_enemies'}}}}}) end,'guards.add: guards[1]: when: remote lane wait_until supports')
  fails(function() S.handlers.queue_edit(sol,{lane=lane,expected_revision=rev,guards={drop={'guard-3'}}}) end,'unknown: drop')
  eq(#lq.guards,3,'a refused edit changes nothing')
  local r=S.handlers.queue_edit(sol,{lane=lane,expected_revision=rev,guards={remove={'guard-3'}}})
  eq(r.lane,lane); eq(r.revision,rev+1)
  eq(#r.guards,2); eq(r.guards[1].id,'guard-1'); eq(r.guards[1].edit,'kept'); eq(r.guards[2].id,'guard-2'); eq(r.guards[2].since_tick,1000)
  eq(r.guards[2].baseline,'losses on Edge8 since tick 1000'); eq(r.guards[1].baseline,'read at each check: a turret on Edge8 holding under 1')
  eq(r.guards[2].set_tick,1000,'the guard set at the submit')
  eq(r.line,'guards edited (revision '..(rev+1)..'): 2 kept, 0 replaced, 0 added, 1 removed (guard-3); the active step ('..wait_id..' wait_until) and the 1 pending step go on')
  eq(r.guard_lines[2],'guard-2 platform_loss (kept): losses on Edge8 since tick 1000')
  eq(lq.current.id,wait_id,'the wait goes on'); eq(lq.current.wait_started,1001); eq(#lq.pending,1); eq(lq.paused,false)
  -- the repair's ghosts: nothing fires, nothing runs again
  ghosts=3
  run(100)
  eq(lq.current.id,wait_id); eq(lq.paused,false); eq(#schedules,1)
  -- replace the ammo guard (a new threshold: its own guard, same id) and add a named loss guard counting from a tick
  rev=lq.revision
  r=S.handlers.queue_edit(sol,{lane=lane,expected_revision=rev,guards={replace={{id='guard-1',when={['until']='ammo_below',platform='Edge8',count=5}}},
    add={{when={['until']='platform_loss',platform='Edge8',names={'thruster'},since_tick=1500}}}}})
  eq(r.guards[1].id,'guard-1'); eq(r.guards[1].edit,'replaced'); eq(r.guards[1].set_tick,2100); eq(lq.guards[1].when.count,5)
  eq(r.guards[2].edit,'kept'); eq(r.guards[2].since_tick,1000)
  eq(r.guards[3].id,'guard-4'); eq(r.guards[3].edit,'added'); eq(r.guards[3].since_tick,1500); eq(r.guards[3].baseline,'losses on Edge8 since tick 1500 (of thruster)')
  fails(function() S.handlers.queue_edit(sol,{lane=lane,expected_revision=lq.revision,guards={remove={'guard-1'},replace={{id='guard-1',when={['until']='ammo_below',platform='Edge8',count=2}}}}}) end,'removed in this call too')
  -- a loss now: the kept guard fires, counting from the submit
  game.tick=2200
  guns[2].valid=false
  L.died(guns[2],'big-metallic-asteroid')
  run(20)
  eq(lq.paused,true); has(lq.paused_why.line,'a guard fired: platform_loss')
  local fired=lq.history[#lq.history]
  eq(fired.action,'guard'); has(fired.result.saw,'1 of ours lost since tick 1000: railgun-turret (6,-12)')
  eq(#schedules,1,'platform_schedule ran once')
  -- guards from a runtime before ids get theirs on a read
  lq.guards[1].id=nil
  local s2=S.handlers.queue_status(sol,{lane=lane})
  eq(s2.guards[1].id,'guard-5')
  defines,prototypes=nil,nil
end
print('d20_batch54 N9 queue_edit guards: ok')
