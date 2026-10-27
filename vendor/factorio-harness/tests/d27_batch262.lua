-- d27 batch262. Run from the harness root: lua tests/d27_batch262.lua
-- IQ (Astra #2536, tick 71197962: ingredient_gap on Nauvis AM3 (40.5,74.5), recipe beacon@legendary, read steel and
-- both circuits as 0 held with legendary ones inside, and named normal donors): the recipe's quality is read; held
-- counts that quality only, other_quality the rest; the donors are searched at that quality (holders, the ground, a
-- chest's request, robots' reservations).
-- Engine facts, 2.0.77 on the private copy: get_recipe() returns recipe and quality; an idle furnace's previous_recipe
-- is {name, quality}; get_item_count(name) and get_item_count{name=} count normal only (a chest of 50 normal and 30
-- legendary steel read 50 both ways), {name=, quality=} that quality; a requester's filters and a provider's
-- targeted_items_pickup rows carry quality as a string.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

game={tick=1000}
defines={inventory={assembling_machine_input=2,furnace_source=3,chest=1,cargo_landing_pad_main=1},logistic_member_index={logistic_container=0}}
prototypes={recipe={beacon={ingredients={{type='item',name='steel-plate',amount=10},{type='item',name='copper-cable',amount=10},
  {type='item',name='electronic-circuit',amount=20},{type='item',name='advanced-circuit',amount=20}}},
  ['iron-plate']={ingredients={{type='item',name='iron-ore',amount=1}}}}}
local LEGENDARY={name='legendary'}  -- get_recipe's second value is a quality prototype
-- an inventory as the game reads it: get_item_count by name or {name} is normal only, {name, quality} that quality
local function inventory(stacks)
  return {get_contents=function() local out={} for i,c in ipairs(stacks) do out[i]={name=c[1],count=c[2],quality=c[3] or 'normal'} end return out end,
    get_item_count=function(x)
      local name,q=type(x)=='table' and x.name or x,type(x)=='table' and x.quality or 'normal'
      local n=0 for _,c in ipairs(stacks) do if c[1]==name and (c[3] or 'normal')==q then n=n+c[2] end end return n
    end}
end

-- ---- the machine: Astra's beacon@legendary with mixed stock ----------------------------------------------------
local am3={valid=true,name='assembling-machine-3',type='assembling-machine',position={x=40.5,y=74.5},
  get_recipe=function() return {name='beacon'},LEGENDARY end,
  get_inventory=function() return inventory({{'steel-plate',10,'legendary'},{'steel-plate',5,'normal'},{'electronic-circuit',20,'legendary'},
    {'advanced-circuit',12,'legendary'},{'copper-cable',40,'normal'}}) end,fluidbox={}}
