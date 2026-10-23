-- Run from repository root: lua tests/d22_batch118.lua
-- d22 batch118. CA3 (opus, shift62 06:26): transfer {unit_number, no position} to a spidertron's ammo failed with
-- "attempt to index local 'pos' (a nil value)"; the entity is now found by its number. CA4 (Luna, shift62 03:58,
-- viewer Aurora site:4385): a take of wood at a Gleba chest's position, made from Nauvis, walked 512 tiles to the
-- solar panel on that tile there; a walking transfer now finds the inventory it uses before the walk, refuses an
-- entity without one, and its legs name the inventory and the surface. Fixture: tests/picksource.lua's.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},
  inventory={chest=1,character_main=1,fuel=1,spider_ammo=4,spider_trunk=5},build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={},entity={},quality={normal={name='normal'}}}
for _,name in ipairs({'yumako-seed','jellynut-seed','wooden-chest','iron-plate','wood'}) do prototypes.item[name]={name=name,type='item',stack_size=50} end
prototypes.item.rocket={name='rocket',type='ammo',stack_size=200}
-- Slot-level inventories (as tests/round0620a.lua).
local function slot()
  local s={valid_for_read=false,count=0}
  function s.clear() s.valid_for_read=false; s.name=nil; s.count=0; s.quality=nil end
  function s.transfer_stack(src,amount)
    amount=math.min(amount or src.count,src.count)
    if s.valid_for_read and (s.name~=src.name or s.quality.name~=src.quality.name) then return false end
    local n=math.min(prototypes.item[src.name].stack_size-(s.valid_for_read and s.count or 0),amount)
    if n<=0 then return false end
    if not s.valid_for_read then s.valid_for_read=true; s.name=src.name; s.quality={name=src.quality.name}; s.count=0 end
    s.count=s.count+n; src.count=src.count-n
    if src.count==0 then src.clear() end
    return true
  end
  return s
