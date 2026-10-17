-- Run from repository root: lua tests/tells.lua
-- Tells (tells.lua), sleep wakes on tells and board news, and board lines
-- for owners, through the runtime against a fake engine.
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


-- tell: to one teammate (any name form), several, or the team; never in chat.
local seq0=astra('chat',{since=0}).cursor
local r=astra('tell',{to='@Sunny',text='29 iron plates in the chest at (-18.5,-34.5)\nfor red science'})
eq(r.seq,1); eq(r.to[1],'sol'); eq(#r.to,1)
assert(r.note:find('not in chat',1,true))
eq(sol('chat',{since=seq0,peek=true}).messages[1],nil) -- the game chat log has no tell
local st=sol('status')
eq((st.chat or {}).unread,nil)
local t=st.team
eq(t.tells[1],'astra, 0s ago: 29 iron plates in the chest at (-18.5,-34.5) for red science'); eq(t.mentions,nil)
eq(sol('status').team,nil) -- shown once
eq((grok('status').team or {}).tells,nil) -- grok was not told
r=grok('tell',{to='astra, sol',text='turret ammo low'}); eq(#r.to,2)
r=grok('tell',{to={'astra','grok'},text='only astra'}); eq(r.to[1],'astra'); eq(#r.to,1) -- yourself is left out
r=sol('tell',{to='team',text='north belt is down'}); eq(r.to,'team')
t=astra('status').team.tells
eq(#t,3); eq(t[1],'grok, 0s ago: turret ammo low'); eq(t[3],'sol to team, 0s ago: north belt is down')
assert(has(grok('status').team.tells,'north belt is down'))
fails(function() astra('tell',{to='nobody',text='x'}) end,'unknown agent nobody')
fails(function() astra('tell',{to='astra',text='x'}) end,'no one to tell')
fails(function() astra('tell',{to='sol',text='  '}) end,'text is required')
fails(function() astra('tell',{text='x'}) end,'to is required')
fails(function() astra('tell',{to='operator',text='x'}) end,'harness requests')
-- A failed tell never stops the character's running action (passive).
astra('walk',{direction='east',ticks=100}); advance(1)
fails(function() astra('tell',{to='sol',text=''}) end,'text is required')
eq(astra('status').active.kind,'walk')

-- A chat read never delivers a tell (chat seq and tell seq are separate).
sol('say',{text='@astra hi'}) -- chat seq; tells are 1..4 too
grok('tell',{to='astra',text='gears ready'})
local c=astra('chat',{})
eq(#c.messages,1); eq(c.messages[1].text,'@astra hi')
-- The read's own reply carries the tell (it is in no message list).
eq(c.team.tells[1],'grok, 0s ago: gears ready'); eq(c.team.mentions,nil)

-- Reads: by default the ones you received, though a team block showed them
-- (Muse, shift10), at every read; since: sent and received; the operator reads
-- all (the stream ticker).
local mine=sol('tells',{})
eq(#mine.tells,2); eq(mine.tells[1].text,'29 iron plates in the chest at (-18.5,-34.5) for red science')
eq(mine.tells[1].from,'astra'); eq(mine.tells[1].to,nil); eq(mine.tells[1].ago_s,0); eq(mine.tells[2].from,'grok')
eq(#sol('tells',{}).tells,2,'read again')
local both=sol('tells',{since=0})
eq(#both.tells,3); eq(both.tells[3].from,'sol'); eq(both.tells[3].to,'team'); eq(both.tells[1].to[1],'sol')
for _,x in ipairs(both.tells) do assert(x.from=='sol' or x.to=='team' or x.to[1]=='sol' or x.to[2]=='sol',x.text) end
local all=op('tells',{})
eq(#all.tells,5); eq(all.cursor,5); eq(all.tells[4].to,'team'); eq(all.tells[4].team,true)
eq(#op('tells',{since=4}).tells,1)
eq(#op('tells',{limit=2}).tells,2)
-- mention_counts carries tells and board lines waiting for each agent.
grok('tell',{to='sol',text='one more'})
local counts={}
for _,row in ipairs(op('mention_counts',{}).agents) do counts[row.name]=row end
eq(counts.sol.tells,1); eq(counts.sol.unread_mentions,1); eq(counts.astra.tells,nil)
sol('status')

-- Sleep wakes on a tell (woke=told) and on board news (woke=board).
sol('sleep',{seconds=60})
eq(sol('sleep_check',{peek=true}).woke,nil)
astra('tell',{to='sol',text='wake up, plates are in'})
r=sol('sleep_check',{peek=true}); eq(r.woke,'told'); eq(r.tell,'astra: wake up, plates are in')
r=sol('sleep_check',{}); eq(r.woke,'told')
assert(has(r.team.tells,'wake up')) -- the final read delivers it
jump(601) -- past the 10 s in which a new sleep repeats this wake
sol('sleep',{seconds=60})
local id=astra('board_post',{kind='request',title='bring 50 gears',owner='sol',note='to the mall chest (3,4)'}).item.id
r=sol('sleep_check',{peek=true}); eq(r.woke,'board'); eq(r.board,'#'..id..' assigned to you by astra: bring 50 gears - to the mall chest (3,4)')
counts={}
for _,row in ipairs(op('mention_counts',{}).agents) do counts[row.name]=row end
eq(counts.sol.unread_board,1)
eq(sol('status').team.board[1],r.board)
-- Your own board changes do not wake you; others' changes to your item do.
sol('sleep',{seconds=60})
sol('board_update',{id=id,status='doing'})
eq(sol('sleep_check',{peek=true}).woke,nil)
astra('board_update',{id=id,note='make it 60'})
eq(sol('sleep_check',{peek=true}).board,'#'..id..' (yours) note by astra: make it 60')
sol('sleep_check',{}); sol('status'); jump(601)

-- Board news for owners: a requester's status change, a reassignment away,
-- a claim posted over yours.
astra('board_update',{id=id,status='dropped'})
eq(sol('status').team.board[1],'#'..id..' (yours) dropped by astra: bring 50 gears')
local id2=astra('board_post',{kind='task',title='belt the copper',owner='sol'}).item.id
sol('status')
astra('board_update',{id=id2,owner='grok'})
eq(sol('status').team.board[1],'#'..id2..' (was yours) assigned by astra to grok: belt the copper')
local claim=sol('board_post',{kind='claim',title='smelting',area={left_top={x=0,y=0},right_bottom={x=10,y=10}}}).item.id
local over=grok('board_post',{kind='claim',title='mall',area={left_top={x=5,y=5},right_bottom={x=20,y=20}}}).item.id
eq(sol('status').team.board[1],'#'..over..' claim by grok overlaps your claim #'..claim..': mall')
eq((astra('status').team or {}).board,nil)

-- A new unowned request reaches every teammate once, after their own items,
-- and wakes no sleeper.
grok('status')
astra('sleep',{seconds=60})
local open=sol('board_post',{kind='request',title='someone build 2 boilers'}).item.id
eq(astra('sleep_check',{peek=true}).woke,nil)
astra('sleep_check',{}); astra('status')
r=grok('board_post',{kind='task',title='wall',owner='astra'}) -- its reply carries grok's news
eq(r.team.board[1],'#'..open..' new unowned request by sol: someone build 2 boilers; take it with board_update {id, owner: "grok"}')
local mine2=r.item.id
sol('board_post',{kind='request',title='another'})
t=astra('status').team.board
eq(t[1],'#'..mine2..' assigned to you by grok: wall')
assert(t[2]:find('new unowned request by sol: another',1,true),t[2])
eq(#grok('status').team.board,1); eq((sol('status').team or {}).board,nil) -- not to its poster

-- Up to 500 characters as written; longer is cut, and the reply says so
-- (shift01: 324 characters cut to 300 with no word of it).
local long=string.rep('steel at (88.5,-27.5) ',22) -- 484 characters
local r1=sol('tell',{to='astra',text=long}); eq(r1.cut,nil)
eq(astra('tells',{since=r1.seq-1}).tells[1].text,(long:gsub('%s+$','')))
r1=sol('tell',{to='astra',text=long..long})
eq(r1.cut.length,#((long..long):gsub('%s+$',''))); eq(r1.cut.kept,500)
eq(#astra('tells',{since=r1.seq-1}).tells[1].text,500)
assert(runtime.dispatch{action='describe',args={},player=1}.actions.tell.text:find('1..500',1,true))

-- operator: a request to the operator, read by the stream service over the
-- operator path; one a minute and 10 an hour per agent, with the wait named.
-- (shift01 16:13: Astra promised a viewer to pass a request on, with no way to.)
local before=op('operator_requests',{}).cursor
r1=astra('operator',{text='a viewer asks for longer viewer replies\nfrom the hosts'})
eq(r1.seq,before+1); eq(r1.cut,nil); assert(r1.note:find('server:',1,true))
local inbox=op('operator_requests',{since=before})
eq(#inbox.requests,1); eq(inbox.requests[1].from,'astra'); eq(inbox.requests[1].text,'a viewer asks for longer viewer replies from the hosts')
eq(inbox.cursor,before+1)
eq((sol('status').team or {}).tells,nil) -- not a tell: no teammate sees it
fails(function() astra('operator',{text='again'}) end,'one operator request a minute; next in 60 s')
jump(1800); fails(function() astra('operator',{text='again'}) end,'next in 30 s')
eq(sol('operator',{text='belt_route refuses diagonal starts'}).seq,before+2) -- per agent
for _=1,9 do jump(3600); astra('operator',{text='more'}) end
jump(3600)
fails(function() astra('operator',{text='eleventh'}) end,'10 operator requests an hour; next in')
jump(3600*50); eq(astra('operator',{text='after the hour'}).seq>0,true) -- the first one left the hour
-- Shift14: a clipped second issue forced Astra to resend and hit the one-minute limit.
local long=string.rep('x',1995)..' tail'
r1=grok('operator',{text=long}); eq(r1.cut,nil)
eq(op('operator_requests',{since=r1.seq-1}).requests[1].text,long)
jump(3600)
local cursor=op('operator_requests',{}).cursor
fails(function() grok('operator',{text=string.rep('x',2001)}) end,'no request filed')
eq(op('operator_requests',{}).cursor,cursor)
-- UTF-8 is bounded by bytes, with no partial code point filed.
fails(function() grok('operator',{text=string.rep('é',1001)}) end,'exceeds 2000 bytes')
r1=grok('operator',{text='whole after refusal'}); eq(r1.seq,cursor+1)
fails(function() grok('operator',{text='too soon'}) end,'one operator request a minute')
-- Teammate tells retain their existing 500-byte limit.
local clipped=astra('tell',{to='sol',text=string.rep('x',600)})
eq(clipped.cut.length,600); eq(clipped.cut.kept,500)
fails(function() grok('operator',{text='  '}) end,'text is required')
eq(#op('operator_requests',{since=before,limit=2}).requests,2)
assert(runtime.dispatch{action='describe',args={},player=1}.actions.operator.text:find('server:',1,true))
-- The operator answers in the game chat as server: (no player): an @name there
-- reaches that agent as a mention, which wakes a sleeper.
runtime.on_event{name=defines.events.on_console_chat,tick=tick,message='@astra longer replies are on the list'}
local m=astra('status').team.mentions
assert(m and m[1]:find('server',1,true) and m[1]:find('longer replies',1,true),m and m[1])
eq((grok('status').team or {}).mentions,nil)
grok('sleep',{seconds=60}); eq(grok('sleep_check',{peek=true}).woke,nil)
runtime.on_event{name=defines.events.on_console_chat,tick=tick,message='@grok thanks, filed'}
eq(grok('sleep_check',{peek=true}).woke,'mentioned')

-- History (Muse, shift10: "a tell shown once in the team block is lost if I
-- miss it"): fh tells lists the last 30 received, oldest first, with time,
-- sender and fyi, whether the team block showed them or not.
grok('status'); grok('tells',{})
for i=1,35 do
  if i%10==0 then jump(600) end
  astra('tell',{to='grok',text='load '..i,fyi=i%2==0 or nil})
end
sol('tell',{to='team',text='team line'})
local shown=grok('tell',{to='sol',text='sent by grok'}).team.tells
eq(#shown,36); eq(grok('status').team,nil) -- the team block showed each once
local h=grok('tells',{}).tells
eq(#h,30); eq(h[1].text,'load 7'); eq(h[29].text,'load 35'); eq(h[30].text,'team line'); eq(h[30].team,true)
eq(h[2].fyi,true); eq(h[1].fyi,nil); eq(h[1].from,'astra'); eq(h[1].ago_s,30); eq(h[30].ago_s,0); eq(h[30].tick,game.tick)
for _,x in ipairs(h) do assert(x.text~='sent by grok' and x.to==nil,x.text) end
eq(#grok('tells',{}).tells,30,'the same list on the next read')
eq(#grok('tells',{limit=5}).tells,5); eq(grok('tells',{limit=5}).tells[1].text,'load 32')
eq(grok('tells',{since=0,limit=100}).tells[#grok('tells',{since=0,limit=100}).tells].text,'sent by grok')
-- A new tell is in the list and, as in any reply, once in the read's team block.
astra('tell',{to='grok',text='after'})
local rd=grok('tells',{})
eq(rd.tells[30].text,'after'); eq(rd.tells[29].text,'team line'); eq(rd.team.tells[1],'astra, 0s ago: after')
eq(grok('tells',{}).team,nil); eq(grok('tells',{}).tells[30].text,'after')
-- A wait that ignores messages (Astra, d15 14:48: Sonnet sat in 15-minute waits no tell reached): the sender is told
-- so; tell {wake: true} ends it, every time (batch8 A4), counting the sender's wake tells over 10 minutes.
do
  grok('wait_ticks',{ticks=54000,wake_on_messages=false}); advance(1)
  local r=astra('tell',{to='grok',text='freight at the pad'})
  assert(r.ignoring and r.ignoring:find('grok is in a wait_ticks that ignores messages until tick',1,true),tostring(r.ignoring))
  advance(60); eq(grok('status').active.kind,'wait_ticks','a plain tell does not end it')
  fails(function() astra('tell',{to='grok',text='x',wake=true,fyi=true}) end,'wake or fyi')
  r=astra('tell',{to='grok',text='the pad is full, needs you now',wake=true})
  eq(r.woken[1],'grok'); eq(r.ignoring,nil)
  local st=grok('status')
  assert(not st.active,'the wait ended'); eq(st.last.outcome,'told'); eq(st.last.why,'told by astra (wake: true)')
  grok('wait_ticks',{ticks=54000,wake_on_messages=false}); advance(1)
  r=astra('tell',{to='grok',text='again',wake=true})
  eq(r.woken[1],'grok (your 2 wake tells to them in the last 10 min)'); eq(r.not_woken,nil)
  assert(not grok('status').active,'woken again')
  grok('wait_ticks',{ticks=54000,wake_on_messages=false}); advance(1)
  r=sol('tell',{to='grok',text='from sol',wake=true}); eq(r.woken[1],'grok','another sender may wake it')
  grok('wait_ticks',{ticks=54000,wake_on_messages=false}); advance(1)
  jump(10*3600); advance(1)
  r=astra('tell',{to='grok',text='ten minutes on',wake=true}); eq(r.woken[1],'grok')
  -- a wait that takes tells only from sol: astra's plain tell is said ignored, and --wake ends it
  grok('wait_ticks',{ticks=54000,wake_from={'sol'}}); advance(1)
  r=astra('tell',{to='grok',text='not from sol'})
  assert(r.ignoring and r.ignoring:find('grok is in a wait_ticks that takes tells only from others until tick',1,true),tostring(r.ignoring))
  advance(60); eq(grok('status').active.kind,'wait_ticks','a plain tell from another does not end it')
  r=astra('tell',{to='grok',text='wake anyway',wake=true}); eq(r.woken[1],'grok (your 2 wake tells to them in the last 10 min)')
  assert(not grok('status').active,'the filtered wait ended')
  -- a wait that takes messages: no ignoring line
  grok('wait_ticks',{ticks=600}); advance(1)
  r=astra('tell',{to='grok',text='plain',fyi=true}); eq(r.ignoring,nil)
  grok('stop',{})
end
print('tells: ok')
