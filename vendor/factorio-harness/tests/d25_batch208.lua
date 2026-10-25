-- Run from repository root: lua tests/d25_batch208.lua
-- d25 batch208 QU1 (Astra #2355: trial187's queue dry_run took platform_defense, uptime and platform_supply reasons over
-- 200 characters; the steps then refused them when they ran): every queue step's text and list arguments are checked
-- at submit and in dry_run against the lengths the action takes when it runs (runtime.lua step_lengths), from the
-- action's own constants, naming the step, the argument, its length and the limit.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
  on_built_entity=15,on_player_mined_entity=16,on_robot_mined_entity=17,on_player_fast_transferred=18,on_gui_opened=19,on_gui_closed=20},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surfaces={}
local function character(surface,pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+#surfaces,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
local function new_surface(name,index,extra)
  local s={name=name,index=index,valid=true}
  for k,v in pairs(extra) do s[k]=v end
  s.find_non_colliding_position=function(_,origin) return origin end
  s.create_entity=function(args) if args.name=='character' then return character(s,args.position) end return {valid=true,name=args.name,position=args.position} end
  s.can_place_entity=function() return true end
  s.find_entities_filtered=function() return {} end
  s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
  surfaces[name]=s; surfaces[index]=s
  return s
end
local nauvis=new_surface('nauvis',1,{planet={name='nauvis'}})
local vulcanus=new_surface('vulcanus',2,{planet={name='vulcanus'}})
new_surface('platform-1',3,{platform={name='Peregrine'}})
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=nauvis,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character(nauvis,{x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=nauvis,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local astra,sol,luna,opus=as('astra'),as('sol'),as('luna'),as('opus')
local names={'astra','sol','luna','opus','kai','grok','mira'}
for _,n in ipairs(names) do runtime.operator.bot_create(n) end
local function has(s,part) assert(type(s)=="string" and s:find(part,1,true),tostring(s).." lacks "..part) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,"should be refused"); return tostring(err) end
local function plan(steps,dry) return function() return astra('queue_submit',{dry_run=dry,steps=steps}) end end
local long=string.rep('x',214)
-- Astra's steps: refused in the dry run and at submit, the step named, the action's own limit and the length given
for _,st in ipairs({
  {action='platform_defense',label='asteroids',args={platform='Peregrine',asteroids=true,seconds=600,reason=long}},
  {action='uptime',label='rates',args={positions={{x=0,y=0}},seconds=600,reason=long}},
  {action='platform_supply',label='chunks',args={platform='Peregrine',collection=true,seconds=600,reason=long}}}) do
  local e=refused(plan({{action='wait_ticks',args={ticks=60}},st},true))
  has(e,'steps[2] ('..st.action..', label "'..st.label..'")')
  has(e,'reason: up to 200 characters (214 given), what '..st.action..' takes when it runs')
  has(refused(plan({st})),'reason: up to 200 characters (214 given)')
end
-- the reason is counted as the watch counts it: line breaks as spaces, the ends trimmed
local function no_length(fn) local ok,err=pcall(fn); assert(ok or not tostring(err):find('takes when it runs',1,true),tostring(err)) end
no_length(plan({{action='uptime',args={positions={{x=0,y=0}},seconds=600,reason='  '..string.rep('y',200)..'\n'}}},true))
-- a read of a watch (no new watch) takes no reason; the action leaves it unread, and so does the check
no_length(plan({{action='uptime',args={reason=long}}},true))
-- the limit is the action's constant (measures.REASON): a changed constant changes both
runtime.measures.REASON=10
has(refused(plan({{action='uptime',args={positions={{x=0,y=0}},seconds=600,reason=string.rep('z',11)}}},true)),'reason: up to 10 characters (11 given)')
has(refused(function() return astra('uptime',{positions={{x=0,y=0}},seconds=600,reason=string.rep('z',11)}) end),'reason: up to 10 characters (11 given)')
runtime.measures.REASON=200
-- lists and texts: the step, the argument, its length and the limit
local e=refused(function() return astra('queue_submit',{dry_run=true,lane='remote',steps={{action='scan',label='ores',args={positions=(function() local t={} for i=1,65 do t[i]={x=i,y=0} end return t end)()}}}}) end)
has(e,'steps[1] (scan, label "ores")'); has(e,'positions has 65 entries, outside 1..64, what scan takes when it runs')
has(refused(plan({{action='platform_rename',args={platform='Peregrine',name=string.rep('n',65)}}},true)),'name is 65 characters, outside 1..64, what platform_rename takes when it runs')
has(refused(plan({{action='platform_rename',args={platform='Peregrine',name=string.rep('é',33)}}},true)),'name is 33 characters (66 bytes), outside 1..64')
has(refused(plan({{action='configure',args={position={x=0,y=0},speaker_alert={message=string.rep('m',501)}}}},true)),'speaker_alert.message is 501 characters, outside 0..500, what configure takes')
has(refused(plan({{action='platform_defense',args={platform='Peregrine',asteroids=true,asteroid_names={'small-*',string.rep('a',101)}}}},true)),'asteroid_names[2] is 101 characters, outside 1..100')
has(refused(plan({{action='remove_ghosts',args={names=(function() local t={} for i=1,33 do t[i]='n'..i end return t end)()}}},true)),'names has 33 entries, outside 1..32')
-- a mode's own limit: a tour's dry run reads up to 128 stops, a live one walks to 64
prototypes=prototypes or {}  -- a queued transfer checks its item where the game has prototypes
local function places(n) local t={} for i=1,n do t[i]={x=i,y=0} end return t end
has(refused(plan({{action='transfer',args={item='coal',direction='to_entity',positions=places(65)}}},true)),'positions has 65 entries, outside 1..64, what transfer takes')
no_length(plan({{action='transfer',args={item='coal',direction='to_entity',positions=places(128),dry_run=true}}},true))
has(refused(plan({{action='transfer',args={item='coal',direction='to_entity',positions=places(129),dry_run=true}}},true)),'positions has 129 entries, outside 1..128')
-- a table of named fields ({item: count}, {x, y}) is left to the action
no_length(plan({{action='load_silo',args={first={coal=10}}}},true))
no_length(plan({{action='load_silo',args={from={x=1,y=2}}}},true))
-- feed counts its item with its items, as the action does
local sixteen={} for i=1,16 do sixteen[i]='item-'..i end
has(refused(plan({{action='feed',args={item='coal',items=sixteen}}},true)),'items has 17 entries (item counts too), outside 1..16, what feed takes')
sixteen[16]='coal'; no_length(plan({{action='feed',args={item='coal',items=sixteen}}},true))
-- refuel: 64 positions a walk, 128 for a tour with from, area or feed_chests, or in a dry run
has(refused(function() runtime.step_length_check('refuel',{positions=places(65)}) end),'positions has 65 entries, outside 1..64, what refuel takes')
runtime.step_length_check('refuel',{positions=places(128),from={x=0,y=0}})
runtime.step_length_check('refuel',{positions=places(128),dry_run=true})
-- every entry, from its own constants: one past the limit refused, the limit itself not
local modes={{},{wait_ticks=60},{asteroids=true,seconds=600},{collection=true,seconds=600},{position={x=0,y=0}},{positions={{x=0,y=0}}},
  {dry_run=true},{from={x=0,y=0}},{area={left_top={x=0,y=0},right_bottom={x=8,y=8}}},{tiles=true},{status='current'}}
local function set(a,key,v)
  local parts={} for k in key:gmatch('[^.]+') do parts[#parts+1]=k end
  local t=a
  for i=1,#parts-1 do t[parts[i]]=t[parts[i]] or {}; t=t[parts[i]] end
  t[parts[#parts]]=v
end
local checked,n=0,0
for action,list in pairs(runtime.step_lengths) do
  for _,r in ipairs(list) do
    n=n+1
    local lo,hi=r[2],r[3]
    if type(lo)=='function' then lo=lo() end
    if type(hi)=='function' then hi=hi() end
    local function value(len) if r.list then local t={} for i=1,len do t[i]='x'..i end return t end return string.rep('x',len) end
    local function args(len)
      for _,m in ipairs(modes) do
        local a={} for k,v in pairs(m) do a[k]=v end
        set(a,r[1],value(len))
        if not r.when or r.when(a) then return a end
      end
      error(action..' '..r[1]..': no mode its when takes')
    end
    if not r.check then
      local over=refused(function() runtime.step_length_check(action,args(hi+1)) end)
      has(over,r[1]..' '..(r.list and 'has '..(hi+1)..' entries' or 'is '..(hi+1)..' characters')..', outside '..lo..'..'..hi..', what '..action..' takes when it runs')
      runtime.step_length_check(action,args(math.max(hi,lo)))
      if lo>=1 then has(refused(function() runtime.step_length_check(action,args(lo-1)) end),'outside '..lo..'..'..hi) end
      checked=checked+1
    end
  end
end
assert(checked>=90,'entries checked: '..checked)
-- the validators: the reason, a blueprint library name, a requests group
local GROUP_MAX=dofile('mod/agent-harness_0.1.0/reqgroups.lua')().MAX_NAME
has(refused(function() runtime.step_length_check('sleep',{reason=string.rep('r',201)}) end),'reason: up to 200 characters (201 given), what sleep takes')
has(refused(function() runtime.step_length_check('blueprint_save',{name=string.rep('b',41)}) end),'name must be 1..40 letters, digits, _ . -')
has(refused(function() runtime.step_length_check('requests',{group=string.rep('g',GROUP_MAX+1)}) end),'group is a name (1..'..GROUP_MAX..' characters)')
runtime.step_length_check('requests',{group=false})
-- every listed key is an argument its action takes
local acts=astra('describe',{}).actions
for action,list in pairs(runtime.step_lengths) do
  assert(acts[action],'step_lengths: no action '..action)
  for _,r in ipairs(list) do local k=r[1]:match('^[^.]+'); assert(acts[action][k]~=nil,'step_lengths: '..action..' takes no '..k) end
end
-- the step label (64 bytes) was already checked at submit; it still is
has(refused(plan({{action='wait_ticks',label=string.rep('l',65),args={ticks=60}}},true)),'label must be a string of at most 64 bytes')
print('d25_batch208 QU1 queue step lengths: ok ('..n..' entries)')
