-- d27 batch261 through the runtime against a fake engine (the scaffold of tests/d26_batch249b.lua): a direct wait_until on
-- tick_at_least, and the queue replies' guard scope. Run from the harness root: lua tests/d27_batch261_rt.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok,'expected a refusal: '..text); assert(tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27},
  direction={north=0},inventory={chest=1},build_mode={normal=1},flow_precision_index={five_seconds=0,one_minute=1}}
local p={index=1,name='luna',valid=true,connected=true,controller_type=1,physical_controller_type=1,character={valid=true},position={x=0,y=0},cheat_mode=false,driving=false}
local charted={}
p.force={name='player',platforms={},is_chunk_visible=function() return false end,
  is_chunk_charted=function(s,c) return charted[s.name]~=false end,get_spawn_position=function() return {x=0,y=0} end}
local nauvis={name='nauvis',index=1,valid=true,planet={name='nauvis'}}
local gleba={name='gleba',index=4,valid=true,planet={name='gleba'}}
local asterion={name='platform-16',index=20,valid=true}
p.surface=nauvis
p.character.surface=nauvis
p.character.prototype={collision_mask={layers={player=true}},crafting_categories={crafting=true}}
p.can_reach_entity=function() return true end
p.create_local_flying_text=function() end
p.get_main_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end
for _,s in ipairs({nauvis,gleba,asterion}) do
  s.find_entities_filtered=function() return {} end; s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
end
asterion.platform={name='Asterion',force=p.force,valid=true}
p.force.platforms={{name='Asterion',valid=true,surface=asterion,force=p.force}}
local surfaces={nauvis=nauvis,gleba=gleba,['platform-16']=asterion}
local pollution_stats={input_counts={},output_counts={},get_flow_count=function() return 0 end}
game={tick=0,surfaces=surfaces,get_surface=function(n) return surfaces[n] end,get_player=function(i) if i==1 or i=='luna' then return p end end,
  forces={player=p.force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
    get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  players={p},connected_players={p},get_pollution_statistics=function() return pollution_stats end,print=function() end}
prototypes={quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5},['quality-unknown']={level=0}},
  item={['electronic-circuit']={type='item'},['artillery-targeting-remote']={type='capsule'},['iron-plate']={type='item'},
    ['asteroid-collector']={type='item'},crusher={type='item'}},
  recipe={['electronic-circuit']={products={{type='item',name='electronic-circuit'}}},['laser-turret']={products={{type='item',name='laser-turret'}}},
    ['electric-mining-drill']={products={{type='item',name='electric-mining-drill'}}}},
  technology={['laser-turret']={effects={{type='unlock-recipe',recipe='laser-turret'}}}},
  entity={['underground-belt']={},['fast-underground-belt']={},['requester-chest']={}}}
p.force.recipes={['electronic-circuit']={name='electronic-circuit',enabled=true,category='crafting'},['laser-turret']={name='laser-turret',enabled=false,category='crafting'}}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function call(action,args) return runtime.dispatch{action=action,args=args,player=1} end

-- AD: a direct wait_until with no timeout runs to its tick_at_least (up to 54000 ticks); one passed is met at once
do
  game.tick=70181005; p.crafting_queue_size=0
  local r=call('wait_until',{['until']='tick_at_least',tick=70181005+20000})
  eq(r.until_tick,70201005); eq(r.condition,'tick_at_least')
  r=call('wait_until',{['until']='any',conditions={{['until']='crafting_done'},{['until']='tick_at_least',tick=70181005+90000}}})
  eq(r.outcome,'met','crafting_done holds: met at once')
  p.crafting_queue_size=2
  r=call('wait_until',{['until']='any',conditions={{['until']='crafting_done'},{['until']='tick_at_least',tick=70181005+90000}}})
  eq(r.until_tick,70181005+54000,'a direct call up to 54000 ticks')
  r=call('wait_until',{['until']='tick_at_least',tick=70181005+20000,timeout=600})
  eq(r.until_tick,70181605,'a timeout given stands')
  r=call('wait_until',{['until']='tick_at_least',tick=70100000})
  eq(r.outcome,'met'); assert(r.saw:find('tick 70100000 reached',1,true),r.saw)
  p.crafting_queue_size=0
  call('stop',{})
end
print('d27_batch261_rt AD direct wait_until on tick_at_least: ok')

-- GR: the compact queue reply names a standing guard; a plan guard on an idle lane is refused through dispatch
do
  local g={['until']='tick_at_least',tick=game.tick+100000}
  fails(function() call('queue_submit',{lane='remote',steps={},guards={{when=g}}}) end,'guards[1]: scope plan (the default) retires a guard when the lane has no step left')
  local r=call('queue_submit',{lane='remote',steps={},guards={{when=g,scope='standing'}}})
  eq(r.guard_ids[1],'guard-1 tick_at_least (standing)')
  r=call('queue_status',{lane='remote'})
  assert(r.guards_after_plan:find('1 guard still armed with no step left',1,true),tostring(r.guards_after_plan))
  eq(r.guards[1].scope,'standing'); eq(r.guards[1].ticks_left,100000)
  call('queue_cancel',{lane='remote'})
end
print('d27_batch261_rt GR queue replies name the scope: ok')
