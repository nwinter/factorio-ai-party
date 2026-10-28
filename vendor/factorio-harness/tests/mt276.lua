-- mt276 (private: multi-team phase 2, part A). Run from the harness root: lua tests/mt276.lua
-- Two teams' forces (player and red): bot_create {force}, the team forces, and each read giving the reader's own
-- force's records only (eggs, landed pods, damage log, attacks and nest news, attack groups, platform hits, power cuts,
-- the hand ledger). A one-team world reads as before.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

local function force(name,spawn)
  return {name=name,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
    get_spawn_position=function() return spawn or {x=0,y=0} end,players={},platforms={}}
end

-- bot_create {name, force}: the record and the body in that force, at its spawn; team_names and agent_force.
do
  storage={agent_harness={active={}}}
  defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
    controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
  rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
  remote={interfaces={}}
  helpers={json_to_table=function(t) return t end}
  local player,red=force('player'),force('red',{x=1000,y=0})
  local surface={name='nauvis',index=1}
  surface.find_non_colliding_position=function(_,origin) return {x=origin.x,y=origin.y} end
  surface.create_entity=function(args)
    local items={}
    local c={valid=true,name=args.name,type='character',force=args.force,surface=surface,position=args.position,unit_number=100,walking_state={walking=false}}
    c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
    c.get_main_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end
    return c
  end
  surface.find_entities_filtered=function() return {} end
  surface.can_place_entity=function() return true end
  local players={}
  game={tick=0,players=players,forces={player=player,red=red,enemy={name='enemy'}},
    get_player=function() return nil end,get_surface=function() return surface end,print=function() end,connected_players=players}
  local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
  eq(table.concat(runtime.team_names(),','),'player','no bots: the player force alone')
  local a=runtime.operator.bot_create('astra')
  eq(a.bot.force,'player')
  local r=runtime.operator.bot_create({name='rb1',force='red'})
  eq(r.ok,true); eq(r.bot.force,'red')
  local rec=storage.agent_harness.bots.by_name.rb1
  eq(rec.force,'red'); eq(rec.character.force,red,'the body in red'); eq(rec.character.position.x>=1000,true,'at red\'s spawn')
  fails(function() runtime.operator.bot_create({name='rb2',force='enemy'}) end,'force must be a player force')
  fails(function() runtime.operator.bot_create({name='rb3',force='blue'}) end,'force must be a player force')
  eq(table.concat(runtime.team_names(),','),'player,red')
  eq(runtime.agent_force('rb1'),red); eq(runtime.agent_force('astra'),player); eq(runtime.agent_force('nobody'),player)
  local listed={}
  for _,b in ipairs(runtime.operator.bots().bots) do listed[b.name]=b.force end
  eq(listed.rb1,'red'); eq(listed.astra,'player')
  -- losses at one spot from two forces: two incidents, each with its force; an agent's own only
  surface.is_chunk_visible=function() return true end
  for _,f in ipairs({player,red,red}) do
    runtime.on_event{name=11,tick=10,entity={valid=true,name='stone-furnace',type='furnace',position={x=40,y=40},force=f,surface=surface}}
  end
  local inc={}
  for _,i in ipairs(storage.agent_harness.losses) do inc[i.force or 'player']=i.total end
  eq(inc.player,1); eq(inc.red,2)
  print('mt276 bot_create {force}, team_names, agent_force, loss incidents: ok')
end

