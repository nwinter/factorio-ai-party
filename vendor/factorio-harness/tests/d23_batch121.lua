-- Run from repository root: lua tests/d23_batch121.lua
-- d23 batch121: CD1 (viewer Aurora site:4387, 4406) the chat unread count's lines naming the reader, and tells shown
-- in a team block but not acknowledged, apart from pending ones, in mention_counts and idle_report. Fake engine as tests/tells.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
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
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
-- As control.lua does: a failed request stops its player unless the runtime
-- marked it passive.
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
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sunny',glyph='S',color='#ffcb45'})
local function counts()
  local out={}
  for _,row in ipairs(op('mention_counts',{}).agents) do out[row.name]=row end
  return out
end
local function idle()
  local out={}
  for _,row in ipairs(op('idle_report',{}).agents) do out[row.name]=row end
  return out
end

-- CD1 (site:4387): the unread chat count is every line after the read, to anyone; to_you counts those naming the reader
sol('chat',{}); grok('chat',{})
astra('say',{text='north belt is down'})
astra('say',{text='@sol the silo needs fuel'})
astra('say',{text='grok has the gears'})
local st=sol('status')
eq(st.chat.unread,3); eq(st.chat.to_you,1); eq(st.chat.of_newest,nil)
eq(st.chat.read_with,'chat (chat_ack does not mark chat lines read)')
eq(grok('status').chat.to_you,1) -- named without @: a mention by name
-- chat_ack closes the unanswered @mention but leaves the chat lines unread; a chat read marks them
eq(sol('chat_ack',{seq='all'}).closed,1)
eq(sol('status').chat.unread,3)
eq(idle().sol.unread_chat,3); eq(idle().sol.unread_chat_to_you,1)
sol('chat',{})
eq(sol('status').chat,nil); eq(idle().sol.unread_chat,0); eq(idle().sol.unread_chat_to_you,nil)
-- the count covers the 200 lines the log keeps: of_newest says so once the oldest kept is unread too
for k=1,205 do astra('say',{text='line '..k}) end
st=sol('status'); eq(st.chat.unread,200); eq(st.chat.of_newest,200); eq(st.chat.to_you,0)
sol('chat',{since=0,peek=true}); sol('chat',{limit=100}); sol('chat',{limit=100})
eq(sol('status').chat,nil)

-- CD1 (site:4406): a tell is pending until a team block shows it, then unacknowledged until chat_ack, reply_to or a
-- tells read; mention_counts and idle_report give the two apart, with the oldest unacknowledged one's age
astra('tell',{to='sol',text='plates are in the chest'})
local c=counts().sol
eq(c.tells,1); eq(c.unacked_tells,nil)
eq(idle().sol.unread_tells,1); eq(idle().sol.unacked_tells,0); eq(idle().sol.unacked_oldest_s,nil)
local told=tick
sol('status') -- the team block shows it
advance(600)
grok('tell',{to='sol',text='turret ammo low'})
sol('status')
advance(300)
c=counts().sol
eq(c.tells,nil); eq(c.unacked_tells,2); eq(c.unacked_oldest_tick,told)
local i=idle().sol
eq(i.unread_tells,0); eq(i.unacked_tells,2); eq(i.unacked_oldest_s,15)
-- an fyi tell is never owed an acknowledgement
astra('tell',{to='sol',text='fyi: belt moved',fyi=true}); sol('status')
eq(counts().sol.unacked_tells,2)
eq(sol('chat_ack',{seq='all'}).read,2)
c=counts().sol; eq(c.unacked_tells,nil); eq(c.unacked_oldest_tick,nil)
eq(idle().sol.unacked_tells,0)
print('d23 batch121 CD1: ok')

