-- Run from repository root: lua tests/teamwhere.lua
-- Where teammates are (where.lua): full status's teammates line (shift05:
-- viewers and agents asked Sol, alone on Vulcanus, about Nauvis work).
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
luna('profile',{display_name='Luna',glyph='L',color='#77aaff'})
local function bot(n) return runtime.bots.record(runtime.bots.index_of(n)) end
local function put(n,surface,x,y) local c=bot(n).character; c.surface=surface; c.position={x=x,y=y}; bot(n).surface=surface.name end
put('astra',nauvis,0,0); put('luna',nauvis,60,-80); put('opus',nauvis,0,25); put('mira',nauvis,-30,0); put('sol',vulcanus,3,3)
-- Kai aboard the platform (no body), grok riding a cargo pod down to Vulcanus, mira dead.
local kai=bot('kai'); kai.character.destroy(); kai.character=nil; kai.surface='platform-1'; kai.travel={state='aboard',platform='Peregrine'}
local grok=bot('grok'); grok.character.destroy(); grok.character=nil; grok.travel={state='descending',platform='Peregrine',to='vulcanus'}
local mira=bot('mira'); mira.position={x=-30,y=0}; mira.character.valid=false
-- Opus made its last request over 15 minutes ago: offline.
opus('status',{brief=true})
jump(15*3600+60)
for _,n in ipairs{'astra','sol','luna','kai','grok','mira'} do runtime.dispatch{action='status',args={brief=true},bot=n} end

-- Full status: elsewhere first, grouped by place; then this surface, nearest first; dead and offline marked.
local st=astra('status')
eq(st.teammates,'Sol on Vulcanus; kai on platform Peregrine; grok in a cargo pod to Vulcanus; opus 25 tiles S (offline); mira 30 tiles W (dead); Luna 100 tiles NE')
eq(sol('status').teammates,'Astra, Luna, opus (offline), mira (dead) on Nauvis; kai on platform Peregrine; grok in a cargo pod to Vulcanus')
-- Brief status (what fh --wait polls) has none.
eq(astra('status',{brief=true}).teammates,nil)
-- Humans (nick) and directors are not teammates; an attached player is.
assert(not st.teammates:find('nick',1,true) and not st.teammates:find('director',1,true))
runtime.dispatch{action='attach',args={},player=1}
assert(astra('status').teammates:find('nick 7 tiles SE',1,true),astra('status').teammates)
nick.connected=false
assert(astra('status').teammates:find('nick 7 tiles SE (offline)',1,true))
-- A player in remote view is where its body is.
nick.connected=true; nick.surface=vulcanus; nick.position={x=0,y=0}; nick.physical_surface=nauvis; nick.physical_position={x=5,y=5}
assert(astra('status').teammates:find('nick 7 tiles SE',1,true))
-- describe tells what the line holds.
assert(astra('describe',{}).actions.status.reports:find('teammates (one line',1,true))

-- Tells: a line from a teammate elsewhere says where; tell says where its recipients are.
local r=astra('tell',{to='sol,luna',text='may I build in claim 235?'})
eq(r.away,'sol is on Vulcanus')
eq(astra('tell',{to='luna',text='hi'}).away,nil)
eq(astra('tell',{to='kai',text='hub?'}).away,'kai is on platform Peregrine')
eq(sol('status').team.tells[1],'astra (on Nauvis), 0s ago: may I build in claim 235?')
eq(luna('status').team.tells[1],'astra, 0s ago: may I build in claim 235?')
sol('tell',{to='astra',text='go ahead'})
eq(astra('status').team.tells[1],'sol (on Vulcanus), 0s ago: go ahead')
local tl=astra('tells',{since=0}).tells
eq(tl[#tl].from,'sol'); eq(tl[#tl].away,'on Vulcanus'); eq(tl[1].away,nil)
tl=astra('tells',{}).tells
eq(#tl,1); eq(tl[1].from,'sol'); eq(tl[1].away,'on Vulcanus')
eq(sol('tells',{}).tells[1].away,'on Nauvis')
-- Chat: mention lines, chat reads and the unread trailer.
sol('say',{text='@astra the furnaces are yours'})
st=astra('status')
eq(st.team.mentions[1],'sol (on Vulcanus) @you, 0s ago: @astra the furnaces are yours')
eq(st.chat.latest,'sol (on Vulcanus): @astra the furnaces are yours')
local msgs=astra('chat',{}).messages
eq(msgs[#msgs].away,'on Vulcanus')
luna('say',{text='ok'})
msgs=astra('chat',{}).messages
eq(msgs[#msgs].from,'luna'); eq(msgs[#msgs].away,nil)
eq(luna('status').chat.latest:find('sol (on Vulcanus): ',1,true),1)

-- Board claims: reads and the overlap warning say where an owner elsewhere is.
local area={left_top={x=0,y=0},right_bottom={x=20,y=20}}
local c1=sol('board_post',{kind='claim',title='brick furnaces',area=area,surface='nauvis'}).item.id  -- (posted from Vulcanus, on Nauvis)
local c2=luna('board_post',{kind='claim',title='iron smelting',area={left_top={x=30,y=0},right_bottom={x=40,y=10}}}).item.id
r=astra('board_post',{kind='claim',title='walls',area={left_top={x=10,y=5},right_bottom={x=35,y=8}}})
eq(r.warnings[1]..'|'..r.warnings[2],'overlaps claim #'..c1..' by sol (on Vulcanus): brick furnaces (posted 0s ago, owner active on it 0s ago, sol last request 0s ago)'
  ..'|overlaps claim #'..c2..' by luna: iron smelting (posted 0s ago, owner active on it 0s ago, luna last request 0s ago)')
local function item(list,id) for _,i in ipairs(list) do if i.id==id then return i end end end
local items=astra('board',{kind='claim'}).items
eq(item(items,c1).owner_away,'on Vulcanus'); eq(item(items,c2).owner_away,nil); eq(item(items,r.item.id).owner_away,nil)
eq(astra('board',{id=c1}).item.owner_away,'on Vulcanus')
eq(item(sol('board',{kind='claim'}).items,c2).owner_away,'on Nauvis')
eq(item(runtime.dispatch{action='board',args={kind='claim'},operator=true}.items,c1).owner_away,nil)
-- The claim label collect and stock print.
local astra_p=runtime.lookup(runtime.bots.index_of('astra'))
local function starts(s,prefix) assert(s:sub(1,#prefix)==prefix,s..' does not start with '..prefix) end
starts(runtime.claims.label({id=c1,title='brick furnaces',owner='sol'},astra_p),'#'..c1..' brick furnaces (claim by sol, on Vulcanus; posted ')
starts(runtime.claims.label({id=c2,title='iron smelting',owner='luna'},astra_p),'#'..c2..' iron smelting (claim by luna; posted ')
print('teamwhere: ok')
