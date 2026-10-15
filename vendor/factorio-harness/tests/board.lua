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
local gleba={name='gleba',index=5}
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
  get_surface=function(n) if n=='gleba' then return gleba elseif n=='mars' then return nil end return surface end,print=function() end,connected_players=players,
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
eq(r.item.surface,'nauvis','the poster\'s surface')
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
fails(function() grok('board_update',{id=1}) end,'give status, owner, note, allow, title, needs or (a claim) surface')
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
-- The plain read lists active items only and counts the finished (Foobator, d15 09:46).
local plain=request{action='board',args={},player=2}
eq(plain.matched,5); eq(plain.finished_left_out,'1 finished (done or dropped) left out: board {"status": "done"} (or "dropped", or {"full": true}) lists them')
for _,row in ipairs(plain.items) do assert(row.status~='done' and row.status~='dropped',row.status) end
eq(request{action='board',args={full=true},player=2}.matched,6)
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
assert(has(t.alerts,'attack #1 at (40,40): by small-biter; stone-furnace x1 hit 1 times, 30 damage, 1s ago'),table.concat(t.alerts,' | '))
assert(has(t.alerts,': by small-biter; no charted nest within 384 tiles; character x1 hit 1 times'))
assert(has(t.alerts,' in (41,40) 1 destroyed: 1 stone-furnace by 1 small-biter'))
assert(has(t.alerts,' in (41,40)'):find('^losses #%d+ in'))
eq(astra('status').team,nil)
-- Every agent hears about the attack; only astra about her character.
t=sol('status').team
assert(has(t.alerts,'attack #1 at (40,40)')); eq(has(t.alerts,'you were hit'),nil)
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
-- The nearest charted spawner is looked up once, at the incident's first hit by a unit.
local spawner={valid=true,name='biter-spawner',type='unit-spawner',position={x=200,y=41}}
local find=surface.find_entities_filtered
surface.find_entities_filtered=function(f) if f.type=='unit-spawner' and f.radius==384 then return {spawner} end return find(f) end
runtime.on_event{name=12,tick=tick,entity={valid=true,name='inserter',type='inserter',position={x=40,y=41},force=force,surface=surface},force=enemy,cause=biter,final_damage_amount=5}
surface.find_entities_filtered=find
t=sol('status').team
assert(has(t.alerts,'inserter x1 hit 1 times, 5 damage'),table.concat(t.alerts,' | '))
local id=has(t.alerts,'inserter x1'):match('^attack #(%d+) at %(40,41%)')
assert(id,table.concat(t.alerts,' | '))
-- More hits on the same incident: not repeated within 2 minutes, then once as "continues" with the totals.
-- Distinct attackers are counted by kind.
jump(600)
runtime.on_event{name=12,tick=tick,entity={valid=true,name='inserter',type='inserter',position={x=40,y=41},force=force,surface=surface},force=enemy,
  cause={valid=true,name='medium-biter',unit_number=9001},final_damage_amount=5}
runtime.on_event{name=12,tick=tick,entity={valid=true,name='inserter',type='inserter',position={x=40,y=41},force=force,surface=surface},force=enemy,
  cause={valid=true,name='small-biter',unit_number=9002},final_damage_amount=5}
runtime.on_event{name=12,tick=tick,entity={valid=true,name='inserter',type='inserter',position={x=40,y=41},force=force,surface=surface},force=enemy,
  cause={valid=true,name='small-biter',unit_number=9003},final_damage_amount=5}
jump(60)
t=sol('status').team
eq(t and has(t.alerts,'attack #'..id),nil)
jump(7200)
t=sol('status').team
local want='attack #'..id..' at (40,41) continues: 3 attackers seen (2 small-biter, 1 medium-biter); likely from nest (200,41) 160 tiles E; '
  ..'inserter x4 hit 4 times, 20 damage, first 2m11s ago, last 2m01s ago'
eq(has(t.alerts,want),want,table.concat(t.alerts,' | '))
eq(sol('status').team,nil)
-- Status alerts carry the same incident as fields.
local row=sol('status',{since=0}).alerts.attacked[1]
eq(row.attackers,3); eq(row.source.bearing,'E'); eq(row.at.y,41)
-- The defense read is reachable through dispatch and listed in describe.
eq(astra('defense').tick,tick); assert(astra('describe').actions.defense.returns)

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
assert(has(st.team.alerts,' in (1,-2000) 1 destroyed: 1 gun-turret'),table.concat(st.team.alerts,' | '))
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
assert(has(astra('status').team.alerts,' in (1,-3000) 1 destroyed: 1 stone-furnace'))
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
local function unnumbered(line) return line and (line:gsub('^losses #%d+ ','losses ')) end
local line=unnumbered(has(astra('status').team.alerts,'(5000,5000)'))
eq(line,'losses in (5000,5000)-(5002,5001) 3 destroyed: 1 gun-turret, 1 pipe, 1 radar by friendly fire: 2 flamethrower-turret, 1 unknown source, 1s ago')
died('transport-belt',6000,6000,enemy_biter,{name='enemy'}); died('transport-belt',6001,6000,flamer,force)
died('stone-wall',6002,6000,enemy_biter,{name='enemy'})
jump(60)
line=unnumbered(has(astra('status').team.alerts,'(6000,6000)'))
eq(line,'losses in (6000,6000)-(6002,6000) 3 destroyed: 2 transport-belt, 1 stone-wall by 2 medium-biter, friendly fire: 1 flamethrower-turret, 1s ago')
-- status alerts carry the same lines; enemy-only lines read as before.
assert(has(astra('status').alerts.latest,'by 2 medium-biter, friendly fire: 1 flamethrower-turret'))
died('stone-wall',7000,7000,enemy_biter,{name='enemy'})
jump(60)
eq(unnumbered(has(astra('status').team.alerts,'(7000,7000)')),'losses in (7000,7000) 1 destroyed: 1 stone-wall by 1 medium-biter, 1s ago')
-- Friendly fire names where the burning turret stands (shift 5-6: a pipe row burnt 8 times, no flamer named).
local flamer_at={valid=true,name='flamethrower-turret',force=force,position={x=8010,y=8004}}
died('pipe',8000,8000,flamer_at,force); died('pipe',8001,8000,flamer_at,force)
jump(60)
eq(unnumbered(has(astra('status').team.alerts,'(8000,8000)')),
  'losses in (8000,8000)-(8001,8000) 2 destroyed: 2 pipe by friendly fire: 2 flamethrower-turret at (8010,8004), 1s ago')