-- CD2 (site:4404, shift62: Anvil docked 2 h at Vulcanus on item_count copper-plate >= 5000 while its hub asked for copper
-- from Nauvis only): each unmet item wait says where the item can come from at that stop, and "no known source" when
-- nothing can: no request from that planet, nothing made aboard and no machine aboard set to make it.
do
  local saved={defines=defines,prototypes=prototypes,game=game}
  defines={flow_precision_index={ten_minutes=3}}
  prototypes={item={['copper-plate']={},['firearm-magazine']={},['calcite']={}}}
  local planet_made={vulcanus={['copper-plate']=9000},nauvis={['copper-plate']=6000},aquilo={}}
  local aboard_made={['firearm-magazine']=300}
  local vulcanus,nauvis,aquilo={index=3,name='vulcanus'},{index=1,name='nauvis'},{index=5,name='aquilo'}
  local platform_surface={index=9,name='platform-9'}
  game={planets={vulcanus={surface=vulcanus},nauvis={surface=nauvis},aquilo={surface=aquilo}}}
  local stock={vulcanus={['copper-plate']=18000},nauvis={['copper-plate']=12000},aquilo={}}
  local force={logistic_networks={}}
  for k,v in pairs(stock) do force.logistic_networks[k]={{get_item_count=function(n) return v[n] or 0 end}} end
  force.get_item_production_statistics=function(sf)
    local t=sf==platform_surface and aboard_made or planet_made[sf.name]
    return {get_flow_count=function(q) assert(q.category=='input' and q.count); return t[q.name] or 0 end}
  end
  local function filter(name,from,min) return {value={name=name,quality='normal'},import_from={name=from},min=min} end
  local sections={sections_count=2,get_section=function(i)
    return ({{active=true,filters={filter('copper-plate','nauvis',5000),filter('calcite','aquilo',200)}},{active=false,filters={filter('copper-plate','vulcanus',5000)}}})[i] end}
  local wait=function(item,n) return {type='item_count',condition={first_signal={name=item},comparator='≥',constant=n}} end
  local recipe={products={{type='item',name='firearm-magazine',amount=1}}}
  platform_surface.find_entities_filtered=function(f) assert(f.limit==200)
    return {{get_recipe=function() return recipe end},{get_recipe=function() return recipe end},{get_recipe=function() return nil end}} end
  local anvil={name='Anvil',force=force,surface=platform_surface,
    hub={valid=true,get_item_count=function() return 0 end,get_logistic_sections=function() return sections end},
    schedule={records={{station='vulcanus',wait_conditions={wait('copper-plate',5000),wait('firearm-magazine',100)}},
      {station='nauvis',wait_conditions={wait('copper-plate',5000)}},{station='aquilo',wait_conditions={wait('calcite',200)}}}}}
  local spindle={name='Spindle',valid=true,hub={valid=true,get_item_count=function(n) return n=='copper-plate' and 7000 or 0 end},
    schedule={records={{station='vulcanus'},{station='nauvis'}}}}
  force.platforms={anvil,spindle}
  anvil.valid=true
  local N=dofile('mod/agent-harness_0.1.0/launchneed.lua'){elsewhere=function() return 'x',0 end}
  local lines=N.wait_lines(anvil)
  eq(lines[1],'stop 1 (vulcanus) waits for copper-plate >= 5000: the hub holds 0, 5000 short; no known source at vulcanus: the hub asks for it from nauvis only, not from vulcanus, nothing aboard made it over the last 10 min and no machine aboard is set to make it (vulcanus holds 18000 (18000 in its logistic networks, 0 outside them) and made 900 a minute over the last 10 min; it reaches the hub only by a request from vulcanus)')
  eq(lines[2],'stop 1 (vulcanus) waits for firearm-magazine >= 100: the hub holds 0, 100 short; vulcanus holds 0 (0 in its logistic networks, 0 outside them) and made 0 a minute over the last 10 min; sources: the hub has no request for it; made aboard 30 a minute over the last 10 min, 2 machines aboard set to make it')
  eq(lines[3],'stop 2 (nauvis) waits for copper-plate >= 5000: the hub holds 0, 5000 short; nauvis holds 12000 (12000 in its logistic networks, 0 outside them) and made 600 a minute over the last 10 min; sources: the hub asks for it from nauvis; nothing aboard made it over the last 10 min; other platforms stopping at nauvis hold it: Spindle 7000; about 9 min at nauvis\'s rate')
  eq(lines[4],'stop 3 (aquilo) waits for calcite >= 200: the hub holds 0, 200 short; no known source at aquilo: the hub asks for it from aquilo, which holds none and made none over the last 10 min; no other platform stopping there holds it; nothing aboard made it or is set to make it')
  eq(#lines,4)
  defines,prototypes,game=saved.defines,saved.prototypes,saved.game
end
print('d23 batch121 CD2: ok')

-- CD3 (site:4362, shift61: Sonnet read the status line's 11793 "item stacks on the ground" around Gleba's pad as full
-- stacks and asked for about 120 chests; each was one item, and Astra counted eight chests): entities on the ground,
-- the items they hold and the storage slots those fill are labelled apart, and deconstruct {items_on_ground} adds the
-- empty slots of the storage chests that may take them.
do
  local saved={prototypes=prototypes,defines=defines}
  prototypes={item={['iron-plate']={stack_size=100},['iron-ore']={stack_size=50},calcite={stack_size=50}}}
  defines={inventory={chest=1}}
  local G=dofile('mod/agent-harness_0.1.0/ground.lua'){state=function() return {} end,real=function(p) return p end,distance=function() return 0 end}
  local function item(name,x,y,n)
    local e={valid=true,type='item-entity',position={x=x,y=y},marked=false}
    e.stack={valid_for_read=true,name=name,count=n or 1,quality={name='normal'},prototype={get_spoil_ticks=function() return 0 end},spoil_percent=0}
    e.to_be_deconstructed=function() return e.marked end
    e.order_deconstruction=function() e.marked=true; return true end
    return e
  end
  local list={}
  for k=1,250 do list[#list+1]=item('iron-plate',k%20,math.floor(k/20)) end
  for k=1,120 do list[#list+1]=item('iron-ore',k%20,20+math.floor(k/20)) end
  list[#list+1]=item('calcite',5,40,30)
  local sum=G.summary(list,12)
  eq(sum.stacks,371); eq(sum.count,400); eq(sum.slots,7) -- 250 plates at 100: 3 slots; 120 ore at 50: 3; 30 calcite at 50: 1
  eq(sum.items[1].name,'iron-plate'); eq(sum.items[1].slots,3); eq(sum.items[2].slots,3); eq(sum.items[3].slots,1)
  eq(G.counts_text(11793,sum,5000),'entities 11793 (each an item stack on the ground); items 400 in the 5000 entities read: 250 iron-plate, 120 iron-ore, 30 calcite; storage slots they fill 7 (at each item\'s stack size)')
  -- marking them: the storage chests of the network covering them, an unfiltered one and one filtered to iron-ore count;
  -- one filtered to coal does not
  local function chest(empty,filter) return {storage_filter=filter,get_inventory=function() return {count_empty_stacks=function() return empty end} end} end
  local net={network_id=7,storages={chest(10),chest(4,{name='iron-ore'}),chest(40,{name='coal'})}}
  local surface={find_entities_filtered=function() return list end,find_logistic_networks_by_construction_area=function() return {net} end}
  local out=G.mark({surface=surface,force={name='player'}},{left_top={x=0,y=0},right_bottom={x=30,y=50}},false,{})
  eq(out.item_stacks,371); eq(out.items_total,400); eq(out.storage_slots_needed,7); eq(out.storage_free_slots,14); eq(out.storage_chests,3)
  eq(out.counts,'entities 371 marked (each an item stack on the ground); items 400; storage slots they fill 7; empty slots in the storage chests that may take them: 14 (3 of 3 chests read)')
  eq(out.items[2].slots,3)
  prototypes,defines=saved.prototypes,saved.defines
end
print('d23 batch121 CD3: ok')

