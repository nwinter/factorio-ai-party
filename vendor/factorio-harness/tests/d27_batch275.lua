-- d27 batch275 HW (Haiku shift86 15:24: 8 of sol's tells listed unread for up to 33 min, cut from its view by its own
-- output filters; `fh wait --until "tell|alert" --max 900` slept the 900 s, since only a tell sent after a sleep
-- begins ends it). A sleep begun with tells unread for 2 minutes or more, not yet reported, ends at once on them.
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
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then error(result,0) end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local sol,haiku=as('sol'),as('haiku')
runtime.operator.bot_create('sol'); runtime.operator.bot_create('haiku')

-- sol's tells: shown once in haiku's next reply, then listed unread
local s1=sol('tell',{to='haiku',text='Restore the foundry now to casting steel'})
local s2=sol('tell',{to='haiku',text='run it now'})
haiku('status')
-- 1. a sleep right after the reply that showed them (under 2 minutes): it sleeps; a tell sent during it ends it
advance(3600)
haiku('sleep',{seconds=900})
eq(haiku('sleep_check',{peek=true}).woke,nil,'fresh unread tells do not end the sleep')
-- 2. two minutes on, still unread: the next sleep ends at once on both, oldest first, and says so
advance(4000)
haiku('sleep_check',{})
local r=haiku('sleep',{seconds=900})
eq(r.already_unread,2)
r=haiku('sleep_check',{})
eq(r.woke,'told'); eq(r.slept_s,0); eq(r.woke_by.kind,'tell'); eq(r.woke_by.seq,s2.seq); eq(r.woke_by.from,'sol'); eq(r.woke_by.unread,true)
assert(r.tell:find('2 unread tells from before this sleep began (a sleep reports each once; chat_ack marks them read): #'..s1.seq..' sol',1,true),r.tell)
assert(r.tell:find('Restore the foundry',1,true) and r.tell:find('#'..s2.seq..' sol, waiting 2m',1,true),r.tell)
-- 3. reported once: the next sleep sleeps through them, and a new tell still ends it
advance(30)
haiku('sleep',{seconds=900})
advance(600)
eq(haiku('sleep_check',{peek=true}).woke,nil,'reported tells do not end a later sleep')
local s3=sol('tell',{to='haiku',text='the pilot is off'})
r=haiku('sleep_check',{}); eq(r.woke,'told'); eq(r.woke_by.seq,s3.seq); eq(r.woke_by.unread,nil)
-- 4. a tell left unread past 2 minutes after that is reported to the next sleep, alone
haiku('status'); advance(7300)
haiku('sleep',{seconds=600}); r=haiku('sleep_check',{})
eq(r.woke,'told'); eq(r.woke_by.seq,s3.seq); assert(r.tell:find('^1 unread tell from before'),r.tell)
-- 5. acked tells are not reported; wake_on_messages false and a wake filter are left as they were
sol('tell',{to='haiku',text='one more'}); haiku('status'); advance(7300)
haiku('chat_ack',{seq='all'})
haiku('sleep',{seconds=600}); eq(haiku('sleep_check',{peek=true}).woke,nil,'read tells do not end it')
haiku('sleep_check',{}); advance(30)
sol('tell',{to='haiku',text='and another'}); haiku('status'); advance(7300)
haiku('sleep',{seconds=600,wake_on_messages=false}); eq(haiku('sleep_check',{peek=true}).woke,nil,'wake_on_messages false')
haiku('sleep_check',{}); advance(30)
haiku('sleep',{seconds=600,wake_from={'operator'}}); eq(haiku('sleep_check',{peek=true}).woke,nil,'a wake filter')
haiku('sleep_check',{}); advance(30)
haiku('sleep',{seconds=600}); eq(haiku('sleep_check',{}).woke,'told')
print('d27_batch275 HW unread tells end a sleep once: ok')
