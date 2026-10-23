-- Run from repository root: lua tests/d22_batch122.lua
-- d22 batch122 CE1 (viewer Aurora 08:48: "can an unrelated reply to someone clear their other unanswered requests? The
-- published owed.lua appears to do that"). It did, for teammates: a say naming the sender closed every open request of
-- theirs, with or without reply_to, and any tell to them closed all of theirs (batch57 S1 had held viewers' lines to
-- one at a time). Now, for everyone: reply_to closes exactly what it names; without it, a say or team tell naming the
-- sender, or a tell to them, closes their request only while it is their one open request to you.
-- Fixture: tests/viewreply.lua's.
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
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
local muse=as('muse')
runtime.operator.bot_create('muse')
local printed={}
nick.print=function(l) printed[#printed+1]=l end
local function op(action,args) return runtime.dispatch{action=action,args=args,operator=true} end
for _,n in ipairs{'astra','muse','sol'} do runtime.dispatch{action='status',args={brief=true},bot=n} end

local function open() local u=muse('status').unanswered; return u and tonumber(u:match('^(%d+) unanswered')) or 0, u end
-- 1. Sol asks two things by @mention; Muse answers the second with reply_to, naming Sol: only that one closes.
local s1=sol('say',{text='@muse are the walls holding?'})
jump(60)
local s2=sol('say',{text='@muse can you send 50 plates?'})
eq(open(),2)
local r=muse('say',{text='@sol yes, sending 50 plates now.',reply_to=s2.seq})
local n,u=open()
eq(n,1,'reply_to closes only the line it names'); assert(u:find('#'..s1.seq..':',1,true),u)
-- 2. An unrelated say naming Sol while two are open closes none, and says so (here: one more first).
local s3=sol('say',{text='@muse when do you leave?'})
eq(open(),2)
r=muse('say',{text='Thanks @sol, noted.'})
eq(open(),2,'a say naming Sol with two open closes none')
eq(r.left_open,'sol has 2 open requests to you (#'..s1.seq..', #'..s3.seq..'): a say or tell naming them closes none; reply_to closes the one it names')
-- 3. A tell to Sol, unrelated, with two open: none closes; the tell's reply says so.
r=muse('tell',{to='sol',text='fyi heading to Vulcanus'})
eq(open(),2,'a tell to Sol with two open closes none')
eq(r.left_open,'sol has 2 open requests to you (#'..s1.seq..', #'..s3.seq..'): a say or tell naming them closes none; reply_to closes the one it names')
-- 4. A tell with reply_to closes only that one.
r=muse('tell',{to='sol',text='walls hold',reply_to=s1.seq})
n,u=open(); eq(n,1); assert(u:find('#'..s3.seq..':',1,true),u)
eq(r.left_open,nil)
-- 5. Sol's one open request: a say naming Sol (no reply_to) answers it, as before.
r=muse('say',{text='@sol leaving at 10:00.'})
eq(open(),0); eq(r.left_open,nil)
-- 6. Tells that ask: two open from Astra; a tell to Astra closes none, reply_to one closes it, then a plain tell the last.
local t1=astra('tell',{to='muse',text='how much LDS can you ship?'})
local t2=astra('tell',{to='muse',text='is the silo loaded?'})
eq(open(),2)
muse('tell',{to='astra',text='working on it'})
eq(open(),2)
muse('say',{text='astra, 200 LDS.',reply_to=t1.seq})
eq(open(),1)
muse('tell',{to='astra',text='silo loaded'})
eq(open(),0,'their one open request: a tell to them answers it')
-- 7. A team tell naming the sender follows the same rule.
local a1=astra('tell',{to='muse',text='ready for flight?'})
local a2=astra('tell',{to='muse',text='fuel ok?'})
muse('tell',{to='team',text='astra: almost'})
eq(open(),2,'a team tell naming astra with two open closes none')
muse('chat_ack',{seq={a1.seq,a2.seq}})
eq(open(),0)
print('d22_batch122 CE1 a reply closes only what it answers: ok')
