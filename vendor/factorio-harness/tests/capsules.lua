-- Run from repository root: lua tests/capsules.lua
-- use_item (capsules.lua, request #89): throws with the game's projectile,
-- range, cooldown; raw fish on yourself; refusals. Through the runtime.
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


-- Capsule prototypes as the game describes them (capsule_action, attack_parameters).
prototypes=prototypes or {}
prototypes.item=prototypes.item or {}
prototypes.entity=prototypes.entity or {}
prototypes.item['grenade']={name='grenade',type='capsule',capsule_action={type='throw',attack_parameters={range=15,cooldown=30,
  ammo_type={action={{type='direct',action_delivery={{type='projectile',projectile='grenade',starting_speed=0.3}}}}}}}}
prototypes.item['poison-capsule']={name='poison-capsule',type='capsule',capsule_action={type='throw',attack_parameters={range=25,min_range=0,cooldown=30,
  ammo_type={action={{action_delivery={{type='projectile',projectile='poison-capsule'}}}}}}}}
prototypes.item['raw-fish']={name='raw-fish',type='capsule',capsule_action={type='use-on-self',attack_parameters={range=0,cooldown=30,
  ammo_type={action={{action_delivery={{type='instant',target_effects={{type='damage',damage={type='physical',amount=-80}}}}}}}}}}}
prototypes.item['cliff-explosives']={name='cliff-explosives',type='capsule',capsule_action={type='destroy-cliffs',attack_parameters={range=10}}}
prototypes.item['iron-plate']=prototypes.item['iron-plate'] or {name='iron-plate',type='item'}
local thrown={}
local make=surface.create_entity
surface.create_entity=function(args)
  if args.name=='grenade' or args.name=='poison-capsule' then thrown[#thrown+1]=args; return {valid=true,name=args.name} end
  return make(args)
end
local body=runtime.lookup(runtime.bots.index_of('astra')).character
local inv=body.get_main_inventory()
inv.remove=function(st) local n=math.min(body.items[st.name] or 0,st.count); body.items[st.name]=(body.items[st.name] or 0)-n; return n end
local at=body.position

-- A grenade: the game's own projectile from the character, at the target, one used.
body.items['grenade']=3
local r=astra('use_item',{item='grenade',position={x=at.x+10,y=at.y}})
eq(r.kind,'throw'); eq(r.projectile,'grenade'); eq(r.range,15); eq(r.distance,10); eq(r.left,2); eq(r.cooldown_ticks,30)
eq(#thrown,1); eq(thrown[1].source,body); eq(thrown[1].target.x,at.x+10); eq(thrown[1].force,body.force); eq(body.items['grenade'],2)
-- The capsule cooldown, then free again.
fails(function() astra('use_item',{item='grenade',position={x=at.x+5,y=at.y}}) end,'cooling down: 30 ticks left')
advance(30)
eq(astra('use_item',{item='grenade',position={x=at.x+5,y=at.y}}).left,1)
advance(30)
-- Out of range names the range; nothing is used.
fails(function() astra('use_item',{item='grenade',position={x=at.x+20,y=at.y}}) end,string.format('out of range: (%g,%g) is 20.0 tiles away; grenade reaches 15 tiles',at.x+20,at.y))
eq(body.items['grenade'],1); eq(#thrown,2)
-- A poison capsule reaches further.
body.items['poison-capsule']=1
eq(astra('use_item',{item='poison-capsule',position={x=at.x+20,y=at.y}}).projectile,'poison-capsule')
advance(30)
-- Raw fish heals the character.
body.items['raw-fish']=1; body.health=100
r=astra('use_item',{item='raw-fish'})
eq(r.kind,'self'); eq(r.healed,80); eq(body.health,180); eq(body.items['raw-fish'],0)
advance(30)
-- Refusals.
eq(astra('use_item',{item='grenade',position={x=at.x+5,y=at.y}}).left,0) -- the last one
advance(30)
fails(function() astra('use_item',{item='grenade',position={x=at.x+5,y=at.y}}) end,'no grenade held')
fails(function() astra('use_item',{item='iron-plate',position={x=at.x+5,y=at.y}}) end,'iron-plate is not a capsule')
body.items['cliff-explosives']=1
-- cliff explosives are thrown now (tests/cliffs.lua); with no cliff there, the call says so
fails(function() astra('use_item',{item='cliff-explosives',position={x=at.x+5,y=at.y}}) end,'no cliff within the blast')
body.items['grenade']=1
fails(function() astra('use_item',{item='grenade'}) end,'position is required')
fails(function() astra('use_item',{item='nonsense'}) end,'unknown item nonsense')
eq(body.items['grenade'],1)
print('capsules: ok')
