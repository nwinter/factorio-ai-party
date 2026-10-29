-- Run from repository root: lua tests/d28_batch325.lua
-- d28 batch325 IC (Astra #2717): "Nauvis supply/science agricultural-science-pack at tick78535609 explicitly counts
-- only10000/19304belts and4096/7523robots. Report residual208 across two1000pods cannot distinguish missing scan stock
-- from spoilage". 1. A residual over a count the census truncated (then or now) is indeterminate (N of M holders
-- counted) and names no cause; dependency reads no rate from it. 2. supply's coverage: holders counted of those the
-- find saw. 3. supply count_all (itemcount.lua): a paginated count of one item on every belt and in every flying
-- robot's cargo equals a full count; each step stays within its bounds (bands, belts, one robot list, cargo reads); a
-- network past ROBOT_LIST_MAX is left out and said (complete false).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
local function lacks(text,part) assert(not (text and tostring(text):find(part,1,true)),tostring(text)..' has '..part) end
game={tick=1000,surfaces={},forces={}}
prototypes={item={['agricultural-science-pack']={name='agricultural-science-pack',type='tool',get_spoil_ticks=function() return 216000 end},
  ['iron-plate']={name='iron-plate',type='item',get_spoil_ticks=function() return 0 end}},fluid={},recipe={},entity={}}
defines={inventory={robot_cargo=5},flow_precision_index={ten_minutes=3}}
local storage_={}
local totals={made=0,used=0}
local stats={get_input_count=function() return totals.made end,get_output_count=function() return totals.used end,get_flow_count=function() return 0 end}
local force={name='player',valid=true,get_item_production_statistics=function() return stats end}
local nauvis={name='nauvis',index=1,valid=true}
local SF=require('spoilflow'){state=function() return storage_ end,secs=function(t) return math.floor(t/60)..'s' end}
local AG='agricultural-science-pack'

-- 1. the residual: indeterminate under a truncated census, then or now; measured as before when both are complete
do
  local short={complete=false,counted=14096,of=26827,text='14096 of 26827 holders counted: 10000 of 19304 belts, 4096 of 7523 robots'}
  local full={complete=true,counted=26827,of=26827}
  eq(SF.sample(force,nauvis,AG,1000,full).line,nil,'the first count')
  game.tick=1000+3600*57; totals.used=1095
  local m=SF.sample(force,nauvis,AG,697,short)
  eq(m.residual,nil,'no residual'); eq(m.uncounted,nil,'no uncounted'); eq(m.residual_means,nil)
  eq(m.indeterminate,'indeterminate (now 14096 of 26827 holders counted: 10000 of 19304 belts, 4096 of 7523 robots)')
  has(m.line,'made 0, used 1095; held 1000 then, at least 697 now; residual indeterminate (now 14096 of 26827 holders counted: 10000 of 19304 belts, 4096 of 7523 robots)')
  lacks(m.line,'spoil'); lacks(m.line,'loss'); lacks(m.line,'left the stock')
  eq(SF.last(force,nauvis,AG),nil,'dependency reads no rate from an indeterminate measure')
  eq(SF.last(force,nauvis,AG,true).indeterminate,m.indeterminate)
  local t=SF.text(force,nauvis,AG)
  has(t,'residual indeterminate (now 14096 of 26827'); lacks(t,'more left the stock')
  -- then truncated, now complete: still indeterminate (the count then left holders out)
  game.tick=game.tick+3600*10; totals.used=1200
  local m2=SF.sample(force,nauvis,AG,600,full)
  eq(m2.indeterminate,'indeterminate (then 14096 of 26827 holders counted: 10000 of 19304 belts, 4096 of 7523 robots)')
  has(m2.line,'held at least 697 then, 600 now')
  -- both complete: the residual as before, its sign's meaning given
  game.tick=game.tick+3600*10; totals.used=1300
  local m3=SF.sample(force,nauvis,AG,450,full)
  eq(m3.indeterminate,nil); eq(m3.residual,600-100-450); has(m3.line,'residual +50')
  eq(SF.last(force,nauvis,AG).residual,50)
  -- a caller with no coverage (before this change) is complete
  game.tick=game.tick+3600*10
  eq(SF.sample(force,nauvis,AG,450).indeterminate,nil)
  print('d28_batch325 1. a residual over a truncated census is indeterminate (N of M holders counted), no cause named: ok')
end

