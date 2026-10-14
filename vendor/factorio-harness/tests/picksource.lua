-- Run from repository root: lua tests/picksource.lua
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
for _,name in ipairs({'yumako-seed','jellynut-seed','wooden-chest','iron-plate'}) do prototypes.item[name]={name=name,type='item',stack_size=50} end
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

-- Luna's seed chests: (48.5,35.5) empty now, (47.5,33.5) with yumako seeds, (52.5,29.5) with jellynut seeds.
local empty=chest({x=48.5,y=35.5})
local yumako=chest({x=47.5,y=33.5},{['yumako-seed']=60})
local jelly=chest({x=52.5,y=29.5},{['jellynut-seed']=30})
local yfarm=chest({x=55.5,y=36.5})
local jfarm=chest({x=-188.5,y=-101.5})
dark['-6,-4']=true -- the jellynut farm's chunk: out of sight and no radar there

-- 1. first_with_stock: the empty chest is skipped, the take is made at the first listed one that holds seeds.
local r=luna('transfer',{positions={empty.position,yumako.position},item='yumako-seed',pick='first_with_stock',count=100,up_to=true})
eq(r.moved,60); eq(r.picked.position.x,47.5); eq(r.picked.item,'yumako-seed'); eq(r.picked.holds,60); eq(r.skipped,1)
eq(r.picked.line,'wooden-chest at (47.5,33.5) holds 60 yumako-seed (first_with_stock; 1 listed place skipped)')
-- The picked chest held 60 of the 100 asked (up_to's own short); the empty one counts only in skipped.
eq(r.skipped_places[1].holds,0); eq(r.short.reason,'source_short'); eq(r.short.asked,100)
eq(main.get_item_count('yumako-seed'),60)
main.remove{name='yumako-seed',count=60}

-- 2. None of the listed places holds it: moved 0, nothing walked or started, not short.
r=luna('transfer',{positions={empty.position,yumako.position},item='yumako-seed',pick='first_with_stock'})
eq(r.moved,0); eq(r.picked,'none'); eq(r.skipped,2); eq(r.short,nil); eq(r.until_tick,nil)
eq(r.note,'none of the 2 listed places holds yumako-seed now: nothing taken, nothing walked')
assert(not luna('status').active,'nothing started')

-- 3. most_stock over two items: the place holding the most of either.
yumako.inv.insert{name='yumako-seed',count=20}
r=luna('transfer',{positions={yumako.position,jelly.position},items={'yumako-seed','jellynut-seed'},pick='most_stock',count=5})
eq(r.picked.item,'jellynut-seed'); eq(r.picked.holds,30); eq(r.moved,5)
main.remove{name='jellynut-seed',count=5}; jelly.inv.insert{name='jellynut-seed',count=5}

-- 4. The courier: take at the picked place, then carry it to that seed's farm in the same timed call. The yumako
-- chest is listed first but the step looks for jellynut seeds first: first_with_stock takes each place's first
-- listed item it holds, so the yumako chest gives yumako seeds; with the yumako chest empty, the jellynut chest.
yumako.inv.remove{name='yumako-seed',count=20}
local to={['yumako-seed']=yfarm.position,['jellynut-seed']=jfarm.position}
r=luna('transfer',{positions={empty.position,yumako.position,jelly.position},items={'yumako-seed','jellynut-seed'},pick='first_with_stock',to=to})
eq(r.picked.item,'jellynut-seed'); eq(r.skipped,2); eq(r.to.x,-188.5); eq(r.places,2)
eq(r.to_line,'then gives it at (-188.5,-101.5) (out of sight now: found on arrival)')
assert(r.until_tick and r.timed,'a timed call')
advance(2)
eq(main.get_item_count('jellynut-seed'),30,'taken at the picked chest'); eq(jelly.inv.get_item_count('jellynut-seed'),0)
eq(luna('status').active.kind,'gather','walking on to the farm')
-- Arrived (this fake moves the character there), in sight again: the farm chest is found and gets the seeds.
body.position={x=-186,y=-100}; dark['-6,-4']=nil
advance(2)
local last=luna('status').last
eq(last.outcome,'transferred'); eq(last.taken,30); eq(last.delivered,30); eq(last.moved,30)
eq(last.picked,'wooden-chest at (52.5,29.5) holds 30 jellynut-seed (first_with_stock; 2 listed places skipped)')
eq(jfarm.inv.get_item_count('jellynut-seed'),30); eq(main.get_item_count('jellynut-seed'),0)
eq(last.entities[1].direction,'to_player'); eq(last.entities[2].direction,'to_entity'); eq(last.entities[2].moved,30)
body.position={x=50,y=32}

-- 5. The yumako farm in reach: both legs at once.
yumako.inv.insert{name='yumako-seed',count=40}
r=luna('collect',{positions={empty.position,yumako.position},items={'yumako-seed','jellynut-seed'},pick='first_with_stock',to=to})
eq(r.picked.item,'yumako-seed'); eq(r.direction,nil)
advance(3)
last=luna('status').last
eq(last.outcome,'transferred'); eq(last.delivered,40); eq(yfarm.inv.get_item_count('yumako-seed'),40)

-- 6. The take gets nothing (the stock went between the call and the tick): it ends there, no walk to the farm.
jelly.inv.insert{name='jellynut-seed',count=10}
r=luna('transfer',{positions={jelly.position},item='jellynut-seed',pick='first_with_stock',to=to})
jelly.inv.remove{name='jellynut-seed',count=10}
advance(2)
last=luna('status').last
eq(last.outcome,'nothing_collected'); eq(last.taken,0); eq(last.delivered,0)
assert(not luna('status').active,'ended'); eq(body.position.x,50,'no walk')

-- 7. As a repeating queue step: a round with every listed chest empty goes on, nothing short.
luna('queue_repeat',{steps={{action='transfer',args={positions={empty.position},item='yumako-seed',pick='first_with_stock',to=to}}},interval_ticks=60})
advance(5)
local q=luna('queue_status')
eq(q.paused,false)
local h=q.history[#q.history]
eq(h.ok,true); eq(h.result.picked,'none'); eq(h.short,nil)
luna('queue_cancel',{})

-- 8. Refusals.
fails(function() luna('transfer',{item='yumako-seed',pick='first_with_stock'}) end,'pick needs positions')
fails(function() luna('transfer',{positions={yumako.position},pick='first_with_stock'}) end,'pick needs item or items')
fails(function() luna('transfer',{positions={yumako.position},item='yumako-seed',pick='nearest'}) end,'pick is first_with_stock or most_stock')
fails(function() luna('transfer',{positions={yumako.position},items={'yumako-seed','iron-plate'},pick='most_stock',to=to}) end,'to has no destination {x,y} for iron-plate')
fails(function() luna('transfer',{positions={yumako.position},item='yumako-seed',to=to}) end,'items and to go with pick')
fails(function() luna('transfer',{positions={yumako.position},item='yumako-seed',direction='to_entity',pick='most_stock'}) end,'direction to_player')
-- 9. Operator 08:01 (Muse: the moved/inventory line only partly there): queue steps and standing orders (both run
-- in the queue) carry moved and inv in their history entries, a step done at once and a timed one when it ends.
yumako.inv.insert{name='yumako-seed',count=40}
luna('queue_submit',{steps={{action='transfer',args={position=yumako.position,item='yumako-seed',count=5,direction='to_player'}}}})
advance(2)
h=luna('queue_status').history
local entry=h[#h]
eq(entry.action,'transfer'); eq(entry.result.moved,5); eq(entry.result.inv,'free 19/20; held: yumako-seed 5')
luna('queue_submit',{steps={{action='transfer',args={positions={yumako.position},item='yumako-seed',pick='first_with_stock',to=to}}}})
advance(6)
h=luna('queue_status').history
entry=h[#h]
eq(entry.ok,true); eq(entry.result.outcome,'transferred'); eq(entry.result.moved,35,'what arrived'); eq(entry.result.inv,'free 19/20; held: yumako-seed 5')
eq(yfarm.inv.get_item_count('yumako-seed'),75)
-- A step that failed at once moved nothing: the line only.
luna('queue_submit',{steps={{action='transfer',args={position=empty.position,item='iron-plate',count=1,direction='to_entity'}}}})
advance(2)
h=luna('queue_status').history
entry=h[#h]
eq(entry.ok,false); eq(entry.result.moved,nil); eq(entry.result.inv,'free 19/20; held: iron-plate 0')
luna('queue_cancel',{})
-- Crafts: moved 0 now, timed says they land as each finishes, the line with the product; a cancel counts the
-- ingredients that came back.
force.recipes['wooden-chest']={name='wooden-chest',enabled=true,category='crafting',energy=0.5,
  products={{type='item',name='wooden-chest',amount=1}},ingredients={{type='item',name='wood',amount=2}}}
prototypes.item.wood={name='wood',type='item',stack_size=100}
main.insert{name='wood',count=10}
body.prototype.crafting_categories={crafting=true}
local queued={}
body.begin_crafting=function(r) queued[#queued+1]={index=#queued+1,recipe=r.recipe,count=r.count}; main.remove{name='wood',count=2*r.count}; return r.count end
body.get_craftable_count=function() return main.get_item_count('wood')//2 end
body.crafting_queue_size=0
body.cancel_crafting=function(c) main.insert{name='wood',count=2*c.count}; queued[c.index].count=queued[c.index].count-c.count end
local c=luna('craft',{recipe='wooden-chest',count=3,force=true})
eq(c.started,3); eq(c.moved,0); assert(c.timed:find('^crafts land in your inventory as each finishes'),c.timed)
assert(c.inv:find('held: wooden-chest 0',1,true),c.inv)
body.crafting_queue=queued
local cc=luna('cancel_craft',{recipe='wooden-chest',count=2})
eq(cc.cancelled,2); eq(cc.moved,4); eq(cc.returned.wood,4); assert(cc.inv:find('held: wood 8',1,true),cc.inv)

print('picksource: ok')
