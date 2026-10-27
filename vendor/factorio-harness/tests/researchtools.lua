-- Run from repository root: lua tests/researchtools.lua
-- The science study's tools (docs/studies/2026-10-13-science.md in the pog repo): research remove/cancel and move,
-- research_options (open technologies by whether the factory makes their packs), the stalled-head alert in every
-- agent's team research lines, and where_is (where an item is stored, nearest first). Fake engine as tests/research.lua.
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
local astra,sol,grok=as('astra'),as('sol'),as('grok')
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')

-- 1. remove (cancel) and move, as the research GUI does
grok('research',{research_queue={'mining-productivity-3','physical-projectile-damage-4','physical-projectile-damage-5','weapon-shooting-speed-3','laser-turret'}})
eq(names(force.research_queue),'mining-productivity-3,physical-projectile-damage-4,physical-projectile-damage-5,weapon-shooting-speed-3,laser-turret')
local r=grok('research',{cancel='mining-productivity-3'}) -- shift 5, 07:01: "unknown argument cancel"
eq(names(r.queue),'physical-projectile-damage-4,physical-projectile-damage-5,weapon-shooting-speed-3,laser-turret'); eq(r.removed[1],'mining-productivity-3'); eq(r.also_removed,nil)
r=grok('research',{remove='physical-projectile-damage-4'}) -- damage-5 needs it: it goes too
eq(names(r.queue),'weapon-shooting-speed-3,laser-turret'); eq(r.also_removed[1],'physical-projectile-damage-5')
fails(function() grok('research',{remove='toolbelt'}) end,'toolbelt is not in the research queue')
fails(function() grok('research',{remove='laser-turret',technology='toolbelt'}) end,'remove and move go without')
grok('research',{research_queue={'physical-projectile-damage-4','physical-projectile-damage-5','laser-turret','toolbelt'}})
r=grok('research',{move='toolbelt',to=1})
eq(names(r.queue),'toolbelt,physical-projectile-damage-4,physical-projectile-damage-5,laser-turret')
r=grok('research',{move='laser-turret',to=2}); eq(names(r.queue),'toolbelt,laser-turret,physical-projectile-damage-4,physical-projectile-damage-5')
fails(function() grok('research',{move='physical-projectile-damage-5',to=1}) end,'physical-projectile-damage-5 needs physical-projectile-damage-4 first')
fails(function() grok('research',{move='physical-projectile-damage-4',to=4}) end,'physical-projectile-damage-5 needs physical-projectile-damage-4')
fails(function() grok('research',{move='toolbelt',to=9}) end,'to must be 1..4')
eq(names(force.research_queue),'toolbelt,laser-turret,physical-projectile-damage-4,physical-projectile-damage-5') -- refusals change nothing
grok('research',{remove={'toolbelt','laser-turret'}}); eq(names(force.research_queue),'physical-projectile-damage-4,physical-projectile-damage-5')
assert(runtime.dispatch{action='describe',args={},player=1}.actions.research.remove:find('research GUI',1,true))

-- 2. research_options: open technologies by whether every pack was made in the last 10 minutes
local o=astra('research_options',{})
eq(names(o.researchable_now),'electric-energy-distribution-2,toolbelt,advanced-material-processing-2') -- fewest units first
eq(o.waiting_for_packs[1].packs_not_made,'military-science-pack'); eq(o.waiting_for_packs[1].count,3) -- damage-5 waits on damage-4
eq(names(o.waiting_for_packs[1].technologies),'laser-turret,weapon-shooting-speed-3,physical-projectile-damage-4')
eq(o.waiting_for_packs[1].technologies[3].queued,1)
eq(o.waiting_for_packs[2].packs_not_made,'production-science-pack')
eq(o.made_last_10_min['automation-science-pack'],300); eq(o.made_last_10_min['military-science-pack'],0)
for _,e in ipairs(o.researchable_now) do assert(e.name~='planet-discovery-fulgora' and e.name~='steel-processing',e.name) end