-- 2. supply's coverage of a scan
do
  local S=require('supply'){state=function() return {} end,integer=function(v,d) return v or d end}
  local c=S.coverage({counted={crafters=890,labs=30,chests=3812,belts=10000,belts_total=19304,inserters=3756,robots=4096,found=36000,
    seen={crafters=890,labs=30,chests=3812,belts=19304,inserters=3756,robots=7523}}})
  eq(c.complete,false); eq(c.counted,890+30+3812+10000+3756+4096); eq(c.of,890+30+3812+19304+3756+7523)
  eq(c.text,'22584 of 35315 holders counted: 10000 of 19304 belts, 4096 of 7523 robots')
  local all=S.coverage({counted={crafters=10,chests=5,belts=200,inserters=40,robots=3,found=258,seen={crafters=10,chests=5,belts=200,inserters=40,robots=3}}})
  eq(all.complete,true); eq(all.text,nil)
  local lean=S.coverage({counted={crafters=10,chests=5000,belts=12,inserters=4,robots=0,found=5026,lean=true,seen={crafters=10,chests=5000,belts=12,inserters=4,robots=0}}})
  eq(lean.text,'5026 of at least 5026 holders counted: 5000 of at least 5000 chests')
  local capped=S.coverage({counted={crafters=10,chests=5,belts=200,inserters=40,robots=3,found=40000,seen={crafters=10,chests=5,belts=200,inserters=40,robots=3}}})
  has(capped.text,'the find stopped at 40000 entities')
  print('d28_batch325 2. supply coverage: holders counted of those the find saw, at least where a find was capped: ok')
end

-- 3. count_all: a stand-in surface of belts in chunks and robots in networks
local calls
local function entity(x,y,n,kind)
  local e={valid=true,position={x=x,y=y},type=kind or 'transport-belt'}
  e.get_item_count=function(item) calls.belt_reads=calls.belt_reads+1; return item==AG and n or 0 end
  return e
end
local function robot(n)
  local inv={get_item_count=function(item) return item==AG and n or 0 end}
  return {valid=true,get_inventory=function() calls.cargo=calls.cargo+1; return inv end}
