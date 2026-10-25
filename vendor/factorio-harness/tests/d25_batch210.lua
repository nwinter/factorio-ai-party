-- d25 batch210 QW1 (Sol #2368): belt_flow sampled every 16 ticks at a bulk inserter's pickup tile read 277/min where
-- the inserter took 746/min: an item the inserter takes in the tick it comes onto the tile is never on the lane. The
-- sample interval is now at most a lane's item spacing (8 ticks on a transport belt) and at most an inserter's half
-- swing; at each sampled tile where inserters pick, their hands are read each sample, items gone are looked for on what
-- the tile feeds, and the point's rate is passed on + picked.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function near(a,b,d) assert(type(a)=='number' and math.abs(a-b)<=d,tostring(a)..' not within '..d..' of '..tostring(b)) end
local force={name='player',is_chunk_visible=function() return true end,is_chunk_charted=function() return true end}
local inserters={}
local surf={name='nauvis',find_entities_filtered=function(f) assert(f.type=='inserter'); return inserters end}
game={tick=0,forces={player=force},get_surface=function() return surf end}
local storage={}
-- lanes[e][k] = {{id,pos,name}}; positions count down to the lane's exit (0)
local lanes,belts={}, {}
local function belt(x,y,dir)
  local e={valid=true,unit_number=100+#belts,type='transport-belt',name='transport-belt',surface=surf,position={x=x,y=y},direction=dir,
    prototype={belt_speed=0.03125},belt_neighbours={inputs={},outputs={}}}
  lanes[e]={{},{}}; belts[#belts+1]=e
  e.get_max_transport_line_index=function() return 2 end
  e.get_transport_line=function(k) return {get_detailed_contents=function()
    local out={}
    for _,it in ipairs(lanes[e][k]) do out[#out+1]={unique_id=it[1],position=it[2],stack={valid_for_read=true,name=it[3]}} end
    return out end} end
  return e
end
local function inserter(x,y,px,py,rot)
  local i={valid=true,name='bulk-inserter',unit_number=900+#inserters,position={x=x,y=y},pickup_position={x=px,y=py},hand=0,quality='normal',
    prototype={get_inserter_rotation_speed=function() return rot or 0.04 end}}
  i.held_stack=setmetatable({},{__index=function(_,k) if k=='valid_for_read' then return i.hand>0 elseif k=='count' then return i.hand elseif k=='name' then return 'uranium-ore' end end})
  inserters[#inserters+1]=i
  return i
end
-- a yellow line east along y=0.5: T1 (the source) -> T2 -> T3 -> T4 (the end); an empty belt side-loads into T3 from
-- the north, so the line has two sections (T1..T2, T3..T4) and three points: T2, the side belt, T4
local T1,T2,T3,T4=belt(1.5,0.5,4),belt(2.5,0.5,4),belt(3.5,0.5,4),belt(4.5,0.5,4)
local SB=belt(3.5,-0.5,8)
local line={T1,T2,T3,T4}
for i=2,4 do line[i].belt_neighbours.inputs={line[i-1]}; line[i-1].belt_neighbours.outputs={line[i]} end
table.insert(T3.belt_neighbours.inputs,SB); SB.belt_neighbours.outputs={T3}
-- an inserter picks from T2 and takes every even item in the tick it comes on; one picks from T4 and takes every item
-- in the tick it comes on (the end), or from the lane when items wait there. A hand holding 4 swings 12 ticks, drops,
-- and swings back 12 ticks before it picks again (a bulk inserter's half swing: 0.5 turn at 0.04 a tick)
local I2=inserter(2.5,1.5,2.5,0.5)
local I4=inserter(4.5,1.5,4.5,0.5)
inserter(6.5,1.5,6.5,0.5)  -- picks from another tile: not counted
local takes={[T2]={ins=I2,key='T2',take=function(id) return id%2==0 end},[T4]={ins=I4,key='T4',take=function() return true end}}
local truth={T2=0,T4=0,on=0}  -- items taken at T2, taken at T4, passed from T2 onto T3
local nextid=0
local function ready(ins,t) return not ins.drop_at and t>=(ins.ready_at or 0) and ins.hand<4 end
local function pick(ins,key,t) ins.hand=ins.hand+1; truth[key]=truth[key]+1; if ins.hand==4 then ins.drop_at=t+12 end end
local function step(t)
  for _,ins in ipairs({I2,I4}) do if ins.drop_at and t>=ins.drop_at then ins.hand=0; ins.drop_at=nil; ins.ready_at=t+12 end end
  for i=4,1,-1 do
    local e=line[i]; local L=lanes[e][1]
    table.sort(L,function(a,b) return a[2]<b[2] end)
    for j=#L,1,-1 do
      local it=L[j]; it[2]=it[2]-0.03125
      if it[2]<0 then
        local nx=line[i+1]; local tk=nx and takes[nx]
        if not nx then it[2]=0
        else
          table.remove(L,j)
          if tk and ready(tk.ins,t) and tk.take(it[1]) then pick(tk.ins,tk.key,t)
          else table.insert(lanes[nx][1],{it[1],it[2]+1,it[3]}); if nx==T3 then truth.on=truth.on+1 end end
        end
      end
    end
    if not line[i+1] then for j=2,#L do L[j][2]=math.max(L[j][2],L[j-1][2]+0.25) end end
  end
  local L4=lanes[T4][1]
  if #L4>0 and ready(I4,t) then table.remove(L4,1); pick(I4,'T4',t) end
  assert(#L4<4,'T4 backed up')
  if t%8==0 then nextid=nextid+1; table.insert(lanes[T1][1],{nextid,0.97,'uranium-ore'}) end
end
for t=1,200 do game.tick=t; step(t) end
local S=require('beltsample'){state=function() return storage end,remote_entity=function(_,a) local x,y=a.position.x or a.position[1],a.position.y or a.position[2]
  for _,e in ipairs(belts) do if math.abs(e.position.x-x)<0.5 and math.abs(e.position.y-y)<0.5 then return e end end error('no belt there') end,on_platform=function(p) return p end}
local p={index=1,force=force}
local r=S.handler(p,{position={1.5,0.5},seconds=10})
-- the item spacing on a transport belt (main: 16, half a tile)
eq(r.every_ticks,8); eq(#r.points,3)
local t0={T2=truth.T2,T4=truth.T4,on=truth.on}
for t=201,801 do game.tick=t; step(t); S.tick(t) end
r=S.handler(p,{})
eq(r.done,true)
local got={T2=truth.T2-t0.T2,T4=truth.T4-t0.T4,on=truth.on-t0.on}
-- T2: the lane read sees only the items that pass on; the hands count the takes; the rate is both
local A=r.points[1]
eq(A.kind,'section'); eq(#A.inserters,1); eq(A.inserters[1].inserter,'bulk-inserter (2.5,1.5) #900')
near(A.picked,got.T2,1); near(A.passed_on,got.on,1)
eq(A.lanes_rate,A.left.rate+A.right.rate); near(A.left.passed,got.on,1)
eq(A.rate,(A.passed_on+A.picked)*6)
near(A.rate,(got.T2+got.on)*6,6)
assert(A.lanes_rate<0.6*A.rate,A.lanes_rate..' vs '..A.rate)
has(r.lines[1],'/min through it: '..A.passed_on..' seen next on transport-belt (3.5,0.5) + '..A.picked..' picked by the inserters picking from it (bulk-inserter (2.5,1.5) #900 picked '..A.picked)
-- the side belt: no inserter, no change
eq(r.points[2].kind,'side'); eq(r.points[2].inserters,nil); eq(r.points[2].rate,0)
-- T4, the end: items taken as they come on are never on the lane (those waiting while the hand swings are)
local B=r.points[3]
assert(B.lanes_rate<0.5*B.rate,B.lanes_rate..' vs '..B.rate); eq(B.passed_on,0)
near(B.picked,got.T4,1); near(B.rate,got.T4*6,6); assert(B.rate>200,B.rate)
has(r.lines[3],'0 seen next on nothing: the line ends here + '..B.picked..' picked by the inserters picking from it (bulk-inserter (4.5,1.5) #901 picked '..B.picked)
eq(r.merges[1],string.format('merge at (3.5,0.5): line %g/min + belt (3.5,-0.5) 0/min in (%g/min), %g/min on after it',A.rate,A.rate,B.rate))
has(r.note,'a lane\'s rate (left) misses an item taken off the tile before a sample sees it there')
has(r.note,'a point with inserters picking from it has rate passed_on + picked')
-- lane entries: T2 saw the odd items come on
near(A.left.entered,got.on,1)
-- exact_tile at the end: through is the picks
r=S.handler(p,{position={4.5,0.5},exact_tile=true,seconds=5})
eq(r.every_ticks,8)
t0.T4=truth.T4
for t=802,1110 do game.tick=t; step(t); S.tick(t) end
r=S.handler(p,{})
near(r.through,truth.T4-t0.T4,1); eq(r.through,r.picked); eq(r.through_rate,r.picked_rate)
has(r.lines[3],'through the tile: '..r.through_rate..'/min (0 seen next on nothing: the line ends here + '..r.picked..' picked)')
-- a legendary bulk inserter (rotation 0.1 a tick: a half swing in 5 ticks) at a sampled tile: sampled every 5 ticks
inserter(4.5,-0.5,4.5,0.5,0.1)
r=S.handler(p,{position={1.5,0.5},seconds=2}); eq(r.every_ticks,5)
r=S.handler(p,{position={4.5,0.5},exact_tile=true,seconds=2}); eq(r.every_ticks,5)
inserters[#inserters]=nil
-- a sample begun before this (no hands, entries or next in storage) runs on and reads as before
r=S.handler(p,{position={1.5,0.5},seconds=2})
for _,pt in ipairs(storage.belt_flow[1].points) do pt.hands, pt.entered, pt.next, pt.next_text, pt.passed_on=nil, nil, nil, nil, nil end
for t=1111,1240 do game.tick=t; step(t); S.tick(t) end
r=S.handler(p,{})
eq(r.done,true); eq(r.points[1].inserters,nil); eq(r.points[1].left.entered,nil); eq(r.points[3].rate,r.points[3].left.rate+r.points[3].right.rate); eq(r.points[3].lanes_rate,nil)
print('d25_batch210: ok')
