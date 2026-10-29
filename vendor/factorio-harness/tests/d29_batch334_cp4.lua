-- d29 batch334 cp4 (operator 12:03: the exact bounds, no answer changes): lost_log's position entries dropped as the
-- ring writes over their rows, and the orphans from before pruned once; ghost_log's ring slots freed when a record is
-- forgotten or put again, and the dead slots from before cleared once; platform_alerts trims, once a minute, stale feeds,
-- old workers and gone platforms' records to what board, urgent and status read. (ores' positional cells: tests/ores.lua;
-- census's packed kind lists: tests/census.lua's maps.) Run from the harness root: lua tests/d29_batch334_cp4.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function count(t) local n=0 for _ in pairs(t or {}) do n=n+1 end return n end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
game={tick=100}
table_size=table_size or function(t) local n=0 for _ in pairs(t) do n=n+1 end return n end

-- 1: lost_log
do
  local S={}
  local L=dofile('mod/agent-harness_0.1.0/lostlog.lua'){state=function() return S end}
  local force,surface={name='player'},{name='nauvis'}
  local function die(i) game.tick=game.tick+1; L.died({force=force,surface=surface,name='stone-wall',position={x=i,y=0},quality={name='normal'},supports_direction=false},'small-biter') end
  die(0)
  L.rows_in('player','nauvis',nil)  -- the position index built
  for i=1,6100 do die(i) end
  local by=S.lost_log.pos['player|nauvis']
  eq(count(by.at),6000,'one entry a row the ring holds, none for rows written over')
  eq(by.n,6000)
  local rows=L.rows_in('player','nauvis',nil)
  eq(#rows,6000); eq(rows[1].x,6100,'newest first'); eq(rows[#rows].x,101)
  -- orphans from before this runtime: pruned once at the next death
  local S2={lost_log={rows={},next=1}}
  S=S2
  local L2=dofile('mod/agent-harness_0.1.0/lostlog.lua'){state=function() return S2 end}
  S2.lost_log.rows[1]={f='player',s='nauvis',n='stone-wall',x=1,y=1,t=50}
  S2.lost_log.next=2
  S2.lost_log.pos={['player|nauvis']={n=3,at={['stone-wall@1,1']={1,50},['stone-wall@2,2']={1,40},['stone-wall@3,3']={7,30}}}}
  game.tick=200
  L2.died({force=force,surface=surface,name='gun-turret',position={x=5,y=5},quality={name='normal'},supports_direction=false},nil)
  local b2=S2.lost_log.pos['player|nauvis']
  eq(S2.lost_log.pruned,true); eq(b2.at['stone-wall@2,2'],nil,'an orphan'); eq(b2.at['stone-wall@3,3'],nil,'an orphan')
  eq(b2.at['stone-wall@1,1'][1],1,'a live entry kept'); eq(b2.n,2,'the live one and the new death')
end
print('d29_batch334_cp4 1 lost_log positions: ok')

-- 2: ghost_log
do
  local S={}
  local G=dofile('mod/agent-harness_0.1.0/ghostlog.lua'){state=function() return S end,via=function() return nil end}
  local surface={name='nauvis'}
  local function ghost(x) return {valid=true,type='entity-ghost',ghost_name='stone-wall',name='entity-ghost',surface=surface,position={x=x,y=0}} end
  G.placed('sol',ghost(1)); G.placed('sol',ghost(2)); G.placed('sol',ghost(3))
  local L=S.ghost_log
  eq(L.ring[1],'nauvis|stone-wall|1,0'); eq(L.ring_clean,true)
  G.forget(ghost(2))
  eq(L.ring[2],nil,'a forgotten record frees its slot'); eq(L.map['nauvis|stone-wall|2,0'],nil)
  G.placed('luna',ghost(1))
  eq(L.ring[1],nil,'put again: its old slot freed'); eq(L.ring[4],'nauvis|stone-wall|1,0'); eq(L.map['nauvis|stone-wall|1,0'].a,'luna')
  eq(G.read(ghost(1)).by,'luna','read as before'); eq(G.read(ghost(3)).by,'sol')
  -- dead slots from before this runtime: cleared once
  local S2={ghost_log={map={['k1']={a='sol',t=1,i=1}},ring={'k1','gone','k1'},next=4,total=3,since=0,pidx={},pidx_done=true,
    tmap={},tring={'t-gone'},tnext=2,tsince=0}}
  local G2=dofile('mod/agent-harness_0.1.0/ghostlog.lua'){state=function() return S2 end}
  G2.stats()
  local L2=S2.ghost_log
  eq(L2.ring[1],'k1','its record lives here'); eq(L2.ring[2],nil,'no record behind it'); eq(L2.ring[3],nil,'its record lives in slot 1')
  eq(L2.tring[1],nil); eq(L2.ring_clean,true)
end
print('d29_batch334_cp4 2 ghost_log slots: ok')

-- 3: platform_alerts trim
do
  local S={}
  local live={valid=true,index=2,name='Lark',surface={name='platform-2'}}
  game={tick=3640,forces={player={platforms={live}}}}
  defines={space_platform_state={on_the_path=1}}
  local P=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return S end,who=function() return 'opus' end}
  S.platform_alerts={by={
    [2]={name='Lark',surface='platform-2',seq=4,total={hits=4},minutes={},workers={sol=3600,astra=3640-2*216000-1},feed={tick=10,tr={}},scan={tick=3600},hub={{tick=1}}},
    [9]={name='Gone',surface='platform-9',seq=7,total={hits=7},minutes={[1]={hits=1}},last_hit=500,creator='luna',workers={sol=1},
      feed={tick=3630},scan={tick=1},hub={{tick=1}},damaged={[5]={}},damaged_n=1,ring={1,2},fuel_trend={},scan_wanted=1}}}
  P.tick(3640)
  local by=S.platform_alerts.by
  eq(by[2].feed,nil,'a feed past FEED_TICKS'); eq(by[2].workers.sol,3600); eq(by[2].workers.astra,nil,'a worker past WORKER_TICKS')
  eq(by[2].scan.tick,3600,'a live platform keeps its scan'); eq(#by[2].hub,1)
  local gone=by[9]
  eq(gone.name,'Gone'); eq(gone.seq,7); eq(gone.total.hits,7); eq(gone.minutes[1].hits,1); eq(gone.last_hit,500); eq(gone.creator,'luna')
  for _,k in ipairs({'scan','feed','hub','damaged','damaged_n','ring','fuel_trend','scan_wanted','workers','surface'}) do
    if k~='surface' then eq(gone[k],nil,'a gone platform drops '..k) end
  end
  eq(gone.surface,'platform-9','its surface kept')
  -- not on other ticks
  S.platform_alerts.by[2].feed={tick=1}
  P.tick(3660)
  eq(S.platform_alerts.by[2].feed.tick,1,'only once a minute')
  -- a trimmed record used again (an index come back) gets its tables back
  local back={valid=true,index=9,name='Gone II',surface={name='platform-9'}}
  local r=P.hit_ring(back)
  eq(r.workers,nil)
  game.tick=3700
  P.note({force={platforms={back}}},'platform_schedule',{platform='Gone II'},{})
  eq(type(S.platform_alerts.by[9].workers),'table','rec gives it its workers again')
  game,defines=nil,nil
end
print('d29_batch334_cp4 3 platform_alerts trim: ok')
