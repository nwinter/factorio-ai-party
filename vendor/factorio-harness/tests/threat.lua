-- Run from repository root: lua tests/threat.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path  -- (snapfail.lua)
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^.5 end
defines={flow_precision_index={one_minute=1}}
local storage={}
local evolution=0.25
local mine={name='player',players={{}},is_chunk_visible=function(_,c) return c.x<3 end,is_chunk_charted=function(_,c) return c.x>=-1 end,
  get_spawn_position=function() return {x=0,y=0} end}
local enemy={name='enemy',get_evolution_factor=function() return evolution end,get_evolution_factor_by_time=function() return 0.2 end,
  get_evolution_factor_by_pollution=function() return 0.04 end,get_evolution_factor_by_killing_spawners=function() return 0.01 end}
local stats={input_counts={['boiler']=1,['burner-mining-drill']=1,['stone-furnace']=1,['lab']=1},output_counts={tree=1},
  get_flow_count=function(f)
    if f.category=='output' then return 30 end
    return ({boiler=300,['burner-mining-drill']=120,['stone-furnace']=40,lab=0.1})[f.name]
  end}
game={tick=1000,forces={enemy=enemy,player=mine},get_pollution_statistics=function() return stats end}
-- Our base sits around the origin; the cloud covers chunks x<=2 on row 0.
local polluted=function(pos) local cx,cy=math.floor(pos.x/32),math.floor(pos.y/32); return (cx<=2 and cy==0) and 50 or 0 end
local spawners={
  {valid=true,type='unit-spawner',force=enemy,position={x=80,y=10}},{valid=true,type='unit-spawner',force=enemy,position={x=90,y=12}},
  {valid=true,type='unit-spawner',force=enemy,position={x=200,y=10}},
  {valid=true,type='unit-spawner',force=enemy,position={x=-300,y=300},fogged=true}}
