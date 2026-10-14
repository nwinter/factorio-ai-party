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
    get_transport_line=function(i) return {get_contents=function() return i==1 and items or {} end} end}
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
has(r.groups[2],'labs (60,60)-(60,60): 0/1 working, 1 no_power, lack automation (1), logistic (1); feeders: no inserters feed these labs')
-- Nothing researching, nothing working.
force.current_research=nil
eq(L.view(p,{}).research,'none: nothing queued (fh call research technology=NAME)')
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
surface.find_entities_filtered=function(f)
  if f.type=='lab' then return labs end
  if f.type=='inserter' then return {i1,i2,i3} end
  if f.type=='assembling-machine' then return makers end
  if type(f.type)=='table' and f.type[1]=='container' then return chests end
  if type(f.type)=='table' and f.type[1]=='transport-belt' then return {feed,gbelt} end
  return {}
end
local carrier={valid=true,get_main_inventory=function() return {get_item_count=function(name) return name==green and 40 or 0 end} end}
L=dofile('mod/agent-harness_0.1.0/labs.lua'){integer=function(v,d) return v or d end,center=function(p) return p.position end,
  status_name=function(e) return names[e.status] end,
  agents=function() return {{index=7,name='grok'},{index=8,name='luna'}} end,
  lookup=function(i) return i==7 and {character=carrier} or {} end}
local s=L.science(p,{})
eq(s.surface,'nauvis'); eq(s.research,'logistics 25%'); eq(#s.packs,2)
local g=s.packs[2]
eq(g.pack,green); eq(g.made_10min,120); eq(g.used_10min,90); eq(g.makers,2); eq(g.makers_working,1); eq(g.makers_states[1],'1 full_output')
eq(g.in_makers,7); eq(g.chests,212); eq(g.belts,6); eq(g.labs,2); eq(g.labs_lacking,3); eq(g.carried[1],'grok 40')
eq(g.line,'logistic: made 120, used 90 in 10 min; makers 2 (1 working, 1 full_output; 7 in their output); chests 212, belts 6, labs 2 (3 of 4 labs have none); carried: grok 40; largest chests: (40,0) steel-chest 200, (44,0) steel-chest 12')
eq(s.packs[1].line,'automation: made 0, used 0 in 10 min; makers 1 (1 working); chests 3, belts 12, labs 11 (1 of 4 labs have none); largest chests: (44,0) steel-chest 3')
eq(s.counted,'4 labs, 4 assemblers, 3 chests, 2 of 2 belts')
-- from somewhere else, the same reply
local far={position={x=500,y=-500},surface=surface,force=force}
eq(L.science(far,{}).packs[2].line,g.line)
-- one pack named; a pack the research does not use; checks
local u=L.science(p,{pack='utility-science-pack'})
eq(#u.packs,1); has(u.packs[1].line,'utility: made 0, used 0 in 10 min; makers 0 (0 working); chests 0, belts 0, labs 0 (the current research does not use it)')
local ok,err=pcall(L.science,p,{pack='iron-plat'}); assert(not ok and tostring(err):find('pack must be an item name',1,true),err)
force.current_research=nil
ok,err=pcall(L.science,p,{}); assert(not ok and tostring(err):find('no research is running: name a pack',1,true),err)
eq(L.science(p,{pack=green}).research,'none')
force.current_research=tech
print('labs: ok')
