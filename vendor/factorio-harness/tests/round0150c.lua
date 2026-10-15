package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(s:find(t,1,true),s) end
prototypes={item={nutrients={spoil_result={name='spoilage'}},eggs={},plate={},belt={place_result={items_to_place_this={{name='belt',count=1}}}},
  rail={place_result={items_to_place_this={{name='rail',count=5}}}},landfill={place_as_tile_result={}}},entity={}}
-- Cleanup removes waste from each inventory but leaves live ingredients/products.
do
  local function inv(rows) return {get_contents=function() return rows end} end
  local inventories={assembling_machine_input=inv({{name='spoilage',count=4},{name='eggs',count=10}}),
    assembling_machine_output=inv({{name='spoilage',quality='uncommon',count=7},{name='plate',count=5}}),
    fuel=inv({{name='nutrients',count=10},{name='spoilage',count=3}}),burnt_result=inv({{name='spent-cell',count=1}})}
  local recipe={ingredients={{name='eggs'}},products={{name='plate'}}}
  local e={get_recipe=function() return recipe end}
  local calls={}
  local C=require('feedclean'){inventory=function(_,k) return inventories[k] end,take=function(_,_,inv,item,q,n)
    calls[#calls+1]={inv,item,q,n};return {transferred=inv=='assembling_machine_output' and 2 or n,inventory_full=inv=='assembling_machine_output'}
  end}
  eq(#C.pending(e),4)
  local rows=C.clear({},e)
  eq(#calls,4);eq(rows[2].quality,'uncommon');eq(rows[2].taken,2);eq(rows[2].left,5);eq(rows[2].inventory_full,true)
  eq(rows[1].taken,4);eq(rows[3].item,'spoilage');eq(rows[4].item,'spent-cell')
  recipe.ingredients={{name='spoilage'}};recipe.products={{name='spoilage'}}
  eq(#C.pending(e),2,'spoilage that is an ingredient/product stays')
end
-- Material counts are per quality, include queued output, multiply recipe yield,
-- use placement item counts, and do not mutate the inventory or start crafts.
do
  local counts={['belt@normal']=1,['belt@rare']=2}
  local p={force={recipes={}},get_main_inventory=function() return {get_item_count=function(q) return counts[q.name..'@'..q.quality] or 0 end} end,
    get_craftable_count=function() return 3 end}
  local M=require('materials'){queued=function(_,item) return item=='belt' and 2 or 0 end,
    recipe=function(_,item) if item=='belt' then return {products={{name='belt',amount=2}}} end end,known=function() return true end}
  local r=M.build(p,{item='belt',builds={{},{},{},{},{quality='rare'}}})
  eq(r[1].need,4);eq(r[1].held,1);eq(r[1].missing,3);eq(r[1].missing_after_queue,1);eq(r[1].hand_craftable,6)
  eq(r[2].held,2);eq(r[2].queued,0);eq(r[2].hand_craftable,0)
  eq(M.build(p,{item='rail'})[1].need,5)
  local tile=M.build(p,{item='landfill',size=3})[1];eq(tile.need,9);eq(tile.maximum,true)
  p.surface={find_entities_filtered=function(f)
    eq(f.limit,1025)
    return {{valid=true,ghost_name='belt',ghost_prototype=prototypes.item.belt.place_result,quality={name='rare'}},
      {valid=true,ghost_name='rail',ghost_prototype=prototypes.item.rail.place_result}}
  end}
  local r,ghosts=M.ghosts(p,{})
  eq(#ghosts,2);eq(r[1].quality,'rare');eq(r[2].need,5)
end
-- Current enemies are separate evidence from a past timer. Gun range does not
-- imply ammunition, activity, or a proven hatch. All reads are bounded/local.
do
  game={tick=6000};defines={inventory={turret_ammo=1}}
  local enemy={valid=true,name='big-wriggler-pentapod-premature',position={x=1,y=0}}
  local gun={valid=true,name='gun-turret',position={x=10,y=0},prototype={turret_range=18},active=false,
    get_inventory=function() return {get_item_count=function() return 0 end} end}
  local live=true
  local p={position={x=0,y=0},force={is_chunk_visible=function() return false end},surface={name='gleba'}}
  p.surface.find_entities_filtered=function(f)
    assert(f.radius and f.limit)
    if f.force=='enemy' then eq(f.radius,16);eq(f.limit,33);return live and {enemy} or {} end
    eq(f.radius,64);eq(f.limit,65);return {gun}
  end
  local E=require('eggnear'){}
  local sites={{surface='gleba',position={x=0,y=0},tick=5400}}
  local r=E.read(p,sites)
  has(r[1],'1 enemies visible within 16 tiles now');has(r[1],'recorded first-hatch timer elapsed 10s ago')
  has(r[1],'gun-turret (10,0) ammo 0 inactive')
  live=false;r=E.read(p,sites);has(r[1],'no enemies visible within 16 tiles now')
  sites[1].tick=6600;r=E.read(p,sites);has(r[1],'recorded first-hatch timer in 10s')
  p.position={x=100,y=0};eq(E.read(p,sites),nil)
end
print('round0150c: ok')
