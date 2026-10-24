-- Run from the harness root: lua tests/d24_batch164.lua
-- d24 batch164 QG1 (viewer Aurora 13:15: "Could you check vehicle-item stock/where_is wording for stored vs placed scope,
-- link placed-vehicle lookup, and cover zero stored Spidertrons with two placed in a regression?"). stock, where_is and
-- supply count items in inventories; a placed spidertron is an entity. A vehicle item's reads now say both: N stored
-- (as items) and M placed (as vehicles), with where and the read that reads one.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s and tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

game={tick=7200}
defines={inventory={robot_cargo=9},flow_precision_index={ten_minutes=3}}
prototypes={item={
  spidertron={name='spidertron',place_result={name='spidertron',type='spider-vehicle'},get_spoil_ticks=function() return 0 end},
  locomotive={name='locomotive',place_result={name='locomotive',type='locomotive'},get_spoil_ticks=function() return 0 end},
  ['iron-plate']={name='iron-plate',get_spoil_ticks=function() return 0 end}},fluid={},recipe={},entity={}}
local nauvis={name='nauvis',index=1,find_entities_filtered=function() return {} end}
local gleba={name='gleba',index=4,find_entities_filtered=function() return {} end}
game.surfaces={nauvis=nauvis,gleba=gleba}
local counts={spidertron=2,locomotive=1}
local force={name='player',logistic_networks={},get_entity_count=function(n) return counts[n] or 0 end}
local function spider(x,y,n) return {valid=true,type='spider-vehicle',name='spidertron',force=force,surface=nauvis,position={x=x,y=y},unit_number=n,
  get_item_count=function() return 0 end} end
local spiders={spider(20.25,-3,102),spider(-40.5,12,101)}
-- game.get_vehicles: every vehicle of ours (cars, tanks, spidertrons, rolling stock), as 2.0.77 lists them
local loco={valid=true,name='locomotive',surface=gleba,position={x=5,y=7},unit_number=9}
local wagon={valid=true,name='cargo-wagon',surface=gleba,position={x=12,y=7},unit_number=10}
local vehicles={spiders[1],loco,spiders[2],wagon}
game.get_vehicles=function(f) eq(f.force,force); return vehicles end
local api={agents=function() return {} end,
  where_index=function(f,s) return {holders=s==nauvis and spiders or {},belts={},hands={},as_of=5400} end}
local S=dofile('mod/agent-harness_0.1.0/stores.lua')(api)
local p={surface=nauvis,force=force,position={x=0,y=0},index=1}

-- where_is: zero spidertron items stored, two spidertrons placed: read as such, not as none
do
  local r=S.where_is(p,{item='spidertron'})
  eq(r.total,0,'stored: no spidertron item in an inventory')
  eq(r.placed.count,2); eq(r.placed.by_surface.nauvis,2); eq(#r.placed.places,2)
  eq(r.placed.places[1].unit_number,101,'by surface, then x'); eq(r.placed.places[1].position.x,-40.5)
  eq(r.scope_line,'spidertron: 0 stored (as items, in inventories on nauvis), 2 placed (as vehicles: spidertron entities, not items): nauvis (-40.5,12) #101, nauvis (20.3,-3) #102; vehicle {position} (or remote: true, vehicle: its unit_number) reads its route; inspect {position} reads it in sight')
  eq(r.note,'none stored as items on this surface; 2 placed as vehicles (placed) (surface=NAME looks on another planet or platform)')
  has(r.scope,'placed: vehicles standing in the world, on every surface')
  eq(r.placed.not_listed,nil)
end
print('d24_batch164 QG1 where_is: 0 stored, 2 placed spidertrons: ok')

-- one the engine counts that the vehicle list does not give: said
do
  counts.spidertron=3
  local r=S.where_is(p,{item='spidertron'})
  eq(r.placed.count,3)
  has(r.scope_line,'3 placed (as vehicles: spidertron entities, not items): nauvis (-40.5,12) #101, nauvis (20.3,-3) #102; 1 not listed (not among the vehicles the game lists)')
  counts.spidertron=2
end
print('d24_batch164 QG1 where_is: a count past the list said: ok')

-- an item that places no vehicle: no scope line, the reply as before
do
  local r=S.where_is(p,{item='iron-plate'})
  eq(r.placed,nil); eq(r.scope_line,nil); eq(r.note,'none on this surface (surface=NAME looks on another planet or platform)')
  eq(S.placed(force,'iron-plate'),nil)
end
print('d24_batch164 QG1 where_is: other items unchanged: ok')

-- rolling stock: named with train {all}
do
  local pl=S.placed(force,'locomotive')
  eq(pl.count,1); eq(pl.by_surface.gleba,1)
  eq(pl.line,'1 placed (as vehicles: locomotive entities, not items): gleba (5,7) #9; train {all, surface} lists its train')
  -- none placed: no list read
  counts.locomotive=0
  game.get_vehicles=function() error('not read') end
  eq(S.placed(force,'locomotive').line,'0 placed (as vehicles: locomotive entities, not items)')
  game.get_vehicles=function(f) return vehicles end
  counts.locomotive=1
end
print('d24_batch164 QG1 placed: a locomotive in a train: ok')

-- stock: the total is what is stored; the scope line leads the summary
do
  local out=S.stock_scope(force,'spidertron',{item='spidertron',total=0,summary='0 spidertron on nauvis as a whole (live); within 128 tiles: none in our machine outputs and chests'})
  eq(out.summary,'spidertron: 0 stored (as items, this read\'s total), 2 placed (as vehicles: spidertron entities, not items): nauvis (-40.5,12) #101, nauvis (20.3,-3) #102; vehicle {position} (or remote: true, vehicle: its unit_number) reads its route; inspect {position} reads it in sight; stored: 0 spidertron on nauvis as a whole (live); within 128 tiles: none in our machine outputs and chests')
  eq(out.placed.count,2)
  local plain=S.stock_scope(force,'iron-plate',{item='iron-plate',total=5,summary='5 iron-plate'})
  eq(plain.summary,'5 iron-plate'); eq(plain.placed,nil)
  -- a network read (no total) is left as it is
  local net=S.stock_scope(force,'spidertron',{network=3,line='logistic network #3 on nauvis holds no spidertron'})
  eq(net.line,'logistic network #3 on nauvis holds no spidertron')
end
print('d24_batch164 QG1 stock: stored and placed side by side: ok')

-- supply: where leads with the scope line (and so the compact read's where line)
do
  nauvis.count_entities_filtered=function() return 0 end
  nauvis.planet={name='nauvis'}
  force.get_item_production_statistics=function() return {get_flow_count=function() return 0 end,get_input_count=function() return 0 end,get_output_count=function() return 0 end} end
  force.recipes, force.platforms = {}, {}
  defines.inventory={chest=1,crafter_input=2,crafter_output=3,fuel=4,robot_cargo=5,lab_input=6}
  defines.logistic_mode={active_provider=1,storage=2,requester=3,passive_provider=4,buffer=5}
  local U=require('supply'){status_name=function(e) return e.status end,position=function(v) return v end,integer=function(v,d) return v or d end,
    timed=function(_,fn,...) return fn(...) end,scope_line=function(...) return S.scope_line(...) end}
  local r=U.supply_fresh(nauvis,force,'spidertron')
  has(r.where,'spidertron: 0 stored (as items, on nauvis), 2 placed (as vehicles: spidertron entities, not items): nauvis (-40.5,12) #101')
  has(r.where,'; stored: none on nauvis')
  eq(r.placed.count,2)
  has(U.compact(r).lines[2],'where: spidertron: 0 stored (as items, on nauvis), 2 placed')
  local plain=U.supply_fresh(nauvis,force,'iron-plate')
  eq(plain.where,'none on nauvis'); eq(plain.placed,nil)
end
print('d24_batch164 QG1 supply: stored and placed side by side: ok')
game,defines,prototypes=nil,nil,nil
