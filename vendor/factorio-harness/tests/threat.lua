-- Run from repository root: lua tests/threat.lua
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
local surface={index=1,get_total_pollution=function() return 1234.4 end,get_pollution=function(pos) return polluted(pos) end,get_chunks=chunks,
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
  known=function(_,e) return not e.fogged end}
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
p.character={valid=true}
local before=scans
game.tick=41000+3000; T.watch(p); eq(scans,before)
game.tick=41000+3600; T.watch(p); eq(scans,before+1)
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
-- A unit's own spawner, when the engine gives it and it is charted, is named as the source.
T.on_damaged{tick=45100,entity={valid=true,name='pipe',force=mine,surface=surface,position={x=100,y=100}},force=enemy,
  cause={valid=true,name='small-biter',unit_number=2,spawner={valid=true,position={x=200,y=10}}},final_damage_amount=3}
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
print('threat tests passed')
