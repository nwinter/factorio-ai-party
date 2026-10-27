-- d27 batch269 BS (Sol #2570): on Vulcanus 4 big mining drills put 1267 tungsten ore a minute on a line belt_flow read
-- as 634/min. Read on a copy (2.0.77): a lane entry is a stack (one unique_id, stack.count items); a big mining drill and
-- a stack inserter put stacks of 1 + the force's belt_stack_size_bonus on a belt; an inserter takes part of a stack (its
-- id stays, its count falls). belt_flow counts items: a stack counts its count; stacks a minute beside them; a lane
-- tile is full at 4 stacks and its cap is in stacks.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function near(a,b,d) assert(math.abs(a-b)<=d,tostring(a)..' not within '..d..' of '..tostring(b)) end
local inserters={}
local surf={name='vulcanus',find_entities_filtered=function(f) assert(f.type=='inserter'); return inserters end}
local force={name='player',belt_stack_size_bonus=1,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end}
game={tick=0,forces={player=force},get_surface=function() return surf end}
local storage={}
-- lanes[entity][line] = {{id,pos,name,count}}; positions count down to the lane's exit (0), as the game reads them
local lanes={}
local n=0
local function belt(x,y,dir)
  n=n+1
  local e={valid=true,unit_number=100+n,type='transport-belt',name='fast-transport-belt',surface=surf,position={x=x,y=y},direction=dir,
    prototype={belt_speed=0.0625},belt_neighbours={inputs={},outputs={}}}
  lanes[e]={{},{}}
  e.get_max_transport_line_index=function() return 2 end
  e.get_transport_line=function(k) return {get_detailed_contents=function()
    local out={}
    for _,it in ipairs(lanes[e][k]) do out[#out+1]={unique_id=it[1],position=it[2],stack={valid_for_read=true,name=it[3],count=it[4]}} end
    return out end} end
  return e
end
local function chain(list) for i=2,#list do list[i].belt_neighbours.inputs={list[i-1]}; list[i-1].belt_neighbours.outputs={list[i]} end end
-- move every item on a chain by speed; one past a tile's exit goes onto the next tile's lane (gone past the last)
local function move(list)
  for i=#list,1,-1 do
    for k=1,2 do
      local L=lanes[list[i]][k]
      for j=#L,1,-1 do
        local it=L[j]
        it[2]=it[2]-0.0625
        if it[2]<0 then table.remove(L,j); if list[i+1] then table.insert(lanes[list[i+1]][k],{it[1],it[2]+1,it[3],it[4]}) end end
      end
    end
  end
end
local S=require('beltsample'){state=function() return storage end,remote_entity=function(_,a) local x,y=a.position.x or a.position[1],a.position.y or a.position[2]
  for e in pairs(lanes) do if math.abs(e.position.x-x)<0.5 and math.abs(e.position.y-y)<0.5 then return e end end error('no belt there') end,on_platform=function(p) return p end}
local Mz=require('measures'){state=function() return storage end}
local p={index=1,force=force}
local id=0
local function stack(name,count) id=id+1; return {id,0.94,name,count} end

-- 1. Sol's line: stacks of 2 on both lanes, one a lane every 8 ticks on a fast belt (450 stacks, 900 items a minute a lane)
do
  local L={}
  for x=1,3 do L[x]=belt(x+0.5,0.5,4) end
  chain(L)
  -- the line full of moving stacks before the sample starts
  for t=1,64 do game.tick=t; move(L); if t%8==0 then for k=1,2 do table.insert(lanes[L[1]][k],stack('tungsten-ore',2)) end end end
  local r=S.handler(p,{position={x=1.5,y=0.5},seconds=10})
  eq(r.tiles,3); eq(r.every_ticks,8)
  local t0=game.tick
  for t=t0+1,t0+600 do
    game.tick=t; move(L)
    if t%8==0 then for k=1,2 do table.insert(lanes[L[1]][k],stack('tungsten-ore',2)) end end
    S.tick(t)
  end
  r=S.handler(p,{})
  eq(r.done,true)
  local pt=r.points[1]
  -- every count is items: twice the stacks
  eq(pt.left.passed,2*pt.left.stacks); eq(pt.right.passed,2*pt.right.stacks)
  eq(pt.left.rate,2*pt.left.stacks_rate); near(pt.left.stacks_rate,450,8); near(pt.left.rate,900,16)
  eq(pt.rate,pt.left.rate+pt.right.rate)
  eq(pt.left.stack_max,2); eq(pt.left.items,string.format('tungsten-ore %d',pt.left.passed))
  eq(pt.left.state,string.format('%g items/min (%g stacks/min, up to 2 a stack)',pt.left.rate,pt.left.stacks_rate))
  has(r.lines[1],string.format('left lane %g items/min',pt.left.rate))
  -- the tile holds items in stacks: held counts items, held_stacks the stacks
  eq(pt.left.held,2*pt.left.held_stacks)
  -- the lane's cap in stacks (fast belt 900 a minute) and in items at the belt stack size 2; 450 stacks/min is no cap
  eq(pt.lane_cap.stacks,900); eq(pt.lane_cap.items,1800); eq(r.limit,nil)
  eq(r.stacking.belt_stack_size,2); eq(r.stacking.largest,2)
  has(r.stacking.line,'belt stack size 2 (1 + the force\'s belt stack bonus 1): a stack inserter or a big mining drill puts stacks of up to 2 on a belt')
  has(r.lines[#r.lines],'stacks of up to 2 seen on 2 of 2 lanes sampled (lanes): every count here is items')
  eq(r.stacking.lanes[1],'section end (3.5,0.5) left lane'); eq(r.stacking.lanes[2],'section end (3.5,0.5) right lane')
  has(r.note,'every count and rate is items')
  -- 2. the same line at its cap: a stack every 4 ticks (900 stacks, 1800 items a minute a lane)
  for k=1,2 do for _,e in ipairs(L) do lanes[e][k]={} end end
  t0=game.tick
  for t=t0+1,t0+64 do game.tick=t; move(L); if t%4==0 then for k=1,2 do table.insert(lanes[L[1]][k],stack('tungsten-ore',2)) end end end
  S.handler(p,{position={x=1.5,y=0.5},seconds=10})
  t0=game.tick
  for t=t0+1,t0+600 do
    game.tick=t; move(L)
    if t%4==0 then for k=1,2 do table.insert(lanes[L[1]][k],stack('tungsten-ore',2)) end end
    S.tick(t)
  end
  r=S.handler(p,{})
  pt=r.points[1]
  near(pt.left.stacks_rate,900,8)
  eq(r.limit,string.format('the left lane runs at its cap in section (1.5,0.5) to (3.5,0.5) (%g stacks/min of 900, %g items/min in stacks of up to 2): the belt carries no more on it',
    pt.left.stacks_rate,pt.left.rate))
  print('d27_batch269 BS a line of stacks: items, stacks and the cap: ok')
end

-- 3. stopped lanes: full is 4 stacks on the tile; 3 stacks of 2 (6 items) is not full
do
  local B=belt(10.5,0.5,4)
  lanes[B][1]={{5001,0.1,'iron-ore',2},{5002,0.35,'iron-ore',2},{5003,0.6,'iron-ore',2},{5004,0.85,'iron-ore',2}}
  lanes[B][2]={{5011,0.1,'iron-ore',2},{5012,0.35,'iron-ore',2},{5013,0.6,'iron-ore',2}}
  S.handler(p,{position={x=10.5,y=0.5},seconds=2})
  local t0=game.tick
  for t=t0+1,t0+120 do game.tick=t; S.tick(t) end
  local r=S.handler(p,{})
  local pt=r.points[1]
  eq(pt.left.state,'stopped, full (8 iron-ore in 4 stacks on the tile)'); eq(pt.left.held,8); eq(pt.left.held_stacks,4)
  eq(pt.right.state,'stopped (6 iron-ore in 3 stacks on the tile)'); eq(pt.right.held,6)
  eq(r.limit,'the end is backed up on its left lane at (10.5,0.5) (8 iron-ore in 4 stacks)')
  print('d27_batch269 BS full lanes counted in stacks: ok')
end

-- 4. exact_tile at an inserter's pickup: the left lane's stacks of 2 lose one item to the inserter mid-tile (the stack
-- keeps its id) and go on with 1; the right lane's stacks of 2 go on whole. Items through = passed on + picked.
do
  local T,N=belt(20.5,0.5,4),belt(21.5,0.5,4)
  chain({T,N})
  local ins={valid=true,name='inserter',unit_number=950,position={x=20.5,y=1.5},pickup_position={x=20.5,y=0.5},hand=0,drop=0}
  ins.held_stack=setmetatable({},{__index=function(_,k) if k=='valid_for_read' then return ins.hand>0 elseif k=='count' then return ins.hand elseif k=='name' then return 'tungsten-ore' end end})
  inserters[1]=ins
  local r=S.handler(p,{position={x=20.5,y=0.5},seconds=10,exact_tile=true})
  eq(r.exact_tile,true); eq(r.every_ticks,4)
  local t0=game.tick
  local came={0,0}
  for t=t0+1,t0+600 do
    game.tick=t
    move({T,N})
    for k=1,2 do local L=lanes[N][k]; for j=#L,1,-1 do if L[j][2]<0.5 then table.remove(L,j) end end end
    for _,it in ipairs(lanes[T][1]) do if it[4]==2 and it[2]<=0.5 then it[4]=1; ins.hand=1; ins.drop=t+8 end end
    if ins.hand>0 and t>=ins.drop then ins.hand=0 end
    if t%16==0 then for k=1,2 do table.insert(lanes[T][k],stack('tungsten-ore',2)); came[k]=came[k]+2 end end
    S.tick(t)
  end
  r=S.handler(p,{})
  eq(r.done,true)
  local L,R=r.left,r.right
  -- the left lane: each stack left 2 items, 1 taken mid-tile (the hand's 1), 1 passed on
  eq(L.left,L.passed_on+L.taken+L.not_seen_after); near(L.taken,L.left/2,1); near(L.passed_on,L.left/2,1); eq(L.not_seen_after,0)
  eq(L.taken_items,string.format('tungsten-ore %d',L.taken)); near(r.picked,L.taken,1)
  -- the right lane: whole stacks of 2 passed on
  eq(R.left,2*R.stacks); eq(R.passed_on,R.left); eq(R.taken,0)
  eq(r.through,L.passed_on+R.passed_on+r.picked); near(r.through,L.left+R.left,1)
  eq(r.rate,L.rate+R.rate); eq(r.stacks_rate,L.stacks_rate+R.stacks_rate)
  has(r.lines[1],string.format('right lane %g items/min (%g stacks/min, up to 2 a stack)',R.rate,R.stacks_rate))
  has(r.lines[#r.lines],string.format('through the tile: %g items/min',r.through_rate))
  -- what came on: every item of every stack, both lanes
  near(L.entered,came[1],4); near(R.entered,came[2],4)
  print('d27_batch269 BS exact_tile part-stacks taken, passed on and picked in items: ok')
end

-- 5. the watch's latest line counts items; a sample begun before this (names for left, entries with no count) reads one
-- item an entry
do
  local B=belt(30.5,0.5,4)
  lanes[B][1]={{6001,0.5,'iron-plate',2}}
  S.handler(p,{position={x=30.5,y=0.5},seconds=10})
  local job=storage.belt_flow[1]
  game.tick=game.tick+8; lanes[B][1]={}; S.tick(game.tick)
  has(Mz.list(1,game.tick)[1].line,'2 items passed the sampled tiles')
  game.tick=job.until_tick; S.tick(game.tick)
  local r=S.handler(p,{})
  eq(r.points[1].left.passed,2); eq(r.points[1].left.stacks,1); eq(r.points[1].left.stack_max,2)
  -- a job begun before this deploy: names only, entries with no count, no stack counters
  S.handler(p,{position={x=30.5,y=0.5},seconds=10})
  job=storage.belt_flow[1]
  local pt=job.points[1]
  pt.left_n, pt.whole, pt.stacks, pt.stack_max=nil,nil,nil,nil
  pt.left[2][7001]='copper-plate'
  pt.lanes[2]={[7002]={pos=0.5,name='copper-plate'}}
  has(Mz.list(1,game.tick)[1].line,'1 items passed the sampled tiles')
  game.tick=game.tick+8; S.tick(game.tick)
  has(Mz.list(1,game.tick)[1].line,'2 items passed the sampled tiles')
  game.tick=job.until_tick; S.tick(game.tick)
  r=S.handler(p,{})
  eq(r.points[1].right.passed,2); eq(r.points[1].right.items,'copper-plate 2'); eq(r.points[1].right.stacks,2); eq(r.points[1].right.stack_max,nil)
  print('d27_batch269 BS the watch line and a sample from before: ok')
end
-- 6. a finished exact_tile sample is done, not "invalid: it reads nothing" (Sol's sleep line, shift86)
do
  local B=belt(40.5,0.5,4)
  lanes[B][1]={{8001,0.5,'iron-plate',2}}
  S.handler(p,{position={x=40.5,y=0.5},seconds=2,exact_tile=true})
  local job=storage.belt_flow[1]
  for t=game.tick+1,job.until_tick do game.tick=t; S.tick(t) end
  eq(job.result.exact_tile,true)
  local row=Mz.list(1,game.tick)[1]
  eq(row.state,'done'); eq(row.of,1)
  -- removed while sampling: invalid, its one tile gone
  S.handler(p,{position={x=40.5,y=0.5},seconds=2,exact_tile=true})
  job=storage.belt_flow[1]
  B.valid=false
  for t=game.tick+1,job.until_tick do game.tick=t; S.tick(t) end
  row=Mz.list(1,game.tick)[1]
  eq(row.state,'invalid'); has(row.line,'invalid: all 1 of what it reads gone or out of sight')
  print('d27_batch269 BS a finished exact_tile watch reads done: ok')
end
print('d27_batch269: ok')
