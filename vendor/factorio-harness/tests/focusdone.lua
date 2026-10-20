-- Run from repository root: lua tests/focusdone.lua
-- (d20 batch57 S2, viewer Aurora, shift47 inbox 16:46: "Could task completion refresh focus and offer ready work toward the
-- shared goal?") A board_update that marks an agent's focused item done or dropped, or its focused project step done,
-- clears the focus: the reply says so and lists the ready work (open unowned tasks and requests, free steps of unblocked
-- projects open to the agent; those the team plan names first; at most 5, each with id, title and age); the agent's
-- status says no focus is set until one is.
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
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sol',glyph='S',color='#ffcb45'})
local muse=as('muse')
runtime.operator.bot_create('muse')
local printed={}
nick.print=function(l) printed[#printed+1]=l end
local function op(action,args) return runtime.dispatch{action=action,args=args,operator=true} end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
-- the board: a task Sol focuses, ready work around it, the team plan naming #p2
local t1=sol('board_post',{kind='task',title='Wall the east lake gap'}).item
sol('board_update',{id=t1.id,owner='sol',status='doing'})
local r1=astra('board_post',{kind='request',title='Laser turrets for the south wall'}).item
jump(600)
local t2=astra('board_post',{kind='task',title='Rebuild NW coal'}).item
local t3=astra('board_post',{kind='task',title='Blocked by the wall',blocked_by=t1.id}).item
local p1=astra('board_post',{kind='project',title='Copper foundry',steps={'site','casting line','retire stone rows'}}).item
local p2=sol('board_post',{kind='project',title='Edge route ship',steps={'hull','guns'}}).item
local p3=astra('board_post',{kind='project',title='Astra only',steps={'x'}}).item
astra('board_update',{id=p3.id,owner='astra',status='doing'})
op('board_plan',{goals='Reach the solar system edge: #'..p2.id..' carries it'})
sol('board_focus',{id=t1.id,verify='the wall stands'})
jump(3600)
-- done: cleared, with the ready work
local r=sol('board_update',{id=t1.id,status='done',note='walled'})
has(r.focus_cleared,'your focus on #'..t1.id..' Wall the east lake gap cleared: #'..t1.id..' is done; no focus is set until board_focus {id} sets one')
assert(type(r.ready)=='table',tostring(r.ready))
-- the plan's project first, then by number; p3 is Astra's and its steps are not open; t3 is now unblocked
has(r.ready[1],'#'..p2.id..' step 1: hull (project Edge route ship, step 1m00s old) (named in the team plan)')
has(r.ready[2],'#'..p2.id..' step 2: guns')
has(r.ready[3],'#'..r1.id..' Laser turrets for the south wall (request, 1m10s old)')
has(r.ready[4],'#'..t2.id..' Rebuild NW coal (task, 1m00s old)')
has(r.ready[5],'#'..t3.id..' Blocked by the wall (task')
eq(r.ready[6],'+3 more')
for _,l in ipairs(r.ready) do assert(not l:find('Astra only',1,true),l) end
-- status says no focus until one is set
local st=sol('status')
has(st.focus,'no focus set (cleared 0s ago: #'..t1.id..' is done, marked by sol)')
eq(st.ready[1],r.ready[1])
jump(600)
sol('board_focus',{id=p2.id,step=1})
st=sol('status')
has(st.focus,'sol focus (set 0s ago): #'..p2.id..' Edge route ship; step 1 hull'); eq(st.ready,nil)
-- the focused step done: cleared; another step done: not
r=sol('board_update',{id=p2.id,done=2})
eq(r.focus_cleared,nil)
r=sol('board_update',{id=p2.id,done=1})
has(r.focus_cleared,'your focus on #'..p2.id..' Edge route ship (step 1) cleared: step 1 of #'..p2.id..' is done')
-- a teammate's focus on an item someone else drops: theirs cleared, the reply names it, no ready list for the dropper
astra('board_focus',{id=t2.id})
r=sol('board_update',{id=t2.id,owner='sol'}); eq(r.focus_cleared,nil)
r=sol('board_update',{id=t2.id,status='dropped',note='coal is gone'})
eq(r.focus_cleared,"astra's focus on #"..t2.id..' Rebuild NW coal cleared: #'..t2.id..' is dropped'); eq(r.ready,nil)
has(astra('status').focus,'no focus set (cleared 0s ago: #'..t2.id..' is dropped, marked by sol)')
-- a status change that is not done or dropped leaves it
astra('board_focus',{id=r1.id})
r=astra('board_update',{id=r1.id,status='blocked',note='no lasers'}); eq(r.focus_cleared,nil)
has(astra('status').focus,'astra focus')
print('focusdone: ok')
