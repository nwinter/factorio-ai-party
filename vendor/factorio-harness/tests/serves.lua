-- Run from repository root: lua tests/serves.lua
-- What a standing order or a recurring reminder serves (serves.lua; d20 batch50 B2, viewer Aurora): order_set and
-- reminder_add take serves {name, position, surface?, radius?}; the reads and lines flag one whose machine is gone, with
-- the tick it was last seen. Fake engine as tests/orders.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,text) assert(type(s)=='string' and s:find(text,1,true),'missing "'..text..'" in: '..tostring(s)) end
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
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
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
-- the boilers our force has (name, position); count_entities_filtered counts them as the game does in a circle
local machines={{name='boiler',position={x=7,y=42}},{name='boiler',position={x=10,y=42}},{name='steam-engine',position={x=8,y=46}}}
surface.count_entities_filtered=function(f)
  if not (f.name and f.position) then return 0 end
  local n=0
  for _,m in ipairs(machines) do
    if m.name==f.name and (m.position.x-f.position.x)^2+(m.position.y-f.position.y)^2<=(f.radius or 0)^2 then n=n+1 end
  end
  return n
end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
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
local astra,sol=as('astra'),as('sol')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol')
local body=runtime.bots.lookup(runtime.bots.index_of('astra')).character
local function report(name)
  for _,row in ipairs(op('idle_report',{}).agents) do if row.name==name then return row end end
end
local function running() local q=astra('queue_status'); return q.order and q.order.name,q end
-- advance until the named order runs (or n ticks pass)
local wait=function(ticks) return {action='wait_ticks',args={ticks=ticks}} end
astra('status'); sol('status')

-- Haiku's boilerfuel as it stood in shift45 (when fuel_below coal 20 within 20 of (8.5,42)), now naming what it serves.
local fuel={['until']='fuel_below',item='coal',count=20,radius=20,position={x=8.5,y=42}}
local r=astra('order_set',{name='boilerfuel',when=fuel,steps={wait(60)},priority=6,cooldown_ticks=1800,
  serves={name='boiler',position={x=8.5,y=42},radius=20}})
local sv=r.order.serves
eq(sv.count,2); eq(sv.surface,'nauvis'); eq(sv.radius,20); eq(sv.gone,nil); eq(sv.last_seen_tick,tick)
eq(sv.line,'serves boiler within 20 of (8.5,42) on nauvis: 2 there (tick '..tick..')')
local o=astra('status').orders
assert(not o:find('serves',1,true),o) -- present: nothing in the orders line
-- one machine at a spot (no radius: within 1 tile)
r=astra('order_set',{name='engine',steps={wait(60)},interval_ticks=36000,serves={name='steam-engine',position={x=8,y=46}}})
eq(r.order.serves.count,1); eq(r.order.serves.radius,nil)
local seen=tick
-- the boilers are removed (Haiku, shift45 06:16); the check about once a game minute finds none
advance(600)
machines={}
advance(3700)
o=astra('status').orders
has(o,'boilerfuel serves boiler within 20 of (8.5,42) on nauvis: none there since tick ')
has(o,'; last seen tick '..seen..', ')
has(o,'engine serves steam-engine at (8,46) on nauvis: none there since tick ')
local list=astra('orders').list
eq(list[1].serves.gone,true); eq(list[1].serves.count,0); eq(list[1].serves.last_seen_tick,seen)
assert(list[1].serves.gone_tick>seen+600 and list[1].serves.gone_tick<=tick,list[1].serves.gone_tick)
-- one set for something not built yet: never seen
r=astra('order_set',{name='later',steps={wait(60)},when=fuel,serves={name='boiler',position={x=100,y=100}}})
has(r.order.serves.line,'not seen since it was set at tick '..tick)
-- built again: no flag
machines={{name='boiler',position={x=100,y=100.5}}}
eq(astra('orders').list[3].serves.gone,nil)
-- refusals
fails(function() astra('order_set',{name='x',steps={wait(60)},when=fuel,serves={name='boiler'}}) end,'serves.position {x,y} is required')
fails(function() astra('order_set',{name='x',steps={wait(60)},when=fuel,serves={name='boiler',position={x=0,y=0},radius=65}}) end,'serves.radius: 0..64')
fails(function() astra('order_set',{name='x',steps={wait(60)},when=fuel,serves='boiler'}) end,'serves is {name, position')

-- A recurring reminder (Muse's nest check, #103 in shift45) names what it serves; its line and its sends flag it once gone.
machines={{name='biter-spawner',position={x=-40,y=12}}}
local rem=sol('reminder_add',{name='nest check',message='captive nest fuel and eggs',every_ticks=3600,
  serves={name='biter-spawner',position={x=-40,y=12}}}).reminder
eq(rem.serves.count,1)
machines={}
advance(3700)
local tells=sol('status').team.tells or {}
local line
for _,t in ipairs(tells) do if t:find('nest check',1,true) then line=t end end
has(line,'serves biter-spawner at (-40,12) on nauvis: none there since tick ')
local rows=sol('reminders',{}).reminders
eq(rows[1].serves.gone,true); has(rows[1].line,'serves biter-spawner at (-40,12) on nauvis: none there since tick ')
sol('reminder_edit',{id=rows[1].id,serves=false})
eq(sol('reminders',{}).reminders[1].serves,nil)
print('serves: ok')
