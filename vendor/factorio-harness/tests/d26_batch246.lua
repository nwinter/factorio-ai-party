-- Run from repository root: lua tests/d26_batch246.lua
-- d26 batch246 FL (Astra #2461: in trial 242 Asterion lost a floor tile at (-50,-60), tick 67333569, and rebuilt it,
-- with no entity lost or hit; platform_loss and platform_hit count entities only, so a queued safe-return plan could
-- not react to bare-floor damage). platform_foundation_loss {platform, since_tick?, at_least?}: a wait_until condition
-- and queue guard met on foundation tiles of that platform destroyed since it began, from flightwatch.lua's loss log
-- (the hub's rebuilds on ghosts no one placed, and a find of such ghosts at most once a second while it is checked).
-- Floor placed on purpose (an agent's ghost, a player's ghost) is left out; a tile lost and rebuilt between two reads
-- is counted; saw and a fired guard's evidence name each tile's position and ticks; a guard edit keeps its baseline.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(type(s)=='string' and s:find(x,1,true),tostring(s)..'\n  lacks: '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2},events={on_space_platform_built_tile=77}}
prototypes={item={['repair-pack']={type='repair-tool'}},entity={},
  quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5}}}
local FOUNDATION='space-platform-foundation'
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
-- the platform: its tiles (key x,y), its tile ghosts
local tiles,ghosts,unit={},{},1000
local surface={index=9,name='platform-41'}
local finds=0
surface.find_entities_filtered=function(f)
  if f.name=='tile-ghost' then
    assert(f.force==force and f.limit,'our tile ghosts, a limited find')
    finds=finds+1
    local out={}
    for _,g in pairs(ghosts) do if #out<f.limit then out[#out+1]=g end end
    return out
  end
  return {}
end
local pl={valid=true,index=41,name='Asterion',surface=surface,force=force}
surface.platform=pl
local other={valid=true,index=42,name='Wren',surface={index=10,name='platform-42',find_entities_filtered=function() return {} end},force=force}
force.platforms={pl,other}
game={tick=100,forces={player=force}}
local st={}
local G=dofile('mod/agent-harness_0.1.0/ghostlog.lua'){state=function() return st end}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function() return pl end,hits=function() return {hits=0,damage=0,entities={},by={}} end,
  ghost_owner=function(g) return G.owner(g) end,ghost_owner_at=function(s,name,pos) return G.owner_at(s,name,pos,true) end,
  ghost_forget_tile=function(s,name,pos) return G.forget_tile(s,name,pos) end,built_tile_heard=function() return true end}
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
  floor_losses=function(q,tick) return F.loss_scan(q,tick),F.LOSS_KEEP end}
local function key(x,y) return x..','..y end
local function ghost(x,y,user)
  unit=unit+1
  local g={valid=true,type='tile-ghost',name='tile-ghost',ghost_name=FOUNDATION,position={x=x+0.5,y=y+0.5},unit_number=unit,
    quality={name='normal'},surface=surface,last_user=user}
  ghosts[key(x,y)]=g
  return g
end
-- an asteroid: the tile goes and the game's ghost (no last user) comes, with no event
local function strike(x,y) tiles[key(x,y)]=nil; ghost(x,y) end
-- the hub (or a robot) builds one: the ghost goes, the tile comes, the event
local function build(x,y)
  assert(ghosts[key(x,y)],'a ghost at '..key(x,y))
  ghosts[key(x,y)]=nil; tiles[key(x,y)]=true
  F.on_built_tile{name=77,tick=game.tick,platform=pl,tile={name=FOUNDATION},item={name=FOUNDATION},quality={name='normal'},
    tiles={{old_tile={name='empty-space'},position={x=x,y=y}}}}
end
local sol={index=1,name='sol',position={x=0,y=0},surface={name='nauvis'},force=force}
for x=-60,40 do for y=-70,5 do tiles[key(x,y)]=true end end

-- 1. a tile destroyed before anything read the platform: open when the guard begins; neither it nor its rebuild counts
strike(-50,-60)
game.tick=1000
local g={['until']='platform_foundation_loss',platform='Asterion'}
C.validate(g)
local met,saw=C.check(sol,g)
eq(met,false); eq(saw,'platform Asterion: no foundation tile of it destroyed since tick 1000'); eq(g.fl_since,1000,'kept on the condition')
eq(finds,1,'one find at the first check')
-- the checks within LOSS_SCAN ticks read no ghosts again
game.tick=1030; eq((C.check(sol,g)),false); eq(finds,1,'no second find within a second')

-- 2. floor placed on purpose: an agent's ghost (the ghost log) and a player's (last_user), found and built: not counted
game.tick=1040
local a=ghost(41,0); G.placed('astra',a)
ghost(42,0,{name='nick'})
game.tick=1100; eq((C.check(sol,g)),false,'placed ghosts found')
game.tick=1120; build(41,0); build(42,0)
-- an agent's ghost placed and built between two finds (its record newer than the last find)
game.tick=1130; local b=ghost(43,0); G.placed('sol',b); game.tick=1140; build(43,0)
-- an agent mines a tile and lays one by hand: no ghost, no platform build
tiles[key(30,0)]=nil; tiles[key(30,0)]=true
-- the tile open since before the guard is rebuilt now: not counted
game.tick=1150; build(-50,-60)
game.tick=1200
met,saw=C.check(sol,g)
eq(met,false); eq(saw,'platform Asterion: no foundation tile of it destroyed since tick 1000')

