-- mt276 C (private: multi-team phase 2, part C). Run from the harness root: lua tests/mt276c.lua
-- The census per team force: one pass per force, the steps in turn a tick each, each pass reading only its force's
-- entities over its own walk box; reads by the asking force (or the team the call runs as).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={entity_status={working=1,low_power=2,no_power=3}}

do
  local function ent(name,typ,x,y,f) return {valid=true,type=typ,name=name,status=1,direction=0,position={x=x,y=y},force=f,force_index=f.index,
    get_recipe=function() return nil end} end
  local player,red={name='player',index=1,valid=true},{name='red',index=4,valid=true}
  local all={ent('stone-wall','wall',3.5,3.5,player),ent('stone-wall','wall',5.5,3.5,player),ent('iron-chest','container',8.5,3.5,player),
    ent('stone-wall','wall',1003.5,3.5,red),ent('iron-chest','container',1005.5,3.5,red)}
  local finds={}
  local sf={name='nauvis',index=1,valid=true}
  sf.find_entities_filtered=function(f)
    local out,a={},f.area
    if f.force and f.force.name then finds[f.force.name]=(finds[f.force.name] or 0)+1 end
    for _,e in ipairs(all) do
      local p=e.position
      if (f.force==nil or f.force==e.force) and (not a or (p.x>=a[1][1] and p.x<a[2][1] and p.y>=a[1][2] and p.y<a[2][2])) then out[#out+1]=e end
    end
    return out
  end
  game={tick=0,surfaces={sf},get_surface=function() return sf end,forces={player=player,red=red},players={}}
  prototypes={entity={},item={},get_entity_filtered=function() return {} end}
  -- the player force's box at the surface's index (as before), red's under 1|red
  local st={walk_box={[1]={left=0,right=0,top=0,bottom=0},['1|red']={left=31,right=31,top=0,bottom=0}}}
  local now='player'
  local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return st end,team_names=function() return {'player','red'} end,
    team_now=function() return now end}
  local t=20000
  while not ((st.census or {}).done and ((st.census_teams or {}).red or {}).done) and t<60000 do t=t+1; game.tick=t; C.tick(t) end
  local dp,dr=st.census.done,st.census_teams.red.done
  assert(dp and dr,'both passes ended')
  eq(dp.where.nauvis,2,'the player force\'s two walls (where counts the snapshot\'s types)'); eq(dr.where.nauvis,1,'red\'s one')
  eq(#C.chests_on(player,sf),1); eq(C.chests_on(red,sf)[1].position.x,1005.5)
  local held=C.typed(red,sf,{'container'})
  eq(#held,1); eq(held[1].force,red)
  eq(#C.typed(player,sf,{'container'}),1)
  assert(finds.player and finds.red,'each force\'s pass found with its own force')
  eq(st.walk_box[1].right<31 and true,true,'the player force\'s box never grew to red\'s base')
  -- reads with no force: the team the call runs as
  now='red'; eq(C.surface_buildings(sf),1)
  now='player'; eq(C.surface_buildings(sf),2)
  -- a force with no pass of its own: filtered reads take the player force's pass (as before), typed none
  local blue={name='blue',index=5,valid=true}
  eq(#C.chests_on(blue,sf),0); eq(C.typed(blue,sf,{'container'}),nil)
  -- the operator read as a team
  now='red'; eq(C.read{part='extras'}.ready,true)
  print('mt276 C census per force: ok')
end

-- walk.start with a force: a new team's box round its bots, never the generated chunks; players of that force only
do
  local st={threat_shared={['player/1']={chart={gen={left=-50,right=50,top=-50,bottom=50}}}}}
  local W=dofile('mod/agent-harness_0.1.0/walk.lua'){state=function() return st end}
  game={players={{surface={index=1},position={x=0,y=0},force={name='player'}}}}
  local s={index=1}
  local w=W.start(s,{{x=1000,y=0}},{max_chunks=1,force='red'})
  eq(w.key,'1|red'); eq(w.box.left,31-4); eq(w.box.right,31+4,'round the bot only (not the player force\'s player)')
  local p=W.start(s,{},{max_chunks=1,force='player'})
  eq(p.key,nil); eq(p.box.left,-50,'the player force: the generated chunks as before')
  -- a team with nothing on a surface (no box, bot or player of its own): nothing to walk; its own platform: one find
  local v=W.start({index=2},{},{max_chunks=1,force='red'})
  eq(v.done,true); eq(W.band(v,{index=2},{}),nil)
  local own=W.start({index=3,platform={force={name='red'}}},{},{max_chunks=1,force='red'})
  eq(own.whole,true)
  local other=W.start({index=3,platform={force={name='blue'}}},{},{max_chunks=1,force='red'})
  eq(other.done,true,'another team\'s platform: nothing')
  game.players[2]={surface={index=2},position={x=64,y=64},force={name='red'}}
  local mine=W.start({index=2},{},{max_chunks=1,force='red'})
  eq(mine.box.left,2-4,'a player of its own there: the box round it')
  print('mt276 C walk boxes per force: ok')
end
