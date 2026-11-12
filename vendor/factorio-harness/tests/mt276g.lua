-- mt276 G (private: multi-team phase 2, part G). Run from the harness root: lua tests/mt276g.lua
-- Contact for agents: a first contact (chart or hit) reaches the teams it concerns as a fact line; another player
-- force's entity is named with its force in losses; the rules of contact go out only on the operator's mt_rules.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part,m) assert(tostring(s):find(part,1,true),(m or 'missing')..': '..part..' in '..tostring(s)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

local function force(name,spawn)
  return {name=name,valid=true,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
    get_spawn_position=function() return spawn or {x=0,y=0} end,players={},platforms={},technologies={},recipes={}}
end

do
  storage={agent_harness={active={}}}
  defines={events={on_script_path_request_finished=10,on_entity_died=11,on_console_chat=12},shooting={not_shooting=0,shooting_enemies=1},
    controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1,character_main=1},build_mode={normal=1},build_check_type={manual=1},
    flow_precision_index={five_seconds=0,one_minute=1},alert_type={}}
  rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
  remote={interfaces={}}
  helpers={json_to_table=function(t) return t end,table_to_json=function() return '{}' end,write_file=function() end}
  log=function() end
  local red,blue=force('red',{x=-1000,y=0}),force('blue',{x=1000,y=0})
  local player=force('player')
  local surface={name='nauvis',index=1,valid=true}
  surface.find_non_colliding_position=function(_,origin) return {x=origin.x,y=origin.y} end
  local unit=100
  surface.create_entity=function(args)
    unit=unit+1
    local c={valid=true,name=args.name,type='character',force=args.force,surface=surface,position=args.position,unit_number=unit,walking_state={walking=false}}
    c.insert=function(s) return s.count end
    c.get_main_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end
    c.get_inventory=c.get_main_inventory
    return c
  end
  surface.find_entities_filtered=function() return {} end
  surface.count_entities_filtered=function() return 0 end
  surface.can_place_entity=function() return true end
  local players={}
  game={tick=100,players=players,forces={player=player,red=red,blue=blue,enemy={name='enemy'}},surfaces={nauvis=surface},
    get_player=function() return nil end,get_surface=function() return surface end,print=function() end,connected_players=players}
  local source=assert(io.open('mod/agent-harness_0.1.0/runtime.lua')):read('*a')
  local R=assert(load('local BUNDLE_ID="fixture-bundle"\n'..source))()
  R.operator.bot_create({name='rb1',force='red'}); R.operator.bot_create({name='rb2',force='red'})
  R.operator.bot_create({name='bb1',force='blue'})
  local s=storage.agent_harness
  -- the teams as mt_setup records them
  s.mt={teams={red={},blue={}},order={'blue','red'},first={},set_tick=1}
  local function describe(bot,args)
    local reply=R.dispatch{id='help-'..bot..'-'..tostring(game.tick),bot=bot,action='describe',args=args or {}}
    game.tick=game.tick+1;return reply
  end
  local before=describe('rb1')
  eq(before.bundle,'fixture-bundle');eq(before.actions.pact_propose,nil)
  eq(describe('rb1',{if_bundle=before.bundle}).unchanged,true)
  local function box(team,bot)
    local idx=R.bots.index_of(bot)
    local m=s.team_stores[team] and s.team_stores[team].mentions
    return m and m[idx] and m[idx].list or {}
  end

  -- a hit: red's gun-turret on blue's wall
  local wall={valid=true,name='stone-wall',force=blue,surface=surface,position={x=10.5,y=20.5}}
  local turret={valid=true,name='gun-turret',force=red,position={x=0,y=20}}
  R.multiteam.on_damaged{entity=wall,force=red,cause=turret,final_damage_amount=5}
  local after=describe('rb1',{if_bundle=before.bundle})
  assert(after.actions.pact_propose,'first contact invalidates cached help')
  assert(after.bundle~=before.bundle)
  eq(describe('rb1',{if_bundle=after.bundle}).unchanged,true)
  local b=box('blue','bb1')
  eq(#b,1,'blue hears of the hit')
  has(b[1].text,'hit: our stone-wall at (10,20) on nauvis, by gun-turret of force red'); eq(b[1].wake,true)
  local r=box('red','rb1')
  eq(#r,1); has(r[1].text,'our gun-turret hit a stone-wall of force blue'); eq(r[1].fyi,true,'the shooter\'s line wakes nobody')
  eq(#box('red','rb2'),1,'every agent of the team')
  R.multiteam.on_damaged{entity=wall,force=red,cause=turret,final_damage_amount=5}
  eq(#box('blue','bb1'),1,'a first contact once')
  eq(R.team_now(),'player')

  -- a chart: blue's chart shows red's furnace
  game.get_surface=function() return surface end
  surface.find_entities_filtered=function(f) if f.force then return {{name='stone-furnace',force=red,position={x=-900.5,y=3.5}}} end return {} end
  R.multiteam.on_charted{force=blue,surface_index=1,area={{-928,0},{-896,32}}}
  b=box('blue','bb1')
  eq(#b,2); has(b[2].text,'charted: a stone-furnace of force red at (-901,3) on nauvis'); eq(b[2].fyi,true)

  -- the rules of contact: only on mt_rules, to each team named, kept per team
  local function tells_of(team) return #((s.team_stores[team].tells or {}).log or {}) end
  eq(tells_of('red'),0,'no rules before the operator sends them')
  fails(function() R.multiteam.operator.mt_rules{teams={'green'},text='x'} end,'not a team')
  local sent=R.multiteam.operator.mt_rules{teams={'red','blue'},text='Other teams exist. (rules text)'}
  eq(#sent.sent,2); eq(tells_of('red'),1); eq(tells_of('blue'),1)
  eq(table.concat(s.team_stores.red.tells.log[1].to,','),'rb1,rb2','to every red agent')
  eq(s.mt.rules.red.tick,game.tick)
  eq(R.multiteam.operator.mt_contacts{}.rules.blue.tick,game.tick)

  -- a loss whose cause is another team's entity names its force; the enemy's by name alone
  local furnace={valid=true,name='stone-furnace',type='furnace',position={x=40,y=40},force=blue,surface=surface}
  R.on_event{name=11,tick=200,entity=furnace,cause=turret,force=red}
  local inc
  for _,i in ipairs(s.losses) do if i.force=='blue' then inc=i end end
  eq(inc.causes['gun-turret of force red'],1)
  eq(R.cause_text({valid=true,name='small-biter',force={name='enemy'}},'blue'),'small-biter')
  eq(R.cause_text(nil,'blue',red),'unknown source of force red')
  eq(R.cause_text({valid=true,name='gun-turret',force=blue},'blue'),'gun-turret','our own: its name')
  -- Two agents per team receive explicit diplomacy; the third team receives none.
  local green=force('green');game.forces.green=green;s.mt.teams.green={};s.mt.order[#s.mt.order+1]='green'
  R.operator.bot_create({name='gb1',force='green'});R.operator.bot_create({name='gb2',force='green'})
  R.operator.bot_create({name='bb2',force='blue'})
  local counts={};for _,pair in ipairs{{'red','rb1'},{'red','rb2'},{'blue','bb1'},{'blue','bb2'}} do counts[pair[2]]=#box(pair[1],pair[2]) end
  local own=R.dispatch{id='diplo-1',bot='rb1',action='diplomacy_send',args={to='blue',text='Please agree to end pact 10.'}}
  eq(own.message.agent,'rb1');has(own.message.text,'Please agree')
  for _,pair in ipairs{{'red','rb2'},{'blue','bb1'},{'blue','bb2'}} do
    local messages=box(pair[1],pair[2]);eq(#messages,counts[pair[2]]+1);has(messages[#messages].text,'Diplomacy red (rb1) -> blue')
  end
  eq(#box('green','gb1'),0);eq(#box('green','gb2'),0)
  local reply=R.dispatch{id='diplo-read',bot='bb2',action='diplomacy',args={with='red'}}
  eq(reply.messages[1].agent,'rb1')
  fails(function() R.dispatch{id='diplo-no-contact',bot='gb1',action='diplomacy',args={with='red'}} end,'unsupported action')
  fails(function() R.dispatch{id='diplo-spoof',bot='bb1',action='diplomacy_send',args={to='red',text='hi',agent='rb2'}} end,'unknown argument agent')
  local proposal=R.dispatch{id='pact-note',bot='rb1',action='pact_propose',args={with='blue',terms={cease_fire=true},note='Please review these terms.'}}
  eq(proposal.pact.note,'Please review these terms.')
  fails(function() R.dispatch{id='pact-bogus',bot='rb1',action='pact_propose',args={with='blue',bogus=true}} end,'unknown argument bogus')
  local function call(bot,action,args) return R.dispatch{id='feed-'..action,bot=bot,action=action,args=args or {}} end
  local profile=call('rb1','profile',{display_name='  Forge  ',persona='A patient builder.',color='#3cb44b',glyph='F'})
  eq(profile.display_name,'Forge');eq(profile.persona,'A patient builder.')
  fails(function() call('rb2','profile',{display_name='FORGE'}) end,'already used')
  fails(function() call('rb1','profile',{display_name='Changed',persona=string.rep('x',161)}) end,'persona')
  eq(call('rb1','profile',{}).display_name,'Forge','invalid persona does not partially edit identity')
  call('bb1','profile',{display_name='Forge',persona='Another team can pick a name independently.'})
  local before=R.dispatch{operator=true,action='mt_feed',args={}}.last_seq
  call('rb1','say',{text='Red team private speech.'})
  call('rb2','tell',{to='rb1',text='Private reply.'})
  call('rb1','board_post',{kind='note',title='Our production plan',note='Mine first.'})
  call('rb1','diplomacy_send',{to='blue',text='A separate explicit offer.'})
  local feed=R.dispatch{operator=true,action='mt_feed',args={since=before}}
  eq(#feed.lines,4);eq(feed.lines[1].kind,'say');eq(feed.lines[2].kind,'tell');eq(feed.lines[3].kind,'board');eq(feed.lines[4].kind,'diplomacy')
  for i,line in ipairs(feed.lines) do eq(line.seq,before+i);eq(line.team,'red') end
  eq(feed.lines[1].scope,'team-private');eq(feed.lines[1].identity.display_name,'Forge');eq(feed.lines[2].to[1],'rb1')
  eq(feed.lines[4].scope,'diplomacy');eq(feed.lines[4].to[1],'blue')
  fails(function() call('gb1','mt_feed',{}) end,'unsupported action')
  local bluechat=call('bb1','chat',{peek=true});assert(not tostring(bluechat):find('Red team private'))
  for _,msg in ipairs(bluechat.messages or {}) do assert(msg.text~='Red team private speech.') end
  local latest=feed.last_seq
  R.dispatch{operator=true,team='red',action='tell',args={to='team',text='Operator-only instructions.'}}
  eq(R.dispatch{operator=true,action='mt_feed',args={}}.last_seq,latest,'operator tells excluded')
  -- Explicit hostile building fire selects the entity; a cease-fire or own
  -- building keeps ordinary enemy fire and cannot become a force attack.
  defines.shooting.shooting_selected=2
  local protected=false
  red.get_friend=function() return false end;red.get_cease_fire=function() return protected end
  local chest={valid=true,name='wooden-chest',health=10,force=blue,position={x=0,y=0}}
  surface.find_entities_filtered=function() return {chest} end
  local shooter={force=red,surface=surface,position={x=0,y=0}}
  eq(R.shoot_selected(shooter,chest.position),2);eq(shooter.selected,chest)
  protected=true;shooter.selected=nil
  eq(R.shoot_selected(shooter,chest.position),1);eq(shooter.selected,nil)
  protected=false;chest.force=red
  eq(R.shoot_selected(shooter,chest.position),1)
  print('mt295 identity, complete ordered speech and operator-only feed: ok')
  print('mt276 G contact lines, paired diplomacy delivery and third-team privacy: ok')
end
