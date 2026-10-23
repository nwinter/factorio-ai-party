-- Run from repository root: lua tests/survey.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path  -- (walk.lua)
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(list,pattern)
  for _,s in ipairs(list or {}) do if s:find(pattern,1,true) then return s end end
  error('no entry containing '..pattern..' in '..table.concat(list or {},' | '))
end
defines={flow_precision_index={one_minute=1,ten_minutes=2},inventory={lab_input=9,turret_ammo=7},
  entity_status={working=1,no_fuel=2,low_power=3,no_power=4,missing_science_packs=5,item_ingredient_shortage=6}}
local status_names={}
for name,id in pairs(defines.entity_status) do status_names[id]=name end
prototypes={item={['automation-science-pack']={type='tool'},['iron-plate']={type='item'},coal={type='item'}}}
local storage={}
game={tick=0}
-- Production statistics: per-minute rates by precision (1 = 1m, 2 = 10m).
local rates={output={['automation-science-pack']={12,10},coal={30,30}},input={['iron-plate']={120,100},['iron-gear-wheel']={20,20}}}
local stats={output_counts={['automation-science-pack']=1,coal=1},input_counts={['iron-plate']=1},
  get_flow_count=function(f) local r=rates[f.category][f.name]; return r and r[f.precision_index] or 0 end}
local function stack(name,count) return {valid_for_read=count>0,name=name,count=count} end
local slots={}
local main=setmetatable({},{__len=function() return 20 end,__index=function(_,i)
  if i=='count_empty_stacks' then return function() local n=0; for k=1,20 do if not (slots[k] and slots[k].valid_for_read) then n=n+1 end end; return n end end
  return slots[i] or stack(nil,0)
end})
local lab_inv={get_item_count=function() return 0 end}
local tech={name='automation',research_unit_ingredients={{name='automation-science-pack',amount=1}}}
local force={name='player',current_research=tech,research_progress=0.5,research_queue={tech},
  get_item_production_statistics=function() return stats end}
local function machine(name,type,status,x,extra)
  local e={valid=true,name=name,type=type,status=defines.entity_status[status],position={x=x,y=0}}
  for k,v in pairs(extra or {}) do e[k]=v end
  return e
