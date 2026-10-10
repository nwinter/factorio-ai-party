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
eq(s.enemies.nearest_reached,'base (85,11) absorbing 50, 45 tiles E of our structures')
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
print('threat tests passed')
