-- Run from repository root: lua tests/d20_batch55.lua
-- d20 batch55 P1 (viewer Aurora, shift47 13:59: "Could factory snapshots retain their capture time after refresh errors
-- and reject older background results?"). The survey, threat's chart, game_alerts, the census and networks are tested
-- in their own files (tests/survey.lua, threat.lua, pushalerts.lua, census.lua, networks.lua); here snapfail.lua and
-- the ground watch.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
game={tick=0}

-- snapfail: the failure kept, the next try counted from it, an older result dropped, the reply's line.
do
  local S=require('snapfail')
  local f=S.failed('survey.lua:1: boom\nstack', 1000)
  eq(f.tick,1000); eq(f.error,'survey.lua:1: boom stack','one line')
  eq(#S.failed(string.rep('x',500),1).error,200,'bounded')
  eq(S.since(400,nil),400); eq(S.since(400,f),1000); eq(S.since(1200,f),1200,'a read since the failure')
  eq(S.older(500,600),true,'a job started before the read it would replace'); eq(S.older(700,600),false); eq(S.older(500,nil),false)
  game.tick=1600
  eq(S.line('the survey',400,f),'the last refresh of the survey failed 10s ago (survey.lua:1: boom stack); the survey is from 20s ago')
  eq(S.line('the survey',400,nil),nil); eq(S.line('the survey',1200,f),nil,'a failure before the read held is not its')
end
print('d20_batch55 snapfail: ok')

-- The ground watch (status alerts, reply hints): a pass that fails keeps the watch's tick, the alerts say its age and
-- the failure, the next pass starts WATCH_EVERY after it; a pass finishing after a newer watch (a force's first,
-- made in a reply) never replaces it.
do
  local st,boom={},nil
  local force={name='player'}
  local surface={index=1,name='nauvis',valid=true,count_entities_filtered=function() return 0 end,find_entities_filtered=function() return {} end}
  game.surfaces={surface}; game.forces={player=force}
  game.get_surface=function(i) return i==1 and surface or nil end
  local bands=0
  local G=dofile('mod/agent-harness_0.1.0/ground.lua'){state=function() return st end,distance=function() return 0 end,
    walk={every=function() return 1 end,due=function() return true end,start=function() return {} end,
      band=function(w) if boom then error(boom) end; bands=bands+1; if not w.went then w.went=true; return {} end end}}
  local function pass() repeat game.tick=game.tick+1; G.watch_tick(game.tick) until not (st.ground_jobs or {}).player end
  game.tick=10000
  G.watch_tick(game.tick); assert(st.ground_jobs.player,'a pass'); pass()
  local w=st.ground_watch.player
  eq(w.tick,10000,'the pass\'s start')
  game.tick=10000+1800; G.watch_tick(game.tick); assert(st.ground_jobs.player,'the next pass')
  boom='band read broke'
  game.tick=game.tick+1; G.watch_tick(game.tick)
  eq(st.ground_jobs.player,nil,'the pass ended'); eq(st.ground_errors.count,1)
  eq(st.ground_watch.player,w); eq(w.tick,10000,'the watch keeps its tick')
  local failed_at=game.tick
  game.tick=game.tick+600
  local lines=G.alerts({force=force})
  eq(#lines,1)
  eq(lines[1],string.format('the last refresh of the ground watch failed 10s ago (%s); the ground watch is from %ds ago',w.refresh_failed.error,
    math.floor((game.tick-10000)/60)))
  assert(w.refresh_failed.error:find('band read broke',1,true))
  boom=nil
  game.tick=failed_at+1799; G.watch_tick(game.tick); eq(st.ground_jobs.player,nil,'no pass within WATCH_EVERY of the failure')
  game.tick=game.tick+1; G.watch_tick(game.tick); assert(st.ground_jobs.player,'the pass after it')
  local start=st.ground_jobs.player.start
  -- the force's watch read at once in a reply (as before its first pass) while this pass runs
  st.ground_watch.player=nil; st.ground_bg=nil
  game.tick=game.tick+1
  local newer=G.watch(force)
  eq(newer.tick,game.tick); eq(G.alerts({force=force}),nil,'no pile, no failure')
  pass()
  assert(start<newer.tick)
  eq(st.ground_watch.player,newer,'the pass\'s older watch was dropped')
  -- Without a newer watch the next pass replaces it as before.
  game.tick=newer.tick+1800; G.watch_tick(game.tick); pass()
  assert(st.ground_watch.player~=newer and st.ground_watch.player.tick>newer.tick,'the next pass replaced it')
  game.surfaces,game.forces,game.get_surface=nil,nil,nil
end
print('d20_batch55 ground watch: ok')
