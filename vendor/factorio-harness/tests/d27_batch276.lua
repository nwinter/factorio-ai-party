-- d27 batch276. Run from the harness root: lua tests/d27_batch276.lua
-- LN (Astra #2579, tick 72082849: labs said requester (91.5,113.5) had no logistic network; inspect showed network #243
-- with 110,299 cryogenic packs). labs looked the network up at the lab's centre. 2.0.77 on a copy of world n: the biolab
-- (91.5,117.5) stands 29.7 tiles from roboport (62,121), outside its logistic range (25) and inside its construction
-- range (55): find_logistic_network_by_position there gives none, while the chest's own logistic_network (and the
-- lookup at the chest) is #243; find_logistic_networks_by_construction_area at the lab gives #243.
-- 1. labs: the feeding requester's (or buffer's) own network; without one, the lab's, said as the lab's.
-- 2. dryrun's cliffs and a turret ghost's ammo: the networks whose construction area covers the spot.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
prototypes={item={['cryogenic-science-pack']={type='tool',stack_size=200}}}

-- ---- 1. labs ---------------------------------------------------------------------------------------------------------
local L=dofile('mod/agent-harness_0.1.0/labs.lua'){}
local net243={network_id=243,get_item_count=function(n) eq(n,'cryogenic-science-pack'); return 110299 end,
  select_pickup_point=function(a) eq(a.position.x,91.5); eq(a.position.y,113.5,'picked for the chest'); return {owner={name='storage-chest',position={x=51.5,y=67.5}}} end}
local function inventory(stacks) return {get_contents=function() return stacks end} end
local function chest(net,mode) return {name='requester-chest',type='logistic-container',position={x=91.5,y=113.5},logistic_network=net,
  prototype={logistic_mode=mode or 'requester'},get_output_inventory=function() return inventory({}) end,
  get_logistic_sections=function() return {sections={}} end} end
local lab={name='biolab',position={x=91.5,y=117.5},bounding_box={left_top={x=89.5,y=115.5},right_bottom={x=93.5,y=119.5}}}
local lookups={}
local function surface(src)
  local ins={name='fast-inserter',position={x=91.5,y=114.5},drop_target=lab,pickup_target=src}
  return {find_entities_filtered=function() return {ins} end,
    find_logistic_network_by_position=function(pos) lookups[#lookups+1]=pos; if pos.y<=115 then return net243 end return nil end}
end
local seen=function() return true end
local line=L.lab_why(lab,'cryogenic-science-pack',surface(chest(net243)),{},seen)
eq(line,'lab (91.5,117.5) lacks cryogenic-science-pack: fed by fast-inserter (91.5,114.5) from requester-chest (91.5,113.5) holding 0, no request for it; '
  ..'requester-chest (91.5,113.5)\'s logistic network #243 holds 110299, robots would take it from storage-chest (51.5,67.5)')
eq(#lookups,0,'the chest\'s own network: no lookup at the lab')
-- a buffer chest the same; a requester in no network says so
has(L.lab_why(lab,'cryogenic-science-pack',surface(chest(net243,'buffer')),{},seen),"requester-chest (91.5,113.5)'s logistic network #243 holds 110299")
eq(L.lab_why(lab,'cryogenic-science-pack',surface(chest(nil)),{},seen):match('; (.*)$'),'requester-chest (91.5,113.5) is in no logistic network')
-- a belt feeds it: the network at the lab, said as the lab's (none covers this one)
local belt={name='express-transport-belt',type='transport-belt',position={x=91.5,y=113.5},get_max_transport_line_index=function() return 2 end,
  get_transport_line=function() return {get_contents=function() return {} end} end}
eq(L.lab_why(lab,'cryogenic-science-pack',surface(belt),{},seen):match('; (.*)$'),'no logistic network covers the lab')
eq(lookups[#lookups].y,117.5)
local covered=surface(belt); covered.find_logistic_network_by_position=function() return net243 end
net243.select_pickup_point=function() return {owner={name='storage-chest',position={x=51.5,y=67.5}}} end
has(L.lab_why(lab,'cryogenic-science-pack',covered,{},seen),"; the lab's logistic network #243 holds 110299")
print('1. labs: the requester\'s own network #243, not the lab centre\'s none: ok')

-- ---- 2. a turret ghost's ammo: a network whose construction area covers it ---------------------------------------------
defines={inventory={turret_ammo=7,turret_modules=3}}
local T=dofile('mod/agent-harness_0.1.0/turretammo.lua'){state=function() return {} end}
local onlycon={find_logistic_network_by_position=function() return nil end,
  find_logistic_networks_by_construction_area=function() return {{network_id=243,get_item_count=function(n) return n=='firearm-magazine' and 4000 or 0 end}} end}
prototypes.item['firearm-magazine']={type='ammo',stack_size=200}
prototypes.item['piercing-rounds-magazine']={type='ammo',stack_size=200}
local t={items={'firearm-magazine','piercing-rounds-magazine'},count=10,slots=1}
local r=T.choose(t,onlycon,{},{x=91.5,y=117.5})
eq(r.name,'firearm-magazine'); eq(r.network_holds,4000)
r=T.choose(t,{find_logistic_network_by_position=function() return nil end,find_logistic_networks_by_construction_area=function() return {} end},{},{x=0,y=0})
eq(r.name,'firearm-magazine'); eq(r.network_holds,nil,'no network reaches it')
print('2. a turret ghost\'s ammo: the network whose construction area covers it: ok')
print('d27_batch276: ok')
