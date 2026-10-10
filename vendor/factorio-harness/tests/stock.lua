-- Run from repository root: lua tests/stock.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={chest=1,cargo_landing_pad_main=2},direction={north=0}}
prototypes={item={pipe={},coal={}}}
game={tick=0}
local function inv(item,n)
  return {get_item_count=function(f) return f.name==item and n or 0 end}
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
print('stock: ok')
