-- Run from repository root: lua tests/cliffs.lua
-- Cliff explosives by hand (capsules.lua clear_cliffs, use_item), through the runtime against tests/retreat.lua's
-- fake engine.
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
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
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


-- Cliff explosives by hand (Sol 15:41: use_item cliff-explosives at (82,38.5) on Gleba refused, "destroy-cliffs not
-- usable this way"): use_item and clear_cliffs throw the game's capsule projectile from within its range, one per spot,
-- each landing before the next; last names the cliffs destroyed and the explosives left.
prototypes={item={['cliff-explosives']={name='cliff-explosives',capsule_action={type='destroy-cliffs',radius=1.5,
  attack_parameters={range=10,cooldown=30,ammo_type={action={{action_delivery={{type='projectile',projectile='cliff-explosives'}}}}}}}},
  grenade={name='grenade',capsule_action={type='throw',attack_parameters={range=15,cooldown=30,ammo_type={action={{action_delivery={{type='projectile',projectile='grenade'}}}}}}}}},
  entity={}}
local world={}
local made={}
local function cliff(x,y) local e={valid=true,name='cliff-gleba',type='cliff',position={x=x,y=y},force={name='neutral'}}; world[#world+1]=e; return e end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    if e.valid and (not f.type or f.type==e.type) and f.position and ((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5<=(f.radius or 0.5) then out[#out+1]=e end
  end
  return out
end
surface.create_entity=function(args)
  if args.name=='character' then return {valid=true} end
  made[#made+1]=args
  return {valid=true,name=args.name}
end
local body=runtime.lookup(runtime.bots.index_of('astra')).character
body.position={x=75,y=38}
body.items['cliff-explosives']=4
local inv=body.get_main_inventory()
inv.remove=function(s) local have=body.items[s.name] or 0; local n=math.min(have,s.count); body.items[s.name]=have-n; return n end
local c1,c2=cliff(82,38.5),cliff(83,40)
local far=cliff(100,38)  -- (25 tiles: in sight, out of range)
-- the reply: the cliffs in each spot's blast; nothing thrown yet
local r=astra('use_item',{item='cliff-explosives',position={x=82,y=38.5}})
eq(#r.spots,1); eq(#r.spots[1].cliffs,2); eq(r.range,10); eq(r.blast_radius,1.5); eq(r.held,4)
advance(1)
eq(#made,1); eq(made[1].name,'cliff-explosives'); eq(made[1].target.x,82); eq(made[1].source,body); eq(body.items['cliff-explosives'],3)
-- the blast (the game's projectile effect): both cliffs go
c1.valid=false; c2.valid=false
advance(40)
local last=astra('status',{}).last
eq(last.kind,'clear_cliffs'); eq(last.outcome,'cliffs_destroyed'); eq(last.thrown,1); eq(#last.destroyed,2); eq(last.left,3)
eq(last.destroyed[1].name,'cliff-gleba')
-- a tour of two spots: the second has nothing left by the time it comes: skipped, not thrown
local c3=cliff(80,36)
made={}
r=astra('clear_cliffs',{positions={{x=80,y=36},{x=82,y=38.5}}})
eq(#r.spots[1].cliffs,1); eq(#r.spots[2].cliffs,0)
advance(31)  -- (cooldown from the last throw has passed)
eq(#made,1)
c3.valid=false
advance(40)
last=astra('status',{}).last
eq(last.outcome,'cliffs_destroyed'); eq(#last.destroyed,1); eq(#last.skipped,1); eq(last.skipped[1].why,'no cliff left in the blast'); eq(last.left,2)
-- refusals: no cliff in the blast (the nearest named), out of range without walk, not held, a grenade still throws
fails(function() astra('use_item',{item='cliff-explosives',position={x=90,y=30}}) end,'no cliff within the blast (radius 1.5) of (90,30); nearest cliff: cliff-gleba at (100,38), 12.8 tiles away')
fails(function() astra('use_item',{item='cliff-explosives',position={x=100,y=38}}) end,'out of range: (100,38) is 25.0 tiles away; cliff-explosives reaches 10 tiles (walk: true walks into range first)')
body.items['cliff-explosives']=0
fails(function() astra('clear_cliffs',{position={x=100,y=38}}) end,'no cliff-explosives held')
assert(astra('describe',{}).actions.clear_cliffs.returns:find('cliffs_destroyed',1,true))
print('cliffs: ok')
