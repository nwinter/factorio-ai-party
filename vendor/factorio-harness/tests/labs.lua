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
print('labs: ok')
