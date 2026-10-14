-- Run with lua tests/robotwait.lua: robot delays per logistic network (Nick 12:35; networks.lua). World n: 1
-- construction robot against 325 logistic robots while Astra's 75-entity layout waited as ghosts.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
storage={}
defines={flow_precision_index={five_seconds=0,one_hour=3},logistic_member_index={logistic_container=0}}
prototypes={item={}}
local force={name='player',players={{}}}
local list={}
local function add(e) e.valid=true; e.force=e.force or force; list[#list+1]=e; return e end
local function inside(p,a) return p.x>=a[1][1] and p.x<=a[2][1] and p.y>=a[1][2] and p.y<=a[2][2] end
local nauvis={name='nauvis',index=1,solar_power_multiplier=1,get_property=function() return 100 end}
nauvis.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(list) do
    local ok=(not f.force or e.force==f.force) and (not f.area or inside(e.position,f.area))
    if f.type then ok=ok and e.type==f.type end
    if f.to_be_deconstructed then ok=ok and e.decon end
    if f.to_be_upgraded then ok=ok and e.upgrade end
    if ok then out[#out+1]=e end
  end
  return out
end
nauvis.count_entities_filtered=function(f) return #nauvis.find_entities_filtered(f) end
game={tick=0,forces={player=force},surfaces={nauvis},get_surface=function() return nauvis end}
-- Network 3: 4 roboports at x=25..100, y=50 (construction 55); 1 construction robot, out on a job; 325 logistic robots
-- all out, 40 waiting to charge at 3 roboports; the items for the layout in its storage.
local held={['assembling-machine-2']=40,['fast-inserter']=100,['iron-plate']=0}
local free={['copper-cable']=500}
local ln={network_id=3,all_logistic_robots=325,available_logistic_robots=0,all_construction_robots=1,available_construction_robots=0,cells={}}
ln.get_item_count=function(item) return held[item] or 0 end
ln.get_supply_counts=function(item) return {storage=free[item] or 0} end
for i=1,4 do
  local x=i*25
  ln.cells[i]={owner={valid=true,position={x=x,y=50}},logistic_radius=25,construction_radius=55,charging_robot_count=i<=3 and 4 or 0,
    to_charge_robot_count=i<=3 and (i==1 and 20 or 10) or 0,
    is_in_construction_range=function(p) return math.abs(p.x-x)<=55 and math.abs(p.y-50)<=55 end}
end
-- A requester wanting 400 copper-cable, holding 0, nothing on the way.
ln.requester_points={{owner={unit_number=501,get_item_count=function() return 0 end},filters={{name='copper-cable',quality='normal',count=400}},targeted_items_deliver={}}}
-- Network 8 elsewhere holds iron plates.
local other={network_id=8,all_logistic_robots=5,available_logistic_robots=5,all_construction_robots=5,available_construction_robots=5,
  cells={{owner={valid=true,position={x=400,y=0}},logistic_radius=25,construction_radius=55}},requester_points={}}
other.get_item_count=function(item) return item=='iron-plate' and 800 or 0 end
force.logistic_networks={nauvis={ln,other}}
-- Astra's layout: 75 ghosts (60 assemblers, 15 fast inserters).
local function ghost(x,y,item)
  return add{type='entity-ghost',name='entity-ghost',unit_number=1000+#list,position={x=x,y=y},ghost_prototype={items_to_place_this={{name=item,count=1}}}}
end
for i=1,60 do ghost(30+(i%20)*3,40+math.floor(i/20)*3,'assembling-machine-2') end
for i=1,15 do ghost(30+i*3,60,'fast-inserter') end
local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end}
local function run(sec) for _=1,sec*60 do game.tick=game.tick+1; N.tick(game.tick) end end
local function view_now() storage.networks.views={} end
local function row() view_now(); return N.read({force=force},{}).surfaces[1].logistic[1] end

-- 1. Under 5 min: the backlog counted, no wait yet, no alert.
run(90)
local r=row()
eq(r.backlog.ghosts,75); eq(r.backlog.waited,0); eq(r.backlog.robots,1)
assert(r.line:find('construction backlog: 75 ghosts, 0 to deconstruct, 0 to upgrade; 0 waited 5+ min, oldest 1 min',1,true),r.line)
for _,g in ipairs(N.alert_groups(force)) do assert(g.kind~='construction_wait') end
-- 2. Past 5 min: the cause, the alert with the items in the network.
run(300)
r=row()
eq(r.backlog.waited,75); eq(r.backlog.oldest_min,6); eq(r.backlog.items_present,true)
assert(r.line:find('75 waited 5+ min, oldest 6 min; cause: all 1 construction robot busy (75 jobs per robot)',1,true),r.line)
local found
for _,g in ipairs(N.alert_groups(force)) do if g.kind=='construction_wait' then found=g end end
assert(found,'the alert')
eq(found.line,'ghosts waiting on robots: 75 in network 3 near (25,50), oldest 6 min, 1 construction robot (busy); the items are in the network')
eq(found.n,75)
-- 3. Deliveries: the copper-cable request unfilled 5+ min while storage holds 500 free; the robots all out, 40 waiting.
assert(r.deliveries,'deliveries stuck')
eq(r.deliveries.stuck,1); eq(r.deliveries.free['copper-cable'],500)
eq(r.deliveries.cause,'no idle logistic robots; 40 robots waiting to charge at 3 roboports; 273 carrying for other requests')
local d
for _,g in ipairs(N.alert_groups(force)) do if g.kind=='deliveries_wait' then d=g end end
eq(d.line,'deliveries waiting on robots: 1 request unfilled 5+ min in network 3 near (25,50) while providers or storage hold the item free (copper-cable 500): no idle logistic robots; 40 robots waiting to charge at 3 roboports; 273 carrying for other requests')
-- 4. An item missing in the network, held in network 8: the cause says where; no alert (that is the game's own
-- no-materials alert).
held['assembling-machine-2']=0
for _,e in ipairs(list) do if e.ghost_prototype.items_to_place_this[1].name=='assembling-machine-2' then e.ghost_prototype.items_to_place_this[1].name='iron-plate' end end
r=row()
assert(r.backlog.cause:find('items missing in this network: iron-plate (held in network #8 near (400,0))',1,true),r.backlog.cause)
for _,g in ipairs(N.alert_groups(force)) do assert(g.kind~='construction_wait','not with items missing') end
-- 5. Ghosts outside every construction area (the bounding box holds a gap): said so.
for _,c in ipairs(ln.cells) do c.is_in_construction_range=function() return false end end
r=row()
eq(r.backlog.cause,'outside every roboport construction area')
-- 6. Built: gone from the backlog (and from the remembered orders).
for _,e in ipairs(list) do e.valid=false end
r=row()
eq(r.backlog.total,0); assert(r.line:find('construction backlog: none',1,true),r.line)
eq(next(storage.networks.orders.player),nil,'gone orders forgotten')
-- Item 4 (12:35): while Nauvis is the only planet in play (runtime one_planet) a line names no planet; the read's
-- surface field keeps it. Without that, the planet leads the line.
assert(N.lines(force,'nauvis',8)[1]:find('^nauvis logistic #3'),'the planet named')
local one=true
local N1=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end,one_planet=function() return one end}
storage.networks.views={}
assert(N1.lines(force,'nauvis',8)[1]:find('^logistic #3: '),N1.lines(force,'nauvis',8)[1])
local rd=N1.read({force=force},{})
eq(rd.surfaces[1].surface,'nauvis'); assert(rd.surfaces[1].logistic[1].line:find('^logistic #3: '))
one=false
assert(N1.lines(force,'nauvis',8)[1]:find('^nauvis logistic #3'))
print('robotwait: ok')
