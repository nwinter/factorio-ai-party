-- Run from repository root: lua tests/d29_batch336.lua
-- (d29 batch336 FL, batch321 section 4: the facts the agents named as missing) technologies: effects as the research
-- screen lists them, a leveled technology's next level, the time each would take at the labs' measured rate and its
-- packs against the stock where the labs are. Fake engine as tests/researchtools.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
local function names(list) local out={} for i,x in ipairs(list) do out[i]=type(x)=='table' and x.name or x end return table.concat(out,',') end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
    on_research_finished=40,on_research_queued=41},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1,ten_minutes=2}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={['automation-science-pack']={},['military-science-pack']={},['iron-plate']={}}}
-- Packs made per name in the last 10 minutes: red, green and blue; no military, no production.
local made={['automation-science-pack']=300,['logistic-science-pack']=200,['chemical-science-pack']=40}
local stats={get_flow_count=function(a) assert(a.category=='input' and a.count==true); return made[a.name] or 0 end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,get_item_production_statistics=function() return stats end}
local surface={name='nauvis',index=1}
local red,green,blue={name='automation-science-pack',amount=1},{name='logistic-science-pack',amount=1},{name='chemical-science-pack',amount=1}
local mil,prod={name='military-science-pack',amount=1},{name='production-science-pack',amount=1}
local techs={}
local function tech(name,count,ingredients,pre)
  local prereq={}
  for _,n in ipairs(pre or {}) do prereq[n]=techs[n] end
  techs[name]={name=name,valid=true,force=force,enabled=true,researched=false,prerequisites=prereq,research_unit_count=count,research_unit_energy=1800,
    research_unit_ingredients=ingredients,saved_progress=0,prototype={effects={}}}
  return techs[name]
end
tech('mining-productivity-3',500,{red,green,blue,prod})
tech('physical-projectile-damage-4',400,{red,green,blue,mil})
tech('physical-projectile-damage-5',500,{red,green,blue,mil},{'physical-projectile-damage-4'})
tech('weapon-shooting-speed-3',300,{red,green,blue,mil})
tech('laser-turret',150,{red,green,mil})
tech('advanced-material-processing-2',250,{red,green,blue})
tech('electric-energy-distribution-2',100,{red,green,blue})
tech('toolbelt',150,{red,green})
local done=tech('steel-processing',50,{red}); done.researched=true
tech('planet-discovery-fulgora',1000,{red,green}); techs['planet-discovery-fulgora'].prototype.research_trigger={type='craft-item'}
force.technologies=techs
force.research_progress=0
local queue={}
setmetatable(force,{__index=function(_,k) if k=='research_queue' then return queue end end,
  __newindex=function(t,k,v)
    if k~='research_queue' then return rawset(t,k,v) end
    queue={}
    for i,x in ipairs(v) do queue[i]=type(x)=='string' and techs[x] or x end
    rawset(t,'current_research',queue[1])
  end})
