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
