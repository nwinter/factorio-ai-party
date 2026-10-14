-- Run from repository root: lua tests/round1350d.lua
-- Round 13:50 part D (item 7): scan's kept rows and transfer's direction names, through the runtime against
-- tests/retreat.lua's fake engine.
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


-- Round 13:50 item 7 (Muse, 13:31): a scan with more than `limit` rows keeps the ones nearest its centre (the position
-- given, the character or the area's middle), listed in reading order, and says so; transfer takes to_machine and
-- from_machine (and to_building, from_building) as to_entity and to_player for every entity kind.
local world={}
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    local p=e.position
    if f.area then
      local lt,rb=f.area.left_top or f.area[1],f.area.right_bottom or f.area[2]
      if p.x>=(lt.x or lt[1]) and p.x<=(rb.x or rb[1]) and p.y>=(lt.y or lt[2]) and p.y<=(rb.y or rb[2]) then out[#out+1]=e end
    elseif f.position then
      if ((p.x-f.position.x)^2+(p.y-f.position.y)^2)^0.5<=(f.radius or 0.5) then out[#out+1]=e end
    else out[#out+1]=e end
  end
  return out
end
-- a field of belts from y=-25 to y=25 around (0,0): 51 rows of 51
for y=-25,25 do for x=-25,25 do world[#world+1]={valid=true,name='transport-belt',type='transport-belt',force=force,surface=surface,position={x=x+0.5,y=y+0.5}} end end
local body=runtime.lookup(runtime.bots.index_of('astra')).character
body.position={x=0,y=0}
local r=astra('scan',{position={x=0,y=0},radius=25,limit=100})
eq(#r.entities,100); eq(r.total,2500); eq(r.truncated,true)  -- (centres inside the 50x50 box)
-- the nearest 100 to (0,0): all within 6 tiles, none at the top edge, in reading order
local far=0
for _,row in ipairs(r.entities) do far=math.max(far,((row.position.x)^2+(row.position.y)^2)^0.5) end
assert(far<6.5,'kept rows reach '..far)
for i=2,#r.entities do
  local u,v=r.entities[i-1].position,r.entities[i].position
  assert(u.y<v.y or (u.y==v.y and u.x<v.x),'reading order')
end
eq(r.kept_nearest.centre.x,0); assert(r.kept_nearest.within<=far+0.01)
assert(r.kept_nearest.note:find('kept the 100 nearest (0,0)',1,true),r.kept_nearest.note)
-- the character's own spot when no position is given; an area's middle for an area
body.position={x=20.5,y=-20.5}
r=astra('scan',{radius=10,limit=10})
for _,row in ipairs(r.entities) do assert(math.abs(row.position.x-20.5)<=2 and math.abs(row.position.y+20.5)<=2,'near the character') end
r=astra('scan',{area={left_top={x=-20,y=-20},right_bottom={x=0,y=0}},limit=4})
eq(r.kept_nearest.centre.x,-10); eq(r.kept_nearest.centre.y,-10)
-- under the limit: everything, no kept_nearest
r=astra('scan',{position={x=0,y=0},radius=2,limit=100})
eq(r.truncated,false); eq(r.kept_nearest,nil); eq(#r.entities,r.total)
-- transfer direction names
local fix=runtime.aliases.fix
local function dir(d) local _,args=fix('transfer',{position={x=1,y=1},item='iron-plate',direction=d},function() return true end); return args.direction end
eq(dir('to_machine'),'to_entity'); eq(dir('from_machine'),'to_player'); eq(dir('to_building'),'to_entity'); eq(dir('from_building'),'to_player')
eq(dir('to_entity'),'to_entity')
assert(astra('describe',{}).actions.transfer.direction:find('to_machine, to_building = to_entity',1,true))
print('round1350d: ok')
