-- Run from repository root: lua tests/ground.lua
-- Items on the ground (ground.lua) through the runtime against a fake engine:
-- scan/observe summaries, the spill and pile alerts (status, reply hints),
-- deconstruct items_on_ground, pickup over an area.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},
  direction={north=0,northeast=2,east=4,southeast=6,south=8,southwest=10,west=12,northwest=14},
  inventory={chest=1,cargo_landing_pad_main=2},build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local neutral={name='neutral'}
local surface={name='nauvis',index=1}
local world={}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},room=math.huge}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) local n=math.min(s.count,c.room); c.room=c.room-n; items[s.name]=(items[s.name] or 0)+n; return n end
  c.get_main_inventory=function() return inv end
  c.get_inventory=function() return inv end
  c.max_health=250
  c.prototype={collision_mask={layers={}},item_pickup_distance=1}
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
-- Entity queries as the engine filters them: type, name, force, area,
-- position+radius, to_be_deconstructed, limit; invert flips the type filter.
local function listed(v,x) for _,y in ipairs(type(v)=='table' and v or {v}) do if y==x then return true end end return false end
local function match(e,f)
  if not e.valid then return false end
  if f.type and listed(f.type,e.type)==(f.invert==true) then return false end
  if f.name and not listed(f.name,e.name) then return false end
  if f.force and e.force.name~=(type(f.force)=='table' and f.force.name or f.force) then return false end
  local pos=e.position
  if f.area then
    local lt,rb=f.area.left_top or f.area[1],f.area.right_bottom or f.area[2]
    if pos.x<lt.x or pos.x>rb.x or pos.y<lt.y or pos.y>rb.y then return false end
  end
  if f.position then
    local r=f.radius or 0.5
    if (pos.x-f.position.x)^2+(pos.y-f.position.y)^2>r*r then return false end
  end
  if f.to_be_deconstructed~=nil and e.marked~=f.to_be_deconstructed then return false end
  return true
