-- d24 batch166 QI1 (operator 13:56: platform_plan {platform: "Asterion", support: true} held world n 388 ms in one tick,
-- 8271 entities chosen; Sol called it repeatedly): support is a job across ticks, at most SLICE units of work a call or
-- tick. Read a slice at a time, the plan is the one read in one go; the reply says how it was read; a running job
-- answers with its step; the plan comes once, page reads it again; a job of another runtime is dropped.
-- Run from the harness root: lua tests/d24_batch166.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
prototypes={entity={['underground-belt']={max_underground_distance=5}}}
game={tick=100}
local store={}
local function box(x,y,w,h) return {left_top={x=x-w/2,y=y-h/2},right_bottom={x=x+w/2,y=y+h/2}} end
local n=0
local function ghost(name,t,x,y,w,h,dir,extra)
  n=n+1
  local g={valid=true,type='entity-ghost',ghost_name=name,ghost_type=t,name='entity-ghost',position={x=x,y=y},direction=dir or 0,bounding_box=box(x,y,w,h),unit_number=n}
  for k,v in pairs(extra or {}) do g[k]=v end
  return g
end
-- floor x -8..39, y -8..7 round the hub (it crosses the chunk edge at x 32); tile ghosts x 40..47, y 0..9 beside it
local built,tile_ghosts={},{}
for x=-8,39 do for y=-8,7 do built[#built+1]={position={x=x,y=y}} end end
built[#built+1]={position={x=45,y=11}}
for x=40,47 do for y=0,9 do tile_ghosts[#tile_ghosts+1]={valid=true,type='tile-ghost',ghost_name='space-platform-foundation',position={x=x+0.5,y=y+0.5}} end end
local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},bounding_box=box(0,0,8,8),unit_number=900,prototype={selectable_in_game=true}}
-- a 3x3 machine across the chunk edge at x 32 (found by both chunks' finds); a ghost in the tile ghosts; a ghost far off
-- over empty space (links); a ring of ghosts enclosing a hole (holes); an underground pair over empty space (tunnels);
-- a lamp between floor and a tile (a stall); a ghost not chosen with names (a strand)
local edge={valid=true,name='assembling-machine-3',type='assembling-machine',position={x=32.5,y=0.5},bounding_box=box(32.5,0.5,3,3),unit_number=901,prototype={selectable_in_game=true}}
local ents={hub,edge,ghost('assembling-machine-2','assembling-machine',44.5,4.5,3,3),ghost('assembling-machine-2','assembling-machine',60.5,30.5,3,3)}
for x=20,26 do for y=20,26 do if x==20 or x==26 or y==20 or y==26 then ents[#ents+1]=ghost('stone-wall','wall',x+0.5,y+0.5,1,1) end end end
ents[#ents+1]=ghost('underground-belt','underground-belt',-12.5,2.5,1,1,4,{belt_to_ground_type='input'})
ents[#ents+1]=ghost('underground-belt','underground-belt',-9.5,2.5,1,1,4,{belt_to_ground_type='output'})
ents[#ents+1]=ghost('small-lamp','lamp',45.5,10.5,1,1)
local function inside(e,a)
  local b=e.bounding_box
  return b.right_bottom.x>a[1][1] and b.left_top.x<a[2][1] and b.right_bottom.y>a[1][2] and b.left_top.y<a[2][2]
end
local finds=0
local surface={valid=true,
  get_chunks=function()
    local list,i={},0
    for cx=-2,2 do for cy=-1,1 do list[#list+1]={x=cx,y=cy} end end
    return function() i=i+1; local c=list[i]; return c end
  end,
  get_tile=function(x,y)
    for _,t in ipairs(built) do if t.position.x==x and t.position.y==y then return {name='space-platform-foundation'} end end
    return {name='empty-space'}
  end,
  find_tiles_filtered=function(f)
    if not f.area then return built end
    local out={}
    for _,t in ipairs(built) do if t.position.x>=f.area[1][1] and t.position.x<f.area[2][1] and t.position.y>=f.area[1][2] and t.position.y<f.area[2][2] then out[#out+1]=t end end
    return out
  end,
  find_entities_filtered=function(f)
    finds=finds+1
    local list
    if f.type=='tile-ghost' then list=tile_ghosts
    elseif f.type=='entity-ghost' then list={} for _,e in ipairs(ents) do if e.type=='entity-ghost' then list[#list+1]=e end end
    elseif f.type then return {}
    else list=ents end
    local out={}
    for _,e in ipairs(list) do
      local b=e.bounding_box or box(e.position.x,e.position.y,1,1)
      if f.position then if math.abs(e.position.x-f.position.x)<=(f.radius or 0) and math.abs(e.position.y-f.position.y)<=(f.radius or 0) then out[#out+1]=e end
      elseif not f.area or inside({bounding_box=b},f.area) then out[#out+1]=e end
    end
    return out
  end}
local pl={name='Asterion',surface=surface,force='us',hub=hub}
local PP=require('platplan'){platform=function() return pl end,position=function(v) return v end,state=function() return store end}
local function strip(r)
  local out={}
  for k,v in pairs(r) do if k~='read' and k~='line' then out[k]=v end end
  out.line=r.line and r.line:gsub('; read .*$','')
  return out
end
local function same(a,b,path)
  path=path or 'reply'
  if type(a)~='table' or type(b)~='table' then eq(a,b,path); return end
  for k,v in pairs(a) do same(v,b[k],path..'.'..tostring(k)) end
  for k,v in pairs(b) do if a[k]==nil then error(path..'.'..tostring(k)..' only in the sliced plan') end end
end

-- in one go: the plan as before, read in this call
PP.SLICE=math.huge
local one=PP.read({},{platform='Asterion',support=true})
eq(one.read,'in this call'); has(one.line,'; read in this call')
eq(one.chosen,#ents,'the machine across the chunk edge chosen once')
assert(one.support.links>0 and one.support.holes==25 and one.support.tunnels==2,'links, the hole and the span planned')
assert(one.support.stalls>=1 and one.support.keep>0 and one.support.remove>0,'a stall, kept and removed tile ghosts')

-- a slice at a time: a running job answers with its step; the same call reads it; the plan is the same
PP.SLICE=40
local r=PP.read({},{platform='Asterion',support=true})
assert(r.support_job,'before: no job, the whole plan in one call: '..tostring(r.line))
eq(r.support_job.state,'running'); local id=r.support_job.job
has(r.line,'is read as a job across ticks'); has(r.line,'the same call again reads it')
local ticks=0
while true do
  game.tick=game.tick+1; ticks=ticks+1
  PP.tick()
  local again=PP.read({},{platform='Asterion',support=true})
  if not again.support_job then r=again; break end
  eq(again.support_job.job,id,'the same job read again')
  assert(ticks<5000,'the job ends')
end
assert(ticks>10,'read over many ticks: '..ticks)
has(r.read,'as job '..id..' across ticks')
same(strip(one),strip(r))
-- read once: the same call then starts a new job; page reads the last plan
local fresh=PP.read({},{platform='Asterion',support=true})
assert(fresh.support_job and fresh.support_job.job>id,'a new job after the plan was read')
local paged=PP.read({},{platform='Asterion',support=true,page=1})
eq(paged.support_job,nil,'page reads the last plan'); eq(paged.support.remove,one.support.remove)
-- an unread plan older than FRESH: a new job
for _=1,5000 do game.tick=game.tick+1; PP.tick() end
game.tick=game.tick+PP.FRESH+1
local stale=PP.read({},{platform='Asterion',support=true})
assert(stale.support_job,'an unread plan older than FRESH is not given')
-- an error found in a job comes with the next read
local bad=PP.read({},{platform='Asterion',support={positions={{x=500,y=500}}}})
local ok,err=pcall(function()
  for _=1,2000 do game.tick=game.tick+1; PP.tick(); bad=PP.read({},{platform='Asterion',support={positions={{x=500,y=500}}}}) end
end)
assert(not ok and tostring(err):find('nothing of ours at (500,500)',1,true),tostring(err))
-- a job of another runtime is dropped
for _,j in pairs(store.platplan_jobs.list) do j.v=0 end
PP.tick()
eq(next(store.platplan_jobs.list),nil,'jobs of another runtime dropped')
-- names: a ghost not chosen standing on a tile that would go is a strand
PP.SLICE=math.huge
local nm=PP.read({},{platform='Asterion',support={names={'stone-wall'}}})
assert(nm.support.strands>=1,'the machine ghost on the tile ghosts is a strand')
game,prototypes=nil,nil
print('d24_batch166 QI1 support as a job across ticks: ok')
