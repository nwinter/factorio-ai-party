-- Run from repository root: lua tests/board.lua
-- Team board, board events, the per-agent `team` reply hints, harness
-- requests and saved plans, through the runtime against a fake engine.
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

-- Posting: kinds, validation, owner resolution by display name, truncation.
local r=sol('board_post',{kind='request',title='build 10 red science assemblers'})
eq(r.item.id,1); eq(r.item.status,'open'); eq(r.item.owner,nil); eq(r.item.requested_by,'sol')
assert(has(r.warnings,'no owner'))
r=sol('board_post',{kind='task',title='feed the labs',owner='Astra'})
eq(r.item.owner,'astra'); eq(r.item.status,'claimed')
r=astra('board_post',{kind='task',title=string.rep('x',300),owner='SOL'})
eq(#r.item.title,120); eq(r.item.owner,'sol')
fails(function() sol('board_post',{kind='task',title='x',owner='nobody'}) end,'unknown agent nobody; agents: astra, grok, nick, sol')
fails(function() sol('board_post',{kind='bogus',title='x'}) end,'kind must be')
fails(function() sol('board_post',{kind='task',title='  '}) end,'title is required')
fails(function() sol('board_post',{kind='claim',title='smelting'}) end,'a claim needs area')
fails(function() sol('board_post',{kind='harness',title='x'}) end,'harness_request')
fails(function() sol('board_post',{kind='task',title='x',colour='red'}) end,'unknown argument colour')
-- Claims belong to the poster and warn about overlaps with others' claims.
r=grok('board_post',{kind='claim',title='iron smelting',area={left_top={x=-60,y=-30},right_bottom={x=-40,y=-20}},owner='sol'})
eq(r.item.owner,'grok'); eq(r.item.status,'claimed'); eq(r.warnings,nil)
r=sol('board_post',{kind='claim',title='copper',area={left_top={x=-45,y=-25},right_bottom={x=-30,y=-10}}})
assert(has(r.warnings,'overlaps claim #4 by grok: iron smelting'))
r=sol('board_post',{kind='note',title='main bus runs north at x=0',tags={'layout'},needs={'iron-plate',{name='copper-cable',count=50}}})
eq(r.item.owner,'sol'); eq(r.item.needs[2].count,50); eq(r.item.tags[1],'layout')

-- A failed board call never stops the character's running action.
astra('walk',{direction='east',ticks=100}); advance(1)
fails(function() astra('board_update',{id=999,note='x'}) end,'no board item #999')
fails(function() astra('board_update',{id=1,status='done'}) end,'only the owner')
eq(astra('status').active.kind,'walk')

-- Updating: anyone takes an open unowned item; only owner/requester change status.
r=grok('board_update',{id=1,owner='grok'})
eq(r.item.owner,'grok'); eq(r.item.status,'claimed'); eq(r.changed[1],'taken')
fails(function() astra('board_update',{id=1,owner='astra'}) end,'only its owner or requester can reassign')
r=astra('board_update',{id=1,note='I can bring gears'})
eq(r.item.notes[1].by,'astra'); eq(r.item.status,'claimed')
r=grok('board_update',{id=1,status='doing',note='placing assemblers'})
eq(r.item.status,'doing')
fails(function() grok('board_update',{id=1,status='finished'}) end,'status must be')
-- A bad argument changes nothing, even with a valid owner beside it.
fails(function() sol('board_update',{id=1,owner='astra',note=''}) end,'note is required')
eq(grok('board',{id=1}).item.owner,'grok')
fails(function() grok('board_update',{id=1}) end,'give status, owner or note')
fails(function() grok('board_update',{id=4,owner='sol'}) end,'stays with its poster')
-- The requester may reassign; the owner may release.
r=sol('board_update',{id=1,owner='astra'}); eq(r.item.owner,'astra'); eq(r.changed[1],'assigned')
r=astra('board_update',{id=1,owner=''}); eq(r.item.owner,nil); eq(r.item.status,'open')
-- Notes are bounded to the last 10.
for i=1,12 do grok('board_update',{id=5,note='n'..i}) end
eq(#grok('board',{id=5}).item.notes,10); eq(grok('board',{id=5}).item.notes[1].text,'n3')

-- Reading: newest first, filters, open_unowned.
jump(10)
grok('board_update',{id=2,note='still on it?'})
r=grok('board',{})
eq(r.items[1].id,2); eq(r.matched,6); eq(r.open_unowned,1)
eq(#grok('board',{limit=2}).items,2)
eq(grok('board',{kind='claim'}).matched,2)
eq(astra('board',{mine=true}).matched,2) -- #2 owned, #3 requested
eq(grok('board',{since_tick=tick-1}).matched,1)
eq(grok('board',{status='open'}).matched,2) -- #1 released, the note
r=sol('board_update',{id=2,status='done'}) -- sol requested it
eq(grok('board',{status='active'}).matched,5)
eq(grok('board',{status={'done','dropped'}}).items[1].id,2)
-- List rows carry the last two notes and a count; the full item has all.
eq(#grok('board',{kind='claim'}).items[1].notes,2); eq(grok('board',{kind='claim'}).items[1].note_count,10)

-- Event log for the overlay: everything, in order, with a cursor; any player
-- (the director has no character) may read it; it carries no team hints.
local ev=request{action='board_events',args={},player=2}
eq(ev.events[1].seq,1); eq(ev.events[1].change,'posted'); eq(ev.events[1].by,'sol'); eq(ev.events[1].title,'build 10 red science assemblers')
eq(ev.cursor,ev.latest); eq(ev.team,nil)
local after=request{action='board_events',args={since_seq=ev.cursor-1},player=2}
eq(#after.events,1); eq(after.events[1].change,'done'); eq(after.events[1].by,'sol')
eq(#request{action='board_events',args={since_seq=0,limit=3},player=2}.events,3)
eq(request{action='board',args={},player=2}.matched,6)
fails(function() request{action='board_post',args={kind='note',title='x'},player=2} end,'directors do not post')

-- Team hints: assignment, requester updates, notes on my items; each shown once.
-- (Any reply carries them: astra's earlier calls already consumed #2's note.)
-- The requester finishing an item tells its owner.
local t=astra('status').team
eq(t.board[1],'#2 (yours) done by sol: feed the labs')
eq(astra('status').team,nil)
local posted=sol('board_post',{kind='task',title='feed the furnaces',owner='astra'}).item.id
local t=astra('status').team
assert(has(t.board,'#'..posted..' assigned to you by sol: feed the furnaces'),table.concat(t.board or {},' | '))
eq(astra('status').team,nil)
grok('board_update',{id=3,note='sol is busy'})
t=astra('status').team
assert(has(t.board,'#3 (your task) note by grok: sol is busy'))
sol('board_update',{id=3,status='blocked',note='no iron'})
t=astra('status').team
assert(has(t.board,'#3 (your task) blocked by sol'),table.concat(t.board,' | '))
assert(has(t.board,'no iron'))
-- My own changes are not news to me.
astra('board_update',{id=3,note='ok'})
eq(astra('status').team,nil)
-- Unowned requests: a nudge once another one passes 2 game minutes.
eq((grok('status').team or {}).board==nil or not has(grok('status').team.board,'nobody owns'),true)
jump(7200)
t=grok('status').team
assert(has(t.board,'1 open request nobody owns'),table.concat(t.board,' | '))
assert(has(t.board,'#1 build 10 red science assemblers'))
assert(has(t.board,'owner: "grok"'))
eq(grok('status').team,nil)
sol('board_post',{kind='task',title='second unowned'}); jump(7200)
assert(has(grok('status').team.board,'2 open requests nobody owns (oldest 4m'))

-- Mentions: @name, @display name, @everyone (@all, @team), else the plain
-- name as a word; each listed in full, once; my own messages never count.
sol('say',{text='astra can you bring gears?'})
t=astra('status').team
eq(#t.mentions,1); eq(t.mentions[1],'sol, 0s ago: astra can you bring gears?')
eq(astra('status').team,nil)
grok('say',{text='@Sunny iron is low'}); grok('say',{text='solar is later'}); grok('say',{text='@SOL ping'}); grok('say',{text='sol-2 is a drill'})
t=sol('status').team
eq(#t.mentions,2); eq(t.mentions[1],'grok @you, 0s ago: @Sunny iron is low'); eq(t.mentions[2],'grok @you, 0s ago: @SOL ping')
sol('say',{text='sol here, @sol'}); eq((sol('status').team or {}).mentions,nil)
grok('say',{text='@everyone turrets now'}); grok('say',{text='@all: rearm'})
t=astra('status').team.mentions
eq(t[1],'grok @everyone, 0s ago: @everyone turrets now'); eq(t[2],'grok @everyone, 0s ago: @all: rearm')
eq(#sol('status').team.mentions,2); eq((grok('status').team or {}).mentions,nil)
-- People in a client and the server (RCON text) mention too.
runtime.on_event{name=13,player_index=1,message='astra, nice base'}
runtime.on_event{name=13,message='@everyone harness v3: board is live'}
t=astra('status').team
eq(t.mentions[1],'nick, 0s ago: astra, nice base'); eq(t.mentions[2],'server @everyone, 0s ago: @everyone harness v3: board is live')
-- Never dropped: all of them, beyond the caps of the other parts.
for i=1,12 do grok('say',{text='@astra item '..i}) end
eq(#astra('status').team.mentions,12)
-- A chat read returns every unread mention in full past its limit (and so delivers them); the rest get a digest.
grok('say',{text='astra one'}); grok('say',{text='solar is fine'}); grok('say',{text='astra three'})
local read=astra('chat',{limit=1})
eq(read.messages[#read.messages].text,'astra three'); eq(read.messages[#read.messages-1].text,'astra one')
eq(read.messages[#read.messages-1].mention,'name'); eq(read.messages[1].mention~=nil,true)
eq((read.team or {}).mentions,nil); eq((read.team or {}).chat_remaining,nil)
assert(read.remaining>=1 and read.digest:find('older message',1,true) and read.digest:find('grok',1,true),read.digest)
for _,m in ipairs(read.messages) do assert(m.mention or m.text=='astra three','non-mention past the limit: '..m.text) end
-- Until those are read, every reply's team hints repeat how many are left.
local left=read.remaining
eq(astra('status').team.chat_remaining,left); eq(astra('board').team.chat_remaining,left)
eq((astra('status',{peek=true}).team or {}).chat_remaining,nil)
repeat read=astra('chat',{limit=30}) until not read.remaining
eq((astra('status').team or {}).chat_remaining,nil)
eq((astra('status').team or {}).mentions,nil)
-- A peek (overlays) does not consume hints.
grok('say',{text='astra peek'})
eq(astra('chat',{peek=true}).team,nil)
eq(astra('status',{peek=true}).team,nil); eq(astra('board',{peek=true}).team,nil); eq(astra('profiles',{peek=true}).profiles~=nil,true)
fails(function() astra('status',{peek='yes'}) end,'unknown argument peek')
-- Supervisors: pending mention counts per agent, without consuming them.
grok('say',{text='@everyone regroup at spawn'})
local counts={}
for _,row in ipairs(op('mention_counts').agents) do counts[row.name]=row end
eq(counts.astra.unread_mentions,2); eq(counts.astra.at_mentions,1); eq(counts.astra.latest,'grok: @everyone regroup at spawn')
eq(counts.sol.unread_mentions,2); eq(counts.grok.unread_mentions,0); eq(counts.astra.last_request_tick,tick)
eq(counts['pog-director'],nil)
eq(#request{action='mention_counts',args={},player=2}.agents,4)
eq(#astra('status').team.mentions,2)
-- The pending list is bounded; the overflow is counted, not hidden.
for i=1,205 do grok('say',{text='@astra flood '..i}) end
eq(op('mention_counts').agents[2].unread_mentions,205)
t=astra('status').team.mentions
eq(#t,201); eq(t[1],'5 older mentions did not fit (200 kept); read chat'); eq(t[2]:sub(-8),' flood 6')
-- say aloud=true is kept with the message (the audio engineer voices it).
sol('say',{text='@everyone power is back',aloud=true})
local function newest(r) return r.messages[#r.messages] end
local peeked=newest(astra('chat',{peek=true,limit=1}))
eq(peeked.text,'@everyone power is back'); eq(peeked.aloud,true)
eq(newest(astra('chat',{limit=1})).aloud,true)
grok('say',{text='quiet line'}); eq(newest(astra('chat',{peek=true,limit=1})).aloud,nil)
fails(function() sol('say',{text='x',aloud='yes'}) end,'aloud must be')
-- A peeking request (fh --wait polls) does not restart the turn clock but counts as activity.
astra('board'); jump(600)
assert(astra('status',{peek=true}).clock:find('+10s since your last request',1,true))
local function counted(name) for _,row in ipairs(op('mention_counts').agents) do if row.name==name then return row end end end
eq(counted('astra').last_request_tick,tick)
jump(300)
assert(astra('board').clock:find('+15s since your last request',1,true))
assert(astra('board').clock:find('+0s since',1,true))
-- The chat trailer on replies: shown when a newer message arrived, always on status, never consumed by peek.
astra('chat',{limit=100}); astra('chat',{limit=100}); astra('chat',{limit=100})
eq(astra('board').chat,nil)
grok('say',{text='new thing'})
eq(astra('board',{peek=true}).chat.unread,1)
eq(astra('board').chat.latest:sub(-9),'new thing'); eq(astra('board').chat,nil); eq(astra('status').chat.unread,1)

-- Alerts: attacks on our entities, my character being hit, groups, losses.
local biter={valid=true,name='small-biter'}
local enemy={name='enemy'}
runtime.on_event{name=12,tick=tick,entity={valid=true,name='stone-furnace',type='furnace',position={x=40,y=40},force=force},force=enemy,cause=biter,final_damage_amount=30}
local ac=runtime.bots.named('astra').character
runtime.on_event{name=12,tick=tick,entity=ac,force=enemy,cause=biter,final_damage_amount=12}
runtime.on_event{name=11,tick=tick,entity={valid=true,name='stone-furnace',position={x=41,y=40},force=force},cause=biter}
jump(60)
t=astra('status').team
assert(has(t.alerts,'you were hit 1 times (12 damage) by small-biter, 1s ago; health 250'),table.concat(t.alerts,' | '))
assert(has(t.alerts,'attack near (48,48) by small-biter: stone-furnace x1 hit 1 times, 30 damage, 1s ago'),table.concat(t.alerts,' | '))
assert(has(t.alerts,'attack near (16,16) by small-biter: character x1 hit 1 times'))
assert(has(t.alerts,'losses in (41,40) 1 destroyed: 1 stone-furnace by 1 small-biter'))
eq(astra('status').team,nil)
-- Every agent hears about the attack; only astra about her character.
t=sol('status').team
assert(has(t.alerts,'attack near (48,48)')); eq(has(t.alerts,'you were hit'),nil)
-- A dead agent still hears that its (last) character was hit.
runtime.on_event{name=12,tick=tick,entity=ac,force=enemy,cause=biter,final_damage_amount=300}
ac.valid=false
assert(has(astra('status').team.alerts,'you were hit 2 times (312 damage) by small-biter, 0s ago; your character died'))
-- A dead bot can still use the board (a plan needs a living character).
eq(astra('board_post',{kind='task',title='died at the chest',owner='astra'}).item.requested_by,'astra')
fails(function() astra('plan_run',{name='x'}) end,'')
ac.valid=true
-- A quiet minute starts a new incident at the same place.
jump(4000)
runtime.on_event{name=12,tick=tick,entity={valid=true,name='inserter',type='inserter',position={x=40,y=41},force=force},force=enemy,cause=biter,final_damage_amount=5}
t=sol('status').team
assert(has(t.alerts,'inserter x1 hit 1 times, 5 damage'),table.concat(t.alerts,' | '))

-- Who hears what on the stream: once per agent, in the first reply that
-- builds a team block (here: as after a hot deploy, nobody has seen it yet).
for _,h in pairs(storage.agent_harness.team_hints) do h.stream_note=nil; h.operator_note=nil end
t=sol('status').team
-- The operator channel too, once.
eq(has(t.reminders,'operator: '),'operator: ./fh operator "text" files a request with the operator, the people running the harness and the stream (harness bugs, tools you need, things viewers ask for that the team cannot do); answers come in the game chat as server:')
eq(has(t.reminders,'stream: '),'stream: viewers hear your say --aloud lines and confessions, spoken in your voice, and like hearing from you every few minutes; other chat and tells show on the stream only as text, which viewers read on screen, so write them as plain sentences with spaces between words')
eq((sol('status').team or {}).reminders,nil)
jump(3600); eq((sol('status').team or {}).reminders,nil)
-- Reminders: profile until display_name, glyph and color are set; once a minute.
t=grok('status').team
assert(has(t.reminders,'stream: '))
assert(has(t.reminders,'profile'))
eq(grok('status').team,nil)
jump(3600); assert(has(grok('status').team.reminders,'profile'))
grok('profile',{display_name='Grok',glyph='G',color='#1a1a1a'})
jump(3600); eq(grok('status').team,nil)

-- Harness requests: a board item owned by the operator; the operator answers
-- over RCON (no player) and the requester hears about it.
r=grok('harness_request',{title='collect should skip other agents chests',problem='radius collect emptied the boiler chest',proposal='an exclude_owned flag'})
eq(r.item.kind,'harness'); eq(r.item.owner,'operator'); eq(r.item.status,'open'); eq(r.item.problem,'radius collect emptied the boiler chest')
fails(function() grok('harness_request',{title='x'}) end,'problem is required')
eq(op('board',{kind='harness'}).items[1].title,'collect should skip other agents chests')
r=op('board_update',{id=r.item.id,status='done',note='harness v2: collect skips chests in claims'})
eq(r.item.status,'done')
t=grok('status').team
assert(has(t.board,'(your harness) done by operator: collect should skip other agents chests - harness v2: collect skips chests in claims'),table.concat(t.board,' | '))
fails(function() op('walk',{}) end,'operator requests support')
fails(function() request{action='board',args={},operator=true,player=1} end,'names no player')
fails(function() op('board',{bogus=1}) end,'unknown argument bogus')
local last=request{action='board_events',args={since_seq=0,limit=200},player=2}
eq(last.events[#last.events].kind,'harness'); eq(last.events[#last.events].change,'done')
eq(last.events[#last.events].text,'harness v2: collect skips chests in claims')

-- Confessions (audience.lua): the author and the operator read them; never chat, hints or teammates.
astra('status'); grok('status')
r=grok('confess',{text='@astra nobody reads the board but me'}); eq(r.seq,1)
fails(function() grok('confess',{text='again'}) end,'one confession every 15 s')
fails(function() astra('confess',{text='x',bogus=1}) end,'unknown argument bogus')
eq(grok('confessions').confessions[1].text,'@astra nobody reads the board but me'); eq(#astra('confessions').confessions,0)
eq(op('confessions',{}).confessions[1].from,'grok')
for _,m in ipairs(storage.agent_harness.chat.messages) do assert(not m.text:find('nobody reads',1,true),'confession leaked into chat') end
astra('chat',{limit=100})
t=astra('status'); eq(t.team,nil); eq(t.chat,nil)
-- Viewer relay: chat from "viewer NAME" for every agent, rate-limited; a
-- mention only for the agent it names with @ (grok and sol get none).
r=op('viewer_say',{name='bob',text='@astra you are doing great, grok too'}); eq(r.posted,true)
t=astra('status'); eq(t.team.mentions[1],'viewer bob @you, 0s ago: @astra you are doing great, grok too')
eq(t.chat.latest,'viewer bob: @astra you are doing great, grok too')
eq((grok('status').team or {}).mentions,nil)
local msgs=grok('chat',{limit=100}).messages; eq(msgs[#msgs].viewer,true); eq(msgs[#msgs].from,'viewer bob'); eq(msgs[#msgs].mention,nil)
op('viewer_say',{name='cy',text='@everyone hi'}); eq((sol('status').team or {}).mentions,nil)
eq(op('viewer_say',{name='bob',text='me again'}).dropped,'viewer_rate')
fails(function() request{action='viewer_say',args={name='bob',text='x'},bot='grok'} end,'unsupported action')

-- Saved plans: validated like queue plans, per agent, run as a queue submit.
local plan={{action='walk',args={direction='north',ticks=5}},{action='wait_ticks',args={ticks=10}}}
r=sol('plan_save',{name='north',steps=plan,note='step north'})
eq(r.steps,2)
fails(function() sol('plan_save',{name='bad',steps={{action='status'}}}) end,'not queueable')
fails(function() sol('plan_save',{name='bad name',steps=plan}) end,'name must be')
fails(function() sol('plan_save',{name='x',steps={}}) end,'non-empty')
eq(sol('plans').plans[1].name,'north'); eq(#astra('plans').plans,0)
eq(sol('plans',{name='north'}).steps[1].args.ticks,5)
fails(function() astra('plan_run',{name='north'}) end,'no saved plan north; save one')
r=sol('plan_run',{name='north'})
eq(r.plan,'north'); eq(#r.pending,2)
advance(1); eq(sol('status').active.kind,'walk')
advance(20)
eq(sol('plans').plans[1].runs,1)
eq(sol('plans',{name='north'}).steps[1].id,nil) -- the queue's ids never touch the saved copy
fails(function() sol('plan_run',{name='south'}) end,'saved: north')
for i=1,49 do sol('plan_save',{name='p'..i,steps=plan}) end
fails(function() sol('plan_save',{name='p50',steps=plan}) end,'at most 50')
sol('plan_save',{name='p1',delete=true})
sol('plan_save',{name='p50',steps=plan})
eq(#sol('plans').plans,50)

-- Bounds: at most 300 items, finished ones pruned first; titles never fail.
local before=storage.agent_harness.board.count
eq(grok('board',{kind='note'}).items[1].id,6)
for i=1,300-before+2 do grok('board_post',{kind='task',title='t'..i,owner='grok'}) end
eq(storage.agent_harness.board.count,300)
eq(grok('board',{id=1}).item.id,1) -- open #1 kept
fails(function() grok('board',{id=2}) end,'no board item #2') -- the two done items go first
eq(grok('board',{kind='harness'}).matched,0)
eq(grok('board',{id=6}).item.kind,'note') -- then notes
grok('board_post',{kind='task',title='one more',owner='grok'})
fails(function() grok('board',{id=6}) end,'no board item #6')
for i=1,40 do grok('board_post',{kind='task',title='u'..i,owner='grok'}) end
fails(function() grok('board',{id=1}) end,'no board item #1') -- then the oldest of anything
eq(storage.agent_harness.board.count,300)
eq(#storage.agent_harness.board.events<=1000,true)

-- describe lists the new actions; directors get no team block.
local d=runtime.dispatch{action='describe'}
assert(d.actions.board_post and d.actions.harness_request and d.actions.plan_run and d.actions.board_events)
eq(request{action='status',args={},player=2}.team,nil)
-- shake4: posts with note, or needs as {item: count}, failed on shape and were resent.
r=sol('board_post',{kind='request',title='plates for the mall',needs={['iron-plate']=200,['copper-plate']=100},note='at the mall chest'})
eq(r.item.needs[1].name,'copper-plate'); eq(r.item.needs[1].count,100); eq(r.item.needs[2].name,'iron-plate'); eq(r.item.needs[2].count,200)
eq(r.item.notes[1].text,'at the mall chest'); eq(r.item.notes[1].by,'sol')
fails(function() sol('board_post',{kind='task',title='x',needs={['iron-plate']='lots'}}) end,'maps item names to counts')
fails(function() sol('board_post',{kind='task',title='x',note='  '}) end,'note is required')

-- Board calls leave a running queue running (shake11 heads-up: "reading or posting on the board seems to stop the
-- queued plan"): reads, posts, updates, the plan, harness requests, tells, research reports.
do
  local index=runtime.bots.index_of('grok')
  local function running(label)
    local q=storage.agent_harness.queues and storage.agent_harness.queues[index]
    assert(q and not q.paused and (q.current or #q.pending>0),label..': the queue stopped')
    eq(grok('status').active.kind,'walk',label)
  end
  grok('queue_submit',{steps={{action='walk',args={direction='south',ticks=600}},{action='walk',args={direction='north',ticks=600}}}})
  advance(2)
  running('submitted')
  grok('board'); running('board')
  grok('board',{mine=true}); running('board mine')
  local id=grok('board_post',{kind='task',title='queue keeps running',owner='grok'}).item.id; running('board_post')
  grok('board_update',{id=id,note='still walking'}); running('board_update')
  grok('board_events',{}); running('board_events')
  grok('board_plan',{doing='walking south'}); running('board_plan')
  grok('board_plan'); running('board_plan read')
  grok('harness_request',{title='x',problem='y'}); running('harness_request')
  grok('tell',{to='sol',text='walking'}); running('tell')
  grok('tells'); running('tells')
  grok('plans'); running('plans')
  grok('research_done'); running('research_done')
  grok('mention_counts'); running('mention_counts')
  advance(1); running('a tick later')
  grok('stop')
end

-- shake11 (27640e9): once the loss incidents reached MAX_INCIDENTS (64), a new incident was appended without `last`,
-- the eviction compare failed on it and left it so, and then every status failed in losses_since
-- ('attempt to compare number with nil').
local wall_biter={valid=true,name='small-biter'}
local function lose(name,x,y) runtime.on_event{name=11,tick=tick,entity={valid=true,name=name,position={x=x,y=y},force=force},cause=wall_biter} end
storage.agent_harness.losses=nil
jump(20000)
for k=1,64 do lose('stone-wall',k*64+1,-1000); jump(1) end -- one incident per 64-tile cell
local losses=storage.agent_harness.losses
eq(#losses,64)
local first_key=losses[1].key
lose('gun-turret',1,-2000) -- the 65th: it is kept, the oldest goes
losses=storage.agent_harness.losses
eq(#losses,64)
for _,i in ipairs(losses) do assert(type(i.last)=='number','incident '..i.key..' has no last tick') end
eq(losses[#losses].names['gun-turret'],1)
for _,i in ipairs(losses) do assert(i.key~=first_key,'the oldest incident was evicted') end
jump(60)
local st=astra('status')
assert(has(st.alerts.latest,'1 gun-turret'),table.concat(st.alerts.latest,' | '))
assert(has(st.team.alerts,'losses in (1,-2000) 1 destroyed: 1 gun-turret'),table.concat(st.team.alerts,' | '))
eq(storage.agent_harness.runtime_fault,nil)
-- A save from before the fix keeps an incident with last=nil: status still works, it counts by its first tick (old
-- here), and it is the first evicted.
table.insert(storage.agent_harness.losses,1,{key='99,99',box={6336,6336,6336,6336},first=tick-100000,names={['stone-wall']=1},causes={},total=1})
table.remove(storage.agent_harness.losses,2)
st=astra('status')
assert(not has(st.alerts.latest,'(6336,6336)'))
sol('status'); astra('status',{since=0})
lose('stone-furnace',1,-3000)
eq(#storage.agent_harness.losses,64)
for _,i in ipairs(storage.agent_harness.losses) do assert(i.key~='99,99','the incident without last went first') end
assert(has(astra('status').team.alerts,'losses in (1,-3000) 1 destroyed: 1 stone-furnace'))
eq(storage.agent_harness.runtime_fault,nil)

-- Friendly fire (shake11-12: our flamethrower turrets burnt gun turrets, radars, belts and their own oil lines): a
-- cause of our own force is named apart from the enemy causes; with no cause left, the killing force tells.
local flamer={valid=true,name='flamethrower-turret',force=force}
local enemy_biter={valid=true,name='medium-biter',force={name='enemy'}}
local function died(name,x,y,cause,killer)
  runtime.on_event{name=11,tick=tick,entity={valid=true,name=name,position={x=x,y=y},force=force},cause=cause,force=killer}
end
died('gun-turret',5000,5000,flamer,force); died('radar',5001,5001,flamer,force); died('pipe',5002,5000,nil,force)
jump(60)
local line=has(astra('status').team.alerts,'(5000,5000)')
eq(line,'losses in (5000,5000)-(5002,5001) 3 destroyed: 1 gun-turret, 1 pipe, 1 radar by friendly fire: 2 flamethrower-turret, 1 unknown source, 1s ago')
died('transport-belt',6000,6000,enemy_biter,{name='enemy'}); died('transport-belt',6001,6000,flamer,force)
died('stone-wall',6002,6000,enemy_biter,{name='enemy'})
jump(60)
line=has(astra('status').team.alerts,'(6000,6000)')
eq(line,'losses in (6000,6000)-(6002,6000) 3 destroyed: 2 transport-belt, 1 stone-wall by 2 medium-biter, friendly fire: 1 flamethrower-turret, 1s ago')
-- status alerts carry the same lines; enemy-only lines read as before.
assert(has(astra('status').alerts.latest,'by 2 medium-biter, friendly fire: 1 flamethrower-turret'))
died('stone-wall',7000,7000,enemy_biter,{name='enemy'})
jump(60)
eq(has(astra('status').team.alerts,'(7000,7000)'),'losses in (7000,7000) 1 destroyed: 1 stone-wall by 1 medium-biter, 1s ago')
print('board: ok')
