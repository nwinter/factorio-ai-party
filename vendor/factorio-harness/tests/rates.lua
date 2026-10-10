-- Run from repository root: lua tests/rates.lua
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function near(a,b) assert(math.abs(a-b)<0.01,tostring(a)..' !~ '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn);assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={entity_status={no_power=4},inventory={assembling_machine_input=2,furnace_source=3}}
prototypes={item={coal={name='coal',fuel_value=4e6},['iron-plate']={name='iron-plate'}},fluid={}}
local force={name='player',recipes={},inserter_stack_size_bonus=0,bulk_inserter_capacity_bonus=0,belt_stack_size_bonus=0}
local function none() return nil end
local function fluidbox() return setmetatable({get_filter=none},{__len=function() return 0 end}) end
local ASSEMBLER={electric_energy_source_prototype={drain=2500/60},get_max_energy_usage=function() return 75000/60 end,
  get_max_energy_production=function() return 0 end}
local gear_recipe={name='iron-gear-wheel',energy=0.5,productivity_bonus=0,prototype={maximum_productivity=3},
  ingredients={{type='item',name='iron-plate',amount=2}},products={{type='item',name='iron-gear-wheel',amount=1}}}
local plate_recipe={name='iron-plate',energy=3.2,productivity_bonus=0,prototype={maximum_productivity=3},
  ingredients={{type='item',name='iron-ore',amount=1}},products={{type='item',name='iron-plate',amount=1}}}
local input_slots={get_item_count=function(name) return name=='iron-plate' and 1 or 0 end}
local assembler={valid=true,name='assembling-machine-1',type='assembling-machine',position={x=0.5,y=0.5},unit_number=1,
  prototype=ASSEMBLER,crafting_speed=0.5,productivity_bonus=0,consumption_bonus=0,speed_bonus=0,status=6,fluidbox=fluidbox(),
  get_recipe=function() return gear_recipe,{name='normal'} end,get_inventory=function() return input_slots end}
local furnace={valid=true,name='stone-furnace',type='furnace',position={x=5,y=0},unit_number=2,crafting_speed=2,
  productivity_bonus=0,consumption_bonus=0,speed_bonus=0,status=1,fluidbox=fluidbox(),
  prototype={burner_prototype={effectivity=1},get_max_energy_usage=function() return 90000/60 end},
  burner={currently_burning={name=prototypes.item.coal,quality={name='normal'}}},
  get_recipe=function() return plate_recipe,{name='normal'} end}
local ore={name='iron-ore',prototype={resource_category='basic-solid',mineable_properties={mining_time=1,products={{type='item',name='iron-ore',amount=1}}}}}
local drill={valid=true,name='electric-mining-drill',type='mining-drill',position={x=10,y=0},unit_number=3,status=1,
  productivity_bonus=0,consumption_bonus=0,speed_bonus=0,fluidbox=fluidbox(),
  prototype={mining_speed=0.5,mining_drill_radius=2.49,resource_categories={['basic-solid']=true},fluidbox_prototypes={},
    electric_energy_source_prototype={drain=0},get_max_energy_usage=function() return 90000/60 end,get_max_energy_production=function() return 0 end}}
local burner_inserter={valid=true,name='burner-inserter',type='inserter',position={x=1.5,y=2.5},force=force,status=2,drop_target=assembler,
  prototype={inserter_stack_size_bonus=0,get_inserter_rotation_speed=function() return 0.01 end}}
local belt={valid=true,name='transport-belt',type='transport-belt',position={x=3.5,y=3.5},prototype={belt_speed=0.03125}}
local world={assembler,furnace,drill,burner_inserter,belt}
local surface={find_entities_filtered=function(f)
  if f.type=='resource' then return {ore,ore,ore,ore} end
  local types={}
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
  local out={}
  for _,e in ipairs(world) do
    if types[e.type] and (not f.position or math.abs(e.position.x-f.position.x)<=0.5) then out[#out+1]=e end
  end
  return out
end}
drill.surface=surface
local p={force=force,surface=surface}
local names={[1]='working',[2]='waiting_for_source_items',[6]='item_ingredient_shortage'}
local R=dofile('mod/agent-harness_0.1.0/rates.lua'){position=function(v) return v end,status_name=function(e) return names[e.status] end}
local area={left_top={x=-10,y=-10},right_bottom={x=20,y=10}}
local r=R.rates(p,{area=area})
local rows={}
for _,row in ipairs(r.rows) do rows[row.item]=row end
-- Assembler: 0.5 s recipe at speed 0.5 = 1 craft/s.
eq(rows['iron-gear-wheel'].produced,60); eq(rows['iron-gear-wheel'].by,'assembling-machine-1 x1')
-- Furnace: 3.2 s at speed 2 = 37.5 plates/min; drill 0.5 ore/s.
eq(rows['iron-plate'].produced,37.5); eq(rows['iron-plate'].consumed,120); eq(rows['iron-plate'].net,-82.5)
eq(rows['iron-ore'].produced,30); eq(rows['iron-ore'].consumed,37.5)
-- Burner fuel: 90 kW / 4 MJ = 1.35 coal/min.
eq(rows.coal.consumed,1.35); eq(rows.coal.into,'stone-furnace x1')
eq(r.power.power.consumed,'168 kW'); eq(r.per,'minute')
eq(R.rates(p,{area=area,per='second'}).rows[2].produced,1) -- gears per second
eq(R.rates(p,{positions={{x=0.5,y=0.5}}}).machines,1)
fails(function() R.rates(p,{area=area,per='hour'}) end,'per must be')
fails(function() R.rates(p,{}) end,'area or positions')
furnace.burner={currently_burning=nil,inventory={get_contents=function() return {} end}}
eq(R.rates(p,{area=area}).errors.no_fuel,1)
furnace.burner={currently_burning={name=prototypes.item.coal,quality={name='normal'}}}
-- Bottleneck: status by recipe, the ingredient short in the machine, the
-- burner inserter (0.6/s) feeding a machine that needs 2/s, and outside needs.
local b=R.bottleneck(p,{area=area})
eq(b.groups[1].machines,'assembling-machine-1 iron-gear-wheel x1'); eq(b.groups[1].short,'iron-plate (1)'); eq(b.groups[1].idle,1)
eq(b.limits[1],'assembling-machine-1 iron-gear-wheel (0.5,0.5): input inserters 0.6/s < needs 2/s')
eq(table.concat(b.needs,'; '),'coal 1.35/min; iron-ore 7.5/min; iron-plate 82.5/min'); eq(b.belt_capacity,'transport-belt 900/min')
eq(b.inserters,'1 inserters: 1 waiting for source items, 0 waiting for space')
print('rates: ok')
