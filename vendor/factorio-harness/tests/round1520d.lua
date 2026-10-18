-- Run from repository root: lua tests/round1520d.lua
-- Walks wait for a moving train to pass the rails ahead (Opus, shift12 15:20: killed by our own train at (195,-150)
-- walking to a locomotive), and recover walks to the agent's own corpses and takes everything (Opus).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},
  inventory={chest=1,character_ammo=4,character_guns=3,character_corpse=9,fuel=2},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local vulcanus={name='vulcanus',index=2}
-- Slot inventories: stacks the runtime moves with transfer_stack, as the engine's.
local function stack(name,count)
  local s={name=name,count=count or 0,valid_for_read=(count or 0)>0,quality={name='normal'}}
  s.transfer_stack=function(other,amount)
    if s.valid_for_read and s.name~=other.name then return false end
    local moved=math.min(amount or other.count,other.count,100-s.count)
    s.name=other.name; s.count=s.count+moved; s.valid_for_read=s.count>0
    other.count=other.count-moved; other.valid_for_read=other.count>0
    return moved==amount
  end
  s.clear=function() s.valid_for_read=false; s.count=0 end
  return s
end
local function slots(...)
  local t={...}; t.valid=true
  t.get_item_count=function(f)
    local name=type(f)=='table' and f.name or f
    local n=0; for _,s in ipairs(t) do if s.valid_for_read and (name==nil or s.name==name) then n=n+s.count end end; return n
  end
  t.get_contents=function()
    local m,o={},{}
    for _,s in ipairs(t) do
      if s.valid_for_read then
        if not m[s.name] then m[s.name]={name=s.name,count=0,quality='normal'}; o[#o+1]=m[s.name] end
        m[s.name].count=m[s.name].count+s.count
      end
    end
    return o
  end
  t.is_empty=function() for _,s in ipairs(t) do if s.valid_for_read then return false end end return true end
  t.count_empty_stacks=function() local n=0; for _,s in ipairs(t) do if not s.valid_for_read then n=n+1 end end; return n end
  return t
end
local function dist(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
local units=0
local function character(pos,surf)
  units=units+1
  local main=slots(stack(),stack(),stack(),stack())
  local c={valid=true,name='character',type='character',force=force,surface=surf or surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  c.main=main
  c.insert=function(st)
    for _,sl in ipairs(main) do
      if not sl.valid_for_read then sl.name=st.name; sl.count=st.count; sl.valid_for_read=true; return st.count end
    end
    return 0
  end
  c.get_main_inventory=function() return main end
  c.get_item_count=function(n) return main.get_item_count(n) end
  c.get_inventory=function() return slots() end
  c.can_reach_entity=function(e) return dist(c.position,e.position)<=10 end
  c.destroy=function() c.valid=false end
  c.prototype={collision_mask={layers={player=true}}}
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
-- The world's entities and a find over them: type, name, position+radius, area, limit.
local ents={}
local function any(list,v) if type(list)=='string' then return list==v end for _,x in ipairs(list) do if x==v then return true end end return false end
local finds=0
local function finder(surf)
  return function(f)
    finds=finds+1
    local out={}
    for _,e in ipairs(ents) do
      local ok=e.valid and (e.surface or surface)==surf
      if ok and f.type then ok=any(f.type,e.type) end
      if ok and f.name then ok=any(f.name,e.name) end
      if ok and f.position and f.radius then ok=dist(e.position,f.position)<=f.radius end
      if ok and f.area then
        local lt,rb=f.area[1] or f.area.left_top,f.area[2] or f.area.right_bottom
        ok=e.position.x>=(lt.x or lt[1]) and e.position.x<=(rb.x or rb[1]) and e.position.y>=(lt.y or lt[2]) and e.position.y<=(rb.y or rb[2])
      end
      if ok then out[#out+1]=e end
      if f.limit and #out>=f.limit then break end
    end
    return out
  end
end
surface.find_entities_filtered=finder(surface)
vulcanus.find_entities_filtered=finder(vulcanus)
prototypes={item={pistol={name='pistol',stack_size=5},['firearm-magazine']={name='firearm-magazine',type='ammo',stack_size=200}},entity={}}
local players={}
local trains={}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then return nil end return players[i] end,
  get_surface=function(n) if n=='vulcanus' or n==2 then return vulcanus end return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end,
  train_manager={get_trains=function(f) eq(f.surface,surface); return trains end}}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.bot and runtime.bots.index_of(req.bot)
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
runtime.operator.bot_create('opus'); runtime.operator.bot_create('grok')
local opus,grok=as('opus'),as('grok')
local function body(name) return storage.agent_harness.bots.by_name[name].character end
local function index(name) return runtime.bots.index_of(name) end
local tick=0
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function last(name) return storage.agent_harness.last[index(name)] end
-- Ticks to a multiple of 10, where the train guard looks.
local function to_tenth() advance((10-tick%10)%10) end

-- 1. The train guard (M.train_guard): rails within 4 tiles ahead, and a moving train that will pass them.
local function rail(x,y) local r={valid=true,name='straight-rail',type='straight-rail',position={x=x,y=y},unit_number=9000+#ents,surface=surface}; ents[#ents+1]=r; return r end
local r1,r2,r3=rail(-2,3),rail(0,3),rail(2,3)
local far=rail(40,3)
local train={valid=true,speed=0.5,carriages={{name='locomotive',position={x=-30,y=3}}},path={current=1,size=4,rails={r1,r2,r3,far}}}
body('opus').position={x=0,y=0}
local p=runtime.lookup(index('opus'))
to_tenth()
local nav={position={x=0,y=20}}
-- No train: walk on.
eq(runtime.train_guard(p,nav,p.position,nav.position),false)
-- Moving toward the rails, its path over them, 30 tiles off at 0.5 tiles a tick (60 ticks): wait.
trains[1]=train
eq(runtime.train_guard(p,nav,p.position,nav.position),true)
eq(nav.train_wait.train,'a train (locomotive at (-30,3), 108 km/h)')
eq(nav.train_wait.rails.x,0); eq(nav.train_wait.rails.y,3)
has(runtime.train_wait_line(nav.train_wait),'waiting 0 s at (0.0,0.0) for a train (locomotive at (-30,3), 108 km/h) to pass the rails ahead at (0.0,3.0)')
-- Between looks (every 10 ticks) the wait holds.
game.tick=tick+3; eq(runtime.train_guard(p,nav,p.position,nav.position),true); game.tick=tick
-- Standing still: no wait, and the one before ends in train_waits.
train.speed=0; tick=tick+10; game.tick=tick
eq(runtime.train_guard(p,nav,p.position,nav.position),false); eq(nav.train_wait,nil)
eq(nav.train_waits[1],'waited 0.2 s at (0.0,0.0) for a train (locomotive at (-30,3), 108 km/h) to pass the rails ahead at (0.0,3.0)')
-- Its path over other rails only, and not on them: walk on.
train.speed=0.5; train.path={current=1,size=1,rails={far}}
eq(runtime.train_guard(p,nav,p.position,nav.position),false)
-- Over 6 s away at its speed (400 tiles at 0.5): walk on.
train.path={current=1,size=4,rails={r1,r2,r3,far}}; train.carriages[1].position={x=-400,y=3}
eq(runtime.train_guard(p,nav,p.position,nav.position),false)
-- Its wagons on the rails ahead now (within 4 tiles), path or not: wait.
train.carriages[1].position={x=1,y=3}; train.path=nil
eq(runtime.train_guard(p,nav,p.position,nav.position),true)
runtime.train_done(nav)
-- No path, within 30 tiles: wait; beyond: walk on.
train.carriages[1].position={x=-25,y=3}
eq(runtime.train_guard(p,nav,p.position,nav.position),true); runtime.train_done(nav)
train.carriages[1].position={x=-40,y=3}
eq(runtime.train_guard(p,nav,p.position,nav.position),false)
-- Already on a rail: walk on off it.
train.carriages[1].position={x=-10,y=3}
eq(runtime.train_guard(p,{position={x=0,y=20}},{x=0,y=3},{x=0,y=20}),false)
-- Rails beyond 4 tiles ahead are not looked at.
eq(runtime.train_guard(p,{position={x=0,y=-20}},{x=0,y=9},{x=0,y=-20}),false)
-- A double track (d17 batch14 A5, Opus at (383,-288)): on the first track with a train coming over the second, ahead,
-- the walk backs off to where it last stood off the rails, and the wait says so.
do
  local second=rail(0,5)
  local nav2={position={x=0,y=20}}
  local saved=trains[1]
  trains[1]=nil
  tick=tick+10; game.tick=tick
  eq(runtime.train_guard(p,nav2,{x=0,y=0.5},nav2.position),false)  -- off the rails: remembered
  trains[1]=train; train.speed=0.5; train.carriages[1].position={x=-20,y=5}; train.path={current=1,size=1,rails={second}}
  tick=tick+10; game.tick=tick
  local r,to=runtime.train_guard(p,nav2,{x=0,y=3},nav2.position)
  eq(r,'backing'); eq(to.x,0); eq(to.y,0.5)
  tick=tick+10; game.tick=tick; train.speed=0
  runtime.train_guard(p,nav2,{x=0,y=0.5},nav2.position)
  has(nav2.train_waits[1],'backing off the rails to (0.0,0.5)')
  trains[1]=saved
  second.valid=false
end

-- 2. A move_to stops short of the rails while the train comes, says so in status, then walks on; last.train_waits.
trains[1]=train; train.speed=0.5; train.carriages[1].position={x=-30,y=3}; train.path={current=1,size=4,rails={r1,r2,r3,far}}
local r=opus('move_to',{position={x=0,y=20},pathfind=false})
advance(1); eq(body('opus').walking_state.walking,true); to_tenth()
local st=opus('status',{})
eq(body('opus').walking_state.walking,false)
has(st.active.train_wait,'for a train (locomotive at (-30,3), 108 km/h) to pass the rails ahead at (0.0,3.0)')
-- The train has gone by: it walks on.
train.carriages[1].position={x=30,y=3}; train.speed=0
advance(10)
eq(body('opus').walking_state.walking,true)
body('opus').position={x=0,y=20}; advance(1)
eq(last('opus').outcome,'arrived')
eq(#last('opus').train_waits,1)
has(last('opus').train_waits[1],'waited ')
has(last('opus').train_waits[1],'s at (0.0,0.0) for a train (locomotive at (-30,3), 108 km/h) to pass the rails ahead at (0.0,3.0)')
eq(last('opus').on_rails,nil)
trains[1]=nil
-- A move_to never ends on a ground rail: arriving on one it steps to the nearest free tile without one, as off a belt.
opus('move_to',{position={x=0,y=3},pathfind=false})
body('opus').position={x=0.2,y=3}; advance(1)
local walk=storage.agent_harness.active[index('opus')]
-- The nearest tile whose box, 0.35 wider, meets no rail (the walk stops within 0.3 of it).
eq(walk.step_off.x,0.5); eq(walk.step_off.y,4.5)
body('opus').position={x=0.5,y=4.5}; advance(1)
eq(last('opus').outcome,'arrived'); eq(last('opus').on_rails,nil)
eq(last('opus').off_belt,'arrived on a straight-rail; stepped to (0.5,4.5), the nearest free tile without a belt or rail (none within the arrival radius)')

-- 3. recover: a bot's corpse is noted where it died, by the tick it died; recover walks to it and takes everything.
-- Read after it went, a corpse fails as the engine's does (the server run: "LuaEntity API call when LuaEntity was invalid").
local function corpse(x,y,items,died,surf,who)
  local inv=slots()
  for name,n in pairs(items) do inv[#inv+1]=stack(name,n) end
  local raw={valid=true,name='character-corpse',type='character-corpse',position={x=x,y=y},surface=surf or surface,force={name='neutral'},
    character_corpse_tick_of_death=died,character_corpse_player_index=who or 65536}
  raw.get_inventory=function(i) eq(i,defines.inventory.character_corpse); return inv end
  raw.destroy=function() raw.valid=false end
  local k=setmetatable({},{__index=function(_,key)
    if key~='valid' and not raw.valid then error('LuaEntity API call when LuaEntity was invalid.') end
    return raw[key]
  end,__newindex=raw})
  ents[#ents+1]=k
  return k
end
local g=body('grok')
g.position={x=60,y=0}; advance(30-tick%30)
-- Dies at (63,0) between the 30-tick position updates: its corpse is 3 tiles from the last spot. A corpse from an
-- older death beside it, and one of a player's, are not its.
local mine=corpse(63,0,{['iron-plate']=150,coal=20},tick+1)
corpse(62,0,{stone=5},tick-500)
corpse(61,1,{wood=5},tick+1,surface,1)
players[1]={index=1,name='nick',valid=true}
g.valid=false; advance(1)
local rec=storage.agent_harness.bots.by_name.grok.corpses
eq(#rec,1); eq(rec[1].position.x,63); eq(rec[1].tick,tick); eq(rec[1].surface,'nauvis')
-- Dead: recover waits for the respawn, as other actions.
local ok,err=pcall(grok,'recover',{})
assert(not ok and tostring(err):find('is dead',1,true),tostring(err))
advance(600)
local g2=body('grok'); assert(g2~=g and g2.valid,'respawned')
g2.position={x=0,y=0}
r=grok('recover',{})
eq(r.places,1); eq(r.corpses[1],'(63.0,0.0) on nauvis: died 0m10s ago, holds 170 items')
eq(r.legs[1].name,'character-corpse'); eq(r.legs[1].walk,63)
eq(r.avoid_enemies,'worms (range + 4), spawners (40 tiles + 4) and areas under attack now (24 tiles + 4)')
eq(storage.agent_harness.active[index('grok')].kind,'gather')
-- An item move: the reply ends with the inventory line; a deploy's note calls it recover.
eq(r.inv,'free 4/4'); eq(r.moved,0)
eq(runtime.carry.called(storage.agent_harness.active[index('grok')]),'recover')
-- Walked there (the fake moves it), it takes everything: 170 items in 3 of its 4 slots of 100.
g2.position={x=58,y=0}; advance(1)
eq(last('grok').outcome,'collected'); eq(last('grok').transferred,170)
eq(last('grok').items['iron-plate'],150); eq(last('grok').items.coal,20)
eq(last('grok').entities[1].removed,true); eq(last('grok').entities[1].name,'character-corpse')
eq(mine.valid,false); eq(g2.get_item_count('iron-plate'),150)
-- It is gone: nothing left to recover; the record is forgotten.
ok,err=pcall(grok,'recover',{})
assert(not ok and tostring(err)=='no corpse of yours on nauvis',tostring(err))
eq(storage.agent_harness.bots.by_name.grok.corpses,nil)

-- 4. Two deaths: newest first, nearest first on the walk; one on another surface is listed, not walked to.
local b=storage.agent_harness.bots.by_name.grok
local k1=corpse(20,0,{['copper-plate']=10},tick-100)
local k2=corpse(-20,0,{['iron-gear-wheel']=5},tick-50)
local k3=corpse(5,5,{sulfur=7},tick-30,vulcanus)
b.corpses={{surface='vulcanus',position={x=5,y=5},tick=tick-30},{surface='nauvis',position={x=-20,y=0},tick=tick-50},{surface='nauvis',position={x=20,y=0},tick=tick-100}}
g2.position={x=15,y=0}
r=grok('recover',{})
eq(r.places,2); eq(#r.corpses,2)
eq(r.elsewhere[1],'(5.0,5.0) on vulcanus: died 0m00s ago, holds 7 items')
local tour=storage.agent_harness.active[index('grok')]
eq(tour.targets[1].entity,k1); eq(tour.targets[2].entity,k2)
-- A full inventory: what fits, the corpse stays and the call ends inventory_full.
for _,sl in ipairs(g2.main) do sl.name='stone'; sl.count=100; sl.valid_for_read=true end
advance(1)
eq(last('grok').outcome,'inventory_full'); eq(k1.valid,true)
eq(#runtime.bots.corpses(index('grok')),3)
-- Only on another surface: refused, naming it.
k1.valid=false; k2.valid=false
ok,err=pcall(grok,'recover',{})
eq(tostring(err),'no corpse of yours on nauvis; elsewhere: (5.0,5.0) on vulcanus: died 0m00s ago, holds 7 items')
k3.valid=false

-- 5. A corpse inside a weapon's reach the map shows is left out, unless unsafe_goal (as move_to's goal check).
for _,sl in ipairs(g2.main) do sl.clear() end
local k4=corpse(30,0,{['iron-plate']=1},tick-10)
b.corpses={{surface='nauvis',position={x=30,y=0},tick=tick-10}}
local check=runtime.avoid.goal_check
runtime.avoid.goal_check=function(_,_,goal) if goal.x==30 then return {m={name='medium-worm-turret',x=40,y=0,range=30},d=10,spot={x=-5,y=0}} end end
ok,err=pcall(grok,'recover',{})
has(tostring(err),'no corpse of yours on nauvis outside the enemy reach the map shows: (30.0,0.0) on nauvis: died 0m00s ago, holds 1 item; the corpse (30,0) is inside medium-worm-turret (40,0) range 30 (10.0 tiles from it); the nearest safe spot toward it: (-5,0), 35 tiles from it')
has(tostring(err),': unsafe_goal: true to go anyway')
r=grok('recover',{unsafe_goal=true})
eq(r.places,1); eq(r.unsafe_goal,'the corpse (30,0) is inside medium-worm-turret (40,0) range 30 (10.0 tiles from it) (unsafe_goal)')
-- avoid_enemies false: no check.
r=grok('recover',{avoid_enemies=false})
eq(r.places,1); eq(r.avoid_enemies,nil)
runtime.avoid.goal_check=check
-- batch24 C2 (Haiku): an enemy group our force sees near the corpse is named; one within group_radius (48) keeps it out
-- unless ignore_groups.
local near_fn=runtime.threat.groups_near
runtime.threat.groups_near=function(_,_,pos) return {{size=12,kinds='8 big-biter, 4 big-spitter',position={x=pos.x+30,y=pos.y},distance=30,heading='W',closing=true}} end
ok,err=pcall(grok,'recover',{avoid_enemies=false})
has(tostring(err),'enemy groups our force sees: a group of 12 (8 big-biter, 4 big-spitter) at (60,0), 30 tiles off, moving W, closing on it; a group of 12 is 30 tiles from it (group_radius 48): ignore_groups: true goes anyway')
r=grok('recover',{avoid_enemies=false,ignore_groups=true})
eq(r.places,1); has(r.corpses[1],'a group of 12 (8 big-biter, 4 big-spitter) at (60,0), 30 tiles off')
r=grok('recover',{avoid_enemies=false,group_radius=20})
eq(r.places,1)
-- The team line for a death that left a corpse with items: who, where, the items, the killer, the groups near; once
-- per agent; an empty corpse is not said.
local kept_deaths=storage.agent_harness.char_deaths
storage.agent_harness.char_deaths={{surface='nauvis',position={x=30,y=0},tick=k4.character_corpse_tick_of_death,who='grok',by='medium-worm-turret'}}
local h={}
local dl=runtime.death_lines({force={}},h)
eq(#dl,1); has(dl[1],'grok died at (30,0) on nauvis '); has(dl[1],': the corpse holds 1 item; killed by medium-worm-turret; enemy groups our force sees: a group of 12')
eq(runtime.death_lines({force={}},h),nil)
storage.agent_harness.char_deaths=kept_deaths
runtime.threat.groups_near=near_fn
k4.valid=false

-- 6. A tour's walk waits for a train too (status train_wait), and its waits come in the tour's last.train_waits.
local k5=corpse(0,30,{['iron-plate']=3},tick-10)
b.corpses={{surface='nauvis',position={x=0,y=30},tick=tick-10}}
g2.position={x=0,y=0}
trains[1]=train; train.speed=0.5; train.carriages[1].position={x=-30,y=3}; train.path={current=1,size=4,rails={r1,r2,r3,far}}
r=grok('recover',{avoid_enemies=false})
eq(r.places,1)
advance(1)
-- The fake engine answers no path requests: steer straight at it.
local leg=storage.agent_harness.active[index('grok')].nav
leg.path_state=nil; leg.direct=true
to_tenth()
eq(g2.walking_state.walking,false)
has(grok('status',{}).active.train_wait,'for a train (locomotive at (-30,3), 108 km/h) to pass the rails ahead at (0.0,3.0)')
train.speed=0; advance(10)
eq(g2.walking_state.walking,true)
eq(#storage.agent_harness.active[index('grok')].train_waits,1)
g2.position={x=0,y=27}; advance(1)
eq(last('grok').outcome,'collected'); eq(k5.valid,false)
has(last('grok').train_waits[1],'s at (0.0,0.0) for a train (locomotive at (-30,3), 108 km/h) to pass the rails ahead at (0.0,3.0)')
trains[1]=nil
-- A tour that ends in reach on a rail walks off the rails first, then ends (backlog #820, Opus 105h09: a recover
-- that ended on the rails at its stop, and a locomotive killed him there); last.off_rails says where.
local k6=corpse(0,10,{stone=1},tick-10)
b.corpses={{surface='nauvis',position={x=0,y=10},tick=tick-10}}
g2.position={x=0.1,y=3}
grok('recover',{avoid_enemies=false}); advance(1)
eq(k6.valid,false,'collected at once')
local act=storage.agent_harness.active[index('grok')]
assert(act and act.rail_exit,'walking off the rails before it ends')
-- (the fake engine answers no path requests: steer straight at the spot, and be there)
act.nav.path_state=nil; act.nav.direct=true
g2.position={x=act.rail_exit.position.x,y=act.rail_exit.position.y}; advance(1)
eq(last('grok').outcome,'collected')
has(last('grok').off_rails,'the tour ended on a rail at (0.1,3.0): walked off the rails to')
eq(last('grok').on_rails,nil)
print('round1520d: ok')
