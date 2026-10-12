-- Director cameras (cameras.lua): lua mod/tests/cameras_test.lua (from vendor/factorio-harness)
-- A camera client that joined a new Space Age world in the intro cutscene ends it (exit_cutscene) and becomes a
-- characterless spectator with a clean view; one already a spectator is left as it is.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local assertions=0
local function eq(a,b) assertions=assertions+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
defines={controllers={character=1,spectator=2,cutscene=3,remote=4}}
local log={}
local function player(index,name,controller)
  local p={index=index,name=name,valid=true,connected=true,controller_type=controller,show_on_map=true,
    position={x=0,y=0},game_view_settings={show_hotkey_suggestions=true}}
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
  p.set_controller=function(c)
    assert(p.controller_type~=defines.controllers.cutscene,'set_controller during the cutscene')
    log[#log+1]='set_controller'; p.controller_type=c.type; p.last_controller=c
  end
  p.teleport=function() end
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
local st2={}
local cams2=require('cameras'){state=function() return st end,bot=function(n) return n=='luna' and api_bot or nil end,controlled=function() return false end}
cams2.set{player=2,follow='luna',zoom=1}
eq(c2.controller_type,defines.controllers.spectator); eq(log[1],'exit_remote_view')
print('cameras ok ('..assertions..' assertions)')
