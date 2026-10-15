-- Private headless-only regression/benchmark mod control.lua; see report-friction6.md.
-- Copy beside the harness Lua modules in a test mod; requires base + Space Age.
-- Creates only a private platform fixture (4096 pipe segments, 256 labs); runs at tick 60.
local statuses={}
for name,id in pairs(defines.entity_status) do statuses[id]=name end
local supply=require('supply'){
  status_name=function(e) return statuses[e.status] end,
  position=function(v) return v end,integer=function(v,d) return v or d end}
local labs=require('labs'){
  status_name=function(e) return statuses[e.status] end,
  center=function(p,a) return a.position or p.position end,integer=function(v,d) return v or d end}
script.on_init(function()
  local force=game.forces.player
  local platform=assert(force.create_space_platform{name='Friction6 private',planet='nauvis',starter_pack='space-platform-starter-pack'})
  platform.apply_starter_pack()
  local s=platform.surface
  local tiles={}
  for y=-128,127 do for x=-128,127 do tiles[#tiles+1]={name='space-platform-foundation',position={x=x,y=y}} end end
  s.set_tiles(tiles)
  force.chart(s,{{-256,-256},{256,256}})
  for _,tech in pairs(force.technologies) do tech.researched=true end
  local function entity(name,x,y) return assert(s.create_entity{name=name,position={x=x,y=y},force=force}) end
  local pipe=entity('pipe',-100,-100)
  local pipe2=entity('pipe',-99,-100)
  pipe.fluidbox[1]={name='water',amount=150}
  local boiler=entity('boiler',-90,-100)
  local pump=entity('offshore-pump',-80,-100); pump.fluidbox[1]={name='water',amount=100}
  local plant=entity('chemical-plant',-70,-100); plant.set_recipe('lubricant')
  local tank=entity('storage-tank',-60,-100); tank.fluidbox[1]={name='lubricant',amount=1234}
  storage.fixture={pipe=pipe,pipe2=pipe2,boiler=boiler,pump=pump,plant=plant,tank=tank}
  -- A bounded but dense private fixture: independent pipe segments and separated labs.
  for y=0,63 do for x=0,63 do local e=entity('pipe',x*2-64,y*2-64); e.fluidbox[1]={name='water',amount=10} end end
  for y=0,15 do for x=0,15 do entity('lab',x*4-32,y*4+70) end end
  storage.surface=s
end)
script.on_event(defines.events.on_tick,function(event)
  if event.tick~=60 then return end
  local s,force,f=storage.surface,game.forces.player,storage.fixture
  force.chart(s,{{-256,-256},{256,256}})
  local function profile(label,fn)
    local p=game.create_profiler(); local r=fn(); p.stop(); log({'','FRICTION6 ',label,' ',p}); return r
  end
  local area={position={x=-99,y=-100},radius=2}
  local one=supply.fluid_supply(s,force,'water',area)
  assert(one.segments_count==1 and one.stored==150,helpers.table_to_json(one))
  assert(f.plant.insert_fluid{name='lubricant',amount=100}==100)
  local oil=supply.fluid_supply(s,force,'lubricant',{position={x=-65,y=-100},radius=12})
  assert(oil.stored==1334 and oil.makers.count==1,helpers.table_to_json(oil))
  local water=supply.fluid_supply(s,force,'water',{position={x=-85,y=-100},radius=8})
  assert(water.users.count==1 and water.makers.count==1,helpers.table_to_json(water))
  for i=1,5 do
    local r=profile('fluid full '..i,function() return supply.fluid_supply(s,force,'water') end)
    assert(r.counted.limited and r.counted.found==2048,helpers.table_to_json(r))
    profile('fluid local '..i,function() return supply.fluid_supply(s,force,'water',area) end)
    profile('labs surface '..i,function() return labs.view({surface=game.surfaces.nauvis,force=force,position={x=999,y=999}},{surface=s.name}) end)
  end
  log('FRICTION6 PASS fluid segments, fluid roles, bounded scans, remote labs')
end)
