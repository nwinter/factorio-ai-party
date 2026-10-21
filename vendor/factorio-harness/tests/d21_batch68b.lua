-- Run from repository root: lua tests/d21_batch68b.lua
-- d21 batch68 AD3 (viewer Aurora 13:03: "Could maps show logistic/power network IDs and coverage, plus a selected item's
-- source-to-consumer blockers?"). netmap.lua: per planet, from the census's lists, its electric networks (letters by
-- poles, a grid of their supply areas, run-length packed), its logistic networks (roboports and radii, robots) and each
-- item's sources and consumers by kind and logistic network, in steps; census.lua keeps our poles.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={chest=1,crafter_trash=8,lab_trash=8,cargo_landing_pad_main=1}}
local function inv(list) return {get_contents=function() return list end} end
local function pole(x,y,id,d) return {valid=true,type='electric-pole',name='pole'..d,position={x=x,y=y},electric_network_id=id,quality={name='normal'},
  prototype={get_supply_area_distance=function() return d end}} end
local net243={network_id=243,all_logistic_robots=40,available_logistic_robots=5,all_construction_robots=10,available_construction_robots=10}
local function covered(p) return p.x<100 and net243 or nil end
local function port(x,y,lr,cr) return {valid=true,type='roboport',name='roboport',position={x=x,y=y},logistic_cell={logistic_network=net243,logistic_radius=lr,construction_radius=cr}} end
prototypes={entity={
  ['assembling-machine-2']={electric_energy_source_prototype={}},['electric-furnace']={electric_energy_source_prototype={}},
  ['electric-mining-drill']={electric_energy_source_prototype={}},lab={electric_energy_source_prototype={},lab_inputs={'automation-science-pack','logistic-science-pack'}},
  ['requester-chest']={logistic_mode='requester'},['storage-chest']={logistic_mode='storage'},['iron-chest']={},
  ['iron-ore']={mineable_properties={products={{type='item',name='iron-ore',amount=1}}}}},
  recipe={['iron-plate']={products={{type='item',name='iron-plate',amount=1}},ingredients={{type='item',name='iron-ore',amount=1}}}}}
local function ent(t,name,x,y,o) o=o or {}; o.valid=true; o.type=t; o.name=name; o.position={x=x,y=y}; return o end
local items={
  ent('assembling-machine','assembling-machine-2',10.5,10.5,{electric_network_id=7,get_recipe=function() return {products={{type='item',name='iron-gear-wheel',amount=1}},
    ingredients={{type='item',name='iron-plate',amount=2},{type='fluid',name='water',amount=10}}} end,
    get_inventory=function(i) return i==8 and inv({{name='spoilage',count=3}}) or nil end}),
  ent('furnace','electric-furnace',20.5,10.5,{electric_network_id=7,get_recipe=function() return nil end,previous_recipe={name='iron-plate'}}),
  ent('mining-drill','electric-mining-drill',150.5,10.5,{electric_network_id=nil,mining_target={name='iron-ore'}}),
  ent('logistic-container','requester-chest',150.5,20.5,{logistic_network=nil,get_requester_point=function() return {filters={{name='iron-gear-wheel',count=50},{name='coal',count=0}}} end}),
  ent('logistic-container','storage-chest',12.5,12.5,{logistic_network=net243,get_inventory=function() return inv({{name='iron-plate',count=60,quality='normal'},{name='iron-plate',count=40,quality='rare'}}) end}),
  ent('lab','lab',30.5,30.5,{electric_network_id=nil}),
  ent('cargo-landing-pad','cargo-landing-pad',40,40,{get_inventory=function() return inv({{name='tungsten-carbide',count=25}}) end}),
  ent('logistic-container','iron-chest',1,1,{}),
}
local nauvis={index=1,name='nauvis',planet={},find_logistic_network_by_position=function(p) return covered(p) end}
local platform={index=2,name='platform-1'}
game={tick=600,surfaces={nauvis=nauvis,['platform-1']=platform},forces={player={name='player',current_research={name='automation',research_unit_ingredients={{type='item',name='automation-science-pack',amount=1}}}}}}
game.get_surface=function(k) return (k==1 or k=='nauvis') and nauvis or (k==2 or k=='platform-1') and platform or nil end
local poles={pole(0.5,0.5,7,3.5),pole(6.5,0.5,7,3.5),pole(12.5,0.5,7,3.5),pole(2.5,2.5,9,2.5),pole(30.5,30.5,11,0)}
local census_ready=false
local st={}
local N=dofile('mod/agent-harness_0.1.0/netmap.lua'){state=function() return st end,
  poles=function(f,s) if not census_ready then return nil end return poles,500,false end,
  typed=function(f,s,t) if t=='roboport' then return {port(10,10,25,55),port(60,10,25,55),port(90,10,30,60)},500 end return items,500 end}
