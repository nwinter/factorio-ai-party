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
eq(most,901,'the dense chunk and a border entity beside it')
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
-- 6. A band covers at most 32 chunks (operator 18:12: a band grown to 8 full rows over a sparse edge found a whole
-- base strip in one step): a box 120 chunks wide, empty above a dense strip; every entity still once.
ents,storage.walk_box={},{}
for x=0,119 do for k=0,9 do put(x*32+3*k+1.5,40*32+16.5) end end
put(0.5,0.5)
local most_chunks=0
local s_find=s.find_entities_filtered
s.find_entities_filtered=function(f)
  local a=f.area
  if a then most_chunks=math.max(most_chunks,(a[2][1]-a[1][1])/32*(a[2][2]-a[1][2])/32) end
  return s_find(f)
end
storage.walk_box[1]={left=0,right=119,top=0,bottom=40}
w=W.start(s)
eq(w.cols,32,'the first band')
n=read(w)
eq(n,#ents,'every entity once')
assert(most_chunks<=32,'a band of '..most_chunks..' chunks')
s.find_entities_filtered=s_find
print('walk: ok')

-- 7. (d22 batch110 BT1: census.walk made 15.4 KB of garbage a call on the private copy) a band reuses one filter and
-- one area table and returns the find's own table with the entities outside the band taken out. Every band gives the
-- same list in the same order, the same built box and the same next band as OLD (W.band before BT1: a new filter,
-- area and list each band); a field one caller's filter gave is not in the next caller's find; out_pos holds each
-- entity's position as the band read it, and each entity a find returns has its position read once.
do
  local function grow(b,x,y)
    if b.left==nil then b.left,b.right,b.top,b.bottom=x,x,y,y; return end
    if x<b.left then b.left=x elseif x>b.right then b.right=x end
    if y<b.top then b.top=y elseif y>b.bottom then b.bottom=y end
  end
  local function chunk(v) return math.floor(v/32) end
  local OLD_BOX={}
  local function OLD(w,sf,filter)
    if w.done then return nil end
    local built=OLD_BOX[sf.index] or {}; OLD_BOX[sf.index]=built
    local f={}; for k,v in pairs(filter) do f[k]=v end
    if w.whole then
      w.done=true
      local list=sf.find_entities_filtered(f)
      for _,e in ipairs(list) do grow(built,chunk(e.position.x),chunk(e.position.y)) end
      return list
    end
    local b=w.box
    if w.y>b.bottom then w.done=true; return nil end
    if w.x==b.left then w.band_rows=w.rows end
    local x1,y1=math.min(w.x+w.cols-1,b.right),math.min(w.y+w.band_rows-1,b.bottom)
    local X0,Y0,X1,Y1=w.x*32,w.y*32,(x1+1)*32,(y1+1)*32
    f.area={{X0,Y0},{X1,Y1}}
    local list={}
    for _,e in ipairs(sf.find_entities_filtered(f)) do
      local p=e.position
      if p.x>=X0 and p.x<X1 and p.y>=Y0 and p.y<Y1 then list[#list+1]=e; grow(built,chunk(p.x),chunk(p.y)) end
    end
    local width,maxc=b.right-b.left+1,w.max or 32
    if #list>250 then w.rows,w.cols=1,math.max(1,math.floor(w.cols/2))
    elseif #list*4<250 then
      if w.cols<width then w.cols=math.min(width,w.cols*2,math.max(1,math.floor(maxc/w.rows)))
      elseif w.rows<8 and w.rows*2*w.cols<=maxc then w.rows=w.rows*2 end
    end
    w.x=x1+1
    if w.x>b.right then w.x=b.left; w.y=y1+1 end
    w.bands=(w.bands or 0)+1
    return list
  end
  -- Entities that count their position reads (a new table each read, as the game's); a find returns a new table each
  -- call, the entities whose 3x3 box overlaps the area, of the filter's type, at most limit, and keeps a copy of each
  -- filter it was given.
  local reads,filters,world=0,{},{}
  local seed=7
  local function rnd(n) seed=(seed*1103515245+12345)%2147483648; return seed%n end
  for i=1,3000 do
    local x,y=rnd(640)-160+0.5,rnd(480)-96+0.5
    world[i]=setmetatable({id=i,type=(i%3==0) and 'inserter' or 'assembling-machine',x=x,y=y},
      {__index=function(_,k) if k=='position' then reads=reads+1; return {x=x,y=y} end end})
  end
  local sf={index=5}
  sf.find_entities_filtered=function(f)
    local copy={}; for k,v in pairs(f) do copy[k]=v end; filters[#filters+1]=copy
    local out,a={},f.area
    for _,e in ipairs(world) do
      local inside=not a or (e.x+1.5>a[1][1] and e.x-1.5<a[2][1] and e.y+1.5>a[1][2] and e.y-1.5<a[2][2])
      if inside and (not f.type or f.type==e.type) and (not f.limit or #out<f.limit) then out[#out+1]=e end
    end
    return out
  end
  local function same_box()
    local nb,ob=storage.walk_box[5],OLD_BOX[5]
    eq(nb.left,ob.left,'box left'); eq(nb.right,ob.right,'box right'); eq(nb.top,ob.top,'box top'); eq(nb.bottom,ob.bottom,'box bottom')
  end
  -- Walks w_new (this W.band) and w_old (OLD) side by side, from start(), with filter; out_pos given when with_pos.
  local function both(start,filter,with_pos)
    local w_new,w_old,bands=start(),start(),0
    while true do
      local pos=with_pos and {} or nil
      local n0=#filters
      reads=0
      local a,apos=W.band(w_new,sf,filter,pos)
      local b=OLD(w_old,sf,filter)
      eq(a==nil,b==nil,'both walks end together')
      if not a then break end
      bands=bands+1
      eq(#a,#b,'band '..bands..': as many entities')
      for i=1,#b do eq(a[i],b[i],'band '..bands..': entity '..i) end
      if with_pos then
        eq(apos,pos,'out_pos returned')
        for i=1,#a do eq(pos[i].x,a[i].x); eq(pos[i].y,a[i].y) end
      else eq(apos,nil,'no out_pos') end
      for k,v in pairs(w_old) do if type(v)~='table' then eq(w_new[k],v,'walk field '..k) end end
      local fn,fo=filters[n0+1],filters[#filters]
      for k,v in pairs(fo) do if k~='area' then eq(fn[k],v,'filter '..k) end end
      for k in pairs(fn) do assert(fo[k]~=nil,'a filter field the caller did not give: '..k) end
      if fo.area then for i=1,2 do for j=1,2 do eq(fn.area[i][j],fo.area[i][j],'area') end end end
    end
    same_box()
    return bands
  end
  storage.walk_box={}
  -- no box yet: one whole-surface find, the same list and box, no area
  eq(both(function() return {surface=5,whole=true} end,{type='assembling-machine'},true),1)
  eq(filters[#filters].area,nil,'a whole-surface find has no area')
  -- bands over the box: a filter with a limit, then one without (the limit does not stay), then one chunk a band
  assert(both(function() return W.start(sf) end,{type='assembling-machine',limit=40},true)>1)
  assert(both(function() return W.start(sf) end,{type='inserter'},false)>1)
  assert(both(function() return W.start(sf,nil,{max_chunks=1}) end,{type='assembling-machine'},true)>1)
  -- one position read an entity a find returned
  local w,returned=W.start(sf),0
  local kept=sf.find_entities_filtered
  sf.find_entities_filtered=function(f) local out=kept(f); returned=returned+#out; return out end
  reads=0
  while W.band(w,sf,{type='inserter'},{}) do end
  sf.find_entities_filtered=kept
  eq(reads,returned,'one position read an entity the finds returned')
end
print('walk BT1 the same bands with one filter: ok')
