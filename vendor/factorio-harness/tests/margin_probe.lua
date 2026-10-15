package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
game={tick=0,forces={player={name='player'},enemy={name='enemy'}}}
prototypes={entity={['biter-spawner']={result_units={}}}}
local force=game.forces.player
force.get_friend=function() return false end
force.get_cease_fire=function() return false end
local state,paths,asked={},{},{}
local surface={name='nauvis',index=1}
local hazard={valid=true,name='biter-spawner',type='unit-spawner',position={x=50,y=42.5},force=game.forces.enemy}
surface.find_entities_filtered=function() return {hazard} end
surface.request_path=function(a) asked[#asked+1]=a; return #asked end
local p={index=1,position={x=0,y=0},surface=surface,force=force,walking_state={walking=false},
  character={prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}}}}
local A=require('avoid'){state=function() return state end,charted=function() return true end,leg=function() return false end}
local P=require('margin_probe'){avoid=A,paths=function() return paths end}
local function nav(pad) return {position={x=100,y=0},path_state='unsafe',foes={mode=A.mode(pad),goal={x=100,y=0}}} end
local n=nav(4)
local count=0
while P.tick(p,n) do
  game.tick=game.tick+1; count=count+1; assert(count<500)
  local q=n.margin_probe
  if q.id then
    local id=q.id; local r=asked[id]
    -- The engine bends every leg through the same narrow corridor, including
    -- geometrically clear detours. A margin of 3 must reject that engine path.
    assert(P.on_path(n,{id=id,path={{position=r.start},{position={x=50,y=0}},{position=r.goal}}}))
  end
  eq(p.position.x,0); eq(p.position.y,0); eq(p.walking_state.walking,false)
end
local r=n.margin_probe.result
eq(r.largest_verified_margin,2); eq(r.tested[1].margin,3); eq(r.tested[1].verified,nil)
eq(r.closest.name,'biter-spawner'); eq(r.closest.distance,42.5); eq(r.closest.clearance,2.5)
assert(r.closest.nest:find('biter-spawner',1,true)); assert(not r.line:find('\n',1,true))
eq(r.to.x,100); eq(n.path_state,'unsafe'); assert(#r.via>0)
eq(P.on_path(n,{id=-1,path={}}),false,'stale path')
-- Exhaustion records the tested margins without claiming the world has no route.
n=nav(2); count=0
while P.tick(p,n) do
  game.tick=game.tick+1; count=count+1; assert(count<100)
  if n.margin_probe.id then P.on_path(n,{id=n.margin_probe.id}) end
end
eq(n.margin_probe.result.largest_verified_margin,nil); eq(#n.margin_probe.result.tested,2)
assert(n.margin_probe.result.line:find('no complete route verified',1,true))
-- Busy engine responses retry, bounded by ticks, without issuing a request per tick.
n=nav(2)
while not (n.margin_probe and n.margin_probe.id) do P.tick(p,n); game.tick=game.tick+1 end
P.on_path(n,{id=n.margin_probe.id,try_again_later=true})
local requests=#asked
assert(P.tick(p,n)); eq(#asked,requests)
game.tick=game.tick+P.MAX_TICKS+1
eq(P.tick(p,n),false); assert(n.margin_probe.result.line:find('budget',1,true))
-- Numeric margins stay hard at endpoints, after retry exhaustion, and through
-- an engine bend. Default margin relaxation remains separately covered in avoid.lua.
local strict={position={x=100,y=0},tolerance=0.5}
A.start(p,strict,A.mode(4)); strict.foes.detours=A.MAX_DETOURS
local chunks=A.chunks_near({p.position,strict.position},52)
A.scan(surface,force,chunks,#chunks)
eq(A.accept(p,strict,{{position={x=100,y=0}}}),false)
eq(strict.path_state,'unsafe'); eq(strict.foes.passed,nil)
-- Inside the margin at the start: do not shrink/skip the disc, even if the goal
-- is far away. The character has not been commanded to walk inside its minimum.
p.position={x=50,y=0}; strict={position={x=150,y=0},tolerance=0.5}
A.start(p,strict,A.mode(4)); strict.foes.detours=A.MAX_DETOURS
chunks=A.chunks_near({p.position,strict.position},52); A.scan(surface,force,chunks,#chunks)
eq(A.accept(p,strict,{{position=strict.position}}),false); eq(strict.path_state,'unsafe')
-- Steering a sidestep or cutting a waypoint corner also respects the minimum.
p.position={x=50,y=-2}
strict={position={x=150,y=0},avoid_mode=A.mode(4)}
eq(A.step_clear(p,strict,{x=50,y=-1}),false); eq(strict.path_state,'unsafe')
-- With a smaller explicit margin this segment is allowed.
strict={position={x=150,y=0},avoid_mode=A.mode(2)}
eq(A.step_clear(p,strict,{x=50,y=-1}),true)
print('margin_probe: ok')
