-- Run from repository root: lua tests/minerotate.lua
-- Mine reach and rotate (Grok 01:51: "Mine says reach 10 but fails at 3 to 8 tiles, and the suggested stand tile is
-- often still out of reach ... Rotate turns a belt 180 degrees"). The fake engine reaches as the game did on world n at
-- 01:58: the distance from the character to the entity's collision box, within 10 for buildings and within 2.7
-- (resource_reach_distance) for ore and trees. The shapes are Grok's shift09 ones: tree-04 at (-69.5625,-115.063) 3.8
-- tiles from the character, stone ore at (72.5,-54.5), a belt run turned north to east to south by two calls each.
-- Fake engine as tests/remotepassive.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={},entity={}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end}
local neutral={name='neutral'}
local surface={name='nauvis',index=1}
local world={}
local function box_distance(pos,e)
  local b=e.bounding_box
  local dx=math.max(b.left_top.x-pos.x,0,pos.x-b.right_bottom.x)
  local dy=math.max(b.left_top.y-pos.y,0,pos.y-b.right_bottom.y)
  return (dx*dx+dy*dy)^0.5
end
local SHORT={resource=true,tree=true}
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=501,health=250,max_health=250,
    driving=false,build_distance=10,reach_distance=10,resource_reach_distance=2.7,character_running_speed=0.15,walking_state={walking=false},
    prototype={mining_speed=0.5,collision_mask={layers={player=true}}}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  -- The engine's rule, as read on world n.
  c.can_reach_entity=function(e) return box_distance(c.position,e)<=(SHORT[e.type] and 2.7 or 10) end
  c.destroy=function() c.valid=false end
  return c
