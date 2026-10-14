-- Run with lua tests/silo.lua: the silo read (silo.lua; Gemini, shift09 00:20:
-- "A dedicated silo status command (parts X/50, loaded cargo weight, missing
-- ingredients)"). The shift world at 00:20: Fulgora's silo at 15/50 building,
-- 32 processing units, low density structures and rocket fuel in it; Nauvis's
-- at 50/50 with the rocket ready. 2.0 rocket-part: 1 of each, 3 s.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={rocket_silo_status={building_rocket=0,create_rocket=1,rocket_ready=7,launch_started=14},
  entity_status={working=1,item_ingredient_shortage=36,waiting_for_source_items=40},
  inventory={crafter_input=2,rocket_silo_rocket=11,rocket_silo_trash=12,cargo_unit=1},
  cargo_destination={invalid=0,orbit=1,station=2,surface=3,space_platform=4},
  space_platform_state={waiting_for_starter_pack=0,on_the_path=4,waiting_at_station=5}}
prototypes={utility_constants={rocket_lift_weight=1000000},item={
  ['processing-unit']={weight=3333.3333282471,stack_size=100},['low-density-structure']={weight=10000,stack_size=50},
  ['rocket-fuel']={weight=10000,stack_size=20},['space-platform-foundation']={weight=20000,stack_size=50}},
  entity={['rocket-silo']={get_inventory_size=function() return 20 end}}}
storage={}
game={tick=360000}
local names={}
for k,v in pairs(defines.entity_status) do names[v]=k end
local function inv(list,slots)
  local t={get_contents=function() local out={} for i,s in ipairs(list) do out[i]={name=s[1],count=s[2],quality='normal'} end return out end,
    get_item_count=function(name) for _,s in ipairs(list) do if s[1]==name then return s[2] end end return 0 end}
  for i=1,slots or 0 do t[i]=true end
  return t
end
local force={name='player',rockets_launched=116}
local recipe={name='rocket-part',energy=3,ingredients={{type='item',name='processing-unit',amount=1},{type='item',name='low-density-structure',amount=1},
  {type='item',name='rocket-fuel',amount=1}}}