-- no census pass with poles yet: the planet is tried again a PERIOD on
N.tick(600); N.tick(603)
eq(st.netmap.job,nil,'nothing to read yet'); eq(st.netmap.tried.nauvis,603)
N.tick(603+N.PERIOD-3); eq(st.netmap.job,nil,'not before PERIOD')
census_ready=true
local t=603+N.PERIOD
for i=1,200 do N.tick(t); t=t+N.EVERY; if st.netmap.done.nauvis then break end end
local m=st.netmap.done.nauvis
assert(m,'a map made in steps'); eq(st.netmap.done['platform-1'],nil,'planets only')
eq(m.census,500)
local e=m.electric
eq(e.nets,'7,A,3;9,B,1;11,C,1','most poles first'); eq(e.poles,5); eq(e.cell,1,'the middle of the poles within EMAX cells at 1 tile')
eq(e.x0,-3); eq(e.y0,-3); eq(e.rle,1)
-- row y=-3: x -3..16 is pole 7's three areas (each 7 wide, touching): 19 A; row y=0 has network 9's area (x 0..4) under 7's
eq(e.rows[1],'19A','supply areas, the bigger network where two cover a cell'); eq(e.rows[4],'19A')
eq(#e.rows,8,'down to the lowest supply edge (y 4); the wire-only pole supplies nothing')
-- logistic: one network, the radius other than the first kept by roboport
eq(#m.logistic,1); local l=m.logistic[1]
eq(l.id,243); eq(l.lr,25); eq(l.cr,55); eq(l.n,3); eq(l.ports,'10,10;60,10'); eq(l.odd,'90,10,30,60'); eq(l.robots,'40,5,10,10')
-- items
local by={} for _,row in ipairs(m.items) do by[row[1]]={row[2],row[3]} end
eq(by['iron-gear-wheel'][1],'A,243,1,0,0,10,10','a crafter making it, in the network at its spot')
eq(by['iron-gear-wheel'][2],'Q,0,1,50,0,150,20','a requester asking for it, in no network')
eq(by['iron-plate'][1],'A,243,1,0,0,20,10;S,243,1,100,0,12,12','a furnace\'s last recipe; a storage chest\'s count over qualities')
eq(by['iron-plate'][2],'A,243,1,0,0,10,10'); eq(by['water'],nil,'fluids left out'); eq(by['coal'],nil,'a request of 0 left out')
eq(by['iron-ore'][1],'M,0,1,0,1,150,10','a drill outside every network, on no electric network'); eq(by['iron-ore'][2],'A,243,1,0,0,20,10')
eq(by['automation-science-pack'][2],'R,243,1,0,1,30,30','a lab: the packs the research takes'); eq(by['logistic-science-pack'],nil)
eq(by['spoilage'][1],'T,243,1,3,0,10,10','a machine\'s trash slots'); eq(by['tungsten-carbide'][1],'L,243,1,25,0,40,40','a landing pad, the network at its spot')
eq(m.research,'automation')
-- the read: the listing, and the map asked for
local r=N.read({}); eq(#r.surfaces,1); eq(r.surfaces[1].surface,'nauvis'); eq(r.map,nil)
eq(N.read({surface='nauvis'}).map,m)
-- a group of many: its box and first positions
st.netmap.done={}; st.netmap.tried={}
for i=1,3 do items[#items+1]=ent('logistic-container','storage-chest',50.5+i*2,60.5,{logistic_network=net243,get_inventory=function() return inv({{name='stone',count=10}}) end}) end
-- a far pole: the grid keeps MAX_CELLS cells round the median and counts the pole beyond
poles[#poles+1]=pole(5000.5,0.5,7,3.5)
for i=1,24 do poles[#poles+1]=pole(i,3.5,7,3.5) end  -- (the far one outside the middle 90%)
N.MAX_CELLS=40
for i=1,200 do N.tick(t); t=t+N.EVERY; if st.netmap.done.nauvis then break end end
m=st.netmap.done.nauvis
by={} for _,row in ipairs(m.items) do by[row[1]]={row[2],row[3]} end
eq(by.stone[1],'S,243,3,30,0,52,60,56,60,52,60,54,60,56,60','count, amount, box and positions')
eq(m.electric.outside,1,'the far pole beyond the grid'); eq(m.electric.cell,1); eq(m.electric.w<=40,true)
-- census keeps our poles for it
local cst={census={done={start=7,walked={[1]=true},poles={[1]={{valid=true},{valid=false}}}}}}
local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return cst end,walk={}}
local list,as_of,capped=C.poles(game.forces.player,nauvis)
eq(#list,1,'valid ones'); eq(as_of,7); eq(capped,false)
eq(C.poles(game.forces.player,platform),nil,'a surface the pass did not walk')
print('d21_batch68b AD3 net map: ok')
