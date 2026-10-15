-- Run from repository root: lua tests/labs.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),tostring(text)..' lacks '..part) end
defines={inventory={lab_input=2}}
local names={[1]='working',[2]='missing_science_packs',[3]='waiting_for_source_items',[4]='no_power'}
local n=0
local function lab(x,y,status,packs)
  n=n+1
  local e={valid=true,unit_number=n,name='lab',type='lab',position={x=x,y=y},status=status,prototype={researching_speed=1}}
  e.get_inventory=function() return {get_item_count=function(name) return packs[name] or 0 end} end
  return e
end
local function belt(x,y,items)
  n=n+1
  return {valid=true,unit_number=n,name='transport-belt',type='transport-belt',position={x=x,y=y},
    get_max_transport_line_index=function() return 2 end,
    get_transport_line=function(i) return {get_contents=function() return i==1 and items or {} end} end,
    get_item_count=function(name) local c=0 for _,v in ipairs(items) do if v.name==name then c=c+v.count end end return c end}
end
local red,green='automation-science-pack','logistic-science-pack'
-- Group A: three adjacent labs; two lack green; a belt carries only red.
local a1,a2,a3=lab(0,0,1,{[red]=5,[green]=2}),lab(3,0,2,{[red]=5}),lab(6,0,2,{[red]=1})
local feed=belt(0,-3,{{name=red,count=12}})
local function inserter(x,y,status,pickup,drop)
  n=n+1
  return {valid=true,unit_number=n,name='inserter',type='inserter',position={x=x,y=y},status=status,pickup_target=pickup,drop_target=drop,held_stack={valid_for_read=false}}
end
local i1,i2,i3=inserter(0,-2,1,feed,a1),inserter(3,-2,3,feed,a2),inserter(6,-2,3,a2,a3)
-- Group B, far away: one unpowered lab, nothing feeds it.
local b1=lab(60,60,4,{})
local labs={a1,a2,a3,b1}
local surface={find_entities_filtered=function(f)
  if f.type=='lab' then return labs end
  if f.type=='inserter' then return {i1,i2,i3} end
  return {}
end}
local tech={name='logistics',research_unit_ingredients={{name=red,amount=1},{name=green,amount=1}},research_unit_count=100,research_unit_energy=600}
local force={current_research=tech,research_progress=0.25,laboratory_speed_modifier=0}
local p={position={x=0,y=0},surface=surface,force=force}
local L=dofile('mod/agent-harness_0.1.0/labs.lua'){integer=function(v,d) return v or d end,center=function(p) return p.position end,
  status_name=function(e) return names[e.status] end}
local r=L.view(p,{})
-- 75 units left x 10 s each at 1 working lab: 750 s.
eq(r.research,'logistics 25% needs automation+logistic, eta 12m30s at 1 working labs')
eq(r.labs,'4 in 2 groups')
eq(#r.groups,2)
has(r.groups[1],'labs (0,0)-(6,0): 1/3 working, 2 missing_science_packs, lack logistic (2)')
has(r.groups[1],'feeders: 3 inserters (1 lab-to-lab)')
has(r.groups[1],'1 idle: source transport-belt (0,-3) has nothing the lab needs')
has(r.groups[1],'no logistic on their 1 belts/chests')
has(r.groups[1],'sources hold automation 12')
has(r.groups[2],'labs (60,60)-(60,60): 0/1 working, 1 no_power, lack automation (1), logistic (1); feeders: no visible inserters feed these labs')
-- Nothing researching, nothing working.
force.current_research=nil
eq(L.view(p,{}).research,'none: nothing queued')
force.current_research=tech; a1.status=2
has(L.view(p,{}).research,'stalled: no lab is working')

-- science: one pack's flow over the whole surface, the same numbers for everyone wherever they stand (shift07: Luna
-- and Grok read different tools and disagreed about the green packs).
defines.inventory.chest=1; defines.flow_precision_index={ten_minutes=3}
prototypes={item={[red]={},[green]={},['utility-science-pack']={}}}
names[5]='full_output'
local flows={[green]={input=120,output=90}}
force.get_item_production_statistics=function() return {get_flow_count=function(f) return (flows[f.name] or {})[f.category] or 0 end} end
local function machine(x,y,status,recipe,out)
  n=n+1
  return {valid=true,unit_number=n,name='assembling-machine-2',type='assembling-machine',position={x=x,y=y},status=status,
    get_recipe=function() return recipe and {products={{name=recipe,amount=1}}} end,
    get_output_inventory=function() return {get_item_count=function(name) return name==recipe and out or 0 end} end}
