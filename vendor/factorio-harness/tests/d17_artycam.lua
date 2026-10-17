-- Run from the harness root: lua tests/d17_artycam.lua
-- artillery_live (viewer Foobator 12:48: show an artillery shell's impact): our pieces, the shells just fired, each
-- with the target on its line and when it lands, and who loaded the piece.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

do
  defines={inventory={artillery_turret_ammo=1,artillery_wagon_ammo=2}}
  game={tick=1000}
  prototypes={get_entity_filtered=function() return {['artillery-turret']=true,['artillery-wagon']=true} end}
  local player={name='player'}
  local counts={['artillery-turret']=1}
  player.get_entity_count=function(n) return counts[n] or 0 end
  player.is_chunk_charted=function() return true end
  local ammo=5
  local finds={}
  local surface={name='nauvis'}
  local piece={valid=true,type='artillery-turret',name='artillery-turret',unit_number=7,position={x=298.5,y=-320.5},surface=surface,force=player,
    artillery_auto_targeting=true,last_user={name='astra'},get_inventory=function() return {get_item_count=function() return ammo end} end}
  local shells={}
  local enemy={
    {name='big-spitter-nest',position={x=398.5,y=-320.5}},   -- 100 tiles east: on the shell's line
    {name='medium-worm-turret',position={x=401,y=-318}},      -- beside it
    {name='biter-spawner',position={x=298.5,y=-200.5}},       -- south: another line
  }
  surface.find_entities_filtered=function(f)
    finds[#finds+1]=f
    if f.force=='enemy' then return enemy end
    if f.type=='artillery-projectile' then return shells end
    if f.force==player then return {piece} end
    return {}
  end
  game.surfaces={nauvis=surface}
  game.get_surface=function(n) return n=='nauvis' and surface or nil end
  game.forces={player=player}
  local st={}
  local A=dofile('mod/agent-harness_0.1.0/artycam.lua'){state=function() return st end,range=function() return 224,32 end}
  -- Opus loads it by hand: the loader is named over the piece's last_user
  A.put('opus',{x=298.5,y=-320.5},'nauvis',{{name='artillery-shell',count=5}},'artillery-turret')
  local r=A.read({})
  eq(#r.pieces,1); eq(r.pieces[1].by,'opus'); eq(r.armed,1); eq(r.every,0.5); eq(#r.shells,0)
  -- a shell 20 tiles out toward the nest: it lands in 80 ticks
  game.tick=1030; ammo=4
  shells={{position={x=318.5,y=-320.6},speed=1}}
  r=A.read({})
  eq(#r.shells,1)
  local s=r.shells[1]
  eq(s.target.name,'big-spitter-nest'); eq(s.target.around,'1 medium-worm-turret'); eq(s.eta_ticks,80); eq(s.lands_tick,1110)
  eq(s.by,'opus'); eq(s.distance,100)
  local key=s.key
  -- read again 15 ticks on: the same shell, the same key
  game.tick=1045; shells={{position={x=333.5,y=-320.6},speed=1}}
  r=A.read({})
  eq(r.shells[1].key,key,'one shell, one key'); eq(r.shells[1].eta_ticks,65)
  -- a shell on no target's line is left out
  shells={{position={x=310,y=-330}}}
  eq(#A.read({}).shells,0)
  -- the shell find stays small: within 48 tiles
  local last
  for _,f in ipairs(finds) do if f.type=='artillery-projectile' then last=f end end
  assert(last.radius<=48,tostring(last.radius))
  -- empty, nothing fired lately: not armed, the slow pace
  ammo=0; game.tick=5000; shells={}
  r=A.read({})
  eq(r.armed,0); eq(r.every,10)
end
print('d17_artycam artillery_live: ok')
