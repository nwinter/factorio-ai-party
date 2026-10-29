-- d29 batch343 MD (Luna, board #2749, d29 08:29: "Read-only inspect of Gleba biochambers reports recipe, inputs and
-- status but omits installed module names/counts, so scheduled module reviews cannot verify module sets"). Run from the
-- harness root: lua tests/d29_batch343.lua
-- inspect's area rows and compact lines: a module-capable entity's modules {name@quality: count}, module_slots
-- (used/total), the modules requested or coming out (an item request; a ghost's insert plan); none installed: no
-- modules, module_slots 0/N; no module slots (a chest): none of these; one get_module_inventory read a row; the exact
-- inspect's modules add installed, used and line beside slots and contents.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1,crafter_modules=4,beacon_modules=3,mining_drill_modules=2},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
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
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
-- As control.lua does: a failed request stops its player unless the runtime
-- marked it passive.
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
local astra,sol,grok=as('astra'),as('sol'),as('grok')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sunny',glyph='S',color='#ffcb45'})


do
  local reads=0
  local function ent(name,t,x,y,extra)
    local e={valid=true,name=name,type=t,force=force,surface=surface,position={x=x,y=y},direction=0,unit_number=9000+math.floor(x*10+y),
      bounding_box={left_top={x=x-0.4,y=y-0.4},right_bottom={x=x+0.4,y=y+0.4}},prototype={name=name,type=t},
      get_inventory=function() return nil end,get_output_inventory=function() return nil end,get_max_inventory_index=function() return 0 end,
      get_item_count=function() return 0 end,status=nil}
    for k,v in pairs(extra or {}) do e[k]=v end
    return e
  end
  local function stack(name,q) return {valid_for_read=true,name=name,count=1,quality={name=q or 'normal'}} end
  local EMPTY={valid_for_read=false}
  local function modinv(index,slots)
    local inv={index=index}
    for i,s in ipairs(slots) do inv[i]=s end
    inv.get_contents=function() return {} end
    return function() reads=reads+1; return inv end
  end
  local plan=function(name,stack_i,index) return {{id={name=name,quality='normal'},items={in_inventory={{inventory=index,stack=stack_i,count=1}}}}} end
  local list={
    ent('biochamber','assembling-machine',2.5,2.5,{get_module_inventory=modinv(4,{stack('productivity-module-3','rare'),stack('productivity-module-3','rare'),EMPTY,stack('speed-module')}),
      get_recipe=function() return {name='nutrients-from-bioflux'} end,get_fluid_contents=function() return {} end,health=300,max_health=300,energy=0}),
    ent('biochamber','assembling-machine',6.5,2.5,{get_module_inventory=modinv(4,{EMPTY,EMPTY,EMPTY,EMPTY}),get_recipe=function() return nil end}),
    ent('beacon','beacon',10.5,2.5,{get_module_inventory=modinv(3,{stack('speed-module-3','legendary'),EMPTY})}),
    ent('electric-mining-drill','mining-drill',2.5,6.5,{get_module_inventory=modinv(2,{stack('speed-module'),EMPTY}),
      item_request_proxy={valid=true,insert_plan=plan('efficiency-module',1,2),removal_plan=plan('speed-module',0,2)}}),
    ent('wooden-chest','container',6.5,6.5,{}),
    ent('entity-ghost','entity-ghost',10.5,6.5,{ghost_name='assembling-machine-3',ghost_type='assembling-machine',
      ghost_prototype={name='assembling-machine-3',type='assembling-machine',module_inventory_size=4},
      insert_plan=plan('productivity-module-2',0,4),get_recipe=function() return nil end})}
  local find=surface.find_entities_filtered
  surface.find_entities_filtered=function(f)
    if f.area and f.force then
      local out={}
      for _,e in ipairs(list) do
        local ok=true
        if f.type then ok=false; for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if t==e.type then ok=true end end end
        if ok then out[#out+1]=e end
      end
      return out
    end
    if f.position then
      local out={}
      for _,e in ipairs(list) do if e.position.x==f.position.x and e.position.y==f.position.y then out[#out+1]=e end end
      return out
    end
    return find(f)
  end
  local r=astra('inspect',{area={left_top={x=0,y=0},right_bottom={x=12,y=8}},all=true})
  local by={}
  for _,row in ipairs(r.entities) do by[row.position.x..','..row.position.y]=row end
  local bio,idle,beacon,drill,chest,ghost=by['2.5,2.5'],by['6.5,2.5'],by['10.5,2.5'],by['2.5,6.5'],by['6.5,6.5'],by['10.5,6.5']
  eq(bio.modules['productivity-module-3@rare'],2,'two rare productivity modules'); eq(bio.modules['speed-module@normal'],1,'normal quality named too')
  eq(bio.module_slots,'3/4'); eq(bio.modules_requested,nil); eq(bio.modules_removing,nil)
  eq(idle.modules,nil,'none installed: no modules'); eq(idle.module_slots,'0/4')
  eq(beacon.modules['speed-module-3@legendary'],1); eq(beacon.module_slots,'1/2')
  eq(drill.module_slots,'1/2'); eq(drill.modules_requested,'efficiency-module*1'); eq(drill.modules_removing,'speed-module*1')
  eq(chest.module_slots,nil,'a chest: no module slots'); eq(chest.modules,nil)
  eq(ghost.ghost,true); eq(ghost.module_slots,'0/4'); eq(ghost.modules_requested,'productivity-module-2*1')
  -- one module inventory read a row with no request (the drill's request reads it once more)
  reads=0
  astra('inspect',{area={left_top={x=0,y=0},right_bottom={x=8,y=4}}})
  eq(reads,2,'two biochambers, one read each')
  -- compact: the same, in words
  r=astra('inspect',{area={left_top={x=0,y=0},right_bottom={x=12,y=8}},all=true,compact=true})
  local text=table.concat(r.lines,'\n')
  assert(has({text},'modules productivity-module-3@rare*2 speed-module*1 (3/4 slots)'),text)
  assert(has({text},'modules none (0/4 slots)'),text)
  assert(has({text},'modules speed-module-3@legendary*1 (1/2 slots)'),text)
  assert(has({text},'modules speed-module*1 (1/2 slots), efficiency-module*1 requested, speed-module*1 coming out'),text)
  assert(has({text},'modules none (0/4 slots), productivity-module-2*1 requested'),text)
  assert(not has({text},'wooden-chest (6.5,6.5): modules'),text)
  -- the exact inspect: installed, used and the line beside slots and contents
  local okx,x=pcall(astra,'inspect',{position={x=2.5,y=2.5}})
  assert(okx,tostring(x))
  eq(x.modules.line,'productivity-module-3@rare*2 speed-module*1 (3/4 slots)'); eq(x.modules.used,3); eq(x.modules.slots,4)
  eq(x.modules.installed['productivity-module-3@rare'],2); eq(x.modules.inventory_index,4,'as before')
  surface.find_entities_filtered=find
end
print('d29_batch343 area inspect: modules {name@quality: count}, module_slots, requested and coming out, in rows and compact lines: ok')

-- modules.lua M.row and M.installed_text on their own
do
  local M=dofile('mod/agent-harness_0.1.0/modules.lua'){}
  local function st(n,q) return {valid_for_read=true,name=n,count=1,quality={name=q}} end
  local e={type='lab',prototype={type='lab'},get_module_inventory=function() return {index=3,st('speed-module','normal'),st('speed-module','uncommon')} end}
  local mr=M.row(e)
  eq(mr.used,2); eq(mr.slots,2); eq(mr.installed['speed-module@normal'],1); eq(mr.installed['speed-module@uncommon'],1)
  eq(mr.line,'speed-module*1 speed-module@uncommon*1 (2/2 slots)')
  eq(M.installed_text(mr.installed),'speed-module*1 speed-module@uncommon*1')
  eq(M.installed_text(nil),'none')
  eq(M.row({type='container',get_module_inventory=function() return nil end}),nil,'no module inventory')
  eq(M.row({type='container',get_module_inventory=function() error('no such method') end}),nil,'none on this type')
end
print('d29_batch343 modules.row: ok')
