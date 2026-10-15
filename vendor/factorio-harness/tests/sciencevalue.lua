local root = 'mod/agent-harness_0.1.0/'
package.path=root..'?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function near(a,b) assert(math.abs(a-b)<1e-8,tostring(a)..' ~= '..tostring(b)) end
local function has(s,p) assert(s and s:find(p,1,true),tostring(s)..' lacks '..p) end
local pack='agricultural-science-pack'
game={tick=1000}
defines={inventory={lab_input=1,chest=2,rocket_silo_rocket=3,assembling_machine_input=4,assembling_machine_output=5,hub_main=6},flow_precision_index={ten_minutes=1},space_platform_state={on_the_path=3,waiting_at_station=6}}
prototypes={item={[pack]={name=pack,type='tool',get_spoil_ticks=function() return 216000 end,get_durability=function(q) return q=='uncommon' and 2 or q=='legendary' and 6 or 1 end},nutrients={type='item',get_spoil_ticks=function() return 18000 end}}}
local function stack(n,p,q,d,left)
  q=q or 'normal'
  return {valid_for_read=true,name=pack,count=n,quality={name=q},durability=d or prototypes.item[pack].get_durability(q),spoil_percent=p,spoil_tick=game.tick+(left or (1-p)*216000)}
end
local function inv(rows)
  rows.valid=true
  rows.get_item_count=function(name) local n=0;for _,s in ipairs(rows) do if s.name==name and s.quality.name=='normal' then n=n+s.count end end;return n end
  rows.get_contents=function() local out={};for _,s in ipairs(rows) do out[#out+1]={name=s.name,count=s.count,quality=s.quality.name} end;return out end
  return rows
end
local S=dofile(root..'spoil.lua'){}
local mixed=inv{stack(200,.9),stack(200,.5)}
local a=S.inventory(mixed,{},nil,36000)
near(a[1].research_units,120);near(a[1].research_units_at_arrival,200/3)
local force={name='player',current_research={name='two-packs',research_unit_ingredients={{name=pack,amount=2}}},research_progress=0}
local v=S.research_value(a[1],force)
near(v.now,60);near(v.at_arrival,100/3);eq(v.packs_per_unit,2)
has(S.research_text(a[1],force),'effective research units now 60.00, at arrival 33.33 (2 pack/unit for two-packs; before lab bonuses)')
local partial=S.inventory(inv{stack(1,.5,nil,.5),stack(2,.5,'legendary',3)},{})
near(partial[pack].research_units,.25);near(partial[pack..'@legendary'].research_units,4.5)
eq(partial[pack].research_units_at_arrival,nil)
local moved={};S.add_count(moved,pack,'normal',10,.5,game.tick+108000);eq(moved[1].research_units,nil)
local merged={};S.merge(merged,a[1]);S.merge(merged,S.inventory(inv{stack(1,0)}, {},nil,36000)[1])
near(merged[1].research_units,121);near(merged[1].research_units_at_arrival,200/3+5/6)
near(S.inventory(inv{stack(1,1,nil,nil,0)},{},nil,1)[1].research_units_at_arrival,0)
near(S.inventory(inv{stack(1,.25)},{},nil,0)[1].research_units_at_arrival,.75)
local nutrient={valid_for_read=true,name='nutrients',count=5,quality={name='normal'},spoil_tick=2000,spoil_percent=.5}
eq(S.inventory(inv{nutrient},{})[1].research_units,nil)

-- Freight keeps each quality's spoil-before-arrival count separate, and
-- clips each stack's value at zero before summing (never clamp an average).
local hub_inv=inv{stack(200,.9),stack(200,.5),stack(10,.25,'uncommon',nil,210600)}
local pl={force=force,state=3,speed=1,space_connection={from={name='nauvis'},to={name='gleba'},length=72000},distance=.5,schedule={current=1,records={{station='gleba'}}},hub={valid=true,get_inventory=function() return hub_inv end}}
local F=dofile(root..'freight.lua'){spoil=S,state=function() return {} end}
local lines=F.freshness(pl)
has(lines[1],'200 spoil before it, 200 arrive');has(lines[1],'at arrival 33.33')
has(lines[2],'0 spoil before it, 10 arrive');has(lines[2],'agricultural-science-pack@uncommon*10')
defines.inventory.hub_trash=7
local trash=inv{stack(4,.75)}
pl.hub.get_inventory=function(id) return id==7 and trash or hub_inv end
lines=F.freshness(pl)
has(lines[1],'agricultural-science-pack*404')
has(lines[1],'now 60.50, at arrival 33.50')
has(lines[1],'200 spoil before it, 204 arrive')
pl.speed=0
for _,line in ipairs(F.freshness(pl)) do assert(not line:find('at arrival',1,true)) end

-- The science read uses the existing scan and includes quality-only chests,
-- rocket cargo, belts, hands and partially used lab input, without a new find.
force.current_research={name='one-pack',research_unit_ingredients={{name=pack,amount=1}}}
force.get_item_production_statistics=function() return {get_flow_count=function() return 0 end} end
local surface={name='nauvis',index=1}
local entities={}
local function ent(type_,inventory)
  local e={valid=true,unit_number=#entities+1,type=type_,name=type_,position={x=#entities*4,y=0},force=force,surface=surface}
  e.get_inventory=function(id) return inventory[id] end
  e.get_output_inventory=function() return inventory[5] end
  entities[#entities+1]=e;return e
end
ent('lab',{[1]=inv{stack(1,.5,nil,.5)}})
ent('container',{[2]=inv{stack(3,.5)}})
local quality_chest=ent('container',{[2]=inv{stack(2,.25,'uncommon')}})
quality_chest.get_item_count=function(filter) eq(filter.name,pack);return 2 end
local empty_reads=0
local empty=ent('container',{[2]={valid=true,get_contents=function() empty_reads=empty_reads+1;return {} end}})
empty.get_item_count=function(filter) eq(filter.name,pack);return 0 end
ent('rocket-silo',{[3]=inv{stack(4,.75)}})
local belt=ent('transport-belt',{})
belt.get_item_count=function(filter) eq(filter.name,pack);return 1 end
belt.get_max_transport_line_index=function() return 1 end
belt.get_transport_line=function() return {get_contents=function() return {{name=pack,count=1}} end,get_detailed_contents=function() return {{stack=stack(1,.1)}} end} end
local hand=ent('inserter',{});hand.held_stack=stack(1,.2)
local finds=0
surface.find_entities_filtered=function() finds=finds+1;return entities end
game.surfaces={nauvis=surface}
local supply=dofile(root..'supply.lua'){spoil=S,status_name=function() return 'working' end}
local L=dofile(root..'labs.lua'){supply=supply,spoil=S,status_name=function() return 'working' end}
local result=L.science_fresh(surface,force,force.current_research,{[pack]=true},{pack})
eq(finds,1);eq(empty_reads,0)
local values=result.packs[1].effective_research_units
eq(#values,2);eq(values[1].count,10);near(values[1].now,4.45);eq(values[2].count,2);near(values[2].now,3)
eq(result.packs[1].chests,5);eq(result.packs[1].labs,1)
has(result.packs[1].line,'observed stacks on nauvis:')
has(result.packs[1].line,'effective research units now 4.45')
print('sciencevalue: ok')
