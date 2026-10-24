-- Run from repository root: lua tests/nestbook.lua
-- The nest book (threat.lua, d24 batch163, Luna #2222, viewer Aurora): every confirmed nest on a surface with its
-- pollution and status, the defense {nests: true} read and the clouds read's reached nests.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^.5 end
local storage={}
-- Chunks x>=0 charted; x>=3 in view (radar).
local mine={name='player',valid=true,is_chunk_charted=function(_,c) return c.x>=0 end,is_chunk_visible=function(_,c) return c.x>=3 end,
  get_spawn_position=function() return {x=0,y=0} end}
local enemy={name='enemy',valid=true}
local polluted={['3,0']=7.25}
local list={}
local function add(type,x,y,u) local e={valid=true,type=type,force=enemy,position={x=x,y=y},unit_number=u}; list[#list+1]=e; return e end
local s1=add('unit-spawner',100,10,1); add('unit-spawner',110,12,2); local worm=add('turret',105,-5,3)  -- chunks (3,0), (3,-1): in view
local far=add('unit-spawner',40,40,4)   -- chunk (1,1): charted, not in view
add('unit-spawner',-40,20,5)            -- chunk (-2,0): not charted
local finds=0
local surface={index=1,name='nauvis',valid=true,
  get_pollution=function(pos) return polluted[math.floor(pos.x/32)..','..math.floor(pos.y/32)] or 0 end,
  find_entities_filtered=function(f)
    finds=finds+1
    assert(f.force=='enemy' and f.type[1]=='unit-spawner' and f.type[2]=='turret')
    local out={}
    for _,e in ipairs(list) do
      local q=e.position
      if e.valid and q.x>=f.area[1][1] and q.x<=f.area[2][1] and q.y>=f.area[1][2] and q.y<=f.area[2][2] then out[#out+1]=e end
    end
    return out
  end}
game={tick=1000,forces={player=mine,enemy=enemy},get_surface=function(i) return i==1 and surface or nil end}
local T=dofile('mod/agent-harness_0.1.0/threat.lua'){state=function() return storage end,distance=distance}
local p={index=1,force=mine,surface=surface,position={x=0,y=0}}

-- No book before a pass.
eq(T.nest_read(p,40).line,'no nest book for nauvis yet: it is made after the chart sweep there (an agent on the surface)')
-- A pass over the chart sweep's box of generated chunks (x -2..3, y -1..1), a band of up to 32 chunks a step.
local shared={force='player',surface=1,chart={gen={left=-2,right=3,top=-1,bottom=1}}}
storage.threat_shared={['player/1']=shared}
T.nest_step(storage,'player/1',shared,1000)  -- starts it
local b=storage.nest_book['player/1']
eq(b.job.rows,3); eq(b.job.every,600)   -- 3 steps, 600 ticks apart at most
local r=T.nest_read(p,40)
eq(r.count,0); eq(r.sweep,'a pass over the chart is running (row 1 of 3)')
for t=1000,1000+3*600,600 do game.tick=t; T.nest_step(storage,'player/1',shared,t) end
eq(finds,3); eq(b.job,nil); eq(b.swept,1000)
eq(#b.list,4,'the uncharted spawner is left out')

-- The read: grouped within 64 tiles, nearest the base centre first.
game.tick=5000
r=T.nest_read(p,40)
eq(r.count,2); eq(r.alive,1); eq(r.unknown,1); eq(r.destroyed,0); eq(r.reached,1); eq(r.book_tick,1000)
local near,base=r.nests[1],r.nests[2]
eq(near.position.x,40); eq(near.status,'unknown'); eq(near.seen,nil); eq(near.pollution_now,0); eq(near.pollution_reaches,false)
eq(near.line,'nest (40,40) 1 spawner, 0 worms, 57 tiles SE of base centre: unknown (not in view since charted); no pollution on its chunks now or remembered: does not reach it')
eq(base.position.x,105); eq(base.position.y,11); eq(base.spawners,2); eq(base.worms,1); eq(base.status,'alive'); eq(base.seen,5000)
eq(base.pollution_now,7.3); eq(base.pollution_reaches,true); eq(base.pollution_last,5000)
eq(base.line,'nest (105,11) 2 spawners, 1 worm, 106 tiles E of base centre: alive (in view now); pollution 7.3 on its chunks now: reaches it')
eq(r.line,'2 confirmed nests on nauvis (1 alive, 1 unknown, 0 destroyed); pollution reaches 1, from the pass at tick 1000')
eq(#T.nest_read(p,1).nests,1); eq(T.nest_read(p,1).more,'1 more: limit raises the count')

-- The cloud leaves: the nest counts as reached for 15 minutes from the last tick pollution was there, then not.
polluted['3,0']=nil
game.tick=5000+600*60
base=T.nest_read(p,40).nests[2]
eq(base.pollution_reaches,true); eq(base.pollution_last,5000)
eq(base.line,'nest (105,11) 2 spawners, 1 worm, 106 tiles E of base centre: alive (in view now); no pollution on its chunks now, last there 10m ago: reaches it')
game.tick=5000+54001
base=T.nest_read(p,40).nests[2]
eq(base.pollution_reaches,false)
assert(base.line:find('last there 15m ago: does not reach it',1,true),base.line)

-- The chart sweep remembers pollution on a nest chunk as a read there would.
polluted['1,1']=3
local chunks={{x=1,y=1}}
surface.get_chunks=function() local i=0; return function() i=i+1; return chunks[i] end end
storage.chart_jobs={['player/1']={start=game.tick,left=1,right=1,top=1,bottom=1,x=1,y=1,per=16}}
surface.is_chunk_generated=function() return true end
local radar_find=surface.find_entities_filtered
surface.find_entities_filtered=function(f) if f.type=='radar' then return {} end return radar_find(f) end
game.tick=game.tick+60
T.sweep_step(storage,'player/1',shared,game.tick)
eq(storage.nest_reach[1]['1,1'],game.tick)
surface.find_entities_filtered=radar_find
polluted['1,1']=nil

-- A worm killed in view: the nest stays alive, counting it; a nest out of view whose spawner is gone stays unknown
-- until its chunk is in view.
worm.valid=false; far.valid=false
game.tick=game.tick+60
r=T.nest_read(p,40)
base,near=r.nests[2],r.nests[1]
eq(base.status,'alive'); eq(base.members_gone,1)
assert(base.line:find('2 spawners, 1 worm (1 seen destroyed)',1,true),base.line)
eq(near.status,'unknown')
local seen_tick=game.tick
mine.is_chunk_visible=function(_,c) return c.x>=1 end
game.tick=game.tick+120
near=T.nest_read(p,40).nests[1]
eq(near.status,'destroyed'); eq(near.gone_tick,game.tick); eq(near.pollution_now,nil)
eq(near.line,'nest (40,40) 1 spawner, 0 worms, 57 tiles SE of base centre: destroyed (seen gone 0s ago)')
-- Out of view again: the spawners still there read unknown, last in view then.
mine.is_chunk_visible=function() return false end
game.tick=game.tick+3600*2
base=T.nest_read(p,40).nests[2]
eq(base.status,'unknown'); eq(base.seen,seen_tick+120)
assert(base.line:find('unknown (last in view 2m00s ago)',1,true) or base.line:find('unknown (last in view 2m ago)',1,true),base.line)

-- The clouds read: the nests pollution was on that are not seen destroyed, with that tick, status and seen.
shared.chart.cells={{3,0,7.3}}; shared.chart.tick=game.tick; shared.chart.pollutant={name='pollution'}
local c=T.operator.clouds({}).clouds[1]
eq(#c.reached,1)
local m=c.reached[1]
eq(m.position.x,105); eq(m.tick,5000); eq(m.ago_s,math.floor((game.tick-5000)/60+0.5)); eq(m.seen_ago_s,120); eq(m.status,'unknown'); eq(m.reaches,false); eq(m.seen,seen_tick+120); eq(m.spawners,2)
-- Destroyed nests are kept for 60 minutes, then dropped from the book.
game.tick=game.tick+216001
r=T.nest_read(p,40)
eq(r.count,1); eq(#b.list,2)

-- A new pass starts NEST_TICKS after the last one began, and finds a spawner placed since.
add('unit-spawner',120,20,6)
shared.chart.gen={left=-2,right=3,top=-1,bottom=1}  -- (the sweep above left a one-chunk chart)
local t0=game.tick
T.nest_step(storage,'player/1',shared,t0)
for t=t0,t0+3*600,600 do game.tick=t; T.nest_step(storage,'player/1',shared,t) end
eq(b.swept,t0); eq(T.nest_read(p,40).nests[1].spawners,3)

-- The defense read's nests mode goes to the book, with no area scan.
local D=dofile('mod/agent-harness_0.1.0/defense.lua'){state=function() return {} end,nest_read=function(q,limit) return {limit=limit,q=q} end}
local got=D.handlers.defense(p,{nests=true})
eq(got.limit,40); eq(got.q,p)
eq(D.handlers.defense(p,{nests=true,limit=3}).limit,3)
print('nestbook: ok')
