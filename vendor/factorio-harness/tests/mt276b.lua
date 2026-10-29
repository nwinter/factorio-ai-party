-- mt276 B (private: multi-team phase 2, part B). Run from the harness root: lua tests/mt276b.lua
-- Team stores: each team's board, tells, chat, votes and roster; the player force's at their old keys (a one-team world
-- and an old save as before), another team's in team_stores while its calls run. Calls, ticks and deliveries run as
-- the agent's team.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
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
  helpers={json_to_table=function(t) return t end,table_to_json=function() return '{}' end}
  local player,red=force('player'),force('red',{x=1000,y=0})
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
  game={tick=0,players=players,forces={player=player,red=red,enemy={name='enemy'}},surfaces={nauvis=surface},
    get_player=function() return nil end,get_surface=function() return surface end,print=function() end,connected_players=players}
  local R=dofile('mod/agent-harness_0.1.0/runtime.lua')
  R.operator.bot_create('astra'); R.operator.bot_create('sol')
  R.operator.bot_create({name='rb1',force='red'}); R.operator.bot_create({name='rb2',force='red'})
  local n=0
  local function call(bot,action,args)
    n=n+1
    return R.dispatch{id='t'..n,bot=bot,action=action,args=args or {}}
  end
  local function op(action,args,team)
    n=n+1
    return R.dispatch{id='t'..n,operator=true,team=team,action=action,args=args or {}}
  end
  local s=storage.agent_harness

  -- the roster: each team's own agents
  local function names(list) local out={} for _,a in ipairs(list) do out[#out+1]=a.name end table.sort(out) return table.concat(out,',') end
  eq(names(R.as_team('player',R.board.agents)),'astra,sol')
  eq(names(R.as_team('red',R.board.agents)),'rb1,rb2')
  eq(R.team_now(),'player','back to player after a team call')

  -- the board: a post by red is red's alone; the player force's stays at the old key
  local pr=call('rb1','board_post',{kind='task',title='red smelting'})
  local pp=call('astra','board_post',{kind='task',title='player smelting'})
  local seen={}
  for _,i in pairs(s.board.items) do seen[#seen+1]=i.title end
  eq(table.concat(seen,','),'player smelting','the player force\'s board at its key')
  local redb=s.team_stores.red.board
  local rseen={}
  for _,i in pairs(redb.items) do rseen[#rseen+1]=i.title end
  eq(table.concat(rseen,','),'red smelting','red\'s board in team_stores')
  eq(s.team_stores.player,nil,'no player entry: its stores never leave the keys between calls')
  local function titles(bot)
    local out={}
    local b=call(bot,'board',{})
    for _,i in ipairs(b.items or {}) do out[#out+1]=i.title end
    return table.concat(out,',')
  end
  eq(titles('rb2'),'red smelting'); eq(titles('sol'),'player smelting')
  assert(pr and pp)

  -- tells: within the team; another team's agent is not a name at all
  call('rb1','tell',{to='rb2',text='iron at the north patch'})
  fails(function() call('rb1','tell',{to='astra',text='hello'}) end,'rb2')
  call('rb1','tell',{to='team',text='all of red'})
  local reds=s.team_stores.red.tells
  eq(#reds.log,2,'red\'s two tells in red\'s store')
  eq(#((s.tells or {}).log or {}),0,'the player force has none')
  local t=reds.log[2]
  eq(table.concat(t.to,','),'rb2','team: red\'s others only')

  -- chat: each team's own log
  call('astra','say',{text='player line'})
  call('rb2','say',{text='red line'})
  local function lines(c) local out={} for _,m in ipairs(c.messages or {}) do out[#out+1]=m.text end return table.concat(out,'|') end
  eq(lines(s.chat),'player line'); eq(lines(s.team_stores.red.chat),'red line')

  -- operator calls run as their team (default player); an operator tell to one agent runs as its team
  eq(#(op('tells',{},'red').tells or {}),2)
  eq(#(op('tells',{}).tells or {}),0)
  fails(function() op('tells',{},'enemy') end,'team: a player force')
  op('tell',{to='rb1',text='operator to red'})
  eq(#s.team_stores.red.tells.log,3,'the operator tell is in red\'s store')

  -- a line filed for an agent from outside a call goes to its team's mention box
  R.board.deliver(R.bots.index_of('rb1'),{seq='x',tick=1,from='loss alert',text='a red line',wake=true})
  local idx=R.bots.index_of('rb1')
  local box=s.team_stores.red.mentions and s.team_stores.red.mentions[idx]
  assert(box and #box.list>=1,'red\'s mention box has the line')
  assert(not (s.mentions and s.mentions[idx]),'nothing in the player force\'s boxes')

  -- an error in a team call leaves the keys as the player force's
  fails(function() R.as_team('red',function() s.board.items[999]={title='mid-call'}; error('boom',0) end) end,'boom')
  eq(R.team_now(),'player'); assert(s.team_stores.red.board.items[999],'the write went to red\'s board')
  assert(not s.board.items[999],'and not the player force\'s')
  print('mt276 B team stores: board, tells, chat, operator, deliveries: ok')

  -- profiles: each team lists its own; a colour too close to another team's is refused without its holder's name
  call('astra','profile',{color='#e6194b',display_name='Astra'})
  local function listed(bot) local out={} for _,r in ipairs(call(bot,'profiles',{}).profiles) do out[#out+1]=r.name end table.sort(out) return table.concat(out,',') end
  eq(listed('rb1'),'rb1,rb2'); eq(listed('sol'),'astra,sol')
  eq(call('rb1','profile',{color='#e6194c'}).color,'#e6194c','another team\'s colour is no refusal (it would tell red others exist)')
  fails(function() call('sol','profile',{color='#e6194c'}) end,'too close to Astra (astra)')

  -- a LuaPlayer mt_assign put in red's force (a spectator that charts) is no agent, of either team
  local chart={index=1,name='red-chart',valid=true,connected=true,force=red,admin=false,position={x=0,y=0},surface=surface}
  players[1]=chart
  game.get_player=function(i) if i==1 or i=='red-chart' then return chart end end
  s.mt={players={['red-chart']='red'}}
  eq(names(R.as_team('red',R.board.agents)),'rb1,rb2','the chart join is not on red\'s roster')
  s.mt.players={}
  eq(names(R.as_team('red',R.board.agents)),'rb1,rb2,red-chart','unassigned, a LuaPlayer in red counts (as in one team)')
  s.mt.players={['red-chart']='red'}

  -- ticks run each team's turn: reminders and lessons per team
  local turns={}
  R.each_team(function() turns[#turns+1]=R.team_now() end)
  eq(table.concat(turns,','),'player,red')
  eq(R.team_now(),'player')
  print('mt276 B profiles, chart joins, team turns: ok')
end

-- a one-team world: no team_stores, every store at its old key
do
  storage={agent_harness={active={}}}
  local player=force('player')
  local surface={name='nauvis',index=1,valid=true,find_non_colliding_position=function(_,o) return o end,find_entities_filtered=function() return {} end,
    can_place_entity=function() return true end,count_entities_filtered=function() return 0 end}
  surface.create_entity=function(args) return {valid=true,name=args.name,type='character',force=args.force,surface=surface,position=args.position,unit_number=7,
    walking_state={walking=false},insert=function(x) return x.count end,get_main_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end} end
  game={tick=0,players={},forces={player=player,enemy={name='enemy'}},surfaces={nauvis=surface},get_player=function() return nil end,
    get_surface=function() return surface end,print=function() end,connected_players={}}
  local R=dofile('mod/agent-harness_0.1.0/runtime.lua')
  R.operator.bot_create('astra'); R.operator.bot_create('sol')
  R.dispatch{id='o1',bot='astra',action='board_post',args={kind='task',title='one team'}}
  R.dispatch{id='o2',bot='astra',action='tell',args={to='sol',text='hi'}}
  local s=storage.agent_harness
  eq(s.team_stores,nil,'no team stores in a one-team world')
  local t={} for _,i in pairs(s.board.items) do t[#t+1]=i.title end
  eq(table.concat(t,','),'one team'); eq(#s.tells.log,1)
  print('mt276 B one team at the old keys: ok')
end