end
local function inventory(size)
  local inv={valid=true}
  for i=1,size do inv[i]=slot() end
  local function q(x) return type(x.quality)=='table' and x.quality.name or x.quality or 'normal' end
  function inv.insert(x)
    local name,count,quality=x.name,x.count,q(x)
    local left=count
    for pass=1,2 do
      for i=1,#inv do
        local s=inv[i]
        if left>0 and ((pass==1 and s.valid_for_read and s.name==name and s.quality.name==quality) or (pass==2 and not s.valid_for_read)) then
          if not s.valid_for_read then s.valid_for_read=true; s.name=name; s.quality={name=quality}; s.count=0 end
          local n=math.min(prototypes.item[name].stack_size-s.count,left); s.count=s.count+n; left=left-n
        end
      end
    end
    return count-left
  end
  function inv.get_item_count(f)
    local name=type(f)=='table' and f.name or f
    local n=0
    for i=1,#inv do local s=inv[i]; if s.valid_for_read and (name==nil or s.name==name) then n=n+s.count end end
    return n
  end
  function inv.get_contents()
    local out,by={},{}
    for i=1,#inv do
      local s=inv[i]
      if s.valid_for_read then
        if not by[s.name] then by[s.name]={name=s.name,quality='normal',count=0}; out[#out+1]=by[s.name] end
        by[s.name].count=by[s.name].count+s.count
      end
    end
    return out
  end
  function inv.count_empty_stacks() local n=0; for i=1,#inv do if not inv[i].valid_for_read then n=n+1 end end; return n end
  function inv.is_empty() return inv.count_empty_stacks()==#inv end
  function inv.find_item_stack(f) for i=1,#inv do local s=inv[i]; if s.valid_for_read and s.name==f.name then return s,i end end end
  function inv.remove(f)
    local left=f.count
    for i=#inv,1,-1 do
      local s=inv[i]
      if left>0 and s.valid_for_read and s.name==f.name then local n=math.min(s.count,left); s.count=s.count-n; left=left-n; if s.count==0 then s.clear() end end
    end
    return f.count-left
  end
  return inv
end
local force={name='player',chart=function() end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end,recipes={}}
-- Chunks our force sees: all but the far farm's until the test says otherwise.
local dark={}
force.is_chunk_visible=function(_,c) return not dark[c.x..','..c.y] end
local surface={name='gleba',index=1}
local world={}
surface.find_entities_filtered=function(f)
  local out={}
  if f.ghost_name or f.type=='item-entity' or f.type=='corpse' then return out end
  for _,e in ipairs(world) do
    local ok=e.valid
    if ok and f.position then
      local r=math.max(f.radius or 0.5,0.3)
      ok=math.abs(e.position.x-f.position.x)<=r and math.abs(e.position.y-f.position.y)<=r
    end
    if ok and f.area then
      local lt,rb=f.area.left_top or f.area[1],f.area.right_bottom or f.area[2]
      ok=e.position.x>=(lt.x or lt[1]) and e.position.x<=(rb.x or rb[1]) and e.position.y>=(lt.y or lt[2]) and e.position.y<=(rb.y or rb[2])
    end
    if ok and f.name then ok=f.name==e.name end
    if ok and f.type then ok=(type(f.type)=='table' and (function() for _,t in ipairs(f.type) do if t==e.type then return true end end end)()) or f.type==e.type end
    if ok and f.force then ok=e.force==f.force end
    if ok then out[#out+1]=e end
  end
  return out
end
surface.can_place_entity=function() return true end
surface.find_non_colliding_position=function(_,pos) return pos end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
surface.find_tiles_filtered=function() return {} end
surface.spill_item_stack=function() end
local function chest(pos,items)
  local inv=inventory(16)
  for name,n in pairs(items or {}) do inv.insert{name=name,count=n} end
  local e={valid=true,name='wooden-chest',type='container',position=pos,force=force,surface=surface,quality={name='normal'},unit_number=#world+2000,
    health=100,max_health=100,prototype={name='wooden-chest',type='container'},
    bounding_box={left_top={x=pos.x-0.35,y=pos.y-0.35},right_bottom={x=pos.x+0.35,y=pos.y+0.35}}}
  e.get_inventory=function(i) return i==defines.inventory.chest and inv or nil end
  e.get_output_inventory=function() return inv end
  e.inv=inv
  world[#world+1]=e
  return e
end
surface.create_entity=function(args)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=args.position,unit_number=500,health=250,max_health=250,
    driving=false,build_distance=10,reach_distance=10,resource_reach_distance=2.7,character_running_speed=0.15,walking_state={walking=false},
    prototype={mining_speed=0.5,collision_mask={layers={player=true}}}}
  c.insert=function(s) return s.count end
  c.destroy=function() c.valid=false end
  return c
end
game={tick=0,players={},forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function() return nil end,get_surface=function() return surface end,print=function() end,connected_players={},
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end,
  create_inventory=function(n) return inventory(n) end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local tick=0
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then error(result,0) end
  return result
end
runtime.operator.bot_create('luna')
local function luna(action,args) return request{action=action,args=args or {},bot='luna'} end
local body=runtime.bots.lookup(runtime.bots.index_of('luna')).character
local main=inventory(20)
body.get_main_inventory=function() return main end
body.get_inventory=function() return main end
body.insert=function(s) return main.insert(s) end
body.get_item_count=function(n) return main.get_item_count(n) end
body.can_insert=function() return true end
local function dist(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
body.can_reach_entity=function(e) return dist(body.position,e.position)<=10 end
body.position={x=50,y=32}

-- Area and position finds over footprints, as the engine's position find matches an entity's box.
local find=surface.find_entities_filtered
surface.find_entities_filtered=function(f)
  if f.position and not f.radius and not f.area then
    local out={}
    for _,e in ipairs(world) do
      local b=e.bounding_box
      if e.valid and b and f.position.x>=b.left_top.x and f.position.x<=b.right_bottom.x and f.position.y>=b.left_top.y and f.position.y<=b.right_bottom.y
        and (not f.name or f.name==e.name) then out[#out+1]=e end
    end
    return out
  end
  return find(f)
end
local function chest(pos,items)
  local inv=inventory(16)
  for name,n in pairs(items or {}) do inv.insert{name=name,count=n} end
  local e={valid=true,name='wooden-chest',type='container',position=pos,force=force,surface=surface,quality={name='normal'},unit_number=#world+2000,
    health=100,max_health=100,prototype={name='wooden-chest',type='container'},
    bounding_box={left_top={x=pos.x-0.35,y=pos.y-0.35},right_bottom={x=pos.x+0.35,y=pos.y+0.35}}}
  e.get_inventory=function(i) return i==defines.inventory.chest and inv or nil end
  e.get_output_inventory=function() return inv end
  e.inv=inv
  world[#world+1]=e
  return e
end

-- CA4. A solar panel (3x3 at (213.5,77.5)) covers (214.5,78.5), where the chest stands on another surface.
local panel={valid=true,name='solar-panel',type='solar-panel',position={x=213.5,y=77.5},force=force,surface=surface,unit_number=3001,health=200,max_health=200,
  prototype={name='solar-panel',type='solar-panel'},bounding_box={left_top={x=212.1,y=76.1},right_bottom={x=214.9,y=78.9}}}
panel.get_inventory=function() return nil end
world[#world+1]=panel
body.position={x=-240,y=-125}
fails(function() luna('transfer',{position={x=214.5,y=78.5},direction='to_player',item='wood',count=25,walk=true}) end,
  'solar-panel at (213.5,77.5) on gleba (position (214.5,78.5) is on its footprint) has no inventory a transfer reaches: nothing walked; solar-panel takes inventory none')
eq(storage.agent_harness.active[runtime.bots.index_of('luna')],nil,'no walk began')
-- the same without walk: true, 18 tiles off (a target out of reach within 64 tiles walks by itself): refused too
body.position={x=195,y=77}
fails(function() luna('transfer',{position={x=214.5,y=78.5},direction='to_player',item='wood',count=25}) end,'solar-panel at (213.5,77.5) on gleba')
-- in reach: the refusal names the entity
body.position={x=210,y=77}
fails(function() luna('transfer',{position={x=214.5,y=78.5},direction='to_player',item='wood',count=25}) end,
  'solar-panel at (213.5,77.5) on gleba has no transferable inventory')
-- A chest that takes it: the walk's legs name the inventory and the reply the surface.
local far=chest({x=120.5,y=40.5},{wood=25})
body.position={x=50,y=32}
local r=luna('transfer',{position=far.position,direction='to_player',item='wood',count=25,walk=true})
assert(r.until_tick,'a walk')
eq(r.legs[1].name,'wooden-chest'); eq(r.legs[1].inventory,'chest'); eq(r.surface,'gleba')
luna('stop',{})
-- a stop among several without the inventory is skipped and named; the rest walk
r=luna('transfer',{positions={{x=214.5,y=78.5},far.position},direction='to_player',item='wood',count=5,walk=true})
eq(#r.legs,1); eq(r.legs[1].inventory,'chest')
assert(r.skipped[1]:find('(214.5,78.5): solar-panel at (213.5,77.5) on gleba',1,true),r.skipped[1])
luna('stop',{})

-- CA3. A spidertron by unit_number alone: found by its number (spider-vehicle is get-by-unit-number in the game).
local ammo=inventory(4)
local spider={valid=true,name='spidertron',type='spider-vehicle',position={x=52.5,y=33.5},force=force,surface=surface,unit_number=22731300,health=3000,max_health=3000,
  prototype={name='spidertron',type='spider-vehicle'},bounding_box={left_top={x=52,y=33},right_bottom={x=53,y=34}}}
spider.get_inventory=function(i) return i==defines.inventory.spider_ammo and ammo or nil end
world[#world+1]=spider
game.get_entity_by_unit_number=function(n) for _,e in ipairs(world) do if e.unit_number==n and e.type=='spider-vehicle' then return e end end end
main.insert{name='rocket',count=230}
r=luna('transfer',{count=230,direction='to_entity',inventory='spider_ammo',item='rocket',unit_number=22731300})
eq(ammo.get_item_count('rocket'),230); eq(main.get_item_count('rocket'),0)
-- by number alone the game finds no chest: refused, naming the form with position
fails(function() luna('transfer',{direction='to_player',item='wood',unit_number=far.unit_number}) end,
  'the game finds no entity by unit_number '..far.unit_number..' alone (only vehicles and the like); give its position too: position={x,y},unit_number='..far.unit_number)
fails(function() luna('transfer',{direction='to_player',item='wood'}) end,'transfer requires position')
-- move_to target by number keeps its own form in the refusal
fails(function() luna('move_to',{target={unit_number=far.unit_number}}) end,'give its position too: target={position={x,y},unit_number='..far.unit_number..'}')

-- CA2 (viewer Aurora site:4407): inspect and circuit_audit read a whole-belt reader's scope by one rule, the game's
-- (beltseg.lua; measured on a private 2.0.77 server and a copy of world n's Asterion). Flow north: a splitter's right
-- output, a side-load onto the main line, an underground pair, the reader, one more belt. Lane 1's segment is 10
-- tiles, lane 2's 9; the splitter's left output lanes happen to be 10 and 9 too (another segment: not counted).
do
  defines=defines or {}
  defines.wire_connector_id={circuit_red=1,circuit_green=2}
  defines.control_behavior={transport_belt={content_read_mode={entire_belt_hold=2}}}
  local all={}
  local function line(len,items) return {total_segment_length=len,get_contents=function() return items or {} end} end
  local function mk(name,typ,x,y,dir,lines,extra)
    local e={valid=true,name=name,type=typ,position={x=x,y=y},direction=dir,unit_number=7000+#all,belt_neighbours={inputs={},outputs={}}}
    e.get_transport_line=function(k) return lines[k] end
    e.get_max_transport_line_index=function() return #lines end
    for k,v in pairs(extra or {}) do e[k]=v end
    all[#all+1]=e
    return e
  end
  local function it(n,c) return {{name=n,count=c,quality='normal'}} end
  local sp=mk('splitter','splitter',0,10.5,0,{line(5),line(5),line(7,it('iron-gear-wheel',4)),line(7),line(10,it('plastic-bar',3)),line(9),line(10,it('wood',2)),line(9)})
  local A=mk('transport-belt','transport-belt',0.5,9.5,0,{line(10,it('iron-plate',1)),line(9)})
  local B=mk('transport-belt','transport-belt',0.5,8.5,0,{line(10,it('iron-plate',1)),line(9)})
  local S1=mk('transport-belt','transport-belt',1.5,8.5,12,{line(2,it('stone-brick',1)),line(2)})
  local S2=mk('transport-belt','transport-belt',2.5,8.5,12,{line(2,it('stone-brick',1)),line(2)})
  local C=mk('underground-belt','underground-belt',0.5,7.5,0,{line(10,it('iron-plate',1)),line(9),line(10,it('coal',2)),line(9)},{belt_to_ground_type='input'})
  local D=mk('underground-belt','underground-belt',0.5,4.5,0,{line(10,it('iron-plate',1)),line(9),line(1,it('stone',5)),line(1)},{belt_to_ground_type='output'})
  local E=mk('transport-belt','transport-belt',0.5,3.5,0,{line(10,it('iron-plate',1)),line(9,it('copper-plate',1))})
  local F=mk('transport-belt','transport-belt',0.5,2.5,0,{line(10,it('iron-plate',1)),line(9)})
  C.neighbours=D; D.neighbours=C
  local function link(a,b) a.belt_neighbours.outputs[#a.belt_neighbours.outputs+1]=b; b.belt_neighbours.inputs[#b.belt_neighbours.inputs+1]=a end
  link(sp,A); link(A,B); link(S2,S1); link(S1,B); link(B,C); link(D,E); link(E,F)
  local seg=dofile('mod/agent-harness_0.1.0/beltseg.lua')()
  local w=seg.walk(E,400)
  eq(#w.list,6,'A..F: the straight input at the side-load, the underground pair'); eq(w.list[1],A); eq(w.at,5)
  eq(w.ends.inputs,'at splitter (0,10.5) (a splitter)'); eq(w.ends.outputs,'at transport-belt (0.5,2.5) (the belt ends there)')
  local h=seg.contents(w,E)
  eq(h['iron-plate'],6); eq(h['copper-plate'],1); eq(h.coal,2,'under the pair: the entrance\'s lines 3 and 4'); eq(h.wood,2,'the splitter\'s right output')
  eq(h.stone,nil,'the exit\'s lines 3 and 4 are its own'); eq(h['plastic-bar'],nil,'its left output: another segment'); eq(h['iron-gear-wheel'],nil); eq(h['stone-brick'],nil)
  -- the side-loading belt: its own segment, ending where it joins
  local w2=seg.walk(S2,400,true)
  eq(#w2.list,2); eq(w2.ends.outputs,'at transport-belt (1.5,8.5); transport-belt (0.5,8.5) past it is another segment')
  eq(#w2.phys.list,7,'the belt in line: S2, S1, B, C, D, E, F')
  eq(seg.contents(w2,S2)['stone-brick'],2)
  -- inspect says it
  E.get_circuit_network=function(x) return x==1 and {signals={{signal={name='iron-plate'},count=6},{signal={name='copper-plate'},count=1},{signal={name='coal'},count=2},{signal={name='wood'},count=2}}} or nil end
  local CI=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
  local text=CI.belt_segment(E)
  assert(text:find(': 6 belts (total_segment_length 10 tiles), back at splitter (0,10.5) (a splitter), on at transport-belt (0.5,2.5) (the belt ends there); it holds 1 copper-plate, 2 coal, 2 wood, 6 iron-plate; the wires read 1 copper-plate, 2 coal, 2 wood, 6 iron-plate',1,true),text)
  -- circuit_audit: the side-loader's short read, with where its segment ends
  for _,e in ipairs({S2,E}) do
    e.get_control_behavior=function() return {read_contents=true,read_contents_mode=2} end
    e.get_circuit_network=function(x) if x==2 then return {network_id=e==S2 and 31 or 32,signals={}} end end
  end
  local surface={find_entities_filtered=function(f) if f.type=='asteroid-collector' then return {} end local out={} for _,e in ipairs(all) do if e.type~='splitter' then out[#out+1]=e end end return out end}
  local CA=dofile('mod/agent-harness_0.1.0/circaudit.lua'){platform=function() return {name='Lab',surface=surface,force='player'} end}
  local r=CA.read({},{platform='Lab'})
  eq(r.belt_readers,2); eq(#r.short_reads,1); eq(r.short_reads[1].physical_belts,7)
  eq(r.lines[1],'transport-belt (2.5,8.5) reads its belt segment onto green #31, as the game counts it (2 tiles, 2 of the 7 belts in line); not in this read: 5 belts downstream from (0.5,8.5) to (0.5,2.5) (its segment ends at transport-belt (1.5,8.5); transport-belt (0.5,8.5) past it is another segment)')
  -- two readers of one segment on one network: counted twice
  E.get_circuit_network=function(x) if x==2 then return {network_id=31,signals={}} end end
  local B2=B
  B2.get_control_behavior=function() return {read_contents=true,read_contents_mode=2} end
  B2.get_circuit_network=function(x) if x==2 then return {network_id=31,signals={}} end end
  r=CA.read({},{platform='Lab'})
  eq(#r.double_counts,1); assert(r.double_counts[1]:find('transport-belt (0.5,8.5) and transport-belt (0.5,3.5) both read one belt segment (6 belts shared) onto green network #31',1,true) or r.double_counts[1]:find('transport-belt (0.5,3.5) and transport-belt (0.5,8.5) both read one belt segment (6 belts shared)',1,true),r.double_counts[1])
end

-- CA1 (Astra, shift62 seq 916: "Asterion hub unwired; wait_until circuit_signal rocket below4850 not met, saw no red or
-- green wire"): an unwired hub reads every signal as 0, as the game's own circuit conditions do (measured on a copy of
-- world n: Asterion's schedule condition rocket < 4850, hub unwired, met at once). A guard that can never be met while
-- the hub has no wire (at_least over 0) is refused at queue_submit and in a dry run.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2},inventory={hub_main=1}}
  prototypes={item={rocket={type='ammo'},['iron-plate']={}},fluid={},virtual_signal={['signal-A']={}},quality={normal={}}}
  game={tick=100}
  local nets={}
  local hub={valid=true,get_circuit_network=function(id) return nets[id] end}
  local ast={valid=true,name='Asterion',index=3,hub=hub}
  local force={name='player',platforms={ast}}
  local p={force=force,index=1}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){}
  local function check(c) c['until']='circuit_signal'; c.platform='Asterion'; C.validate(c); return C.check(p,c) end
  local met,saw=check({signal='rocket',below=4850})
  eq(met,true); eq(saw,"Asterion's hub has no red or green wire: rocket reads 0 there, as the game's own circuit conditions read an unwired hub (met)")
  met,saw=check({signal='rocket',at_least=100})
  eq(met,false); eq(saw,"Asterion's hub has no red or green wire: rocket reads 0 there, as the game's own circuit conditions read an unwired hub (never met while it has none)")
  eq(check({signal='rocket',at_least=0}),true,'at_least 0: 0 meets it')
  -- wired: the signal, absent reads 0 as before
  nets[2]={get_signal=function(sg) return sg.name=='rocket' and 5000 or 0 end}
  met,saw=check({signal='rocket',below=4850}); eq(met,false); eq(saw,"rocket 5000 on Asterion's hub (green)")
  met=check({signal='signal-A',below=1}); eq(met,true,'a wire without that signal: 0')
  eq(C.guard_refusal(p,{['until']='circuit_signal',platform='Asterion',signal='rocket',at_least=100}),nil,'wired')
  nets[2]=nil
  local want="circuit_signal rocket at_least 100 on Asterion: its hub has no red or green wire, so rocket reads 0 there (as the game's own circuit conditions read an unwired hub) and at_least 100 is never met while it has none"
  eq(C.guard_refusal(p,{['until']='circuit_signal',platform='Asterion',signal='rocket',at_least=100}),want)
  eq(C.guard_refusal(p,{['until']='circuit_signal',platform='Asterion',signal='rocket',below=4850}),nil,'below: met at once, not refused')
  eq(C.guard_refusal(p,{['until']='all',conditions={{['until']='circuit_signal',platform='Asterion',signal='rocket',at_least=100}}}),want,'inside all')
  -- queue_submit and dry runs in the platform lane, the remote lane and the body lane
  local s={active={}}
  local base={state=function() return s end,player=function() return p end,handlers={},busy=function() return false end,stop=function() end,stop_index=function() end,
    direct_action=function() return nil end,condition=function() return false,'' end,validate_condition=function(c) C.validate(c) end,
    guard_refusal=function(pp,c) return C.guard_refusal(pp,c) end}
  package.loaded.scheduler=nil
  local make=dofile('mod/agent-harness_0.1.0/scheduler.lua')
  local q=dofile('mod/agent-harness_0.1.0/queue_lanes.lua'){scheduler=make(base),factory=make,base=base,is_read=function() return false end}
  local never={['until']='circuit_signal',platform='Asterion',signal='rocket',at_least=100}
  local wait={action='wait_until',args={['until']='circuit_signal',platform='Asterion',signal='rocket',below=4850,timeout=60}}
  for _,lane in ipairs({'platform:Asterion','remote'}) do
    fails(function() q.handlers.queue_submit(p,{lane=lane,dry_run=true,steps={wait},guards={{when=never}}}) end,'guards[1]: when: '..want)
    fails(function() q.handlers.queue_submit(p,{lane=lane,steps={wait},guards={{when=never}}}) end,want)
    eq(q.handlers.queue_submit(p,{lane=lane,dry_run=true,steps={wait},guards={{when={['until']='circuit_signal',platform='Asterion',signal='rocket',below=4850}}}}).steps,1)
  end
end

print('d22_batch118: ok')
