-- requester_rate (batch26 B2, Astra: lithium furnaces at 9/min against 49/min; each requester asked 10 over 80 tiles):
-- the request against the fed machines' use and the robots' round trip from the nearest stock.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
defines={logistic_member_index={logistic_container=1}}
prototypes={entity={['logistic-robot']={speed=0.05,max_payload_size=1}},recipe={['lithium-plate']={ingredients={{name='lithium',amount=1}},energy=6.4}}}
local force={worker_robots_speed_modifier=0,worker_robots_storage_bonus=3}
local provider={valid=true,name='passive-provider-chest',position={x=80.5,y=0.5},get_item_count=function() return 139 end}
local net={select_pickup_point=function(f) eq(f.name,'lithium'); return {owner=provider} end}
local chest={valid=true,unit_number=1,name='requester-chest',position={x=0.5,y=0.5},force=force,bounding_box={left_top={x=0,y=0},right_bottom={x=1,y=1}},
  prototype={logistic_mode='requester'},logistic_network=net,get_item_count=function() return 3 end,
  get_logistic_point=function() return {filters={{name='lithium',count=10}}} end}
local furnace={valid=true,unit_number=2,name='electric-furnace',crafting_speed=2,get_recipe=function() return nil end,previous_recipe={name='lithium-plate'}}
local ins={valid=true,pickup_target=chest,drop_target=furnace}
local ins2={valid=true,pickup_target=chest,drop_target={valid=true,unit_number=3,name='electric-furnace',crafting_speed=2,get_recipe=function() return prototypes.recipe['lithium-plate'] end}}
chest.surface={find_entities_filtered=function(f) eq(f.type,'inserter'); return {ins,ins2} end}
local R=require('reqrate'){position=function(v) return v end,entity=function() return chest end}
local r=R.read({force=force},{position={x=0.5,y=0.5}})
eq(#r.rows,1); local row=r.rows[1]
eq(row.use_per_min,37.5); eq(row.from.distance,80); eq(row.round_trip_s,53.3); eq(row.most_per_min,11.3); eq(row.covers_min,0.3)
has(r.lines[1],'requester-chest (0.5,0.5) lithium: asks 10, holds 3; used 37.5/min by 2 electric-furnace')
has(r.lines[1],'passive-provider-chest (80.5,0.5), 80 tiles, holding 139')
has(r.lines[1],'at most 10 a round trip, about 11.3/min; the request covers 0.3 min of use')
print('reqrate: ok')
