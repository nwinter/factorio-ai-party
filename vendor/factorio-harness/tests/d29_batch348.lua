-- Run from repository root: lua tests/d29_batch348.lua
-- (d29 batch348 CS, Sol #2758) a queued circuit_set is checked at submit (and in queue_submit's dry run) with the values
-- the live call parses (circuits.lua check_args, plan_set's own parsers), and networks takes "red+green", the text
-- inspect shows, as both. Fake engine as tests/researchtools.lua.
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
prototypes.virtual_signal={['signal-C']={},['signal-N']={},['signal-P']={},['signal-A']={}}
local C=runtime.circuits
local function refused(fn,text) local ok,err=pcall(fn); assert(not ok,'not refused: '..text); assert(tostring(err):find(text,1,true),tostring(err)..'\n  lacks: '..text) end
local clock={decider={conditions={{signal='signal-C',comparator='<',value=40,first_networks='red+green'}},outputs={{signal='signal-C',copy_input=true,networks='red+green'}}}}

-- 1. networks: "red+green" (inspect's text) is both, as are "green+red", spaces and case; others refused naming it
C.check_args(clock)
for _,t in ipairs({'red+green','green+red','Red + Green','both','red','green'}) do
  C.check_args{decider={conditions={{signal='signal-C',comparator='<',value=1,first_networks=t}},outputs={{signal='signal-C',copy_input=true}}}}
end
refused(function() C.check_args{decider={conditions={{signal='signal-C',comparator='<',value=1,first_networks='red,green'}},outputs={{signal='signal-C',copy_input=true}}}} end,
  'decider.conditions 1.first_networks is red, green or both (red+green, as inspect shows it, is both)')
refused(function() C.check_args{arithmetic={first='signal-A',operation='*',second=2,output='signal-A',second_networks='blue'}} end,'arithmetic.second_networks is red, green or both')
refused(function() C.check_args{decider={conditions={{signal='signal-C',comparator='<',value=1}},outputs={{signal='signal-C',copy_input=true,networks='all'}}}} end,'decider.outputs 1.networks is red, green or both')

-- 2. each field's values, as the live call parses them
refused(function() C.check_args{enable=false} end,'enable: false is two things')
refused(function() C.check_args{switch_off=1} end,'switch_off must be true')
refused(function() C.check_args{remove_condition='yes'} end,'remove_condition must be true')
refused(function() C.check_args{switch_off=true,remove_condition=true} end,'one at a time')
refused(function() C.check_args{clear=false} end,'clear must be true')
refused(function() C.check_args{enable={signal='no-such-signal',comparator='<',value=1}} end,'unknown signal no-such-signal')
refused(function() C.check_args{logistic={signal='signal-A',comparator='?',value=1}} end,'logistic')
C.check_args{logistic=false}
refused(function() C.check_args{read={contents='yes'}} end,'read.contents must be boolean')
refused(function() C.check_args{settings=5} end,'settings is {name: value}')
refused(function() C.check_args{on=1} end,'on must be boolean')
refused(function() C.check_args{signals={{signal='signal-A'}}} end,'signals 1 needs signal and count')
refused(function() C.check_args{arithmetic={first='signal-A',operation='%%',second=1,output='signal-A'}} end,'arithmetic.operation is one of')
refused(function() C.check_args{decider={conditions={{signal='signal-C',comparator='<',value=1},{signal='signal-P',comparator='>',value=0}},outputs={{signal='signal-N',constant=1}}}} end,
  'decider.conditions 2: say how it joins the row before')
refused(function() C.check_args{selector={operation='sort'}} end,'selector.operation is one of')

-- 3. queue_submit: its dry run refuses a step live would refuse (Sol's clock draft with "red+green" passed before and
-- failed live at its third step); a live submit is refused the same, before any step runs
local bad={decider={conditions={{signal='signal-C',comparator='<',value=40,first_networks='red,green'}},outputs={{signal='signal-C',copy_input=true}}}}
local function step(args) local a={position={x=5,y=5}} for k,v in pairs(args) do a[k]=v end; return {action='circuit_set',args=a} end
refused(function() astra('queue_submit',{steps={step({logistic=false}),step(bad)},dry_run=true}) end,'first_networks is red, green or both')
refused(function() astra('queue_submit',{steps={step({logistic=false}),step(bad)}}) end,'first_networks is red, green or both')
-- the red+green clock passes the dry run, and live parses it the same (both)
local r=astra('queue_submit',{steps={step(clock)},dry_run=true})
assert(r.dry_run and r.steps==1,'dry run')
print('d29_batch348 CS: ok')
