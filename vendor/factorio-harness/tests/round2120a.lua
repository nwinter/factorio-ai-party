-- Run from repository root: lua tests/round2120a.lua
-- 1. The walking tours check every stop at the call (Haiku, shift14 03:58: rearm surface=true walked into a big worm's
-- range; the character and 50 explosives lost): a stop inside a worm's range, within 40 tiles of a spawner or in an
-- area under attack now is left out and named, none left refuses; recover dry_run gives each corpse's danger and is a read.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4},
  inventory={chest=1,character_ammo=4,turret_ammo=7,fuel=2,furnace_source=3,furnace_result=5,artillery_turret_ammo=8,character_corpse=9},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1},
  wire_connector_id={pole_copper=5,circuit_red=1,circuit_green=2},entity_status={working=1,no_power=2,low_power=3}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,get_friend=function() return false end,get_cease_fire=function() return false end}
local enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}
local surface={name='nauvis',index=1}
-- Inventories with counts by item.
local function inv(items)
  local o={valid=true}
  o.get_item_count=function(q)
    if q==nil then local n=0; for _,c in pairs(items) do n=n+c end; return n end
    return items[type(q)=='table' and q.name or q] or 0
  end
  o.get_contents=function() local l={}; for k,c in pairs(items) do if c>0 then l[#l+1]={name=k,count=c,quality='normal'} end end; return l end
  o.items=items
  return o
end
local units=0
local function character(pos)
  units=units+1
  local main=inv({})
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  c.main=main
  c.insert=function(st) main.items[st.name]=(main.items[st.name] or 0)+st.count; return st.count end
  c.get_main_inventory=function() return main end
  c.get_item_count=function(n) return main.items[n] or 0 end
  c.get_inventory=function(id) if id==defines.inventory.character_ammo then return inv({}) end end
  c.can_reach_entity=function() return false end
  c.destroy=function() c.valid=false end
  c.prototype={collision_mask={layers={player=true}}}
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
-- The world's entities and a find over them: force (ours, or enemy names), type, name, position+radius, area, limit.
local ents={}
local function any(list,v) if type(list)=='string' then return list==v end for _,x in ipairs(list) do if x==v then return true end end return false end
local finds=0
surface.find_entities_filtered=function(f)
  finds=finds+1
  local out={}
  for _,e in ipairs(ents) do
    local ok=e.valid
    if ok and f.force then
      if type(f.force)=='table' and f.force.name then ok=e.force==f.force
      else ok=e.force~=nil and any(f.force,e.force.name) end
    end
    if ok and f.type then ok=any(f.type,e.type) end
    if ok and f.name then ok=any(f.name,e.name) end
    if ok and f.position and f.radius then local dx,dy=e.position.x-f.position.x,e.position.y-f.position.y; ok=dx*dx+dy*dy<=f.radius*f.radius end
    if ok and f.area then
      local lt,rb=f.area[1] or f.area.left_top,f.area[2] or f.area.right_bottom
      ok=e.position.x>=(lt.x or lt[1]) and e.position.x<=(rb.x or rb[1]) and e.position.y>=(lt.y or lt[2]) and e.position.y<=(rb.y or rb[2])
    end
    if ok then out[#out+1]=e end
    if f.limit and #out>=f.limit then break end
  end
  return out
end
local gun={type='ammo-turret',attack_parameters={ammo_categories={'bullet'}},automated_ammo_count=10,get_inventory_size=function() return 1 end}
prototypes={item={['firearm-magazine']={name='firearm-magazine',type='ammo',order='a',ammo_category={name='bullet'},stack_size=200},
    coal={name='coal',fuel_value=4000000,fuel_category='chemical',stack_size=50},explosives={name='explosives',stack_size=50}},
  entity={['gun-turret']={name='gun-turret',type='ammo-turret'},['stone-furnace']={name='stone-furnace',type='furnace'},
    ['big-worm-turret']={name='big-worm-turret',type='turret',attack_parameters={range=38}},
    ['biter-spawner']={name='biter-spawner',type='unit-spawner',result_units={{unit='small-biter'}}},['small-biter']={vision_distance=30}},
  recipe={}}
prototypes.get_item_filtered=function(f)
  local out={}
  for name,it in pairs(prototypes.item) do if it.type==f[1].type then out[name]=it end end
  return out
end
prototypes.get_entity_filtered=function(f)
  local out={}
  for name,e in pairs(prototypes.entity) do if e.type==f[1].type then out[name]=e end end
  return out
end
local function turret(x,y,items)
  local e={valid=true,name='gun-turret',type='ammo-turret',position={x=x,y=y},force=force,unit_number=#ents+1000,prototype=gun,surface=surface}
  local i=inv(items or {})
  e.get_inventory=function(id) eq(id,defines.inventory.turret_ammo); return i end
  ents[#ents+1]=e
  return e
end
local function furnace(x,y)
  local e={valid=true,name='stone-furnace',type='furnace',position={x=x,y=y},force=force,unit_number=#ents+1000,prototype={crafting_categories={smelting=true}},surface=surface}
  local f,src=inv({coal=0}),inv({})
  e.get_fuel_inventory=function() return f end
  e.get_inventory=function(id) if id==defines.inventory.fuel then return f elseif id==defines.inventory.furnace_source then return src end return inv({}) end
  e.get_recipe=function() return nil end
  ents[#ents+1]=e
  return e
end
local function foe(name,type,x,y) local e={valid=true,name=name,type=type,position={x=x,y=y},force=enemy,surface=surface}; ents[#ents+1]=e; return e end
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy=enemy},
  get_player=function(i) if type(i)=='string' then return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
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
runtime.operator.bot_create('haiku'); runtime.operator.bot_create('grok')
local haiku,grok=as('haiku'),as('grok')
local function body(name) return runtime.lookup(runtime.bots.index_of(name)).character end
local function index(name) return runtime.bots.index_of(name) end
local function active(name) return storage.agent_harness.active[index(name)] end
local function last(name) return storage.agent_harness.last[index(name)] end
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
body('haiku').position={x=0,y=0}; body('grok').position={x=0,y=0}
body('haiku').main.items['firearm-magazine']=500
body('grok').main.items.coal=200

-- 1a. rearm surface=true: the turret in the big worm's range and the one 30 tiles from a spawner are left out at the
-- call, named; the clusters, the tour and its time are the other two.
foe('big-worm-turret','turret',120,0)
foe('biter-spawner','unit-spawner',0,100)
local t1=turret(20,0); turret(100,0); local t3=turret(-60,0); turret(0,70)
local r=haiku('rearm',{surface=true,below=5})
eq(r.places,2)
eq(#r.left_out,2)
eq(r.left_out[1],'gun-turret (100,0) is inside big-worm-turret (120,0) range 38 (20.0 tiles from it)')
eq(r.left_out[2],"gun-turret (0,70) is within 40 tiles of biter-spawner (0,100), its units' reach (30.0 tiles from it)")
eq(r.left_out_more,nil)
eq(r.left_out_note,'left out of the walk: inside the enemy reach the map shows (unsafe_goal: true walks there too)')
eq(#r.clusters,2); eq(r.clusters[1],'1 turret around (20,0), 20 tiles from you, holding 0 rounds')
eq(active('haiku').targets[1].entity,t1); eq(active('haiku').targets[2].entity,t3); eq(#active('haiku').targets,2)
has(r.ticks_note,'through 2 turrets')
eq(r.avoid_enemies,'worms (range + 4), spawners (40 tiles + 4) and areas under attack now (24 tiles + 4)')
-- The tour's last says them too.
haiku('stop')
eq(last('haiku').left_out[1],'gun-turret (100,0) is inside big-worm-turret (120,0) range 38 (20.0 tiles from it)'); eq(last('haiku').left_out_count,2)
-- unsafe_goal: every turret; avoid_enemies false: no check.
r=haiku('rearm',{surface=true,below=5,unsafe_goal=true})
eq(r.places,4); eq(r.left_out,nil)
r=haiku('rearm',{surface=true,below=5,avoid_enemies=false})
eq(r.places,4); eq(r.left_out,nil); eq(r.avoid_enemies,nil)
-- Every turret there inside a reach: refused, naming it; the tour running goes on.
local running=active('haiku')
fails(function() assert(runtime.dispatch{action='rearm',args={area={left_top={x=90,y=-10},right_bottom={x=110,y=10}},below=5},bot='haiku'}) end,
  'every turret under 5 rounds of the ammo each holds there lies in enemy reach the map shows: gun-turret (100,0) is inside big-worm-turret (120,0) range 38 (20.0 tiles from it) [1 held by a worm or spawner (it stays: unsafe_goal: true goes anyway)]: unsafe_goal: true to go anyway, avoid_enemies: false for no check')
eq(active('haiku'),running,'the refusal stops nothing')
haiku('stop')
-- An area under attack now (threat.lua's incident, last hit within 30 s) counts as well.
storage.agent_harness.damage={['nauvis:0,-1']={id=1548,at={x=-58,y=-4},first=tick,last=tick,hits=3,damage=90,surface='nauvis',size=2,kinds={['small-biter']=2}}}
r=haiku('rearm',{surface=true,below=5})
eq(r.places,1); eq(#r.left_out,3); eq(r.left_out[2],'gun-turret (-60,0) is within 24 tiles of attack #1548 at (-58,-4), an area under attack now (last hit 0s ago, 2 attackers seen) (4.5 tiles from it); it clears in about 30 s (tick 1800) unless hit again (an area counts as under attack 30 s after its last hit) [1 threat holds it: attack #1548 at (-58,-4), 4.5 tiles from it: our entities under attack now (last hit 0s ago by 2 small-biter); every one moves (unsafe_goal: "moving" goes on)]')
haiku('stop')
-- (d17 batch35 A3, Haiku) unsafe_goal "moving": the turret only the attack holds stays in the tour, named in through;
-- those the worm and the spawner hold are left out
r=haiku('rearm',{surface=true,below=5,unsafe_goal='moving'})
eq(#r.left_out,2); assert(r.left_out[1]:find('big-worm-turret',1,true),r.left_out[1]); assert(r.left_out[2]:find('biter-spawner',1,true),r.left_out[2])
eq(#r.through,1); assert(r.through[1]:find('gun-turret (-60,0) is within 24 tiles of attack #1548',1,true),r.through[1])
assert(r.through[1]:find('every one moves',1,true),r.through[1]); eq(r.places,2)
storage.agent_harness.damage={}
haiku('stop')

-- 1b. refuel and feed tours (stock.lua start_tour): the burner in the worm's range left out, named.
local f1=furnace(10,0); furnace(110,4)
r=grok('refuel',{radius=200,fuel='coal',count=10})
eq(r.places,1); eq(active('grok').targets[1].entity,f1)
eq(r.left_out[1],'stone-furnace (110,4) is inside big-worm-turret (120,0) range 38 (10.8 tiles from it)')
r=grok('feed',{radius=200,fuel='coal',fuel_count=10})
eq(r.places,1); eq(r.left_out[1],'stone-furnace (110,4) is inside big-worm-turret (120,0) range 38 (10.8 tiles from it)')
-- Only that burner in the radius: refused.
grok('stop')
body('grok').position={x=112,y=10}
fails(function() grok('refuel',{radius=8,fuel='coal',count=10}) end,
  'every place of this tour lies in enemy reach the map shows: stone-furnace (110,4) is inside big-worm-turret (120,0) range 38 (10.8 tiles from it) [1 held by a worm or spawner (it stays: unsafe_goal: true goes anyway)]: unsafe_goal: true to go anyway')
body('grok').position={x=0,y=0}

-- 1c. recover dry_run (Haiku, 03:58: "recover needs a dry_run so I can see the corpse's danger before walking"): each
-- corpse, how far, what it holds, whether recover walks to it, and the danger the map shows round it. A read: the
-- tour running goes on.
local T=tick
local function corpse(x,y,items,died)
  local k={valid=true,name='character-corpse',type='character-corpse',position={x=x,y=y},surface=surface,force={name='neutral'},
    character_corpse_tick_of_death=died,character_corpse_player_index=65536}
  local i=inv(items)
  k.get_inventory=function(id) eq(id,defines.inventory.character_corpse); return i end
  ents[#ents+1]=k
  return k
end
local k1=corpse(110,0,{explosives=50,['firearm-magazine']=19},T)
corpse(-30,0,{coal=3},T-100)
storage.agent_harness.bots.by_name.haiku.corpses={{surface='nauvis',position={x=110,y=0},tick=T},{surface='nauvis',position={x=-30,y=0},tick=T-100}}
storage.agent_harness.damage={['nauvis:3,0']={id=1687,at={x=112,y=2},first=tick-120,last=tick-60,hits=5,damage=274,surface='nauvis',size=1,kinds={['big-worm-turret']=1}}}
haiku('rearm',{surface=true,below=5,unsafe_goal=true}); local tour=active('haiku')
eq(runtime.read_call('recover',{dry_run=true}),true); eq(runtime.read_call('recover',{}),false); eq(runtime.read_call('status',nil),true)
r=haiku('recover',{dry_run=true})
eq(active('haiku'),tour,'a read: the tour goes on')
eq(r.dry_run,true); eq(#r.corpses,2)
local c=r.corpses[1]
eq(c.distance,110); eq(c.items,69); eq(c.holds,'explosives*50, firearm-magazine*19'); eq(c.died,'0m00s ago')
has(c.walk,'left out by recover: the corpse (110,0) is inside big-worm-turret (120,0) range 38 (10.0 tiles from it) [2 threats hold it: big-worm-turret at (120,0), 10.0 tiles from it: standing (range 38); attack #1687 at (112,2), 2.8 tiles from it: our entities under attack now (last hit 1s ago by 1 big-worm-turret)]; the nearest safe spot toward it: (')
eq(c.danger[1],'big-worm-turret (120,0): 10.0 tiles from it, range 38: the corpse lies inside it')
eq(c.danger[2],'attack #1687 at (112,2): 2.8 tiles from it, 1 attacker seen (1 big-worm-turret), last hit 1s ago (under attack now)')
eq(#c.danger,2); eq(c.nests[1],'1 big-worm-turret around (120,0)')
c=r.corpses[2]
eq(c.walk,'recover walks to it: it lies outside the enemy reach the map shows'); eq(c.danger,'none the map shows'); eq(c.died,'0m01s ago')
eq(r.avoid_enemies,'worms (range + 4), spawners (40 tiles + 4) and areas under attack now (24 tiles + 4)')
has(r.danger_note,'worms whose range comes within 16 tiles of it')
-- A spawner within 40 + 16 tiles of a corpse: named with how far outside its units' reach the corpse lies.
local k3=corpse(0,150,{stone=1},T-200)
storage.agent_harness.bots.by_name.haiku.corpses[3]={surface='nauvis',position={x=0,y=150},tick=T-200}
r=haiku('recover',{dry_run=true})
eq(r.corpses[3].danger[1],"biter-spawner (0,100): 50.0 tiles from it, its units come 40 tiles: 10.0 tiles outside it")
k3.valid=false; storage.agent_harness.bots.by_name.haiku.corpses[3]=nil
-- unsafe_goal: walked to, named; avoid_enemies false: no check, the danger still listed.
r=haiku('recover',{dry_run=true,unsafe_goal=true})
eq(r.corpses[1].walk,'recover walks to it (unsafe_goal): the corpse (110,0) is inside big-worm-turret (120,0) range 38 (10.0 tiles from it) [2 threats hold it: big-worm-turret at (120,0), 10.0 tiles from it: standing (range 38); attack #1687 at (112,2), 2.8 tiles from it: our entities under attack now (last hit 1s ago by 1 big-worm-turret)]')
r=haiku('recover',{dry_run=true,avoid_enemies=false})
eq(r.corpses[1].walk,'recover walks to it (avoid_enemies false: no check)'); eq(r.avoid_enemies,'false: no check')
eq(r.corpses[1].danger[1],'big-worm-turret (120,0): 10.0 tiles from it, range 38: the corpse lies inside it')
fails(function() haiku('recover',{dry_run='yes'}) end,'dry_run must be true or false')
-- The walk itself: with unsafe_goal the tour keeps unsafe_goal, so its leg check walks to the corpse the call let in.
r=haiku('recover',{unsafe_goal=true})
eq(r.places,2); eq(active('haiku').unsafe_goal,true); eq(active('haiku').targets[1].entity.position.x,-30)
haiku('stop')
k1.valid=false
storage.agent_harness.damage={}

-- 2. A pole's death that cuts power (Opus, shift14: a small pole at (78.5,-182.5) cut 20 drills and the uranium line
-- twice, found only by tracing): the alert in the next reply's team block and in status alerts; scan rows give each
-- pole's electric network and where its copper wires go.
local made={}
local function pole(x,y,id)
  local e={valid=true,name='small-electric-pole',type='electric-pole',position={x=x,y=y},force=force,surface=surface,unit_number=#ents+5000,
    electric_network_id=id,quality='normal',prototype={get_supply_area_distance=function() return 2.5 end}}
  e.wires={[5]={connections={}},[1]={connections={}},[2]={connections={}}}
  e.get_wire_connector=function(k) return e.wires[k] end
  setmetatable(e,{__index=function(_,k) if k=='electric_network_statistics' then
    return {output_counts=made[e.electric_network_id] or {},get_flow_count=function(f) return (made[e.electric_network_id] or {})[f.name] or 0 end} end end})
  ents[#ents+1]=e
  return e
end
local function wire(a,b) table.insert(a.wires[5].connections,{target={owner=b}}); table.insert(b.wires[5].connections,{target={owner=a}}) end
local g1,g2,g3,g4=pole(-200,-200,57),pole(-193,-200,57),pole(-186,-200,57),pole(-200,-193,57)
wire(g1,g2); wire(g2,g3); wire(g1,g4)
local dr={valid=true,name='electric-mining-drill',type='mining-drill',position={x=-186,y=-198},force=force,surface=surface,unit_number=#ents+5000,
  electric_network_id=57,prototype={electric_energy_source_prototype={}}}
ents[#ents+1]=dr
made[57]={['steam-engine']=2000}
r=haiku('scan',{position={x=-193,y=-200},radius=10})
local rows={}
for _,row in ipairs(r.entities) do rows[row.position.x..','..row.position.y]=row end
eq(rows['-200,-200'].network,57); eq(rows['-200,-200'].wires,'(-193,-200) (-200,-193)')
eq(rows['-193,-200'].wires,'(-200,-200) (-186,-200)'); eq(rows['-186,-198'].network,nil)
runtime.on_event{name=defines.events.on_entity_died,tick=tick,entity=g2,cause={valid=true,name='big-biter',force=enemy,type='unit',position={x=-190,y=-205}},force=enemy}
g2.valid=false
g1.wires[5].connections={{target={owner=g4}}}; g3.wires[5].connections={}
g3.electric_network_id=212; dr.electric_network_id=212
advance(340)
local alerts=haiku('clock',{}).team.alerts
local line
for _,a in ipairs(alerts) do if a:find('power cut',1,true) then line=a end end
eq(line,'power cut #1: small-electric-pole (-193,-200) destroyed by big-biter 5s ago: split electric network #57 in 2: #57 had power at tick 332 (120 kW); #212 had no power at tick 332 (1 pole, around (-186,-200)): 1 electric-mining-drill; no ghost of the pole there; the missing link: small-electric-pole (-193,-200) (nothing there), between small-electric-pole (-200,-200) on #57 now and small-electric-pole (-186,-200) on #212 now')
-- Once: the next reply has it no more; status alerts lists it.
local again=haiku('clock',{}).team
for _,a in ipairs(again and again.alerts or {}) do assert(not a:find('power cut',1,true),'told once') end
eq(haiku('status',{alerts=true,brief=true}).alerts.power_cuts[1],line)
local told
for _,a in ipairs(grok('clock',{}).team.alerts) do if a:find('power cut #1',1,true) then told=true end end
eq(told,true,'every agent is told')

-- (d17 batch22 C2, Haiku) rearm before it walks: the magazines the stops need against what you carry; a tour that
-- cannot finish refused unless partial: true, saying how many stops it completes
do
  haiku('stop')
  storage.agent_harness.damage={}
  body('haiku').main.items['firearm-magazine']=12
  fails(function() assert(runtime.dispatch{action='rearm',args={surface=true,below=10,avoid_enemies=false},bot='haiku'}) end,
    'not walked: the 4 stops need firearm-magazine 40 (you carry 12) to reach 10 each; what you carry completes 1 of them in the tour\'s order')
  local part=haiku('rearm',{surface=true,below=10,avoid_enemies=false,partial=true})
  eq(part.partial,'partial: 1 of 4 stops get their full count with what you carry')
  haiku('stop')
  local plan=haiku('rearm',{surface=true,below=10,avoid_enemies=false,dry_run=true})
  eq(plan.completes,1)
  body('haiku').main.items['firearm-magazine']=500
end
print('round2120a: ok')