local surfaces={}
local function surface(name)
  local s={name=name,planet={name=name},ents={}}
  s.find_entities_filtered=function(f)
    eq(f.force,force); assert(f.limit,'bounded')
    local out={}
    for _,e in ipairs(s.ents) do
      local inside=not f.area or (e.position.x>=f.area.left_top.x and e.position.x<=f.area.right_bottom.x and e.position.y>=f.area.left_top.y and e.position.y<=f.area.right_bottom.y)
      if e.type==f.type and inside then out[#out+1]=e end
    end
    return out
  end
  surfaces[name]=s
  return s
end
local fulgora,nauvis=surface('fulgora'),surface('nauvis')
function game.get_surface(name) return surfaces[name] end
local unit=0
local function ent(s,f)
  unit=unit+1
  local e={valid=true,unit_number=unit,surface=s,force=force}
  for k,v in pairs(f) do e[k]=v end
  s.ents[#s.ents+1]=e
  return e
end
local function silo(s,x,y,f)
  local e=ent(s,{name='rocket-silo',type='rocket-silo',position={x=x,y=y},prototype={rocket_parts_required=50},get_recipe=function() return recipe end,
    crafting_speed=1,productivity_bonus=0,use_transitional_requests=false})
  for k,v in pairs(f) do e[k]=v end
  e.get_inventory=function(i) return e.inv[i] end
  return e
end
-- Fulgora: building, 15/50, part 40% done; no rocket fuel in it.
local fs=silo(fulgora,-65.5,90.5,{rocket_parts=15,rocket_silo_status=0,status=1,crafting_progress=0.4,is_crafting=function() return true end,
  inv={[2]=inv({{'processing-unit',32},{'low-density-structure',32}}),[11]=inv({},20),[12]=inv({})}})
-- Its feeders: a chest of processing units (one in the hand), a belt with 5 low density structures (idle), and one
-- inserter dropping elsewhere.
local chest=ent(fulgora,{name='steel-chest',type='container',position={x=-71.5,y=86.5},get_output_inventory=function() return inv({{'processing-unit',100},{'iron-plate',50}}) end})
local belt=ent(fulgora,{name='transport-belt',type='transport-belt',position={x=-71.5,y=94.5},get_max_transport_line_index=function() return 2 end,
  get_transport_line=function(i) return {get_contents=function() return i==1 and {{name='low-density-structure',count=5,quality='normal'}} or {} end} end})
ent(fulgora,{name='fast-inserter',type='inserter',position={x=-70.5,y=86.5},drop_target=fs,pickup_target=chest,status=1,
  held_stack={valid_for_read=true,name='processing-unit',count=1}})
ent(fulgora,{name='fast-inserter',type='inserter',position={x=-70.5,y=94.5},drop_target=fs,pickup_target=belt,status=40,held_stack={valid_for_read=false}})
ent(fulgora,{name='inserter',type='inserter',position={x=-60.5,y=86.5},drop_target=chest,pickup_target=fs,status=1,held_stack={valid_for_read=false}})
-- Nauvis: ready, 933 kg aboard, a platform above and one on its way.
local ns=silo(nauvis,15.5,59.5,{rocket_parts=50,rocket_silo_status=7,status=36,crafting_progress=0,is_crafting=function() return false end,
  inv={[2]=inv({{'processing-unit',3}}),[11]=inv({{'processing-unit',100},{'space-platform-foundation',30}},20),[12]=inv({})}})
force.platforms={{valid=true,name='Sunward',state=5,space_location={name='nauvis'}},{valid=true,name='Skylark',state=4},
  {valid=true,name='Nest',state=0,space_location={name='nauvis'}}}

local cargo=dofile('mod/agent-harness_0.1.0/cargo.lua'){}
local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return storage end,cargo=cargo,
  position=function(v) assert(type(v)=='table' and v.x and v.y,'position'); return v end,
  status_name=function(e) return names[e.status] end}
local p={force=force,surface=fulgora}

-- 1. The silo on the agent's surface: parts, crafting, what it lacks, feeders.
local r=S.read(p,{})
eq(r.surface,'fulgora'); eq(#r.silos,1); eq(r.rockets_launched,116)
local f=r.silos[1]
eq(f.parts,'15/50'); eq(f.state,'building_rocket'); eq(f.status,'working'); eq(f.rocket_ready,false)
eq(f.crafting.parts_left,35); eq(f.crafting.part_progress,'40%'); eq(f.crafting.part_s,3); eq(f.crafting.rocket_eta_s,104)
eq(#f.ingredients,3)
local pu,lds,rf=f.ingredients[1],f.ingredients[2],f.ingredients[3]
eq(pu.name,'processing-unit'); eq(pu.in_silo,32); eq(pu.in_hands,1); eq(pu.at_sources,100); eq(pu.needed,34,'35 parts left, one in progress'); eq(pu.short,nil)
eq(lds.in_silo,32); eq(lds.at_sources,5); eq(lds.short,nil)
eq(rf.in_silo,0); eq(rf.at_sources,0); eq(rf.short,34)
eq(#f.lacks,1); eq(f.lacks[1],'rocket-fuel')
eq(f.feeders.inserters,2,'the inserter taking out of the silo is no feeder'); eq(f.feeders.idle[1],'1 idle: source transport-belt (-71.5,94.5) holds no ingredient it takes')
eq(f.cargo.kg,0); eq(f.cargo.slots,20); eq(f.cargo.lift_kg,1000); eq(f.auto_requests,false); eq(f.platforms_above,nil); eq(f.last_launch,nil)
eq(f.line,'rocket-silo (-65.5,90.5) on fulgora: building rocket, parts 15/50; working (part 40%), 35 parts left, the rocket in 1m44s at this speed; '
  ..'for the parts left: processing-unit 32 in the silo, 101 at feeders (34 needed), low-density-structure 32 in the silo, 5 at feeders (34 needed), '
  ..'rocket-fuel 0 in the silo, 0 at feeders (34 needed); lacks rocket-fuel in the silo; short for this rocket: rocket-fuel 34; '
  ..'2 feeding inserters (1 idle: source transport-belt (-71.5,94.5) holds no ingredient it takes); no cargo loaded; automatic requests off; no launch seen')

-- 2. Productivity: +10% makes 35 parts in 32 crafts.
fs.productivity_bonus=0.1
eq(S.read(p,{}).silos[1].ingredients[1].needed,31)
eq(S.read(p,{}).silos[1].crafting.productivity,'+10%')
fs.productivity_bonus=0

-- 3. Nauvis by surface: ready, cargo against the lift, platforms above.
local n=S.read(p,{surface='nauvis'}).silos[1]
eq(n.parts,'50/50'); eq(n.rocket_ready,true); eq(n.crafting,nil); eq(n.lacks,nil)
eq(n.cargo.kg,933.3); eq(n.cargo.stacks,2); eq(n.cargo.items,'processing-unit*100 space-platform-foundation*30'); eq(n.cargo.over_kg,nil)
eq(n.platforms_above[1],'Nest (waiting for its starter pack)'); eq(n.platforms_above[2],'Sunward'); eq(#n.platforms_above,2)
assert(n.line:find('rocket ready, parts 50/50; cargo 933.3/1000 kg, 2/20 slots: processing-unit*100 space-platform-foundation*30; automatic requests off; our platforms above: Nest (waiting for its starter pack), Sunward; no launch seen',1,true),n.line)

-- 4. A launch: the game's order event (cargo and destination), then the agent's call the same tick (who).
local hub={valid=true,surface={platform={valid=true,name='Sunward'}}}
local pod={get_inventory=function(i) eq(i,1); return inv({{'processing-unit',100},{'space-platform-foundation',30}}) end,
  cargo_pod_destination={type=2,station=hub}}
S.on_launch_ordered({rocket_silo=ns,rocket={attached_cargo_pod=pod}})
S.record(ns,{by='sol',to='platform Sunward'})
game.tick=game.tick+3600*12+60*5
n=S.read(p,{surface='nauvis'}).silos[1]
eq(n.last_launch.ago,'12m05s'); eq(n.last_launch.to,'platform Sunward'); eq(n.last_launch.by,'sol')
eq(n.last_launch.cargo,'processing-unit*100 space-platform-foundation*30')
assert(n.line:find('last launch 12m05s ago to platform Sunward by sol, cargo processing-unit*100 space-platform-foundation*30',1,true),n.line)
-- An automatic launch (no player) to orbit later replaces it.
S.on_launch_ordered({rocket_silo=ns,rocket={attached_cargo_pod={get_inventory=function() return inv({}) end,cargo_pod_destination={type=1}}}})
n=S.read(p,{surface='nauvis'}).silos[1]
eq(n.last_launch.to,'orbit'); eq(n.last_launch.by,nil); eq(n.last_launch.cargo,'empty'); eq(n.last_launch.ago,'0s')

-- 5. Overweight cargo; trash; automatic requests.
ns.inv[11]=inv({{'space-platform-foundation',50},{'rocket-fuel',20}},20)
ns.inv[12]=inv({{'processing-unit',7}})
ns.use_transitional_requests=true
n=S.read(p,{surface='nauvis'}).silos[1]
eq(n.cargo.kg,1200); eq(n.cargo.over_kg,200); eq(n.trash,'processing-unit*7'); eq(n.auto_requests,true)
assert(n.line:find('trash slots: processing-unit*7; automatic requests on',1,true),n.line)

-- 6. position picks the nearest of several; no silo is an error.
silo(fulgora,40.5,40.5,{rocket_parts=0,rocket_silo_status=0,status=36,crafting_progress=0,is_crafting=function() return false end,inv={[2]=inv({}),[11]=inv({},20),[12]=inv({})}})
eq(#S.read(p,{}).silos,2)
local near=S.read(p,{position={x=30,y=30}}).silos
eq(#near,1); eq(near[1].position.x,40.5)
eq(near[1].status,'item_ingredient_shortage'); eq(#near[1].lacks,3)
assert(near[1].line:find('item ingredient shortage, 50 parts left',1,true),near[1].line)
assert(near[1].line:find('no inserter feeds it',1,true),near[1].line)
local ok,err=pcall(S.read,p,{surface='vulcanus'})
assert(not ok and tostring(err):find('no surface vulcanus'),err)
surface('vulcanus')
ok,err=pcall(S.read,p,{surface='vulcanus'})
assert(not ok and tostring(err):find('no rocket silo of ours on vulcanus'),err)
print('silo ok')