end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    if match(e,f) then out[#out+1]=e; if f.limit and #out>=f.limit then break end end
  end
  return out
end
surface.count_entities_filtered=function(f) local g={}; for k,v in pairs(f) do g[k]=v end; g.limit=nil; return #surface.find_entities_filtered(g) end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
local paths={}
surface.request_path=function(r) paths[#paths+1]={id=#paths+1,goal=r.goal}; return #paths end
local networks={}
surface.find_logistic_networks_by_construction_area=function(pos) return networks end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local players={nick}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,surfaces={nauvis=surface},forces={player=force,neutral=neutral,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
-- A character walks 0.2 tiles a tick the way its walking_state points; x>=50 is a wall.
local STEP={[0]={0,-1},[2]={0.7,-0.7},[4]={1,0},[6]={0.7,0.7},[8]={0,1},[10]={-0.7,0.7},[12]={-1,0},[14]={-0.7,-0.7}}
local walkers={}
local function advance(n)
  for _=1,n do
    for _,c in ipairs(walkers) do
      local w=c.walking_state
      if w and w.walking then
        local d=STEP[w.direction]
        local x=c.position.x+d[1]*0.2
        if x<50 then c.position={x=x,y=c.position.y+d[2]*0.2} end
      end
    end
    tick=tick+1; game.tick=tick; runtime.tick{tick=tick}
    -- The pathfinder answers at once: straight to the goal.
    while #paths>0 do
      local r=table.remove(paths,1)
      runtime.on_event{name=defines.events.on_script_path_request_finished,id=r.id,path={{position=r.goal}}}
    end
  end
end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.bot and runtime.bots.index_of(req.bot) or nil
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end

-- The world: our chest, a pile of iron plates beside it, a full landing pad
-- with spilled science and carbon around it.
local function add(e) e.valid=true; world[#world+1]=e; return e end
local function stack_at(name,count,x,y)
  local e={type='item-entity',name='item-on-ground',force=neutral,position={x=x,y=y},marked=false}
  e.stack={valid_for_read=true,name=name,count=count,quality={name='normal'}}
  e.destroy=function() e.valid=false; e.stack.valid_for_read=false end
  e.to_be_deconstructed=function() return e.marked end
  e.order_deconstruction=function(f) if e.marked then return false end e.marked=true; return true end
  e.cancel_deconstruction=function() e.marked=false end
  return add(e)
end
add{type='container',name='iron-chest',force=force,position={x=10.5,y=10.5}}
for i=0,149 do stack_at('iron-plate',100,20+(i%15),20+math.floor(i/15)) end
local pad=add{type='cargo-landing-pad',name='cargo-landing-pad',force=force,position={x=-66,y=28}}
local pad_inv=setmetatable({count_empty_stacks=function() return 0 end},{__len=function() return 80 end})
pad.get_inventory=function(i) eq(i,defines.inventory.cargo_landing_pad_main); return pad_inv end
for i=0,79 do stack_at('space-science-pack',200,-60+(i%10),30+math.floor(i/10)) end
for i=0,39 do stack_at('carbon',50,-75+(i%10),20+math.floor(i/10)) end
-- The bot's first reply runs the first watch pass.
local astra=as('astra')
runtime.operator.bot_create('astra')
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
local body=runtime.lookup(runtime.bots.index_of('astra')).character
body.position={x=0,y=0}
walkers[1]=body

-- scan: items on the ground as a summary by item, not 150 rows.
local r=astra('scan',{position={x=25,y=25},radius=16})
eq(#r.entities,1); eq(r.entities[1].name,'iron-chest')
eq(r.ground_items.stacks,150); eq(r.ground_items.items[1].name,'iron-plate'); eq(r.ground_items.items[1].count,15000)
eq(r.ground_items.items[1].box.left_top.x,20); eq(r.ground_items.items[1].box.right_bottom.y,29)
-- Filtered for them: rows, as before.
r=astra('scan',{position={x=25,y=25},radius=16,type='item-entity',limit=5})
eq(#r.entities,5); eq(r.truncated,true); eq(r.ground_items,nil)
-- No items: no ground_items key.
eq(astra('scan',{position={x=200,y=200},radius=4}).ground_items,nil)
-- observe: the same summary; rows only with entity filters.
r=astra('observe',{position={x=25,y=25},radius=16})
eq(r.ground_items.stacks>0,true); assert(not has((function() local n={} for i,e in ipairs(r.entities) do n[i]=e.name end return n end)(),'item-on-ground'))
r=astra('observe',{position={x=25,y=25},radius=16,entity_types={'item-entity'},limit=3})
eq(#r.entities,3); eq(r.ground_items,nil)

-- status alerts: the spilling pad and the pile near our chest.
local st=astra('status')
local lines=st.alerts.ground_items
local pad_line=has(lines,'cargo landing pad at (-66,28) on nauvis is full (80/80 slots) and pods spill: 120 item stacks on the ground within 40 tiles')
assert(pad_line,table.concat(lines,'\n'))
assert(pad_line:find('16000 space-science-pack, 2000 carbon',1,true),pad_line)
local pile=has(lines,'150 item stacks on the ground at (20,20)-(34,29) on nauvis, near our buildings: 15000 iron-plate')
assert(pile,table.concat(lines,'\n'))
-- The pad's spill is not reported again as a pile.
eq(#lines,2)
-- A pile far from our buildings is not an alert.
for i=0,119 do stack_at('stone',50,300+(i%10),300+math.floor(i/10)) end
-- The watch is cached for 30 s: same lines; the reply hints carried them once.
eq(#astra('status').alerts.ground_items,2)
-- Reply hints: once (the status replies above already showed them), then not again.
r=astra('scan',{position={x=200,y=200},radius=2})
assert(not has(r.team and r.team.alerts,'item stacks'),'seen lines repeat')
-- A pile that grows by half is told again after the next pass.
for i=0,99 do stack_at('iron-plate',100,20+(i%15),31+math.floor(i/15)) end
advance(1800)
r=astra('scan',{position={x=200,y=200},radius=2})
local again=has(r.team and r.team.alerts,'250 item stacks on the ground at (20,20)')
assert(again,'grown pile not told again')
eq(has(r.team.alerts,'cargo landing pad'),nil)
r=astra('scan',{position={x=200,y=200},radius=2}); eq(has(r.team and r.team.alerts,'item stacks'),nil)
eq(has(astra('status').alerts.ground_items,'(300,300)'),nil)
-- A pad with free slots is not spilling.
pad_inv.count_empty_stacks=function() return 3 end
advance(1800)
eq(has(astra('status').alerts.ground_items or {},'cargo landing pad'),nil)
pad_inv.count_empty_stacks=function() return 0 end

-- deconstruct items_on_ground: every stack in the area marked, our chest left alone.
local area={left_top={x=0,y=0},right_bottom={x=40,y=40}}
r=astra('deconstruct',{area=area,items_on_ground=true})
eq(r.item_stacks,250); eq(r.items[1].name,'iron-plate'); eq(r.items[1].count,25000); eq(r.items[1].stacks,250); eq(r.items[1].box,nil)
eq(r.robot_networks,0); eq(r.storage_chests,0); eq(r.outside_construction_area,250); eq(r.changed,0)
eq(world[1].marked,nil)
r=astra('deconstruct',{area=area,items_on_ground=true})
eq(r.item_stacks,0); eq(r.item_stacks_already,250)
r=astra('cancel_deconstruction',{area=area,items_on_ground=true})
eq(r.item_stacks,250)
-- Inside a roboport's construction area: the network and its storage chests are counted.
networks={{network_id=7,storages={{},{}}}}
r=astra('deconstruct',{area=area,items_on_ground=true})
eq(r.robot_networks,1); eq(r.storage_chests,2); eq(r.outside_construction_area,nil)
networks={}
astra('cancel_deconstruction',{area=area,items_on_ground=true})
-- With entity filters the chest is marked too; tiles is a separate call.
local chest=world[1]
chest.minable=true; chest.order_deconstruction=function() chest.marked=true; return true end; chest.to_be_deconstructed=function() return chest.marked==true end
r=astra('deconstruct',{area=area,items_on_ground=true,entity_types={'container'}})
eq(r.item_stacks,250); eq(r.changed,1); eq(chest.marked,true)
chest.marked=false
astra('cancel_deconstruction',{area=area,items_on_ground=true})
fails(function() astra('deconstruct',{area=area,items_on_ground=true,tiles=true}) end,'items_on_ground and tiles are separate calls')
fails(function() astra('deconstruct',{area=area,items_on_ground='yes'}) end,'items_on_ground must be boolean')

-- pickup over an area: refused when nothing is there.
fails(function() astra('pickup',{position={x=0,y=-20},radius=4}) end,'no items on the ground in (-4,-24)-(4,-16)')
fails(function() astra('pickup',{area={left_top={x=0,y=0},right_bottom={x=100,y=10}}}) end,'at most 64x64')
-- Three copper stacks east of the bot and a coal one: it walks to each and picks them up.
local c1,c2,c3=stack_at('copper-plate',100,3,0),stack_at('copper-plate',40,3.5,0),stack_at('copper-plate',100,6,1)
local coal=stack_at('coal',50,-4,0)
r=astra('pickup',{position={x=0,y=0},radius=8,items={'copper-plate'}})
eq(r.item_stacks,3); eq(r.items[1].name,'copper-plate'); eq(r.items[1].count,240)
eq(astra('status').active.kind,'pickup')
advance(400)
local last=astra('status').last
eq(last.kind,'pickup'); eq(last.outcome,'picked_up'); eq(last.picked['copper-plate'],240); eq(last.left,0)
eq(c1.valid,false); eq(c2.valid,false); eq(c3.valid,false); eq(coal.valid,true)
eq(body.items['copper-plate'],240)
-- Inventory full: stops with what it took.
body.room=30
r=astra('pickup',{position={x=0,y=0},radius=8})
advance(400)
last=astra('status').last
eq(last.outcome,'inventory_full'); eq(last.picked.coal,30); eq(coal.stack.count,20); eq(last.left,1)
body.room=math.huge
-- A stack it cannot walk to (beyond the wall at x=50): blocked, the rest picked up.
body.position={x=45,y=0}
local near=stack_at('stone',5,46,0)
local far=stack_at('stone',5,55,0)
astra('pickup',{area={left_top={x=40,y=-5},right_bottom={x=60,y=5}},ticks=3000})
advance(3000)
last=astra('status').last
eq(near.valid,false); eq(far.valid,true)
eq(last.outcome,'blocked'); eq(last.skipped,1); eq(last.left,1)
-- Time up: timed_out, not duration_elapsed.
body.position={x=0,y=0}
stack_at('wood',5,30,-30)
astra('pickup',{area={left_top={x=0,y=-40},right_bottom={x=40,y=0}},ticks=20})
advance(30)
eq(astra('status').last.outcome,'timed_out')
-- The plain pickup is unchanged: refused with nothing in reach.
fails(function() astra('pickup',{}) end,'nothing to pick up within 1 tiles')
print('ground: ok')