end
local entities={
  machine('assembling-machine-1','assembling-machine','working',1,{electric_buffer_size=100}),
  machine('assembling-machine-1','assembling-machine','item_ingredient_shortage',2,{electric_buffer_size=100}),
  machine('assembling-machine-1','assembling-machine','low_power',3,{electric_buffer_size=100}),
  machine('boiler','boiler','no_fuel',4,{burner={inventory={is_empty=function() return true end},remaining_burning_fuel=0}}),
  machine('boiler','boiler','working',5,{burner={inventory={is_empty=function() return true end},remaining_burning_fuel=10}}),
  machine('boiler','boiler','working',6,{burner={inventory={is_empty=function() return false end},remaining_burning_fuel=10}}),
  machine('lab','lab','missing_science_packs',7,{electric_buffer_size=100,get_inventory=function() return lab_inv end}),
}
-- Spoilable fuel (Sol, shift13 16:50: biochambers starved with 20 nutrients loaded, the batch rotting within seconds):
-- two biochambers, one whose nutrients spoil in 4 s, one in 2 minutes; and coal, which does not spoil.
prototypes.item.nutrients={type='item'}
local function fuel_inv(list)
  local inv=setmetatable({is_empty=function() return #list==0 end},{__len=function() return #list end,__index=function(_,i) return list[i] end})
  return inv
end
local function nutrients(ticks) return {valid_for_read=true,name='nutrients',spoil_tick=game.tick+ticks,prototype={get_spoil_ticks=function() return 18000 end}} end
local coal={valid_for_read=true,name='coal',spoil_tick=0,prototype={get_spoil_ticks=function() return 0 end}}
entities[#entities+1]=machine('biochamber','assembling-machine','working',30,{burner={inventory=fuel_inv({nutrients(7200),nutrients(240)}),remaining_burning_fuel=10}})
entities[#entities+1]=machine('biochamber','assembling-machine','working',32,{burner={inventory=fuel_inv({nutrients(7200)}),remaining_burning_fuel=10}})
entities[#entities+1]=machine('stone-furnace','furnace','working',34,{burner={inventory=fuel_inv({coal}),remaining_burning_fuel=10}})
for i,n in ipairs{0,3,20} do
  entities[#entities+1]=machine('gun-turret','ammo-turret','working',10+i,{get_inventory=function() return {get_item_count=function() return n end} end})
end
-- Flamers as the 2.0 engine has them: a 100-unit fluidbox on the pipe line (get_capacity: the whole segment's, 66700)
-- and a 100-unit buffer it fires from; get_fluid_contents holds both. One dry, one with 20 of 200 (low), one full,
-- Astra's (shift11 16:36: its pipe drained, 87.2 crude oil in its buffer; status said dry), and one with crude oil in
-- its box.
local FLAMER={name='flamethrower-turret',fluidbox_prototypes={{volume=100}},fluid_buffer_size=100,
  attack_parameters={fluids={{type='crude-oil'},{type='heavy-oil'},{type='light-oil'}}}}
for i,f in ipairs{{0,0},{0,20},{100,100},{0,87.2},{87.2,0}} do
  local contents=f[1]+f[2]>0 and {['crude-oil']=f[1]+f[2]} or {}
  entities[#entities+1]=machine('flamethrower-turret','fluid-turret','working',20+i,{prototype=FLAMER,
    fluidbox={[1]=f[1]>0 and {name='crude-oil',amount=f[1]} or nil,get_capacity=function() return 66700 end},
    get_fluid_contents=function() return contents end})
end
-- Belts: one unpaired entrance, one pair, a line end, and a belt pointing
-- into the back of another belt (no output connection, belt ahead).
local ugs={{position={x=-3.5,y=-27.5},belt_to_ground_type='input'},{position={x=0.5,y=5.5},belt_to_ground_type='output',neighbours={}}}
local function belt(x,y,d,outputs) return {name='transport-belt',position={x=x,y=y},direction=d,belt_neighbours={outputs=outputs or {}}} end
local belts={belt(0.5,9.5,4),belt(1.5,9.5,8),belt(5.5,9.5,4,{{}})}
local surface={index=1,find_entities_filtered=function(f)
  if f.type=='underground-belt' then return ugs end
  if f.type=='transport-belt' then return belts end
  if f.position then return (f.position.x==1.5 and f.position.y==9.5) and {belts[2]} or {} end
  return entities
end}
local p={index=1,force=force,surface=surface,get_main_inventory=function() return main end}
local S=dofile('mod/agent-harness_0.1.0/survey.lua'){state=function() return storage end,status_name=function(e) return status_names[e.status] end}

-- Factory line: science consumed, plates produced, research progress.
local s=S.summary(p)
eq(s.inv,'free=20/20')
eq(s.factory.science,'automation 12|10 /min (1m|10m)')
eq(s.factory.plates,'iron-plate 120|100 /min (1m|10m)')
eq(s.factory.research,'automation 50% (queue ends)')
eq(s.machines['assembling-machine-1'],'1/3 working, 1 item_ingredient_shortage, 1 low_power')
eq(s.machines.boiler,'2/3 working, 1 no_fuel')
eq(s.machine_positions,nil)
has(s.warnings,'fuel: biochamber 0/2 no_fuel, fuel spoils within 60s in 1 (the first: nutrients in 4s at (30,0)); boiler 1/3 no_fuel at (4,0), 1 burning their last fuel')
assert(not has(s.warnings,'fuel:'):find('stone-furnace',1,true),'coal does not spoil: no stone-furnace part')
-- A burner its full burnt-result slot stopped (burnt.lua; Sol, shift14: two biochambers read working, spoilage*200 in that
-- slot): counted in the fuel part whatever its status reads.
local S3=dofile('mod/agent-harness_0.1.0/survey.lua'){state=function() return {} end,status_name=function(e) return status_names[e.status] end,
  burnt_stuck=function(e) return e.name=='biochamber' and e.position.x==30 and {burnt='spoilage*200'} or nil end}
has(S3.summary(p).warnings,'fuel: biochamber 0/2 no_fuel, 1 stopped by a full burnt-result slot or unusable fuel (the first at (30,0): spoilage*200), fuel spoils within 60s in 1')
has(s.warnings,'power: 1 of 4 machines low_power: assembling-machine-1 (3,0) (fh call power lists them)')
has(s.warnings,'ammo: gun-turret 1/3 empty at (11,0), 1 below 5 at (12,0); rearm radius=R')
has(s.warnings,'flamer oil: flamethrower-turret 4 of 5 with oil (crude-oil 20 at (22,0), ...); 1/5 dry at (21,0), 1 below 25% at (22,0) 10%; fh call flamers')
has(s.warnings,'belts: 1 unpaired undergrounds: input (-3.5,-27.5)')
has(s.warnings,'belts: 1 belts point into a belt they cannot feed: (0.5,9.5) into transport-belt')
eq(s.factory.belt_ends,'1 line ends')
has(s.warnings,'labs: 1/1 missing packs: automation-science-pack (1 labs)')
-- Cached between polls; machines=true rescans and lists positions.
entities[2].status=defines.entity_status.working
eq(S.summary(p).machines['assembling-machine-1'],'1/3 working, 1 item_ingredient_shortage, 1 low_power')
local detail=S.summary(p,true)
eq(detail.machines['assembling-machine-1'],'2/3 working, 1 low_power')
eq(detail.machine_positions['assembling-machine-1'].low_power[1].x,3)
-- The ETA comes from sampled progress; a short one with nothing next warns.
game.tick=600; force.research_progress=0.75
s=S.summary(p)
eq(s.factory.research,'automation 75% eta 10s (queue ends)')
has(s.warnings,'research queue ends in 10s with nothing next')
force.research_queue={tech,{name='logistics'}}
game.tick=1200; force.research_progress=0.875
eq(S.summary(p).factory.research,'automation 87% eta 7s next logistics')
force.current_research=nil
game.tick=1800; has(S.summary(p).warnings,'research idle: nothing queued (1 labs)')
force.current_research=tech

-- Hand share: fed against consumption, collected and crafted against production.
S.log_hand('fed','coal',60); S.log_hand('collected','iron-gear-wheel',50); S.log_hand('crafted','iron-gear-wheel',10)
game.tick=2400
eq(S.summary(p).factory.hand,'fed coal 60 (20%); collected iron-gear-wheel 50 (25%); crafted iron-gear-wheel 10 (5%) (10m)')
-- Buckets older than 10 minutes drop out.
game.tick=2400+3600*10; S.log_hand('fed','coal',3)
game.tick=game.tick+600
eq(S.summary(p).factory.hand,'fed coal 3 (1%) (10m)')

-- Inventory: nearly full names the biggest slot users; hoarding needs 10 min
-- without the count going down.
for i=1,16 do slots[i]=stack('stone',50) end
slots[17]=stack('coal',10)
game.tick=100000; S.sample(p)
s=S.summary(p)
eq(s.inv,'free=3/20')
has(s.warnings,'inventory: 17/20 slots (3 free); most slots: stone 16, coal 1')
for _,w in ipairs(s.warnings) do assert(not w:find('hoarding'),w) end
game.tick=100000+36000; S.sample(p)
has(S.summary(p).warnings,'hoarding: stone 16/20 slots, not drawn down for 10m')
-- A decrease resets the clock.
slots[16]=stack('stone',10); game.tick=game.tick+3600; S.sample(p)
for _,w in ipairs(S.summary(p).warnings) do assert(not w:find('hoarding'),w) end
-- Agents on two surfaces each keep their own survey for 10 s (shift03: one
-- entry per force made them replace each other, a rescan on nearly every status).
local scans=0
local function counted(s) local find=s.find_entities_filtered; s.find_entities_filtered=function(f) if type(f.type)=='table' and f.type[1]=='assembling-machine' then scans=scans+1 end return find(f) end; return s end
counted(surface)
local other=counted({index=2,find_entities_filtered=function(f) if f.position then return {} end if type(f.type)=='table' then return {entities[1]} end return {} end})
local q={index=2,force=force,surface=other,get_main_inventory=function() return main end}
game.tick=200000
for _=1,10 do S.summary(p); S.summary(q); game.tick=game.tick+30 end
eq(scans,2)
eq(S.summary(q).machines['assembling-machine-1'],'1/1 working'); eq(S.summary(p).machines['assembling-machine-1'],'2/3 working, 1 low_power')
eq(S.summary(q).as_of,200000)
game.tick=200600; S.summary(q); eq(scans,3)

-- The background survey (task-statuscost, 01:15 on world n: survey.summary 60 ms in a full status; operator 04:00:
-- survey.tick 50-57 ms in a game second every 10 s): for each force and surface read lately, every 30 s a job walks
-- the surface a band of chunks a step (walk.lua; every type in one find) and reads 150 entities a step, a step every
-- few ticks, then makes the same summary; a status reads the last finished one and finds nothing.
do
  storage.survey_cache=nil; storage.survey_jobs=nil; storage.survey_bg=nil; storage.survey_read=nil
  game.tick=300000
  local at_once=S.summary(p)
  game.forces={[force.name]=force}
  game.get_surface=function(i) return i==surface.index and surface or nil end
  for _,e in ipairs(ugs) do e.valid,e.type,e.name=true,'underground-belt','underground-belt' end
  for _,e in ipairs(belts) do e.valid,e.type=true,'transport-belt' end
  local find=surface.find_entities_filtered
  local per_tick,wholes,extra=0,0,{}
  -- (the walk's finds: every type it asks for, inside the band's area)
  surface.find_entities_filtered=function(f)
    per_tick=per_tick+1
    if f.position then return find(f) end
    if not f.area then wholes=wholes+1 end
    local types={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
    local out={}
    for _,list in ipairs({entities,ugs,belts,extra}) do
      for _,e in ipairs(list) do
        local q,a=e.position,f.area
        if types[e.type] and (not a or (q.x>=a[1][1] and q.x<=a[2][1] and q.y>=a[1][2] and q.y<=a[2][2])) then out[#out+1]=e end
      end
    end
    return out
  end
  local function surveyed(list)
    local out={}
    for _,w in ipairs(list) do if not w:find('^inventory') and not w:find('^hoarding') then out[#out+1]=w end end  -- per call
    return table.concat(out,' | ')
  end
  local function pass()
    local ticks,worst=0,0
    repeat
      game.tick=game.tick+1; per_tick=0; S.tick(game.tick); ticks=ticks+1
      worst=math.max(worst,per_tick)
    until (ticks>1 and not (storage.survey_jobs or {})['player/1']) or ticks>3000
    assert(ticks<3000,'the job ends')
    assert(worst<=2,'at most the step\'s find and a belt end check a tick: '..worst)
    return ticks
  end
  game.tick=game.tick+1800
  pass()
  local entry=storage.survey_cache['player/1']
  eq(entry.tick,301801,'the job\'s start, 30 s on')
  eq(wholes,1,'no box known yet: one whole-surface find')
  per_tick=0
  game.tick=game.tick+300
  local later=S.summary(p)
  eq(per_tick,0,'the status reads the last survey')
  eq(later.as_of,301801)
  eq(surveyed(later.warnings),surveyed(at_once.warnings),'the same summary')
  for name,line in pairs(at_once.machines) do eq(later.machines[name],line) end
  eq(later.factory.belt_ends,at_once.factory.belt_ends)
  -- The next survey: bands of chunks only, the same summary.
  wholes=0; game.tick=game.tick+1800
  pass()
  eq(wholes,0,'bands only once the box is known')
  later=S.summary(p)
  eq(surveyed(later.warnings),surveyed(at_once.warnings),'the same summary from bands')
  for name,line in pairs(at_once.machines) do eq(later.machines[name],line) end
  -- A step that fails ends its job, noted in survey_errors; the last survey is kept and the next job waits 30 s.
  extra[1]={valid=true,type='ammo-turret',name='gun-turret',position={x=0,y=0},status=0,get_inventory=function() error('broken turret') end}
  game.tick=game.tick+1800
  local kept=storage.survey_cache['player/1']
  local kept_tick=kept.tick
  for _=1,3000 do game.tick=game.tick+1; S.tick(game.tick); if storage.survey_errors then break end end
  eq(storage.survey_errors.count,1); assert(storage.survey_errors.last:find('broken turret',1,true),storage.survey_errors.last)
  eq(storage.survey_jobs['player/1'],nil); eq(storage.survey_cache['player/1'],kept,'the last survey is kept')
  -- (d20 batch55 P1, viewer Aurora) the survey keeps the tick it was taken at; the reply says its age and the failure.
  local failed_at=storage.survey_errors.tick
  eq(kept.tick,kept_tick,'the tick it was taken at, not the failure\'s'); eq(kept.refresh_failed.tick,failed_at)
  game.tick=failed_at+600
  local told=S.summary(p)
  eq(told.as_of,kept_tick); eq(told.age_s,math.floor((game.tick-kept_tick)/60))
  eq(told.refresh_failed,string.format('the last refresh of the factory survey failed 10s ago (%s); the factory survey is from %ds ago',
    kept.refresh_failed.error,told.age_s))
  assert(kept.refresh_failed.error:find('broken turret',1,true))
  -- The next job waits BG_TICKS after the failure (not after the survey's own tick, long past).
  for _=1,1199 do game.tick=game.tick+1; S.tick(game.tick) end
  eq(storage.survey_jobs['player/1'],nil,'no job within 30 s of the failure')
  extra[1]=nil
  game.tick=game.tick+1; S.tick(game.tick)
  assert(storage.survey_jobs['player/1'],'a job 30 s after the failure')
  -- A slow job finishing after a forced read (machines=true) never replaces it.
  local job=storage.survey_jobs['player/1']
  game.tick=game.tick+5
  local forced=S.summary(p,true)
  local newer=storage.survey_cache['player/1']
  eq(newer.tick,game.tick,'the forced read is now'); eq(forced.as_of,nil); eq(forced.refresh_failed,nil,'a new read carries no failure')
  for _=1,3000 do game.tick=game.tick+1; S.tick(game.tick); if not storage.survey_jobs['player/1'] then break end end
  eq(storage.survey_jobs['player/1'],nil,'the job ended')
  assert(job.start<newer.tick)
  eq(storage.survey_cache['player/1'],newer,'the job\'s older survey was dropped')
  -- Without a newer read, a job's survey replaces the cache as before.
  game.tick=newer.tick+1800
  game.tick=game.tick+1; S.tick(game.tick)
  assert(storage.survey_jobs['player/1'],'the next job')
  for _=1,3000 do game.tick=game.tick+1; S.tick(game.tick); if not storage.survey_jobs['player/1'] then break end end
  assert(storage.survey_cache['player/1'].tick>newer.tick,'the next job\'s survey replaced it')
  surface.find_entities_filtered=find
  game.forces=nil
end
-- With the runtime's research rate (research.lua, sampled every 10 s), the ETA is the last minute's rate and says so;
-- a fallback to a longer window says the last minute had none (Grok 03:20: a starved window said 2 hours, the
-- finish came in under 40 minutes). 300 units x 30 = 9000 work; half done, 4500 left at 2.5 per tick = 1800 ticks.
local rate={2.5,3600,nil}
local S2=dofile('mod/agent-harness_0.1.0/survey.lua'){state=function() return {} end,status_name=function(e) return status_names[e.status] end,
  research_rate=function(name) eq(name,'player'); return rate[1],rate[2],rate[3] end}
tech.research_unit_count=300; tech.research_unit_energy=30
force.research_progress=0.5; force.research_queue={tech}
game.tick=300000
eq(S2.summary(p).factory.research,'automation 50% eta 30s (rate of the last 1m) (queue ends)')
rate={1,7200,true}; game.tick=300600
eq(S2.summary(p).factory.research,'automation 50% eta 1m15s (rate of the last 2m: none in the last 1m) (queue ends)')
-- No rate measured yet (under 30 s of samples): no ETA.
rate={nil}; game.tick=301200
eq(S2.summary(p).factory.research,'automation 50% (queue ends)')
local cached=storage.survey_cache['player/1']
assert(cached.digest and cached.digest.tick==cached.tick,'the digest\'s tick is the survey\'s')
eq(cached.digest.machines.lab.type,'lab')
assert(cached.digest.fuel.boiler.empty>0 and cached.digest.fuel.boiler.low>0)
-- (d22 batch110 BT1: the job's garbage) a machine with no burner counts under its engine status name, as
-- api.status_name gives it (runtime machine_status), and a burner one under api.status_name's (burnt.lua's state); the
-- job reads its force and surface from a cache of the objects, re-read once one is no longer valid; the band filter it
-- hands walk.band holds force and type only, whatever a walk did to it.
do
  local st4={}
  local calls,filters={},{}
  local fake_walk={every=function() return 1 end,due=function() return true end,
    start=function() return {n=0} end,
    band=function(w,s,f)
      local keys={}
      for k in pairs(f) do keys[#keys+1]=k end
      table.sort(keys); filters[#filters+1]=table.concat(keys,',')
      f.area={{0,0},{32,32}}  -- a walk that leaves its area in the filter
      w.n=w.n+1
      if w.n>1 then return nil end
      return s.find_entities_filtered{force=f.force,type=f.type}
    end}
  local S4=dofile('mod/agent-harness_0.1.0/survey.lua'){state=function() return st4 end,walk=fake_walk,
    status_name=function(e) calls[#calls+1]=e.name; return e.burner and 'burnt_result_full' or 'wrong' end}
  local f4={name='player',valid=true,current_research=nil,research_queue={},research_progress=0,get_item_production_statistics=function() return stats end}
  local s4={index=4,valid=true,name='nauvis'}
  local list={machine('assembling-machine-2','assembling-machine','item_ingredient_shortage',1,{electric_buffer_size=100}),
    machine('stone-furnace','furnace','working',2,{burner={inventory=fuel_inv({coal}),remaining_burning_fuel=10}}),
    machine('fast-inserter','inserter','working',3,{electric_buffer_size=100})}
  s4.find_entities_filtered=function(f) if f.position then return {} end return list end
  local force_reads,surface_reads=0,0
  game.forces=setmetatable({},{__index=function(_,name) force_reads=force_reads+1; return name=='player' and f4 or nil end})
  game.get_surface=function(i) surface_reads=surface_reads+1; return i==4 and s4 or nil end
  game.tick=500000
  st4.survey_cache={['player/4']={tick=0,warnings={},machines={}}}
  st4.survey_read={['player/4']=game.tick}
  for _=1,6 do game.tick=game.tick+1; S4.tick(game.tick) end
  eq(st4.survey_jobs['player/4'],nil,'the job ended')
  local entry=st4.survey_cache['player/4']
  eq(entry.tick,500001,'the job made a survey')
  eq(entry.machines['assembling-machine-2'],'0/1 working, 1 item_ingredient_shortage')
  eq(entry.machines['stone-furnace'],'0/1 working, 1 burnt_result_full')
  eq(table.concat(calls,','),'stone-furnace','api.status_name for the burner machine only')
  eq(table.concat(filters,' | '),'force,type | force,type')
  eq(force_reads,1); eq(surface_reads,1)
  -- A force or surface no longer valid is read again (and a step with neither ends its job, as before).
  st4.survey_cache['player/4'].tick=0; st4.survey_read['player/4']=game.tick
  f4.valid=false
  local f5={}; for k,v in pairs(f4) do f5[k]=v end; f5.valid=true
  game.forces=setmetatable({},{__index=function(_,name) force_reads=force_reads+1; return name=='player' and f5 or nil end})
  s4.valid=false
  local s5={}; for k,v in pairs(s4) do s5[k]=v end; s5.valid=true
  game.get_surface=function(i) surface_reads=surface_reads+1; return i==4 and s5 or nil end
  for _=1,6 do game.tick=game.tick+1; S4.tick(game.tick) end
  eq(force_reads,2); eq(surface_reads,2)
  eq(st4.survey_cache['player/4'].tick,500007,'the second job made its survey')
  game.forces=nil; game.get_surface=nil
end
-- (BT1) with runtime's api (status_name is machine_status over burnt.lua, burnt_stuck is burnt.stuck), each machine
-- counts under the status machine_status gives it, burnt.stuck read once a burner: stopped by a full burnt-result
-- slot, by unusable fuel, burning, no burner.
do
  local B=dofile('mod/agent-harness_0.1.0/burnt.lua'){}
  local function machine_status(e)
    local ok,f=pcall(B.stuck,e)
    if ok and f then return f.unusable and B.UNUSABLE or B.STATE end
    return status_names[e.status]
  end
  local ITEM={spoilage={stack_size=200,fuel_category='chemical',get_spoil_ticks=function() return 0 end},
    nutrients={stack_size=50,fuel_category='nutrients',get_spoil_ticks=function() return 0 end}}
  local function st(name,count) return {valid_for_read=true,name=name,count=count,quality={name='normal'},prototype=ITEM[name],spoil_tick=0} end
  local function inv(list) return setmetatable({is_empty=function() return #list==0 end},{__len=function() return #list end,__index=function(_,i) return list[i] end}) end
  local function chamber(x,fuel,burnt,remaining)
    return machine('biochamber','assembling-machine','working',x,{burner={inventory=inv(fuel),burnt_result_inventory=inv(burnt),
      remaining_burning_fuel=remaining,fuel_categories={nutrients=true}}})
  end
  local list={chamber(1,{st('spoilage',3)},{st('spoilage',200)},0),        -- full slot, nothing burning
    chamber(2,{st('spoilage',3)},{},0),                                     -- only fuel it does not burn
    chamber(3,{st('nutrients',4)},{st('spoilage',200)},1000),               -- full but burning
    chamber(4,{st('nutrients',4)},{},0),                                    -- fine
    machine('assembling-machine-2','assembling-machine','item_ingredient_shortage',5,{electric_buffer_size=100})}
  local stucks=0
  local S6=dofile('mod/agent-harness_0.1.0/survey.lua'){state=function() return {} end,status_name=machine_status,
    burnt_stuck=function(e) stucks=stucks+1; return B.stuck(e) end}
  local a={}
  for _,e in ipairs(list) do local s=machine_status(e); a[e.name]=a[e.name] or {}; a[e.name][s]=(a[e.name][s] or 0)+1 end
  eq(a.biochamber.burnt_result_full,1); eq(a.biochamber.fuel_unusable,1); eq(a.biochamber.working,2)
  local s6={index=6,find_entities_filtered=function(f) if type(f.type)=='table' then return list end return {} end}
  local r=S6.summary({index=1,force=force,surface=s6,get_main_inventory=function() return main end},true)
  eq(r.machines.biochamber,'2/4 working, 1 burnt_result_full, 1 fuel_unusable')
  eq(r.machines['assembling-machine-2'],'0/1 working, 1 item_ingredient_shortage')
  eq(stucks,4,'burnt.stuck once a burner')
end
-- (BT1) a walk that hands back the positions its band read (walk.band's out_pos): the slice reads no position of its
-- own and gives the same survey as a walk without them.
do
  local reads=0
  local function moved(e) local p=e.position; e.position=nil; return setmetatable(e,{__index=function(_,k) if k=='position' then reads=reads+1; return {x=p.x,y=p.y} end end}) end
  local list={moved(machine('assembling-machine-2','assembling-machine','item_ingredient_shortage',1,{electric_buffer_size=100})),
    moved(machine('assembling-machine-2','assembling-machine','low_power',2,{electric_buffer_size=100})),
    moved(machine('gun-turret','ammo-turret','working',3,{get_inventory=function() return {get_item_count=function() return 0 end} end})),
    moved(machine('transport-belt','transport-belt','working',4,{direction=4,belt_neighbours={outputs={}}}))}
  local function run(with_pos)
    local st7={}
    local w7={every=function() return 1 end,due=function() return true end,start=function() return {n=0} end,
      band=function(w,s,f,out_pos)
        w.n=w.n+1
        if w.n>1 then return nil end
        local found={}
        for i,e in ipairs(list) do found[i]=e; if with_pos and out_pos then out_pos[i]={x=i,y=0} end end  -- (each one's x is its index)
        if with_pos then return found,out_pos end
        return found
      end}
    local S7=dofile('mod/agent-harness_0.1.0/survey.lua'){state=function() return st7 end,walk=w7,status_name=function(e) return status_names[e.status] end}
    local f7={name='player',valid=true,research_queue={},research_progress=0,get_item_production_statistics=function() return stats end}
    local s7={index=7,valid=true,name='nauvis',find_entities_filtered=function() return {} end}
    game.forces={player=f7}; game.get_surface=function() return s7 end
    st7.survey_cache={['player/7']={tick=0,warnings={},machines={}}}; st7.survey_read={['player/7']=game.tick}
    for _=1,6 do game.tick=game.tick+1; S7.tick(game.tick) end
    game.forces=nil; game.get_surface=nil
    local entry=st7.survey_cache['player/7']
    assert(entry.tick>0,'the job made a survey')
    return entry
  end
  reads=0
  local plain=run(false)
  assert(reads>=4,'without the band\'s positions the slice reads them: '..reads)
  reads=0
  local fast=run(true)
  eq(reads,0)
  eq(table.concat(fast.warnings,' | '),table.concat(plain.warnings,' | '))
  for name,line in pairs(plain.machines) do eq(fast.machines[name],line) end
  eq(fast.positions['assembling-machine-2'].low_power[1].x,2)
  eq(fast.factory.belt_ends,plain.factory.belt_ends)
end
print('survey: ok')
