-- Run from vendor/factorio-harness: lua tests/d32_batch402.lua
-- UV2: the six item-prototype gaps in the batch401 queue audit.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
  on_built_entity=15,on_player_mined_entity=16,on_robot_mined_entity=17,on_player_fast_transferred=18,on_gui_opened=19,on_gui_closed=20},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surfaces={}
local function character(surface,pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+#surfaces,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
local function new_surface(name,index,extra)
  local s={name=name,index=index,valid=true}
  for k,v in pairs(extra) do s[k]=v end
  s.find_non_colliding_position=function(_,origin) return origin end
  s.create_entity=function(args) if args.name=='character' then return character(s,args.position) end return {valid=true,name=args.name,position=args.position} end
  s.can_place_entity=function() return true end
  s.find_entities_filtered=function() return {} end
  s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
  surfaces[name]=s; surfaces[index]=s
  return s
end
local nauvis=new_surface('nauvis',1,{planet={name='nauvis'}})
local vulcanus=new_surface('vulcanus',2,{planet={name='vulcanus'}})
new_surface('platform-1',3,{platform={name='Peregrine'}})
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=nauvis,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character(nauvis,{x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=nauvis,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')

prototypes={item={['iron-ore']={}},fluid={water={}},quality={normal={}}}
local stats={get_input_count=function() return 0 end,get_output_count=function() return 0 end,get_flow_count=function() return 0 end}
force.get_item_production_statistics=function() return stats end
defines.flow_precision_index.ten_minutes=2
game.surfaces=surfaces
prototypes.item.coal={}
prototypes.quality.rare={}
local function has(s,part) assert(tostring(s):find(part,1,true),tostring(s)..' lacks '..part) end
local function refused(fn,...)
  local ok,err=pcall(fn)
  assert(not ok,'expected refusal')
  for _,part in ipairs({...}) do has(err,part) end
  return tostring(err)
end
local function copy(t)
  if type(t)~='table' then return t end
  local out={}; for k,v in pairs(t) do out[k]=copy(v) end; return out
end
local function call(action,args) return runtime.dispatch{action=action,args=args,player=1} end
local function cases(name)
  local pos={x=0,y=0}
  return {
    {'feed',{items={'coal',name}},'items[2]'},
    {'feed',{item=name},'item'},
    {'transfer',{pick='first_with_stock',direction='to_player',positions={pos},items={'coal',name}},'items[2]'},
    {'collect',{pick='first_with_stock',positions={pos},items={'coal',name}},'items[2]'},
    {'transfer',{position=pos,direction='to_entity',items={[name]=1}},'items.'..name},
    {'transfer',{steps={{take={pos},item='coal'},{give={pos},item=name}}},'steps[2].item'},
    -- Other forms accepted by the same execution parsers.
    {'feed',{item='coal',items={name}},'items[1]'},
    {'transfer',{pick='most_stock',direction='to_player',positions={pos},items={[name]=3}},'items.'..name},
    {'collect',{pick='most_stock',positions={pos},items={[name]=3}},'items.'..name},
    {'collect',{pick='first_with_stock',positions={pos},items=name},'items'},
    {'collect',{pick='first_with_stock',positions={pos},item=name},'item'},
    {'transfer',{pick='first_with_stock',direction='to_player',positions={pos},item=name},'item'},
  }
end
local scheduler=require('scheduler')(runtime.scheduler_api)
local calls=0
local uptime=runtime.uptime.handler
runtime.uptime.handler=function(...) calls=calls+1; return uptime(...) end
for _,name in ipairs({'water','batch402-missing-item'}) do
  local why=name=='water' and 'fluid prototype' or 'unknown item name'
  for _,case in ipairs(cases(name)) do
    local action,args,field=table.unpack(case)
    local detail=field..': '..name..' is not an item ('..why..')'
    -- Shared execution parser emits the identical argument and reason.
    refused(function() runtime.scheduler_api.handlers[action](nick,copy(args)) end,detail)
    for _,dry in ipairs({true,false}) do
      refused(function() call('queue_submit',{dry_run=dry,mode='replace',steps={
        {action='uptime',args={items={'coal'},seconds=300}},
        {action=action,label='prototype-check',args=copy(args)}}}) end,
        'steps[2] ('..action..', label "prototype-check"): args: '..detail)
      for i=1,3 do game.tick=game.tick+1; scheduler.tick() end
      eq(calls,0)
      local q=storage.agent_harness.queues and storage.agent_harness.queues[1]
      if q then eq(q.current,nil); eq(#q.pending,0); eq(#q.history,0) end
      eq(storage.agent_harness.uptime and storage.agent_harness.uptime[1],nil)
    end
  end
end
-- Every valid replacement passes a real dry run. No execution parser mutates caller arguments in preflight.
for _,case in ipairs(cases('iron-ore')) do
  local action,args=case[1],case[2]
  local before_item,before_items=args.item,args.items
  local r=call('queue_submit',{dry_run=true,steps={{action=action,args=args}}})
  eq(r.dry_run,true); eq(r.queued,false); eq(r.steps,1)
  eq(args.item,before_item); eq(args.items,before_items)
end
-- Normalization and counts stay as execution used them.
local a={item='coal',items={'iron-ore','coal'}}
local items=runtime.feed_items(a)
eq(#items,2); eq(items[1],'coal'); eq(items[2],'iron-ore'); eq(a.item,'coal')
local names,counts=runtime.pick_items{item='coal',items={['iron-ore']=3,coal=5}}
eq(table.concat(names,','),'coal,coal,iron-ore'); eq(counts.coal,5); eq(counts['iron-ore'],3)
eq(runtime.transfer_item_counts{coal=2,['iron-ore']=3},2)
local places,legs,groups=runtime.transferchain.plan{steps={
  {take={{x=0,y=0}},item='coal',count=3},{give={{x=1,y=0}},item='coal',split='even'}}}
eq(#places,2); eq(#legs,2); eq(groups[1].left,3); eq(groups[2].split,'even')
-- A valid queued pick executes through the scheduler; with no source entity it moves zero items.
call('queue_submit',{steps={{action='collect',args={pick='first_with_stock',positions={{x=0,y=0}},items={'coal'}}}}})
game.tick=game.tick+1; scheduler.tick()
local q=storage.agent_harness.queues[1]
eq(#q.history,1); eq(q.history[1].ok,true); eq(q.history[1].result.moved,0); eq(q.history[1].result.picked,'none')
-- Guard steps receive the same indexed error before submission.
refused(function() call('queue_submit',{dry_run=true,steps={{action='wait_ticks',args={ticks=60}}},
  guards={{when={['until']='tick_at_least',tick=600},steps={{action='feed',args={items={'water'}}}}}}}) end,
  'guards[1]: steps[1]','items[1]: water is not an item (fluid prototype)')
print('d32_batch402: six audit rows, shared dry/live errors, valid forms, atomic refusal and execution: ok')