-- 3. a stalled head: damage-4 waits on military packs nobody made; after 10 minutes with no progress every agent hears it once
astra('status'); sol('status')
advance(600*30) -- 5 minutes
eq(((astra('status').team or {}).research),nil)
advance(600*36) -- past 10 minutes
local line=has(astra('status').team.research,'research stalled: physical-projectile-damage-4 heads the queue')
assert(line and line:find('military-science-pack',1,true) and line:find('research {remove=',1,true),line)
assert(has(sol('status').team.research,'research stalled'))
eq(((astra('status').team or {}).research),nil) -- once
assert(has(grok('status').team.research,'research stalled')) -- a first reply looks back ten minutes
advance(600*120) -- 20 more minutes: still no repeat inside 30 minutes
eq(((astra('status').team or {}).research),nil)
advance(600*61) -- past 30 minutes: again
assert(has(astra('status').team.research,'research stalled'))
-- progress resets the wait; a head whose packs are made never alerts
force.research_progress=0.05; advance(600)
force.research_progress=0.1; advance(600*70)
eq(((astra('status').team or {}).research),nil)
made['military-science-pack']=50
force.research_progress=0.1; advance(600*70)
eq(((astra('status').team or {}).research),nil)
-- With the science line's lab state (Astra, 12:02: automation named for none made while all 43 labs lacked agricultural
-- science): the pack the labs lack is named, with how many have none, made in 10 min and logistic network stock; a pack
-- none was made of but every lab holds is not.
made['military-science-pack']=0
-- (the science line's own job, which would read this test world's two labs, held off: its line counts as just built)
storage.agent_harness.science_jobs=nil; storage.agent_harness.science_line={player={tick=1e12}}
storage.agent_harness.science_labs={player={tick=game.tick,surface='nauvis',n=43,working=0,lack={['logistic-science-pack']=43}}}
force.logistic_networks={nauvis={{get_item_count=function(n) return n=='logistic-science-pack' and 12 or 0 end}}}
local function refresh_labs() storage.agent_harness.science_labs.player.tick=game.tick end
force.research_progress=0.12; advance(600); refresh_labs()
for _=1,7 do advance(600*10); refresh_labs() end
line=has(astra('status').team.research,'research stalled: physical-projectile-damage-4 heads the queue and has made no progress for')
assert(line:find('its labs lack logistic-science-pack (43 of 43 labs on nauvis have none; '..math.floor(made['logistic-science-pack'] or 0)
  ..' made in the last 10 min; 12 in logistic networks there)',1,true),line)
assert(not line:find('military',1,true),'every lab holds military packs: '..line)
-- Every lab holds every pack: no stall alert, whatever was made.
storage.agent_harness.science_labs.player.lack={}
force.research_progress=0.14; advance(600); refresh_labs()
for _=1,13 do advance(600*10); refresh_labs() end
eq(((astra('status').team or {}).research),nil)
storage.agent_harness.science_labs=nil; storage.agent_harness.science_line=nil; force.logistic_networks=nil

-- 4. where_is: nearest first from the caller, belts and inserter hands as totals, teammates by name
runtime.bots.lookup(runtime.bots.index_of('sol')).character.insert{name='automation-science-pack',count=7}
local w=astra('where_is',{item='automation-science-pack'})
eq(w.total,1118+40+4+2+14+7+1); eq(w.by_kind.chest,1158); eq(w.by_kind.lab,4); eq(w.by_kind.belts,14) -- 2 belts x 2 lines
eq(w.by_kind.inserter_hands,1)
eq(w.by_kind.characters,7)
-- (d18 batch39 D2, Opus) the most held first by default, each kind's count and places in kinds_line
eq(w.places[1].entity,'steel-chest'); eq(w.places[1].count,1118); eq(w.places[2].entity,'wooden-chest'); eq(w.places[2].count,40)
eq(w.kinds_line,'1186 automation-science-pack: 1158 chest (2 places), 14 belts, 7 characters (1 place), 4 lab (1 place), 2 machine (1 place), 1 inserter hands')
-- sort: "nearest": the caller's nearest first, as before
w=astra('where_is',{item='automation-science-pack',sort='nearest'})
eq(w.places[1].kind,'character'); eq(w.places[1].agent,'sol') -- bots stand at the spawn with astra
eq(w.places[2].entity,'wooden-chest'); eq(w.places[2].count,40)
eq(w.places[#w.places].entity,'steel-chest'); eq(w.places[#w.places].count,1118)
for k=2,#w.places do assert(w.places[k].distance>=w.places[k-1].distance) end
w=astra('where_is',{item='automation-science-pack',limit=2}); eq(#w.places,2); eq(w.more,3); eq(w.pages,3)
w=astra('where_is',{item='automation-science-pack',limit=2,page=3}); eq(#w.places,1); eq(w.more,nil); eq(w.page,3)
fails(function() astra('where_is',{item='automation-science-pack',sort='random'}) end,'sort is "largest" (default) or "nearest"')
eq(astra('where_is',{item='military-science-pack'}).places[1].entity,'passive-provider-chest')
local plates=astra('where_is',{item='iron-plate',surface='nauvis'}); eq(plates.by_kind.chest,5) -- (the bots' kits hold more)
eq(plates.by_kind.pod,16)
local pod
for _,pl in ipairs(plates.places) do if pl.kind=='pod' then pod=pl end end
eq(pod.entity,'cargo-pod-container'); eq(pod.count,16); eq(pod.position.x,-10.5)
fails(function() astra('where_is',{item='unobtainium'}) end,'unknown item unobtainium')
fails(function() astra('where_is',{}) end,'item is required')
fails(function() astra('where_is',{item='iron-plate',surface='vulcanus'}) end,'unknown surface vulcanus')
-- reads never stop the character
astra('walk',{direction='east',ticks=100}); advance(1)
fails(function() astra('where_is',{item='nope'}) end,'unknown item')
eq(astra('status').active.kind,'walk')
print('researchtools: ok')
