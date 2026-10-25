-- d24 batch176 QS1 (Astra #2248): belt_flow {exact_tile=true} samples the two lanes of the belt at one tile only, by
-- item id: passed on (seen on what the tile feeds), taken from mid-lane, gone at the end unseen after, and the inserters
-- picking from the tile counted from their hands. A line blocked at its end reads stopped there; the tile where an
-- inserter takes reads the inserter's draw.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local force={name='player',is_chunk_visible=function() return true end,is_chunk_charted=function() return true end}
local inserters={}
local surf={name='platform-16',find_entities_filtered=function(f) assert(f.type=='inserter'); return inserters end}
game={tick=0,forces={player=force},get_surface=function() return surf end}
local storage={}
-- lanes[entity][line] = {{id,pos,name}}; positions count down to the lane's exit (0), as the game reads them
local lanes={}
local n=0
local function belt(x,y,dir,typ,lines)
  n=n+1
  local e={valid=true,unit_number=100+n,type=typ or 'transport-belt',name=typ=='splitter' and 'fast-splitter' or typ=='underground-belt' and 'fast-underground-belt' or 'fast-transport-belt',
    surface=surf,position={x=x,y=y},direction=dir,prototype={belt_speed=0.0625},belt_neighbours={inputs={},outputs={}}}
  lanes[e]={}
  for k=1,lines or 2 do lanes[e][k]={} end
  e.get_max_transport_line_index=function() return lines or 2 end
  e.get_transport_line=function(k) return {get_detailed_contents=function()
    local out={}
    for _,it in ipairs(lanes[e][k]) do out[#out+1]={unique_id=it[1],position=it[2],stack={valid_for_read=true,name=it[3]}} end
    return out end} end
  return e
end
local function inserter(x,y,px,py)
  local i={valid=true,name='fast-inserter',unit_number=900+#inserters,position={x=x,y=y},pickup_position={x=px,y=py},hand=0}
  i.held_stack=setmetatable({},{__index=function(_,k) if k=='valid_for_read' then return i.hand>0 elseif k=='count' then return i.hand elseif k=='name' then return 'explosives' end end})
  inserters[#inserters+1]=i
  return i
end
-- Asterion's explosives line, facing south: tile (13.5,25.5) feeds (13.5,26.5), which ends blocked
local T=belt(13.5,25.5,8)
local N=belt(13.5,26.5,8)
T.belt_neighbours.outputs={N}; N.belt_neighbours.inputs={T}
local ins=inserter(12.5,25.5,13.5,25.5)
inserter(14.5,27.5,13.5,27.5)  -- picks from another tile: not counted
local S=require('beltsample'){state=function() return storage end,remote_entity=function(_,a) local x,y=a.position.x or a.position[1],a.position.y or a.position[2]
  for e in pairs(lanes) do if math.abs(e.position.x-x)<(e.type=='splitter' and 1 or 0.5) and math.abs(e.position.y-y)<0.5 then return e end end error('no belt there') end,on_platform=function(p) return p end}
local p={index=1,force=force}
-- the left lane: an item comes on every 16 ticks and moves to the exit, then onto N (one of them taken at the boundary);
-- the right lane: 4 items stand, and every 32 ticks the inserter takes the one at 0.5 (its hand counts) and the queue
-- closes up; N stands full.
local nextid=1
local function step(t)
  local L=lanes[T][1]
  for i=#L,1,-1 do
    local it=L[i]
    it[2]=it[2]-0.0625
    if it[2]<0 then table.remove(L,i); if it[1]~=3 then table.insert(lanes[N][1],{it[1],0.9,it[3]}) end end
  end
  if t%16==0 then nextid=nextid+1; L[#L+1]={nextid,0.94,'explosives'} end
  if t%32==8 then
    local R=lanes[T][2]
    for i,it in ipairs(R) do if it[2]==0.5 then table.remove(R,i); break end end
    R[#R+1]={1000+t,0.5,'explosives'}
    ins.hand=ins.hand+1
  end
  if t%32==20 then ins.hand=0 end
end
lanes[T][2]={{901,0,'explosives'},{902,0.25,'explosives'},{903,0.5,'explosives'},{904,0.75,'explosives'}}
lanes[N][2]={{801,0,'explosives'},{802,0.25,'explosives'},{803,0.5,'explosives'},{804,0.75,'explosives'}}
local r=S.handler(p,{position={13.5,25.5},platform='Asterion',exact_tile=true,seconds=2})
eq(r.sampling,true); eq(r.exact_tile,true); eq(r.every_ticks,4)
eq(r.tile.name,'fast-transport-belt'); eq(r.tile.unit_number,T.unit_number); eq(r.tile.direction,'south')
eq(r.feeds,'fast-transport-belt (13.5,26.5)'); eq(#r.inserters,1); eq(r.inserters[1],'fast-inserter (12.5,25.5) #900')
has(r.note,'the tile (13.5,25.5) (fast-transport-belt #'..T.unit_number..' facing south) only, both lanes')
for t=1,121 do game.tick=t; step(t); S.tick(t) end
r=S.handler(p,{})
eq(r.done,true); eq(r.exact_tile,true)
-- left lane: the items that reached the exit; all but id 3 seen on N after; id 3 gone at the end, not seen there
eq(r.left.left,6); eq(r.left.passed_on,5); eq(r.left.not_seen_after,1); eq(r.left.taken,0); eq(r.left.rate,180)
-- right lane: the inserter's takes from mid-lane, and its hand counts the same
eq(r.right.taken,4); eq(r.right.passed_on,0); eq(r.right.taken_items,'explosives 4'); eq(r.right.state,'120/min'); eq(r.right.held,4)
eq(r.picked,4); eq(r.inserters[1].picked,4); eq(r.inserters[1].rate,120); eq(r.inserters[1].items,'explosives 4')
eq(r.lines[1],"tile (13.5,25.5) fast-transport-belt #"..T.unit_number.." facing south: left lane 180/min (explosives 6): 5 seen on fast-transport-belt (13.5,26.5) after, 0 gone from mid-lane (taken off this tile), 1 gone at the lane's end and not seen on it, 1 held; right lane 120/min (explosives 4): 0 seen on fast-transport-belt (13.5,26.5) after, 4 gone from mid-lane (taken off this tile), 0 gone at the lane's end and not seen on it, 4 held")
eq(r.lines[2],'inserters picking from this tile (their hands read each sample): fast-inserter (12.5,25.5) #900 picked 4 (120/min: explosives 4)')
-- the blocked end: both lanes stopped full, nothing picks there
inserters={}
lanes[N][1]={{701,0,'explosives'},{702,0.25,'explosives'},{703,0.5,'explosives'},{704,0.75,'explosives'}}
S.handler(p,{position={13.5,26.5},exact_tile=true,seconds=2})
for t=122,250 do game.tick=t; S.tick(t) end
r=S.handler(p,{})
eq(r.feeds,'nothing: the line ends here'); eq(r.rate,0)
eq(r.left.state,'stopped, full (4 explosives on the tile)'); eq(r.right.state,'stopped, full (4 explosives on the tile)')
eq(r.lines[2],'no inserter picks from this tile')
-- an underground entrance feeds its own hidden lines; a splitter's half picks its input lanes
local U=belt(20.5,5.5,8,'underground-belt',4); U.belt_to_ground_type='input'
lanes[U][1]={{501,0.1,'coal'}}
r=S.handler(p,{position={20.5,5.5},exact_tile=true,seconds=2})
eq(r.feeds,'its own underground lines'); eq(r.tile.underground,'entrance')
game.tick=251; lanes[U][1]={}; lanes[U][3]={{501,1.9,'coal'}}
for t=251,380 do game.tick=t; S.tick(t) end
r=S.handler(p,{}); eq(r.left.passed_on,1); eq(r.left.not_seen_after,0)
local SP=belt(30,5.5,0,'splitter',8)
lanes[SP][3]={{601,0.3,'stone'}}
r=S.handler(p,{position={30.5,5.5},exact_tile=true,seconds=2})
eq(r.tile.half,'right'); eq(r.feeds,"the splitter's outputs")
for t=381,510 do game.tick=t; S.tick(t) end
r=S.handler(p,{}); eq(r.left.held,1); has(r.lines[1],"(its right half's input lanes)")
r=S.handler(p,{position={29.5,5.5},exact_tile=true,seconds=2}); eq(r.tile.half,'left')
-- the line read stays the default
storage.belt_flow=nil
r=S.handler(p,{position={13.5,25.5},seconds=2}); eq(r.exact_tile,nil); eq(r.tiles,2)
fails(function() S.handler(p,{position={13.5,25.5},exact_tile='yes'}) end,'exact_tile: true or false')
print('d24_batch176: ok')
