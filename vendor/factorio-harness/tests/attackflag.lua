-- Run from repository root: lua tests/attackflag.lua
-- The stream's attack flag (operator 13:40, viewer Joonazan 13:36): status combat's target, fired_tick, kills_10s and
-- hurt, and status hurt, through the runtime against tests/retreat.lua's fake engine.
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


-- What a shoot does now, and hits on the body (viewer Joonazan, 13:36: the stream called Sol's shoot auto guard by the
-- egg breeders, nothing in range, "under attack"). status combat: target, fired_tick, kills_10s, hurt; status hurt.
local enemy=game.forces.enemy
local foes={}
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(foes) do
    if e.valid and f.position and ((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5<=(f.radius or 1) then out[#out+1]=e end
  end
  return out
end
local a_body=runtime.lookup(runtime.bots.index_of('astra')).character
a_body.position={x=0,y=0}
a_body.get_inventory=function() return {get_item_count=function() return 10 end,is_empty=function() return false end} end
local function brief() return astra('status',{brief=true}) end
local function damaged(entity,by,cause,amount)
  runtime.on_event{name=defines.events.on_entity_damaged,tick=tick,entity=entity,force=by,cause=cause,final_damage_amount=amount}
end

-- A guard with nothing in range: a combat row, but no target, nothing fired, no hits.
astra('shoot',{auto=true,ticks=600})
advance(10)
local c=brief().combat
assert(c and c.auto,'the guard runs')
eq(c.target,nil,'no target'); eq(c.fired_tick,nil,'nothing fired'); eq(c.kills_10s,0); eq(c.hurt,nil); eq(brief().hurt,nil)
-- A biter comes in range: the target, and it fires.
local biter={valid=true,name='small-biter',type='unit',force=enemy,position={x=6,y=0},surface=surface,unit_number=70}
foes={biter}
advance(7)
c=brief().combat
eq(c.target.name,'small-biter'); eq(c.target.position.x,6); eq(c.target.distance,6); eq(c.fired_tick,tick)
-- It leaves: no target, the last fire stays where it was.
local fired=tick
biter.position={x=40,y=0}
advance(7)
c=brief().combat
eq(c.target,nil,'out of range'); eq(c.fired_tick,fired)
-- Hits by another force count; our own (a flamethrower's fire) do not.
damaged(a_body,force,nil,30)
eq(brief().hurt,nil,'friendly fire is no attack')
damaged(a_body,enemy,biter,15)
local h=brief().hurt
eq(h.by,'small-biter'); eq(h.damage,15); eq(h.ago_s,0); eq(h.at.x,40); eq(h.tick,tick); eq(h.what,nil)
eq(brief().combat.hurt.by,'small-biter')
advance(300); damaged(a_body,enemy,biter,10)
eq(brief().hurt.damage,25,'hits under 10 s apart add up')
advance(900)
eq(brief().hurt.ago_s,15)
damaged(a_body,enemy,nil,7)
h=brief().hurt
eq(h.damage,7,'a new episode'); eq(h.by,'enemy')
-- Kills by the character in the last 10 s (a guard runs again: a shoot lasts at most 600 ticks).
astra('shoot',{auto=true,ticks=600})
runtime.on_event{name=defines.events.on_entity_died,tick=tick,entity=biter,cause=a_body,force=force}
eq(brief().combat.kills_10s,1)
advance(590)
eq(brief().combat.kills_10s,1)
advance(11)
astra('shoot',{auto=true,ticks=600})
eq(brief().combat.kills_10s,0)
-- The vehicle it rides: a hit on it counts, named.
local car={valid=true,name='car',type='car',force=force,position={x=0,y=0},surface=surface,unit_number=900}
a_body.vehicle=car
advance(60)
damaged(car,enemy,biter,40)
h=brief().hurt
eq(h.what,'car'); eq(h.damage,40); eq(h.ago_s,0)
a_body.vehicle=nil
-- The full status carries the same, and hits older than 5 minutes are gone.
eq(astra('status').hurt.by,'enemy')  -- (out of the car: the character's own last hit, the one with no cause)
eq(astra('status').combat.kills_10s,0)
astra('stop',{})
advance(18001)
eq(brief().hurt,nil)
-- Without a shoot: no combat row, the hurt line still there while fresh.
damaged(a_body,enemy,biter,5)
eq(brief().combat,false); eq(brief().hurt.damage,5)
assert(astra('describe',{}).actions.status.reports:find('hurt (also in brief',1,true))
print('attackflag: ok')
