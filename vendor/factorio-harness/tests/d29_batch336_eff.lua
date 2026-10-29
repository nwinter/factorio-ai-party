-- Run from repository root: lua tests/d29_batch336_eff.lua (d29 batch336 FL5: the crafts counter anchors efficiency.lua keeps for rates producers; mocks as tests/efficiency.lua)
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
local asm=machine(nauvis,'assembling-machine-2',20.5,20.5,{products_finished=10,get_recipe=function() return {name='copper-cable'} end})
pass()
local m=storage_.efficiency.machines[asm.unit_number]
eq(m.p0,10); eq(m.t1,nil)
eq(E.counter_then(asm.unit_number,game.tick),nil)            -- under MIN_SPAN: none
local first=m.t0
eq(select(2,E.counter_then(asm.unit_number,first+E.MIN_SPAN)),first)  -- the newer anchor once a minute back
-- past ANCHOR: the newer becomes the older, the counter now the newer
asm.products_finished=70
game.tick=first+E.ANCHOR
pass()
eq(m.p1,10); eq(m.t1,first); eq(m.p0,70)
local pf,t=E.counter_then(asm.unit_number,game.tick); eq(pf,10); eq(t,first)
-- a counter that went back (a rebuilt machine under the same unit) drops the anchors
asm.products_finished=3
pass()
eq(m.t1,nil); eq(m.p0,3)
print('d29_batch336_eff FL5 anchors: ok')
