-- Run from repository root: lua tests/visuals.lua
-- What agents are doing, drawn for the camera clients only (visuals.lua, and
-- highlights.lua's speech bubbles): mining progress, icon and particles, the
-- crafting queue, a move_to route, item moves, work rings; nothing without a
-- camera client, nothing for an agent's player (Nick 14:40).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,m) assert(math.abs(a-b)<1e-6,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local objects={}
local function obj(kind,args)
  local o={id=#objects+1,valid=true,kind=kind,args=args}
  o.destroy=function() o.valid=false end
  objects[#objects+1]=o
  return o
end
rendering={get_object_by_id=function(id) return objects[id] end}
for _,k in ipairs{'text','circle','line','arc','sprite','rectangle'} do rendering['draw_'..k]=function(a) return obj(k,a) end end
remote={interfaces={}}
helpers={json_to_table=function(t) return t end,is_valid_sprite_path=function(path) return path~='item/nothing' end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local particles={}
local surface={name='nauvis',index=1,valid=true}
surface.create_particle=function(a) particles[#particles+1]=a end
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=700,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},crafting_queue_progress=0}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end; c.get_main_inventory=function() return inv end; c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end; c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.count_entities_filtered=function() return 0 end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local flying={}
local cam={index=1,name='pog-cam1',valid=true,connected=false,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=0,y=0}}
cam.create_local_flying_text=function(a) flying[#flying+1]=a end
cam.print=function() end
local players={cam}
local connected={}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) if n=='nauvis' or n==1 then return surface end end,print=function() end,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
setmetatable(game,{__index=function(_,k) if k=='connected_players' then return connected end end})
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
runtime.operator.bot_create('sol')
local index=runtime.bots.index_of('sol')
local sol=runtime.bots.record(index)
local c=sol.character
c.position={x=0,y=0}
runtime.dispatch{action='profile',args={display_name='Sol',glyph='S',color='#ffcb45'},bot='sol'}
local rgb=runtime.profiles.get(index).rgb
local base=#objects
local function mine(kind) local out={}; for i=base+1,#objects do local o=objects[i]; if o.valid and (not kind or o.kind==kind) then out[#out+1]=o end end; return out end
local function only_camera()
  for i=base+1,#objects do local a=objects[i].args; eq(#a.players,1); eq(a.players[1],1,'only the camera player sees it') end
end
local active=storage.agent_harness.active
local rock={valid=true,name='big-rock',type='simple-entity',position={x=3,y=0},surface=surface,force=force,
  prototype={mineable_properties={mining_time=2,mining_particle='stone-particle',products={{type='item',name='stone'}}}}}

-- Mining with no camera client connected: nothing at all.
active[index]={kind='mine',entity=rock,started=0,done_tick=100,until_tick=600,products={'stone'}}
runtime.visuals.tick(20)
eq(#mine(),0); eq(#particles,0)
-- A camera connects: the arc fills with the mining time, the product's icon, the game's particles.
cam.connected=true; connected={cam}
runtime.visuals.tick(20)
local arc=mine('arc')[1]
near(arc.args.angle,2*math.pi*0.2); eq(arc.args.target,rock); eq(arc.args.color.r,rgb.r)
eq(mine('sprite')[1].args.sprite,'item/stone'); eq(mine('sprite')[1].args.target.entity,rock)
eq(#particles,2); eq(particles[1].name,'stone-particle')
runtime.visuals.tick(50)
eq(#mine('arc'),1,'the arc is replaced, not stacked'); near(mine('arc')[1].args.angle,2*math.pi*0.5)
eq(#particles,2,'particles every 20 ticks')
-- Ore: progress through the current hand-mining cycle.
local ore={valid=true,name='iron-ore',type='resource',position={x=2,y=2},surface=surface,amount=50,
  prototype={mineable_properties={mining_time=1,products={{type='item',name='iron-ore'}}}}}
active[index]={kind='mine',entity=ore,cycle=40,next_mine=70,until_tick=600,products={'iron-ore'},mined=0,started=0}
runtime.visuals.tick(60)
near(mine('arc')[1].args.angle,2*math.pi*0.75)
only_camera()
-- The mine ends: its drawing goes.
active[index]=nil
runtime.visuals.tick(70)
eq(#mine('arc'),0); eq(#mine('sprite'),0)

-- Hand crafting: the next recipes above the head, the first with its progress.
c.crafting_queue={{recipe='iron-gear-wheel',count=5},{recipe='pipe',count=1},{recipe='electronic-circuit',count=2},{recipe='inserter',count=1}}
c.crafting_queue_progress=0.25
runtime.visuals.tick(90)
local sprites=mine('sprite')
eq(#sprites,3,'three recipes'); eq(sprites[1].args.sprite,'recipe/iron-gear-wheel'); eq(sprites[1].args.target.entity,c)
eq(mine('text')[1].args.text,'x5'); eq(#mine('text'),2,'counts over 1 only')
near(mine('arc')[1].args.angle,2*math.pi*0.25)
c.crafting_queue={}
runtime.visuals.tick(120)
eq(#mine('sprite'),0,'an empty queue clears it')

-- move_to: a faint dashed line along the route to the goal.
active[index]={kind='move_to',position={x=20,y=0},until_tick=900,nav=nil,waypoints={{position={x=5,y=0}},{position={x=10,y=5}},{position={x=15,y=5}}},waypoint=2}
runtime.visuals.tick(150)
local lines=mine('line')
eq(#lines,3,'from the character through the waypoints left to the goal'); eq(lines[1].args.from,c); eq(lines[1].args.to.x,10)
eq(lines[3].args.to.x,20); eq(lines[1].args.dash_length,0.5); assert(lines[1].args.color.a<0.5)
eq(mine('circle')[1].args.target.x,20); eq(mine('text')[1].args.text,'walking here')
active[index]=nil
runtime.visuals.tick(180)
eq(#mine('line'),0)

-- Item moves: flying text for each camera player, in Sol's colour.
local p=runtime.lookup(index)
runtime.visuals.moved(p,{x=3,y=4},surface,'+50 [item=iron-plate]')
eq(#flying,1); eq(flying[1].text,'+50 [item=iron-plate]'); eq(flying[1].position.x,3); eq(flying[1].color.r,rgb.r)
-- Work: a brief ring on the target; none for a platform request or without a place.
runtime.visuals.worked(p,'configure',{position={x=7,y=7}})
local ring=mine('circle')[1]
eq(ring.args.target.x,7); eq(ring.args.time_to_live,60)
runtime.visuals.worked(p,'deconstruct',{area={left_top={x=0,y=0},right_bottom={x=10,y=4}}})
eq(mine('circle')[2].args.target.x,5)
local n=#objects
runtime.visuals.worked(p,'configure',{position={x=7,y=7},platform='Starling'})
runtime.visuals.worked(p,'inspect',{position={x=7,y=7}})
runtime.visuals.worked(p,'build',{})
eq(#objects,n,'no ring')
-- At most 30 brief objects a second.
game.tick=6000
for i=1,40 do runtime.visuals.worked(p,'rotate',{position={x=i,y=0}}) end
eq(#objects-n,30)
only_camera()

-- The camera leaves: the replaceable drawings go, nothing new is drawn.
c.crafting_queue={{recipe='pipe',count=1}}
runtime.visuals.tick(210)
assert(#mine('sprite')==1)
cam.connected=false; connected={}
runtime.visuals.tick(240)
eq(#mine('sprite'),0)

-- Through the runtime's tick (a fault there is counted, never fatal).
cam.connected=true; connected={cam}
for t=1,30 do game.tick=6000+t; runtime.tick{tick=6000+t} end
eq(#mine('sprite'),1,'the runtime tick draws it')
local saved=runtime.visuals.tick
runtime.visuals.tick=function() error('boom') end
game.tick=6031; runtime.tick{tick=6031}
eq(storage.agent_harness.visual_errors.count,1)
runtime.visuals.tick=saved

-- Speech bubbles (highlights): over Sol's character while the line is voiced.
local r=runtime.dispatch{action='highlights',operator=true,args={bubbles={{agent='sol',text='I will take the north wall',ttl=240}}}}
eq(r.drawn,2)
local bubble=objects[#objects]
eq(bubble.kind,'text'); eq(bubble.args.text,'I will take the north wall'); eq(bubble.args.target.entity,c); eq(bubble.args.time_to_live,240)
eq(objects[#objects-1].kind,'rectangle')
eq(runtime.dispatch{action='highlights',operator=true,args={bubbles={{agent='nobody',text='x'}}}}.skipped,1)
print('visuals: ok')
