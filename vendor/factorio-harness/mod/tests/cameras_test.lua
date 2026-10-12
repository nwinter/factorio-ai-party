-- Director cameras (cameras.lua): lua mod/tests/cameras_test.lua (from vendor/factorio-harness)
-- A camera client that joined a new Space Age world in the intro cutscene ends it (exit_cutscene) and becomes a
-- characterless spectator with a clean view; one already a spectator is left as it is.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local assertions=0
local function eq(a,b) assertions=assertions+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
defines={controllers={character=1,spectator=2,cutscene=3}}
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
    log[#log+1]='set_controller'; p.controller_type=c.type
  end
  p.teleport=function() end
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
print('cameras ok ('..assertions..' assertions)')
