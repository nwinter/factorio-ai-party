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
for i,n in ipairs{0,3,20} do
  entities[#entities+1]=machine('gun-turret','ammo-turret','working',10+i,{get_inventory=function() return {get_item_count=function() return n end} end})
end
-- Flamers: one dry, one at 10% (low), one full.
for i,n in ipairs{0,20,200} do
  entities[#entities+1]=machine('flamethrower-turret','fluid-turret','working',20+i,{fluidbox={[1]=n>0 and {amount=n} or nil,get_capacity=function() return 200 end}})
end
-- A full flamer on a long oil line (shift07 15:31): get_capacity is the whole segment's in 2.0 (66700); its own tank
-- is the prototype's volume (100), so 99 is neither dry nor low.
entities[#entities+1]=machine('flamethrower-turret','fluid-turret','working',24,{prototype={fluidbox_prototypes={{volume=100}}},
  fluidbox={[1]={amount=99},get_capacity=function() return 66700 end}})
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
has(s.warnings,'fuel: boiler 1/3 no_fuel, 1 burning their last fuel')
has(s.warnings,'power: 1 of 4 machines low_power (fh call power lists them)')
has(s.warnings,'ammo: gun-turret 1/3 empty at (11,0), 1 below 5 at (12,0); rearm radius=R')
has(s.warnings,'flamer oil: flamethrower-turret 1/4 dry at (21,0), 1 below 25% at (22,0) 10%; fh call flamers')
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
  for _=1,3000 do game.tick=game.tick+1; S.tick(game.tick); if storage.survey_errors then break end end
  eq(storage.survey_errors.count,1); assert(storage.survey_errors.last:find('broken turret',1,true),storage.survey_errors.last)
  eq(storage.survey_jobs['player/1'],nil); eq(storage.survey_cache['player/1'],kept,'the last survey is kept')
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
print('survey: ok')
