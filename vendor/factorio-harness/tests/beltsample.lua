-- belt_flow (batch24 B2, Astra ~10 times on Kestrel): a belt line cut at its merges, each section's last tile and each
-- merging belt sampled by item id; items a minute that left, and a stopped lane told from a moving full one.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=0}
local storage={}
local n=0
-- contents(e,k,tick) -> {{id,pos,name}}
local function belt(x,y,dir,contents)
  n=n+1
  local e={valid=true,unit_number=n,type='transport-belt',name='transport-belt',position={x=x,y=y},direction=dir,
    prototype={belt_speed=0.03125},belt_neighbours={inputs={},outputs={}}}
  e.get_transport_line=function(k) return {get_detailed_contents=function()
    local out={}
    for _,it in ipairs(contents and contents(e,k,game.tick) or {}) do out[#out+1]={unique_id=it[1],position=it[2],stack={valid_for_read=true,name=it[3]}} end
    return out end} end
  return e
end
-- moving: one iron-plate a tile every 32 ticks on the left lane (a new id each time), its position moving
local function moving(name,base) return function(_,k,t) if k==1 then local id=base+math.floor(t/32); return {{id,(t%32)/32,name}} end return {} end end
-- stopped: 4 coal on the right lane, never moving
local function stopped(_,k) if k==2 then return {{900,0.1,'coal'},{901,0.35,'coal'},{902,0.6,'coal'},{903,0.85,'coal'}} end return {} end
local function both(a,b) return function(e,k,t) local x=a(e,k,t); for _,v in ipairs(b(e,k,t)) do x[#x+1]=v end return x end end
-- main line east along y=0, x=1..6; a side belt at (4,-1) facing south side-loads onto (4,0)
local main={}
for x=1,6 do main[x]=belt(x+0.5,0.5,4,x<=3 and both(moving('iron-plate',0),stopped) or both(moving('iron-plate',0),stopped)) end
for x=2,6 do main[x].belt_neighbours.inputs={main[x-1]}; main[x-1].belt_neighbours.outputs={main[x]} end
local side=belt(4.5,-0.5,8,moving('copper-plate',1000))
table.insert(main[4].belt_neighbours.inputs,side); side.belt_neighbours.outputs={main[4]}
local S=require('beltsample'){state=function() return storage end,remote_entity=function(_,a) for _,b in ipairs(main) do if b.position.x==a.position.x then return b end end error('no belt there') end,
  on_platform=function(p) return p end}
local p={index=1}
local r=S.handler(p,{position={x=2.5,y=0.5},seconds=2})
eq(r.sampling,true); eq(r.tiles,6); eq(r.every_ticks,16); eq(#r.points,3)
eq(r.points[1],'section end (3.5,0.5)'); eq(r.points[2],'merging belt (4.5,-0.5) into (4.5,0.5)'); eq(r.points[3],'section end (6.5,0.5)')
local mid=S.handler(p,{}); eq(mid.sampling,true); eq(mid.seconds_left,2)
for t=1,140 do game.tick=t; S.tick(t) end
r=S.handler(p,{})
eq(r.done,true); eq(r.samples,9)
-- 4 iron-plates left each section end in 128 ticks: 112.5 a minute; the right lane's 4 coal never moved
eq(r.points[1].left.passed,4); eq(r.points[1].left.rate,112.5); eq(r.points[1].left.items,'iron-plate 4')
eq(r.points[1].right.state,'stopped, full (4 coal on the tile)'); eq(r.points[1].right.rate,0)
eq(r.points[2].kind,'side'); eq(r.points[2].left.items,'copper-plate 4')
eq(r.lines[1],'section (1.5,0.5) to (3.5,0.5) (3 tiles): left lane 112.5/min (iron-plate 4); right lane stopped, full (4 coal on the tile)')
eq(r.lines[2],'belt (4.5,-0.5) merging into (4.5,0.5): left lane 112.5/min (copper-plate 4); right lane empty')
eq(r.merges[1],'merge at (4.5,0.5): line 112.5/min + belt (4.5,-0.5) 112.5/min in (225/min), 112.5/min on after it')
-- (d17 batch35 B2) the side-load's side and lane, the mix after it, and the limit (the end's right lane backed up)
eq(r.lane_mix[1],"side-load at (4.5,0.5): belt (4.5,-0.5) facing south comes in from the line's left side (the line faces east): both its lanes go onto the line's left lane; after it the left lane carries iron-plate 4, the right stopped, full (4 coal on the tile)")
eq(r.limit,'the end is backed up on its right lane at (6.5,0.5) (4 coal)')
-- a side-load stopped full while the lane after it runs at its cap: the straight line goes first
do
  local function cap(_,k,t) if k==1 then local out={} for i=0,3 do out[#out+1]={5000+math.floor(t/8)*4+i,((t%8)/8+i)/4,'calcite'} end return out end return {} end
  local L={}
  for x=1,4 do L[x]=belt(x+0.5,10.5,4,cap) end
  for x=2,4 do L[x].belt_neighbours.inputs={L[x-1]}; L[x-1].belt_neighbours.outputs={L[x]} end
  local sd=belt(3.5,9.5,8,function(_,k) return {{7000+k*10,0.1,'carbon'},{7001+k*10,0.35,'carbon'},{7002+k*10,0.6,'carbon'},{7003+k*10,0.85,'carbon'}} end)
  table.insert(L[3].belt_neighbours.inputs,sd); sd.belt_neighbours.outputs={L[3]}
  local S2=require('beltsample'){state=function() return storage end,remote_entity=function(_,a) for _,b in ipairs(L) do if b.position.x==a.position.x then return b end end end,on_platform=function(q) return q end}
  game.tick=200
  S2.handler({index=3},{position={x=1.5,y=10.5},seconds=2})
  for t=201,340 do game.tick=t; S2.tick(t) end
  local r2=S2.handler({index=3},{})
  eq(r2.limit,"a side-load waits at (3.5,10.5): belt (3.5,9.5) is stopped full of 4 carbon while the line after it runs at its cap (450/min a lane): the line's own items go first")
end
-- arguments
fails(function() S.handler(p,{position={x=2.5,y=0.5},seconds=1}) end,'seconds: 2..30')
storage.belt_flow=nil
fails(function() S.handler({index=2},{}) end,'no belt_flow sampled yet')
print('beltsample: ok')
