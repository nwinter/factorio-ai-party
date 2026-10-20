-- Run from repository root: lua tests/rests.lua
-- Rests between turns (rests.lua; d20 batch50 B1, viewer Aurora): the teammates line and tell replies say
-- "resting until HH:MM (pace|quota)", with the recipient's board items whose review falls inside the rest.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
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
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local astra,sol,luna,opus=as('astra'),as('sol'),as('luna'),as('opus')
local names={'astra','sol','luna','opus','kai','grok','mira'}
for _,n in ipairs(names) do runtime.operator.bot_create(n) end
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sol',glyph='S',color='#ffcb45'})
local function bot(n) return runtime.bots.record(runtime.bots.index_of(n)) end
local function put(n,surface,x,y) local c=bot(n).character; c.surface=surface; c.position={x=x,y=y}; bot(n).surface=surface.name end
put('astra',nauvis,0,0); put('luna',nauvis,60,-80); put('opus',nauvis,0,25); put('mira',nauvis,-30,0); put('sol',vulcanus,3,3)
local function op(action,args) return runtime.dispatch{action=action,args=args,operator=true} end
jump(60)
for _,n in ipairs(names) do runtime.dispatch{action='status',args={brief=true},bot=n} end
-- Opus's open items: one review inside the coming rest, one after it, one done; luna's item is not opus's.
local due=opus('board_post',{kind='task',title='Boiler check',owner='opus',evidence={metric='steam 60/s',next_check=tick+3*3600}}).item.id
local late=opus('board_post',{kind='task',title='Swiftlet route',owner='opus',evidence={metric='PU 600',next_check=tick+30*3600}}).item.id
local gone=opus('board_post',{kind='task',title='Old furnaces',owner='opus',evidence={metric='x',next_check=tick+2*3600}}).item.id
opus('board_update',{id=gone,status='done'})
luna('board_post',{kind='task',title='Luna item',owner='luna',evidence={metric='y',next_check=tick+2*3600}})
jump(60)
-- no rest: nothing said
eq(astra('tell',{to='opus',text='boilers?'}).resting,nil)
assert(not astra('status').teammates:find('resting',1,true))
-- the loop pushes a 5-minute pace rest (tools/agy-quota.py), at 48 ticks a second
local r=op('rest',{agent='opus',until_clock='07:34',until_s=300,reason='pace',ticks_per_s=48})
eq(r.agent,'opus'); eq(r.until_tick,tick+300*48); eq(r.reason,'pace')
eq(astra('status').teammates,'Sol on Vulcanus; kai 4 tiles SW; grok 4 tiles SW; opus 25 tiles S (resting until 07:34 (pace)); mira 30 tiles W; luna 100 tiles NE')
local row
for _,x in ipairs(astra('players',{}).teammates) do if x.name=='opus' then row=x end end
eq(row.resting,'resting until 07:34 (pace)'); eq(row.offline,nil)
r=astra('tell',{to='opus,luna',text='boilers?'})
eq(r.resting,'opus is resting until 07:34 (pace); board items with a review in the rest: #'..due..' Boiler check (review in 3 min)')
eq(astra('tell',{to='team',text='all'}).resting:find('opus is resting until 07:34 (pace)',1,true),1)
eq(astra('tell',{to='luna',text='hi'}).resting,nil)
-- a quota rest past the 15-minute offline mark: resting, not offline
op('rest',{agent='opus',until_clock='09:10',until_s=3600,reason='quota'})
jump(20*3600)
for _,n in ipairs{'astra','sol','luna','mira'} do runtime.dispatch{action='status',args={brief=true},bot=n} end
eq(astra('status').teammates,'Sol on Vulcanus; kai 4 tiles SW (offline); grok 4 tiles SW (offline); opus 25 tiles S (resting until 09:10 (quota)); mira 30 tiles W; luna 100 tiles NE')
-- the review 3 min after the rest began is behind now, still inside the rest: said as ago
eq(astra('tell',{to='opus',text='x'}).resting,'opus is resting until 09:10 (quota); board items with a review in the rest: #'..due..' Boiler check (review 17 min ago), #'..late..' Swiftlet route (review in 10 min)')
-- the next turn: the loop ends it (done), or opus's own request does
eq(op('rest',{agent='opus',done=true}).ended,true)
eq(astra('tell',{to='opus',text='x'}).resting,nil)
op('rest',{agent='opus',until_clock='09:40',until_s=600,reason='pace'})
assert(astra('status').teammates:find('opus 25 tiles S (resting until 09:40 (pace))',1,true))
jump(1)
opus('status',{brief=true})
eq(astra('tell',{to='opus',text='x'}).resting,nil)
-- past its tick: over
op('rest',{agent='opus',until_clock='09:41',until_s=10,reason='pace'})
jump(601)
runtime.dispatch{action='status',args={brief=true},bot='astra'}
assert(not astra('status').teammates:find('resting',1,true))
-- refusals stop nobody (operator requests)
assert(not pcall(op,'rest',{agent='opus',until_clock='7:34',until_s=60,reason='pace'}))
assert(not pcall(op,'rest',{agent='opus',until_clock='07:34',until_s=60,reason='nap'}))
assert(not pcall(op,'rest',{agent='opus',until_clock='07:34',reason='pace'}))
print('rests: ok')
