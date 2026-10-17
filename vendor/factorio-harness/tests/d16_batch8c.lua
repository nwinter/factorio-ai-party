-- d16 batch8 Group C (building, circuits, research). Run from the harness root: lua tests/d16_batch8c.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- C2 (Sol 16:50: an infinite technology named several times was queued once): a target level keeps it coming.
do
  local st={}
  local function tech(name,level,max) return {name=name,level=level,researched=false,prototype={level=1,max_level=max}} end
  local force={name='player',technologies={['physical-projectile-damage-7']=tech('physical-projectile-damage-7',7,4294967295),
    automation=tech('automation',1,1),['mining-productivity-3']=tech('mining-productivity-3',3,4294967295)},research_queue={}}
  function force.add_research(t)
    if #force.research_queue>=7 then return false end
    for _,q in ipairs(force.research_queue) do if q==t then return false end end
    force.research_queue[#force.research_queue+1]=t; return true
  end
  game={forces={player=force}}
  local R=dofile('mod/agent-harness_0.1.0/researchtarget.lua'){state=function() return st end}
  fails(function() R.set(force,{automation=2}) end,'automation has one level')
  fails(function() R.set(force,{['physical-projectile-damage-7']=200}) end,'at level 7; a target is at most 100 levels past it')
  fails(function() R.set(force,{nope=3}) end,'no technology nope')
  local out=R.set(force,{['physical-projectile-damage-7']=10})
  eq(out[1],'physical-projectile-damage-7: target level 10')
  eq(force.research_queue[1].name,'physical-projectile-damage-7')
  force.current_research=force.research_queue[1]
  local rows=R.read(force)
  eq(rows[1].line,'physical-projectile-damage-7: target level 10; researching level 7; 4 levels left')
  -- Level 7 done: the game takes it off the queue and the technology reads level 8.
  table.remove(force.research_queue,1); force.current_research=nil
  force.technologies['physical-projectile-damage-7'].level=8
  for i=1,7 do force.research_queue[i]={name='other'..i} end
  R.tick(300)
  eq(R.read(force)[1].line,'physical-projectile-damage-7: target level 10; not queued: the queue is full (added when there is room); 3 levels left')
  table.remove(force.research_queue,1)
  R.tick(600)
  eq(R.read(force)[1].line,'physical-projectile-damage-7: target level 10; queued at 7, level 8; 3 levels left')
  -- Past level 10 the target is done and dropped.
  force.technologies['physical-projectile-damage-7'].level=11
  R.tick(900)
  eq(#R.read(force),0)
  eq(R.set(force,{['mining-productivity-3']=0})[1],'mining-productivity-3: target removed')
  game=nil
end
print('d16_batch8c C2 research target levels: ok')

-- C3 (Opus 18:20: 3 of 4 trunks at half capacity): where walked lanes lose capacity.
do
  local n=0
  local belts={}
  local surface={}
  function surface.find_entities_filtered(f)
    local cx,cy=(f.area[1][1]+f.area[2][1])/2,(f.area[1][2]+f.area[2][2])/2
    for _,b in ipairs(belts) do
      if math.abs(b.position.x-cx)<0.5 and math.abs(b.position.y-cy)<0.5 and (f.ghost_type and b.ghost_name or f.type and not b.ghost_name) then return {b} end
    end
    return {}
  end
  local function belt(x,y,dir,shape,left,right)
    n=n+1
    local b={type='transport-belt',name='transport-belt',position={x=x,y=y},direction=dir,belt_shape=shape,valid=true,unit_number=n,
      belt_neighbours={inputs={}},surface=surface,force='player',l={left=left or {},right=right or {}}}
    belts[#belts+1]=b
    return b
  end
  local function at(p) return string.format('(%g,%g)',p.x,p.y) end
  local A=dofile('mod/agent-harness_0.1.0/beltaudit.lua'){try=function(fn) local ok,v=pcall(fn); if ok then return v end end,
    place=function(e) return e.name..' '..at(e.position) end,at=at,side=function(k) return k==1 and 'left' or 'right' end,
    lanes_of=function(e) return e.l end,lane_text=function(m) local t={} for k,v in pairs(m) do t[#t+1]=v..' '..k end return #t>0 and table.concat(t,', ') or 'empty' end,
    lane_near=function(e,pos) return pos.x<e.position.x and 1 or 2 end,lane_full=function() return false end}
  -- A trunk going north at x=0; a belt from the west side-loads both its lanes at (0,0).
  local t0=belt(0.5,0.5,0,'straight',{['iron-plate']=4},{['iron-plate']=4})
  local t1=belt(0.5,1.5,0,'straight',{['iron-plate']=4},{['iron-plate']=4})
  t0.belt_neighbours.inputs={t1}
  local s=belt(-0.5,0.5,4,'straight',{['copper-plate']=4},{['copper-plate']=3})
  t0.belt_neighbours.inputs[2]=s
  local out=A.audit({{tiles={t1,t0}}},nil,24)
  eq(out[1],'transport-belt (-0.5,0.5) side-loads both its lanes (left 4 copper-plate, right 3 copper-plate) onto transport-belt (0.5,0.5) left lane only: at most half of what it carries gets on')
  -- A turn east to north made straight by one empty stub tile behind it.
  local c=belt(10.5,0.5,0,'straight')
  local stubt=belt(10.5,1.5,0,'straight')
  local w=belt(9.5,0.5,4,'straight',{['iron-ore']=5},{})
  c.belt_neighbours.inputs={stubt,w}
  out=A.audit({{tiles={w,c}}},nil,24)
  has(out[1],'a curve made a side-load at transport-belt (10.5,0.5): transport-belt (9.5,0.5) turns into it, but the empty transport-belt (10.5,1.5) behind it keeps it straight, so both lanes')
  -- A route ending two tiles short of the trunk going on.
  local e=belt(20.5,5.5,0,'straight',{coal=3},{})
  local f=belt(20.5,2.5,0,'straight')
  out=A.audit({{tiles={e},end_at=e,stop='belt ends at transport-belt (20.5,5.5): ...'}},nil,24)
  eq(out[1],'missing tiles at (20.5,4.5), (20.5,3.5): transport-belt (20.5,5.5) ends there and transport-belt (20.5,2.5) goes on after it carrying left empty, right empty (nothing reaches it from here)')
  -- A ghost one tile ahead.
  local g=belt(30.5,4.5,0,'straight'); g.ghost_name='transport-belt'
  local e2=belt(30.5,5.5,0,'straight')
  out=A.audit({{tiles={e2},end_at=e2,stop='belt ends at x'}},nil,24)
  eq(out[1],'transport-belt (30.5,5.5) ends at a transport-belt ghost (30.5,4.5): nothing passes until it is built')
  -- Nothing to say.
  local lone=belt(50.5,50.5,0,'straight')
  out=A.audit({{tiles={lone},end_at=lone,stop='belt ends at x'}},nil,24)
  eq(out[1],'1 belt tile walked: no side-load of two carried lanes onto one, no curve made a side-load, no route ending 4 tiles or less short of a belt ahead')
end
print('d16_batch8c C3 lane audit: ok')

-- C4 (Opus 18:20, 4 times: among drills and belts every walk ended "nor to anywhere within 48 tiles"): say so.
do
  local P=dofile('mod/agent-harness_0.1.0/pathing.lua'){paths=function() return {} end}
  local near={{name='electric-mining-drill',type='mining-drill',valid=true},{name='electric-mining-drill',type='mining-drill',valid=true},
    {name='transport-belt',type='transport-belt',valid=true}}
  local p={position={x=-300.4,y=-305.4},surface={find_entities_filtered=function() return near end}}
  local nav={region={closed=false}}
  eq(P.boxed(p,nav),'boxed in at (-300.4,-305.4) by 2 electric-mining-drill, 1 transport-belt within 2.5 tiles: the gaps between them are narrower than a path request starts in, but the area you can reach is not closed in: move_to squeeze=true walks your own steps out along the gaps; pathfind=false steers straight at the goal (belts carry you)')
  nav.squeeze_tried=true
  has(P.boxed(p,nav),'not closed in: pathfind=false steers')
  eq(P.boxed(p,{region={closed=true}}),nil,'closed in says what closes it')
  near={{name='stone-wall',type='wall',valid=true}}
  eq(P.boxed(p,{}),nil,'walls alone: not drills or belts')
end
print('d16_batch8c C4 boxed in by drills and belts: ok')

-- E11 (Astra 19:50): a leg's asteroids, and shots per asteroid after resistances and bonuses.
do
  prototypes={space_connection={['gleba-aquilo']={from={name='gleba'},to={name='aquilo'},length=30000,asteroid_spawn_definitions={
      {asteroid='big-oxide-asteroid',type='entity',spawn_points={{distance=0,probability=0},{distance=0.4,probability=0.001},{distance=1,probability=0.001}}},
      {asteroid='oxide-asteroid-chunk',type='asteroid-chunk',spawn_points={{distance=0,probability=0.5},{distance=1,probability=0.5}}}}}},
    entity={['big-oxide-asteroid']={get_max_health=function() return 2000 end,resistances={physical={decrease=2000,percent=0.1},explosion={decrease=0,percent=0.1}}},
      ['medium-oxide-asteroid']={get_max_health=function() return 400 end,resistances={physical={decrease=0,percent=0.1}}}},
    item={['firearm-magazine']={get_ammo_type=function() return {category='bullet',action={{action_delivery={{type='instant',target_effects={{type='damage',damage={amount=5,type='physical'}}}}}}}} end}}}
  local R=dofile('mod/agent-harness_0.1.0/routeammo.lua'){segments=function() return {} end}
  local d=R.density('aquilo','gleba')
  assert(math.abs(d['big-oxide-asteroid']-0.0008)<1e-9,tostring(d['big-oxide-asteroid'])); eq(d['oxide-asteroid-chunk'],nil,'chunks are not shot')
  local force={get_ammo_damage_modifier=function() return 1 end,get_turret_attack_modifier=function() return 0 end}
  eq(R.shots('big-oxide-asteroid','firearm-magazine',force),false,'under 1 a hit: none hurt')
  eq(R.shots('medium-oxide-asteroid','firearm-magazine',force),45,'400 / (10 x 0.9)')
  prototypes=nil
end
print('d16_batch8c E11 route asteroids and shots: ok')
