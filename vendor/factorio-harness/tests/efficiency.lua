-- Run with lua tests/efficiency.lua: production credited to the agent who built the machine (efficiency.lua; Nick
-- 15:50, viewers Enginerd and Foobator). The build log (by unit and by spot; a ghost's planner for robot builds and
-- revives), a crafting machine's crafts times its recipe's items, drill and lab estimates, machines built before the
-- count and the operator seed, the shift's numbers against hand hauling, and the walk: a block every other tick.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
function table_size(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
defines={entity_status={working=1,no_power=2}}
local box3={left_top={x=-1.5,y=-1.5},right_bottom={x=1.5,y=1.5}}
prototypes={
  entity={['assembling-machine-2']={type='assembling-machine',collision_box=box3},['stone-furnace']={type='furnace',collision_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}},
    ['electric-mining-drill']={type='mining-drill',collision_box=box3,mining_speed=0.5},lab={type='lab',collision_box=box3,get_researching_speed=function() return 1 end},
    ['transport-belt']={type='transport-belt'}},
  recipe={['copper-cable']={products={{type='item',name='copper-cable',amount=2}}},['iron-plate']={products={{type='item',name='iron-plate',amount=1}}},
    ['iron-gear-wheel']={products={{type='item',name='iron-gear-wheel',amount=1}}}}}
