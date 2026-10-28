-- Run from the harness root: lua tests/d28_batch301_rt.lua
-- d28 batch301 LS (Astra #2654: at tick 75165041 body job 37499, load_silo of 500 magazines to IVb, was over one
-- rocket's lift and appended its 5 rockets behind the queue; job 37500 put the auto requests back before any of them
-- launched, and the reset after it failed with the 500 still held). Through the runtime against a fake engine (as
-- tests/d16_batch7_rt.lua): a load_silo that runs as a queue step and splits (or takes rockets: N) becomes its rockets
-- in place, right after it and before the steps that follow; a queue with no room refuses it; a direct call appends.
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


-- 500 magazines at 10 kg: 5 rockets of 100 under the 1000 kg lift (the fake has no silo: the default lift and slots)
prototypes={item={['firearm-magazine']={name='firearm-magazine',type='ammo',weight=10000,stack_size=200,get_spoil_ticks=function() return 0 end}},entity={},recipe={},tile={}}
force.platforms={{valid=true,name='Kestrel IVb'}}
local index=runtime.bots.index_of('astra')
-- Each rocket step loads and launches at once here (a stub for the silo), its order kept; the first call is the real one.
local H=runtime.scheduler_api.handlers
local real=H.load_silo
local ran, replies = {}, {}
H.load_silo=function(p,a)
  -- a split's rocket (split_part) or one of rockets: N's (the 50 without rockets)
  if a.split_part or (a.rockets==nil and a.items and a.items[1] and a.items[1].count==50) then ran[#ran+1]=a.items and a.items[1] and a.items[1].count or 'rocket'; return {outcome='launched'} end
  local out=real(p,a); replies[#replies+1]=out; return out
end
local LOAD={position={x=40.5,y=4.5},items={{item='firearm-magazine',count=500}},launch=true,platform='Kestrel IVb'}
local function q() return storage.agent_harness.queues[index] end
local function order()
  local out={}
  for _,e in ipairs(q().history) do out[#out+1]=(e.label or e.action)..(e.ok and '' or ' FAILED') end
  return table.concat(out,', ')
end
local function step(label) return {action='wait_ticks',args={ticks=1},label=label} end

-- Astra's sequence: the split load, then the restore, then the reset; the rockets run between the load and the restore
do
  astra('queue_cancel',{})
  q().history={}
  astra('queue_submit',{steps={{action='load_silo',args=LOAD,label='load'},step('restore auto_requests'),step('reset personal max')}})
  advance(10)
  eq(order(),'load, rocket 1 of 5, rocket 2 of 5, rocket 3 of 5, rocket 4 of 5, rocket 5 of 5, restore auto_requests, reset personal max')
  eq(table.concat(ran,','),'100,100,100,100,100')
  local r=replies[#replies]
  eq(r.in_place,true); eq(r.rockets,5); eq(r.behind,2); eq(#r.steps,5)
  assert(r.split:find('^5000%.?0? kg over 5 rockets'),r.split)
  assert(r.split:find('became 5 load_silo steps (job-',1,true),r.split)
  assert(r.split:find('run right after it and before the 2 steps that follow in your queue, loading and launching in turn',1,true),r.split)
  -- the rockets are the load's plan: one plan of 8 steps
  local plan=q().history[1].plan
  for _,e in ipairs(q().history) do eq(e.plan,plan,'one plan') end
  eq(q().plan.steps,8)
end
print('d28_batch301_rt LS a queued split runs its rockets before the steps that follow: ok')

-- Pending steps before and after it keep their places; rockets: N in a queue does the same
do
  astra('queue_cancel',{})
  q().history={}; ran={}
  local three={position={x=40.5,y=4.5},items={{item='firearm-magazine',count=50}},launch=true,platform='Kestrel IVb',rockets=3}
  astra('queue_submit',{steps={step('before'),{action='load_silo',args=LOAD,label='load'},step('after 1'),{action='load_silo',args=three,label='three'},step('after 2')}})
  advance(20)
  eq(order(),'before, load, rocket 1 of 5, rocket 2 of 5, rocket 3 of 5, rocket 4 of 5, rocket 5 of 5, after 1, three, rocket 1 of 3, rocket 2 of 3, rocket 3 of 3, after 2')
  local r=replies[#replies]
  eq(r.in_place,true); eq(r.rockets,3); eq(r.behind,1)
  assert(r.note:find('became 3 load_silo steps (job-',1,true),r.note)
  assert(r.note:find('run right after it and before the 1 step that follow in your queue',1,true),r.note)
end
print('d28_batch301_rt LS pending steps keep their places; rockets: N in place too: ok')

-- No room in the queue for the rockets: the step is refused, nothing queued, and the plan pauses as on any failure
do
  astra('queue_cancel',{})
  q().history={}; ran={}
  local list={{action='load_silo',args=LOAD,label='load'}}
  for i=1,125 do list[#list+1]=step('s'..i) end
  astra('queue_submit',{steps=list})
  advance(1)
  local e=q().history[#q().history]
  eq(e.label,'load'); eq(e.ok,false)
  local why=tostring(e.result and e.result.reason)
  assert(why:find('goes as 5 rockets, which this queue step could not become in place (queue capacity exceeded: 125 pending and 5 more is over 128); nothing loaded or queued',1,true),why)
  eq(#q().pending,125); eq(q().pending[1].label,'s1'); eq(#ran,0)
  astra('queue_cancel',{})
end
print('d28_batch301_rt LS no room: refused, nothing queued: ok')

-- A direct call (no queue step running) appends as before, behind the steps pending
do
  astra('queue_cancel',{})
  q().history={}; ran={}
  astra('queue_submit',{steps={step('pending 1'),step('pending 2')},start=false})
  local r=astra('load_silo',LOAD)
  eq(r.in_place,nil); eq(r.rockets,5)
  assert(r.split:find('each a load_silo step appended to your queue, loading and launching in turn',1,true),r.split)
  local labels={}
  for i,st in ipairs(q().pending) do labels[i]=st.label end
  eq(table.concat(labels,', '),'pending 1, pending 2, rocket 1 of 5, rocket 2 of 5, rocket 3 of 5, rocket 4 of 5, rocket 5 of 5')
  astra('queue_cancel',{})
end
print('d28_batch301_rt LS a direct call appends as before: ok')
print('d28_batch301_rt LS: ok')
