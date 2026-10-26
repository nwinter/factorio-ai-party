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
  local used=100  -- artillery shells used (item statistics): a shot adds one
  player.get_item_production_statistics=function() return {get_output_count=function() return used end} end
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
  local function within(f,p)
    if f.area then return p.x>=f.area[1][1] and p.y>=f.area[1][2] and p.x<=f.area[2][1] and p.y<=f.area[2][2] end
    if f.position then return (p.x-f.position.x)^2+(p.y-f.position.y)^2<=f.radius^2 end
    return true
  end
  surface.find_entities_filtered=function(f)
    finds[#finds+1]=f
    if f.force=='enemy' then
      local out={}
      for _,t in ipairs(enemy) do if within(f,t.position) then out[#out+1]=t end end
      return out
    end
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
  local r=A.read({pieces=true})
  eq(#r.pieces,1); eq(r.pieces[1].by,'opus'); eq(r.armed,0,'no nest index yet'); eq(r.every,10); eq(#r.shells,0)
  eq(A.read({}).pieces,1,'(batch224) their count unless asked for the rows')
  -- (batch224) the nest index: one box of 8x8 chunks a read over the piece's range (224 tiles: 9 boxes), never a find
  -- over the whole range
  local reads=1
  while r.armed==0 and reads<20 do r=A.read({pieces=true}); reads=reads+1 end
  eq(r.armed,1,'armed once the index is built'); eq(r.every,0.5); eq(r.pieces[1].targets,3)
  assert(reads<=11,'index built in '..reads..' reads')
  for _,f in ipairs(finds) do assert(not (f.force=='enemy' and f.radius and f.radius>16),'a find over the range') end
  -- (batch224) a shot: a shell 20 tiles out, 2.4 tiles off the line from the piece's centre (the muzzle's shift); seen
  -- once it is pending and the read asks for the next within 0.1 s
  local function on_path(x0,y0,k) local dx,dy=398.5-x0,-320.5-y0 local n=math.sqrt(dx*dx+dy*dy) return {x=x0+dx/n*k,y=y0+dy/n*k} end
  game.tick=1030; ammo=4; used=101
  shells={{position={x=318.5,y=-322.9},speed=1}}
  r=A.read({})
  eq(#r.shells,0); eq(r.pending,1); eq(r.every,0.2)
  -- seen again 6 ticks on: its path through both sightings reaches the nest
  game.tick=1036; shells={{position=on_path(318.5,-322.9,6),speed=1}}
  r=A.read({})
  eq(#r.shells,1,'resolved'); eq(r.pending,nil)
  local s=r.shells[1]
  eq(s.target.name,'big-spitter-nest'); eq(s.target.around,'1 medium-worm-turret'); eq(s.eta_ticks,74); eq(s.lands_tick,1110)
  eq(s.by,'opus'); eq(s.distance,100); eq(s.piece.position.x,298.5)
  -- a later shot elsewhere and a search that finds this shell again: the same shell followed, not a new sighting
  game.tick=1045; used=102; shells={{position=on_path(318.5,-322.9,15),speed=1}}
  r=A.read({})
  eq(#r.shells,0); eq(r.pending,nil,'known')
  -- one sighting from the piece's centre alone would have missed: the line from it through the first sighting passes
  -- the nest 9.6 tiles off (PERP 2.5)
  -- a shell on no target's path is left out
  game.tick=1200; used=103; shells={{position={x=310,y=-330}}}
  r=A.read({}); eq(r.pending,1)
  game.tick=1206; shells={{position={x=316,y=-336}}}
  r=A.read({}); eq(#r.shells,0); eq(r.pending,nil)
  -- nothing fired (shells used as before): no shell find
  local nfinds=#finds
  game.tick=1300; r=A.read({})
  for i=nfinds+1,#finds do assert(finds[i].type~='artillery-projectile','a shell find with nothing fired') end
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

-- (d26 batch224 AY, viewer Aurora 05:29) a flare past the automatic range: its shells get the flare's spot, the nest
-- there and who flared it; the half-second pace while a flare is kept; more than 16 pieces watched.
do
  game={tick=2000}
  local player={name='player'}
  player.get_entity_count=function(n) return n=='artillery-turret' and 20 or 0 end
  player.is_chunk_charted=function() return true end
  local used=500
  player.get_item_production_statistics=function() return {get_output_count=function() return used end} end
  local surface={name='nauvis'}
  local pieces={}
  for i=1,20 do
    pieces[i]={valid=true,type='artillery-turret',name='artillery-turret',unit_number=100+i,position={x=0.5,y=i*10+0.5},surface=surface,force=player,
      last_user={name='opus'},get_inventory=function() return {get_item_count=function() return 5 end} end}
  end
  local enemy={{name='big-spitter-nest',position={x=1402,y=11}},{name='medium-worm-turret',position={x=1398,y=8}},
    {name='small-worm-turret',position={x=1300,y=200}}}
  local shells={}
  surface.find_entities_filtered=function(f)
    if f.force=='enemy' then
      local out={}
      for _,t in ipairs(enemy) do
        if (t.position.x-f.position.x)^2+(t.position.y-f.position.y)^2<=f.radius^2 then out[#out+1]=t end
      end
      return out
    end
    if f.type=='artillery-projectile' then
      local out={}
      for _,sh in ipairs(shells) do
        if (sh.position.x-f.position.x)^2+(sh.position.y-f.position.y)^2<=f.radius^2 then out[#out+1]=sh end
      end
      return out
    end
    if f.force==player then return pieces end
    return {}
  end
  game.surfaces={nauvis=surface}
  game.get_surface=function(n) return n=='nauvis' and surface or nil end
  game.forces={player=player}
  local st={}
  local A=dofile('mod/agent-harness_0.1.0/artycam.lua'){state=function() return st end,range=function() return 627.2,32 end}
  local r=A.read({pieces=true})
  eq(#r.pieces,20,'all 20 pieces watched'); eq(r.armed,0); eq(r.every,10); eq(#r.shells,0)
  local flare={valid=true}
  A.flare{by='opus',flare=flare,position={x=1400,y=10},surface='nauvis'}
  game.tick=2030
  r=A.read({})
  eq(r.every,0.2,'a waiting flare: the fast pace'); eq(r.flares_waiting,1); eq(#r.shells,0)
  -- piece 1 at (0.5,10.5) fires: its shell 25 tiles out, 2.4 tiles off the centre line; seen again 6 ticks on
  local function on_path(x0,y0,k) local dx,dy=1400-x0,10-y0 local n=math.sqrt(dx*dx+dy*dy) return {x=x0+dx/n*k,y=y0+dy/n*k} end
  game.tick=2060; flare.valid=false; used=501
  shells={{position={x=25.5,y=8.1},speed=1}}
  r=A.read({}); eq(r.pending,1)
  game.tick=2066; shells={{position=on_path(25.5,8.1,6),speed=1}}
  r=A.read({})
  eq(#r.shells,1,'the flare shell is kept')
  local s=r.shells[1]
  eq(s.target.position.x,1400); eq(s.target.name,'big-spitter-nest'); eq(s.target.around,'1 medium-worm-turret')
  eq(s.flare.by,'opus'); eq(s.by,'opus'); eq(s.piece.position.y,10.5,'its piece: on the path behind it')
  assert(math.abs(s.eta_ticks-1368)<=1,s.eta_ticks); assert(math.abs(s.distance-1400)<=1,s.distance)
  eq(r.flares_waiting,0); eq(r.flares_kept,1); eq(r.every,0.2)
  -- a read 34 ticks after the last: SEARCH (4) pieces in turn, 42-tile finds; 12 ticks after: every piece, 20-tile finds
  game.tick=2100; used=510
  local n0,rmax=0,0
  local find0=surface.find_entities_filtered
  surface.find_entities_filtered=function(f) if f.type=='artillery-projectile' then n0=n0+1; rmax=math.max(rmax,f.radius) end return find0(f) end
  shells={}
  A.read({})
  assert(n0<=4,'searched '..n0)
  n0,rmax=0,0; game.tick=2112; used=520
  A.read({})
  eq(n0,19,'every piece at the fast pace but piece 1, cooling down after its shot'); eq(rmax,20)
  surface.find_entities_filtered=find0
  -- a shell on no flare's line: left out
  game.tick=2190; used=511; shells={{position={x=20,y=60}}}
  r=A.read({}); r=nil
  game.tick=2196; shells={{position={x=26,y=63}}}
  eq(#A.read({}).shells,0)
  -- the flare taken more than FLARE_AFTER ago: dropped, the slow pace again
  game.tick=2400; shells={}
  r=A.read({})
  eq(r.flares_kept,0); eq(r.every,10)
end
print('d17_artycam flares: ok')