end
local function chest(x,y,items)
  n=n+1
  return {valid=true,unit_number=n,name='steel-chest',type='container',position={x=x,y=y},
    get_inventory=function() return {get_item_count=function(name) return items[name] or 0 end} end}
end
local makers={machine(20,0,1,green,0),machine(23,0,5,green,7),machine(26,0,1,red,0),machine(29,0,1,nil)}
local chests={chest(40,0,{[green]=200}),chest(44,0,{[green]=12,[red]=3}),chest(48,0,{})}
local gbelt=belt(20,-3,{{name=green,count=6}})
surface.name='nauvis'
-- science reads everything in one find (supply.lua): every entity of the listed types.
local everything={}
for _,list in ipairs({labs,{i1,i2,i3},makers,chests,{feed,gbelt}}) do for _,e in ipairs(list) do everything[#everything+1]=e end end
surface.find_entities_filtered=function(f)
  if f.type=='lab' then return labs end
  if f.type=='inserter' then return {i1,i2,i3} end
  local types={}
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
  local out={}
  for _,e in ipairs(everything) do if types[e.type] then out[#out+1]=e end end
  return out
end
local carrier={valid=true,get_main_inventory=function() return {get_item_count=function(name) return name==green and 40 or 0 end} end}
local team={agents=function() return {{index=7,name='grok'},{index=8,name='luna'}} end,
  lookup=function(i) return i==7 and {character=carrier} or {} end}
local supply=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return names[e.status] end,agents=team.agents,lookup=team.lookup}
L=dofile('mod/agent-harness_0.1.0/labs.lua'){integer=function(v,d) return v or d end,center=function(p) return p.position end,
  status_name=function(e) return names[e.status] end,agents=team.agents,lookup=team.lookup,supply=supply}
-- Each read below changes the fake world first: the clock moves past the 10 s a reply is reused (supply.lua reuse).
game=game or {tick=0}
local science_once=L.science
local function science(pl,a) game.tick=game.tick+600; return science_once(pl,a) end
local s=science(p,{})
eq(s.surface,'nauvis'); eq(s.research,'logistics 25%'); eq(#s.packs,2)
local g=s.packs[2]
eq(g.pack,green); eq(g.made_10min,120); eq(g.used_10min,90); eq(g.makers,2); eq(g.makers_working,1); eq(g.makers_states[1],'1 full_output')
eq(g.in_makers,7); eq(g.chests,212); eq(g.belts,6); eq(g.labs,2); eq(g.labs_lacking,3); eq(g.carried[1],'grok 40')
eq(g.line,'logistic: made 120, used 90 in 10 min; makers 2 (2 assembling-machine-2; 1 working, 1 full_output; 7 in their output); chests 212, belts 6, labs 2 (3 of 4 labs have none); carried: grok 40; largest holders: (40,0) steel-chest 200, (44,0) steel-chest 12')
eq(s.packs[1].line,'automation: made 0, used 0 in 10 min; makers 1 (1 assembling-machine-2; 1 working); chests 3, belts 12, labs 11 (1 of 4 labs have none); largest holders: (44,0) steel-chest 3')
eq(s.counted,'4 crafters, 4 labs, 3 chests, 2 of 2 belts, 3 inserters, 0 robots, 0 logistic networks')
-- reach: where else the pack sits and why it does not reach the labs.
has(g.reach,'in other chests 212')
has(g.reach,'no inserter takes from the 2 makers')
has(g.reach,'3 inserters feed the labs: 1 working, 2 waiting_for_source_items (sources with none of it: 1 lab, 1 transport-belt); 1 labs have no inserter feeding them')
has(g.reach,'worst lab (60,60) lab no_power; holds 0; no inserter feeds it; nearest logistic-science-pack: steel-chest (44,0) 62 tiles')
-- the next worst labs lack it: fed from a belt or a lab holding none
local needs={[red]=true,[green]=true}
local scan=supply.scan(surface,force,{[green]=true},{packs=needs})
local _,worst=supply.machines(scan.items[green],scan.items[green].users,'labs',scan,needs)
eq(worst[2],'(3,0) lab missing_science_packs (missing logistic-science-pack); holds 0; none of its 1 feeding inserters takes from a place holding or requesting it (1 transport-belt); nearest logistic-science-pack: transport-belt (20,-3) 17 tiles')
eq(worst[3],'(6,0) lab missing_science_packs (missing logistic-science-pack); holds 0; none of its 1 feeding inserters takes from a place holding or requesting it (1 lab); nearest logistic-science-pack: transport-belt (20,-3) 14 tiles')
-- from somewhere else, the same reply
local far={position={x=500,y=-500},surface=surface,force=force}
eq(science(far,{}).packs[2].line,g.line)
-- one pack named; a pack the research does not use; checks
local u=science(p,{pack='utility-science-pack'})
eq(#u.packs,1); has(u.packs[1].line,'utility: made 0, used 0 in 10 min; makers 0 (0 working); chests 0, belts 0, labs 0 (the current research does not use it)')
local ok,err=pcall(science,p,{pack='iron-plat'}); assert(not ok and tostring(err):find('pack must be an item name',1,true),err)
force.current_research=nil
ok,err=pcall(science,p,{}); assert(not ok and tostring(err):find('no research is running: name a pack',1,true),err)
eq(science(p,{pack=green}).research,'none')
force.current_research=tech
-- The science reply carries each pack's chain too (here: its makers' recipe has no ingredients).
eq(science(p,{}).packs[2].chain,'chain: logistic-science-pack: 1 of 2 working (1 full_output), made 12/min, used 9/min')
-- A landing pad beside the chests and among the largest holders (Sol, 23:03: chests 185 and the largest chests left
-- out the pad's 766; Muse read it as 170 agricultural packs left).
do
  defines.inventory.cargo_landing_pad_main=defines.inventory.cargo_landing_pad_main or 42
  local pad=chest(70,0,{[green]=766}); pad.name='cargo-landing-pad'; pad.type='cargo-landing-pad'
  everything[#everything+1]=pad
  local gp=science(p,{}).packs[2]
  eq(gp.chests,212); eq(gp.landing_pads,766)
  has(gp.line,'chests 212, landing pads 766, belts 6')
  has(gp.line,'largest holders: (70,0) cargo-landing-pad 766, (40,0) steel-chest 200, (44,0) steel-chest 12')
  everything[#everything]=nil
end

-- chain (Sonnet, shift09: "I spend most cycles diagnosing that by hand"): the pack's recipe tree from the scan's
-- crafters, made and used per minute at each step, following what most makers lack down to the first step whose
-- makers mostly do not.
names[6]='item_ingredient_shortage'
defines.inventory.assembling_machine_input=4
prototypes.fluid={['petroleum-gas']={}}
local chem,adv,plastic='chemical-science-pack','advanced-circuit','plastic-bar'
local recipes={
  [chem]={name=chem,products={{name=chem,amount=2}},ingredients={{type='item',name='engine-unit',amount=2},{type='item',name=adv,amount=3},{type='item',name='sulfur',amount=1}}},
  [adv]={name=adv,products={{name=adv,amount=1}},ingredients={{type='item',name='electronic-circuit',amount=2},{type='item',name=plastic,amount=2},{type='item',name='copper-cable',amount=4}}},
  [plastic]={name=plastic,products={{name=plastic,amount=2}},ingredients={{type='fluid',name='petroleum-gas',amount=20},{type='item',name='coal',amount=1}}}}
local function crafter(recipe,status,held)
  n=n+1
  return {valid=true,unit_number=n,name='assembling-machine-2',type='assembling-machine',position={x=n,y=90},status=status,
    get_recipe=function() return recipes[recipe] end,
    get_inventory=function(i) eq(i,4); return {get_item_count=function(name) return held[name] or 0 end} end}
end
local cs={}
for i=1,14 do cs[#cs+1]=crafter(chem,i<=9 and 6 or 1,{['engine-unit']=4,sulfur=2}) end
for i=1,17 do cs[#cs+1]=crafter(adv,i<=12 and 6 or 1,{['electronic-circuit']=10,['copper-cable']=20}) end
for i=1,4 do cs[#cs+1]=crafter(plastic,1,{coal=5}) end
flows[chem]={input=120,output=300}; flows[adv]={input=80,output=200}; flows[plastic]={input=300,output=520}
force.get_fluid_production_statistics=function() return {get_flow_count=function(f) return f.name=='petroleum-gas' and (f.category=='input' and 6000 or 5800) or 0 end} end
local c=supply.chain({crafters=cs},force,surface,chem)
eq(c.line,'chain: chemical-science-pack: 9 of 14 makers lack advanced-circuit, made 12/min, used 30/min; '
  ..'advanced-circuit: 12 of 17 makers lack plastic-bar, made 8/min, used 20/min; plastic-bar: 4 of 4 working, made 30/min, used 52/min')
local tree={}
for _,row in ipairs(c.tree) do tree[#tree+1]=row.item..'@'..row.depth end
eq(table.concat(tree,' '),'chemical-science-pack@0 engine-unit@1 advanced-circuit@1 electronic-circuit@2 plastic-bar@2 petroleum-gas@3 coal@3 copper-cable@2 sulfur@1')
eq(c.tree[1].lacking[adv],9); eq(c.tree[1].working,5); eq(c.tree[1].states.item_ingredient_shortage,9)
eq(c.tree[6].made_per_min,600); eq(c.tree[6].used_per_min,580); eq(c.tree[6].makers,0)
-- A step whose makers lack something unmade: the line ends where nothing makes it.
for _,m in ipairs(cs) do if m.get_recipe().name==plastic then m.status=6; m.get_fluid_count=function() return 0 end end end
c=supply.chain({crafters=cs},force,surface,chem)
has(c.line,'plastic-bar: 4 of 4 makers lack petroleum-gas, made 30/min, used 52/min; petroleum-gas: no assembler, furnace, silo, mining drill or pump makes it, made 600/min, used 580/min')
-- Miners (Grok, 04:55: the chain said stone has no assembler): mining drills and pumpjacks make their resource's
-- products, offshore pumps their fluid; the step names their count, their states in words and what they put into;
-- a resource's required fluid is the step below it; a drill whose resource ran out keeps what it mined last.
do
  names[7],names[8],names[9]='waiting_for_space_in_destination','no_minable_resources','missing_required_fluid'
  local ms={}
  local mstate={}
  local S2=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return names[e.status] end,state=function() return mstate end}
  local function res(name,products,fluid) return {valid=true,prototype={mineable_properties={products=products,required_fluid=fluid}},name=name} end
  local stone_res=res('stone',{{type='item',name='stone',amount=1}})
  local function drill(name,status,target,into)
    n=n+1
    return {valid=true,unit_number=n,name=name,type='mining-drill',position={x=n,y=120},status=status,mining_target=target,drop_target=into}
  end
  local belt_e,chest_e={name='transport-belt'},{name='wooden-chest'}
  for i=1,5 do ms[#ms+1]=drill('electric-mining-drill',1,stone_res,belt_e) end
  ms[#ms+1]=drill('electric-mining-drill',7,stone_res,chest_e)
  ms[#ms+1]=drill('burner-mining-drill',7,stone_res,chest_e)
  local spent=drill('electric-mining-drill',1,stone_res,belt_e)
  ms[#ms+1]=spent
  recipes['stone-brick']={name='stone-brick',products={{name='stone-brick',amount=1}},ingredients={{type='item',name='stone',amount=2}}}
  local furn={valid=true,unit_number=999,name='stone-furnace',type='furnace',position={x=0,y=130},status=6,
    get_recipe=function() return recipes['stone-brick'] end,get_inventory=function() return {get_item_count=function() return 0 end} end}
  defines.inventory.furnace_source=defines.inventory.furnace_source or 5
  local c2=S2.chain({crafters={furn},miners=ms},force,surface,'stone-brick')
  has(c2.line,'stone-brick: 1 of 1 makers lack stone')
  has(c2.line,'; stone: 7 electric-mining-drill, 1 burner-mining-drill (6 working, 2 output full) into 6 transport-belt, 2 wooden-chest, made')
  eq(c2.tree[2].miners,8); eq(c2.tree[2].miner_states['output full'],2); eq(c2.tree[2].outputs['wooden-chest'],2)
  -- The spent drill: no target now, still under stone from what it mined last.
  spent.mining_target=nil; spent.status=8
  c2=S2.chain({crafters={furn},miners=ms},force,surface,'stone-brick')
  has(c2.line,'stone: 7 electric-mining-drill, 1 burner-mining-drill (5 working, 2 output full, 1 no resource left)')
  -- Uranium needs sulfuric acid: the step below it; drills short of it lack it. Offshore pumps make water.
  local u_res=res('uranium-ore',{{type='item',name='uranium-ore',amount=1}},'sulfuric-acid')
  prototypes.fluid['sulfuric-acid']={}; prototypes.fluid.water={}
  local ud={drill('electric-mining-drill',9,u_res,belt_e),drill('electric-mining-drill',9,u_res,belt_e),drill('electric-mining-drill',1,u_res,belt_e)}
  local pump={valid=true,unit_number=1001,name='offshore-pump',type='offshore-pump',position={x=0,y=140},status=1,fluidbox={{name='water',amount=100}}}
  local c3=S2.chain({crafters={},miners={ud[1],ud[2],ud[3],pump}},force,surface,'uranium-ore')
  has(c3.line,'uranium-ore: 2 of 3 makers lack sulfuric-acid')
  has(c3.line,'sulfuric-acid: no assembler, furnace, silo, mining drill or pump makes it')
  local c4=S2.chain({crafters={},miners={pump}},force,surface,'water')
  has(c4.line,'water: 1 offshore-pump (1 working),')
end
-- friction6: surface-only scans have no caller-centred radius; current inventory reads need visibility.
do
  local searched
  local remote_surface={name='remote-labs',find_entities_filtered=function(f) searched=f; return f.type=='lab' and {a1,b1} or {} end}
  game.get_surface=function(name) return name=='remote-labs' and remote_surface end
  force.is_chunk_visible=function(s,c) assert(s==remote_surface); return c.x==0 end
  local L=dofile('mod/agent-harness_0.1.0/labs.lua'){
    center=function(p,a) assert(p.surface==remote_surface); return a.position or p.position end,
    integer=function(v,d) return v or d end,status_name=function(e) return names[e.status] end}
  local r=L.view(p,{surface='remote-labs'})
  eq(r.surface,'remote-labs'); eq(r.position,nil); eq(r.radius,nil); eq(r.labs,'1 in 1 groups')
  r=L.view(p,{surface='remote-labs',position={x=0,y=0},radius=8})
  eq(r.position.x,0); eq(r.radius,8)
  local ok,err=pcall(L.view,p,{surface='remote-labs',radius=8})
  assert(not ok and tostring(err):find('requires position',1,true),tostring(err))
  ok,err=pcall(L.view,p,{surface='absent'}); assert(not ok and tostring(err):find('no surface absent',1,true))
  local hidden=belt(64,0,{{name=green,count=9}})
  local feeder=inserter(1,0,3,hidden,a1)
  remote_surface.find_entities_filtered=function(f) return f.type=='lab' and {a1} or {feeder} end
  has(L.view(p,{surface='remote-labs'}).groups[1],'pickup target outside visible chunks')
end

print('labs: ok')
