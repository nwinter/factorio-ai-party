-- d22 batch93 BC1 (viewer Aurora 13:13: "Haiku says the belt warning lists only 4 of 11 locations"): status's factory
-- warnings that show fewer places than they count say how many more and the call that lists them all, status {list:
-- KIND, page?}, which pages every place from the same survey. World n at 12:04 (a copy): "belts: 11 belts point into a
-- belt they cannot feed: (-26.5,-18.5) into underground-belt, ..., ..." with 4 shown and no way to read the other 7.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(list,pattern)
  for _,s in ipairs(type(list)=='table' and list or {list}) do if tostring(s):find(pattern,1,true) then return s end end
  error('no entry containing '..pattern..' in '..(type(list)=='table' and table.concat(list,' | ') or tostring(list)))
end
local function fails(f,x) local ok,err=pcall(f); assert(not ok,'did not fail'); has(tostring(err),x) end

defines={flow_precision_index={one_minute=1,ten_minutes=2},inventory={lab_input=9,turret_ammo=7},
  entity_status={working=1,no_fuel=2,low_power=3,no_power=4,missing_science_packs=5}}
local names={}
for k,v in pairs(defines.entity_status) do names[v]=k end
prototypes={item={}}
game={tick=0}
local stats={output_counts={},input_counts={},get_flow_count=function() return 0 end}
local force={name='player',get_item_production_statistics=function() return stats end}
local function ent(name,type,x,y,extra)
  local e={valid=true,name=name,type=type,status=defines.entity_status.working,position={x=x,y=y}}
  for k,v in pairs(extra or {}) do e[k]=v end
  return e
end
local entities={}
-- 9 empty gun turrets and 2 low ones; 7 burner drills with no fuel
for i=1,9 do entities[#entities+1]=ent('gun-turret','ammo-turret',100+i,0,{get_inventory=function() return {get_item_count=function() return 0 end} end}) end
for i=1,2 do entities[#entities+1]=ent('gun-turret','ammo-turret',200+i,0,{get_inventory=function() return {get_item_count=function() return 2 end} end}) end
for i=1,7 do entities[#entities+1]=ent('burner-mining-drill','mining-drill',300+i,0,{status=defines.entity_status.no_fuel,
  burner={inventory={is_empty=function() return true end},remaining_burning_fuel=0}}) end
-- 11 belts that point into another belt's side they cannot feed; 8 unpaired undergrounds
local belts,ahead={},{}
for i=1,11 do
  belts[#belts+1]={name='transport-belt',position={x=i*10+0.5,y=0.5},direction=4,belt_neighbours={outputs={}}}
  ahead[(i*10+1.5)..',0.5']={name='transport-belt'}
end
local ugs={}
for i=1,8 do ugs[#ugs+1]={position={x=i*10+0.5,y=50.5},belt_to_ground_type=i%2==0 and 'output' or 'input'} end
local surface={index=1,name='nauvis',valid=true,find_entities_filtered=function(f)
  if f.type=='underground-belt' then return ugs end
  if f.type=='transport-belt' then return belts end
  if f.position then local a=ahead[f.position.x..','..f.position.y]; return a and {a} or {} end
  return entities
end}
local p={index=1,force=force,surface=surface,get_main_inventory=function() return nil end}
local st={}
local S=dofile('mod/agent-harness_0.1.0/survey.lua'){state=function() return st end,status_name=function(e) return names[e.status] end}

local s=S.summary(p)
-- the warnings show what they did and say how many more and the call
local w=has(s.warnings,'belts: 11 belts point into a belt they cannot feed: ')
has(w,'(10.5,0.5) into transport-belt, (100.5,0.5) into transport-belt, (110.5,0.5) into transport-belt, (20.5,0.5) into transport-belt, +7 more (status {list: "belts_stuck"} lists all 11)')
has(s.warnings,'belts: 8 unpaired undergrounds: input (10.5,50.5), input (30.5,50.5), input (50.5,50.5), input (70.5,50.5), +4 more (status {list: "belts_unpaired"} lists all 8)')
w=has(s.warnings,'ammo: gun-turret 9/11 empty at ')
has(w,' +3 more, 2 below 5 at (201,0) (202,0); status {list: "ammo_empty"} lists all 9 empty; rearm radius=R')
assert(not w:find('ammo_low',1,true),'the 2 low ones are all shown: no list call for them')
has(s.warnings,'fuel on nauvis: burner-mining-drill 7/7 no_fuel at (301,0) (302,0) (303,0) (304,0) (305,0) (306,0) +1 more; status {list: "no_fuel"} lists all 7 with no fuel')
-- nothing shown as "..." any more
for _,x in ipairs(s.warnings) do assert(not x:find(', ...',1,true) and not x:find(' ...;',1,true),x) end

-- status {list}: every place, paged 50 a page, the same survey
local r=S.list(p,'belts_stuck')
eq(r.count,11); eq(#r.rows,11); eq(r.page,1); eq(r.pages,1); eq(r.next,nil)
eq(r.rows[11],'(90.5,0.5) into transport-belt')
has(r.line,'belts that point into a belt they cannot feed on nauvis: 11; 1-11 of them (page 1 of 1): (10.5,0.5) into transport-belt')
eq(#S.list(p,'belts_unpaired').rows,8)
r=S.list(p,'ammo_empty'); eq(r.count,9); eq(r.rows[1],'gun-turret (101,0)')
r=S.list(p,'no_fuel'); eq(r.count,7); eq(r.rows[7],'burner-mining-drill (307,0)')
eq(S.list(p,'ammo_low').count,2)
eq(S.list(p,'last_fuel').count,0)
-- many: pages and next
for i=12,130 do
  belts[#belts+1]={name='transport-belt',position={x=i*10+0.5,y=0.5},direction=4,belt_neighbours={outputs={}}}
  ahead[(i*10+1.5)..',0.5']={name='transport-belt'}
end
s=S.summary(p,true)  -- a fresh survey
has(s.warnings,'+126 more (status {list: "belts_stuck"} lists all 130)')
r=S.list(p,'belts_stuck')
eq(r.count,130); eq(#r.rows,50); eq(r.pages,3); eq(r.next,'status {list: "belts_stuck", page: 2}')
r=S.list(p,'belts_stuck',3)
eq(#r.rows,30); eq(r.next,nil); has(r.line,'101-130 of them (page 3 of 3)')
has(S.list(p,'belts_stuck',4).line,'page 4 of 3 is past them')
fails(function() S.list(p,'belts') end,'list is one of ammo_empty, ammo_low, belts_stuck, belts_unpaired, last_fuel, no_fuel')
fails(function() S.list(p,'belts_stuck',0) end,'page is 1 or more')
defines,prototypes,game=nil,nil,nil
print('d22_batch93 BC1 warnings with every place readable: ok')
