-- Run from repository root: lua tests/walk.lua
-- Whole-surface reads in bands of chunks (walk.lua; operator 04:00: whole-surface finds in single steps burst to
-- 138 ms in a game second): every entity once, a band sized to find about 250, the box from where the force built,
-- the players and (before any walk) the threat chart's generated chunks; steps spread over a job's period.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
storage={}
game={tick=0,players={}}
local W=dofile('mod/agent-harness_0.1.0/walk.lua'){state=function() return storage end}
-- A fake surface: entities with positions; a find by area returns those whose 3x3 box overlaps it (as the game does
-- for entities that only touch the area), and counts the chunks it covered.
local ents,swept,finds={},0,0
local s={index=1,find_entities_filtered=function(f)
  finds=finds+1
  local out,a={},f.area
  if a then swept=swept+(a[2][1]-a[1][1])/32*(a[2][2]-a[1][2])/32 end
  for _,e in ipairs(ents) do
    local p=e.position
    if not a or (p.x+1.5>a[1][1] and p.x-1.5<a[2][1] and p.y+1.5>a[1][2] and p.y-1.5<a[2][2]) then out[#out+1]=e end
  end
  return out
end}
local function put(x,y) ents[#ents+1]={position={x=x,y=y},id=#ents+1} end
-- A base 10 chunks wide: a dense block of 900 in one chunk, a sparse line across, entities on chunk borders.
for i=0,29 do for j=0,29 do put(64+1+i,64+1+j) end end
for x=0,319,8 do put(x+0.5,200.5) end
put(31.5,100.5); put(32.5,100.5); put(64,64)
local function read(w)
  local seen,n,most,bands={},0,0,0
  while true do
    local list=W.band(w,s,{type='assembling-machine'})
    if not list then break end
    bands=bands+1; most=math.max(most,#list)
    for _,e in ipairs(list) do assert(not seen[e.id],'once: '..e.id); seen[e.id]=true; n=n+1 end
  end
  return n,most,bands
end
-- 1. Nothing known: one whole-surface find; the built box comes from what it found.
local w=W.start(s)
eq(w.whole,true)
local n=read(w)
eq(n,#ents); eq(finds,1)
local b=storage.walk_box[1]
eq(b.left,0); eq(b.right,9); eq(b.top,2); eq(b.bottom,6)
-- 2. Bands over the box grown by 4 chunks: every entity once (the border ones too). A band's size follows the band
-- before it, so the one that meets the dense chunk finds it with its neighbours (the job reads 150 a step anyway).
finds,swept=0,0
w=W.start(s)
eq(w.box.left,-4); eq(w.box.right,13); eq(w.box.top,-2); eq(w.box.bottom,10)
local most,bands
n,most,bands=read(w)
eq(n,#ents,'every entity once')
eq(most,903,'the dense chunk and the 3 border entities beside it')
assert(bands<=40,'bands: '..bands)
eq(swept,18*13,'every chunk of the box once')
-- 3. A player far off: the box reaches the player, 4 chunks around.
game.players={{surface={index=1},position={x=1000,y=-500}}}
w=W.start(s)
eq(w.box.right,math.floor(1000/32)+4); eq(w.box.top,math.floor(-500/32)-4)
game.players={}
-- 4. Before any walk, a surface the threat chart swept: its generated chunks.
storage.threat_shared={['player/2']={chart={gen={left=-10,right=10,top=-5,bottom=5}}}}
local w2=W.start({index=2})
eq(w2.whole,nil); eq(w2.box.left,-10); eq(w2.box.bottom,5)
-- 5. Pacing: 4 ticks a step before any pass; then 80% of the period over the last pass's steps; a pass past that goes
-- on every 4 ticks.
eq(W.every(nil,1800),4); eq(W.every(30,1800),48); eq(W.every(1,18000),600)
local job={start=100,every=48}
eq(W.due(job,120,1800),false); eq(W.due(job,148,1800),true); eq(W.due(job,170,1800),false); eq(W.due(job,196,1800),true)
job.last=1539; eq(W.due(job,1541,1800),false); eq(W.due(job,1543,1800),true,'past 80%: every 4')
print('walk: ok')
