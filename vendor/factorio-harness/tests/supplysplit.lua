-- supply {item, split} (batch27 B4, Opus: where an ore goes now): each group of machines whose recipe takes the item,
-- by recipe and place, with its take at full speed and what feeds it; requesters asking for it that feed none of them.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or '')..' '..tostring(a)..' ~= '..tostring(b)) end
defines={flow_precision_index={ten_minutes=2},logistic_member_index={logistic_container=1}}
prototypes={item={['iron-ore']={}},recipe={['iron-plate']={name='iron-plate',energy=3.2,ingredients={{type='item',name='iron-ore',amount=1}}}}}
local n=0
local function furnace(x,y,working)
  n=n+1
  return {valid=true,unit_number=n,name='steel-furnace',type='furnace',position={x=x,y=y},crafting_speed=2,working=working,
    get_recipe=function() return nil end,previous_recipe=prototypes.recipe['iron-plate']}
end
-- a west row of 4 (3 working) fed from a belt; an east pair 100 tiles off fed from a requester chest in network #5
local west={furnace(0,0,true),furnace(0,3,true),furnace(0,6,true),furnace(0,9,false)}
local east={furnace(100,0,true),furnace(100,3,true)}
local belt={valid=true,type='transport-belt',name='transport-belt',position={x=-2.5,y=0.5}}
local req={valid=true,unit_number=90,type='logistic-container',name='requester-chest',position={x=98.5,y=1.5},prototype={logistic_mode='requester'},logistic_network={network_id=5},
  get_logistic_point=function() return {filters={{name='iron-ore',count=100}}} end}
local lone={valid=true,unit_number=91,type='logistic-container',name='requester-chest',position={x=50.5,y=50.5},prototype={logistic_mode='requester'},
  get_logistic_point=function() return {filters={{name='iron-ore',count=40}}} end}
local inserters={}
for i,f in ipairs(west) do inserters[#inserters+1]={valid=true,type='inserter',position={x=-1,y=f.position.y},drop_target=f,pickup_target=belt} end
for i,f in ipairs(east) do inserters[#inserters+1]={valid=true,type='inserter',position={x=99,y=f.position.y},drop_target=f,pickup_target=req} end
local function inside(e,ar) return e.position.x>=ar[1][1] and e.position.x<=ar[2][1] and e.position.y>=ar[1][2] and e.position.y<=ar[2][2] end
local surface={name='nauvis',find_entities_filtered=function(f)
  local out={}
  if type(f.type)=='table' then for _,e in ipairs(west) do out[#out+1]=e end; for _,e in ipairs(east) do out[#out+1]=e end; return out end
  if f.type=='inserter' then for _,e in ipairs(inserters) do if inside(e,f.area) then out[#out+1]=e end end return out end
  if f.type=='logistic-container' then return {req,lone} end
  return out
end}
local force={get_item_production_statistics=function() return {get_flow_count=function(a) return a.category=='output' and 1500 or 1400 end} end}
local S=require('supply'){status_name=function(e) return e.working and 'working' or 'no_ingredients' end,position=function(v) return v end,integer=function(v,d) return v or d end}
local r=S.supply({surface=surface,force=force},{item='iron-ore',split=true})
eq(#r.groups,2)
eq(r.groups[1].machines,4); eq(r.groups[1].working,3); eq(r.groups[1].per_min,150,'4 at 2x speed, 1 ore a 3.2 s craft')
eq(r.lines[1],'iron-ore on nauvis: used 150/min, made 140/min (last 10 min); 2 groups of machines take 225/min at full speed:')
eq(r.lines[2],'iron-plate near (0,0)-(0,9): 4 steel-furnace (3 working) take 150/min at full speed, 67% of the take; fed from belts (4 inserters); a belt it takes from at (-2.5,0.5)')
eq(r.lines[3],'iron-plate near (100,0)-(100,3): 2 steel-furnace (2 working) take 75/min at full speed, 33% of the take; fed from requester chests of logistic network #5 (2 inserters)')
eq(r.lines[4],'1 requester or buffer chest asks 40 in all and feeds none of these machines')
assert(not pcall(S.supply,{surface=surface,force=force},{item='iron-ore',split=1}),'split is true')
-- batch28 B4 (Opus: where petroleum gas goes, 3 times): a fluid's groups with the pipe segments they draw from and the
-- machines making it on each.
do
  prototypes.fluid={['petroleum-gas']={}}
  prototypes.recipe['plastic-bar']={name='plastic-bar',energy=1,ingredients={{type='fluid',name='petroleum-gas',amount=20},{type='item',name='coal',amount=1}}}
  prototypes.recipe['advanced-oil-processing']={name='advanced-oil-processing',energy=5,ingredients={{type='fluid',name='crude-oil',amount=100}},products={{type='fluid',name='petroleum-gas',amount=55}}}
  local function fb(seg,name) local t={{name=name,amount=50}}; t.get_filter=function() return nil end; t.get_fluid_segment_id=function() return seg end; return setmetatable(t,{__len=function() return 1 end}) end
  local function plant(x,seg,working)
    n=n+1
    return {valid=true,unit_number=n,name='chemical-plant',type='assembling-machine',position={x=x,y=40},crafting_speed=1,working=working,
      get_recipe=function() return prototypes.recipe['plastic-bar'] end,fluidbox=fb(seg,'petroleum-gas')}
  end
  local a1,a2,b1=plant(0,7,true),plant(3,7,true),plant(200,9,false)
  n=n+1
  local refinery={valid=true,unit_number=n,name='oil-refinery',type='assembling-machine',position={x=-10,y=40},crafting_speed=1,
    get_recipe=function() return prototypes.recipe['advanced-oil-processing'] end,fluidbox=fb(7,'petroleum-gas')}
  local fsurf={name='nauvis',find_entities_filtered=function(f) if type(f.type)=='table' then return {a1,a2,b1,refinery} end return {} end}
  local fforce={get_fluid_production_statistics=function() return {get_flow_count=function(a) return a.category=='output' and 25000 or 24000 end} end}
  local r=S.supply({surface=fsurf,force=fforce},{item='petroleum-gas',split=true})
  eq(#r.groups,2)
  eq(r.lines[1],'petroleum-gas on nauvis: used 2500/min, made 2400/min (last 10 min); 2 groups of machines take 3600/min at full speed:')
  eq(r.lines[2],'plastic-bar near (0,40)-(3,40): 2 chemical-plant (2 working) take 2400/min at full speed, 67% of the take; fed from pipe segment #7 (made on it by 1 oil-refinery)')
  eq(r.lines[3],'plastic-bar near (200,40)-(200,40): 1 chemical-plant (0 working) take 1200/min at full speed, 33% of the take; fed from pipe segment #9 (no machine making it is on it: tanks, pumps or a pipe in between)')
end
print('supplysplit: ok')