end
local belts={}
local truth=0
-- 40 x 30 chunks; a dense block near the origin (900 belts in one chunk) and sparse rows elsewhere
for i=1,900 do local n=(i%7==0) and 3 or 0; truth=truth+n; belts[#belts+1]=entity(5+(i%30),5+math.floor(i/30)%30,n) end
for cx=-20,19 do for cy=-15,14,3 do local n=(cx+cy)%5==0 and 2 or 0; truth=truth+n; belts[#belts+1]=entity(cx*32+16,cy*32+16,n,'underground-belt') end end
local robots_big, robots_small, robots_con = {}, {}, {}
local cargo_truth=0
for i=1,5677 do local n=(i%50==0) and 1 or 0; cargo_truth=cargo_truth+n; robots_big[i]=robot(n) end
for i=1,40 do robots_small[i]=robot(i==1 and 4 or 0); cargo_truth=cargo_truth+(i==1 and 4 or 0) end
for i=1,9 do robots_con[i]=robot(0) end
local function network(id,all,avail,list,con)
  local n={network_id=id,all_logistic_robots=all,available_logistic_robots=avail,all_construction_robots=#(con or {}),available_construction_robots=0}
  setmetatable(n,{__index=function(_,k)
    if k=='logistic_robots' then calls.lists=calls.lists+1; calls.listed=calls.listed+#list; return list end
    if k=='construction_robots' then calls.lists=calls.lists+1; calls.listed=calls.listed+#(con or {}); return con or {} end
  end})
  return n
end
local nets={network(243,7523,1846,robots_big,robots_con),network(832,48,8,robots_small)}
force.logistic_networks={nauvis=nets}
nauvis.find_entities_filtered=function(f)
  calls.finds=calls.finds+1
  local a=f.area; local out={}
  for _,e in ipairs(belts) do
    local p=e.position
    if p.x>=a[1][1] and p.x<a[2][1] and p.y>=a[1][2] and p.y<a[2][2] then out[#out+1]=e end
  end
  return out
end
game.surfaces={[1]=nauvis,nauvis=nauvis}; game.forces={player=force}
game.players={}
local hstate={walk_box={[1]={left=-20,right=19,top=-15,bottom=14}}}
local IC=require('itemcount'){state=function() return hstate end}
local p={force=force,surface=nauvis}
local function run(maxticks)
  local steps,worst={}, {finds=0,belt_reads=0,lists=0,listed=0,cargo=0}
  for _=1,maxticks do
    game.tick=game.tick+1
    calls={finds=0,belt_reads=0,lists=0,listed=0,cargo=0}
    IC.tick(game.tick)
    for k,v in pairs(calls) do if v>worst[k] then worst[k]=v end end
    local j=hstate.itemcount.jobs['player|1|'..AG]
    if j and j.phase=='done' then return j,worst end
  end
  error('not done in '..maxticks..' ticks')
end
do
  calls={finds=0,belt_reads=0,lists=0,listed=0,cargo=0}
  local first=IC.read(p,nauvis,AG,{count_all=true})
  eq(first.count_all,'started'); has(first.next,'read again')
  local again=IC.read(p,nauvis,AG,{count_all=true})
  eq(again.count_all,'counting'); eq(again.waiting,'queued (0 ahead)')
  local job,worst=run(20000)
  local out=IC.read(p,nauvis,AG,{count_all=true})
  eq(out.count_all,'done'); eq(out.belts.count,truth,'belts: the paginated count equals the full one')
  eq(out.belts.read,#belts,'every belt read once')
  eq(out.robots.count,cargo_truth,'robots: every flying robot read once'); eq(out.robots.read,5677+40+9)
  eq(out.total,truth+cargo_truth); eq(out.complete,true); eq(out.robots.networks,2)
  has(out.coverage,'every belt of ours in the 1824 chunks of the box where we built on nauvis ('..#belts..' belts read')
  has(out.line,AG..' on nauvis: '..truth..' on belts, '..cargo_truth..' in robots\' cargo')
  assert(out.first_tick<out.last_tick and #out.pages>3,'pages at their own ticks')
  has(out.pages[1],'belts')
  -- the bounds a step: finds, belt reads, one robot list of at most ROBOT_LIST_MAX, cargo reads
  assert(worst.finds<=IC.BANDS_A_STEP,'finds a step '..worst.finds)
  assert(worst.belt_reads<=IC.BELTS_A_STEP,'belt reads a step '..worst.belt_reads)
  assert(worst.lists<=1 and worst.listed<=IC.ROBOT_LIST_MAX,'one list a step')
  assert(worst.cargo<=IC.ROBOTS_A_STEP,'cargo reads a step '..worst.cargo)
  -- a done count is returned while fresh; past FRESH a new one starts
  eq(IC.read(p,nauvis,AG,{count_all=true}).count_all,'done')
  game.tick=game.tick+IC.FRESH+1
  eq(IC.read(p,nauvis,AG,{count_all=true}).count_all,'started')
  run(20000)
  print(string.format('d28_batch325 3. count_all: %d belts and %d robots counted in pages equal the full count (%d, %d); a step at most %d finds, %d belt reads, %d robot list (%d), %d cargo reads: ok',
    #belts,5677+49,truth,cargo_truth,worst.finds,worst.belt_reads,worst.lists,worst.listed,worst.cargo))
end
do
  -- a network past ROBOT_LIST_MAX: left out and said, complete false
  nets[1].available_logistic_robots=7523-(IC.ROBOT_LIST_MAX+1)
  game.tick=game.tick+IC.FRESH+1
  IC.read(p,nauvis,AG,{count_all=true})
  local _,worst=run(20000)
  local out=IC.read(p,nauvis,AG,{count_all=true})
  eq(out.complete,false); has(out.coverage,'not read: network 243: 8001 flying logistic robots (a list over 8000 is one read past the step bound)')
  has(out.line,': incomplete'); assert(worst.listed<=IC.ROBOT_LIST_MAX)
  nets[1].available_logistic_robots=1846
  -- the other reads refuse it with count_all; an item only
  local ok,err=pcall(IC.read,p,nauvis,AG,{count_all=true,near={x=0,y=0}})
  assert(not ok); has(err,'no near with it')
  ok,err=pcall(IC.read,p,nauvis,'crude-oil',{count_all=true})
  assert(not ok)
  -- no box yet: refused at its turn, said
  hstate.walk_box={}; hstate.threat_shared={}
  game.tick=game.tick+IC.FRESH+1
  IC.read(p,nauvis,AG,{count_all=true})
  local j=run(100)
  has(j.failed,'no box of where we built')
  eq(IC.read(p,nauvis,AG,{count_all=true}).count_all,'started','a failed count starts again')
  print('d28_batch325 4. a network past the list bound left out (complete false); count_all alone; no box: said: ok')
end
