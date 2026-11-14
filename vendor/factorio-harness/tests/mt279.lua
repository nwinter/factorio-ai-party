-- mt279 L2 (private: multi-team). Run from the harness root: lua tests/mt279.lua
-- The forces an agent's reply names: never the reader's own; another team's by name only after contact, else other;
-- enemy and neutral as before; the player force's replies (world n) unchanged.
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
  local R=dofile('mod/agent-harness_0.1.0/runtime.lua')
  R.operator.bot_create({name='rb1',force='red'}); R.operator.bot_create({name='rb2',force='red'})
  R.operator.bot_create({name='bb1',force='blue'}); R.operator.bot_create('astra')
  local s=storage.agent_harness
  -- the teams as mt_setup records them
  s.mt={teams={red={},blue={}},order={'blue','red'},first={},set_tick=1}

  -- the reply shapes the mt277 smoke test leaked, as red reads them before any contact
  local reply={entities={{name='stone-furnace',position={x=1,y=2},force='red'},{name='small-biter',force='enemy'},{name='tree',force='neutral'},
    {name='gun-turret',force='blue'}},alerts={enemy_news={{kind='nest_charted',force='red',surface='nauvis'}}},
    built={entity='stone-furnace',force='red'},lines={'built stone-furnace force=red at (1,2)','a gun-turret of force blue at (5,5)',
    'red science packs: 5','a small-biter (force enemy)'}}
  local stored=reply.alerts.enemy_news[1]
  local out=R.scrub_forces(reply,'red')
  eq(out.entities[1].force,nil,'our own entity: no force'); eq(out.entities[2].force,'enemy'); eq(out.entities[3].force,'neutral')
  eq(out.entities[4].force,'other','another team before contact'); eq(out.alerts.enemy_news[1].force,nil); eq(out.built.force,nil)
  eq(out.lines[1],'built stone-furnace force=ours at (1,2)'); eq(out.lines[2],'a gun-turret of force other at (5,5)')
  eq(out.lines[3],'red science packs: 5','a colour word that names no force stays'); eq(out.lines[4],'a small-biter (force enemy)')
  eq(stored.force,'red','the stored record keeps its force (the reply is copied)'); eq(reply.entities[1].force,'red')
  eq(out.entities[1].name,'stone-furnace')
  -- after contact (red's chart showed blue's entity): blue by name, red still never
  s.mt.first['chart red>blue']=50
  out=R.scrub_forces(reply,'red')
  eq(out.entities[4].force,'blue'); eq(out.lines[2],'a gun-turret of force blue at (5,5)'); eq(out.entities[1].force,nil)
  -- a hit is contact both ways; a chart only for the team whose chart it was
  eq(R.force_shown('red','blue'),'other','blue has not charted red')
  s.mt.first['shot red>blue']=60
  eq(R.force_shown('red','blue'),'red','blue was hit by red')
  s.mt.first={}

  -- a whole request: a team's reply scrubbed, the player force's as it was
  R.multiteam.operator.mt_rules{teams={'red'},text='the gun-turret of force red and force blue'}
  local t=R.dispatch{id='q1',bot='rb1',action='tells',args={}}
  local seen
  for _,x in ipairs(t.tells or t.log or {}) do seen=x.text end
  eq(seen,nil,'undiscovered force line withheld, not anonymized as other')
  eq(s.team_stores.red.tells.log[1].text,'the gun-turret of force red and force blue','stored as sent')
  R.as_team('player',function() R.tells.operator.tell({to='astra',text='a gun-turret of force red'}) end)
  local p=R.dispatch{id='q2',bot='astra',action='tells',args={}}
  for _,x in ipairs(p.tells or p.log or {}) do seen=x.text end
  eq(seen,'a gun-turret of force red','the player force\'s reply: no change')
  -- an error text too
  local ok,err=pcall(R.dispatch,{id='q3',bot='rb1',action='tell',args={to='nobody force red',text='x'}})
  assert(not ok); assert(not tostring(err):find('force red',1,true),tostring(err))
  print('mt279 L2 reply forces: ok')
end

-- an attack group as status alerts read it: never the set of forces that saw it gather (red and blue would say both
-- teams exist); the stored group keeps it
do
  local st={attack_groups={{seq=2,tick=500,size=4,position={x=5,y=5},seen={red=true,blue=true}}}}
  game={tick=600}
  local T=dofile('mod/agent-harness_0.1.0/threat.lua'){state=function() return st end,distance=function() return 0 end}
  local red=T.alerts(0,'nauvis','red')
  eq(#red.attack_groups,1); eq(red.attack_groups[1].size,4); eq(red.attack_groups[1].seen,nil)
  assert(st.attack_groups[1].seen.blue,'the stored group keeps the forces that saw it')
  print('mt279 L2 attack groups without the forces that saw them: ok')
end
