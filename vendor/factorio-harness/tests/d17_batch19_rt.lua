-- Run from the harness root: lua tests/d17_batch19_rt.lua
-- d17 batch19 through the runtime's dispatch against a fake engine (the scaffold of tests/d17_batch17_rt.lua).
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


-- A1 (Sol 6+ times, board #874; Grok on Swift's thruster tanks): wait_until fluid_count and circuit_signal, and all of
-- them, as the agents called them, through dispatch's argument check, directly and as a remote-lane queue step.
do
  prototypes=prototypes or {}
  prototypes.item=prototypes.item or {}
  prototypes.fluid={['thruster-fuel']={name='thruster-fuel'},['thruster-oxidizer']={name='thruster-oxidizer'}}
  prototypes.virtual_signal={['signal-F']={name='signal-F'}}
  prototypes.space_location={nauvis={},gleba={}}
  defines.wire_connector_id={circuit_red=1,circuit_green=2}
  local fuel,ox=8000,13000
  local tank=function(k) return {valid=true,type='storage-tank',get_fluid_count=function(f) if f=='thruster-fuel' then return k.fuel end if f=='thruster-oxidizer' then return k.ox end return 0 end} end
  local held={fuel=fuel,ox=ox}
  local psurface={name='platform-3',find_entities_filtered=function(f) if f.type=='storage-tank' then return {tank(held)} end return {} end}
  local red={get_signal=function(s) return s.name=='signal-F' and 3 or 0 end}
  local hub={valid=true,position={x=0,y=0},get_circuit_network=function(w) return w==1 and red or nil end}
  local swift={valid=true,name='Swift',index=3,hub=hub,state=6,space_location={name='nauvis'},surface=psurface,force=force}
  force.platforms={swift}
  -- Grok 20:31:35, word for word: refused before ("unknown argument fluid for wait_until")
  local ok,r=pcall(grok,'wait_until',{['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=12000,timeout=16000})
  assert(ok,tostring(r))
  advance(12)
  local st=grok('status',{})
  assert(st.active and st.active.kind=='wait_until',require and tostring(st.active and st.active.kind))
  held.fuel=12500
  advance(12)
  st=grok('status',{})
  eq(st.last and st.last.kind,'wait_until'); eq(st.last.outcome,'met')
  -- Grok 20:31:25, word for word: both tanks (refused before: "unknown argument conditions")
  held.fuel=8000
  ok,r=pcall(grok,'wait_until',{['until']='all',conditions={{['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=12000},
    {['until']='fluid_count',platform='Swift',fluid='thruster-oxidizer',at_least=12000}},timeout=18000})
  assert(ok,tostring(r))
  held.fuel=12000; advance(24)
  st=grok('status',{})
  eq(st.last.outcome,'met')
  -- the hint the refusal gave for item is still the hint
  fails(function() grok('wait_until',{['until']='fluid_count',platform='Swift',item='thruster-fuel',at_least=12000,timeout=15000}) end,'fluid_count requires fluid')
  -- circuit_signal the same way
  ok,r=pcall(grok,'wait_until',{['until']='circuit_signal',platform='Swift',signal='signal-F',at_least=3,timeout=600})
  assert(ok,tostring(r))
  advance(12)
  eq(grok('status',{}).last.outcome,'met')
  -- Sol 20:25:14's step, word for word, in the remote lane: dry run and for real
  local step={action='wait_until',args={['until']='fluid_count',platform='Swift',fluid='thruster-oxidizer',at_least=12000,timeout=54000},wait=true,
    label='Recharge thruster-oxidizer to12000'}
  ok,r=pcall(sol,'queue_submit',{lane='remote',dry_run=true,steps={step}})
  assert(ok,tostring(r))
  ok,r=pcall(sol,'queue_submit',{lane='remote',steps={step}})
  assert(ok,tostring(r))
  -- all in the remote lane: fuel and oxidizer together
  ok,r=pcall(sol,'queue_submit',{lane='remote',dry_run=true,steps={{action='wait_until',args={['until']='all',conditions={
    {['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=12000},{['until']='fluid_count',platform='Swift',fluid='thruster-oxidizer',at_least=12000}},timeout=54000},
    wait=true,label='both tanks'}}})
  assert(ok,tostring(r))
  -- a member the remote lane does not take still refuses the step
  fails(function() sol('queue_submit',{lane='remote',dry_run=true,steps={{action='wait_until',args={['until']='all',conditions={
    {['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=1},{['until']='no_enemies',radius=10}},timeout=600},wait=true}}}) end,
    'remote lane wait_until supports')
end
print('d17_batch19_rt A1 fluid_count, circuit_signal and all through dispatch: ok')

-- A1's cause, kept from coming back: every field conditions.lua reads from a condition is an argument wait_until takes
-- (batch17 named fluid and signal only in the `until` text, and all's conditions never was a key).
do
  local src=io.open('mod/agent-harness_0.1.0/conditions.lua'):read('a')
  local seen,missing={},{}
  for k in src:gmatch('[^%w_%.]c%.([%a_]+)') do seen[k]=true end
  for k in src:gmatch("c%['([%a_]+)'%]") do seen[k]=true end
  seen.name=nil  -- (a cargo stack's c.name in the rocket line)
  for k in pairs(seen) do if not runtime.takes('wait_until',k) then missing[#missing+1]=k end end
  table.sort(missing)
  eq(table.concat(missing,', '),'','fields conditions.lua reads that wait_until refuses')
end
print('d17_batch19_rt A1 every condition field is a wait_until argument: ok')
