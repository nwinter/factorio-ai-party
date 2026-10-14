-- Run from repository root: lua tests/round0620a.lua
-- Round 06:20 part A against a fake engine with slot-level inventories:
-- 1. a build over a chest keeps its contents in the new chest (Sonnet, Astra: six chests drained into inventories,
--    2500 copper stranded; a refused upgrade with a full inventory had taken 1600 cable);
-- 2. inserter filters in scan rows, configure {filters, mode}, circuit_set settings (Sonnet: three inserters with
--    stale filters blocked a whole line);
-- 3. an unknown argument names the keys the entity takes (Luna: configure {filter} on a long-handed inserter);
-- 4. item moves report moved and end with the inventory line (Muse: "tick-only lines read as failures").
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},
  inventory={chest=1,character_main=1,fuel=1,furnace_source=2,furnace_result=3},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1},
  entity_status={working=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local world={}
prototypes={item={},entity={},quality={normal={name='normal'}}}
local function chest_proto(name,slots)
  local proto={name=name,type='container',fast_replaceable_group='container',
    collision_box={left_top={x=-0.35,y=-0.35},right_bottom={x=0.35,y=0.35}},
    mineable_properties={products={{type='item',name=name,amount=1}}}}
  proto.get_inventory_size=function(index) return index==defines.inventory.chest and slots or nil end
  prototypes.entity[name]=proto
  prototypes.item[name]={name=name,type='item',stack_size=50,place_result=proto}
  return proto
end
chest_proto('wooden-chest',16); chest_proto('iron-chest',32); chest_proto('steel-chest',48)
for _,name in ipairs({'copper-plate','iron-plate','copper-cable'}) do prototypes.item[name]={name=name,type='item',stack_size=name=='copper-cable' and 200 or 100} end
prototypes.item['yumako']={name='yumako',type='capsule',stack_size=50}

-- Slot-level inventories: transfer_stack moves item data (a stack's spoil) with the items, as the engine does.
local function slot()
  local s={valid_for_read=false,count=0}
  function s.clear() s.valid_for_read=false; s.name=nil; s.count=0; s.quality=nil; s.data=nil end
  function s.transfer_stack(src,amount)
    amount=math.min(amount or src.count,src.count)
    if s.valid_for_read and (s.name~=src.name or s.quality.name~=src.quality.name) then return false end
    local room=prototypes.item[src.name].stack_size-(s.valid_for_read and s.count or 0)
    local n=math.min(room,amount)
    if n<=0 then return false end
    if not s.valid_for_read then s.valid_for_read=true; s.name=src.name; s.quality={name=src.quality.name}; s.count=0; s.data=src.data end
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
    local size_=prototypes.item[name].stack_size
    local left=count
    for pass=1,2 do
      for i=1,#inv do
        local s=inv[i]
        if left>0 and ((pass==1 and s.valid_for_read and s.name==name and s.quality.name==quality) or (pass==2 and not s.valid_for_read)) then
          if not s.valid_for_read then s.valid_for_read=true; s.name=name; s.quality={name=quality}; s.count=0; s.data=x.data end
          local n=math.min(size_-s.count,left); s.count=s.count+n; left=left-n
        end
      end
    end
    return count-left
  end
  function inv.get_item_count(f)
    local name=type(f)=='table' and f.name or f
    local n=0
    for i=1,#inv do local s=inv[i]; if s.valid_for_read and (name==nil or s.name==name) and (type(f)~='table' or f.quality==nil or s.quality.name==f.quality) then n=n+s.count end end
    return n
  end
  function inv.get_contents()
    local out,by={},{}
    for i=1,#inv do
      local s=inv[i]
      if s.valid_for_read then
        local k=s.name..'@'..s.quality.name
        if not by[k] then by[k]={name=s.name,quality=s.quality.name,count=0}; out[#out+1]=by[k] end
        by[k].count=by[k].count+s.count
      end
    end
    return out
  end
  function inv.count_empty_stacks() local n=0; for i=1,#inv do if not inv[i].valid_for_read then n=n+1 end end; return n end
  function inv.is_empty() return inv.count_empty_stacks()==#inv end
  function inv.supports_filters() return false end
  function inv.find_item_stack(f)
    for i=1,#inv do
      local s=inv[i]
      if s.valid_for_read and s.name==f.name and s.quality.name==(f.quality or 'normal') then
        s.prototype=prototypes.item[s.name]
        return s,i
      end
    end
  end
  function inv.remove(f)
    local left=f.count
    for i=#inv,1,-1 do
      local s=inv[i]
      if left>0 and s.valid_for_read and s.name==f.name and s.quality.name==(f.quality or 'normal') then
        local n=math.min(s.count,left); s.count=s.count-n; left=left-n
        if s.count==0 then s.clear() end
      end
    end
    return f.count-left
  end
  function inv.destroy() inv.destroyed=true end
  return inv
end
local function fill(inv,name,count,data)
  local n=inv.insert{name=name,count=count}
  assert(n==count,'filled '..n..' of '..count)
  if data then for i=1,#inv do if inv[i].valid_for_read and inv[i].name==name then inv[i].data=data end end end
end

local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,recipes={}}
local surface={name='nauvis',index=1}
local spilled={}
local function inside(pos,area)
  local lt,rb=area.left_top or area[1],area.right_bottom or area[2]
  local l,t=lt.x or lt[1],lt.y or lt[2]
  local r,b=rb.x or rb[1],rb.y or rb[2]
  return pos.x>=l and pos.x<=r and pos.y>=t and pos.y<=b
end
surface.find_entities_filtered=function(f)
  local out={}
  if f.ghost_name then return out end
  local types=type(f.type)=='table' and f.type or (f.type and {f.type}) or nil
  for _,e in ipairs(world) do
    local ok=e.valid
    if ok and f.area then ok=inside(e.position,f.area) end
    if ok and f.position then
      local r=f.radius or 0.3
      ok=math.abs(e.position.x-f.position.x)<=math.max(r,0.3) and math.abs(e.position.y-f.position.y)<=math.max(r,0.3)
    end
    if ok and f.name then ok=(type(f.name)=='table' and (function() for _,n in ipairs(f.name) do if n==e.name then return true end end end)() or f.name==e.name) end
    if ok and types then
      local hit=false
      for _,t in ipairs(types) do hit=hit or t==e.type end
      if f.invert then hit=not hit end
      ok=hit
    end
    if ok and f.force then ok=e.force==f.force or e.force==(type(f.force)=='string' and f.force) end
    if ok then out[#out+1]=e end
  end
  if f.limit then while #out>f.limit do table.remove(out) end end
  return out
end
surface.can_place_entity=function() return true end
surface.find_non_colliding_position=function(_,pos) return pos end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
surface.spill_item_stack=function(t) spilled[#spilled+1]={name=t.stack.name,count=t.stack.count} end
surface.find_tiles_filtered=function() return {} end
local unit=1000
local function chest(name,pos)
  unit=unit+1
  local proto=prototypes.entity[name]
  local inv=inventory(proto.get_inventory_size(defines.inventory.chest))
  local e={valid=true,name=name,type='container',position=pos,force=force,surface=surface,prototype=proto,quality={name='normal'},unit_number=unit,
    health=100,max_health=100,bounding_box={left_top={x=pos.x-0.35,y=pos.y-0.35},right_bottom={x=pos.x+0.35,y=pos.y+0.35}}}
  e.get_inventory=function(i) return i==defines.inventory.chest and inv or nil end
  e.get_max_inventory_index=function() return 1 end
  e.get_output_inventory=function() return inv end
  e.insert=function(s) return inv.insert(s) end
  e.mine=function(args)
    for i=1,#inv do if inv[i].valid_for_read then local s=inv[i]; while s.valid_for_read do local before=s.count; for j=1,#args.inventory do args.inventory[j].transfer_stack(s); if not s.valid_for_read then break end end; if s.valid_for_read and s.count==before then return false end end end end
    args.inventory.insert{name=name,count=1}
    e.valid=false
    return true
  end
  e.destroy=function() e.valid=false end
  world[#world+1]=e
  return e,inv
end
surface.create_entity=function(args)
  if args.name=='character' then
    local c={valid=true,name='character',type='character',force=force,surface=surface,position=args.position,unit_number=500,health=250,max_health=250,
      driving=false,build_distance=10,reach_distance=10,resource_reach_distance=2.7,character_running_speed=0.15,walking_state={walking=false},
      prototype={mining_speed=0.5,collision_mask={layers={player=true}}}}
    c.insert=function(s) return s.count end
    c.destroy=function() c.valid=false end
    return c
  end
  if prototypes.entity[args.name] and prototypes.entity[args.name].type=='container' then
    return (chest(args.name,args.position))
  end
  local e={valid=true,name=args.name,position=args.position,force=args.force,surface=surface}
  world[#world+1]=e
  return e
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
runtime.operator.bot_create('astra')
local function astra(action,args) return request{action=action,args=args or {},bot='astra'} end
local body=runtime.bots.lookup(runtime.bots.index_of('astra')).character
local main=inventory(20)
body.get_main_inventory=function() return main end
body.get_inventory=function() return main end
body.insert=function(s) return main.insert(s) end
body.get_item_count=function(n) return main.get_item_count(n) end
body.can_insert=function() return true end
body.can_reach_entity=function() return true end
body.position={x=0,y=0}

-- 1a. Astra's upgrade: a wooden chest of 1600 copper-cable (8 stacks) under an iron chest: the cable stays in the new chest.
local old,oldinv=chest('wooden-chest',{x=3.5,y=0.5})
fill(oldinv,'copper-cable',1600)
fill(main,'iron-chest',1)
local r=astra('build',{item='iron-chest',position={x=3.5,y=0.5}})
eq(old.valid,false); eq(r.entity.name,'iron-chest'); eq(r.replaced.name,'wooden-chest')
eq(r.replaced.contents,'kept 1600 copper-cable in the new iron-chest')
local new=world[#world]
eq(new.get_inventory(1).get_item_count('copper-cable'),1600)
eq(main.get_item_count('copper-cable'),0,'none of it to the character')
eq(main.get_item_count('wooden-chest'),1,'the old chest to the character')
eq(main.get_item_count('iron-chest'),0)

-- 1b. The operator's example: 3600 copper-plate in a steel chest (36 of its 48 slots) under an iron chest (32 slots):
-- 3200 stay, 400 come to the character with the steel chest; a stack's item data (spoil) travels with it.
old,oldinv=chest('steel-chest',{x=5.5,y=0.5})
fill(oldinv,'copper-plate',3600,'fresh')
fill(main,'iron-chest',2)
r=astra('build',{item='iron-chest',position={x=5.5,y=0.5}})
eq(r.replaced.contents,'kept 3200 copper-plate in the new iron-chest; 400 copper-plate moved to you')
new=world[#world]
eq(new.get_inventory(1).get_item_count('copper-plate'),3200)
eq(new.get_inventory(1)[1].data,'fresh','item data travels into the new chest')
eq(main.get_item_count('copper-plate'),400); eq(main.get_item_count('steel-chest'),1); eq(main.get_item_count('iron-chest'),1)
eq(#spilled,0)

-- 1c. Astra's refused upgrade: no room for what the new chest cannot hold: refused, and nothing moved anywhere.
main=inventory(20)
fill(main,'iron-plate',1700)          -- 17 slots
fill(main,'iron-chest',2)             -- 1 slot (2 left after the build: it frees none)
old,oldinv=chest('steel-chest',{x=7.5,y=0.5})
fill(oldinv,'copper-plate',3600)
local made=#world
fails(function() astra('build',{item='iron-chest',position={x=7.5,y=0.5}}) end,
  'cannot replace steel-chest (7.5,0.5): your inventory has no room for 400 copper-plate, 1 steel-chest (2 free slots, 5 needed); nothing moved')
eq(old.valid,true); eq(oldinv.get_item_count('copper-plate'),3600,'the old chest keeps all of it')
eq(main.get_item_count('copper-plate'),0); eq(main.get_item_count('iron-chest'),2); eq(#world,made,'nothing built')
-- The last item of its stack frees its slot: with 4 free slots and a single iron chest the same build fits
-- (4 copper stacks and the steel chest in 5 slots).
main=inventory(20)
fill(main,'iron-plate',1500)          -- 15 slots
fill(main,'iron-chest',1)             -- 1 slot, freed by the build
r=astra('build',{item='iron-chest',position={x=7.5,y=0.5}})
eq(r.replaced.contents,'kept 3200 copper-plate in the new iron-chest; 400 copper-plate moved to you')
eq(main.count_empty_stacks(),0)

-- 2. Sonnet's stale filters: a long-handed inserter whose whitelist still holds iron-plate.
defines.control_behavior={type={inserter=7}}
prototypes.item.coal={name='coal',type='item',stack_size=50}
local function inserter(name,pos,filters,mode,use)
  local set={}
  for i,f in ipairs(filters) do set[i]=f end
  local cb={type=7,circuit_set_filters=false,circuit_enable_disable=false}
  unit=unit+1
  local e={valid=true,name=name,type='inserter',position=pos,force=force,surface=surface,filter_slot_count=5,inserter_filter_mode=mode,use_filters=use,
    pickup_position={x=pos.x,y=pos.y-2},drop_position={x=pos.x,y=pos.y+2},direction=0,unit_number=unit,prototype={name=name,type='inserter'},
    quality={name='normal'},health=100,max_health=100,bounding_box={left_top={x=pos.x-0.15,y=pos.y-0.15},right_bottom={x=pos.x+0.15,y=pos.y+0.15}}}
  e.get_filter=function(i) return set[i] and {name=set[i]} or nil end
  e.set_filter=function(i,f) set[i]=f end
  e.get_control_behavior=function() return cb end
  e.get_or_create_control_behavior=function() return cb end
  world[#world+1]=e
  return e,cb
end
local ins,cb=inserter('long-handed-inserter',{x=10.5,y=0.5},{'iron-plate'},'whitelist',true)
local function row_of(scan,name) for _,row in ipairs(scan.entities) do if row.name==name then return row end end end
-- A scan row carries the filters in use without asking.
eq(row_of(astra('scan',{position={x=10.5,y=0.5},radius=3}),'long-handed-inserter').filters,'whitelist: iron-plate')
-- configure {mode} alone: the mode changes, the items stay; the reply reads back the line and the one before.
r=astra('configure',{position=ins.position,mode='blacklist'})
eq(r.line,'blacklist: iron-plate'); eq(r.before,'whitelist: iron-plate'); eq(ins.inserter_filter_mode,'blacklist')
assert(r.corrected:find('mode is filter_mode',1,true),r.corrected)
-- One name given as filter: the list of one.
r=astra('configure',{position=ins.position,filter='copper-plate'})
eq(r.line,'blacklist: copper-plate'); eq(r.filters[1],'copper-plate'); eq(r.use_filters,true)
-- use_filters false keeps the items, unused; [] clears and turns filtering off.
eq(astra('configure',{position=ins.position,use_filters=false}).line,'off (filters: copper-plate)'); eq(ins.use_filters,false)
eq(astra('configure',{position=ins.position,filters={}}).line,'none')
-- A whitelist in use with no items says so.
ins.use_filters=true; ins.inserter_filter_mode='whitelist'
eq(row_of(astra('scan',{position={x=10.5,y=0.5},radius=3}),'long-handed-inserter').filters,'whitelist: no items set')
-- circuit_set settings set them too; with the circuit network setting them, rows say so.
r=astra('circuit_set',{position=ins.position,settings={filters={'iron-plate','coal'},filter_mode='whitelist'}})
eq(r.filters,'whitelist: iron-plate, coal')
cb.circuit_set_filters=true
eq(row_of(astra('scan',{position={x=10.5,y=0.5},radius=3,fields='filters'}),'long-handed-inserter').filters,'set by circuit (now: iron-plate, coal)')
cb.circuit_set_filters=false
fails(function() astra('circuit_set',{position=ins.position,settings={stack='x'}}) end,'filters, filter_mode, use_filters')
-- A chest has no filters: no field.
eq(row_of(astra('scan',{position={x=7.5,y=0.5},radius=1,fields='filters'}),'steel-chest'),nil)

-- 3. Luna: an unknown argument names the nearest argument and what the entity takes.
local ok3,err3=pcall(astra,'configure',{position=ins.position,filtr={'coal'}})
assert(not ok3,'refused')
assert(err3:find('unknown argument filtr for configure; valid: ',1,true),err3)
assert(err3:find('; closest name: filters; long-handed-inserter at (10.5,0.5) takes: filters, filter_mode (alias mode), use_filters; and position, name, unit_number, platform, surface',1,true),err3)
-- A chest: configure has nothing of its own for it.
fails(function() astra('configure',{position={x=7.5,y=0.5},bar=4}) end,
  'iron-chest at (7.5,0.5) takes: nothing of its own: configure sets recipes (assembling machines), item filters (inserters, loaders, asteroid collectors) and rocket silo switches')
-- circuit_set: its arguments for that entity.
fails(function() astra('circuit_set',{position=ins.position,setting={}}) end,
  'closest name: settings; long-handed-inserter at (10.5,0.5) takes: enable, logistic, read, settings (')
-- Any action: the nearest name, no entity part.
fails(function() astra('transfer',{position=ins.position,counts=3}) end,'; closest name: count')

-- 4. Muse (06:27): every item move says moved (transferred stays as its alias for a shift) and carries the
-- inventory line after the move; a move that runs over time says so, and its last has both when it ends.
main=inventory(20)
fill(main,'iron-plate',150)
local box=chest('iron-chest',{x=12.5,y=0.5})
r=astra('transfer',{position=box.position,item='iron-plate',count=50,direction='to_entity'})
eq(r.moved,50); eq(r.transferred,50,'the alias')
eq(r.inv,'free 18/20; held: iron-plate 100')
-- collect from a named chest: the same words.
r=astra('collect',{positions={box.position},item='iron-plate',chests=true})
eq(r.moved,50); eq(r.inv,'free 18/20; held: iron-plate 150')
-- Rows over several targets say moved too.
local box2=chest('iron-chest',{x=12.5,y=2.5})
r=astra('transfer',{positions={box.position,box2.position},item='iron-plate',count=10,direction='to_entity'})
eq(r.moved,20); eq(r.entities[1].moved,10); eq(r.entities[1].transferred,nil)
assert(r.tally:find('moved 20 iron-plate; 2 of 2 targets touched',1,true),r.tally)
-- A pickup runs over ticks: moved 0 so far, what ends it, the line now; last has what it took when it ends.
local plate={valid=true,name='item-on-ground',type='item-entity',position={x=0.2,y=0.1},force=force,
  stack={valid_for_read=true,name='copper-plate',count=7,quality={name='normal'}}}
plate.destroy=function() plate.valid=false end
world[#world+1]=plate
r=astra('pickup',{})
eq(r.moved,0); assert(r.timed:find('^moves until tick %d+: last.moved and last.inv say what it moved'),r.timed)
eq(r.inv,'free 18/20')
advance(20)
local last=astra('status',{}).last
eq(last.outcome,'picked_up'); eq(last.moved,7); eq(last.inv,'free 17/20; held: copper-plate 7')

print('round0620a: ok')