local force={name='player'}
force.current_research={research_unit_energy=1800}   -- 30 s a unit
force.laboratory_speed_modifier=0
game={tick=1000,surfaces={},forces={player=force}}
local queries=0
local function surface(name,platform)
  local s={name=name,entities={},platform=platform,planet=not platform and {name=name} or nil}
  s.find_entities_filtered=function(f)
    queries=queries+1
    assert(f.area and f.force==force and f.type,'by area, type and force')
    local out={}
    for _,e in ipairs(s.entities) do
      if e.valid and e.position.x>=f.area.left_top.x and e.position.x<f.area.right_bottom.x and e.position.y>=f.area.left_top.y and e.position.y<f.area.right_bottom.y then out[#out+1]=e end
    end
    return out
  end
  s.count_entities_filtered=function() error('no count over a surface') end
  game.surfaces[name]=s
  return s
end
local nauvis=surface('nauvis')
game.get_surface=function(n) return game.surfaces[n] end
local units=0
local function machine(s,name,x,y,f)
  units=units+1
  local e={valid=true,name=name,type=prototypes.entity[name].type,position={x=x,y=y},surface=s,force=force,unit_number=units,
    prototype=prototypes.entity[name],status=defines.entity_status.working,products_finished=0}
  for k,v in pairs(f or {}) do e[k]=v end
  s.entities[#s.entities+1]=e
  return e
end
local storage_={shift={seq=1,tick=500}}
local hand={astra=100,sol=0}
local E=dofile('mod/agent-harness_0.1.0/efficiency.lua'){state=function() return storage_ end,force=function() return force end,
  agent_names=function() return {'astra','sol'} end,hand_items=function(n) return hand[n] end}
local function run(ticks) for _=1,ticks do game.tick=game.tick+1; E.tick(game.tick) end end
local function pass() local p=storage_.efficiency and storage_.efficiency.walk.pass or 1; for _=1,5000 do run(1); if storage_.efficiency.walk.pass>p then return end end; error('no pass end') end
local function agent(r,name) for _,a in ipairs(r.agents) do if a.name==name then return a end end end

-- 1. Before the log: a furnace with 900 plates made is "built before the count"; it counts for the lifetime, not
-- the shift.
local furnace=machine(nauvis,'stone-furnace',4,4,{products_finished=900,get_recipe=function() return nil end,previous_recipe={name='iron-plate'}})
-- 2. Built by hand by astra (the log, by unit): an assembler making copper cable, 2 a craft.
local asm=machine(nauvis,'assembling-machine-2',20.5,20.5,{products_finished=10,get_recipe=function() return {name='copper-cable'} end})
E.built('astra',asm)
-- 3. A ghost sol placed (by spot); robots build it later: sol's.
local ghost={valid=true,type='entity-ghost',ghost_name='assembling-machine-2',position={x=40.5,y=40.5},surface=nauvis}
E.built('sol',ghost)
local robot=machine(nauvis,'assembling-machine-2',40.5,40.5,{products_finished=0,get_recipe=function() return {name='iron-gear-wheel'} end})
-- 4. A ghost sol placed and luna revived by hand (construct): still sol's.
local g2={valid=true,type='entity-ghost',ghost_name='assembling-machine-2',position={x=60.5,y=40.5},surface=nauvis}
E.built('sol',g2)
local revived=machine(nauvis,'assembling-machine-2',60.5,40.5,{products_finished=0,get_recipe=function() return {name='iron-gear-wheel'} end})
E.built('luna',revived,true)
-- 5. A drill and a lab astra built: estimates from the time working.
local ore={prototype={mineable_properties={mining_time=1,products={{type='item',name='iron-ore'}}}}}
local drill=machine(nauvis,'electric-mining-drill',100.5,100.5,{mining_target=ore,speed_bonus=0,productivity_bonus=0})
E.built('astra',drill)
local lab=machine(nauvis,'lab',120.5,100.5,{speed_bonus=0})
E.built('astra',lab)
-- A belt is no machine: not logged.
E.built('astra',{valid=true,type='transport-belt',name='transport-belt',position={x=1,y=1},surface=nauvis})

queries=0
local start=game.tick
pass()
local ticks=game.tick-start
-- the walk: one block query every other tick, at most once a tick (8 blocks each way: 17 x 17 = 289 blocks)
assert(queries<=math.ceil(ticks/2)+2,'at most one block every other tick: '..queries..' in '..ticks)
eq(queries,289,'17 x 17 blocks of 128 tiles')
local r=E.read()
local a,s,b=agent(r,'astra'),agent(r,'sol'),agent(r,E.BEFORE)
eq(b.items,900); eq(b.items_shift,0,'before the count: lifetime only'); eq(b.machines,1)
eq(a.items,20); eq(a.items_shift,20,'built this shift: 10 crafts x 2 cables'); eq(a.crafts,10); eq(a.machines,3); eq(a.running,3)
eq(a.top_items[1].item,'copper-cable'); eq(a.built_logged,3)
eq(s.machines,2,'the robot build and the revived ghost are sol\'s'); eq(agent(r,'luna'),nil,'luna revived it: not hers')
eq(r.team.machines,6); eq(r.team.running,6)

-- 6. Crafts since the last visit; the drill and lab estimates over the time between visits.
asm.products_finished=60       -- 50 more crafts: 100 cables
robot.products_finished=30
furnace.products_finished=1000 -- 100 more plates, before the count's
local t0=game.tick
pass()
local secs=(game.tick-t0)/60
r=E.read(); a,s,b=agent(r,'astra'),agent(r,'sol'),agent(r,E.BEFORE)
eq(a.items,120); eq(a.items_shift,120); eq(s.items,30); eq(s.items_shift,30)
eq(b.items,1000); eq(b.items_shift,100,'later crafts count for the shift')
-- drill: 0.5 mining speed on a 1 s resource: 0.5 ore a second; lab: 1 unit per 30 s
assert(math.abs(a.ore_about-math.floor(secs*0.5+0.5))<=1,'drill estimate '..a.ore_about..' over '..secs..' s')
assert(math.abs(a.lab_units_about-math.floor(secs/30+0.5))<=1,'lab estimate '..a.lab_units_about)
-- 7. A machine that stops working: not running; no estimate while it is not working.
drill.status=defines.entity_status.no_power
pass()
r=E.read(); a=agent(r,'astra')
eq(a.running,2,'the drill stopped')
local ore_then=a.ore_about
pass()
eq(agent(E.read(),'astra').ore_about,ore_then,'no estimate while not working')

-- 8. Hand hauling this shift against machine items: astra 100 hand items at the shift start, 150 now.
hand.astra=150
r=E.read(); a=agent(r,'astra')
eq(a.hand_items_shift,50); eq(a.machine_share_pct,math.floor(100*120/170+0.5))
eq(E.review_line('astra'),'machines you built made 120 items this shift (3 of your machines, 2 running); 71% of your items this shift moved by machines')
eq(E.review_line('nobody'),nil)

-- 9. The operator seed names the furnace's builder (from the journals): its credit moves to them on the next visit.
local out=E.seed({rows={{unit=furnace.unit_number,by='opus',tick=100},{name='stone-furnace',x=300,y=300,by='opus',tick=100},
  {name='transport-belt',x=1,y=1,by='opus',tick=100}}})
eq(out.units,1); eq(out.spots,1,'belts are no machines')
pass()
r=E.read()
eq(agent(r,'opus').items,1000); eq(agent(r,E.BEFORE).items,0)
fails(function() E.seed({}) end,'rows: 1..2000 seed rows')
fails(function() E.seed({rows={{by='x'}}}) end,'row 1: by and tick')
-- a seed by spot with no surface: a machine built there later (a new unit) is theirs, found anywhere on its footprint
local seeded=machine(nauvis,'stone-furnace',300.5,300.5,{products_finished=4,get_recipe=function() return {name='iron-plate'} end})
pass(); pass()
eq(agent(E.read(),'opus').machines,2,'the spot seed matched (300,300)')
-- a machine in the outermost ring (block 8 of 8): the square grows by 2 blocks for the next pass
machine(nauvis,'stone-furnace',1100.5,0.5,{get_recipe=function() return {name='iron-plate'} end})
pass()
eq(storage_.efficiency.walk.extent.nauvis,10)

-- 10. A new shift: the shift numbers start over; a machine rebuilt by someone else is theirs.
storage_.shift={seq=2,tick=game.tick}
asm.valid=false
local rebuilt=machine(nauvis,'assembling-machine-2',20.5,20.5,{products_finished=0,get_recipe=function() return {name='copper-cable'} end})
E.built('sol',rebuilt)
rebuilt.products_finished=5
pass()
r=E.read(); a,s=agent(r,'astra'),agent(r,'sol')
eq(a.items_shift,0,'new shift'); eq(a.items,120,'lifetime kept'); eq(a.machines,2,'its assembler is gone')
eq(s.items_shift,10,'5 crafts of the rebuilt assembler: sol\'s'); eq(r.shift.seq,2)
eq(r.walk.surfaces[1],'nauvis')

-- 11. A platform surface is walked too, over a smaller square.
local plat=surface('platform-1',{force=force})
local crusher=machine(plat,'assembling-machine-2',2.5,-3.5,{products_finished=7,get_recipe=function() return {name='iron-gear-wheel'} end})
E.built('astra',crusher)
pass(); pass()
r=E.read()
eq(r.walk.extent['platform-1'],2); eq(agent(r,'astra').machines,3)
print('efficiency ok')
