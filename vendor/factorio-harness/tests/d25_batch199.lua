-- Run from repository root: lua tests/d25_batch199.lua
-- d25 batch199 QL1 (Astra #2285): configure sets every setting given in one call or refuses the call before anything
-- changes; the reply lists what it applied and the modifiers that did nothing.
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

for _,n in ipairs({'coal','firearm-magazine','speed-module','iron-gear-wheel'}) do prototypes.item[n]={name=n,type='item',stack_size=100} end
for _,n in ipairs({'small-biter','medium-biter','big-biter'}) do prototypes.entity[n]={name=n,type='unit'} end
prototypes.quality={normal={name='normal',level=0},rare={name='rare',level=2}}
force.recipes['iron-gear-wheel']={name='iron-gear-wheel',enabled=true,category='crafting',ingredients={},products={}}
local function box(e,pos,w)
  e.valid=true; e.position=pos; e.force=force; e.surface=surface; e.quality=e.quality or {name='normal'}; e.health=100; e.max_health=100
  e.bounding_box={left_top={x=pos.x-w,y=pos.y-w},right_bottom={x=pos.x+w,y=pos.y+w}}
  unit=unit+1; e.unit_number=unit
  world[#world+1]=e
  return e
end

-- What each subsystem the dispatch reaches did (they have their own suites): a log of calls.
local log={}
local function logged(k) for _,x in ipairs(log) do if x==k then return true end end end
runtime.turretammo.clear=function(x) log[#log+1]='item_requests'; return {into='firearm-magazine*10'} end
runtime.turretammo.check=function() end
runtime.turretammo.set=function(e,v) log[#log+1]='ammo'; return {after=tostring(v),before='none'} end
runtime.invbar.set=function(e,v) log[#log+1]='bar'; return {bar=v} end
runtime.circuits.set_speaker_alert=function() log[#log+1]='speaker_alert'; return {line='alert'},nil end
runtime.circuits.check_description=function(e,d) return d end
runtime.circuits.description=function(e) return e.combinator_description end
runtime.artillery.configure=function() log[#log+1]='auto_targeting'; return {} end
runtime.details.configure_storage_filter=function() log[#log+1]='storage_filter'; return {} end
runtime.details.configure_splitter=function(e,args)
  for _,k in ipairs({'input_priority','output_priority','filter'}) do if args[k]~=nil then log[#log+1]='splitter_'..k end end
  return {}
end
runtime.details.configure_wait_for_full_hand=function() log[#log+1]='wait_for_full_hand'; return {line='same'} end
runtime.modules.parse=function(v) return v end
runtime.modules.set=function() log[#log+1]='modules'; return {} end

-- A gun turret (eight priority slots, as get_priority_target past the list raises) and the others the keys go to.
local function turret(pos)
  local slots={}
  local e=box({name='gun-turret',type='ammo-turret',ignore_unprioritised_targets=false},pos,0.9)
  e.get_priority_target=function(i) assert(i>=1 and i<=8,'out of range'); return slots[i] end
  e.set_priority_target=function(i,nm) slots[i]=nm and {name=nm} or nil end
  setmetatable(e,{__index=function(t,k) if k=='priority_targets' then local l={} for i=1,8 do if slots[i] then l[#l+1]=slots[i] end end return l end end})
  e.reset=function() for i=1,8 do slots[i]=nil end; e.ignore_unprioritised_targets=false end
  e.targets=function() local l={} for i=1,8 do if slots[i] then l[#l+1]=slots[i].name end end return table.concat(l,',') end
  return e
end
local guns={}
for i=1,6 do guns[i]=turret({x=i-1,y=-3}) end
local ins=box({name='fast-inserter',type='inserter',filter_slot_count=5,inserter_filter_mode='whitelist',use_filters=false,direction=0,
  pickup_position={x=0,y=1},drop_position={x=0,y=-1},prototype={name='fast-inserter',type='inserter',inserter_stack_size_bonus=0},inserter_stack_size_override=0,
  inserter_spoil_priority='none'},{x=1.5,y=0.5},0.15)
do
  local set={}
  ins.get_filter=function(i) return set[i] end
  ins.set_filter=function(i,f) if f==nil then set[i]=nil elseif type(f)=='string' then set[i]={name=f,quality='normal',comparator='='} else set[i]={name=f.name} end end
  ins.get_control_behavior=function() return nil end
  ins.reset=function() for i=1,5 do set[i]=nil end; ins.inserter_filter_mode='whitelist'; ins.use_filters=false; ins.inserter_stack_size_override=0; ins.inserter_spoil_priority='none' end
end
local ghost=box({name='entity-ghost',type='entity-ghost',ghost_name='gun-turret',ghost_type='ammo-turret',ignore_unprioritised_targets=false},{x=6,y=-3},0.9)
do
  local t=turret({x=99,y=99}); t.valid=false
  ghost.get_priority_target=t.get_priority_target; ghost.set_priority_target=t.set_priority_target
  ghost.reset=function() t.reset(); ghost.ignore_unprioritised_targets=false end; ghost.targets=t.targets
  setmetatable(ghost,{__index=function(_,k) if k=='priority_targets' then return t.priority_targets end end})
end
local splitter=box({name='splitter',type='splitter',direction=0},{x=3.5,y=1},0.5)
local storage=box({name='storage-chest',type='logistic-container',prototype={type='logistic-container',logistic_mode='storage'}},{x=5.5,y=0.5},0.35)
local wchest=box({name='wooden-chest',type='container',prototype={type='container'}},{x=7.5,y=0.5},0.35)
local arty=box({name='artillery-turret',type='artillery-turret'},{x=1,y=3},1.4)
local speaker=box({name='programmable-speaker',type='programmable-speaker'},{x=3.5,y=2.5},0.35)
local comb=box({name='constant-combinator',type='constant-combinator',combinator_description=''},{x=4.5,y=2.5},0.35)
local silo=box({name='entity-ghost',type='entity-ghost',ghost_name='rocket-silo',ghost_type='rocket-silo',use_transitional_requests=false,send_to_orbit_automatically=false},{x=7,y=3},4)
local asm=box({name='assembling-machine-2',type='assembling-machine',prototype={type='assembling-machine',crafting_categories={crafting=true}},crafting_progress=0,fluidbox={}},{x=6.5,y=-0.5},1.4)
do
  local cur
  asm.get_recipe=function() return cur end
  asm.set_recipe=function(r) cur=r and force.recipes[r]; return {} end
  asm.get_inventory=function() return nil end
  asm.reset=function() cur=nil end
end

-- Astra's call (plan156): item_requests: false with priority_targets and ignore_unprioritised, one turret and six.
local r=astra('configure',{position=guns[1].position,item_requests=false,priority_targets={'medium-biter','big-biter'},ignore_unprioritised=true})
eq(r.removed,'bring firearm-magazine*10'); eq(guns[1].targets(),'medium-biter,big-biter'); eq(guns[1].ignore_unprioritised_targets,true)
eq(table.concat(r.applied,','),'ignore_unprioritised,item_requests,priority_targets'); eq(r.ignored,nil)
eq(r.line,'gun-turret (0,-3): item requests removed (bring firearm-magazine*10); priority targets: medium-biter, big-biter (in this order); ignore unprioritised targets: on')
guns[1].reset(); log={}
local list={}
for i=1,6 do list[i]=guns[i].position end
r=astra('configure',{positions=list,item_requests=false,priority_targets={'big-biter'},ignore_unprioritised=true})
eq(r.cleared,6); eq(#log,6)
for i=1,6 do eq(guns[i].targets(),'big-biter','gun '..i); eq(guns[i].ignore_unprioritised_targets,true); eq(r.entities[i].targeting,'priority targets: big-biter (in this order); ignore unprioritised targets: on') end
for i=1,6 do guns[i].reset() end; log={}
-- A bad name, or an entity among them with no targeting: nothing changes on it (requests kept too).
fails(function() astra('configure',{positions=list,item_requests=false,priority_targets={'big-bitter'}}) end,'unknown entity big-bitter in priority_targets')
eq(#log,0)
r=astra('configure',{positions={guns[1].position,wchest.position},item_requests=false,ignore_unprioritised=true})
eq(r.cleared,1); eq(r.failed,1); eq(#log,1); assert(r.entities[2].error:find('wooden-chest (type container) has no priority targets',1,true),r.entities[2].error)
guns[1].reset(); log={}
-- A turret ghost: its ammo request and its targeting in one call.
r=astra('configure',{position=ghost.position,ammo='firearm-magazine',priority_targets={'small-biter'}})
assert(logged('ammo')); eq(ghost.targets(),'small-biter'); eq(r.targeting,'priority targets: small-biter (in this order); ignore unprioritised targets: off')
ghost.reset(); log={}
-- Modifiers given without what they modify are listed as ignored.
r=astra('configure',{position=ins.position,filters={'coal'},by='robots',quality='rare',force=true})
eq(table.concat(r.applied,','),'filters'); eq(r.ignored[1],'by (goes with modules)'); eq(r.ignored[2],'quality (the recipe\'s quality: goes with recipe)')
eq(r.ignored[3],'force (goes with recipe or auto_requests)')
ins.reset()
-- A key the branch reached does not set: refused before anything changes, naming whose setting it is.
fails(function() astra('configure',{position=storage.position,filters={'coal'},filter_mode='blacklist'}) end,
  'storage-chest (5.5,0.5): configure sets storage_filter, filters, bar here; filter_mode (an inserter\'s) is not: nothing changed')
fails(function() astra('configure',{position=splitter.position,filters={'coal'},use_filters=true}) end,'use_filters (an inserter\'s) is not: nothing changed')
fails(function() astra('configure',{position=wchest.position,auto_requests=true}) end,'wooden-chest (7.5,0.5): configure sets recipe here; auto_requests (a rocket silo\'s) is not')
fails(function() astra('configure',{position=guns[1].position,ammo='firearm-magazine',item_requests=false}) end,'an ammo request is a turret ghost\'s')
eq(#log,0)
-- hand_size with a bad filter or spoil priority: the hand size is not set either.
fails(function() astra('configure',{position=ins.position,hand_size=1,filters={'coal@mythic'}}) end,'unknown quality mythic')
fails(function() astra('configure',{position=ins.position,hand_size=1,spoil_priority='oldest'}) end,'spoil_priority is none, fresh_first or spoiled_first')
fails(function() astra('configure',{position=ins.position,spoil_priority='fresh_first',filter_mode='greylist'}) end,'filter_mode is whitelist or blacklist')
eq(ins.inserter_stack_size_override,0); eq(ins.inserter_spoil_priority,'none')

-- Every pair of settings, on each entity either key goes to: a success set both (each one's effect is there), a
-- refusal changed nothing.
local KEYS={
  recipe={asm,'iron-gear-wheel',function() return asm.get_recipe() and asm.get_recipe().name=='iron-gear-wheel' end},
  filters={ins,{'coal'},function(e) if e==splitter then return logged('splitter_filter') elseif e==storage then return logged('storage_filter') end return ins.get_filter(1) and ins.get_filter(1).name=='coal' end},
  filter={splitter,'coal',function(e) if e==storage then return logged('storage_filter') elseif e==ins then return ins.get_filter(1)~=nil end return logged('splitter_filter') end},
  filter_mode={ins,'blacklist',function() return ins.inserter_filter_mode=='blacklist' end},
  use_filters={ins,true,function() return ins.use_filters==true end},
  hand_size={ins,1,function() return ins.inserter_stack_size_override==1 end},
  wait_for_full_hand={ins,false,function() return logged('wait_for_full_hand') end},
  spoil_priority={ins,'fresh_first',function() return ins.inserter_spoil_priority=='fresh-first' end},
  bar={wchest,4,function() return logged('bar') end},
  priority_targets={guns[1],{'big-biter'},function(e) return e.targets and e.targets()=='big-biter' end},
  ignore_unprioritised={guns[1],true,function(e) return e.ignore_unprioritised_targets==true end},
  auto_targeting={arty,false,function() return logged('auto_targeting') end},
  modules={asm,{'speed-module'},function() return logged('modules') end},
  storage_filter={storage,'coal',function() return logged('storage_filter') end},
  input_priority={splitter,'left',function() return logged('splitter_input_priority') end},
  output_priority={splitter,'right',function() return logged('splitter_output_priority') end},
  item_requests={guns[1],false,function() return logged('item_requests') end},
  ammo={ghost,'firearm-magazine',function() return logged('ammo') end},
  speaker_alert={speaker,{show_alert=true},function() return logged('speaker_alert') end},
  description={comb,'x',function() return comb.combinator_description=='x' end},
  auto_requests={silo,true,function() return silo.use_transitional_requests==true end},
  send_to_orbit_automatically={silo,true,function() return silo.send_to_orbit_automatically==true end},
}
local names={}
for k in pairs(KEYS) do names[#names+1]=k end
table.sort(names)
for k in pairs(runtime.CONFIGURE_SETTINGS) do assert(KEYS[k],'no case for setting '..k) end
local function state()
  local parts={tostring(#log),asm.get_recipe() and 'r' or '-',ins.inserter_filter_mode,tostring(ins.use_filters),tostring(ins.inserter_stack_size_override),
    ins.inserter_spoil_priority,tostring(ins.get_filter(1) and ins.get_filter(1).name),guns[1].targets(),tostring(guns[1].ignore_unprioritised_targets),
    ghost.targets(),tostring(ghost.ignore_unprioritised_targets),comb.combinator_description,tostring(silo.use_transitional_requests),tostring(silo.send_to_orbit_automatically)}
  return table.concat(parts,'|')
end
local function reset()
  log={}; asm.reset(); ins.reset(); guns[1].reset(); ghost.reset(); comb.combinator_description=''; silo.use_transitional_requests=false; silo.send_to_orbit_automatically=false
end
local ok_pairs,refused=0,0
for i=1,#names do
  for j=i+1,#names do
    local k1,k2=names[i],names[j]
    local seen={}
    for _,e in ipairs({KEYS[k1][1],KEYS[k2][1]}) do
      if not seen[e] then
        seen[e]=true
        reset()
        local before=state()
        local args={position=e.position,[k1]=KEYS[k1][2],[k2]=KEYS[k2][2]}
        local ok,out=pcall(astra,'configure',args)
        local where=k1..'+'..k2..' on '..(e.ghost_name or e.name)
        if ok then
          ok_pairs=ok_pairs+1
          assert(KEYS[k1][3](e),where..': '..k1..' did nothing')
          assert(KEYS[k2][3](e),where..': '..k2..' did nothing')
        else
          refused=refused+1
          eq(state(),before,where..' refused ('..tostring(out)..') but changed')
        end
      end
    end
  end
end
print(string.format('pairs: %d set, %d refused', ok_pairs, refused))

-- QL2 (Sol #2295): drill_list is a reply field of ores with patch; sent as an argument, the refusal says so, and the
-- patch help names it as one.
fails(function() astra('ores',{patch={x=0,y=0},drill_list=true}) end,'unknown argument drill_list for ores: drill_list is a reply field: every ores call with patch carries it')
local patch=runtime.handlers and runtime.handlers.describe and runtime.handlers.describe().actions.ores.patch or runtime.dispatch{action='describe',args={},bot='astra'}.actions.ores.patch
assert(patch:find('carries drill_list (a reply field, no argument; with forecast or without)',1,true),patch)

-- QL3 (Sol #2298): refinery N(-108.5,-125.5) on coal liquefaction at speed 2.5, read on a copy of world n. capacity,
-- delivers_up_to, full and idle_full_output_from apart; blocking says which rule holds it (crafting_progress 1: a
-- finished craft waits for room; 0: the idle rule, an input short).
prototypes.recipe={['coal-liquefaction']={name='coal-liquefaction',energy=5,
  ingredients={{type='item',name='coal',amount=10},{type='fluid',name='heavy-oil',amount=25},{type='fluid',name='steam',amount=50}},
  products={{type='fluid',name='heavy-oil',amount=90},{type='fluid',name='light-oil',amount=20},{type='fluid',name='petroleum-gas',amount=10}}}}
local function refinery(o)
  local boxes={{'input','heavy-oil',50,o.hin},{'input','steam',100,100},{'output','heavy-oil',180,o.heavy},{'output','light-oil',100,o.light},{'output','petroleum-gas',100,o.pg}}
  local fb=setmetatable({get_prototype=function(i) return {object_name='LuaFluidBoxPrototype',production_type=boxes[i][1]} end,
    get_filter=function(i) return {name=boxes[i][2]} end,get_capacity=function(i) return boxes[i][3] end},
    {__len=function() return #boxes end,__index=function(_,i) local b=boxes[i]; return b and b[4] and {name=b[2],amount=b[4]} or nil end})
  return {type='assembling-machine',crafting_speed=2.5,crafting_progress=o.progress,fluidbox=fb,get_recipe=function() return {name='coal-liquefaction'} end,
    get_output_inventory=function() return {get_item_count=function() return 0 end} end,
    get_inventory=function() return {get_item_count=function(n) return n=='coal' and (o.coal or 0) or 0 end} end,
    get_fluid_contents=function() return {['heavy-oil']=(o.hin or 0)+(o.heavy or 0),steam=100} end}
end
local stop=runtime.outputstop.read(refinery{hin=50,heavy=60,light=15,pg=40,coal=0,progress=0},'full_output')
local pg=stop.products[3]
eq(pg.capacity,100); eq(pg.delivers_up_to,90); eq(pg.full,false); eq(pg.idle_full_output_from,20); eq(pg.stops_at,nil); eq(pg.full_output_from,nil)
eq(stop.blocking,'input')
eq(stop.line,"full_output, no output at its limit: it is not crafting (crafting_progress 0) and holds 2 crafts' worth or more (petroleum-gas 40); it lacks coal 0 (a craft takes 10): it crafts again when that arrives")
stop=runtime.outputstop.read(refinery{hin=50,heavy=125.5,light=10,pg=0,coal=40,progress=1},'full_output')
eq(stop.blocking,'output')
eq(stop.line,'full_output: a finished craft waits for room in its output, heavy-oil 125.5 of 180 (goes out at 90 or less): it goes out when that is taken out')
stop=runtime.outputstop.read(refinery{hin=50,heavy=162,light=15.8,pg=0,coal=40,progress=0.4},'working')
eq(stop.blocking,nil)
eq(stop.next_wait,'this craft\'s results do not fit now, heavy-oil 162 of 180 (goes out at 90 or less): at its end the craft waits finished unless that is taken out by then')

-- QL3 second part: the send-down forecast at a stop (a copy of world n, 2.0.77): over the max of a request from the
-- planet it is stopped at goes to the trash and down there (a max of 0: all of it); over the max of a request from
-- another planet stays in the hub until the platform flies, then goes down at the next stop.
do
  local where={stopped=true,at='nauvis'}
  local S=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,
    freight={where=function() return where end,pads=function() return {},{} end}}
  local hub={get_item_count=function() return 20 end}
  local pl={schedule={current=1,records={{station='nauvis'},{station='fulgora'}}}}
  local d=S.sends_down(hub,pl,{fulgora={barrel=0}},{nauvis={barrel=0}})
  eq(d[1],"barrel: the hub holds 20; its requests would keep none (kept none): 20 over its max 0 go to the hub's trash now and down to nauvis (here), asked or not")
  d=S.sends_down(hub,pl,{},{fulgora={barrel=0}})
  eq(d[1],"barrel: the hub holds 20; its requests would keep none (kept none): 20 over its max 0 go to the hub's trash once it flies and down to fulgora at its next stop, asked or not")
end
print('d25_batch199 ok')