force.add_research=function(t)
  for _,x in ipairs(queue) do if x==t then return false end end
  queue[#queue+1]=t; rawset(force,'current_research',queue[1]); return true
end
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
  c.get_item_count=function(n) return items[(type(n)=='table' and (n.quality or 'normal')=='normal' and n.name or n)] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
-- The map for where_is: chests, labs, a machine, belts, an inserter hand.
local function holder(type_,name,x,y,counts)
  return {valid=true,type=type_,name=name,force=force,surface=surface,position={x=x,y=y},
    get_item_count=function(item) return counts[(type(item)=='table' and (item.quality or 'normal')=='normal' and item.name or item)] or 0 end}
end
local function belt(n)
  return {valid=true,type='transport-belt',name='transport-belt',force=force,position={x=0,y=0},
    get_max_transport_line_index=function() return 2 end,
    get_transport_line=function(i) return {get_item_count=function(item) return (type(item)=='table' and (item.quality or 'normal')=='normal' and item.name or item)=='automation-science-pack' and n or 0 end} end}
end
local map={
  holder('container','steel-chest',100,0,{['automation-science-pack']=1118}),
  holder('container','wooden-chest',10,0,{['automation-science-pack']=40,['iron-plate']=5}),
  holder('lab','lab',30,0,{['automation-science-pack']=4}),
  holder('lab','lab',33,0,{}),
  holder('assembling-machine','assembling-machine-2',20,0,{['automation-science-pack']=2}),
  holder('logistic-container','passive-provider-chest',-50,0,{['military-science-pack']=12}),
  -- A landed cargo pod's container (operator 09:04: a stopped platform's trash on Gleba, no landing pad).
  holder('temporary-container','cargo-pod-container',-10.5,-5.5,{['iron-plate']=16}),
  belt(3),belt(4),
  {valid=true,type='inserter',name='inserter',force=force,position={x=1,y=1},held_stack={valid_for_read=true,name='automation-science-pack',count=1}},
}
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function(f)
  if not f or not f.type then return {} end
  local want={}
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end
  local out={}
  for _,e in ipairs(map) do if want[e.type] then out[#out+1]=e end end
  return out
end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,surfaces={nauvis=surface},forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) if n==nil or n=='nauvis' or n==1 then return surface end return nil end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.player or (req.bot==nil and 1 or nil)
    if req.bot then who=runtime.bots.index_of(req.bot) end
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local astra=as('astra')
runtime.operator.bot_create('astra')

-- The labs hold packs; the logistic network holds more.
map[3].get_inventory=function() return {get_item_count=function(n) return n=='automation-science-pack' and 4 or 0 end} end
map[4].get_inventory=function() return {get_item_count=function() return 0 end} end
rawset(force,'logistic_networks',{nauvis={{get_item_count=function(n) return ({['automation-science-pack']=100,['logistic-science-pack']=50})[n] or 0 end}}})
-- A leveled (infinite) technology and a recipe productivity one.
local ppd=tech('physical-projectile-damage-7',2000,{red,green}); ppd.level=8
ppd.prototype={max_level=4294967295,effects={{type='ammo-damage',ammo_category='bullet',modifier=0.4},{type='turret-attack',turret_id='gun-turret',modifier=0.4}}}
local lds=tech('low-density-structure-productivity',1000,{red,green}); lds.level=3
lds.prototype={max_level=4294967295,effects={{type='change-recipe-productivity',recipe='low-density-structure',change=0.1}}}
techs.toolbelt.prototype={effects={{type='character-inventory-slots-bonus',modifier=10}}}
techs['laser-turret'].prototype={effects={{type='unlock-recipe',recipe='laser-turret'}}}
techs['laser-turret'].saved_progress=0.5

