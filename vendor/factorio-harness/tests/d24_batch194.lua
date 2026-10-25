-- Run from repository root: lua tests/d24_batch194.lua
-- d24 batch194 QAJ1 (Sol #2270): item filters with quality and comparator for inserters and loaders, through the
-- runtime against tests/round0620a.lua's fake engine.
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

-- The game's item filters as 2.0.77 keeps them (a copy of world n): a name alone reads quality normal, comparator "=";
-- {name} with no quality reads no quality (every quality); comparators read back as the signs <= -> ≤ and so on.
defines.control_behavior={type={inserter=7}}
for _,n in ipairs({'plastic-bar','coal'}) do prototypes.item[n]={name=n,type='item',stack_size=100} end
prototypes.quality={normal={name='normal',level=0},uncommon={name='uncommon',level=1},rare={name='rare',level=2},epic={name='epic',level=3},
  legendary={name='legendary',level=5},['quality-unknown']={name='quality-unknown',level=0,hidden=true}}
local SIGN={['<=']='≤',['>=']='≥',['!=']='≠'}
local function inserter(name,pos)
  local set={}
  local cb={type=7,circuit_set_filters=false,circuit_enable_disable=false}
  local e={valid=true,name=name,type='inserter',position=pos,force=force,surface=surface,filter_slot_count=5,inserter_filter_mode='whitelist',use_filters=false,
    pickup_position={x=pos.x,y=pos.y-2},drop_position={x=pos.x,y=pos.y+2},direction=0,unit_number=9001,prototype={name=name,type='inserter'},
    quality={name='normal'},health=100,max_health=100,bounding_box={left_top={x=pos.x-0.15,y=pos.y-0.15},right_bottom={x=pos.x+0.15,y=pos.y+0.15}}}
  e.get_filter=function(i) local f=set[i]; if not f then return nil end local out={} for k,v in pairs(f) do out[k]=v end return out end
  e.set_filter=function(i,f)
    if f==nil then set[i]=nil
    elseif type(f)=='string' then assert(prototypes.item[f],'Unknown item name: '..f); set[i]={name=f,quality='normal',comparator='='}
    elseif f.quality==nil then set[i]={name=f.name}
    else set[i]={name=f.name,quality=f.quality,comparator=SIGN[f.comparator] or f.comparator or '='} end
  end
  e.get_control_behavior=function() return cb end
  e.get_or_create_control_behavior=function() return cb end
  e.get_fluid_contents=function() return {} end
  world[#world+1]=e
  return e,cb
end
local ins,cb=inserter('fast-inserter',{x=10.5,y=0.5})

-- Sol's case: a whitelist of plastic-bar normal..epic, one filter (epic, "<=") or four; read back as given.
local r=astra('configure',{position=ins.position,filters={{name='plastic-bar',quality='epic',comparator='<='}},filter_mode='whitelist'})
eq(r.filters[1],'plastic-bar@<=epic'); eq(r.line,'whitelist: plastic-bar@<=epic'); eq(r.not_as_asked,nil)
eq(ins.get_filter(1).comparator,'≤'); eq(ins.get_filter(1).quality,'epic'); eq(ins.use_filters,true)
r=astra('configure',{position=ins.position,filters={'plastic-bar','plastic-bar@uncommon','plastic-bar@rare',{item='plastic-bar',quality='epic'}}})
eq(r.line,'whitelist: plastic-bar, plastic-bar@uncommon, plastic-bar@rare, plastic-bar@epic')
eq(ins.get_filter(1).quality,'normal'); eq(ins.get_filter(4).comparator,'=')
-- the same as a blacklist; the read's string form goes back in unchanged
r=astra('configure',{position=ins.position,filters={'plastic-bar@<=epic'},filter_mode='blacklist'})
eq(r.line,'blacklist: plastic-bar@<=epic'); eq(ins.get_filter(1).comparator,'≤')
-- every comparator, the signs too; "name@any" and {name} take every quality
r=astra('configure',{position=ins.position,filters={'coal@!=legendary','coal@>rare','coal@>=uncommon','coal@<rare',{name='coal',quality='rare',comparator='≥'}}})
eq(r.line,'blacklist: coal@!=legendary, coal@>rare, coal@>=uncommon, coal@<rare, coal@>=rare')
r=astra('configure',{position=ins.position,filters={'coal@any',{name='plastic-bar'}}})
eq(r.line,'blacklist: coal@any, plastic-bar@any'); eq(ins.get_filter(1).quality,nil)
-- one filter alone, as a table
eq(astra('configure',{position=ins.position,filters={name='coal',quality='epic'}}).line,'blacklist: coal@epic')
-- scan rows and inspect give them so
local function row_of(scan,name) for _,row in ipairs(scan.entities) do if row.name==name then return row end end end
eq(row_of(astra('scan',{position={x=10.5,y=0.5},radius=3}),'fast-inserter').filters,'blacklist: coal@epic')
eq(astra('inspect',{position=ins.position}).filters[1],'coal@epic')
-- refusals name what is known (Sol: {name,quality} was "unknown item table", plastic-bar@epic "unknown item")
fails(function() astra('configure',{position=ins.position,filters={'plastic-bar@mythic'}}) end,'unknown quality mythic; qualities: normal, uncommon, rare, epic, legendary')
fails(function() astra('configure',{position=ins.position,filters={{name='plastic-bar',quality='epic',comparator='=<'}}}) end,'unknown comparator =<; comparators: =, !=, <, <=, >, >=')
fails(function() astra('configure',{position=ins.position,filters={{name='plastic-bar',comparator='<='}}}) end,'comparator <= goes with quality')
fails(function() astra('configure',{position=ins.position,filters={'plastic-bar@<=any'}}) end,'any takes no comparator')
fails(function() astra('configure',{position=ins.position,filters={'plastic-rod@epic'}}) end,'unknown item plastic-rod')
fails(function() astra('configure',{position=ins.position,filters={{name='coal',amount=1}}}) end,'filter: unknown key amount')
fails(function() astra('configure',{position=ins.position,filters={'coal@quality-unknown'}}) end,'unknown quality quality-unknown')
eq(ins.get_filter(1).quality,'epic','a refused call sets nothing')
-- circuit_set settings take the same filters
r=astra('circuit_set',{position=ins.position,settings={filters={'plastic-bar@<=epic'},filter_mode='whitelist'}})
eq(ins.get_filter(1).comparator,'≤'); eq(ins.inserter_filter_mode,'whitelist')
-- a slot the game holds otherwise than asked is said
local plain=ins.set_filter
ins.set_filter=function(i,f) if type(f)=='table' and f.quality=='epic' then return plain(i,'coal') end return plain(i,f) end
r=astra('configure',{position=ins.position,filters={'plastic-bar@epic'}})
eq(r.not_as_asked[1],'slot 1 holds coal (asked plastic-bar@epic)')
ins.set_filter=plain
-- a paste's filters against its blueprint's (placewhy.lua): quality and comparator count (a blueprint keeps the
-- game's ItemFilter rows)
astra('configure',{position=ins.position,filters={'plastic-bar@<=epic'}})
eq(runtime.placewhy.settings_diff(ins,{filters={{index=1,name='plastic-bar',quality='epic',comparator='≤'}}}),nil)
local d=runtime.placewhy.settings_diff(ins,{filters={{index=1,name='plastic-bar',quality='normal',comparator='='},{index=2,name='plastic-bar'}}})
eq(d.differs[1],'filters plastic-bar@<=epic, blueprint plastic-bar,plastic-bar@any')
print('d24_batch194 ok')