-- 3. a tile destroyed and rebuilt between two checks: counted, from the hub's rebuild
game.tick=1210; strike(13,-20)
game.tick=1290; build(13,-20)
game.tick=1300
met,saw=C.check(sol,g)
eq(met,true); eq(saw,'platform Asterion: 1 foundation tile destroyed since tick 1000: (13,-20) lost and rebuilt between reads (after tick 1200), rebuilt at tick 1290')
eq(#g.evidence,1); eq(g.evidence[1].x,13); eq(g.evidence[1].y,-20); eq(g.evidence[1].after,1200); eq(g.evidence[1].rebuilt,1290); eq(g.evidence[1].seen,nil)

-- 4. a tile destroyed with the hub out of foundation: counted when a find first sees its ghost; its rebuild later
-- fills in the row and adds none
game.tick=1340; strike(20,-5)
game.tick=1400
met,saw=C.check(sol,g)
eq(met,true); eq(saw,'platform Asterion: 2 foundation tiles destroyed since tick 1000: (13,-20) lost and rebuilt between reads (after tick 1200), rebuilt at tick 1290, (20,-5) ghost first seen at tick 1400 (lost after tick 1300), not rebuilt yet')
game.tick=1450; build(20,-5)
game.tick=1500
met,saw=C.check(sol,g)
eq(met,true); has(saw,'2 foundation tiles destroyed since tick 1000'); has(saw,'(20,-5) ghost first seen at tick 1400 (lost after tick 1300), rebuilt at tick 1450')
eq(g.evidence[2].seen,1400); eq(g.evidence[2].rebuilt,1450)

-- 5. at_least, since_tick back through the log, a wait's own record, another platform
local three={['until']='platform_foundation_loss',platform='Asterion',at_least=3,since_tick=1000}
C.validate(three)
met,saw=C.check(sol,three)
eq(met,false); has(saw,'2 foundation tiles destroyed since tick 1000 (met at 3): (13,-20)')
eq(three.evidence,nil,'no evidence before it is met')
local late={['until']='platform_foundation_loss',platform='Asterion',since_tick=1295}
met,saw=C.check(sol,late)
eq(met,true); has(saw,'1 foundation tile destroyed since tick 1295: (20,-5)')
local rec={}
local w={['until']='platform_foundation_loss',platform='Asterion'}
eq((C.check(sol,w,nil,rec)),false); eq(rec.fl_since,1500); eq(w.fl_since,nil,'a wait keeps its start on its record')
eq((C.check(sol,{['until']='platform_foundation_loss',platform='Wren'})),false,'another platform')

-- 6. a guard begun after a find from long ago: a ghost found then may have been lost before it, not counted
game.tick=1600
local w2={['until']='platform_foundation_loss',platform='Wren'}
eq((C.check(sol,w2)),false)
other.surface.find_entities_filtered=function() return {{valid=true,type='tile-ghost',name='tile-ghost',ghost_name=FOUNDATION,position={x=2.5,y=2.5},unit_number=1,quality={name='normal'}}} end
game.tick=5000
local fresh={['until']='platform_foundation_loss',platform='Wren',since_tick=4990}
met,saw=C.check(sol,fresh)
eq(met,false); eq(saw,'platform Wren: no foundation tile of it destroyed since tick 4990')
-- the older wait, begun before that find, counts it (lost after tick 1600)
met,saw=C.check(sol,w2)
eq(met,true); eq(saw,'platform Wren: 1 foundation tile destroyed since tick 1600: (2,2) ghost first seen at tick 5000 (lost after tick 1600), not rebuilt yet')

-- 7. more than the ring holds between two checks: all counted, the first 8 named
game.tick=5100
for i=1,F.LOSS_KEEP+4 do strike(i-60,-1); build(i-60,-1) end
game.tick=5200
local many={['until']='platform_foundation_loss',platform='Asterion',since_tick=5000}
met,saw=C.check(sol,many)
-- since_tick before the ring's oldest row: counted from its oldest
eq(met,true); has(saw,F.LOSS_KEEP..' foundation tiles destroyed since tick 5000'); has(saw,', +'..(F.LOSS_KEEP-8)..' more')
eq((C.check(sol,g)),true); local _,s2=C.check(sol,g); has(s2,(F.LOSS_KEEP+6)..' foundation tiles destroyed since tick 1000')

-- 8. refusals
fails(function() C.validate({['until']='platform_foundation_loss'}) end,'platform_foundation_loss requires platform')
fails(function() C.validate({['until']='platform_foundation_loss',platform='Asterion',at_least=0}) end,'at_least')
fails(function() C.validate({['until']='platform_foundation_loss',platform='Asterion',at_least=1001}) end,'at_least')
C.validate({['until']='platform_foundation_loss',platform='Asterion',at_least=1000})
fails(function() C.validate({['until']='platform_foundation_loss',platform='Asterion',since_tick=99999}) end,'platform_foundation_loss since_tick is a game tick up to now')
fails(function() C.check(sol,{['until']='platform_foundation_loss',platform='Nope'}) end,'no platform of ours named Nope')
print('d26_batch246 FL the loss log and the condition: ok')

-- 9. the queues: the remote and platform lanes take it as a wait and a guard; dry_run refuses what a submit refuses;
-- a guard edit keeps its baseline; the fired guard keeps the tiles in its history
do
  local lanes=dofile('mod/agent-harness_0.1.0/queue_lanes.lua')
  local checked
  local function factory(api) checked=api.check_step; return {handlers={},schema={queue_submit={}}} end
  pcall(lanes,{scheduler={handlers={},schema={queue_submit={}}},base={player=function() end,busy=function() end},factory=factory,is_read=function() return false end})
  assert(checked,'the lane check')
  checked('wait_until',{['until']='platform_foundation_loss',platform='Asterion',at_least=2})
  checked('wait_until',{['until']='any',conditions={{['until']='platform_foundation_loss',platform='Asterion'},{['until']='platform_hit',platform='Asterion'}}})
  fails(function() checked('wait_until',{['until']='platform_foundation_loss'}) end,'platform_foundation_loss')
end
do
  local qst={}
  local base={state=function() return qst end,player=function() return sol end,handlers={platform_schedule=function() return {ok=true} end},
    condition=function(p,c) return C.check(p,c) end,wait_check=function(p,c,record) return C.check(p,c,nil,record) end,
    validate_condition=function(c) C.validate(c) end,busy=function() return false end,stop=function() end,stop_index=function() end}
  local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
  local S=dofile('mod/agent-harness_0.1.0/queue_lanes.lua'){scheduler=factory(base),factory=factory,base=base,is_read=function() return false end}
  local function run(n) for _=1,n do game.tick=game.tick+1; S.tick() end end
  local lane='platform:Asterion'
  local steps={{action='wait_ticks',args={ticks=50000}}}
  -- dry_run and the submit refuse the same at_least; 1000 passes both
  local bad={{when={['until']='platform_foundation_loss',platform='Asterion',at_least=1001}}}
  local okd,errd=pcall(S.handlers.queue_submit,sol,{lane=lane,steps=steps,guards=bad,dry_run=true})
  local oks,errs=pcall(S.handlers.queue_submit,sol,{lane=lane,steps=steps,guards=bad})
  assert(not okd and not oks,'both refuse at_least 1001'); has(tostring(errd),'at_least'); eq(tostring(errd),tostring(errs),'the same refusal')
  local d=S.handlers.queue_submit(sol,{lane=lane,steps=steps,guards={{when={['until']='platform_foundation_loss',platform='Asterion',at_least=1000}}},dry_run=true})
  eq(d.dry_run,true); local q0=(qst['lane_queues|Asterion'] or {})[1]; assert(not q0 or (#q0.pending==0 and not q0.current and #(q0.guards or {})==0),'dry_run queues nothing')
  -- the plan: a long wait, a foundation guard and an ammo guard
  game.tick=6000
  local q=S.handlers.queue_submit(sol,{lane=lane,steps=steps,guards={{when={['until']='platform_foundation_loss',platform='Asterion'},steps={{action='platform_schedule',args={platform='Asterion',current=1}}}},
    {when={['until']='platform_loss',platform='Asterion',names={'thruster'}}}}})
  eq(q.guards[1].id,'guard-1'); eq(q.guards[1].when.fl_since,6000,'counted from the submit')
  run(50)
  local lq=qst['lane_queues|Asterion'][1]
  -- the edit: the loss guard removed, the foundation guard kept with its baseline
  local r=S.handlers.queue_edit(sol,{lane=lane,expected_revision=lq.revision,guards={remove={'guard-2'}}})
  eq(r.guards[1].id,'guard-1'); eq(r.guards[1].edit,'kept'); eq(r.guards[1].since_tick,6000)
  eq(r.guards[1].baseline,'foundation tiles of Asterion destroyed since tick 6000')
  eq(lq.guards[1].when.fl_since,6000); assert(lq.guards[1].when.fl_seq,'its place in the log kept')
  -- a tile destroyed and rebuilt between two guard checks fires it
  game.tick=6100; strike(-50,-60); game.tick=6105; build(-50,-60)
  run(20)
  eq(#lq.guards,0,'the guard fired')
  local fired
  for _,h in ipairs(lq.history) do if h.action=='guard' then fired=h end end
  assert(fired,'the guard in the history')
  eq(fired.result.condition,'platform_foundation_loss')
  has(fired.result.saw,'platform Asterion: 1 foundation tile destroyed since tick 6000: (-50,-60) lost and rebuilt between reads')
  has(fired.result.saw,'rebuilt at tick 6105')
  eq(fired.result.evidence[1].x,-50); eq(fired.result.evidence[1].y,-60); eq(fired.result.evidence[1].rebuilt,6105)
end
print('d26_batch246 FL the lanes, dry_run, guard edit and fired evidence: ok')