local ours={{valid=true,position={x=10,y=10}},{valid=true,position={x=40,y=10}}}
local scans=0
-- Generated chunks x -2..8, y -1..1; column -2 is uncharted.
local function chunks()
  local list={}
  for x=-2,8 do for y=-1,1 do list[#list+1]={x=x,y=y} end end
  local i=0
  return function() i=i+1; return list[i] end
end
local surface={index=1,name='nauvis',get_total_pollution=function() return 1234.4 end,get_pollution=function(pos) return polluted(pos) end,get_chunks=chunks,
  find_entities_filtered=function(f)
    if f.type=='unit-spawner' then scans=scans+1; return spawners end
    if f.type=='radar' then return {{},{}} end
    local out={}
    for _,e in ipairs(ours) do if distance(e.position,f.position)<=f.radius then out[#out+1]=e end end
    return out
  end,
  get_closest=function(pos,list)
    table.sort(list,function(a,b) return distance(a.position,pos)<distance(b.position,pos) end); return list[1]
  end}
local p={index=1,surface=surface,position={x=0,y=0},force=mine}
local T=dofile('mod/agent-harness_0.1.0/threat.lua'){state=function() return storage end,distance=distance,
  known=function(_,e) return not e.fogged end,lookup=function(i) return i==1 and p or nil end}
local s=T.summary(p)
eq(s.evolution.factor,0.25); eq(s.evolution.pollution,0.04); eq(s.evolution.delta,nil)
eq(s.pollution.total,1234); eq(s.pollution.per_min,460); eq(s.pollution.absorbed_per_min,30)
eq(s.pollution.top,'boiler 300, burner-mining-drill 120, stone-furnace 40')
eq(s.enemies.bases,2); eq(s.enemies.reached,1)
eq(s.enemies.nearest_reached,'base (85,11) pollution there now (50), 45 tiles E of our structures')
eq(s.enemies.reached_list,'(85,11) 45 tiles E')
eq(s.enemies.next,'base (200,10) 4 chunks from the cloud (cloud to its W)')
eq(s.enemies.list,nil); eq(scans,1)
eq(s.enemies.nearest,'base (85,11) 2 spawners, 45 tiles E of our structures, seen now')
-- Chart coverage, and the cloud only within the chart plus where it leaves it.
eq(s.chart.charted_chunks,30); eq(s.chart.visible_chunks,12); eq(s.chart.radars,2); eq(s.chart.extent,'x -32..287 y -32..63')
eq(s.pollution.cloud_chunks,4); eq(s.pollution.cloud_extent,'x -32..95 y 0..31'); eq(s.pollution.cloud_beyond_chart,'W')
-- The cloud layer for the stream map (viewer Joonazan, operator 13:02): the operator read clouds carries every charted
-- polluted chunk with its amount, the pollutant and its map colour, and the nests reached; the status chart does not.
do
  surface.pollutant_type={name='pollution',chart_color={r=0.55,g=0.27,b=0.09,a=0.6}}
  local get,sc=game.get_surface,scans
  game.get_surface=function(i) return i==1 and surface or nil end
  eq(s.chart.cells,nil,'no cells in a status reply')
  T.summary(p,true)  -- (a fresh chart, with the pollutant now)
  local c=T.operator.clouds({}).clouds
  eq(#c,1); eq(c[1].surface,'nauvis'); eq(c[1].chunks,4); eq(c[1].max,50); eq(c[1].total,200)
  eq(c[1].cells[1][1],-1); eq(c[1].cells[1][2],0); eq(c[1].cells[1][3],50)
  eq(c[1].pollutant.name,'pollution'); eq(c[1].pollutant.color.r,0.55)
  eq(c[1].reached[1].position.x,85)
  eq(#T.operator.clouds({surface='gleba'}).clouds,0)
  game.get_surface=get; scans=sc
end
-- Cached for 600 ticks; threats=true rescans and lists every base.
game.tick=1500; T.summary(p); eq(scans,1)
local detail=T.summary(p,true); eq(scans,2); eq(#detail.enemies.list,2); eq(detail.enemies.list[2].cloud_gap,4)
-- Evolution delta compares with a reading at least five minutes old.
game.tick=1000+18000; evolution=0.26; T.summary(p)
game.tick=1000+36000; evolution=0.27
local later=T.summary(p); eq(later.evolution.delta,0.01); eq(later.evolution.since,19000)
-- Unit groups only count where our force can see them.
local function group(x,members)
  return {valid=true,force=enemy,surface=surface,position={x=x,y=5},members=members,
    command={destination={x=10,y=10}}}
end
T.on_group{tick=37000,group=group(50,{1,2,3,4,5})}
T.on_group{tick=37001,group=group(500,{1,2})}
-- Damage by enemies is summarised per chunk; enemy and neutral victims are ignored.
local wall={valid=true,name='stone-wall',force=mine,position={x=40,y=10}}
local drill={valid=true,name='burner-mining-drill',force=mine,position={x=45,y=12}}
local biter={valid=true,name='small-biter'}
T.on_damaged{tick=37010,entity=wall,force=enemy,cause=biter,final_damage_amount=7}
T.on_damaged{tick=37020,entity=drill,force=enemy,cause=biter,final_damage_amount=5}
T.on_damaged{tick=37030,entity={valid=true,name='biter-spawner',force=enemy,position={x=80,y=10}},force=mine,final_damage_amount=9}
T.on_damaged{tick=37040,entity=wall,force={name='neutral'},final_damage_amount=1}
local alerts=T.alerts(36000)
eq(#alerts.attack_groups,1); eq(alerts.attack_groups[1].size,5); eq(alerts.attack_groups[1].target.x,10)
eq(#alerts.attacked,1); eq(alerts.attacked[1].hits,2); eq(alerts.attacked[1].damage,12); eq(alerts.attacked[1].by,'small-biter')
eq(alerts.attacked[1].entities,'burner-mining-drill x1, stone-wall x1'); eq(alerts.attacked[1].chunk_centre.x,48)
eq(T.alerts(37100),nil)
-- A nest charted after the first survey, and the cloud reaching a known nest, are news.
spawners[#spawners+1]={valid=true,type='unit-spawner',force=enemy,position={x=100,y=-200}}
polluted=function(pos) local cx,cy=math.floor(pos.x/32),math.floor(pos.y/32); return (cx<=6 and cy==0) and 50 or 0 end
game.tick=38000; T.summary(p,true)
local news=T.alerts(37500).enemy_news
eq(#news,2); eq(news[1].kind,'pollution_reached_nest'); eq(news[1].position.x,200); eq(news[2].kind,'nest_charted'); eq(news[2].position.y,-200)
game.tick=39000; T.summary(p,true); eq(T.alerts(38500),nil)
-- Reply lines for the news: pollution reaching a nest, with bearing and distance from the base centre and our nearest building.
local lines=T.news_lines(nil,37500)
eq(#lines,1); eq(lines[1],'pollution reached nest (200,10), 1 spawner: 200 tiles E of base centre (0,0), 160 tiles E of our nearest building')
eq(#T.news_lines(news[2].seq,0),0)
-- Once per nest: a cloud that recedes and returns is not news again.
local cloud=polluted
polluted=function() return 0 end; game.tick=40000; T.summary(p,true)
polluted=cloud; game.tick=41000; T.summary(p,true)
eq(#T.news_lines(nil,39500),0)
-- Replies rescan an agent's survey only when it is over a minute old.
p.character={valid=true}; p.valid=true
local before=scans
game.tick=41000+3000; T.watch(p); T.watch_step(storage,game.tick); eq(scans,before)
-- (d19 batch45) asked in the reply, read in the background: listed one tick, clustered the next, then the news
game.tick=41000+3600; T.watch(p); eq(scans,before); eq(storage.watch_jobs[1].asked,game.tick)
T.watch_step(storage,game.tick); eq(scans,before+1)
T.watch_step(storage,game.tick); eq(storage.watch_jobs[1],nil); eq(storage.watch_errors,nil)
-- Incidents: a gathered group heading for the attacked point gives its size and kinds; the nearest charted spawner
-- is the likely source, with distance and bearing from the attacked point.
T.on_group{tick=45000,group={valid=true,force=enemy,surface=surface,position={x=60,y=20},members={{name='small-biter'},{name='small-biter'},{name='medium-biter'}},
  command={destination={x=20,y=20}}}}
game.tick=45100
T.on_damaged{tick=45100,entity={valid=true,name='stone-furnace',force=mine,surface=surface,position={x=20,y=21}},force=enemy,
  cause={valid=true,name='small-biter',unit_number=1},final_damage_amount=10}
local a=T.alerts(45050).attacked[1]
eq(a.group.size,3); eq(a.group.kinds,'2 small-biter, 1 medium-biter'); eq(a.source.position.x,80); eq(a.source.bearing,'E'); eq(a.source.distance,61)
eq(a.line:gsub('^attack #%d+',''),' at (20,21): a group of 3 (2 small-biter, 1 medium-biter) that gathered at (60,20); likely from nest (80,10) 61 tiles E; '
  ..'stone-furnace x1 hit 1 times, 10 damage, 0s ago')
-- A unit's own spawner, when the engine gives it and it is charted, is named as the source. (d22 batch100 BJ2) As
-- 2.0.77 gives it: the spawner on the unit's commandable (unit.spawner is no key), every game object userdata.
local function ud(fields)
  local u=io.tmpfile()
  debug.setmetatable(u,{__index=function(_,k) local v=fields[k]; if v==nil and k~='commandable' then error('LuaEntity doesn\'t contain key '..k) end; return v end})
  return u
end
local own=ud{valid=true,position={x=200,y=10}}
T.on_damaged{tick=45100,entity={valid=true,name='pipe',force=mine,surface=surface,position={x=100,y=100}},force=enemy,
  cause=ud{valid=true,name='small-biter',type='unit',force=enemy,unit_number=2,position={x=190,y=30},surface=surface,commandable=ud{valid=true,spawner=own}},final_damage_amount=3}
a=T.alerts(45050).attacked
local pipe_hit=a[1].at.x==100 and a[1] or a[2]
eq(pipe_hit.line:match('; (from nest [^;]+);'),'from nest (200,10) 135 tiles NE'); eq(pipe_hit.attackers,1); eq(pipe_hit.kinds,'1 small-biter')
-- Nine agents on one surface: the chart (every chunk) is walked once a minute
-- and the pollution read once per 10 s for all of them; nests stay per agent.
local walks=0
surface.get_chunks=function() walks=walks+1; return chunks() end
local agents={}
for i=1,9 do agents[i]={index=10+i,surface=surface,position={x=i,y=0},force=mine} end
game.tick=60000; scans=0
for _=1,20 do for _,a in ipairs(agents) do T.summary(a) end; game.tick=game.tick+60 end
eq(walks,1); eq(scans,18)
eq(T.summary(agents[3]).chart.charted_chunks,30)
game.tick=60000+3600; T.summary(agents[1]); eq(walks,2)
-- Reach is remembered for 15 minutes: the pollution on a nest's chunk hovers about zero at the cloud's edge, and a
-- reading of 0 right after one of 50 still counts as reached (status flickered 1, 0, 1 in shift 6).
polluted=function(pos) local cx,cy=math.floor(pos.x/32),math.floor(pos.y/32); return (cx<=2 and cy==0) and 50 or 0 end
game.tick=130000; local r=T.summary(p,true); eq(r.enemies.reached,1)
polluted=function() return 0 end
game.tick=130000+600; r=T.summary(p,true); eq(r.enemies.reached,1)
eq(r.enemies.nearest_reached,'base (85,11) pollution last there 10s ago, 45 tiles E of our structures')
game.tick=130000+T.REACH_WINDOW+1; eq(T.summary(p,true).enemies.reached,0)
-- Reached-nest news once per nest per shift: a new shift tells the agents again of nests still reached.
polluted=cloud
game.tick=200000; T.summary(p,true)
eq(#T.news_lines(nil,199000),0)
storage.shift={tick=200500}
game.tick=201000; T.summary(p,true)
local again=T.news_lines(nil,200900)
eq(#again,2); assert(again[1]:find('pollution reached nest (85,11)',1,true),again[1])
game.tick=202000; T.summary(p,true); eq(#T.news_lines(nil,201500),0)
-- The nearest structure is a building: a ghost or a car near a nest is not one.
ours[#ours+1]={valid=true,type='entity-ghost',position={x=180,y=10}}
ours[#ours+1]={valid=true,type='car',position={x=185,y=10}}
game.tick=203000; local far=T.summary(p,true).enemies.list
for _,b in ipairs(far) do if b.position.x==200 then eq(b.distance,160) end end
-- Surfaces: hits on a platform are not attacks here; the same chunk on two planets is two incidents, and a reader
-- elsewhere is told the surface.
local nauvis,vulcanus,platform={index=1,name='nauvis'},{index=2,name='vulcanus'},{index=3,name='platform-3',platform={name='Starling'}}
local function hit(tick,surf,x)
  T.on_damaged{tick=tick,entity={valid=true,name='gun-turret',force=mine,surface=surf,position={x=x,y=5}},force=enemy,
    cause={valid=true,name='small-biter',unit_number=tick},final_damage_amount=10}
end
storage.damage=nil; storage.source_memo=nil
nauvis.find_entities_filtered=function() return {} end; vulcanus.find_entities_filtered=nauvis.find_entities_filtered
game.tick=210000
hit(210000,nauvis,5); hit(210000,vulcanus,6); hit(210000,platform,7)
local rows=T.alerts(209000,'nauvis').attacked
eq(#rows,2)
local on_v=rows[1].surface=='vulcanus' and rows[1] or rows[2]
eq(on_v.surface,'vulcanus'); assert(on_v.line:find('^attack #%d+ on vulcanus at %(6,5%)'),on_v.line)
local on_n=rows[1].surface=='nauvis' and rows[1] or rows[2]
assert(on_n.line:find('^attack #%d+ at %(5,5%)'),on_n.line)
eq(T.attack_line(storage.damage['vulcanus:0,0'],false,'vulcanus'):find(' on '),nil)
-- Live groups for the operator (attack_groups_live): every gathered group with a target, visible or not, followed
-- while valid; where it is, its members, state, the distances to its target and to our nearest building.
defines.group_state={gathering=0,moving=1,attacking_distraction=2,attacking_target=3,finished=4}
storage.live_groups=nil; storage.attack_groups=nil
local field={index=4,name='nauvis',find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs({{valid=true,type='wall',position={x=100,y=0}},{valid=true,type='car',position={x=150,y=0}}}) do
      if distance(e.position,f.position)<=f.radius then out[#out+1]=e end
    end
    return out
  end,get_closest=function(pos,list) table.sort(list,function(a,b) return distance(a.position,pos)<distance(b.position,pos) end); return list[1] end}
local function unit(name) return {name=name} end
local big={valid=true,force=enemy,surface=field,position={x=300,y=0},state=0,
  members={unit('big-biter'),unit('big-biter'),unit('medium-spitter')},
  command={type=1,commands={{type=2},{target={valid=true,position={x=96,y=4}}}}}}
local fogged={valid=true,force=enemy,surface=field,position={x=900,y=0},state=0,members={unit('small-biter')},
  command={destination={x=700,y=0}}}
local idle={valid=true,force=enemy,surface=field,position={x=0,y=900},state=0,members={unit('small-biter')}}
game.tick=220000
T.on_group{tick=220000,group=big}; T.on_group{tick=220000,group=fogged}; T.on_group{tick=220000,group=idle}
local live=T.operator.attack_groups_live({}).groups
eq(#live,2) -- a group without a target is not tracked
eq(live[1].size,3); eq(live[1].kinds,'2 big-biter, 1 medium-spitter'); eq(live[1].state,'gathering')
eq(live[1].target.x,96); eq(live[1].target_distance,204); eq(live[1].nearest,nil) -- 200 tiles out: no building within 160
eq(live[2].visible,false); eq(live[2].target.x,700)
-- it moves in: positions and distances follow the group, members as they are now
big.position={x=180,y=0}; big.state=1; big.members={unit('big-biter'),unit('medium-spitter')}
game.tick=221200
live=T.operator.attack_groups_live({}).groups
eq(live[1].position.x,180); eq(live[1].state,'moving'); eq(live[1].size,2); eq(live[1].first_size,3)
eq(live[1].nearest.x,100); eq(live[1].nearest_distance,80); eq(live[1].age_s,20)
-- gone (invalid) or too old: dropped
big.valid=false
eq(#T.operator.attack_groups_live({}).groups,1)
game.tick=220000+36001
eq(#T.operator.attack_groups_live({}).groups,0); eq(#storage.live_groups,0)
-- at most 10 kept
for i=1,12 do T.on_group{tick=game.tick,group={valid=true,force=enemy,surface=field,position={x=i,y=500},state=0,members={unit('small-biter')},command={destination={x=0,y=0}}}} end
eq(#storage.live_groups,10); eq(#T.operator.attack_groups_live({}).groups,10)
-- batch24 C2 (Haiku: a corpse near a wave): the groups our force sees round a point, how far, which way, closing
storage.live_groups=nil
local wave={valid=true,force=enemy,surface=field,position={x=90,y=0},state=1,members={unit('big-biter'),unit('big-biter'),unit('small-spitter')},command={destination={x=10,y=0}}}
local unseen={valid=true,force=enemy,surface=field,position={x=130,y=0},state=1,members={unit('small-biter')},command={destination={x=10,y=0}}}
T.on_group{tick=game.tick,group=wave}; T.on_group{tick=game.tick,group=unseen}
wave.position={x=60,y=0}
local near=T.groups_near(mine,field,{x=20,y=0},160)
eq(#near,1) -- the other stands in a chunk our force does not see
eq(near[1].size,3); eq(near[1].distance,40); eq(near[1].heading,'W'); eq(near[1].closing,true)
eq(T.groups_line(near),'enemy groups our force sees: a group of 3 (2 big-biter, 1 small-spitter) at (60,0), 40 tiles off, moving W, closing on it')
eq(T.groups_line({}),'no enemy group our force sees within reach of it')
eq(#T.groups_near(mine,field,{x=20,y=0},30),0)
-- Big enemies (big_enemies_live): demolishers found by a type search every 10 s, followed by reference; their speed,
-- whether they close on our nearest building, the ETA, the nearest character. Platforms are not searched.
local demo={valid=true,unit_number=77,name='small-demolisher',position={x=-536,y=68}}
local far_demo={valid=true,unit_number=78,name='medium-demolisher',position={x=3000,y=0}}
local turret={valid=true,type='ammo-turret',name='gun-turret',position={x=-236,y=68}}
local sol_char={valid=true,type='character',position={x=-240,y=70},player={name='sol'}}
local searches=0
local vul={name='vulcanus',find_entities_filtered=function(f)
    if f.type=='segmented-unit' then searches=searches+1; return {demo,far_demo} end
    local out={}
    for _,e in ipairs(f.type=='character' and {sol_char} or {turret,sol_char}) do
      if f.force==mine and distance(e.position,f.position)<=f.radius then out[#out+1]=e end
    end
    return out
  end,get_closest=function(pos,list) table.sort(list,function(a,b) return distance(a.position,pos)<distance(b.position,pos) end); return list[1] end}
demo.surface,far_demo.surface=vul,vul
local plat_surface={name='platform-1',platform={},find_entities_filtered=function() error('platforms are not searched') end}
game.surfaces={vulcanus=vul,['platform-1']=plat_surface}
mine.players={{}}; game.forces={enemy=enemy,player=mine}
game.tick=300000
local big=T.operator.big_enemies_live({}).enemies
eq(#big,1); eq(searches,1) -- the far one has nothing of ours within 500 tiles
eq(big[1].name,'small-demolisher'); eq(big[1].nearest.name,'gun-turret'); eq(big[1].nearest_distance,300)
eq(big[1].character_distance,296); eq(big[1].character.player,'sol'); eq(big[1].speed,nil); eq(big[1].eta_s,nil)
-- 2 s later it has come 5 tiles closer: 2.5 tiles/s, closing, ~118 s away; no new search inside 10 s
demo.position={x=-531,y=68}; game.tick=300120
big=T.operator.big_enemies_live({}).enemies
eq(big[1].speed,2.5); eq(big[1].closing,true); eq(big[1].eta_s,118); eq(searches,1)
-- it turns away
demo.position={x=-536,y=68}; game.tick=300240
big=T.operator.big_enemies_live({}).enemies
eq(big[1].closing,false); eq(big[1].eta_s,nil)
-- dead: dropped; the next search after 10 s finds what is there
demo.valid=false; game.tick=300300
eq(#T.operator.big_enemies_live({}).enemies,0)
game.tick=300900; T.operator.big_enemies_live({}); eq(searches,2)

-- task-statuscost (01:15 on world n: threat.summary 110 ms, threat.watch up to 123 ms): a base's nearest building and
-- cloud gap are kept per surface and base chunk for every agent; at most 2 fresh searches per call, the rest '?' until
-- a later call.
do
  local st2,rings={},0
  local far={}
  for i=1,5 do far[i]={valid=true,type='unit-spawner',force=enemy,position={x=100*i,y=200}} end
  local surf={index=7,get_pollution=function() return 0 end,get_total_pollution=function() return 0 end,get_chunks=function() return function() end end,
    find_entities_filtered=function(f)
      if f.type=='unit-spawner' then return far end
      if f.type=='radar' then return {} end
      rings=rings+1
      local out={}
      for _,e in ipairs(ours) do if distance(e.position,f.position)<=f.radius then out[#out+1]=e end end
      return out
    end,
    get_closest=function(pos,list) table.sort(list,function(a,b) return distance(a.position,pos)<distance(b.position,pos) end); return list[1] end}
  local T2=dofile('mod/agent-harness_0.1.0/threat.lua'){state=function() return st2 end,distance=distance,known=function() return true end}
  local a1={index=1,surface=surf,position={x=300,y=0},force=mine}
  local a2={index=2,surface=surf,position={x=310,y=0},force=mine}
  game.tick=400000
  local function known_distances(r) local n=0 for _,b in ipairs(r.enemies.list) do if b.distance then n=n+1 end end return n end
  local r1=T2.summary(a1,true)
  eq(#r1.enemies.list,5); eq(known_distances(r1),2,'two searched this call')
  assert(r1.enemies.list[5].distance_pending,'the rest wait for a later call')
  local after_first=rings
  eq(known_distances(T2.summary(a1,true)),4); eq(known_distances(T2.summary(a1,true)),5)
  local all=rings
  eq(known_distances(T2.summary(a2,true)),5,'another agent reads what was found'); eq(rings,all,'no ring search for it')
  assert(after_first>0)
  game.tick=400000+18000
  local before=rings
  eq(known_distances(T2.summary(a2,true)),5,'5 min later: the kept ones still shown')
  assert(rings>before and rings-before<=8,'and two searched again (up to 4 rings each)')
end
-- The chart sweep (task-statuscost): after the first chart, the chart is redone in the background over the box of
-- generated chunks plus a margin, a slice a tick; the same numbers as the walk over every chunk; a status walks none.
do
  local st3,walked={},0
  local surf={index=9,name='nauvis',get_total_pollution=function() return 0 end,get_pollution=function(pos) return polluted(pos) end,
    get_chunks=function() walked=walked+1; return chunks() end,
    is_chunk_generated=function(c) return c.x>=-2 and c.x<=8 and c.y>=-1 and c.y<=1 end,
    find_entities_filtered=function(f) if f.type=='radar' then return {{},{}} end return {} end}
  local T3=dofile('mod/agent-harness_0.1.0/threat.lua'){state=function() return st3 end,distance=distance,known=function() return true end}
  local a={index=1,surface=surf,position={x=0,y=0},force=mine}
  game.tick=500000
  local first_s=T3.summary(a)
  local first=first_s.chart
  eq(walked,1)
  game.forces={enemy=enemy,player=mine}
  game.get_surface=function(i) return i==9 and surf or nil end
  game.players={}
  game.tick=game.tick+3600
  -- (spread: the box's 19x11 chunk positions at 16 a tick, the least; operator 18:12: 2000 a tick put a big surface's
  -- sweep in a few ticks, threat.tick 83 ms in one game second)
  local ticks=0
  repeat game.tick=game.tick+1; T3.tick(game.tick); ticks=ticks+1 until not next(st3.chart_jobs or {}) and ticks>1 or ticks>100
  eq(st3.chart_jobs and next(st3.chart_jobs),nil,'the sweep is done')
  eq(ticks,1+math.ceil(19*11/16),'the job starts, then 16 positions a tick')
  local swept=T3.summary(a).chart
  eq(walked,1,'no walk over every chunk in a status')
  eq(swept.charted_chunks,first.charted_chunks); eq(swept.visible_chunks,first.visible_chunks); eq(swept.extent,first.extent)
  eq(swept.radars,first.radars)
  local s3=T3.summary(a)
  eq(s3.pollution.cloud_chunks,first_s.pollution.cloud_chunks); eq(s3.pollution.cloud_extent,first_s.pollution.cloud_extent)
  eq(s3.pollution.cloud_beyond_chart,first_s.pollution.cloud_beyond_chart)
  -- (d20 batch55 P1, viewer Aurora) A sweep that fails: the chart keeps the tick it was made at, status says its age and
  -- the failure, and the next sweep starts CHART_TICKS after the failure.
  local _,sh=next(st3.threat_shared)
  local made=sh.chart.tick
  local gen=surf.is_chunk_generated
  game.tick=made+3600
  T3.tick(game.tick); assert(next(st3.chart_jobs),'a sweep started')
  surf.is_chunk_generated=function() error('chunk read broke') end
  game.tick=game.tick+1; T3.tick(game.tick)
  eq(next(st3.chart_jobs),nil,'the sweep ended'); eq(st3.chart_errors.count,1)
  eq(sh.chart.tick,made,'the chart keeps its tick')
  local failed_at=game.tick
  game.tick=game.tick+600
  eq(T3.summary(a).chart.refresh_failed,string.format('the last refresh of the chart failed 10s ago (%s); the chart is from %ds ago',
    sh.chart.refresh_failed.error,math.floor((game.tick-made)/60)))
  assert(sh.chart.refresh_failed.error:find('chunk read broke',1,true))
  surf.is_chunk_generated=gen
  game.tick=failed_at+3599; T3.tick(game.tick); eq(next(st3.chart_jobs),nil,'no sweep within CHART_TICKS of the failure')
  game.tick=game.tick+1; T3.tick(game.tick); assert(next(st3.chart_jobs),'the next sweep')
  -- A sweep finishing after a forced read (threats=true) never replaces its chart.
  local job_start=select(2,next(st3.chart_jobs)).start
  game.tick=game.tick+2; T3.tick(game.tick)
  local forced=T3.summary(a,true)
  local newer=sh.chart
  eq(newer.tick,game.tick); eq(forced.chart.refresh_failed,nil,'a new chart carries no failure')
  repeat game.tick=game.tick+1; T3.tick(game.tick) until not next(st3.chart_jobs)
  assert(job_start<newer.tick)
  eq(sh.chart,newer,'the sweep\'s older chart was dropped')
  game.forces={enemy=enemy,player=mine}; game.get_surface=nil; game.players=nil
end
-- The spawner index (operator 18:33: threat.watch 93 ms in one reply, its find of spawners within 512 tiles): built in
-- the background in bands of at most 32 chunks over the circles asked for; a reply inside it finds no spawner and gives
-- the same bases; a killed spawner drops out at once; an agent outside it is found at once as before.
do
  local st4={}
  local nests={}
  for i=0,5 do nests[#nests+1]={valid=true,type='unit-spawner',force=enemy,position={x=150+i*3,y=-100+i*2},
    bounding_box={left_top={x=147.5+i*3,y=-102.5+i*2},right_bottom={x=152.5+i*3,y=-97.5+i*2}}} end
  nests[#nests+1]={valid=true,type='unit-spawner',force=enemy,position={x=-400,y=250},bounding_box={left_top={x=-402.5,y=247.5},right_bottom={x=-397.5,y=252.5}}}
  nests[#nests+1]={valid=true,type='unit-spawner',force=enemy,position={x=900,y=0},bounding_box={left_top={x=897.5,y=-2.5},right_bottom={x=902.5,y=2.5}}}
  local direct,banded,widest=0,0,0
  local surf={index=4,name='nauvis',get_total_pollution=function() return 0 end,get_pollution=function() return 0 end,get_chunks=chunks,
    is_chunk_generated=function() return false end,
    find_entities_filtered=function(f)
      if f.type=='unit-spawner' then
        local out={}
        if f.area then
          banded=banded+1; widest=math.max(widest,(f.area[2][1]-f.area[1][1])/32)
          for _,e in ipairs(nests) do local q=e.position; if q.x>=f.area[1][1]-3 and q.x<=f.area[2][1]+3 and q.y>=f.area[1][2]-3 and q.y<=f.area[2][2]+3 then out[#out+1]=e end end
        else
          direct=direct+1
          for _,e in ipairs(nests) do if distance(e.position,f.position)<=f.radius+2.5 then out[#out+1]=e end end
        end
        return out
      end
      if f.type=='radar' then return {} end
      return {}
    end,
    get_closest=function(pos,list) return list[1] end}
  local T4=dofile('mod/agent-harness_0.1.0/threat.lua'){state=function() return st4 end,distance=distance,known=function() return true end}
  local a={index=7,surface=surf,position={x=0,y=0},force=mine}
  game.tick=700000
  local first=T4.summary(a,true).enemies
  eq(direct,1); eq(first.bases,2,'the near nests as one base and the one at (-400,250); (900,0) is out of range')
  game.forces={enemy=enemy,player=mine}
  game.get_surface=function(i) return i==4 and surf or nil end
  game.players={}
  local ticks=0
  repeat game.tick=game.tick+1; ticks=ticks+1; T4.tick(game.tick) until (st4.spawn_index and st4.spawn_index['player/4']) or ticks>5000
  assert(st4.spawn_index['player/4'],'the index is built')
  assert(widest<=32,'bands of at most 32 chunks: '..widest)
  assert(ticks>40,'spread over ticks: '..ticks)
  local second=T4.summary(a,true).enemies
  eq(direct,1,'no find in the reply'); eq(second.bases,first.bases); eq(second.nearest,first.nearest)
  nests[7].valid=false
  eq(T4.summary(a,true).enemies.bases,1,'a killed nest drops out at once')
  local far={index=8,surface=surf,position={x=3000,y=0},force=mine}
  T4.summary(far,true); eq(direct,2,'outside the index: found at once')
  game.forces={enemy=enemy,player=mine}; game.get_surface=nil; game.players=nil
end
print('threat tests passed')
