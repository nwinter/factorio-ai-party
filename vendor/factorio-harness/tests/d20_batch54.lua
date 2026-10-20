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
