-- Run from repository root: lua tests/stock.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={chest=1,cargo_landing_pad_main=2},direction={north=0}}
prototypes={item={pipe={},coal={}}}
game={tick=0}
local function inv(item,n)
  return {get_item_count=function(f) return f.name==item and n or 0 end,
    get_contents=function() return n>0 and {{name=item,quality='normal',count=n}} or {} end}
end
local function crafter(x,n,recipe)
  local e={valid=true,name='assembling-machine-1',type='assembling-machine',position={x=x,y=0}}
  e.out=inv('pipe',n)
  e.get_output_inventory=function() return e.out end
  e.get_recipe=function() return recipe and {products={{type='item',name=recipe}}} end
  return e
end
local chest={valid=true,name='wooden-chest',type='container',position={x=-5,y=0},get_inventory=function() return inv('pipe',7) end}
local world={crafter(20,100,'pipe'),crafter(10,0,'pipe'),crafter(30,50,'pipe'),chest,crafter(4,0,'iron-gear-wheel')}
local p={position={x=0,y=0},force={},reach_distance=10}
local reachable={}
p.can_reach_entity=function(e) return reachable[e]==true end
p.get_main_inventory=function() return inv('pipe',3) end
p.surface={find_entities_filtered=function(f)
  local out={}
  local types={}
  for _,t in ipairs(f.type or {}) do types[t]=true end
  for _,e in ipairs(world) do
    if math.abs(e.position.x-f.position.x)<=f.radius and (f.type==nil or types[e.type]) then out[#out+1]=e end
  end
  return out
end}
local distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
local taken,paths,navs={},0,{}
local api={distance=distance,position=function(v) return v end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(v>=lo and v<=hi,name..' out of range'); return v end,
  take=function(_,e,item,_,count)
    local have=e.type=='container' and 7 or e.out.get_item_count{name=item}
    local n=math.min(have,count); taken[#taken+1]=e.position.x..':'..n
    return {transferred=n}
  end,
  request_path=function() paths=paths+1 end,
  navigate=function(_,nav) navs[#navs+1]=nav.position.x end,
  stop_walking=function() end}
local stock=dofile('mod/agent-harness_0.1.0/stock.lua')(api)
-- scan: nearest first, grouped, with the crafters set to the recipe.
local s=stock.scan(p,'pipe',{radius=64})
eq(s.total,157); eq(#s.places,3); eq(s.places[1].name,'wooden-chest'); eq(s.places[2].position.x,20)
eq(s.groups[1].name,'assembling-machine-1'); eq(s.groups[1].count,150); eq(s.groups[1].entities,2)
eq(s.makers['assembling-machine-1'],3)
local line=stock.line(s)
assert(line:find('157 pipe held by our factory (150 in 2 assembling-machine-1, 7 in 1 wooden-chest); nearest 7 at (-5,0) 5 tiles away; largest 100 in assembling-machine-1 at (20,0) 20 tiles away; collect item=pipe radius=32',1,true),line)
eq(stock.scan(p,'pipe',{radius=15}).total,7)
eq(stock.line(stock.scan(p,'coal',{radius=64})),nil)
-- view: rows, limit and inventory.
local v=stock.view(p,{item='pipe',limit=2})
eq(#v.places,2); eq(v.more,1); eq(v.held,3); eq(v.places[2].distance,20)
assert(not pcall(stock.view,p,{item='nope'}))
-- view without an item (shake2: "item must be a known item name"): every
-- item held, largest first, with how many entities and chests hold it.
local copper={valid=true,name='iron-chest',type='container',position={x=8,y=0},get_inventory=function() return inv('copper-plate',200) end}
world[#world+1]=copper
local all=stock.view(p,{})
eq(#all.items,2); eq(all.items[1],'copper-plate 200 in 1 entity (1 chest)'); eq(all.items[2],'pipe 157 in 3 entities (1 chest)')
eq(all.radius,128); eq(all.more,nil); assert(all.note:find('item=NAME',1,true),all.note)
local top=stock.view(p,{limit=1}); eq(#top.items,1); eq(top.more,1)
eq(#stock.view(p,{radius=6}).items,1)
table.remove(world)
-- The stock line says when a chest holds some, so the collect hint includes chests=true.
assert(line:find('radius=32 chests=true gathers it',1,true),line)
-- gather: nearest-neighbour route from the character, walking where out of reach.
-- Chests are skipped unless chests=true: the trip reports what it leaves there.
local no_chests,info=stock.start(p,{item='pipe',radius=40,count=120},600)
eq(info.stock,150); eq(info.places,2); eq(info.left_in_chests,7); eq(no_chests.targets[1].position.x,20)
local action,out=stock.start(p,{item='pipe',radius=40,count=120,chests=true},600)
eq(out.stock,157); eq(out.places,3); eq(out.left_in_chests,nil)
eq(action.targets[1].position.x,-5); eq(action.targets[2].position.x,20); eq(action.targets[3].position.x,30)
reachable[chest]=true
eq(stock.tick(p,action),nil); eq(taken[1],'-5:7'); eq(action.got,7); eq(navs[1],20); eq(paths,1)
reachable[world[1]]=true
eq(stock.tick(p,action),nil); eq(taken[2],'20:100'); eq(navs[2],30)
reachable[world[3]]=true
eq(stock.tick(p,action),'collected'); eq(taken[3],'30:13'); eq(action.got,120)
-- Stock inside another agent's board claim stays put; the result names the claim.
storage={agent_harness={board={items={{id=4,kind='claim',status='claimed',owner='sol',title='sol mall',area={left_top={x=-10,y=-5},right_bottom={x=-1,y=5}}},
  {id=5,kind='claim',status='claimed',owner='me',title='mine',area={left_top={x=15,y=-5},right_bottom={x=25,y=5}}}}}}}
api.claims=dofile('mod/agent-harness_0.1.0/claims.lua'){state=function() return storage.agent_harness end}
p.name='me'; p.surface.name='nauvis'
local claimed,cinfo=stock.start(p,{item='pipe',radius=40,count=120,chests=true},600)
eq(cinfo.places,2); eq(claimed.targets[1].position.x,20)
eq(cinfo.skipped_claims[1],'7 pipe in 1 places of #4 sol mall (claim by sol; posted 0s ago, owner active on it 0s ago); ask the owner')
-- A claim that allows me, or a stale one (30 min with no activity by its owner), keeps nothing from me.
local sol_claim=storage.agent_harness.board.items[1]
sol_claim.allow={'me'}
claimed,cinfo=stock.start(p,{item='pipe',radius=40,count=120,chests=true},600)
eq(cinfo.places,3); eq(cinfo.skipped_claims,nil)
sol_claim.allow=nil; sol_claim.created_tick=0; sol_claim.active_tick=0
game.tick=108000
claimed,cinfo=stock.start(p,{item='pipe',radius=40,count=120,chests=true},600)
eq(cinfo.places,3); eq(cinfo.skipped_claims,nil)
game.tick=107999
claimed,cinfo=stock.start(p,{item='pipe',radius=40,count=120,chests=true},600)
eq(cinfo.places,2)
game.tick=0
-- A claim on another surface keeps nothing here (Sol 07:52: a Nauvis claim labelled Gleba furnaces).
sol_claim.surface='gleba'; sol_claim.created_tick=0; sol_claim.active_tick=0
claimed,cinfo=stock.start(p,{item='pipe',radius=40,count=120,chests=true},600)
eq(cinfo.places,3,'the gleba claim is not here'); eq(cinfo.skipped_claims,nil)
api.claims=nil
-- nothing held: an empty route ends at once.
action=stock.start(p,{item='coal',radius=40},600)
eq(stock.tick(p,action),'nothing_collected')
-- a full inventory ends the trip.
api.take=function() return {transferred=2,inventory_full={blocked_item='pipe'}} end
action=stock.start(p,{item='pipe',radius=40},600)
eq(stock.tick(p,action),'inventory_full')
-- Tours visit given entities nearest-first and top each up via api.visit.
local visits={}
api.visit=function(_,action,e) visits[#visits+1]=e.position.x; return {transferred=5,stop=#visits==2 and action.stop_at_two and 'out_of_items' or nil} end
local t1,t2,t3={valid=true,position={x=9,y=0}},{valid=true,position={x=3,y=0}},{valid=true,position={x=6,y=0}}
reachable={[t1]=true,[t2]=true,[t3]=true}
local tour,info=stock.start_tour(p,'rearm',{t1,t2,t3},600,{item='firearm-magazine',count=10})
eq(info.places,3); eq(info.op,'rearm')
eq(stock.tick(p,tour),'topped_up'); eq(table.concat(visits,','),'3,6,9'); eq(tour.got,15); eq(tour.visited,3)
visits={}
tour=stock.start_tour(p,'refuel',{t1,t2,t3},600,{item='coal',count=5,stop_at_two=true})
eq(stock.tick(p,tour),'out_of_items'); eq(#visits,2)
eq(stock.tick(p,stock.start_tour(p,'refuel',{},600,{item='coal'})),'nothing_to_do')
-- Every tour walks with the enemy check (round1950a, Haiku 45h02m: a rearm tour walked into attack #1550 and died;
-- its cluster lay in attack #1548): avoid_enemies as move_to's (default on; false: none), and a place inside a
-- reach is left out and named unless unsafe_goal.
do
  local kv,kc,kt,km,ks,kr=api.visit,api.goal_check,api.goal_text,api.avoid_mode,api.avoid_start,reachable
  local visited,started={},0
  api.visit=function(_,_,e) visited[#visited+1]=e.position.x; return {transferred=5} end
  api.avoid_mode=function(v) if v==false then return nil end return {pad=4,spawners=true,attacks=true,v=v} end
  api.goal_check=function(_,_,goal) if goal.x==30 then return {m={name='attack #1548',attack=true,x=30,y=4,range=24},d=4} end end
  api.goal_text=function(label,goal) return label..' ('..goal.x..','..goal.y..') is within 24 tiles of attack #1548 at (30,4)' end
  api.avoid_start=function() started=started+1 end
  local a1,a2,a3={valid=true,position={x=3,y=0}},{valid=true,position={x=30,y=0}},{valid=true,position={x=40,y=0}}
  reachable={[a1]=true,[a3]=true}
  local tour,info=stock.start_tour(p,'rearm',{a1,a2,a3},600,{item='firearm-magazine',count=10})
  eq(tour.avoid_mode.pad,4); eq(tour.avoid_enemies,nil)
  for _=1,4 do if stock.tick(p,tour) then break end end
  eq(table.concat(visited,','),'3,40','the place in the attack left out'); eq(tour.danger,1)
  eq(tour.dangers[1],'place (30,0) is within 24 tiles of attack #1548 at (30,4)')
  eq(tour.first_unreached,'(30,0): place (30,0) is within 24 tiles of attack #1548 at (30,4) (unsafe_goal: true walks there)')
  -- unsafe_goal walks there; avoid_enemies=false has no check
  visited={}; reachable={[a1]=true,[a3]=true}
  tour=stock.start_tour(p,'rearm',{a1,a2,a3},600,{item='firearm-magazine',count=10,unsafe_goal=true})
  stock.tick(p,tour); eq(tour.danger,nil); assert(tour.nav and tour.nav.position.x==30,'walks to the place in the attack')
  tour=stock.start_tour(p,'rearm',{a1},600,{item='firearm-magazine',avoid_enemies=false}); eq(tour.avoid_mode,nil)
  tour=stock.start_tour(p,'rearm',{a1},600,{item='firearm-magazine',avoid_enemies=true}); eq(tour.avoid_mode.v,true)
  api.visit,api.goal_check,api.goal_text,api.avoid_mode,api.avoid_start,reachable=kv,kc,kt,km,ks,kr
end
-- round2120a (Haiku, shift14 03:58: rearm surface=true walked into a big worm's range): every stop is checked at the
-- call too: one inside a reach is left out and named (left_out), none left refuses; a courier with either place in
-- one is refused; screened (the caller checked them) and unsafe_goal skip the check.
do
  local km,ki,kt=api.avoid_mode,api.goal_inside,api.goal_text
  api.avoid_mode=function(v) if v==false then return nil end return {pad=4,spawners=true,attacks=true} end
  api.goal_inside=function(_,goal) if goal.x==30 then return {m={name='big-worm-turret',x=40,y=0,range=38},d=10} end end
  api.goal_text=function(label,goal) return label..' ('..goal.x..','..goal.y..') is inside big-worm-turret (40,0) range 38 (10.0 tiles from it)' end
  local a1,a2,a3={valid=true,name='gun-turret',position={x=3,y=0}},{valid=true,name='gun-turret',position={x=30,y=0}},{valid=true,name='gun-turret',position={x=50,y=0}}
  local tour,out=stock.start_tour(p,'rearm',{a1,a2,a3},600,{item='firearm-magazine',count=10})
  eq(out.places,2); eq(#tour.targets,2); eq(tour.targets[2].entity,a3)
  eq(out.left_out[1],'gun-turret (30,0) is inside big-worm-turret (40,0) range 38 (10.0 tiles from it)'); eq(out.left_out_more,nil)
  eq(tour.left_out[1],out.left_out[1]); eq(tour.left_out_count,1)
  tour,out=stock.start_tour(p,'rearm',{a1,a2,a3},600,{item='firearm-magazine',screened=true}); eq(out.places,3); eq(out.left_out,nil); eq(tour.screened,nil)
  tour,out=stock.start_tour(p,'rearm',{a1,a2,a3},600,{item='firearm-magazine',unsafe_goal=true}); eq(out.places,3); eq(out.left_out,nil)
  tour,out=stock.start_tour(p,'rearm',{a1,a2,a3},600,{item='firearm-magazine',avoid_enemies=false}); eq(out.places,3)
  local ok,err=pcall(stock.start_tour,p,'rearm',{a2},600,{item='firearm-magazine'})
  assert(not ok and tostring(err):find('every place of this tour lies in enemy reach the map shows: gun-turret (30,0) is inside big-worm-turret (40,0) range 38 (10.0 tiles from it) [1 held by a worm or spawner (it stays: unsafe_goal: true goes anyway)]: unsafe_goal: true to go anyway',1,true),tostring(err))
  -- Nine left out: the first 8 named, the rest counted.
  local many={}
  for i=1,9 do many[i]={valid=true,name='gun-turret',position={x=30,y=i}} end
  many[10]=a1
  tour,out=stock.start_tour(p,'rearm',many,600,{item='firearm-magazine',ordered=true})
  eq(out.places,1); eq(#out.left_out,8); eq(out.left_out_more,1); eq(tour.left_out_count,9)
  -- A courier goes to both places or none.
  ok,err=pcall(stock.start_legs,p,{{entity=a1,position=a1.position},{position={x=30,y=0}}},600,{item='pipe'})
  assert(not ok and tostring(err):find('a place of this courier lies in enemy reach the map shows: place (30,0) is inside big-worm-turret (40,0) range 38 (10.0 tiles from it): unsafe_goal: true to go anyway',1,true),tostring(err))
  eq(stock.start_legs(p,{{entity=a1,position=a1.position},{position={x=30,y=0}}},600,{item='pipe',unsafe_goal=true}).unsafe_goal,true)
  -- collect with a radius: the assembler at (30,0) left out.
  local action,o=stock.start(p,{item='pipe',radius=64},600)
  eq(o.places,1); eq(action.targets[1].position.x,20); eq(o.left_out[1],'assembling-machine-1 (30,0) is inside big-worm-turret (40,0) range 38 (10.0 tiles from it)')
  api.avoid_mode,api.goal_inside,api.goal_text=km,ki,kt
end
-- A courier whose take fails goes no further (round1650d: Luna's walked on to the give): failed, with the first error.
do
  local kept=api.visit
  local given=0
  api.visit=function(_,action,e) if action.index==1 then error('inventory is not applicable to this entity type') end given=given+1; return {transferred=5} end
  local legs=stock.start_legs(p,{{entity=t1,position=t1.position},{entity=t2,position=t2.position}},600,{transfer={direction='to_player'},legs={{},{}},item='coal',rows={},items={}})
  legs.op='transfer'
  eq(stock.tick(p,legs),'failed'); eq(given,0,'no give'); eq(legs.index,2)
  assert(legs.first_error:find('inventory is not applicable',1,true),legs.first_error)
  api.visit=kept
end
-- Waiting at a machine (Muse, operator 09:31: a collect from a machine's output lost to its output inserters about
-- four times): take each product the tick it is in the output, for up to wait ticks or count; the report weighs
-- what was taken against what the machine made and its inserters took.
do
  prototypes.item['iron-gear-wheel']={}
  local out={n=4}
  local gears={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=6,y=0},force=p.force,products_finished=100}
  out.get_item_count=function(f) return f.name=='iron-gear-wheel' and out.n or 0 end
  out.get_contents=function() return out.n>0 and {{name='iron-gear-wheel',quality='normal',count=out.n}} or {} end
  out.is_empty=function() return out.n==0 end
  gears.get_output_inventory=function() return out end
  gears.get_recipe=function() return {name='iron-gear-wheel',products={{type='item',name='iron-gear-wheel',amount=1}}} end
  local took=0
  local api2={}
  for k,v in pairs(api) do api2[k]=v end
  api2.take=function(_,e,item,_,count,inv)
    assert(inv=='assembling_machine_output','the output only')
    local n=math.min(out.n,count); out.n=out.n-n; took=took+n
    return {transferred=n,items={{name='iron-gear-wheel',count=n}}}
  end
  local W=dofile('mod/agent-harness_0.1.0/stock.lua')(api2)
  local fp={position={x=0,y=0},force=p.force,reach_distance=10,can_reach_entity=function() return true end}
  game.tick=1000
  local action,reply=W.start_wait(fp,{},gears,300)
  eq(reply.machine,'assembling-machine-2 (6,0)'); eq(reply.recipe,'iron-gear-wheel'); eq(reply.wait_ticks,300); eq(reply.in_reach,true)
  eq(action.kind,'gather'); eq(action.until_tick,1000+3600+300)
  -- An inserter picking from the output: what it grabs shows in its hand (counted each tick, stock.lua watch).
  local hand={valid_for_read=false}
  local grabber={valid=true,name='inserter',unit_number=77,pickup_target=gears,held_stack=hand}
  gears.surface={find_entities_filtered=function(f) eq(f.type,'inserter'); return {grabber} end}
  gears.bounding_box={left_top={x=4.5,y=-1.5},right_bottom={x=7.5,y=1.5}}
  -- First tick in reach: the 4 in the output are taken.
  eq(W.tick(fp,action),nil); eq(action.got,4); eq(took,4)
  -- The machine finishes 10 gears over the wait; the inserter grabs 3 of them before the character's next tick, each
  -- time swinging away with it (its hand empty again a tick later).
  local function craft(k,stolen)
    gears.products_finished=gears.products_finished+k; out.n=out.n+k-stolen
    hand.valid_for_read=stolen>0; hand.name=stolen>0 and 'iron-gear-wheel' or nil; hand.count=stolen
  end
  for i=1,7 do game.tick=game.tick+1; craft(1,0); eq(W.tick(fp,action),nil) end
  for i=1,3 do
    game.tick=game.tick+1; craft(1,1); eq(W.tick(fp,action),nil)
    game.tick=game.tick+1; craft(0,0); eq(W.tick(fp,action),nil)
  end
  eq(action.got,11)
  game.tick=1000+300
  eq(W.tick(fp,action),'collected')
  local r=W.wait_report(action)
  eq(r.took,'iron-gear-wheel*11'); eq(r.crafts,10); eq(r.made,'iron-gear-wheel*10'); eq(r.inserters_took,'iron-gear-wheel*3'); eq(r.waited_s,5)
  eq(r.why,nil,'it took some'); eq(r.left_otherwise,nil); eq(r.chance,nil)
  -- Sol's iron-bacteria (shift12 12:41): 16 crafts in 50 s, each 4 spoilage and iron-bacteria by a 10% chance; the
  -- output inserter takes spoilage only, and none of the 16 made iron-bacteria. Counted, not estimated.
  prototypes.item['iron-bacteria']={}; prototypes.item.spoilage={}
  gears.products_finished=500; out.n=0; hand.valid_for_read=false
  gears.get_recipe=function() return {name='iron-bacteria',products={{type='item',name='iron-bacteria',amount=1,probability=0.1},
    {type='item',name='spoilage',amount=4}}} end
  local spoil=0
  out.get_item_count=function(f) return f.name=='spoilage' and spoil or 0 end
  out.get_contents=function() return spoil>0 and {{name='spoilage',quality='normal',count=spoil}} or {} end
  out.is_empty=function() return spoil==0 end
  game.tick=5000
  action=W.start_wait(fp,{item='iron-bacteria',count=1},gears,3000)
  W.tick(fp,action)
  for i=1,16 do
    game.tick=game.tick+1; gears.products_finished=gears.products_finished+1; spoil=spoil+4; W.tick(fp,action)
    game.tick=game.tick+1; spoil=spoil-4; hand.valid_for_read=true; hand.name='spoilage'; hand.count=4; W.tick(fp,action)
    game.tick=game.tick+1; hand.valid_for_read=false; W.tick(fp,action)
  end
  game.tick=5000+3000
  eq(W.tick(fp,action),'nothing_collected')
  r=W.wait_report(action)
  eq(r.took,'none'); eq(r.crafts,16); eq(r.made,'spoilage*64'); eq(r.inserters_took,'spoilage*64')
  eq(r.chance,'iron-bacteria comes from 10% of crafts')
  eq(r.why,'the machine made no iron-bacteria in 50 s (16 crafts); iron-bacteria comes from 10% of crafts: about 1.6 expected')
  -- One made and taken by the inserter's hand: said so.
  game.tick=9000
  action=W.start_wait(fp,{item='iron-bacteria',count=1},gears,600)
  W.tick(fp,action)
  game.tick=game.tick+1; gears.products_finished=gears.products_finished+1; hand.valid_for_read=true; hand.name='iron-bacteria'; hand.count=1
  W.tick(fp,action)
  game.tick=9000+600; W.tick(fp,action)
  eq(W.wait_report(action).why,'the machine made 1 iron-bacteria; its output inserters took 1')
  hand.valid_for_read=false
  gears.get_recipe=function() return {name='iron-gear-wheel',products={{type='item',name='iron-gear-wheel',amount=1}}} end
  out.get_item_count=function(f) return f.name=='iron-gear-wheel' and out.n or 0 end
  out.get_contents=function() return out.n>0 and {{name='iron-gear-wheel',quality='normal',count=out.n}} or {} end
  out.is_empty=function() return out.n==0 end
  -- count ends it early; an empty output costs no take.
  out.n=2; gears.products_finished=200; took=0
  action=W.start_wait(fp,{count=2},gears,300)
  eq(W.tick(fp,action),'collected'); eq(took,2)
  out.n=0
  action=W.start_wait(fp,{item='iron-gear-wheel'},gears,5)
  local calls=0; api2.take=function() calls=calls+1; return {transferred=0} end
  for i=1,5 do game.tick=game.tick+1; W.tick(fp,action) end
  game.tick=game.tick+1
  eq(calls,0); eq(W.tick(fp,action),'nothing_collected')
  -- Out of reach: it walks there first; not an assembler or furnace, not ours: refused.
  fp.can_reach_entity=function() return false end
  action=W.start_wait(fp,{},gears,300)
  local paths0=paths
  eq(W.tick(fp,action),nil); eq(paths,paths0+1); eq(action.waiting,nil)
  local ok,err=pcall(W.start_wait,fp,{},{valid=true,name='wooden-chest',type='container',position={x=1,y=1},force=p.force},10)
  assert(not ok and tostring(err):find('wooden-chest is no assembler or furnace',1,true),err)
  ok,err=pcall(W.start_wait,fp,{},{valid=true,name='assembling-machine-1',type='assembling-machine',position={x=1,y=1},force={}},10)
  assert(not ok and tostring(err):find('is not ours',1,true),err)
end
print('stock: ok')

-- Feed tours use the shared avoidance legs and retain the no-route diagnostic
-- before discarding a stop's nav (Haiku's former bare no_safe_route).
do
  local oldnav,oldavoid,oldreport,oldleg,oldmode=api.navigate,api.avoid_start,api.avoid_report,api.leg_done,api.avoid_mode
  local saved_reachable=reachable
  reachable={}
  local legs=0
  api.avoid_mode=function() return {pad=4} end
  api.avoid_start=function(_,nav) nav.foes={mode={pad=4}} end
  api.navigate=function() return legs==0 and 'arrived' or 'no_safe_route' end
  api.leg_done=function(_,nav,outcome) if outcome=='arrived' then legs=legs+1;return true end end
  api.avoid_report=function(out) out.why='no route at margin 4';out.smaller_margins={largest_verified_margin=2,line='largest verified margin 2 tiles'} end
  local e={valid=true,position={x=40,y=0}}
  local tour=stock.start_tour(p,'feed',{e},600,{item='coal',count=10})
  stock.tick(p,tour);eq(tour.index,1);eq(legs,1)
  stock.tick(p,tour);eq(tour.index,2);eq(tour.route_failures[1].smaller_margins.largest_verified_margin,2)
  assert(tour.first_unreached:find('largest verified margin 2 tiles',1,true))
  api.navigate,api.avoid_start,api.avoid_report,api.leg_done,api.avoid_mode=oldnav,oldavoid,oldreport,oldleg,oldmode
  reachable=saved_reachable
end

-- collect wait_ticks at several machines (Sonnet 00:20): it stands at the first and takes from the others it reaches
-- from there too (action.also); one out of reach is named in the report, not walked to.
do
  prototypes.item['copper-cable']={}
  local function machine(x,n)
    local o={n=n}
    o.get_item_count=function(f) return f.name=='copper-cable' and o.n or 0 end
    o.get_contents=function() return o.n>0 and {{name='copper-cable',quality='normal',count=o.n}} or {} end
    o.is_empty=function() return o.n==0 end
    local m={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=x,y=0},force=p.force,products_finished=0,out=o,
      bounding_box={left_top={x=x-1.5,y=-1.5},right_bottom={x=x+1.5,y=1.5}},surface={find_entities_filtered=function() return {} end}}
    m.get_output_inventory=function() return o end
    m.get_recipe=function() return {name='copper-cable',products={{type='item',name='copper-cable',amount=2}}} end
    return m
  end
  local first,second,far=machine(2,4),machine(8,6),machine(40,9)
  local api3={}
  for k,v in pairs(api) do api3[k]=v end
  api3.take=function(_,e,item,_,count)
    local n=math.min(e.out.n,count); e.out.n=e.out.n-n
    return {transferred=n,items={{name='copper-cable',count=n}}}
  end
  local W=dofile('mod/agent-harness_0.1.0/stock.lua')(api3)
  local fp={position={x=0,y=0},force=p.force,reach_distance=10,can_reach_entity=function(e) return e~=far end}
  game.tick=2000
  local action=W.start_wait(fp,{item='copper-cable'},first,60)
  action.also={second,far}
  eq(W.tick(fp,action),nil); eq(action.got,10,'4 from the first, 6 from the second')
  second.out.n=2; second.products_finished=1
  game.tick=2001; eq(W.tick(fp,action),nil); eq(action.got,12)
  eq(far.out.n,9,'the far one is not taken from')
  game.tick=2000+61
  eq(W.tick(fp,action),'collected')
  local r=W.wait_report(action)
  eq(r.also,'from the others: assembling-machine-2 (8,0) 8; out of reach from where it stood: assembling-machine-2 (40,0)')
  eq(r.took,'copper-cable*12')
end
print('stock collect at several machines: ok')
-- collect follow during the wait (d16 batch10 D1, Sol 00:20: a barrel sat in an output chest out of reach): a chest in
-- reach is taken from; one out of reach becomes where the wait stands; a walk there that fails ends unreached, saying so.
do
  local function machine(x,n)
    local o={n=n}
    o.get_item_count=function(f) return f.name=='copper-cable' and o.n or 0 end
    o.get_contents=function() return o.n>0 and {{name='copper-cable',quality='normal',count=o.n}} or {} end
    o.is_empty=function() return o.n==0 end
    local m={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=x,y=0},force=p.force,products_finished=0,out=o,
      bounding_box={left_top={x=x-1.5,y=-1.5},right_bottom={x=x+1.5,y=1.5}},surface={find_entities_filtered=function() return {} end}}
    m.get_output_inventory=function() return o end
    m.get_recipe=function() return {name='copper-cable',products={{type='item',name='copper-cable',amount=2}}} end
    return m
  end
  local function chest(x,n)
    local c=machine(x,n); c.type='container'; c.name='iron-chest'
    c.get_inventory=function() return c.out end
    return c
  end
  local m,near,far=machine(2,0),chest(4,3),chest(30,5)
  local api4={}
  for k,v in pairs(api) do api4[k]=v end
  api4.take=function(_,e,item,_,count)
    local n=math.min(e.out.n,count); e.out.n=e.out.n-n
    return {transferred=n,items={{name='copper-cable',count=n}}}
  end
  local walked
  api4.request_path=function() end; api4.stop_walking=function() end
  api4.navigate=function(_,nav) walked=nav.position; return 'unreachable' end
  local W=dofile('mod/agent-harness_0.1.0/stock.lua')(api4)
  local chests={{entity=near,name=near.name,position=near.position},{entity=far,name=far.name,position=far.position}}
  W.output_takers=function() return {chests=chests,line='1 inserter'} end
  local fp={position={x=0,y=0},force=p.force,reach_distance=10,can_reach_entity=function(e) return e~=far end}
  game.tick=5000
  local action=W.start_wait(fp,{item='copper-cable'},m,600)
  action.follow=true
  eq(W.tick(fp,action),nil); eq(action.got,3,'the chest in reach')
  eq(action.targets[1].entity,far,'the far one holding it: the wait stands there now')
  game.tick=5001; eq(W.tick(fp,action),'collected','3 taken before the walk'); eq(walked.x,30)
  assert(action.why:find('its output inserters put copper-cable into iron-chest (30,0), out of reach: the wait walked there and takes from it; the walk to it ended unreachable out of reach',1,true),action.why)
end
print('stock collect follow during the wait: ok')
-- collect wait_ticks with to (batch26 C4, Grok: nutrients taken by robots from a provider within 5 s, a craft lost
-- several times an hour): each take from the output goes the same tick into the other machine by hand; one out of reach
-- from where the wait stands ends it unreached, saying so; a give that moves fewer says what stayed.
do
  prototypes.item.nutrients={}
  local o={n=0}
  o.get_item_count=function(f) return f.name=='nutrients' and o.n or 0 end
  o.get_contents=function() return o.n>0 and {{name='nutrients',quality='normal',count=o.n}} or {} end
  o.is_empty=function() return o.n==0 end
  local maker={valid=true,name='biochamber',type='assembling-machine',position={x=2,y=0},force=p.force,products_finished=0,
    bounding_box={left_top={x=0.5,y=-1.5},right_bottom={x=3.5,y=1.5}},surface={find_entities_filtered=function() return {} end}}
  maker.get_output_inventory=function() return o end
  maker.get_recipe=function() return {name='nutrients-from-spoilage',products={{type='item',name='nutrients',amount=10}}} end
  local user={valid=true,name='biochamber',type='assembling-machine',position={x=6,y=0}}
  local given,room={},100
  local api5={}
  for k,v in pairs(api) do api5[k]=v end
  api5.take=function(_,e,item,_,count) local n=math.min(o.n,count); o.n=o.n-n; return {transferred=n,items={{name=item,count=n}}} end
  api5.give=function(_,e,item,_,count,inv)
    eq(e,user); eq(inv,'fuel')
    local n=math.min(room,count); room=room-n; given[#given+1]=game.tick..':'..n
    return {transferred=n,entity_full=n<count and {slots=1} or nil}
  end
  local W=dofile('mod/agent-harness_0.1.0/stock.lua')(api5)
  local fp={position={x=0,y=0},force=p.force,reach_distance=10,can_reach_entity=function() return true end}
  game.tick=7000
  local action=W.start_wait(fp,{item='nutrients'},maker,600)
  action.give_to={entity=user,inventory='fuel'}
  eq(W.tick(fp,action),nil); eq(#given,0,'nothing made yet: nothing given')
  game.tick=7001; o.n=10; maker.products_finished=1
  eq(W.tick(fp,action),nil); eq(given[1],'7001:10','given the tick it was taken'); eq(o.n,0)
  room=4
  game.tick=7002; o.n=10
  eq(W.tick(fp,action),nil); eq(given[2],'7002:4')
  game.tick=7000+600; eq(W.tick(fp,action),'collected')
  local r=W.wait_report(action)
  eq(r.gave,'14 nutrients into biochamber (6,0) fuel'); eq(r.gave_short,'6 stayed in your inventory: the machine given to had no room')
  -- the machine given to out of reach from where the wait stands
  fp.can_reach_entity=function(e) return e~=user end
  action=W.start_wait(fp,{item='nutrients'},maker,600)
  action.give_to={entity=user,inventory='fuel'}
  eq(W.tick(fp,action),'unreached')
  eq(action.why,'to: biochamber (6,0) is out of reach from where the wait stands at biochamber (2,0); stand in reach of both')
end
print('stock collect wait with to: ok')
-- batch28 B3 (Muse: 15 minutes for 5 collectors and 350 ice): a landed cargo pod's container is a place of kind pod;
-- stacks on the ground in sight are places of kind ground with positions, counted in on_ground and not in total.
do
  prototypes.item.ice={}
  local podinv={get_item_count=function(f) return f.name=='ice' and 350 or 0 end}
  local pod={valid=true,unit_number=777,name='cargo-pod-container',type='temporary-container',position={x=12.5,y=3.5},force={name='neutral'},
    get_inventory=function() return podinv end}
  local fs={find_entities_filtered=function(f) if f.name=='cargo-pod-container' or (f.type and #f.type>0) then return {pod} end return {} end}
  local api6={}
  for k,v in pairs(api) do api6[k]=v end
  api6.on_ground=function() return {cells={{position={x=30,y=0},count=40,stacks=1}}} end
  local W=dofile('mod/agent-harness_0.1.0/stock.lua')(api6)
  local fp={position={x=0,y=0},force={name='player'},surface=fs,get_main_inventory=function() return {get_item_count=function() return 0 end} end}
  local v=W.view(fp,{item='ice'})
  eq(v.total,350,'the pod counted once, the ground not')
  eq(v.on_ground,40)
  eq(v.places[1].kind,'pod'); eq(v.places[1].count,350)
  eq(v.places[2].kind,'ground'); eq(v.places[2].name,'1 stack on the ground'); eq(v.places[2].position.x,30)
  assert(v.by_holder.line:find('landed cargo pods 350',1,true),v.by_holder.line)
end
print('stock pods and ground: ok')
-- d20 batch65 AA7 (Grok 22:15: stock {item: nutrients, places: "all", limit: 8, holders: [provider, storage, machine]}
-- failed "attempt to index local 'near' (a nil value)"): a holders filter that leaves no place. Every holders value, with
-- the whole surface read (places "all") and with a limit: the summary and holders_left_out say what it left out.
do
  prototypes.item.nutrients={}
  local function holder(name,type,x,n,mode)
    local e={valid=true,name=name,type=type,position={x=x,y=0},unit_number=x+1000}
    if mode then e.prototype={logistic_mode=mode} end
    local i=inv('nutrients',n)
    e.get_inventory=function() return i end
    e.get_output_inventory=function() return i end
    e.get_recipe=function() return nil end
    return e
  end
  local all={holder('passive-provider-chest','logistic-container',3,10,'passive-provider'),holder('storage-chest','logistic-container',5,20,'storage'),
    holder('requester-chest','logistic-container',7,300,'requester'),holder('buffer-chest','logistic-container',9,40,'buffer'),
    holder('iron-chest','container',11,50),holder('biochamber','assembling-machine',13,60),holder('cargo-landing-pad','cargo-landing-pad',15,70),
    holder('cargo-pod-container','temporary-container',17,80)}
  local function surface(list)
    return {name='gleba',find_entities_filtered=function(f)
      local out={}
      local types={}
      for _,t in ipairs(f.type or {}) do types[t]=true end
      for _,e in ipairs(list) do
        if (f.type==nil or types[e.type]) and (f.name==nil or f.name==e.name) and (f.position==nil or distance(e.position,f.position)<=f.radius) then out[#out+1]=e end
      end
      return out
    end}
  end
  api.on_ground=function() return {cells={{position={x=19,y=0},count=4,stacks=1}}} end
  local q={position={x=0,y=0},force={},surface=surface(all),get_main_inventory=function() return inv('nutrients',0) end}
  local want={provider=10,storage=20,requester=300,buffer=40,chest=50,machine=60,pad=70,pod=80,ground=4,wagon=0,vehicle=0}
  for kind,n in pairs(want) do
    for _,limit in ipairs({8,1}) do
      local ok,v=pcall(stock.view,q,{item='nutrients',holders={kind},limit=limit},{surface=q.surface,whole=true})
      assert(ok,kind..': '..tostring(v))
      eq(v.total,630,kind)
      if n>0 then
        eq(#v.places,1,kind); eq(v.places[1].kind,kind); eq(v.places[1].count,n,kind)
        assert(v.summary:find('nearest '..n..' at',1,true),v.summary)
      else
        eq(#v.places,0,kind)
        assert(v.summary:find('630 nutrients held by our factory',1,true),v.summary)
        assert(v.summary:find('no place of the holders asked ('..kind..') holds it; by holder kind: requester 300 in 1 place, pod 80 in 1 place',1,true),v.summary)
        assert(v.summary:find('ground 4 in 1 place (not in total)',1,true),v.summary)
      end
      assert(v.holders_left_out:find('requester',1,true) or kind=='requester',v.holders_left_out)
    end
  end
  -- Grok's call: no provider, storage or machine on the surface holds it
  local q2={position={x=0,y=0},force={},surface=surface({all[3],all[5]}),get_main_inventory=q.get_main_inventory}
  api.on_ground=nil
  local v=stock.view(q2,{item='nutrients',holders={'provider','storage','machine'},limit=8},{surface=q2.surface,whole=true})
  eq(#v.places,0); eq(v.more,nil)
  eq(v.summary,'350 nutrients held by our factory (300 in 1 requester-chest, 50 in 1 iron-chest); no place of the holders asked (provider, storage, machine) holds it; by holder kind: requester 300 in 1 place, chest 50 in 1 place')
  eq(v.holders_left_out,'requester 300 in 1 place, chest 50 in 1 place')
  -- a filter that keeps every place: nothing left out
  v=stock.view(q2,{item='nutrients',holders={'requester','chest'},limit=1},{surface=q2.surface,whole=true})
  eq(#v.places,1); eq(v.more,1); eq(v.holders_left_out,nil)
  -- within a radius too (stock without places "all")
  v=stock.view(q2,{item='nutrients',holders={'machine'},radius=64},{surface=q2.surface})
  eq(#v.places,0); assert(v.summary:find('(machine) holds it',1,true),v.summary)
end
print('stock holders left out: ok')
