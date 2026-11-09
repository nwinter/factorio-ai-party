-- Run from the harness root: lua tests/d17_batch19_rt.lua
-- d29 batch368 CP (Sol #2777), entity circuit reads through the runtime's dispatch against a fake engine (the scaffold of tests/d17_batch17_rt.lua).
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


-- Native networks at the loop reader are independent of the hub.
prototypes=prototypes or {}; prototypes.item={rocket={}}; prototypes.fluid={}; prototypes.virtual_signal={}; prototypes.quality={normal={}}
defines.wire_connector_id={circuit_red=1,circuit_green=2}
local count,broken=3000,false
local nets={[1]={network_id=73,get_signal=function() if broken then error('network invalidated') end; return count end},[2]={network_id=74,get_signal=function() return 100 end}}
local reader={valid=true,name='transport-belt',type='transport-belt',position={x=13.5,y=31.5},unit_number=369,quality='normal',
  prototype={get_max_circuit_wire_distance=function() return 9 end},get_circuit_network=function(w) return nets[w] end}
local found={reader}
local psurface={name='platform-49',index=49,find_entities_filtered=function(f)
  assert(f.force==force); assert(f.position.x==13.5 and f.position.y==31.5); return found end}
local hub={valid=true,name='space-platform-hub',position={x=0,y=0},get_circuit_network=function(w) return w==1 and {network_id=11,get_signal=function() return 7777 end} or nil end}
local pl={valid=true,name='Resolute',index=49,hub=hub,state=6,space_location={name='nauvis'},surface=psurface,force=force}
force.platforms={pl}
local function cond(w,n) return {['until']='circuit_signal',platform='Resolute',position={13.5,31.5},wire=w or 'red',signal='rocket',below=n or 2300} end
local function includes(s,v) assert(type(s)=='string' and s:find(v,1,true),tostring(s)..' lacks '..v) end
local r=sol('wait_until',cond())
includes(r.saw,'rocket 3000 on transport-belt (13.5,31.5) on Resolute'); includes(r.saw,'red network #73: 3000'); includes(r.saw,'read tick 0')
count=2200; advance(12)
r=sol('status',{}); eq(r.last.outcome,'met'); includes(r.last.saw,'rocket 2200')
local hubwait={['until']='circuit_signal',platform='Resolute',signal='rocket',at_least=7777}
r=sol('wait_until',hubwait); eq(r.outcome,'met'); includes(r.saw,'rocket 7777'); includes(r.saw,'red network #11')
for _,w in ipairs({'green','both','red+green','green+red',' Red + Green '}) do
 r=sol('wait_until',cond(w,2400)); eq(r.outcome,'met'); includes(r.saw,'green network #74: 100')
 if w~='green' then includes(r.saw,'rocket 2300') end
end
fails(function() sol('wait_until',cond('blue')) end,'wire is red, green or both')
local function submit(lane,c,dry,guard)
 return sol('queue_submit',{lane=lane,mode='replace',dry_run=dry,steps={guard and {action='wait_ticks',args={ticks=600}} or {action='wait_until',args=c}},guards=guard and {{when=c}} or nil})
end
-- Every lane, and both real and dry submission, check the selected entity/wire.
for _,lane in ipairs({'body','remote','platform:Resolute'}) do
 for _,dry in ipairs({true,false}) do
  for _,guard in ipairs({true,false}) do
   submit(lane,cond(),dry,guard)
   nets[1]=nil
   fails(function() submit(lane,cond(),dry,guard) end,'transport-belt (13.5,31.5) on Resolute has no readable red network')
   nets[1]={network_id=73,get_signal=function() if broken then error('network invalidated') end; return count end}
  end
 end
 sol('queue_cancel',{lane=lane})
end
-- Refusals name what stands there; no substitution of hub count or fabricated zero.
found={}; fails(function() sol('wait_until',cond()) end,'found no entity')
found={{valid=true,name='stone-wall',type='wall',prototype={get_max_circuit_wire_distance=function() return 0 end}}}
fails(function() submit('remote',cond(),true,true) end,'found stone-wall')
found={reader}; broken=true; fails(function() sol('wait_until',cond()) end,'network invalidated'); broken=false
-- A disconnected active wait remains unreadable and clears old evidence; reconnection reads its new id.
count=3000; sol('wait_until',cond()); nets[1]=nil; advance(12)
r=sol('status',{}); assert(r.active); includes(r.active.saw,'no readable red network')
nets[1]={network_id=83,get_signal=function() return 0 end}; advance(12)
r=sol('status',{}); eq(r.last.outcome,'met'); includes(r.last.saw,'red network #83: 0')
-- A lane guard records the entity/count/tick, including inside all after another evidence-bearing condition.
count=3000; nets[1]={network_id=93,get_signal=function() return count end}
submit('platform:Resolute',cond(),false,true); advance(12); nets[1]=nil; advance(12)
r=sol('queue_status',{lane='platform:Resolute'}); includes(r.guards[1].saw,'no readable red network')
nets[1]={network_id=94,get_signal=function() return 0 end}; advance(12)
r=sol('queue_status',{lane='platform:Resolute'})
local fired
for _,row in ipairs(r.history or {}) do if row.action=='guard' then fired=row end end
assert(fired,'guard history'); local ev=fired.result.evidence
eq(ev.entity.name,'transport-belt'); eq(ev.networks[1].id,94); eq(ev.count,0); eq(ev.tick,fired.finished_tick); includes(fired.result.saw,'read tick '..ev.tick)
-- Compound evidence keeps both entity reads, not only the first member's.
sol('queue_submit',{lane='remote',mode='replace',steps={{action='wait_ticks',args={ticks=600}}},guards={{when={['until']='all',conditions={cond('red'),cond('green')}}}}})
advance(12); r=sol('queue_status',{lane='remote'})
for _,row in ipairs(r.history or {}) do if row.action=='guard' then fired=row end end
eq(#fired.result.evidence.circuit_conditions,2); eq(fired.result.evidence.circuit_conditions[2].networks[1].id,74)
-- A queued wait also stays pending with an unreadable saw until the wire returns.
count=3000; nets[1]={network_id=95,get_signal=function() return count end}
submit('remote',cond(),false,false); advance(12); nets[1]=nil; advance(12)
r=sol('queue_status',{lane='remote'}); assert(r.active); includes(r.active.saw,'no readable red network')
nets[1]={network_id=96,get_signal=function() return 0 end}; advance(12)
r=sol('queue_status',{lane='remote'}); assert(not r.active); includes(r.history[#r.history].result.saw,'red network #96: 0')
-- Both explicitly requested wires must exist; a genuine connected zero remains readable.
nets[2]=nil; fails(function() sol('wait_until',cond('both')) end,'no readable green network')
print('d29_batch368 CP entity circuit waits, queue validation, disconnection and guard evidence: ok')