-- What the game removes on its own is no loss (Luna, 08:56: an emptied cargo pod's container vanished and was told as
-- friendly fire from an unknown source): no incident, no line.
runtime.on_event{name=11,tick=tick,entity={valid=true,name='cargo-pod-container',type='temporary-container',position={x=8500,y=8500},force=force},force=force}
runtime.on_event{name=11,tick=tick,entity={valid=true,name='item-on-ground',type='item-entity',position={x=8501,y=8500},force=force},force=force}
jump(60)
for _,l in ipairs(astra('status').team.alerts or {}) do assert(not l:find('(8500,8500)',1,true),l) end
for _,i in ipairs(astra('status').alerts.incidents or {}) do assert(i.box.x0~=8500,'no incident for the pod') end
-- Another surface is named, and a platform by its name.
runtime.on_event{name=11,tick=tick,entity={valid=true,name='stone-furnace',position={x=9000,y=9000},force=force,surface={name='vulcanus'}},cause=enemy_biter}
runtime.on_event{name=11,tick=tick,entity={valid=true,name='gun-turret',position={x=9000,y=9000},force=force,surface={name='platform-3',platform={name='Starling'}}},cause=enemy_biter}
jump(60)
local alerts=astra('status').team.alerts
eq(#(function() local n={} for _,l in ipairs(alerts) do if l:find('(9000,9000)',1,true) then n[#n+1]=l end end return n end)(),2)
assert(has(alerts,' on vulcanus in (9000,9000) 1 destroyed: 1 stone-furnace'),table.concat(alerts,' | '))
assert(has(alerts,' on platform Starling in (9000,9000) 1 destroyed: 1 gun-turret'),table.concat(alerts,' | '))
-- status alerts.incidents: rows for programs (the stream's loss banners). 12:58 on 2026-10-13: a small demolisher
-- destroyed Sol's 59 turrets on Vulcanus at (-223,74); the stream read the text as Nauvis and cut to an empty field.
local demolisher={valid=true,name='small-demolisher',force={name='enemy'}}
for k=0,58 do
  runtime.on_event{name=11,tick=tick,entity={valid=true,name='gun-turret',position={x=-223+k%10,y=74+math.floor(k/10)},force=force,surface={name='vulcanus'}},cause=demolisher}
end
runtime.on_event{name=11,tick=tick,entity={valid=true,name='stone-furnace',position={x=-223,y=74},force=force,surface={name='nauvis'}},cause=enemy_biter}
jump(60)
local st=astra('status',{since=tick-200})
local rows={}
for _,r in ipairs(st.alerts.incidents or {}) do
  local key=r.platform and r.surface..'/'..r.platform or r.box.x0==-223 and r.surface or nil
  if key then rows[key]=r end
end
local v=rows.vulcanus
eq(v.total,59); eq(v.box.x0,-223); eq(v.box.y0,74); eq(v.box.x1,-214); eq(v.box.y1,79); eq(v.names,'59 gun-turret'); eq(v.by,'59 small-demolisher')
eq(v.platform,nil); assert(v.id and v.first_tick and v.last_tick)
assert(v.line:find('^#%d+ on vulcanus in %(%-223,74%)%-%(%-214,79%) 59 destroyed: 59 gun%-turret by 59 small%-demolisher'),v.line)
local n=rows.nauvis
eq(n.total,1); eq(n.box.x0,-223); assert(n.line:find('^#%d+ in %(%-223,74%) 1 destroyed'),n.line)
eq(rows['platform-3/Starling'].platform,'Starling')
-- The same lines in latest, the row's line; an operator read (no character's surface) names any surface but nauvis.
assert(has(st.alerts.latest,'on vulcanus in (-223,74)'))

-- Claims live on their owner's activity (agent-minds study: 67 claims open at the end of shift07, 60 untouched all
-- shift): stale after 30 min (stock sweeps include it), closed by the harness after 2 h; allow lists.
local function body(name) return runtime.bots.lookup(runtime.bots.index_of(name)).character end
-- A claim from before this runtime (no activity kept, updated 5 h ago) counts from the deploy: nothing closes at once.
local legacy=sol('board_post',{kind='claim',title='old mall',area={left_top={x=30000,y=0},right_bottom={x=30010,y=10}}}).item
local stored=storage.agent_harness.board.items[legacy.id]
stored.active_tick=nil; stored.updated_tick=tick-5*216000; stored.created_tick=stored.updated_tick
jump(60)
-- whatever reads it first (here collect's claim check, before any board read) starts its timers
assert(runtime.claims.other({name='grok',surface=surface},{x=30005,y=5}),'fresh from the deploy: it binds')
eq(stored.active_tick,tick)
local item=astra('board',{id=legacy.id}).item
eq(item.status,'claimed'); eq(item.owner_active,'0s ago'); eq(item.stale,nil)
local home=body('sol').position
local c=sol('board_post',{kind='claim',title='north smelting',area={left_top={x=10000,y=10000},right_bottom={x=10020,y=10020}}}).item
eq(c.owner_active,'0s ago'); eq(c.stale,nil)
local w=astra('board_post',{kind='claim',title='overlap',area={left_top={x=10010,y=10010},right_bottom={x=10030,y=10030}}})
local warn=has(w.warnings,'overlaps claim #'..c.id..' by sol: north smelting (')
assert(warn and warn:find('owner active on it 0s ago, sol last request 0s ago',1,true),table.concat(w.warnings,' | '))
astra('board_update',{id=w.item.id,status='dropped'})
jump(31*3600)
item=astra('board',{id=c.id}).item
eq(item.stale,true); eq(item.owner_active,'31m00s ago')
assert(runtime.claims.find({name='grok',surface=surface},{x=10001,y=10001}),'a stale claim is still found')
eq(runtime.claims.other({name='grok',surface=surface},{x=10001,y=10001}),nil) -- but binds nobody
assert(runtime.claims.label(c and storage.agent_harness.board.items[c.id],{name='grok'}):find('stale: stock sweeps include it; closes 1h29m from now',1,true))
-- Sol hears it in one batched line; its requests elsewhere keep nothing fresh; standing in the claim does, and so
-- does acting on a position in it.
local digest=has(sol('status').team.board,'your claims: stale after 30 min without your activity')
assert(digest and digest:find('#'..c.id..' north smelting',1,true),digest)
eq(astra('board',{id=c.id}).item.stale,true)
body('sol').position={x=10005,y=10005}
sol('status')
eq(astra('board',{id=c.id}).item.owner_active,'0s ago')
body('sol').position=home
jump(31*3600)
sol('labs',{position={x=10002,y=10002},radius=4})
eq(astra('board',{id=c.id}).item.owner_active,'0s ago')
-- and so does the owner's board update; someone else's note does not
jump(31*3600)
astra('board_update',{id=c.id,note='taking 50 plates from here'})
eq(astra('board',{id=c.id}).item.stale,true)
sol('board_update',{id=c.id,note='still mine'})
eq(astra('board',{id=c.id}).item.stale,nil)
assert(runtime.claims.other({name='grok',surface=surface},{x=10001,y=10001}),'fresh again: it binds')
-- allow: the owner names agents its labels show as allowed (their stock sweeps include it)
fails(function() astra('board_update',{id=c.id,allow='astra'}) end,'only the owner (sol) can change who claim #'..c.id..' allows')
fails(function() astra('board_post',{kind='task',title='x',allow='sol'}) end,'allow is for a claim')
local r=sol('board_update',{id=c.id,allow='Astra'})
eq(r.item.allow[1],'astra'); eq(r.changed[1],'allow')
eq(runtime.claims.other({name='astra',surface=surface},{x=10001,y=10001}),nil)
assert(runtime.claims.other({name='grok',surface=surface},{x=10001,y=10001}))
assert(runtime.claims.label(storage.agent_harness.board.items[c.id],{name='astra'}):find('allows astra, you are allowed',1,true))
r=sol('board_update',{id=c.id,allow='everyone'}); eq(r.item.allow[1],'everyone')
eq(runtime.claims.other({name='grok',surface=surface},{x=10001,y=10001}),nil)
r=sol('board_update',{id=c.id,allow={}}); eq(r.item.allow,nil)
local c2=grok('board_post',{kind='claim',title='oil',allow={'sol','nick','Sol'},area={left_top={x=20000,y=0},right_bottom={x=20010,y=10}}}).item
eq(table.concat(c2.allow,','),'nick,sol')
fails(function() grok('board_post',{kind='claim',title='oil',allow={'sol','nobody'},area={left_top={x=20000,y=0},right_bottom={x=20010,y=10}}}) end,'unknown agent nobody')
-- 2 h with no activity by its owner: the harness closes it, and its owner hears so.
local seq0=op('board_events',{since_seq=0,limit=1}).latest
jump(120*3600)
local lines=sol('status').team.board
digest=has(lines,'your claims: closed after 2h without your activity: ')
assert(digest and digest:find('#'..c.id..' north smelting',1,true),table.concat(lines or {},' | '))
eq(has(lines,'expired'),nil)
eq(astra('board',{id=c.id}).item.status,'dropped')
local expired
for _,e in ipairs(op('board_events',{since_seq=seq0,limit=200}).events) do if e.id==c.id and e.change=='expired' then expired=e end end
assert(expired and expired.by=='harness' and expired.text:find('^closed by the harness: no activity by its owner for 2h'),expired and expired.text)
eq(runtime.claims.find({name='grok',surface=surface},{x=10001,y=10001}),nil)
-- Many claims closing at once: one line for their owner, never one per claim.
astra('status'); jump(3*3600)
local mine={}
for k=1,8 do
  mine[k]=astra('board_post',{kind='claim',title='lot '..k,area={left_top={x=40000+20*k,y=0},right_bottom={x=40010+20*k,y=10}}}).item.id
end
jump(120*3600)
lines=astra('status').team.board or {}
local claim_lines=0
for _,l in ipairs(lines) do if l:find('claim',1,true) then claim_lines=claim_lines+1 end end
eq(claim_lines,1)
digest=has(lines,'your claims: closed after 2h without your activity: #'..mine[1]..' lot 1, #'..mine[2]..' lot 2')
assert(digest and digest:find(', +2 more',1,true),table.concat(lines,' | '))
-- Stale marks a minute apart: the second waits for the next line, at most one every 3 min.
local a1=astra('board_post',{kind='claim',title='east',area={left_top={x=50000,y=0},right_bottom={x=50010,y=10}}}).item.id
jump(60)
local a2=astra('board_post',{kind='claim',title='west',area={left_top={x=50100,y=0},right_bottom={x=50110,y=10}}}).item.id
jump(30*3600-60)
digest=has(astra('status').team.board,'your claims: stale')
assert(digest and digest:find('#'..a1..' east',1,true) and not digest:find('west',1,true),digest)
jump(61)
eq(has((astra('status').team or {}).board,'your claims'),nil)
jump(2*3600)
eq(has((astra('status').team or {}).board,'your claims'),nil)
jump(3600)
digest=has(astra('status').team.board,'your claims: stale')
assert(digest and digest:find('#'..a2..' west',1,true) and not digest:find('east',1,true),digest)
-- told once per stretch: no more lines while they stay stale
jump(10*3600)
eq(has((astra('status').team or {}).board,'your claims'),nil)

-- A task whose owner has made no request for 20 min can be taken by anyone (shift07: #284 power held two shifts).
local t=grok('board_post',{kind='task',title='power line',owner='grok'}).item
grok('board_update',{id=t.id,status='doing'})
fails(function() astra('board_update',{id=t.id,owner='astra'}) end,'#'..t.id..' is owned by grok (last request 0s ago); only its owner or requester can reassign it')
jump(20*3600-1)
astra('status'); sol('status') -- others' requests don't count
fails(function() astra('board_update',{id=t.id,owner='astra'}) end,'(last request 19m59s ago)')
jump(1)
r=astra('board_update',{id=t.id,owner='astra'})
eq(r.item.owner,'astra'); eq(r.item.status,'doing'); eq(r.changed[1],'taken')
eq(r.item.notes[#r.item.notes].text,'taken from grok (last request 20m00s ago)')
local heard=grok('status').team.board
assert(has(heard,'#'..t.id..' (your task) taken by astra: power line - taken from grok (last request 20m00s ago)'),table.concat(heard or {},' | '))
-- only for yourself: a quiet owner's item is not reassigned to a third agent
jump(20*3600)
fails(function() sol('board_update',{id=t.id,owner='grok'}) end,'only its owner or requester can reassign it')
-- an asleep owner reads as such
grok('sleep',{seconds=600})
eq(runtime.board.owner_state('grok'),'asleep 0s')
eq(runtime.board.owner_state('operator'),nil)

-- An fyi tell waits for the next reply and wakes nobody; supervisors count it apart.
sol('status'); grok('sleep_check',{}); grok('status')
r=grok('tell',{to='sol',text='belts done',fyi=true})
assert(r.note:find('^fyi: '),r.note)
fails(function() grok('tell',{to='sol',text='x',fyi='yes'}) end,'fyi must be true or false')
local row
for _,a in ipairs(op('mention_counts',{}).agents) do if a.name=='sol' then row=a end end
eq(row.fyi,1); eq(row.tells,nil); eq(row.unread_mentions,0); eq(row.oldest_tick,nil)
assert(has(sol('status').team.tells,'grok (fyi), 0s ago: belts done'))
sol('sleep',{seconds=30})
grok('tell',{to='sol',text='routine: belts still fine',fyi=true})
advance(5)
eq(sol('sleep_check',{peek=true}).woke,nil)
grok('tell',{to='sol',text='need you at the furnaces'})
advance(5)
eq(sol('sleep_check',{peek=true}).woke,'told')
eq(op('tells',{since=0,limit=100}).tells[#op('tells',{since=0,limit=100}).tells-1].fyi,true)
-- science (labs.lua) is reached as an action and as an observe scope, with its arguments checked
prototypes=prototypes or {item={}}
fails(function() astra('science',{pack='nope-pack'}) end,'pack must be an item name')
fails(function() astra('observe',{scope='science',pack='nope-pack'}) end,'pack must be an item name')
fails(function() astra('science',{packs='x'}) end,'unknown argument packs for science')
assert(astra('describe').actions.science.pack)
-- silo (silo.lua) is a read reached as an action, with its arguments checked
fails(function() astra('silo',{}) end,'no rocket silo of ours on')
fails(function() astra('silo',{radius=5}) end,'unknown argument radius for silo')
assert(astra('describe').actions.silo.position and astra('describe').actions.silo.surface)

-- Projects (operator 00:50): long jobs that outlive a context and a shift: a goal, steps anyone adds and marks done
-- (who did each), areas, notes and the owner's handoff; the plain listing and the shift block show a line each.
jump(3600); astra('status'); sol('status'); grok('status')
local pj=sol('board_post',{kind='project',title='nuclear plant',goal='uranium power for the main bus',
  steps={'mine uranium','centrifuges','reactor and exchangers'},area={left_top={x=100,y=100},right_bottom={x=160,y=140}}}).item
eq(pj.kind,'project'); eq(pj.status,'open'); eq(pj.owner,nil); eq(pj.progress,'0 of 3 steps'); eq(pj.goal,'uranium power for the main bus')
eq(pj.steps[1],'[ ] 1. mine uranium'); eq(#pj.steps,3); eq(pj.areas[1].left_top.x,100); eq(pj.area,nil); eq(pj.goal_edited,'by sol, 0s ago')
-- everyone else hears of it once, as news
assert(has(astra('status').team.board,'#'..pj.id..' new project by sol: nuclear plant (no owner; 0 of 3 steps)'))
eq(has((sol('status').team or {}).board,'new project'),nil)
eq(has((astra('status').team or {}).board,'new project'),nil)
-- a project's arguments are for projects; done takes the numbers of its steps
fails(function() sol('board_post',{kind='task',title='x',steps={'a'}}) end,'goal, steps, areas and handoff are for kind project')
fails(function() grok('board_update',{id=t.id,done=1}) end,'done is for a project (#'..t.id..' is a task); status "done" finishes an item')
fails(function() astra('board_update',{id=pj.id,done=true}) end,'done takes step numbers: a number or an array of them (status "done" finishes the project)')
fails(function() astra('board_update',{id=pj.id,done=9}) end,'project #'..pj.id..' has no step 9; its steps: 1, 2, 3')
fails(function() astra('board_update',{id=pj.id}) end,'give status, owner, note, allow, title, needs or (a claim) surface; for a project also step, done, undone')
fails(function() astra('board_update',{id=pj.id,done={1,9}}) end,'has no step 9')
eq(astra('board',{id=pj.id}).item.progress,'0 of 3 steps') -- a bad argument changes nothing
-- anyone adds steps and marks them done; who did each shows
jump(60)
r=astra('board_update',{id=pj.id,done=1,step={'turbines','pumps to the exchangers'}})
eq(r.item.progress,'1 of 5 steps'); eq(r.item.steps[1],'[x] 1. mine uranium (done by astra, 0s ago)'); eq(r.item.steps[5],'[ ] 5. pumps to the exchangers')
eq(r.changed[1],'step_added'); eq(r.changed[2],'step_done')
local last=op('board_events',{since_seq=op('board_events',{limit=1}).latest-1}).events[1]
eq(last.change,'step_done'); eq(last.text,'1. mine uranium'); eq(last.progress,'1 of 5 steps'); eq(last.steps_done,1); eq(last.steps_total,5)
-- the poster hears step changes as news; they wake nobody
local heard=sol('status').team.board
assert(has(heard,'#'..pj.id..' (your project) step done by astra: nuclear plant - 1. mine uranium (1 of 5 steps)'),table.concat(heard or {},' | '))
assert(has(heard,'#'..pj.id..' (your project) step added by astra: nuclear plant - 4. turbines; 5. pumps to the exchangers (1 of 5 steps)'))
sol('sleep',{seconds=30}); grok('board_update',{id=pj.id,done={2}}); advance(5)
eq(sol('sleep_check',{peek=true}).woke,nil)
jump(1800); sol('status')
r=grok('board_update',{id=pj.id,undone=2,note='centrifuges lack power'})
eq(r.item.progress,'1 of 5 steps'); eq(r.item.notes[#r.item.notes].text,'centrifuges lack power'); eq(r.changed[1],'step_undone')
-- board with an id and a project change is board_update
eq(grok('board',{id=pj.id,done=2}).item.progress,'2 of 5 steps')
eq(grok('board',{id=pj.id,undone=2}).item.progress,'1 of 5 steps')
-- a project keeps its last 20 notes
for k=1,22 do grok('board_update',{id=pj.id,note='n'..k}) end
eq(#grok('board',{id=pj.id}).item.notes,20)
-- anyone takes an open unowned project; its goal, handoff and areas are then the owner's
r=sol('board_update',{id=pj.id,owner='sol'}); eq(r.item.owner,'sol'); eq(r.item.status,'claimed')
r=sol('board_update',{id=pj.id,handoff='uranium mined at (120,110); centrifuges placed, no power yet'})
eq(r.item.handoff_edited,'by sol, 0s ago'); eq(r.changed[1],'handoff')
fails(function() astra('board_update',{id=pj.id,goal='x'}) end,
  'only the owner edits the goal, handoff and areas of #'..pj.id..' until its owner has made no request for 30 min; #'..pj.id..' is owned by sol (last request 0s ago)')
fails(function() astra('board_update',{id=pj.id,areas={}}) end,'only the owner edits the goal, handoff and areas')
-- a step another agent added: only that agent or the owner removes it
fails(function() grok('board_update',{id=pj.id,remove_step=4}) end,'step 4 of #'..pj.id..' was added by astra: only astra or the owner removes it until')
r=astra('board_update',{id=pj.id,remove_step=4,done=4})
eq(r.item.progress,'1 of 4 steps'); eq(r.item.steps[4],'[ ] 5. pumps to the exchangers') -- numbers stay with their steps
eq(#r.changed,1) -- a step removed in the same update is not marked
-- 30 min without a request by its owner: anyone edits the goal, handoff and areas and may take it (20 min is not enough)
jump(20*3600)
fails(function() astra('board_update',{id=pj.id,goal='x'}) end,'until its owner has made no request for 30 min; #'..pj.id..' is owned by sol (last request 20m00s ago)')
fails(function() astra('board_update',{id=pj.id,owner='astra'}) end,'only its owner or requester can reassign it (anyone can take an open unowned item, or one whose owner has made no request for 30 min)')
jump(10*3600)
r=astra('board_update',{id=pj.id,goal='power for the bus and the rail yard',areas={{left_top={x=100,y=100},right_bottom={x=180,y=150}},{left_top={x=0,y=0},right_bottom={x=5,y=5}}}})
eq(r.item.goal,'power for the bus and the rail yard'); eq(r.item.goal_edited,'by astra, 0s ago'); eq(#r.item.areas,2); eq(r.item.owner,'sol')
heard=sol('status').team.board
assert(has(heard,'#'..pj.id..' (your project) goal by astra: nuclear plant - power for the bus and the rail yard (1 of 4 steps)'),table.concat(heard or {},' | '))
assert(has(heard,'#'..pj.id..' (your project) areas by astra: nuclear plant - 2 areas (1 of 4 steps)'))
jump(30*3600)
r=astra('board_update',{id=pj.id,owner='astra'}); eq(r.item.owner,'astra'); eq(r.changed[1],'taken')
assert(r.item.notes[#r.item.notes].text:find('taken from sol (last request 30m00s ago)',1,true),r.item.notes[#r.item.notes].text)
-- the plain listing: a line per open project, the reader's own first; the rows leave them out
local p2=grok('board_post',{kind='project',title='robot mall',owner='grok',steps='roboports'}).item
eq(p2.status,'claimed'); eq(p2.progress,'0 of 1 step')
r=astra('board',{})
eq(r.projects[1],'#'..pj.id..' nuclear plant: 1 of 4 steps; owner astra (last request 0s ago); next 2. centrifuges; handoff: uranium mined at (120,110); centrifuges placed, no power yet')
eq(r.projects[2],'#'..p2.id..' robot mall: 0 of 1 step; owner grok (last request 0s ago); next 1. roboports')
for _,row in ipairs(r.items) do assert(row.kind~='project',row.title) end
r=sol('board',{})
assert(r.projects[1]:find('^#'..p2.id..' robot mall'),r.projects[1]) -- the newest first for a reader who owns none
-- a project row: progress, the next 3 steps not done, the goal and handoff cut to 160
r=astra('board',{kind='project'})
eq(#r.items,2); eq(r.items[1].id,p2.id); eq(r.items[2].next_steps[1],'[ ] 2. centrifuges'); eq(r.items[2].steps,nil); eq(r.items[2].owner_state,'last request 0s ago')
-- the operator's listing has the rows
local found
for _,row in ipairs(op('board',{limit=100}).items) do if row.id==pj.id then found=row end end
eq(found.progress,'1 of 4 steps')
-- the first reply of a shift lists the open projects
runtime.operator.shift_start()
local sh=astra('status').team.shift
eq(sh.projects[1],'#'..pj.id..' nuclear plant: 1 of 4 steps; owner astra (last request 0s ago); next 2. centrifuges; handoff: uranium mined at (120,110); centrifuges placed, no power yet')
eq(#sh.projects,2)
-- d15 (Foobator, joonazan): blocked_by and parent links, step owners, parallel steps, the compact line, open steps.
do
  local p3=sol('board_post',{kind='project',title='Aquilo landing',owner='sol',parent=pj.id,blocked_by={p2.id},open_steps=true,
    steps={'stage the kit',{text='ride the rocket',parallel=true},{text='drop the heaters',parallel=true,owner='nick'},'build the base'}}).item
  eq(p3.blocked_by[1],p2.id); eq(p3.parent,pj.id); eq(p3.open_steps,true)
  sol('board_update',{id=p3.id,done=1})
  local line
  for _,l in ipairs(sol('board',{projects='compact'}).projects) do if l:find('Aquilo',1,true) then line=l end end
  eq(line,'#'..p3.id..' Aquilo landing [sol] 1/4; next 2. ride the rocket | 3. drop the heaters @nick; blocked by #'..p2.id..' robot mall (claimed, 0 of 1 step); part of #'..pj.id..' nuclear plant; steps open to all')
  local r3=grok('board',{})
  assert(r3.open_steps and r3.open_steps[1]:find('#'..p3.id..' step 2: ride the rocket (owner sol; take it with board_update {id: '..p3.id..', take_step: 2})',1,true),tostring(r3.open_steps and r3.open_steps[1]))
  local u=grok('board_update',{id=p3.id,take_step=2}); eq(u.changed[1],'step_taken')
  fails(function() grok('board_update',{id=p3.id,take_step=3}) end,'step 3 of #'..p3.id..' is taken by nick')
  sol('board_update',{id=p3.id,open_steps=false})
  fails(function() astra('board_update',{id=p3.id,take_step=4}) end,'its owner opens the steps to all with open_steps: true')
  fails(function() sol('board_update',{id=p3.id,blocked_by={p3.id}}) end,'does not wait for itself')
  eq(sol('board_update',{id=p3.id,blocked_by={}}).item.blocked_by,nil)
  sol('board_update',{id=p3.id,status='dropped'})
end
-- a finished project leaves the lines; the board keeps at most 30 open projects
r=astra('board_update',{id=pj.id,status='done',note='4 reactors running'})
eq(#astra('board',{}).projects,1)
for k=1,29 do grok('board_post',{kind='project',title='p'..k}) end
fails(function() grok('board_post',{kind='project',title='one more'}) end,'the board holds at most 30 open projects')
eq(#astra('board',{}).projects,9); eq(astra('board',{}).projects[9],'+22 more: board {kind: "project"}')
-- open projects outlast the cap: 300 tasks later p2 is still there, the finished one is not
for k=1,300 do grok('board_post',{kind='task',title='filler '..k}) end
assert(grok('board',{id=p2.id}).item)
fails(function() grok('board',{id=pj.id}) end,'no board item #'..pj.id)
-- Title and needs (Astra, shift10: a request's ask could not be corrected after posting):
-- its poster, owner or the operator; anyone once the one responsible has made no request for 20 min.
local rq=sol('board_post',{kind='request',title='need 100 green circuits',needs={['electronic-circuit']=100}})
local rid=rq.item.id
fails(function() grok('board_update',{id=rid,title='x'}) end,'only its poster (sol), its owner (none) or the operator changes the title and needs of #'..rid)
r=sol('board_update',{id=rid,title='need 200 green circuits',needs={{name='electronic-circuit',count=200},{name='copper-cable',count=50}}})
eq(r.item.title,'need 200 green circuits'); eq(r.item.needs[1].count,200); eq(r.changed[1],'title_changed'); eq(r.changed[2],'needs_changed')
eq(r.item.history[1],"title changed by sol: 'need 100 green circuits' -> 'need 200 green circuits' (0s ago)")
eq(r.item.history[2],'needs changed by sol: electronic-circuit*100 -> electronic-circuit*200, copper-cable*50 (0s ago)')
fails(function() sol('board_update',{id=rid,title='  '}) end,'title is required')
eq(sol('board',{id=rid}).item.title,'need 200 green circuits') -- a bad title changes nothing
-- Taken by grok: grok edits; astra may not while grok is active, and may once grok is quiet for 20 min.
grok('board_update',{id=rid,owner='grok'})
grok('board_update',{id=rid,title='need 200 green circuits at (10,4)'})
-- The poster is told, with the old title.
assert(has(sol('status').team.board,'#'..rid..' (your request) title changed by grok: need 200 green circuits at (10,4) - was: need 200 green circuits'))
fails(function() astra('board_update',{id=rid,needs=''}) end,'or anyone once grok has made no request for 20 min')
jump(20*3600+60); sol('status'); astra('status')
r=astra('board_update',{id=rid,needs=''})
eq(r.item.needs,nil); eq(r.changed[1],'needs_changed')
eq(r.item.history[4],'needs changed by astra: electronic-circuit*200, copper-cable*50 -> none (0s ago)')
-- The owner is told, with the old value.
assert(has(grok('status').team.board,'#'..rid..' (yours) needs changed by astra: need 200 green circuits at (10,4) - none (was electronic-circuit*200, copper-cable*50)'))
-- The operator edits anything; the team plan is board_plan's.
r=op('board_update',{id=rid,title='need 50 green circuits'}); eq(r.item.title,'need 50 green circuits')
local plan_id
for id,item in pairs(storage.agent_harness.board.items) do if item.kind=='plan' then plan_id=id end end
if plan_id then fails(function() sol('board_update',{id=plan_id,title='x'}) end,'the team plan changes with board_plan') end
-- plan_ticks (the pog site's Team plan, viewer Alex 22:12): the plan also as lines with the tick each was set, the goals'
-- tick and the last edit's; without it the plan is as before.
do
  local t0=game.tick
  sol('board_plan',{goals='rockets: blue science line'})
  jump(600)
  astra('board_plan',{doing='blue circuits at (40,-20)'})
  jump(60)
  sol('board_plan',{agent='grok',doing='oil outpost'})
  local p=sol('board',{limit=5,plan_ticks=true}).plan
  eq(p.goals_tick,t0); eq(p.updated_tick,game.tick)
  local by={}
  for _,l in ipairs(p.lines) do by[l.agent]=l end
  eq(by.astra.text,'blue circuits at (40,-20)'); eq(by.astra.tick,t0+600); eq(by.astra.by,'astra')
  eq(by.grok.tick,game.tick); eq(by.grok.by,'sol')
  local plain=sol('board',{limit=5}).plan
  eq(plain.lines,nil); eq(plain.goals_tick,nil); assert(plain.doing and #plain.doing==#p.lines,'doing as before')
  fails(function() sol('board',{limit=5,plan_ticks='yes'}) end,'plan_ticks must be true or false')
end
-- A claim is on one surface (Sol 07:52: Astra's Nauvis claim #212 labelled Gleba furnaces at (62,22)): the poster's, or
-- `surface`; overlaps count on that surface only; its owner moves it with board_update {surface}; one from before
-- claims had a surface gets its owner's surface the first time it is read, else nauvis.
do
  local soc=storage.agent_harness.bots.by_name.sol.character
  soc.surface=gleba
  local g=sol('board_post',{kind='claim',title='gleba furnaces',area={left_top={x=50,y=10},right_bottom={x=70,y=30}}})
  eq(g.item.surface,'gleba','posted on gleba'); eq(g.warnings,nil)
  soc.surface=surface
  local n=grok('board_post',{kind='claim',title='iron east',area={left_top={x=55,y=15},right_bottom={x=75,y=35}}})
  eq(n.item.surface,'nauvis'); eq(n.warnings,nil,'the gleba claim is not in the way on nauvis')
  local g2=grok('board_post',{kind='claim',title='gleba beds',area={left_top={x=55,y=15},right_bottom={x=60,y=20}},surface='gleba'})
  eq(g2.item.surface,'gleba'); assert(has(g2.warnings,'overlaps claim #'..g.item.id..' by sol'),table.concat(g2.warnings or {},' | '))
  fails(function() grok('board_post',{kind='claim',title='x',area={left_top={x=0,y=0},right_bottom={x=1,y=1}},surface='mars'}) end,'surface must be a surface name')
  fails(function() grok('board_post',{kind='task',title='x',surface='gleba'}) end,'surface is for a claim')
  fails(function() grok('board_update',{id=g.item.id,surface='nauvis'}) end,'only the owner (sol) can change the surface of claim #'..g.item.id)
  local t=sol('board_post',{kind='task',title='weed the beds'})
  fails(function() sol('board_update',{id=t.item.id,surface='nauvis'}) end,'surface is for a claim')
  eq(sol('board_update',{id=g.item.id,surface='nauvis'}).item.surface,'nauvis')
  eq(sol('board_update',{id=g.item.id,surface='gleba'}).item.surface,'gleba')
  local item=storage.agent_harness.board.items[g.item.id]
  item.surface=nil; soc.surface=gleba
  eq(sol('board',{id=g.item.id}).item.surface,'gleba','an old claim: where its owner is')
  soc.surface=surface; eq(item.surface,'gleba','set once')
  -- The owner's work keeps a claim fresh on its surface only: at the same coordinates on nauvis it does not.
  item.active_tick=tick-100
  runtime.claims.worked({name='sol',surface=surface,character={valid=true,position={x=60,y=20},surface=surface}},{position={x=60,y=20}})
  eq(item.active_tick,tick-100,'nauvis work does not keep a gleba claim')
  runtime.claims.worked({name='sol',surface=gleba,character={valid=true,position={x=60,y=20},surface=gleba}},{})
  eq(item.active_tick,tick)
  eq(runtime.claims.other({name='grok',surface=surface},{x=60,y=20}),nil,'nor binds on nauvis')
  eq(runtime.claims.other({name='grok',surface=gleba},{x=60,y=20}).id,g.item.id)
  -- An old claim whose owner's surface holds none of our buildings in its area, while exactly one other planet's does
  -- (world n 08:05: Luna on Gleba, her claim #111 built only on Nauvis): that planet.
  game.surfaces={nauvis=surface,gleba=gleba}
  local built={nauvis=true}
  for _,sf in ipairs({surface,gleba}) do
    sf.count_entities_filtered=function(f) eq(f.limit,1); eq(f.force,'player'); eq(f.area[1].x,50); return built[sf.name] and 1 or 0 end
  end
  item.surface=nil; soc.surface=gleba; item.title='furnace row'
  eq(sol('board',{id=g.item.id}).item.surface,'nauvis','built only on nauvis')
  built={nauvis=true,gleba=true}; item.surface=nil
  eq(sol('board',{id=g.item.id}).item.surface,'gleba','built on both: where its owner is')
  built={}; item.surface=nil
  eq(sol('board',{id=g.item.id}).item.surface,'gleba','built on neither: where its owner is')
  -- The one planet its title names comes first ("Gleba landing power", world n #364); two named: as above.
  built={}; item.surface=nil; item.title='Nauvis lab expansion'
  eq(sol('board',{id=g.item.id}).item.surface,'nauvis','named in the title')
  item.surface=nil; item.title='Gleba to Nauvis seed belt'
  eq(sol('board',{id=g.item.id}).item.surface,'gleba','two planets named: where its owner is')
  surface.count_entities_filtered,gleba.count_entities_filtered,game.surfaces=nil,nil,nil
  soc.surface=surface
end
print('board: ok')
