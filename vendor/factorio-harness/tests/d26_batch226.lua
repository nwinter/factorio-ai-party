-- Run from the harness root: lua tests/d26_batch226.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
-- d26 batch226 QM (Sol #2423: Weaver's 600 s collector_tally in flight caught 103 and inferred 26,644). In flight every
-- chunk also drifts with the platform's frame (on a copy, Weaver at 3.77 km a tick: +0.789 tiles in 10 ticks beyond
-- its movement), so none sat within 0.5 of where its movement put it and each read counted every watched chunk gone.
-- The tally now matches a chunk by its name and movement, measures the frame's drift from those matches, predicts and
-- traces paths in that frame, and names the reads the platform moved at.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
defines={inventory={asteroid_collector_output=1},entity_status={working=1},flow_precision_index={one_minute=1,ten_minutes=3}}
prototypes={asteroid_chunk={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={}},item={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={}}}
game={tick=1000,surfaces={},forces={}}
local produced={}
local force={name='player',get_item_production_statistics=function() return {
  get_flow_count=function() return 0 end,get_input_count=function(n) return produced[n] or 0 end} end}
game.forces.player=force
local chunks={}
local nextk=0
local function chunk(name,x,y,mx,my) chunks[#chunks+1]={name=name,position={x=x,y=y},movement={mx,my}} end
local function inside(c,a) return c.position.x>=a.left_top.x and c.position.x<=a.right_bottom.x and c.position.y>=a.left_top.y and c.position.y<=a.right_bottom.y end
-- a collector at (0.5,-20.5) facing north on the hull's north edge (y -20 and below it), oxide only; its output a count
local held=0
local col={valid=true,name='asteroid-collector',position={x=0.5,y=-20.5},direction=0,prototype={collection_box_offset=5},quality={name='normal'},status=1,
  filter_slot_count=1,get_filter=function(i) return i==1 and {name='oxide-asteroid-chunk'} or nil end,
  get_inventory=function() return {get_contents=function() return {} end,get_item_count=function(n) return (n==nil or n=='oxide-asteroid-chunk') and held or 0 end} end}
local function on_hull(x,y) return y>=-20 and math.abs(x)<=40 end
local surface={index=4,find_entities_filtered=function(f) return f.type=='asteroid-collector' and {col} or {} end,
  get_chunks=function() local done=false; return function() if done then return nil end done=true; return {area={left_top={x=-32,y=-32},right_bottom={x=32,y=32}}} end end,
  count_tiles_filtered=function() return 1 end,
  get_tile=function(x,y) return {valid=true,name=on_hull(x,y) and 'space-platform-foundation' or 'empty-space'} end}
game.surfaces[4]=surface
local pl={valid=true,name='Weaver',surface=surface,force=force,speed=0,
  find_asteroid_chunks_filtered=function(f) local out={} for _,c in ipairs(chunks) do if not f.area or inside(c,f.area) then out[#out+1]=c end end return out end}
local states={}
local C=dofile('mod/agent-harness_0.1.0/collectreach.lua'){state=function() return states end}
local reach=C.reach(col)
-- the game: each tick a chunk moves by its movement and the frame's drift; the collector takes an oxide 0.2 inside its
-- reach once its arm is back (20 ticks); one that reaches the hull is gone; new chunks come in from the north
local truth, struck, ready, frame = 0, 0, 0, 0
local function spawn(t)
  nextk=nextk+1
  local name=nextk%3==0 and 'metallic-asteroid-chunk' or 'oxide-asteroid-chunk'
  local x=((nextk*7)%17)-8
  -- each its own movement (2.0.77 keeps a chunk's movement read to read)
  chunk(name,x,-34,(nextk%5-2)*0.0004+nextk*1e-7,frame>0 and 0.002+nextk*1e-7 or 0.05+nextk*1e-7)
end
local function step(t)
  for i=#chunks,1,-1 do
    local c=chunks[i]
    c.position={x=c.position.x+c.movement[1],y=c.position.y+c.movement[2]+frame}
    if c.name=='oxide-asteroid-chunk' and t>=ready and C.outside(reach,c.position)<=-0.2 then
      table.remove(chunks,i); truth=truth+1; held=held+1; ready=t+20
    elseif on_hull(c.position.x,c.position.y) then table.remove(chunks,i); struck=struck+1 end
  end
  if t%15==0 then spawn(t) end
  if held>0 and t%30==0 then held=held-1 end  -- an inserter would pick it up; here the output keeps what is in it
end
local function run(p,secs)
  -- the field already streaming in
  for t=game.tick-1200,game.tick-1 do step(t) end
  truth, struck=0, 0
  produced['oxide-asteroid-chunk']=0
  C.start(p,pl,secs)
  local t0=game.tick
  for t=t0+1,t0+secs*60 do
    game.tick=t; step(t); produced['oxide-asteroid-chunk']=truth
    C.tick(t)
  end
  return C.tally(p,pl)
end
-- in flight: Weaver's speed, the frame drifting 0.0789 tiles a tick south (+y), chunks with slow movement of their own
held=0
pl.speed, frame = 3.77, 0.0789
local p={index=1}
local t=run(p,20)
assert(truth>=20,'chunks caught in flight: '..truth)
eq(t.done,true)
-- the inferred count comes to the catch (main: every watched chunk counted gone at each read, hundreds)
assert(math.abs(t.gone_in_reach_total-truth)<=2,'in flight, inferred '..t.gone_in_reach_total..' against '..truth..' taken')
eq(t.moving.reads,t.moving.of_reads); eq(t.moving.reads,121); eq(t.moving.speed_max_km_s,226)
assert(math.abs(t.moving.drift_max-4.7)<=0.1,t.moving.drift_max)
has(t.line,'; the platform moved at 121 of 121 reads (ticks ')
has(t.line,', up to 226 km/s), the chunks drifting with its frame up to ')
has(t.note,'a chunk is matched read to read by its name and movement')
assert(t.hit_hull>0,'chunks passing the reach struck the hull')
-- docked: no drift, chunks coming in on their own movement; the same count, and no moving
local q={index=2}
chunks={}; pl.speed, frame = 0, 0
game.tick=game.tick+2000
t=run(q,20)
assert(truth>=20,'chunks caught docked: '..truth)
assert(math.abs(t.gone_in_reach_total-truth)<=2,'docked, inferred '..t.gone_in_reach_total..' against '..truth..' taken')
eq(t.moving,nil); assert(not t.line:find('the platform moved',1,true))
print('d26_batch226 QM collector tally in flight: ok')