-- 1. no rate measured yet: effects and packs, no takes
local r=astra('technologies',{name={'physical-projectile-damage-7','low-density-structure-productivity','toolbelt','laser-turret','steel-processing'}})
local by={} for _,e in ipairs(r.entries) do by[e.name]=e end
eq(table.concat(by['physical-projectile-damage-7'].effects,'; '),'ammo-damage (bullet) +40%; turret-attack (gun-turret) +40%')
eq(by['physical-projectile-damage-7'].next_level,'level 8 adds ammo-damage (bullet) +40%, turret-attack (gun-turret) +40%; 2000 units')
eq(by['low-density-structure-productivity'].effects[1],'low-density-structure productivity +10%')
eq(by['low-density-structure-productivity'].next_level,'level 3 adds low-density-structure productivity +10%; 1000 units')
eq(by.toolbelt.effects[1],'character-inventory-slots-bonus +10'); eq(by.toolbelt.next_level,nil)
eq(by['laser-turret'].effects[1],'laser-turret'); eq(by['laser-turret'].progress,50)
eq(by['laser-turret'].packs_needed,'automation-science-pack 75 (104 where the labs are), logistic-science-pack 75 (50 where the labs are), military-science-pack 75 (0 where the labs are)')
eq(by['laser-turret'].packs_short,'logistic-science-pack 25, military-science-pack 75')
eq(by.toolbelt.takes,nil); assert(r.lab_rate:find('not measured yet',1,true),r.lab_rate)
eq(by['steel-processing'].packs_needed,nil); eq(by['steel-processing'].takes,nil)   -- researched: none
-- 2. the rate the queue measures: toolbelt (150 units x 1800) from 0 to 10% in 3600 ticks = 7.5 work a tick
storage.agent_harness.research_rate={player={}}
for k=0,6 do local l=storage.agent_harness.research_rate.player; l[#l+1]={tick=k*600,name='toolbelt',progress=0.1*k/6,work=150*1800} end
rawset(force,'current_research',techs.toolbelt); force.research_progress=0.1
r=astra('technologies',{name={'toolbelt','laser-turret','physical-projectile-damage-7','planet-discovery-fulgora'}})
by={} for _,e in ipairs(r.entries) do by[e.name]=e end
eq(by.toolbelt.takes,'9m00s')                 -- (1-0.1) x 150 x 1800 / 7.5 = 32400 ticks
eq(by.toolbelt.progress,10)
eq(by['laser-turret'].takes,'5m00s')          -- 0.5 x 150 x 1800 / 7.5 = 18000 ticks
eq(by['physical-projectile-damage-7'].takes,'2h13m') -- 2000 x 1800 / 7.5 = 480000 ticks
eq(by['planet-discovery-fulgora'].takes,nil); eq(by['planet-discovery-fulgora'].packs_needed,nil)  -- a trigger technology
assert(r.lab_rate:find('7.5 research work a tick',1,true),r.lab_rate)
assert(runtime.dispatch{action='describe',args={},player=1}.actions.technologies.returns:find('packs_short',1,true))

-- 3. (FL5) rates {item}: one row a producer, full speed beside what its crafts counter made over the efficiency anchor
do
  local cable={name='copper-cable',energy=0.5,productivity_bonus=0,prototype={maximum_productivity=3},ingredients={{type='item',name='copper-plate',amount=1}},
    products={{type='item',name='copper-cable',amount=2}}}
  local function crafter(x,unit,pf)
    return {valid=true,name='assembling-machine-2',type='assembling-machine',force=force,surface=surface,position={x=x,y=0},unit_number=unit,
      prototype={},crafting_speed=1,productivity_bonus=0,products_finished=pf,status=1,get_recipe=function() return cable end}
  end
  -- 120 crafts/min full speed = 240 cable/min; the first made 900 crafts in 15 min (60/min = 120 cable/min)
  local a,b=crafter(1,901,5000),crafter(4,902,10)
  game.tick=100000; tick=100000
  storage.agent_harness.efficiency={machines={[901]={t1=100000-54000,p1=4100,t0=100000-1000,p0=4990}}}
  local rows,lines=runtime.rates_producers({a,b},'copper-cable')
  eq(#rows,2); eq(rows[1].full_per_min,240); eq(rows[1].measured_per_min,120); eq(rows[1].measured_over,'15m00s')
  eq(rows[2].measured_per_min,nil)
  assert(lines[1]:find('assembling-machine-2 (1,0) copper-cable: made 120/min over the last 15m00s, full speed 240/min',1,true),lines[1])
  assert(lines[2]:find('not counted yet',1,true),lines[2])
  eq(lines[3],'these 2: made 120/min (1 counted) against 480/min at full speed')
  -- only the newer anchor, at least a minute back: used; under a minute: not counted
  storage.agent_harness.efficiency.machines[901]={t0=100000-7200,p0=4880}
  rows=runtime.rates_producers({a},'copper-cable'); eq(rows[1].measured_per_min,120); eq(rows[1].measured_over,'2m00s')  -- 120 crafts in 2 min
  storage.agent_harness.efficiency.machines[901]={t0=100000-600,p0=4990}
  rows=runtime.rates_producers({a},'copper-cable'); eq(rows[1].measured_per_min,nil)
  runtime.PRODUCERS=1
  rows,lines=runtime.rates_producers({a,b},'copper-cable'); eq(#rows,1); assert(lines[2]:find('+1 more producers not read',1,true),lines[2])
  runtime.PRODUCERS=48
end
print('d29_batch336: ok')
