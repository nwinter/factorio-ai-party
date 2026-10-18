-- Director cameras (cameras.lua): lua mod/tests/cameras_test.lua (from vendor/factorio-harness)
-- A camera client that joined a new Space Age world in the intro cutscene ends it (exit_cutscene) and becomes a
-- characterless spectator with a clean view; one already a spectator is left as it is.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local assertions=0
local function eq(a,b) assertions=assertions+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
defines={controllers={character=1,spectator=2,cutscene=3,remote=4},
  alert_type={entity_destroyed=1,no_material_for_construction=2,turret_out_of_ammo=3,entity_under_attack=4}}
local log={}
local function player(index,name,controller)
  local p={index=index,name=name,valid=true,connected=true,controller_type=controller,show_on_map=true,
    position={x=0,y=0},game_view_settings={show_hotkey_suggestions=true},alerts_on={[1]=true,[2]=true,[3]=true,[4]=false}}
  p.is_alert_enabled=function(t) return p.alerts_on[t]==true end
  p.disable_alert=function(t) p.alerts_on[t]=false; return true end
  p.enable_alert=function(t) p.alerts_on[t]=true; return true end
  if controller~=defines.controllers.spectator then
    local c={valid=true}
    c.destroy=function() c.valid=false; log[#log+1]='destroy' end
    p.character=c
  end
  -- LuaPlayer methods are called with a dot (no self)
  p.exit_cutscene=function()
    assert(p.controller_type==defines.controllers.cutscene,'not in a cutscene')
    log[#log+1]='exit_cutscene'; p.controller_type=defines.controllers.character
  end
  -- As seen live (14:24): the remote view opens where the spectator stands,
  -- not at set_controller's position.
  p.set_controller=function(c)
    assert(p.controller_type~=defines.controllers.cutscene,'set_controller during the cutscene')
    log[#log+1]='set_controller'; p.controller_type=c.type; p.last_controller=c
  end
  p.teleport=function(pos,surface)
    p.position={x=pos.x,y=pos.y}; if surface then p.surface=surface end
    log[#log+1]='teleport'
  end
  p.exit_remote_view=function() log[#log+1]='exit_remote_view'; p.controller_type=defines.controllers.spectator end
  p.surface={name='nauvis'}
  return p
end
local people={player(1,'pog-cam1',defines.controllers.cutscene),player(2,'pog-cam2',defines.controllers.spectator)}
game={tick=300,connected_players=people,get_player=function(i) return type(i)=='number' and people[i] or nil end,
  get_surface=function() return nil end}
local st={}
local cams=require('cameras'){state=function() return st end,bot=function() return nil end,controlled=function() return false end}
cams.tick() -- tick 300: the recheck makes every connected director a spectator
local p=people[1]
eq(log[1],'exit_cutscene'); eq(log[2],'set_controller'); eq(log[3],'destroy')
eq(p.controller_type,defines.controllers.spectator); eq(p.game_view_settings.show_hotkey_suggestions,false)
eq(p.show_on_map,false)
eq(#log,3) -- pog-cam2 was a spectator already: nothing for it
-- a client that never was in a cutscene: no exit_cutscene call (it would error)
log={}
people[3]=player(3,'pog-cam3',defines.controllers.character)
cams.tick()
eq(log[1],'set_controller'); eq(people[3].controller_type,defines.controllers.spectator)
-- a map camera: the remote controller with chart rendering at a low zoom, kept through the 5 s recheck
log={}
game.get_surface=function(n) return n=='nauvis' and {name='nauvis'} or nil end
local r=cams.set{player=2,map=true,position={x=10,y=-20},zoom=0.08}
eq(r.ok,true); eq(r.camera.map,true)
local c2=people[2]
eq(c2.controller_type,defines.controllers.remote); eq(c2.last_controller.chart_mode_cutoff>0.08,true)
eq(c2.last_controller.position.x,10); eq(c2.zoom,0.08)
game.tick=600; cams.tick()
eq(c2.controller_type,defines.controllers.remote) -- not pulled back to spectator by the recheck
assert(not pcall(cams.set,{player=2,map=true,position={x=0,y=0},zoom=3}),'map zoom out of range accepted')
-- the next ordinary camera call: a spectator again, following its subject
people[4]=player(4,'luna',defines.controllers.character)
local api_bot={character={valid=true,position={x=5,y=5},surface={name='nauvis'}},position={x=5,y=5}}
log={}
local cams2=require('cameras'){state=function() return st end,bot=function(n) return n=='luna' and api_bot or nil end,controlled=function() return false end}
cams2.set{player=2,follow='luna',zoom=1}
eq(c2.controller_type,defines.controllers.spectator); eq(log[1],'exit_remote_view')
eq(c2.position.x,5); eq(c2.position.y,5) -- follow shots as before: on the subject
-- A base-map shot after following Luna shows the asked spot and zoom, not
-- Luna (14:24: every "Base map" shot was centred on the last subject).
c2.zoom=1
r=cams2.set{player=2,map=true,position={x=120,y=-40},zoom=0.1}
eq(c2.controller_type,defines.controllers.remote); eq(c2.position.x,120); eq(c2.position.y,-40); eq(c2.zoom,0.1)
eq(r.camera.position.x,120)
-- An entity the remote view centres on is dropped.
c2.centered_on={valid=true}
cams2.set{player=2,map=true,position={x=60,y=10},zoom=0.1}
eq(c2.centered_on,nil); eq(c2.position.x,60)
-- A view that drifts off the spot is put back on the next tick; one on it is left alone.
c2.position={x=5,y=5}
game.tick=601; cams2.tick()
eq(c2.position.x,60); eq(c2.position.y,10); eq(c2.controller_type,defines.controllers.remote)
log={}
game.tick=602; cams2.tick()
eq(#log,0)
-- Back to following: the spectator is on Luna again.
cams2.set{player=2,follow='luna',zoom=1}
eq(c2.controller_type,defines.controllers.spectator); eq(c2.position.x,5)
-- Alerts: a map shot turns the camera player's alerts off (their markers covered the base in the terrain frame);
-- the next camera call turns back on the ones it turned off, and leaves one that was off (under attack) off.
eq(c2.alerts_on[1],true); eq(c2.alerts_on[2],true); eq(c2.alerts_on[4],false)
cams2.set{player=2,map=true,position={x=60,y=10},zoom=0.1}
eq(c2.alerts_on[1],false); eq(c2.alerts_on[2],false); eq(c2.alerts_on[3],false); eq(c2.alerts_on[4],false)
cams2.set{player=2,map=true,position={x=70,y=10},zoom=0.1} -- map to map: still off
eq(c2.alerts_on[2],false)
cams2.set{player=2,follow='luna',zoom=1}
eq(c2.alerts_on[1],true); eq(c2.alerts_on[2],true); eq(c2.alerts_on[3],true); eq(c2.alerts_on[4],false)
eq(st.map_alerts[2],nil)
cams2.set{player=2,map=true,position={x=60,y=10},zoom=0.1}
eq(c2.alerts_on[2],false)
cams2.set{player=2,release=true} -- a release turns them back on too
eq(c2.alerts_on[2],true); eq(c2.alerts_on[4],false)
-- d17 16:40: a person put in spectator (or god) mode by the operator is not a director, and one recorded as a director
-- before this is forgotten: the recheck leaves them alone.
log={}
people[4]=player(4,'nick',defines.controllers.spectator)
st.directors=st.directors or {}; st.directors[4]=true
eq(cams.director(4),false); eq(st.directors[4],nil)
cams.tick()
for _,l in ipairs(log) do assert(l~='set_controller' or people[4].controller_type==defines.controllers.spectator) end
eq(people[4].show_on_map~=false,true)
-- d17 16:58: the alert reader is a person when one is connected, else a camera client, else none.
do
  local cam={index=1,valid=true,connected=true,name='pog-cam1'}
  local nick={index=4,valid=true,connected=true,name='nick'}
  local isdir=function(i) return i==1 end
  eq(cams.alert_reader({players={cam}},isdir),cam)
  eq(cams.alert_reader({players={cam,nick}},isdir),nick)
  eq(cams.alert_reader({players={{index=9,valid=true,connected=false}}},isdir),nil)
end
print('cameras ok ('..assertions..' assertions)')
