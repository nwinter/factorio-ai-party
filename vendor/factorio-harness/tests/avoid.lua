-- Run from repository root: lua tests/avoid.lua
-- Walks around enemy worms and spawners (avoid.lua), alone and through move_to
-- against a fake engine (Opus, shift09 03:20: the pathfinder walked him 30 tiles from a nest).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    if req.bot then pcall(runtime.stop_player,runtime.bots.index_of(req.bot)) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local astra=as('astra')
runtime.operator.bot_create('astra')

-- The module on its own: modes, nests, crossings, the way round.
local A=runtime.avoid
-- (round1950a: spawners, 40 tiles, and the areas under attack now count by default too)
eq(A.mode(nil).pad,4); eq(A.mode(nil).spawners,true); eq(A.mode(nil).attacks,true); eq(A.mode(false),nil); eq(A.mode(true).spawners,true); eq(A.mode(true).pad,8); eq(A.mode(12).pad,12)
fails(function() A.mode('yes') end,'avoid_enemies must be true, false, a margin 0..32 tiles or {distance: N}')
-- {distance: N} (Opus, d15 07:50): N tiles from every worm and spawner, their reach not counted.
eq(A.mode({distance=12}).distance,12); eq(A.mode({distance=12}).pad,0)
eq(A.describe(A.mode({distance=12})),'worms and spawners (12 tiles from each; their reach not counted) and areas under attack now (24 tiles)')
fails(function() A.mode({distance=2}) end,'avoid_enemies {distance: N}: N 4..64')
fails(function() A.mode({distance=12,pad=3}) end,'avoid_enemies {distance: N}')
do
  -- the discs: every worm and spawner N tiles round, whatever its reach
  local chunks=A.chunks_near({{x=0,y=0}},16)
  local st=storage.agent_harness
  st.enemy_chunks=st.enemy_chunks or {}
  local kept=st.enemy_chunks[surface.index]
  local c={}
  st.enemy_chunks[surface.index]=c
  c[chunks[1][3]]={t=game.tick,list={{x=10,y=0,name='medium-worm-turret'},{x=60,y=0,name='biter-spawner',spawner=true}}}
  local blobs=A.blobs(surface,{chunks[1]},A.mode({distance=12}))
  local rs={}
  for _,b in ipairs(blobs) do for _,m in ipairs(b.members or {b}) do rs[#rs+1]=m.r end end
  table.sort(rs); eq(rs[1],12); eq(rs[#rs],12)
  st.enemy_chunks[surface.index]=kept
end
eq(A.describe(A.mode(nil)),'worms (range + 4), spawners (40 tiles + 4) and areas under attack now (24 tiles + 4)')
eq(A.describe(A.mode(true)),'worms (range + 8), spawners (40 tiles + 8) and areas under attack now (24 tiles + 8)')
-- A detour clears the disc; a clear line needs none; a goal walled in by discs has no way.
local disc={x=50,y=0,r=10,members={{x=50,y=0,r=10,range=6,name='w'}}}
eq(#A.detour({x=0,y=0},{x=100,y=30},{disc},{}),0)
local vias=A.detour({x=0,y=0},{x=100,y=0},{disc},{})
assert(#vias>=2,'corners around the disc'); eq(vias[#vias].x,100)
local from={x=0,y=0}
for _,v in ipairs(vias) do assert(A.seg_dist(from,v,disc)>=9.99,'leg clear of the disc'); from=v end
local ring={}
for _,c in ipairs({{140,0},{60,0},{100,40},{100,-40}}) do ring[#ring+1]={x=c[1],y=c[2],r=34,members={{x=c[1],y=c[2],r=34,range=30,name='w'}}} end
eq(A.detour({x=0,y=0},{x=100,y=0},ring,{}),nil)
-- The crossing names the member whose reach the path enters.
local bi,m,d=A.crossing({{x=0,y=0},{x=100,y=0}},{disc},{})
eq(bi,1); eq(m.name,'w'); eq(d,0)
eq(A.crossing({{x=0,y=20},{x=100,y=20}},{disc},{}),nil)
-- The deepest pass counts, not the first one into a margin (world n copy: a walk
-- whose path entered a big worm's margin at 41 tiles, then passed 12 from it, was
-- taken as margin-only and the character died).
local nest={x=0,y=0,r=60,members={{x=-20,y=0,r=42,range=38,name='big-worm-turret'},{x=20,y=0,r=34,range=30,name='medium-worm-turret'}}}
bi,m,d=A.crossing({{x=-100,y=-40},{x=-30,y=-40},{x=30,y=-5},{x=100,y=-5}},{nest},{})
eq(m.name,'medium-worm-turret'); assert(d>9 and d<10,d)
-- A goal between members' reach but inside the nest's outline is reached round the members' own discs.
local v2=A.detour({x=-100,y=0},{x=0,y=45},{nest},{})
assert(v2 and #v2>=1 and v2[#v2].y==45,'a way to a goal between the members')
from={x=-100,y=0}
for _,v in ipairs(v2) do for _,mm in ipairs(nest.members) do assert(A.seg_dist(from,v,mm)>=mm.r-0.01,'leg clear of '..mm.name) end; from=v end

-- A walk past a medium worm (range 30): the engine's path goes 5 tiles from it,
-- so the walk goes round in legs, each the engine's path, and says so.
prototypes={entity={['medium-worm-turret']={attack_parameters={range=30}},['biter-spawner']={result_units={{unit='small-biter'}}},['small-biter']={vision_distance=30}}}
force.get_friend=function() return false end; force.get_cease_fire=function() return false end
local enemy=game.forces.enemy
local structures={}
local trees={}
surface.find_entities_filtered=function(f)
  local out={}
  -- an entity looked up at a position (mine's target): the trees there
  if f.position and not f.type then
    for _,e in ipairs(trees) do if math.abs(e.position.x-f.position.x)<=(f.radius or 0.5) and math.abs(e.position.y-f.position.y)<=(f.radius or 0.5) then out[#out+1]=e end end
    return out
  end
  if f.area and f.type then
    local a=f.area
    for _,e in ipairs(structures) do
      if e.position.x>=a[1][1] and e.position.x<a[2][1] and e.position.y>=a[1][2] and e.position.y<a[2][2] then out[#out+1]=e end
    end
  end
  return out
end
local asked={}
surface.request_path=function(a) asked[#asked+1]=a; return 700+#asked end
local me=runtime.lookup(runtime.bots.index_of('astra')).character
me.position={x=0,y=0}
me.prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}}
local worm={valid=true,name='medium-worm-turret',type='turret',position={x=50,y=5},force=enemy}
structures={worm}
local function path(points) local out={} for i,q in ipairs(points) do out[i]={position={x=q[1],y=q[2]}} end return out end
local function answer(points) local n=#asked; runtime.on_event{name=10,id=700+n-1,path=path(points)}; runtime.on_event{name=10,id=700+n,path=path(points)} end
local r=astra('move_to',{position={x=100,y=0}})
eq(r.avoid_enemies,'worms (range + 4), spawners (40 tiles + 4) and areas under attack now (24 tiles + 4)'); eq(#asked,2)
advance(3) -- the chunks along the way are read meanwhile (8 a tick)
answer({{0,0},{50,0},{100,0}})
advance(2)
local nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.foes.detours,1); eq(#asked,4) -- the first leg asked for
assert(nav.position.x~=100,'the first leg goes to a corner, not the goal')
local legs=0
while nav.position.x~=100 or nav.position.y~=0 do
  local target={x=nav.position.x,y=nav.position.y}
  assert(((target.x-50)^2+(target.y-5)^2)^0.5>=34,'corner outside the worm\'s reach + 4')
  answer({{me.position.x,me.position.y},{target.x,target.y}})
  me.position={x=target.x,y=target.y}
  advance(2)
  legs=legs+1
  assert(legs<20,'legs end')
  nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
  assert(nav,'walk still running')
end
answer({{me.position.x,me.position.y},{100,0}})
me.position={x=100,y=0}
advance(2)
local last=astra('status').last
eq(last.outcome,'arrived'); eq(last.target.x,100)
eq(last.avoided_enemies[1],'1 medium-worm-turret around (50,5)')
-- A goal inside a worm's range is refused (Astra, operator 07:26: died at (-25,335) on the way to (-10,350), a goal in
-- a nest's reach), naming the worm and the nearest safe spot toward the goal: on the line back to the character,
-- just outside range + 4.
asked={}
local ok,err=pcall(astra,'move_to',{position={x=60,y=0}})
eq(ok,false)
eq(tostring(err):match('goal .*'),"goal (60,0) is inside medium-worm-turret (50,5) range 30 (11.2 tiles from it): unsafe_goal: true to go anyway; the nearest safe spot toward it: (84,0), 24 tiles from it, outside every worm's range, spawner's 40 tiles and area under attack (24 tiles), + 4, the map shows")
eq(#asked,0,'no path asked')
-- unsafe_goal: true goes anyway (the worm's nest is not avoided); the reply and last name it.
r=astra('move_to',{position={x=60,y=0},unsafe_goal=true})
eq(r.unsafe_goal,'goal (60,0) is inside medium-worm-turret (50,5) range 30 (11.2 tiles from it) (unsafe_goal)')
advance(3)
answer({{100,0},{60,0}})
me.position={x=60,y=0}
advance(2)
last=astra('status').last
eq(last.outcome,'arrived'); eq(last.avoided_enemies,nil); eq(last.enemies_at_start_or_goal[1],'1 medium-worm-turret around (50,5)')
-- A via point inside the range is refused the same way.
ok,err=pcall(astra,'move_to',{position={x=100,y=0},via={{x=55,y=10}}})
eq(ok,false); assert(tostring(err):find('via point 1 (55,10) is inside medium-worm-turret (50,5) range 30',1,true),err)
-- A goal in the margin only (32 tiles off: range 30 + 4): not refused, and the way there keeps out of the range
-- (the disc ends just short of the goal; before, the whole nest went unchecked).
me.position={x=50,y=-45}; asked={}
r=astra('move_to',{position={x=50,y=37}})
eq(r.unsafe_goal,nil)
advance(3)
answer({{50,-45},{50,37}})
advance(2)
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.foes.detours,1,'the straight way crosses the range: round it')
assert(nav.position.x~=50 or nav.position.y~=37,'the first leg goes to a corner')
assert(((nav.position.x-50)^2+(nav.position.y-5)^2)^0.5>=30,'corner outside the range')
eq(nav.foes.at_ends[1],'1 medium-worm-turret around (50,5)')
astra('stop')
-- Standing in the range itself, the spot comes from round the goal: the nearest point outside every disc.
me.position={x=45,y=5}
ok,err=pcall(astra,'move_to',{position={x=50,y=15}})
eq(ok,false); assert(tostring(err):find('the nearest safe spot toward it: (50,40), 25 tiles from it',1,true),err)
me.position={x=100,y=0}
-- Worms all round the goal (none reaching it): no safe route, the walk ends where it stands.
me.position={x=0,y=0}; asked={}
structures={}
for _,c in ipairs({{140,0},{60,0},{100,40},{100,-40}}) do structures[#structures+1]={valid=true,name='medium-worm-turret',type='turret',position={x=c[1],y=c[2]},force=enemy} end
storage.agent_harness.enemy_chunks=nil
astra('move_to',{position={x=100,y=0}})
advance(3)
answer({{0,0},{100,0}})
advance(33)
last=astra('status').last
eq(last.outcome,'no_safe_route')
eq(#last.smaller_margins.tested,4)
eq(last.smaller_margins.largest_verified_margin,nil)
assert(last.smaller_margins.line:find('no complete route verified',1,true))
eq(me.position.x,0); eq(me.position.y,0)
assert(last.why:find('no way to (100,0) around',1,true),last.why)
-- avoid_enemies=false: no check, the engine's path as it is.
asked={}
r=astra('move_to',{position={x=100,y=0},avoid_enemies=false})
eq(r.avoid_enemies,nil)
answer({{0,0},{100,0}})
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.path_state,'found'); eq(nav.foes,nil)
-- Spawners count with avoid_enemies=true: a biter spawner 20 tiles off the way (sight 30 + 8).
astra('stop')
structures={{valid=true,name='biter-spawner',type='unit-spawner',position={x=50,y=20},force=enemy}}
storage.agent_harness.enemy_chunks=nil
asked={}
r=astra('move_to',{position={x=100,y=0},avoid_enemies=true})
eq(r.avoid_enemies,'worms (range + 8), spawners (40 tiles + 8) and areas under attack now (24 tiles + 8)')
advance(3)
answer({{0,0},{100,0}})
advance(2)
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.foes.detours,1); eq(nav.foes.avoided[1],'1 biter-spawner around (50,20)')
-- A goal within 40 tiles of a spawner is refused (round1950a, Haiku 45h57m: a tree 38 tiles from a nest; big spitters
-- killed it within 5 s), by default too; avoid_enemies=false walks there.
astra('stop'); asked={}
ok,err=pcall(astra,'move_to',{position={x=50,y=35},avoid_enemies=true})
eq(ok,false); assert(tostring(err):find("goal (50,35) is within 40 tiles of biter-spawner (50,20), its units' reach (15.0 tiles from it): unsafe_goal: true to go anyway; the nearest safe spot toward it:",1,true),err)
assert(tostring(err):find("outside every worm's range, spawner's 40 tiles and area under attack (24 tiles), + 8, the map shows",1,true),err)
fails(function() astra('move_to',{position={x=50,y=55}}) end,"goal (50,55) is within 40 tiles of biter-spawner (50,20), its units' reach (35.0 tiles from it)")
r=astra('move_to',{position={x=50,y=55},avoid_enemies=false}); eq(r.unsafe_goal,nil); astra('stop')
-- Mining within 40 tiles of a spawner is refused too (round1950a, Haiku 45h57m: a dry tree 38 tiles from a nest),
-- unless unsafe_goal.
do
  local tree={valid=true,name='dry-tree',type='tree',position={x=50,y=50},force={name='neutral'},minable=true,
    prototype={mineable_properties={products={}}},bounding_box={left_top={x=49.6,y=49.6},right_bottom={x=50.4,y=50.4}}}
  trees={tree}
  me.position={x=50,y=48}
  fails(function() astra('mine',{position={x=50,y=50}}) end,"the mining spot (50,50) is within 40 tiles of biter-spawner (50,20), its units' reach (30.0 tiles from it): unsafe_goal: true to mine anyway")
  local okm,errm=pcall(astra,'mine',{position={x=50,y=50},unsafe_goal=true})
  assert(okm or not tostring(errm):find('unsafe_goal',1,true),tostring(errm))
  astra('stop'); trees={}; me.position={x=0,y=0}
end
-- By default the way goes round a spawner too: one 20 tiles off it.
astra('stop'); asked={}
storage.agent_harness.enemy_chunks=nil
astra('move_to',{position={x=100,y=0}})
advance(3)
answer({{0,0},{100,0}})
advance(2)
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.foes.detours,1); eq(nav.foes.avoided[1],'1 biter-spawner around (50,20)')
-- The areas under attack now (round1950a, Haiku 45h02m: a rearm tour walked into attack #1550 and died; status had
-- listed attack #1548 at its goal): an incident hit within the last minute is a disc of 24 tiles round its first hit.
astra('stop'); asked={}
structures={}; storage.agent_harness.enemy_chunks=nil
storage.agent_harness.damage={['nauvis:1,0']={id=1548,at={x=60,y=0},first=tick-300,last=tick-60,hits=5,damage=180,surface='nauvis',size=3}}
fails(function() astra('move_to',{position={x=65,y=0}}) end,
  'goal (65,0) is within 24 tiles of attack #1548 at (60,0), an area under attack now (last hit 1s ago, 3 attackers seen) (5.0 tiles from it); it clears in about 29 s (tick 1809) unless hit again (an area counts as under attack 30 s after its last hit): unsafe_goal: true to go anyway; the nearest safe spot toward it:')
-- An attack whose last hit was over 30 s ago is over.
storage.agent_harness.damage['nauvis:1,0'].last=tick-1900
r=astra('move_to',{position={x=65,y=0}}); eq(r.unsafe_goal,nil); astra('stop')
-- A way through one goes round it, named.
storage.agent_harness.damage['nauvis:1,0'].last=tick-60
asked={}
astra('move_to',{position={x=120,y=0}})
advance(3)
answer({{0,0},{60,0},{120,0}})
advance(2)
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.foes.detours,1); eq(nav.foes.avoided[1],'1 attack #1548 around (60,0)')
astra('stop')
-- An attack that starts on the way later: the walk plans again round it (once), said in last.replanned.
storage.agent_harness.damage={}
asked={}
astra('move_to',{position={x=120,y=0}})
advance(3)
answer({{0,0},{120,0}})
advance(2)
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.path_state,'found'); local before=#asked
storage.agent_harness.damage['nauvis:2,0']={id=1550,at={x=70,y=2},first=tick,last=tick,hits=1,damage=30,surface='nauvis',size=1}
advance(31)
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
assert(#asked>before,'a new path asked for'); eq(nav.attack_replan,'attack #1550 at (70,2) started on the way: planned again round it')
storage.agent_harness.damage={}
astra('stop')
last=astra('status').last
eq(last.replanned,'attack #1550 at (70,2) started on the way: planned again round it')
-- One that starts within 24 tiles of the walker, the way on passing nearer its hit than here: planned again too, the
-- zone kept to just short of here so the way goes no deeper (on a copy of world n an attack 18 tiles off Haiku's way
-- was walked through).
asked={}
astra('move_to',{position={x=120,y=0}})
advance(3)
answer({{0,0},{120,0}})
advance(2)
before=#asked
storage.agent_harness.damage['nauvis:0,0']={id=1551,at={x=15,y=10},first=tick,last=tick,hits=1,damage=30,surface='nauvis',size=1}
advance(31)
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.attack_replan,'attack #1551 at (15,10) started on the way: planned again round it')
-- An attack behind, the way on going away from it: no new plan.
astra('stop'); storage.agent_harness.damage={}; asked={}
astra('move_to',{position={x=120,y=0}})
advance(3)
answer({{0,0},{120,0}})
advance(2)
before=#asked
storage.agent_harness.damage['nauvis:-1,0']={id=1552,at={x=-15,y=0},first=tick,last=tick,hits=1,damage=30,surface='nauvis',size=1}
advance(31)
nav=storage.agent_harness.active[runtime.bots.index_of('astra')]
eq(nav.attack_replan,nil,'no new plan')
storage.agent_harness.damage={}
astra('stop')
-- Private 2.0.77 autowalk check: a worm added after a clear destination was cached must be seen on the next
-- call, before the minute-long path cache expires. Tour stops and move_to goals use the same fresh local read.
do
  storage.agent_harness.enemy_chunks={}
  structures={}
  local p=runtime.bots.lookup(runtime.bots.index_of('astra'))
  local goal={x=20,y=0}
  local mode=A.mode(nil)
  eq(A.inside(p,goal,mode),nil)
  structures[1]={valid=true,name='medium-worm-turret',type='turret',position={x=40,y=0},force=enemy}
  advance(1)
  local c=A.inside(p,goal,mode)
  assert(c,'the next call sees a new worm on a previously empty charted chunk')
  eq(c.m.name,'medium-worm-turret'); eq(c.d,20)
  local check=A.goal_check(p,{x=0,y=0},goal,mode)
  eq(check.m.name,'medium-worm-turret'); assert(check.spot and check.spot.x<10)
  -- Multiple nearby tour stops in one tick share the refreshed chunks.
  local find=surface.find_entities_filtered
  surface.find_entities_filtered=function() error('same-tick goal repeated a chunk scan') end
  eq(A.inside(p,goal,mode).m.name,'medium-worm-turret')
  surface.find_entities_filtered=find
  structures={}; advance(1)
  eq(A.inside(p,goal,mode),nil,'a removed worm does not keep refusing the destination')
end
-- Belt clearance shares the current charted hazard reads, memoized per tile chunk.
do
  storage.agent_harness.enemy_chunks={}
  local p=runtime.bots.lookup(runtime.bots.index_of('astra'))
  structures={{valid=true,name='medium-worm-turret',type='turret',position={x=40,y=0},force=enemy}}
  local block,note,margin,cost=A.route_guard(p,8)
  assert(note:find('range + 8',1,true)); assert(margin>=56)
  assert(block(9,0)); eq(block(0,0),nil)
  local reads=surface.find_entities_filtered
  surface.find_entities_filtered=function() error('tile in same chunk rescanned hazards') end
  assert(block(10,1)); eq(cost.chunks,1)
  surface.find_entities_filtered=reads
  eq(A.route_guard(p,false),nil); eq(A.route_guard(p,nil),nil)
  fails(function() A.route_guard(p,33) end,'0..32')
  structures={}; advance(1)
  local fresh=A.route_guard(p,8); eq(fresh(9,0),nil)
end
print('avoid: ok')

-- Opus, shift14/15 far-east mine. Real charted coordinates copied into a fixture;
-- the default +4 discs close a 6.145-tile gap by 1.855 tiles. The route through
-- that corridor must keep out of every actual reach and report margin passes.
do
  local es=dofile('tests/fixtures/opus-corridor.lua')
  local blobs={}
  for _,e in ipairs(es) do blobs[#blobs+1]={members={{x=e.x,y=e.y,r=e.range+4,range=e.range,name=e.name}}} end
  local start,goal={x=266,y=-290},{x=393,y=-279}
  local path,narrow=A.route(start,goal,blobs,{})
  assert(path and narrow,'the corridor is inside margins, outside reaches')
  local len,prev=0,start
  for _,v in ipairs(path) do
    for _,e in ipairs(es) do assert(A.seg_dist(prev,v,e)>=e.range+0.49,'corridor clears '..e.name) end
    local leg=((prev.x-v.x)^2+(prev.y-v.y)^2)^.5
    assert(leg<=16.001,'short engine goals through the corridor')
    len=len+leg; prev=v
  end
  assert(len<140,'uses the corridor, not the northern 263-tile detour')
  local n={foes={vias={{x=10,y=20},{x=30,y=20}},tolerance=2}}
  assert(A.next_leg({},n)); eq(n.tolerance,0.25,'reach the corner before turning')
  assert(A.next_leg({},n)); eq(n.tolerance,2,'user tolerance only at final goal')
  n={vehicle=true,foes={vias={{x=10,y=20},{x=30,y=20}},tolerance=2}}
  assert(A.next_leg({},n));eq(n.tolerance,3,'vehicle turning tolerance stays unchanged')
end
-- A rotated ring with 0.225-tile gaps: the old octagon graph returns nil,
-- although all four gaps are outside the protected discs.
do
  local ring={}
  for i=0,3 do
    local angle=(21+i*90)*math.pi/180
    ring[#ring+1]={members={{x=10.2*math.cos(angle),y=10.2*math.sin(angle),r=7.1,range=6,name='w'}}}
  end
  local path=A.detour({x=-30,y=-10},{x=0,y=0},ring,{})
  assert(path and #path>1,'the sub-tile opening is real')
  local prev={x=-30,y=-10}
  for _,v in ipairs(path) do for _,b in ipairs(ring) do assert(A.seg_dist(prev,v,b.members[1])>=7.09) end; prev=v end
end
-- The four-detour limit only rejects actual reach, never a margin-only pass.
do
  local stash={}
  local B=dofile('mod/agent-harness_0.1.0/avoid.lua'){state=function() return stash end,charted=function() return true end,leg=function() error('no fifth detour') end}
  local sp={name='nauvis',index=91,find_entities_filtered=function() return {} end}
  local pp={surface=sp,force=force,position={x=168.5,y=-280}}
  local goal={x=268.5,y=-280}
  local nav={position=goal,tolerance=1}
  B.start(pp,nav,B.mode(nil))
  local cs=B.chunks_near({pp.position,goal},52)
  for _,c in ipairs(cs) do B.read_chunk(sp,force,c[1],c[2]) end
  -- read_chunk returns rows; scan populates the cache.
  B.scan(sp,force,cs,#cs)
  local key=(math.floor(218.5/32)+524288)*1048576+(math.floor(-239.5/32)+524288)
  stash.enemy_chunks[91][key]={t=game.tick,list={{x=218.5,y=-239.5,name='spitter-spawner',spawner=true}}}
  nav.foes.detours=4
  assert(B.accept(pp,nav,{{position=goal}}),'40.5 tiles from sight 40 is margin only')
  assert(nav.foes.passed)
  pp.position={x=168.5,y=-278}; nav.position={x=268.5,y=-278};nav.foes.goal=nav.position
  eq(B.accept(pp,nav,{{position=nav.position}}),false,'38.5 tiles is still refused')
  eq(nav.path_state,'unsafe')
end
print('avoid round0020b: ok')
-- Replay the failing final leg through accept/next_leg, as straight engine legs.
-- Terrain pathfinding is still the game's job; each path it returns is guarded.
do
  local es=dofile('tests/fixtures/opus-corridor.lua')
  local st={}; local B
  B=dofile('mod/agent-harness_0.1.0/avoid.lua'){state=function() return st end,charted=function() return true end,
    leg=function(p,n) return B.next_leg(p,n) end}
  local sp={name='nauvis',index=92}
  sp.find_entities_filtered=function(q)
    local out={}
    for _,e in ipairs(es) do
      if e.x>=q.area[1][1] and e.x<q.area[2][1] and e.y>=q.area[1][2] and e.y<q.area[2][2] then
        out[#out+1]={valid=true,name=e.name,type=e.name:find('spawner') and 'unit-spawner' or 'turret',position={x=e.x,y=e.y},force=enemy}
      end
    end
    return out
  end
  prototypes.entity['small-worm-turret']={turret_range=25};prototypes.entity['big-worm-turret']={turret_range=38}
  local pp={surface=sp,force=force,position={x=266,y=-290}}
  local nav={position={x=393,y=-279},tolerance=1}
  B.start(pp,nav,B.mode(nil))
  local chunks={}
  for x=4,16 do for y=-14,-3 do chunks[#chunks+1]={x,y,(x+524288)*1048576+(y+524288)} end end
  B.scan(sp,force,chunks,#chunks)
  eq(B.accept(pp,nav,{{position=nav.position}}),false)
  eq(nav.foes.margin_route,true);eq(nav.foes.detours,1)
  for _=1,16 do
    assert(B.accept(pp,nav,{{position=nav.position}}),'planned leg remains outside actual reaches')
    pp.position=nav.position
    if not nav.leg then break end
    assert(B.leg_done(pp,nav,'arrived'))
  end
  eq(pp.position.x,393);eq(pp.position.y,-279);eq(nav.foes.detours,1)
  local last={};B.report(last,nav);assert(last.passed_within_margin and not last.why)
end
print('Opus corridor accepted: ok')
