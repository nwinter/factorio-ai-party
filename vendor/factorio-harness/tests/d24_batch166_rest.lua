-- Run from repository root: lua tests/d24_batch166_rest.lua
-- (d24 batch166 cp3: platform_plan and platform_production on world n took 102 ms in the first reply after a second)
-- The team block's alert routing (pushalerts.lua roster) reads every agent's place; a resting agent's place read the
-- note of the alert groups that go to it (resting_note), which read the roster again: places nested until the stack
-- ran out, each level over every alert group. Routing reads bare places (the rest's label alone); the teammates line
-- keeps the note.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
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
local nauvis={name='nauvis',index=1,valid=true,planet={name='nauvis'}}
nauvis.find_non_colliding_position=function(_,origin) return origin end
nauvis.create_entity=function(args) if args.name=='character' then return character(nauvis,args.position) end return {valid=true,name=args.name,position=args.position} end
nauvis.can_place_entity=function() return true end
nauvis.find_entities_filtered=function() return {} end
nauvis.count_entities_filtered=function() return 0 end
nauvis.get_total_pollution=function() return 0 end; nauvis.get_chunks=function() return function() end end; nauvis.get_pollution=function() return 0 end
nauvis.request_path=function() return 1 end
surfaces.nauvis=nauvis; surfaces[1]=nauvis
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local function op(action,args) return runtime.dispatch{action=action,args=args or {},operator=true} end
for _,n in ipairs{'astra','sol','muse','gemini'} do runtime.operator.bot_create(n) end
for _,n in ipairs{'astra','sol','muse','gemini'} do as(n)('status',{brief=true}) end
-- muse and gemini rest; alert groups built by each (the last scan, read by the background job)
op('rest',{agent='muse',until_clock='16:00',until_day='Sat',until_s=86400,reason='quota'})
op('rest',{agent='gemini',until_clock='16:00',until_day='Sat',until_s=86400,reason='pace'})
local s=storage.agent_harness
s.push_bg=true
local groups={}
for i=1,40 do
  local by=i%2==0 and 'muse' or 'gemini'
  groups[i]={key='low_power|nauvis|'..i,kind='low_power',surface='nauvis',center={x=i*40,y=0},by={[by]=1},n=1,line='low power '..i}
end
s.push_alerts={player={tick=game.tick,groups=groups}}

-- resting_note counted, and how deep it nests
local note=runtime.pushalerts.resting_note
local calls,depth,deepest=0,0,0
runtime.pushalerts.resting_note=function(...)
  calls=calls+1; depth=depth+1; deepest=math.max(deepest,depth)
  local ok,r=pcall(note,...)
  depth=depth-1
  if not ok then error(r,0) end
  return r
end
jump(120)
local st=as('astra')('status',{brief=true})
eq(type(st),'table')
eq(deepest,0,'a reply\'s alert routing reads no resting note')
eq(calls,0)
-- routing still sees the rest: a resting builder is not playing, so the group goes to the team
local who=runtime.pushalerts.owners(groups[2],{muse={index=runtime.bots.index_of('muse'),place=runtime.where.place(runtime.bots.index_of('muse'),true)}})
eq(who.muse,'built'); assert(who['*team'] and who['*team']:find('muse resting',1,true),tostring(who['*team']))
-- a bare place: the rest's label alone
eq(runtime.where.place(runtime.bots.index_of('muse'),true).resting,'resting until Sat 16:00 (quota)')
-- the teammates line keeps the note: once per resting agent, not nested
jump(120)
local tm=as('astra')('status').teammates
eq(deepest,1,'the note reads bare places'); eq(calls,2)
assert(tm:find('muse 4 tiles SW (resting until Sat 16:00 (quota); 20 alert groups go to it (built 20), heard by no one else)',1,true),tm)
assert(tm:find('gemini 6 tiles SW (resting until Sat 16:00 (pace); 20 alert groups go to it (built 20), heard by no one else)',1,true),tm)
runtime.pushalerts.resting_note=note
print('d24_batch166_rest: ok')
