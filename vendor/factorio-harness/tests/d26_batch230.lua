-- Run with lua tests/d26_batch230.lua: d26 batch230 SF (Sol #2425). A recorder of a platform's explosives every 5 s got
-- every other frame from supply's 10 s reuse. supply {item, stock: true}: the count by place read now, never reused,
-- the same total and places as supply's where; one an agent a 5 s for the same surface and item; refused on a surface
-- the census counts too many buildings on. Every supply reply says read (fresh or reused) and read_tick.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={chest=1},flow_precision_index={ten_minutes=3}}
prototypes={item={explosives={type='item'},coal={type='item'}},fluid={water={}},entity={},recipe={}}
local function make_surface(name,index,platform)
  local s={name=name,index=index,platform=platform,world={},finds=0}
  local function finder(f)
    s.finds=s.finds+1
    local types={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
    local out={}
    for _,e in ipairs(s.world) do
      if types[e.type] and e.valid and (e.force or 'player')=='player' then out[#out+1]=e end
    end
    return out
  end
  s.find_entities_filtered=finder
  s.count_entities_filtered=function(f) return #finder(f) end
  return s
end
local ship=make_surface('platform-16',16,{name='Asterion'})
local planet=make_surface('fulgora',4,nil)
local function add(s,e) e.valid=true; e.surface=s; e.unit_number=#s.world+1000*s.index; s.world[#s.world+1]=e; return e end
local function belt(s,x,y,n)
  local e=add(s,{name='transport-belt',type='transport-belt',position={x=x,y=y},direction=4,n=n})
  e.get_item_count=function(id) eq(id,'explosives','a belt read by the item\'s name'); return e.n end
  return e
end
local function chest(s,x,y,n)
  local e=add(s,{name='steel-chest',type='container',position={x=x,y=y},n=n})
  local inv={get_item_count=function(id) return id=='explosives' and e.n or 0 end}
  e.get_inventory=function(id) eq(id,1,'the chest inventory'); return inv end
  return e
end
local function inserter(s,x,y,n)
  local e=add(s,{name='fast-inserter',type='inserter',position={x=x,y=y}})
  e.held_stack={valid_for_read=n>0,name='explosives',count=n}
  return e
end
local B={belt(ship,1.5,1.5,8),belt(ship,2.5,1.5,6),belt(ship,3.5,1.5,0)}
local C=chest(ship,5.5,5.5,40)
local I=inserter(ship,6.5,5.5,2)
belt(planet,1.5,1.5,3)
local force={name='player',logistic_networks={},current_research=nil,get_item_production_statistics=function()
  return {get_flow_count=function() return 0 end} end}
game={tick=1000,get_surface=function(name) return name=='fulgora' and planet or ship end}
local buildings={['platform-16']=7460,fulgora=2400}
local S=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return e.status end,
  position=function(v) return {x=v.x,y=v.y} end,
  integer=function(v,d) return v==nil and d or v end,
  surface_buildings=function(s) return buildings[s.name] end}
local sol={index=1,name='sol',surface=ship,force=force,position={x=0,y=0}}
local astra={index=2,name='astra',surface=ship,force=force,position={x=0,y=0}}

-- 1. stock: the count by place at this tick, the same total and places as supply's where.
local full=S.supply(sol,{item='explosives'})
eq(full.where,'56: belts 14, other chests 40, inserter hands 2')
eq(full.read,'fresh'); eq(full.read_tick,1000)
ship.finds=0
local r=S.supply(sol,{item='explosives',stock=true})
eq(r.stock,true); eq(r.read,'fresh'); eq(r.read_tick,1000); eq(r.next_tick,1300)
eq(r.total,56); eq(r.where,full.where,'stock gives supply\'s where')
eq(r.places.belts,14); eq(r.places['other chests'],40); eq(r.places['inserter hands'],2)
eq(r.places['machine outputs'],nil,'places holding none are left out')
eq(r.counted,'0 crafters, 1 chests, 3 of 3 belts, 1 inserters, 0 robots')
assert(r.as_of=='live (tick 1000)',r.as_of)
assert(r.belt_lines==nil and r.networks==nil and r.makers==nil and r.flow==nil,'counts only')
-- a platform: a find per group of types
assert(ship.finds>=4,'a find per group on a platform: '..ship.finds)
-- compact leaves a stock reply as it is
eq(S.compact(r),r)

-- 2. one read an agent a 5 s for the same surface and item: sooner is refused with the next tick
game.tick=1299
local ok,err=pcall(S.supply,sol,{item='explosives',stock=true})
assert(not ok and err:find('the next from tick 1300',1,true) and err:find('at tick 1000',1,true),err)
-- another agent, or another item, reads now
B[1].n=20
local a=S.supply(astra,{item='explosives',stock=true})
eq(a.read_tick,1299); eq(a.total,68,'read now, not reused')
eq(S.supply(sol,{item='coal',stock=true}).total,0)
-- at 300 ticks the same agent reads again, the counts of now
game.tick=1300
B[2].n=0; C.n=10; I.held_stack={valid_for_read=false}
r=S.supply(sol,{item='explosives',stock=true})
eq(r.read_tick,1300); eq(r.total,30); eq(r.where,'30: belts 20, other chests 10')

-- 3. the default supply read is unchanged: reused within 10 s, and now says so with the tick it was read
game.tick=1500
local again=S.supply(sol,{item='explosives'})
eq(again.read,'reused'); eq(again.read_tick,1000); eq(again.where,'56: belts 14, other chests 40, inserter hands 2')
assert(again.as_of:find('8s ago',1,true),again.as_of)
local c=S.compact(again)
eq(c.read,'reused'); eq(c.read_tick,1000)
-- the kept reply keeps its own read: a later reuse still says reused, a read after 10 s fresh
game.tick=1599
eq(S.supply(sol,{item='explosives'}).read,'reused')
game.tick=1600
local fresh=S.supply(sol,{item='explosives'})
eq(fresh.read,'fresh'); eq(fresh.read_tick,1600); eq(fresh.where,'30: belts 20, other chests 10')
-- requesters says it too
local req=S.supply(sol,{item='explosives',requesters=true})
eq(req.read,'fresh'); eq(req.read_tick,1600)
game.tick=1610
eq(S.supply(sol,{item='explosives',requesters=true}).read,'reused')

-- 4. size: a platform of at most 10000 buildings, a planet of at most 2500 (by the census); a planet not counted yet
-- is refused, a platform read
local onplanet={index=1,name='sol',surface=planet,force=force,position={x=0,y=0}}
eq(S.supply(onplanet,{item='explosives',stock=true,surface='fulgora'}).total,3)
buildings.fulgora=2501
ok,err=pcall(S.supply,astra,{item='explosives',stock=true,surface='fulgora'})
assert(not ok and err:find('a planet of at most 2500',1,true) and err:find('counts 2501 on fulgora',1,true),err)
buildings.fulgora=nil
ok,err=pcall(S.supply,astra,{item='explosives',stock=true,surface='fulgora'})
assert(not ok and err:find('has not counted',1,true),err)
buildings['platform-16']=10001
game.tick=2000
ok,err=pcall(S.supply,sol,{item='explosives',stock=true})
assert(not ok and err:find('a platform of at most 10000',1,true),err)
buildings['platform-16']=nil
eq(S.supply(sol,{item='explosives',stock=true}).total,30,'a platform the census has not counted is read')

-- 5. Refusals: not true, a fluid, with the other modes.
game.tick=3000
ok,err=pcall(S.supply,sol,{item='explosives',stock=1}); assert(not ok and err:find('stock is true',1,true),err)
ok,err=pcall(S.supply,sol,{item='water',stock=true}); assert(not ok and err:find('stock is for an item',1,true),err)
for _,k in ipairs({'belt_positions','near','radius','makers','requesters','split'}) do
  local args={item='explosives',stock=true}; args[k]=true
  ok,err=pcall(S.supply,sol,args); assert(not ok and err:find('no '..k..' with it',1,true),k..': '..tostring(err))
end
-- a refused call takes no read: the next one reads
eq(S.supply(sol,{item='explosives',stock=true}).read_tick,3000)
assert(S.schema.supply.stock and S.schema.supply.returns:find('read_tick',1,true),'schema')
print('d26_batch230 SF: ok')