local asked={}
local G=dofile('mod/agent-harness_0.1.0/gap.lua'){position=function(v) return v end,entity=function() return am3 end,seen=function() return true end,
  scan=function(_,item,opts) asked[#asked+1]={item=item,quality=opts.quality}; return {places={}} end,
  where_kept=function(_,item,need,scan,q) return string.format('kept %s@%s, %d', item, tostring(q), need) end,status=function() return 'item_ingredient_shortage' end}
do
  local r=G.read({},{position={x=40.5,y=74.5}})
  local m=r.machines[1]
  eq(m.recipe,'beacon'); eq(m.recipe_quality,'legendary')
  local by={}
  for _,row in ipairs(m.ingredients) do by[row.item]=row end
  -- on main: steel, both circuits and cable read 0 held (get_item_count(name): normal only)
  eq(by['steel-plate'].held,10,'legendary steel held'); eq(by['steel-plate'].short,nil); eq(by['steel-plate'].other_quality,5,'the normal steel: other quality')
  eq(by['steel-plate'].quality,'legendary')
  eq(by['electronic-circuit'].held,20); eq(by['electronic-circuit'].short,nil)
  eq(by['advanced-circuit'].held,12); eq(by['advanced-circuit'].short,8)
  eq(by['copper-cable'].held,0,'normal cable does not feed a legendary craft'); eq(by['copper-cable'].short,10); eq(by['copper-cable'].other_quality,40)
  eq(r.lines[1],'assembling-machine-3 (40.5,74.5) beacon@legendary (item_ingredient_shortage): steel-plate@legendary 10/10 (and 5 of other quality, which this recipe does not take); '
    ..'copper-cable@legendary 0/10 (and 40 of other quality, which this recipe does not take): 10 short; kept copper-cable@legendary, 10; '
    ..'electronic-circuit@legendary 20/20; advanced-circuit@legendary 12/20: 8 short; kept advanced-circuit@legendary, 8')
  -- the donors searched at the recipe's quality
  eq(#asked,2); eq(asked[1].item,'copper-cable'); eq(asked[1].quality,'legendary'); eq(asked[2].quality,'legendary')
  -- a normal recipe as before: normal held, the field and the line plain
  am3.get_recipe=function() return {name='beacon'},{name='normal'} end
  asked={}
  r=G.read({},{position={x=40.5,y=74.5}})
  m=r.machines[1]
  eq(m.recipe_quality,'normal'); by={}
  for _,row in ipairs(m.ingredients) do by[row.item]=row end
  eq(by['steel-plate'].held,5); eq(by['steel-plate'].other_quality,10); eq(by['steel-plate'].quality,nil); eq(by['copper-cable'].held,40)
  has(r.lines[1],'beacon (item_ingredient_shortage): steel-plate 5/10 (and 10 of other quality'); eq(asked[1].quality,'normal')
end
print('d27_batch262 IQ held at the recipe quality: ok')

-- ---- an idle furnace: previous_recipe {name, quality} ----------------------------------------------------------
do
  local fu={valid=true,name='electric-furnace',type='furnace',position={x=4.5,y=-10.5},get_recipe=function() return nil end,
    previous_recipe={name={name='iron-plate'},quality={name='legendary'}},get_inventory=function() return inventory({{'iron-ore',3,'normal'}}) end,fluidbox={}}
  local F=dofile('mod/agent-harness_0.1.0/gap.lua'){position=function(v) return v end,entity=function() return fu end,seen=function() return true end,
    scan=function() return {places={}} end,where_kept=function() return 'none' end}
  local m=F.read({},{position=fu.position}).machines[1]
  eq(m.recipe,'iron-plate'); eq(m.recipe_quality,'legendary'); eq(m.ingredients[1].held,0); eq(m.ingredients[1].other_quality,3)
end
print('d27_batch262 IQ an idle furnace keeps its quality: ok')

-- ---- the donors: holders found once, by quality; the ground by quality ------------------------------------------
do
  local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^.5 end
  local empty=inventory({})
  local cables=inventory({{'copper-cable',100,'normal'},{'copper-cable',15,'legendary'}})
  local chest={valid=true,name='iron-chest',type='container',position={x=50.5,y=74.5},get_inventory=function() return cables end}
  local machine={valid=true,name='assembling-machine-3',type='assembling-machine',position={x=40.5,y=74.5},get_recipe=function() return {name='beacon'},LEGENDARY end,
    get_inventory=function() return inventory({{'steel-plate',10,'legendary'},{'electronic-circuit',20,'legendary'},{'advanced-circuit',20,'legendary'}}) end,
    get_output_inventory=function() return empty end,fluidbox={}}
  local surface={name='nauvis',find_entities_filtered=function(f)
    if f.name=='cargo-pod-container' then return {} end
    if f.radius then return {} end
    if f.type[3]=='rocket-silo' then return {machine} end
    if f.type[1]=='container' then return {chest} end
    if f.type[1]=='assembling-machine' then return {machine} end
    return {}
  end}
  local p={surface=surface,force={name='player'},position={x=0,y=0}}
  local ground_reads={}
  local cells={}
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){distance=distance,
    on_ground=function(_,_,item,o) ground_reads[#ground_reads+1]={item=item,quality=o.quality,radius=o.radius}; return {count=7,stacks=1,cells={{position={x=45.5,y=74.5},count=7,stacks=1}}} end}
  local G2=dofile('mod/agent-harness_0.1.0/gap.lua'){position=function(v) return v end,seen=function() return true end,entity=function() return machine end,
    scan=function(pp,item,opts) return S.scan(pp,item,opts) end,near=function(pp,box,ground) return S.near(pp,box,ground) end,
    ground_index=function() return {count=9,stacks=2,cells=cells} end,
    where_kept=function(_,item,need,scan,q) local out={} for _,x in ipairs(scan.places) do out[#out+1]=string.format('%s %d%s',x.name,x.count,x.quality and '@'..x.quality or '') end return table.concat(out,'; ') end}
  -- the ground index (every quality) shows no stack within 64 tiles: no ground read
  cells={{position={x=400.5,y=74.5},count=9,stacks=2}}
  local r=G2.read(p,{area={left_top={x=0,y=60},right_bottom={x=60,y=90}}})
  local cable=r.machines[1].ingredients[2]
  eq(cable.item,'copper-cable'); eq(cable.short,10)
  -- on main: the near index kept normal stock only and the legendary scan read the chest's 100 normal cable
  eq(cable.donors,'iron-chest 15','the legendary cable only'); eq(#ground_reads,0)
  -- stacks within the radius by the index: the ground read at the recipe's quality, within 64 tiles
  cells={{position={x=45.5,y=74.5},count=9,stacks=2}}
  r=G2.read(p,{area={left_top={x=0,y=60},right_bottom={x=60,y=90}}})
  eq(#ground_reads,1); eq(ground_reads[1].quality,'legendary'); eq(ground_reads[1].radius,64)
  eq(r.machines[1].ingredients[2].donors,'1 stack on the ground 7@legendary; iron-chest 15')
  -- the same chest for a normal recipe: its 100 normal cable
  machine.get_recipe=function() return {name='beacon'},{name='normal'} end
  machine.get_inventory=function() return inventory({{'steel-plate',10},{'electronic-circuit',20},{'advanced-circuit',20}}) end
  ground_reads={}
  r=G2.read(p,{area={left_top={x=0,y=60},right_bottom={x=60,y=90}}})
  has(r.machines[1].ingredients[2].donors,'iron-chest 100'); eq(ground_reads[1].quality,'normal')
end
print('d27_batch262 IQ donors at the recipe quality: ok')

-- ---- a chest's request and robots' reservations, by quality --------------------------------------------------
do
  local R=dofile('mod/agent-harness_0.1.0/reqchest.lua'){}
  -- the filters as the copy read them: {comparator, count, index, name, quality}
  local pt={filters={{comparator='=',count=10,index=1,name='steel-plate',quality='normal'},{comparator='=',count=25,index=2,name='steel-plate',quality='legendary'}}}
  eq(R.request(pt,'steel-plate','legendary'),25); eq(R.request(pt,'steel-plate','normal'),10)
  eq(R.request(pt,'steel-plate'),35,'no quality: every quality, as before')
  local U=dofile('mod/agent-harness_0.1.0/supply.lua'){}
  local pp={valid=true,type='logistic-container',get_logistic_point=function() return {targeted_items_pickup={{count=12,name='steel-plate',quality='normal'},{count=8,name='steel-plate',quality='legendary'}}} end}
  eq(U.reserved(pp,'steel-plate','legendary'),8); eq(U.reserved(pp,'steel-plate','normal'),12); eq(U.reserved(pp,'steel-plate'),20)
end
print('d27_batch262 IQ requests and reservations by quality: ok')
