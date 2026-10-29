-- d28 batch330 IH (Astra, board #2728, d28 22:03: "R16b drain bench at79533397 radius inspect reported bulk holds empty
-- while exactinspect79536978 held_count4 rocket ... This can falsely certify drained state."). Run from the harness root:
-- lua tests/d28_batch330.lua
-- inspect's area rows: an inserter's hand (held, held_count) and no holds; a machine's craft under way (in_progress)
-- beside its slots; belts' lanes as before.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
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
  local function ent(name,t,x,y,extra)
    local e={valid=true,name=name,type=t,force=force,surface=surface,position={x=x,y=y},direction=0,unit_number=9000+math.floor(x*10+y),
      bounding_box={left_top={x=x-0.4,y=y-0.4},right_bottom={x=x+0.4,y=y+0.4}},prototype={name=name,type=t},
      get_inventory=function() return nil end,get_output_inventory=function() return nil end,get_max_inventory_index=function() return 0 end,
      get_item_count=function() return 0 end,status=nil}
    for k,v in pairs(extra or {}) do e[k]=v end
    return e
  end
  local hand={valid_for_read=true,name='rocket',count=4,quality={name='normal'}}
  local rare={valid_for_read=true,name='rocket',count=2,quality={name='rare'}}
  local list={ent('bulk-inserter','inserter',7.5,5.5,{pickup_position={x=7.5,y=6.5},drop_position={x=7.5,y=4.3},held_stack=hand}),
    ent('bulk-inserter','inserter',8.5,5.5,{pickup_position={x=8.5,y=6.5},drop_position={x=8.5,y=4.3},held_stack={valid_for_read=false}}),
    ent('fast-inserter','inserter',6.5,5.5,{pickup_position={x=6.5,y=6.5},drop_position={x=6.5,y=4.3},held_stack=rare}),
    ent('transport-belt','transport-belt',5.5,5.5,{get_max_transport_line_index=function() return 2 end,
      get_transport_line=function(i) return {get_contents=function() return i==2 and {{name='rocket',count=4,quality='normal'}} or {} end} end}),
    ent('assembling-machine-2','assembling-machine',9.5,6.5,{is_crafting=function() return true end,crafting_progress=0.4,
      get_recipe=function() return {name='iron-gear-wheel'} end})}
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
    return find(f)
  end
  local r=astra('inspect',{area={left_top={x=4,y=4},right_bottom={x=10,y=8}}})
  local by={}
  for _,row in ipairs(r.entities) do by[row.position.x]=row end
  local a,b,c=by[7.5],by[8.5],by[6.5]
  eq(a.held,'4 rocket'); eq(a.held_count,4); eq(a.holds,nil,'an inserter has no holds')
  eq(b.held,'nothing'); eq(b.held_count,0); eq(b.holds,nil)
  eq(c.held,'2 rocket@rare'); eq(c.held_count,2)
  eq(by[5.5].holds,'right lane: rocket*4','a belt: its lanes as before')
  eq(by[9.5].in_progress,'one craft 40% done (its products are in no slot yet)')
  -- compact: the hand as before, the craft under way too
  r=astra('inspect',{area={left_top={x=4,y=4},right_bottom={x=10,y=8}},compact=true})
  local text=table.concat(r.lines,'\n')
  has({text},'hand: rocket*4'); has({text},'hand empty'); has({text},'one craft 40% done')
  surface.find_entities_filtered=find
end
print('d28_batch330 area inspect: an inserter\'s hand (held, held_count) without holds; a craft under way: ok')
