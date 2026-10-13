-- Run from repository root: lua tests/highlights.lua
-- Camera highlights (highlights.lua): drawn for the director camera clients
-- only, replaced by each call, expiring on their own; operator-only (Nick
-- 12:58: show what the agents act on inside the camera picture).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
-- The renderer records every object and who may see it.
local objects={}
local function obj(kind,args)
  local o={id=#objects+1,valid=true,kind=kind,args=args}
  o.destroy=function() o.valid=false end
  objects[#objects+1]=o
  return o
end
rendering={draw_text=function(a) return obj('text',a) end,draw_circle=function(a) return obj('circle',a) end,
  draw_line=function(a) return obj('line',a) end,get_object_by_id=function(id) return objects[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1,valid=true}
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=700,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
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
-- Player 1: a human agent; player 2: the camera client pog-cam1.
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local cam={index=2,name='pog-cam1',valid=true,connected=false,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=0,y=0}}
local players={nick,cam}
for _,pl in ipairs(players) do pl.print=function() end end
local connected={nick}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) if n=='nauvis' or n==1 then return surface end end,print=function() end,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
setmetatable(game,{__index=function(_,k) if k=='connected_players' then return connected end end})
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
runtime.operator.bot_create('sol')
local sol_bot=runtime.bots.record(runtime.bots.index_of('sol'))
sol_bot.character.position={x=0,y=0}
runtime.dispatch{action='profile',args={display_name='Sol',glyph='S',color='#ffcb45'},bot='sol'}
local function op(args) return runtime.dispatch{action='highlights',args=args,operator=true} end
-- Objects drawn from here on (nametags drew theirs above).
local base=#objects
local function mine() local out={}; for i=base+1,#objects do out[#out+1]=objects[i] end; return out end
local function live() local n=0; for _,o in ipairs(mine()) do if o.valid then n=n+1 end end; return n end

local items={{agent='sol',position={x=30,y=0},extent=6,label='Sol · placing ghosts'},{agent='sol',position={x=3,y=0},label='Sol · inspecting'}}
-- No camera client connected: nothing is drawn (an empty players list would show it to everyone).
local r=op{items=items}
eq(r.drawn,0); eq(#mine(),0); assert(r.note:find('no camera client',1,true))
-- With the camera connected: ring and label on each spot, a line from Sol to the far one only; only the camera sees them.
cam.connected=true; connected={nick,cam}
r=op{items=items,ttl=300}
eq(r.drawn,6); eq(r.players[1],2); eq(#r.players,1)
local kinds={}
local drawn=mine()
for _,o in ipairs(drawn) do
  kinds[o.kind]=(kinds[o.kind] or 0)+1
  eq(#o.args.players,1); eq(o.args.players[1],2,'only the camera player sees it'); eq(o.args.time_to_live,300)
end
eq(kinds.circle,2); eq(kinds.text,3); eq(kinds.line,1)
local ring=drawn[1].args
eq(ring.radius,3.8); eq(ring.target.x,30); eq(ring.width,3,'acting: a bold ring')
local p=runtime.profiles.get(runtime.bots.index_of('sol'))
eq(ring.color.r,p.rgb.r,'Sol\'s colour')
eq(drawn[2].args.text,'Sol · placing ghosts')
eq(drawn[3].args.from,sol_bot.character); eq(drawn[3].args.to.x,30); eq(drawn[3].args.dash_length,1)
-- The label again on the line near Sol, 4 tiles toward the spot, with the distance (the spot may be off screen).
local close=drawn[4].args
eq(close.text,'Sol · placing ghosts · 30 m'); eq(close.target.entity,sol_bot.character); eq(close.target.offset[1],4)
local function near(a,b,m) assert(math.abs(a-b)<1e-9,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
-- Looking reads apart: a thin ring and a dotted line; alpha fades the colour; an item's own ttl.
r=op{items={{agent='sol',position={x=0,y=20},kind='looking',alpha=0.5,ttl=120,label='Sol · inspecting {entity}'}}}
drawn={}
for _,o in ipairs(mine()) do if o.valid then drawn[#drawn+1]=o end end
eq(drawn[1].args.width,1.5); eq(drawn[1].args.time_to_live,120); eq(drawn[1].args.color.a,0.5)
near(drawn[1].args.color.r,p.rgb.r*0.5)
eq(drawn[2].args.text,'Sol · inspecting','{entity} with nothing there: dropped')
eq(drawn[3].args.dash_length,0.25)
-- {entity}: what stands at the spot.
surface.find_entities_filtered=function(f)
  if f.radius and f.position and f.position.y==20 then return {{valid=true,type='ammo-turret',name='gun-turret'}} end
  return {}
end
op{items={{agent='sol',position={x=0,y=20},kind='looking',label='Sol · inspecting {entity}'}}}
local texts={}
for _,o in ipairs(mine()) do if o.valid and o.kind=='text' then texts[#texts+1]=o.args.text end end
eq(texts[1],'Sol · inspecting gun turret'); eq(texts[2],'Sol · inspecting gun turret · 20 m')
surface.find_entities_filtered=function() return {} end
assert(not pcall(op,{items={{position={x=1,y=1},alpha=2}}}),'alpha out of range accepted')
-- Each call replaces the last set.
r=op{items={{position={x=1,y=1},color={r=0,g=1,b=0}}}}
eq(r.drawn,1); eq(live(),1); eq(objects[#objects].args.color.g,1)
-- clear removes it.
op{clear=true}; eq(live(),0)
-- Bad input changes nothing.
op{items={{position={x=1,y=1}}}}
fails(function() op{items={{position={x='a'}}}} end,'items[1].position {x,y} is required')
fails(function() op{items={{position={x=1,y=1},extent=500}}} end,'extent must be 0..200')
fails(function() op{items={{position={x=1,y=1}}},ttl=5} end,'ttl must be 30..1800')
local many={}
for i=1,13 do many[i]={position={x=i,y=0}} end
fails(function() op{items=many} end,'at most 12')
eq(live(),1,'a refused call leaves the last set')
-- An unknown surface is skipped.
eq(op{items={{position={x=1,y=1},surface='vulcanus'}}}.skipped,1)
-- Agents cannot reach it: not an action, not in describe.
fails(function() runtime.dispatch{action='highlights',args={items=items},bot='sol'} end,'unsupported action')
assert(not runtime.dispatch{action='describe',args={},bot='sol'}.actions.highlights)
print('highlights: ok')