-- spoil: one sweep a tick, the forces in turn, each into its own watch; a reader's eggs are its force's.
do
  game={tick=1000,get_surface=function(n) return n=='nauvis' and {name='nauvis'} or nil end}
  prototypes={item={['pentapod-egg']={get_spoil_ticks=function() return 54000 end,
    spoil_to_trigger_result={items_per_trigger=1,trigger={{type='create-entity',entity_name='big-wriggler-pentapod-premature',as_enemy=true}}}}}}
  local st,asked={},{}
  local S=dofile('mod/agent-harness_0.1.0/spoil.lua'){state=function() return st end,
    force=function(name) asked[#asked+1]=name or 'player'; return nil end,team_names=function() return {'player','red'} end,characters=function() return {} end}
  st.eggs={anchors={},places={},told={},seq=0,tick=1000,anchor_tick=1000}
  S.tick(1001); eq(#asked,1,'red has no sweep yet'); eq(asked[1],'red')
  S.tick(1002); eq(#asked,1,'player is between sweeps: no force read')
  local function found(by) return {{surface='nauvis',position={x=1,y=2},entity='wooden-chest',item='pentapod-egg',count=3,tick=5000,percent=0.5,soon=0,by=by}} end
  st.eggs.found=found('astra'); st.eggs_teams.red.found=found('rb1')
  local pr={force={name='red'},surface={name='nauvis'}}
  local pp={force={name='player'},surface={name='nauvis'}}
  eq(S.read_eggs(pr,{}).rows[1].by,'rb1'); eq(S.read_eggs(pp,{}).rows[1].by,'astra')
  eq(st.eggs.seq,0,'the news seq is one counter, in st.eggs')
  print('mt276 spoil per force: ok')
end

-- landed: containers and pads of the reader's force only.
do
  local red,player={name='red'},{name='player'}
  local st={landed={reg={nauvis={[1]={valid=true,force=player,position={x=1,y=1},get_inventory=function() return {get_contents=function() return {{name='iron-plate',count=5}} end} end},
    [2]={valid=true,force=red,position={x=9,y=9},get_inventory=function() return {get_contents=function() return {{name='coal',count=7}} end} end}}},pads={},pass={},sweep={planet=1,slice=1}}}
  local L=dofile('mod/agent-harness_0.1.0/landed.lua'){state=function() return st end,position=function(q) return q end}
  local all=L.now('nauvis'); eq(all.n,2)
  local r=L.now('nauvis','red'); eq(r.n,1); eq(r.items.coal,7); eq(r.items['iron-plate'],nil)
  eq(L.now('nauvis','player').items['iron-plate'],5)
  print('mt276 landed per force: ok')
end

-- damagelog: every team's entities kept, each with its force; a reader sees its own force's.
do
  local st={}
  game={tick=100}
  local D=dofile('mod/agent-harness_0.1.0/damagelog.lua'){state=function() return st end,position=function(q) return q end,
    integer=function(v,d) return v or d end}
  local function hit(fname,unit,x)
    local f={name=fname,is_chunk_visible=function() return true end}
    D.on_damaged{tick=100,entity={valid=true,unit_number=unit,force=f,position={x=x,y=0},surface={name='nauvis'},name='stone-furnace'},
      damage_type={name='physical'},final_damage_amount=5}
  end
  hit('player',1,1); hit('red',2,2); hit('enemy',3,3)
  eq(st.damage_log.by[1].force,nil,'the player force kept as before'); eq(st.damage_log.by[2].force,'red'); eq(st.damage_log.by[3],nil,'not enemy')
  local function reader(fname) return {force={name=fname},surface={name='nauvis',find_entities_filtered=function() return {} end},position={x=0,y=0}} end
  eq(#D.read(reader('red'),{}).entities,1); eq(D.read(reader('red'),{}).entities[1].position.x,2)
  eq(#D.read(reader('player'),{}).entities,1); eq(D.read(reader('player'),{}).entities[1].position.x,1)
  print('mt276 damagelog per force: ok')
end

-- threat: attacked areas, nest news and attack groups by force (a group: the forces that saw it).
do
  local st={damage={['nauvis:0,0']={id=1,at={x=1,y=1},surface='nauvis',last=500,damage=10,hits=1,entities={}},
    ['red|nauvis:0,0']={id=2,at={x=2,y=2},surface='nauvis',last=500,damage=10,hits=1,entities={},force='red'}},
    attack_groups={{seq=1,tick=500,size=3,position={x=0,y=0}},{seq=2,tick=500,size=4,position={x=5,y=5},seen={red=true}}},
    enemy_news={{seq=3,tick=500,kind='nest_charted',surface='nauvis',position={x=0,y=0}},{seq=4,tick=500,kind='nest_charted',force='red',surface='nauvis',position={x=9,y=9}}}}
  game={tick=600}
  local T=dofile('mod/agent-harness_0.1.0/threat.lua'){state=function() return st end,distance=function() return 0 end}
  local red=T.alerts(0,'nauvis','red')
  eq(#red.attacked,1); eq(red.attacked[1].id,2); eq(#red.attack_groups,1); eq(red.attack_groups[1].size,4); eq(#red.enemy_news,1); eq(red.enemy_news[1].seq,4)
  local pl=T.alerts(0,'nauvis','player')
  eq(#pl.attacked,1); eq(pl.attacked[1].id,1); eq(#pl.attack_groups,1); eq(pl.attack_groups[1].size,3); eq(pl.enemy_news[1].seq,3)
  local all=T.alerts(0,'nauvis'); eq(#all.attacked,2,'no force: all (the operator)')
  print('mt276 threat per force: ok')
end

-- platalerts rows and powercut cuts by force.
do
  local st={platform_alerts={by={[1]={name='Alpha',surface='platform-1',last_hit=500,minutes={[0]={hits=1,damage=5,entities={},by={}}},force=false},
    [2]={name='Alpha',surface='platform-2',last_hit=500,minutes={[0]={hits=2,damage=9,entities={},by={}}},force='red'}}},
    powercut={cuts={{id=1,tick=500,surface='nauvis',force='player',parts={},poles=1},{id=2,tick=500,surface='nauvis',force='red',parts={},poles=1}}}}
  game={tick=600}
  local P=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end}
  eq(#P.rows(0,'red'),1); eq(P.rows(0,'red')[1].surface,'platform-2'); eq(P.rows(0,'player')[1].surface,'platform-1'); eq(#P.rows(0),2)
  local C=dofile('mod/agent-harness_0.1.0/powercut.lua'){state=function() return st end}
  C.line=function(c) return 'cut '..c.id end
  eq(#C.since(0,nil,'red'),1); eq(C.since(0,nil,'red')[1],'cut 2'); eq(#C.since(0,nil),2)
  local lines=C.lines({force={name='red'},surface={name='nauvis'}},{})
  eq(#lines,1); eq(lines[1],'cut 2')
  print('mt276 platform hits and power cuts per force: ok')
end

-- survey's hand ledger: one per force, the player force's in hand_log as before.
do
  local st={}
  game={tick=7200}
  local S=dofile('mod/agent-harness_0.1.0/survey.lua'){state=function() return st end}
  S.log_hand('fed','iron-plate',5); S.log_hand('fed','coal',3,'red'); S.log_hand('crafted','iron-gear-wheel',2,'player')
  eq(st.hand_log[2].fed['iron-plate'],5); eq(st.hand_log[2].crafted['iron-gear-wheel'],2); eq(st.hand_log[2].fed.coal,nil)
  eq(st.hand_log_teams.red[2].fed.coal,3)
  print('mt276 hand ledger per force: ok')
end
