-- Run from the harness root: lua tests/d20_batch56_rt.lua
-- d20 batch56 through the runtime against a fake engine (the scaffold of tests/d17_batch18_rt.lua).
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
-- chunks our force does not see: hidden['nauvis|cx,cy']=true
local hidden={}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,is_chunk_visible=function(s,c) return not (hidden[(s.name or s)..'|'..c.x..','..c.y]) end,platforms={},is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local vulcanus={name='vulcanus',index=2,find_entities_filtered=function() return {} end}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
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
  get_surface=function(n) if n=='vulcanus' then return vulcanus end return surface end,print=function() end,connected_players=players,
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

local shots={}
game.take_screenshot=function(t) shots[#shots+1]=t end
game.surfaces={surface,vulcanus}

-- R3 (shifts 45-47: 27 empty-area inspects read like a sight refusal): an empty area says whether it is in sight, all,
-- part or none of it.
do
  fails(function() astra('inspect',{area={left_top={x=2,y=2},right_bottom={x=10,y=10}}}) end,
    'no entity of ours with its centre in (2,2)-(10,10); the area is in sight now (our force sees its chunk)')
  fails(function() astra('inspect',{area={left_top={x=-10,y=-10},right_bottom={x=10,y=10}}}) end,
    'the area is in sight now (our force sees all 4 of its chunks)')
  hidden['nauvis|-1,-1']=true
  fails(function() astra('inspect',{area={left_top={x=-10,y=-10},right_bottom={x=10,y=10}}}) end,
    'no entity of ours with its centre in (-10,-10)-(10,10); 3 of its 4 chunks in sight now, 1 out of sight')
  fails(function() astra('inspect',{area={left_top={x=-10,y=-10},right_bottom={x=-2,y=-2}}}) end,
    'the area is out of sight now (its chunk is not one our force sees: radar coverage or a character\'s sight lights a chunk); the nearest radar coverage')
  hidden['nauvis|-1,-1']=nil
end
print('d20_batch56_rt R3 empty area in sight or not: ok')

-- R2 (Enginerd 14:42: 5 of 19 shots came right after a long walk): screenshot {position} by remote view, every chunk of
-- the frame in sight; without it at the character, as before.
do
  local r=astra('screenshot',{path='pog/astra/a.png'})
  local me=shots[#shots].position
  eq(r.position.x,me.x); eq(r.by,nil)
  -- (d21 batch66 AB2) every reply names where the engine renders it and what of ours stands in the frame
  eq(r.surface,'nauvis'); eq(r.platform,nil); assert(r.line:find('rendered on nauvis centred (',1,true) and r.line:find(' (your character): frame (',1,true),r.line)
  r=astra('screenshot',{path='pog/astra/b.png',position={x=150,y=20}})
  eq(shots[#shots].position.x,150); eq(shots[#shots].position.y,20); eq(shots[#shots].resolution.x,1280)
  eq(r.by,'remote view'); eq(r.surface,'nauvis'); eq(r.position.x,150)
  assert(me.x~=150)
  -- the frame (130,8.75)-(170,31.25) takes in chunk (5,0): out of sight, refused, nothing queued
  hidden['nauvis|5,0']=true
  local n=#shots
  fails(function() astra('screenshot',{path='pog/astra/c.png',position={x=150,y=20}}) end,
    'the frame (130,8.75)-(170,31.25) (1280x720 px, 32 px a tile) takes in 1 of 2 chunks our force does not see now: (160,0)-(191,31)')
  -- the centre out of sight: as inspect, with the nearest coverage
  fails(function() astra('screenshot',{path='pog/astra/c.png',position={x=165,y=20}}) end,'screenshot centre at (165,20)')
  fails(function() astra('screenshot',{path='pog/astra/c.png',position={x=165,y=20}}) end,'is in no chunk our force sees now')
  eq(#shots,n)
  hidden['nauvis|5,0']=nil
  -- another planet: position needed; there, by remote view
  fails(function() astra('screenshot',{path='pog/astra/d.png',surface='vulcanus'}) end,'screenshot with surface needs position there')
  r=astra('screenshot',{path='pog/astra/d.png',surface='vulcanus',position={x=10,y=10}})
  eq(shots[#shots].surface,vulcanus); eq(r.surface,'vulcanus'); eq(r.by,'remote view')
  hidden['vulcanus|0,0']=true
  fails(function() astra('screenshot',{path='pog/astra/e.png',surface='vulcanus',position={x=10,y=10}}) end,'(remote view needs radar coverage there)')
end
print('d20_batch56_rt R2 screenshot by remote view: ok')

-- d21 batch66 AB2 (Sol #1602: ./shot at=0,0 platform=Solstice from Fulgora; the image, a platform's hub drawn at low
-- resolution, was read as Fulgora round his body): the engine gets the platform's surface and the centre asked, the
-- hub without one, and the reply names them, the frame and what of ours stands in it.
do
  local plsurf={name='platform-7',index=7,valid=true}
  local ents={{type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}},{type='ammo-turret',name='gun-turret',position={x=-6,y=3}},
    {type='ammo-turret',name='gun-turret',position={x=6,y=3}},{type='entity-ghost',name='entity-ghost',position={x=8,y=0}}}
  plsurf.find_entities_filtered=function(f) eq(f.area[1].x,-25,'the frame searched'); return ents end
  force.platforms={{valid=true,name='Solstice',index=3,surface=plsurf,hub={valid=true,position={x=0,y=0}},force=force}}
  local r=sol('screenshot',{path='pog/sol/p.png',width=1600,height=1080,platform='Solstice',position={x=0,y=0}})
  eq(shots[#shots].surface,plsurf,'rendered on the platform'); eq(shots[#shots].position.x,0); eq(shots[#shots].position.y,0)
  eq(r.surface,'platform-7'); eq(r.platform,'Solstice'); eq(r.position.x,0); eq(r.frame.left_top.x,-25); eq(r.frame.right_bottom.y,16.875)
  eq(r.in_frame['gun-turret'],2); eq(r.ghosts_in_frame,1)
  eq(r.line,'rendered on platform Solstice (surface platform-7) centred (0,0): frame (-25,-16.875)-(25,16.875), 50x33.75 tiles; ours in it: gun-turret 2, space-platform-hub 1; 1 ghost')
  -- platform only: centred on its hub
  plsurf.find_entities_filtered=function() return ents end
  r=sol('screenshot',{path='pog/sol/q.png',platform='Solstice'})
  eq(shots[#shots].surface,plsurf); eq(shots[#shots].position.x,0)
  assert(r.line:find('rendered on platform Solstice (surface platform-7) centred (0,0) (the hub): frame',1,true),r.line)
  -- surface= a platform's surface name reads the same
  r=sol('screenshot',{path='pog/sol/s.png',surface='platform-7',position={x=2,y=1}})
  eq(shots[#shots].surface,plsurf); eq(r.platform,'Solstice'); eq(r.position.x,2)
  force.platforms={}
end
print('d20_batch56_rt d21 batch66 AB2 screenshot of a platform: ok')

-- R4 (Astra #1399 for viewer Foobator): a combinator's description, LuaEntity.combinator_description in 2.0.77, on
-- arithmetic, decider, selector and constant combinators and their ghosts; up to 500 bytes.
do
  local C=runtime.circuits
  local cc={valid=true,name='constant-combinator',type='constant-combinator',combinator_description=''}
  local chest={valid=true,name='iron-chest',type='container'}
  setmetatable(chest,{__index=function(_,k) if k=='combinator_description' then error('Entity is not arithmetic-combinator or decider-combinator or selector-combinator or constant-combinator.',0) end end})
  local ghost={valid=true,name='entity-ghost',type='entity-ghost',ghost_name='decider-combinator',ghost_type='decider-combinator',combinator_description='dec'}
  eq(C.description(cc),nil); eq(C.description(ghost),'dec'); eq(C.description(chest),nil)
  eq(C.check_description(cc,'Iron plate threshold\nfor the mall'),'Iron plate threshold\nfor the mall')
  eq(C.check_description(cc,false),'')
  fails(function() C.check_description(cc,string.rep('x',501)) end,'description is 501 bytes; the game keeps at most 500')
  fails(function() C.check_description(chest,'x') end,'description: iron-chest takes none')
  fails(function() C.check_description(cc,7) end,'description is a string up to 500 bytes')
  eq(C.check_description(ghost,string.rep('x',500)),string.rep('x',500))
  -- configure by remote view sets it and reads it back
  local placed={valid=true,name='constant-combinator',type='constant-combinator',position={x=150.5,y=20.5},force=force,surface=surface,
    combinator_description='',get_control_behavior=function() return nil end,get_wire_connectors=function() return {} end,
    prototype={selectable_in_game=true},quality={name='normal'}}
  surface.find_entities_filtered=function(f) if f.position and math.abs(f.position.x-150.5)<1 and math.abs(f.position.y-20.5)<1 then return {placed} end return {} end
  local r=astra('configure',{position={x=150.5,y=20.5},description='Iron plate threshold'})
  eq(placed.combinator_description,'Iron plate threshold'); eq(r.description,'Iron plate threshold'); eq(r.description_before,'')
  eq(r.line,'constant-combinator (150.5,20.5): description "Iron plate threshold" (was none)')
  r=astra('configure',{position={x=150.5,y=20.5},description=''})
  eq(placed.combinator_description,''); eq(r.line,'constant-combinator (150.5,20.5): description none (was "Iron plate threshold")')
  fails(function() astra('configure',{position={x=150.5,y=20.5},description='x',recipe='y'}) end,'description goes alone')
  surface.find_entities_filtered=function() return {} end
end
print('d20_batch56_rt R4 combinator description: ok')