end
-- Free ground: the tile centre of the asked point (nothing here collides with a character).
surface.find_non_colliding_position=function(_,pos) return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5} end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    if e.valid and f.position and math.abs(e.position.x-f.position.x)<0.3 and math.abs(e.position.y-f.position.y)<0.3 and (not f.name or f.name==e.name) then out[#out+1]=e end
  end
  return out
end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local players={nick}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then error(result,0) end
  return result
end
runtime.operator.bot_create('grok')
local function grok(action,args) return request{action=action,args=args or {},bot='grok'} end
local body=runtime.bots.lookup(runtime.bots.index_of('grok')).character
body.prototype={mining_speed=0.5,collision_mask={layers={player=true}}}
body.resource_reach_distance=2.7
body.can_reach_entity=function(e) return box_distance(body.position,e)<=(SHORT[e.type] and 2.7 or 10) end
local function thing(name,type_,x,y,half,extra)
  local e={valid=true,name=name,type=type_,position={x=x,y=y},force=(type_=='tree' or type_=='resource') and neutral or force,
    bounding_box={left_top={x=x-half,y=y-half},right_bottom={x=x+half,y=y+half}},minable=true,
    prototype={mineable_properties={mining_time=0.5,products={{type='item',name='wood',amount=4}}}},direction=0}
  for k,v in pairs(extra or {}) do e[k]=v end
  world[#world+1]=e
  return e
end
-- The spot in a refusal: within the reach the engine applies, by its rule.
local function spot_of(text)
  local x,y=text:match('in reach from %(([%-%d.]+),([%-%d.]+)%)')
  return x and {x=tonumber(x),y=tonumber(y)} or nil
end

-- 1. Grok's tree, 3.8 tiles from the character's centre (08:45:03): refused with reach 2.7 and a spot that reaches it.
-- Before: "is 3.8 tiles away, reach 10; in reach from (-61.1,-115.7)", a spot 8.5 tiles off, farther than the character.
local tree=thing('tree-04','tree',-69.5625,-115.063,0.4)
body.position={x=-65.7734375,y=-115.36328125}
local ok,err=pcall(grok,'mine',{position={x=-69.5625,y=-115.063},ticks=120})
eq(ok,false)
assert(tostring(err):find('entity is out of reach: tree-04 at (-69.5625,-115.063) is 3.4 tiles away (to its edge), reach 2.7 (ore, trees and rocks)',1,true),tostring(err))
local spot=spot_of(tostring(err)); assert(spot,'a spot is named: '..tostring(err))
assert(box_distance(spot,tree)<=2.7,'the spot reaches the tree: '..box_distance(spot,tree))
body.position=spot
grok('mine',{position={x=-69.5625,y=-115.063},ticks=120})
eq(grok('status').active.kind,'mine')
-- Walked off mid-mine: last says why in the same words.
body.position={x=-60,y=-115.3}
advance(1)
local last=grok('status').last
eq(last.outcome,'out_of_reach'); assert(last.error and last.error:find('reach 2.7 (ore, trees and rocks)',1,true),tostring(last.error))
tree.valid=false

-- 2. Grok's stone ore at (72.5,-54.5), 3.8 tiles off (08:21:00): reach 2.7; the spot reaches it.
local ore=thing('stone','resource',72.5,-54.5,0.1)
body.position={x=76.3,y=-54.5}
ok,err=pcall(grok,'mine',{position={x=72.5,y=-54.5}})
eq(ok,false); assert(tostring(err):find('stone at (72.5,-54.5) is 3.7 tiles away (to its edge), reach 2.7',1,true),tostring(err))
spot=spot_of(tostring(err)); assert(spot and box_distance(spot,ore)<=2.7,tostring(err))
ore.valid=false

-- 3. Buildings: reach 10 to the collision box. A 3x3 assembler 11.4 from its centre is 10.0 from its box: in reach;
-- 11.8 from its centre (10.4 to the box) is out, and the spot reaches it.
local asm=thing('assembling-machine-2','assembling-machine',11.4,0,1.4,{rotate=function() return false end})
body.position={x=0,y=0}
eq(grok('rotate',{position={x=11.4,y=0}}).rotated,false)
asm.position.x=11.8; asm.bounding_box={left_top={x=10.4,y=-1.4},right_bottom={x=13.2,y=1.4}}
ok,err=pcall(grok,'rotate',{position={x=11.8,y=0}})
eq(ok,false); assert(tostring(err):find('assembling-machine-2 at (11.8,0) is 10.4 tiles away (to its edge), reach 10;',1,true),tostring(err))
spot=spot_of(tostring(err)); assert(spot and box_distance(spot,asm)<=10,tostring(err))
asm.valid=false
-- A target the engine refuses inside the long reach gets the short one (a rock, say).
local rock=thing('big-rock','simple-entity',4,0,0.9)
body.can_reach_entity=function(e) return box_distance(body.position,e)<=(SHORT[e.type] and 2.7 or e.type=='simple-entity' and 2.7 or 10) end
ok,err=pcall(grok,'mine',{position={x=4,y=0}})
eq(ok,false); assert(tostring(err):find('big-rock at (4,0) is 3.1 tiles away (to its edge), reach 2.7 (ore, trees and rocks)',1,true),tostring(err))
rock.valid=false

-- 4. Rotate: one call is one 90-degree turn clockwise; reverse counter-clockwise; direction turns until it faces that
-- way; the reply names before and after.
local belt=thing('transport-belt','transport-belt',2.5,0.5,0.4)
belt.rotate=function(o) belt.direction=(belt.direction+(o.reverse and -4 or 4))%16; return true end
local r=grok('rotate',{position={x=2.5,y=0.5}})
eq(r.before,'north'); eq(r.after,'east'); eq(r.turns,1); eq(r.rotated,true)
r=grok('rotate',{position={x=2.5,y=0.5},reverse=true})
eq(r.before,'east'); eq(r.after,'north'); eq(r.turns,1)
-- Grok's run (08:51:51): north to south took two calls; with direction it is one, two turns.
r=grok('rotate',{position={x=2.5,y=0.5},direction='south'})
eq(r.before,'north'); eq(r.after,'south'); eq(r.turns,2); eq(belt.direction,8)
-- The reply's entity says where the belt moves items now (beltflow.lua; Grok, shift11: south is +y).
eq(r.entity.belt,'moves items south to (2.5,1.5) (no belt takes them there: they stop at its end); no belt feeds it')
-- The shorter way round: south to east is one turn counter-clockwise.
r=grok('rotate',{position={x=2.5,y=0.5},direction='east'})
eq(r.after,'east'); eq(r.turns,1)
r=grok('rotate',{position={x=2.5,y=0.5},direction=12})
eq(r.after,'west'); eq(r.turns,2)
r=grok('rotate',{position={x=2.5,y=0.5},direction='west'})
eq(r.rotated,false); eq(r.turns,0); eq(r.note,'it faces west already')
fails(function() grok('rotate',{position={x=2.5,y=0.5},direction='up'}) end,'direction must be a compass name')
fails(function() grok('rotate',{position={x=2.5,y=0.5},direction='east',reverse=true}) end,'give direction or reverse, not both')
-- An underground belt flips end and direction on each rotate: east from west is one turn; north is out of reach of it.
local under=thing('underground-belt','underground-belt',3.5,2.5,0.4,{direction=12,belt_to_ground_type='input'})
under.rotate=function() under.direction=(under.direction+8)%16; return true end
r=grok('rotate',{position={x=3.5,y=2.5},direction='east'})
eq(r.after,'east'); eq(r.turns,1)
fails(function() grok('rotate',{position={x=3.5,y=2.5},direction='north'}) end,'underground-belt at (3.5,2.5) faces')
print('minerotate: ok')
