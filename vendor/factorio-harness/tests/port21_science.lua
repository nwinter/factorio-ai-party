package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function near(a,b) assert(math.abs(a-b)<1e-7,tostring(a)..' ~= '..tostring(b)) end
local pack='agricultural-science-pack'
local function removed(_,k) assert(k~='durability' and k~='get_durability','removed science API '..k) end
prototypes={item={[pack]=setmetatable({name=pack,type='item',science_capacity=1,get_spoil_ticks=function() return 216000 end},{__index=removed})},
 quality={normal={science_pack_drain_multiplier=1},rare={science_pack_drain_multiplier=.98}}}
local S=dofile('mod/agent-harness_0.1.0/spoil.lua'){}
game={tick=1000}; defines={inventory={lab_input=1,lab_trash=2},entity_status={working=1},flow_precision_index={ten_minutes=1}}
local st=setmetatable({name=pack,valid_for_read=true,count=2,quality={name='rare'},spoil_tick=100000,spoil_percent=.5},{__index=removed})
local inv={st};inv.valid=true;inv.get_contents=function() return {{name=pack,count=st.count,quality='rare'}} end
local v=S.inventory(inv,{})
near(v[1].research_units,1/.98)
local moved={}; S.add_count(moved,pack,'normal',2,.5,100000);near(moved[1].research_units,1)
-- Freshness is a product property in 2.1 and does not freshen a different product.
prototypes.item.other={name='other',get_spoil_ticks=function() return 10000 end}
local recipe={name='mixed',categories={'organic'},ingredients={},products={{name=pack,type='item',reset_freshness_on_craft=true},{name='other',type='item',percent_spoiled=.25}}}
local line=S.recipe_output(nil,recipe,{})
assert(line:find(pack..' start fresh',1,true) and line:find('other start 25% spoiled',1,true),line)
-- A lab retains capacity with no pack left in its inventory. Sampling a drain must still count it.
local stored=.75
local empty={get_contents=function() return {} end,get_item_count=function() return 0 end}
local force={name='player',laboratory_speed_modifier=0,current_research={name='test',research_unit_energy=3600,research_unit_ingredients={{name=pack,amount=1}}}}
local e={name='lab',type='lab',valid=true,unit_number=1,status=1,force=force,quality={name='normal'},speed_bonus=0,position={x=0,y=0},
 prototype={lab_inputs={pack},get_researching_speed=function() return 1 end,science_pack_drain_rate_percent=100},
 get_inventory=function() return empty end,get_stored_durability=function(n) assert(n==pack);return {durability=stored} end}
local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){}
local m={packs={},order={},trash_last={},spoiled={}}
U.sample_lab(m,e);near(m.packs[pack].d,.75)
game.tick=1060;stored=.74;U.sample_lab(m,e);near(m.packs[pack].used,.01);assert(m.packs[pack].empty==0)
-- Full-speed lab rates use science_capacity, without asking item prototypes for tool durability.
local R=dofile('mod/agent-harness_0.1.0/rates.lua'){}
local rate=R.compute({force=force},{e},'minute');near(rate.rows[1].consumed,1)
prototypes.item[pack].science_capacity=2
near(R.compute({force=force},{e},'minute').rows[1].consumed,.5)
-- Whole inventory stock remains zero; stored capacity is named separately, and the lab is not lacking.
local supply=dofile('mod/agent-harness_0.1.0/supply.lua'){spoil=S,status_name=function() return 'working' end}
local surface={name='test',index=1,find_entities_filtered=function() return {e} end};e.surface=surface
force.get_item_production_statistics=function() return {get_flow_count=function() return 0 end} end
game.surfaces={test=surface}
local L=dofile('mod/agent-harness_0.1.0/labs.lua'){supply=supply,spoil=S,status_name=function() return 'working' end}
local science=L.science_fresh(surface,force,force.current_research,{[pack]=true},{pack})
assert(science.packs[1].labs==0 and science.packs[1].labs_lacking==0)
near(science.packs[1].lab_stored_capacity,.74)
assert(science.packs[1].line:find('already consumed from inventory',1,true))
print('port21 science: item packs, quality, per-product freshness, partial lab capacity, shortage and rate reads passed')
