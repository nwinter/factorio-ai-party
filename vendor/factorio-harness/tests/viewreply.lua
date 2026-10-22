-- Run from repository root: lua tests/viewreply.lua
-- A say that answers a viewer's line (d20 batch50 C1, NickWinter 07:25, shift45 seq 16942-16943): viewer lines to an
-- agent carry their seq and what answers them; say reply_to a viewer line keeps reply_to on the chat line and starts
-- "@Name " in the game chat when the text names them nowhere.
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
local v=op('viewer_say',{name='NickWinter (host)',text='@muse Muse: How could we end the biter problem on Nauvis once and for all?',source='site'})
-- the team block and the chat read say what answers it
local st=muse('status')
eq(st.team.mentions[1],'viewer NickWinter (host) (site) @you, 0s ago: @muse Muse: How could we end the biter problem on Nauvis once and for all? (#'..v.seq..': reply_to: '..v.seq..' answers it; a say naming NickWinter does while it is their only open line)')
local msgs=muse('chat',{since=v.seq-1}).messages
eq(msgs[1].answer,'reply_to: '..v.seq..' answers it (a say naming NickWinter does while it is their only open line)')
eq(astra('chat',{since=v.seq-1}).messages[1].answer,nil) -- not to astra
-- Muse's answer, naming no one, with reply_to
local r=muse('say',{text='Good question. The permanent fix is killing the spawners inside our pollution cloud.',reply_to=v.seq})
eq(r.reply_to.seq,v.seq); eq(r.reply_to.to,'NickWinter'); eq(r.reply_to.addressed,'@NickWinter put in front')
local line=muse('chat',{since=r.seq-1}).messages[1]
eq(line.text,'@NickWinter Good question. The permanent fix is killing the spawners inside our pollution cloud.')
eq(line.reply_to,v.seq)
assert(printed[#printed]:find(': @NickWinter Good question.',1,true),printed[#printed])
eq(muse('status').unanswered,nil) -- answered
-- a text that names them stays as it is
r=muse('say',{text='NickWinter, artillery is the long-range part.',reply_to={v.seq}})
eq(r.reply_to.addressed,nil); eq(muse('chat',{since=r.seq-1}).messages[1].text,'NickWinter, artillery is the long-range part.')
eq(muse('chat',{since=r.seq-1}).messages[1].reply_to,v.seq)
-- reply_to a teammate's line: no reply_to kept, nothing added
local s=sol('say',{text='@muse are the walls holding?'})
r=muse('say',{text='Yes, both walls hold.',reply_to=s.seq})
eq(r.reply_to,nil); eq(muse('chat',{since=r.seq-1}).messages[1].text,'Yes, both walls hold.'); eq(muse('chat',{since=r.seq-1}).messages[1].reply_to,nil)

-- (d20 batch57 S1, viewer Aurora 15:24: "Could replies link to and close only the question they answer? ... closing by name
-- can hide other unanswered requests"; shift47 17572: Opus's "Enginerd, fair. I hand-built those six panels ..." closed
-- Enginerd's three open lines to Opus, two of them about power) a viewer's line closes by name only while it is their one
-- open line; reply_to closes only the line it names
local e1=op('viewer_say',{name='Enginerd',text='@muse Okay, so add more power.',source='site'})
jump(1300) -- one line per viewer every 20 s
local e2=op('viewer_say',{name='Enginerd',text='@muse did you know that bots can rebuild buildings for you?',source='site'})
local un=muse('status').unanswered
assert(un and un:find('2 unanswered',1,true) and un:find('reply_to: '..e1.seq..' answers it (a say naming Enginerd does while it is their only open line)',1,true),un)
r=muse('say',{text='Enginerd, fair. I put a roboport there.'})
eq(r.left_open,'Enginerd has 2 open lines to you (#'..e1.seq..', #'..e2.seq..'): a say naming them closes none; reply_to closes the one it names')
assert(muse('status').unanswered:find('2 unanswered',1,true))
-- reply_to the second: only that one closes, though the text names Enginerd
r=muse('say',{text='Enginerd, fair. I put a roboport there.',reply_to=e2.seq})
eq(r.left_open,nil)
un=muse('status').unanswered
assert(un:find('1 unanswered',1,true) and un:find('#'..e1.seq..':',1,true),un)
-- now the one open line: a say naming them closes it
r=muse('say',{text='Enginerd, more accumulators are going in.'})
eq(r.left_open,nil); eq(muse('status').unanswered,nil)
-- (d22 batch75 AK6) that say closed Enginerd's one open line by name: linked to it as reply_to would
eq(r.linked,'linked to #'..e1.seq..' Enginerd (it names them; their one open line to you), as reply_to: '..e1.seq..' would')
local ln=muse('chat',{since=r.seq-1}).messages[1]
eq(ln.reply_to,e1.seq); eq(ln.linked_by,'name'); eq(ln.replies_to[1].seq,e1.seq); eq(ln.replies_to[1].name,'Enginerd')
eq(ln.replies_to[1].text,'Okay, so add more power.','the relay\'s @muse left out')
-- a teammate's mentions still close by name
sol('say',{text='@muse wall status?'}); sol('say',{text='@muse and the north gate?'})
muse('say',{text='@sol both hold.'})
eq(muse('status').unanswered,nil)
-- the reminder for a viewer's line names reply_to
jump(1300)
local e3=op('viewer_say',{name='Enginerd',text='@muse why coal?',source='site'})
assert(runtime.owed,'runtime.owed'); jump(36100); runtime.owed.tick()
local box=muse('status').team
local found=false
for _,l in ipairs(box and box.tells or {}) do if l:find('say reply_to: '..e3.seq..', or chat_ack',1,true) then found=true end end
assert(found,'reminder names reply_to: '..tostring(box and table.concat(box.tells or {},' | ')))
-- (d22 batch75 AK6, viewer Aurora site:4175: "preserve source message IDs through the harness and reply feed, then thread by
-- those IDs? Allow one answer to link to several messages.") viewer_say keeps the line's own id; a say with reply_to
-- several viewer lines keeps each (seq, name, id, text), puts "@Name " in front of each one it names nowhere, and the
-- chat read and the reply say so
jump(1300)
local f1=op('viewer_say',{name='Foobator',text='@muse is the south wall closed?',source='site',id='site:4175'})
eq(f1.id,'site:4175')
local a1=op('viewer_say',{name='Aurora',text='@muse and the west one?',source='youtube',id='yt:Ugx-1.2'})
local vl=muse('chat',{since=f1.seq-1}).messages
eq(vl[1].source_id,'site:4175'); eq(vl[2].source_id,'yt:Ugx-1.2')
r=muse('say',{text='Both walls are closed: 76 sections south, 40 west.',reply_to={f1.seq,s.seq,a1.seq}})
eq(r.reply_to.seq,f1.seq); eq(r.reply_to.to,'Foobator'); eq(r.reply_to.addressed,'@Foobator @Aurora put in front')
eq(#r.reply_to.also,1); eq(r.reply_to.also[1].seq,a1.seq); eq(r.reply_to.also[1].to,'Aurora')
ln=muse('chat',{since=r.seq-1}).messages[1]
eq(ln.text,'@Foobator @Aurora Both walls are closed: 76 sections south, 40 west.')
eq(ln.reply_to,f1.seq); eq(#ln.replies_to,2); eq(ln.linked_by,nil)
eq(ln.replies_to[1].id,'site:4175'); eq(ln.replies_to[1].source,'site'); eq(ln.replies_to[1].text,'is the south wall closed?')
eq(ln.replies_to[2].id,'yt:Ugx-1.2'); eq(ln.replies_to[2].name,'Aurora')
un=muse('status').unanswered
assert(un:find('1 unanswered',1,true) and un:find('#'..e3.seq..':',1,true),un) -- both closed (Enginerd's e3 stays)
-- an id that is not like those is left out; the line still goes
local k=op('viewer_say',{name='Kai',text='@muse hi',id='not an id'})
eq(k.posted,true); eq(k.id,nil); eq(muse('chat',{since=k.seq-1}).messages[1].source_id,nil)
print('viewreply: ok')
