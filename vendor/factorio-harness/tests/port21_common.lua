-- Real 2.1 defines omit the aliases. Exercise both sides of each machine-type branch.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={inventory={crafter_input=2,crafter_output=3},entity_status={}}
game={tick=6000}
local r={name='test',ingredients={{type='item',name='iron-plate',amount=2}},products={{type='item',name='gear',amount=1}}}
prototypes={recipe={test=r},item={['iron-plate']={}}}
local input={{valid_for_read=true,name='iron-plate',spoil_tick=6600}}
input.get_contents=function() return {{name='iron-plate',count=1,quality='normal'}} end
input.get_item_count=function() return 1 end
local output={get_contents=function() return {{name='gear',count=5,quality='normal'}} end,get_item_count=function() return 5 end}
local G=require('gap'){}
local A=require('makersall'){}
local U=require('uptime'){status_name=function() return 'item_ingredient_shortage' end}
local C=require('conditions'){position=function(p) return p end}
for _,kind in ipairs{'assembling-machine','furnace','rocket-silo'} do
 local e={type=kind,name=kind,position={x=0,y=0},valid=true,products_finished=0,get_recipe=function() return r,{name='normal'} end,
  get_inventory=function(id) assert(id==2 or id==3,'removed inventory ID'); return id==2 and input or output end}
 local p={surface={find_entities_filtered=function() return {e} end},force={}}
 local gap=G.machine(p,e); assert(gap.ingredients[1].held==1,kind..' gap')
 local all=A.row(e,r,'gear'); assert(all.inputs=='iron-plate 1/2' and all.output_holds==5,kind..' all makers')
 local m={e=e,recipe='test',recipe_quality='normal',status={},short={}}
 U.sample{samples=0,machines={m}}
 assert(m.short['iron-plate'].least==1,kind..' uptime input')
 if kind~='rocket-silo' then
  assert(m.out_last.gear.normal==5,kind..' uptime output')
  local met=C.check(p,{['until']='spoil_within',position=e.position,seconds=20})
  assert(met,kind..' spoil condition')
 end
end
print('port21: assembler/furnace/silo input, assembler/furnace output and spoil condition use common IDs')
