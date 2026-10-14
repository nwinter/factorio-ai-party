-- Run from repository root: lua tests/round1050b.lua
-- transfer/collect {positions, item | items, pick, to} (Luna 07:57: a repeating seed courier walked 300+ tile laps
-- from empty seed chests). Luna's shift10 loop: yumako-seed from (48.5,35.5) or (47.5,33.5), jellynut-seed from
-- (52.5,29.5); the yumako farm chest at (187.5,54.5), the jellynut one at (-188.5,-101.5). Here the yumako farm stands
-- in reach and the jellynut farm far off, out of sight.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},
  inventory={chest=1,character_main=1,fuel=1},build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={},entity={},quality={normal={name='normal'}}}
for _,name in ipairs({'yumako-seed','jellynut-seed','wooden-chest','iron-plate','boiler'}) do prototypes.item[name]={name=name,type='item',stack_size=50} end
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
  function inv.destroy() inv.destroyed=true end
  function inv.find_item_stack(f) for i=1,#inv do local s=inv[i]; if s.valid_for_read and s.name==f.name then s.prototype=prototypes.item[s.name]; return s,i end end end
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


-- Round 10:50 part B (tests/round1050b.lua; the fake above is tests/picksource.lua's).
prototypes.item['firearm-magazine']={name='firearm-magazine',type='ammo',stack_size=200}
prototypes.item['pipe']={name='pipe',type='item',stack_size=100}
prototypes.item['coal']={name='coal',type='item',stack_size=50,fuel_value=4000000}

-- 3. Haiku: an ammo chest held pipes and no magazines, which cost a walk.
local pipes=chest({x=53.5,y=32.5},{pipe=40})
local ammo=chest({x=56.5,y=34.5},{['firearm-magazine']=200})
local far_ammo=chest({x=70.5,y=40.5},{['firearm-magazine']=50})
-- from "nearest": the nearest chest in reach holding it, and which.
local r=luna('transfer',{item='firearm-magazine',from='nearest',count=20})
eq(r.moved,20); eq(main.get_item_count('firearm-magazine'),20)
eq(r.from_nearest,'wooden-chest at (56.5,34.5), 7.0 tiles from you, holds 200 firearm-magazine (2 chests checked, 1 holding it)')
-- A named chest holding none of it says where the nearest one is.
r=luna('transfer',{position=pipes.position,item='firearm-magazine',count=20,direction='to_player'})
eq(r.moved,0)
assert(r.nothing_moved:find('wooden-chest at (53.5,32.5) holds no firearm-magazine in chest; it holds pipe*40; the nearest holding firearm-magazine: wooden-chest at (56.5,34.5), 7.0 tiles from you, holds 180 (transfer from: "nearest")',1,true),r.nothing_moved)
-- None in reach: refused, naming the nearest within 32 tiles; with radius it walks there.
ammo.inv.remove{name='firearm-magazine',count=180}
fails(function() luna('transfer',{item='firearm-magazine',from='nearest'}) end,
  'no chest in reach holds firearm-magazine (2 checked); the nearest within 32 tiles: wooden-chest at (70.5,40.5), 22.2 tiles away, holds 50 (radius=24 walks there)')
r=luna('transfer',{item='firearm-magazine',from='nearest',up_to=true})
eq(r.moved,0); eq(r.short.reason,'source_empty')
r=luna('transfer',{item='firearm-magazine',from='nearest',radius=30})
assert(r.until_tick and r.from_nearest:find('^wooden%-chest at %(70.5,40.5%)'),tostring(r.from_nearest))
eq(r.legs[1].position.x,70.5); eq(r.legs[1].walk,22.2); eq(r.legs[1].in_reach,false)
body.position={x=66,y=38}
advance(2)
local last=luna('status').last
eq(last.outcome,'transferred'); eq(main.get_item_count('firearm-magazine'),70)
body.position={x=50,y=32}
-- friction2 (Sonnet: the nearest held 20 of the 300 asked; Grok took 40 iron plates from a requester feeding a machine):
-- a count more than the nearest holds comes from the next ones too, nearest first, requester and buffer chests last.
prototypes.item['iron-plate']={name='iron-plate',type='item',stack_size=100}
local c1=chest({x=47.5,y=30.5},{['iron-plate']=20})
local r1=chest({x=48.5,y=34.5},{['iron-plate']=100})
r1.name='requester-chest'; r1.type='logistic-container'; r1.prototype={name='requester-chest',type='logistic-container',logistic_mode='requester'}
local c2=chest({x=44.5,y=36.5},{['iron-plate']=150})
r=luna('transfer',{item='iron-plate',from='nearest',count=100})
eq(r.moved,100); eq(main.get_item_count('iron-plate'),100)
eq(c1.inv.get_item_count('iron-plate'),0); eq(c2.inv.get_item_count('iron-plate'),70); eq(r1.inv.get_item_count('iron-plate'),100)
eq(r.from_nearest,'2 chests hold 170 of the 100 asked, nearest first, requester and buffer chests last: wooden-chest (47.5,30.5) 2.9 tiles, holds 20; '
  ..'wooden-chest (44.5,36.5) 7.1 tiles, holds 150 (5 chests checked, 3 holding it)')
-- the requester only when the rest is short
r=luna('transfer',{item='iron-plate',from='nearest',count=150})
eq(r.moved,150); eq(c2.inv.get_item_count('iron-plate'),0); eq(r1.inv.get_item_count('iron-plate'),20)
assert(r.from_nearest:find('wooden-chest (44.5,36.5) 7.1 tiles, holds 70; requester-chest (48.5,34.5) 2.9 tiles, holds 100 (requester)',1,true),r.from_nearest)
-- one chest that holds it all: as before
r=luna('transfer',{item='iron-plate',from='nearest',count=10})
eq(r.moved,10); eq(r.from_nearest,'requester-chest at (48.5,34.5), 2.9 tiles from you, holds 20 iron-plate (a requester chest: taken from last) (5 chests checked, 1 holding it)')
-- walking (radius, up to 256): the count across the stops; the walk ends transferred once it is taken
local f1=chest({x=80.5,y=32.5},{['iron-plate']=30})
local f2=chest({x=84.5,y=32.5},{['iron-plate']=30})
r=luna('transfer',{item='iron-plate',from='nearest',count=50,radius=40})
assert(r.until_tick and r.from_nearest:find('^2 chests hold 60 of the 50 asked'),tostring(r.from_nearest))
body.position={x=82,y=32}
advance(2)
last=luna('status').last
eq(last.outcome,'transferred'); eq(f1.inv.get_item_count('iron-plate')+f2.inv.get_item_count('iron-plate'),10)
eq(main.get_item_count('iron-plate'),310)
body.position={x=50,y=32}
-- with radius and every chest in reach: the count, not more (on a copy of world n it took 82 of 75 before)
local g1=chest({x=52.5,y=30.5},{['iron-plate']=20})
local g2=chest({x=53.5,y=34.5},{['iron-plate']=62})
r=luna('transfer',{item='iron-plate',from='nearest',count=75,radius=40})
eq(r.moved,75); eq(g1.inv.get_item_count('iron-plate')+g2.inv.get_item_count('iron-plate'),7)
g1.valid=false; g2.valid=false
fails(function() luna('transfer',{item='iron-plate',from='nearest',radius=257}) end,'radius out of range')
for _,e in ipairs({c1,r1,c2,f1,f2}) do e.valid=false end
-- from {x,y} is still the position (an alias).
r=luna('transfer',{from=ammo.position,item='pipe',count=1,direction='to_player'})
assert(r.corrected:find('from is position',1,true),r.corrected)
fails(function() luna('transfer',{item='pipe',from='farthest'}) end,'from is "nearest"')
fails(function() luna('transfer',{position=pipes.position,item='pipe',radius=5}) end,'radius goes with from: "nearest"')

-- 4. Opus: feed over positions with walk: the far ones are walked to, the reply lists each leg.
local function boiler(pos)
  local fuel=inventory(1)
  local e={valid=true,name='boiler',type='boiler',position=pos,force=force,surface=surface,quality={name='normal'},unit_number=#world+3000,
    health=200,max_health=200,prototype={name='boiler',type='boiler'},
    bounding_box={left_top={x=pos.x-1,y=pos.y-1},right_bottom={x=pos.x+1,y=pos.y+1}}}
  e.get_inventory=function(i) return i==defines.inventory.fuel and fuel or nil end
  e.get_fuel_inventory=function() return fuel end
  e.fuel=fuel
  world[#world+1]=e
  return e
end
local b1=boiler({x=52.5,y=30.5})
local b2=boiler({x=75.5,y=30.5})
main.insert{name='coal',count=40}
r=luna('feed',{positions={b1.position,b2.position},item='coal',fuel='coal',walk=true})
assert(r.until_tick,'a tour'); eq(r.out_of_reach,1)
eq(#r.legs,2); eq(r.legs[1].position.x,52.5); eq(r.legs[1].in_reach,true); eq(r.legs[2].position.x,75.5); eq(r.legs[2].walk,23)
advance(2)
eq(b1.fuel.get_item_count('coal')>0,true,'the one in reach first')
body.position={x=70,y=30}
advance(2)
last=luna('status').last
eq(last.outcome,'topped_up'); eq(b2.fuel.get_item_count('coal')>0,true)
body.position={x=50,y=32}
-- All in reach: the feed at once.
r=luna('feed',{positions={b1.position},item='coal',fuel='coal',walk=true})
eq(r.until_tick,nil)
fails(function() luna('feed',{item='coal',walk=true}) end,'walk goes with positions')

-- 11. Sol: inserter -> fast inserter over it keeps its filters, wires and circuit settings, as the game's fast
-- replace does (~12 feeders set again by hand).
defines.control_behavior={type={inserter=7}}
defines.wire_origin={player=0}
local function connector(owner,id)
  local c={owner=owner,wire_connector_id=id,connections={}}
  c.connect_to=function(t,_,origin) c.connections[#c.connections+1]={target=t,origin=origin}; t.connections[#t.connections+1]={target=c,origin=origin}; return true end
  return c
end
local pole={valid=true,name='small-electric-pole',type='electric-pole',position={x=54.5,y=28.5},force=force,surface=surface}
pole.connectors={}
pole.get_wire_connector=function(id) pole.connectors[id]=pole.connectors[id] or connector(pole,id); return pole.connectors[id] end
world[#world+1]=pole
local function inserter(name,pos)
  local set,cb,conns={}, {type=7}, {}
  local e={valid=true,name=name,type='inserter',position=pos,force=force,surface=surface,quality={name='normal'},unit_number=#world+4000,
    filter_slot_count=5,inserter_filter_mode='whitelist',use_filters=false,direction=0,health=100,max_health=100,
    pickup_position={x=pos.x,y=pos.y-1},drop_position={x=pos.x,y=pos.y+1},
    prototype={name=name,type='inserter',fast_replaceable_group='inserter',collision_box={left_top={x=-0.15,y=-0.15},right_bottom={x=0.15,y=0.15}},
      mineable_properties={products={{type='item',name=name,amount=1}}}},
    bounding_box={left_top={x=pos.x-0.15,y=pos.y-0.15},right_bottom={x=pos.x+0.15,y=pos.y+0.15}}}
  e.get_filter=function(i) return set[i] and {name=set[i]} or nil end
  e.set_filter=function(i,f) set[i]=type(f)=='table' and f.name or f end
  e.get_control_behavior=function() return next(cb,nil)~='type' and cb or (cb.circuit_enable_disable~=nil and cb or nil) end
  e.get_or_create_control_behavior=function() return cb end
  e.get_wire_connector=function(id) conns[id]=conns[id] or connector(e,id); return conns[id] end
  e.get_wire_connectors=function() return conns end
  e.mine=function(args) args.inventory.insert{name=name,count=1}; e.valid=false; return true end
  e.cb=cb; e.conns=conns
  world[#world+1]=e
  return e
end
for _,n in ipairs({'inserter','fast-inserter'}) do
  prototypes.item[n]={name=n,type='item',stack_size=50}
  prototypes.entity[n]={name=n,type='inserter',fast_replaceable_group='inserter',collision_box={left_top={x=-0.15,y=-0.15},right_bottom={x=0.15,y=0.15}}}
  prototypes.item[n].place_result=prototypes.entity[n]
end
local old=inserter('inserter',{x=54.5,y=30.5})
old.set_filter(1,'coal'); old.use_filters=true
old.get_wire_connector(1).connect_to(pole.get_wire_connector(1),false,0)
old.cb.circuit_enable_disable=true; old.cb.circuit_condition={first_signal={type='item',name='coal'},comparator='<',constant=100}
old.cb.circuit_read_hand_contents=true
local make=surface.create_entity
surface.create_entity=function(args) if args.name=='fast-inserter' then return inserter('fast-inserter',args.position) end return make(args) end
main.insert{name='fast-inserter',count=1}
r=luna('build',{item='fast-inserter',position={x=54.5,y=30.5}})
surface.create_entity=make
local new=world[#world]
eq(new.name,'fast-inserter'); eq(old.valid,false); eq(r.replaced.name,'inserter')
eq(new.get_filter(1).name,'coal'); eq(new.use_filters,true); eq(new.inserter_filter_mode,'whitelist')
eq(#new.conns[1].connections,1); eq(new.conns[1].connections[1].target.owner,pole)
eq(new.cb.circuit_enable_disable,true); eq(new.cb.circuit_condition.constant,100); eq(new.cb.circuit_read_hand_contents,true)
eq(r.replaced.kept[1],'filters whitelist: coal'); eq(r.replaced.kept[2],'1 of 1 wires')
assert(r.replaced.kept[3]:find('^circuit settings %(.*circuit_condition.*circuit_enable_disable.*circuit_read_hand_contents'),r.replaced.kept[3])
eq(r.replaced.not_kept,nil); eq(main.get_item_count('inserter'),1)

-- Round 15:20 item 10 (Grok: three walks to a copper-cable provider that robots had emptied): what robots have
-- reserved at a chest is named; one with free stock comes first; a walk to a reserved one says so; an empty take
-- there says what it held when it was named.
defines.logistic_member_index=defines.logistic_member_index or {logistic_container=0}
prototypes.item['copper-cable']={name='copper-cable',type='item',stack_size=200}
local function provider(pos,n,reserved)
  local e=chest(pos,{['copper-cable']=n})
  e.type='logistic-container'; e.name='passive-provider-chest'; e.prototype={name='passive-provider-chest',type='logistic-container'}
  e.reserved=reserved
  e.get_logistic_point=function() return {targeted_items_pickup={{name='copper-cable',quality='normal',count=e.reserved}}} end
  return e
end
body.position={x=50,y=32}
provider({x=52.5,y=32.5},10,10)                 -- nearer, all of it reserved
local free_p=provider({x=57.5,y=32.5},30,5)
r=luna('transfer',{item='copper-cable',from='nearest',count=5})
eq(r.moved,5)
assert(r.from_nearest:find('^passive%-provider%-chest at %(57.5,32.5%), 7.5 tiles from you, holds 30 copper%-cable, 5 of it reserved for robots to take %(%d+ chests checked, 2 holding it%)$'),r.from_nearest)
-- Robots take the rest before the next take: the empty take says what it held when named.
free_p.inv.remove{name='copper-cable',count=25}
r=luna('transfer',{position=free_p.position,item='copper-cable',count=5,direction='to_player'})
eq(r.moved,0)
assert(r.nothing_moved:find('; it held 30 copper-cable 0s ago when named to you, 5 of it then reserved for robots to take',1,true),r.nothing_moved)
-- A walk to a provider whose stock robots have reserved says so as it starts.
local far_p=provider({x=75.5,y=32.5},20,20)
r=luna('transfer',{position=far_p.position,item='copper-cable',count=5,direction='to_player',walk=true})
eq(r.reserved_note,'robots have 20 copper-cable reserved to take at it now: they may empty it before you arrive')
luna('stop')

print('round1050b: ok')
