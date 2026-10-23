-- Run from repository root: lua tests/d23_batch123.lua
-- (d23 batch123 CF1, viewer Aurora 09:44: "Luna's focus still shows the removed mash prerequisite. Could plan or dependency
-- changes flag stale focus/blocker text and prompt a refresh?") A step edited or removed, a link taken out or a title
-- changed marks the focus and team-plan lines that name what it took away: shown where they show, with the change and
-- when; the change's reply lists them; each one's agent hears it once.
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
-- Luna's case (shift63 16:04-16:10): her focus on #1052 step 8 named the approved mash site; Astra rewrote step 8.
local old8='Verify measured ingredient surplus and an approved safe supplied mash site; build one bounded upstream cell only if both pass, otherwise hold expansion.'
local pj=luna('board_post',{kind='project',title='Fresh agricultural science',steps={'source proof','ghost survey',old8}}).item
local t=astra('board_post',{kind='task',title='Scale fresh agricultural science',parent=pj.id}).item
luna('board_focus',{id=pj.id,step='3: Verify sustained ingredient headroom and Sonnet-approved mash site; otherwise hold.',
  blocker='No safe supplied mash footprint approved.',verify='Revisit build only after site owner approval.'})
luna('board_plan',{doing='#'..pj.id..' hold expansion until an approved mash site exists'})
sol('board_focus',{id=t.id,blocker='waiting on the rail'})
jump(600)
local new8='Increase net egg capacity now using a supplied breeder upgrade, then raise AG load with stock stops.'
local r=astra('board_update',{id=pj.id,edit_step={n=3,text=new8}})
eq(#r.stale,2,'the focus and the plan line')
has(r.stale[1],"luna's focus on #"..pj.id..' marked stale 0s ago: step 3 of #'..pj.id..' edited by astra (was: "Verify measured')
has(r.stale[1],'this text names approved, hold, ingredient, mash, otherwise, site, verify, safe, build')
has(r.stale[2],"luna's team-plan line marked stale 0s ago: step 3 of #"..pj.id..' edited by astra')
has(r.stale[2],'this text names approved, expansion, hold, mash, site')
-- where it shows: her status, the focus read's rows, the plan
jump(120)
local st=luna('status')
has(st.focus,'blocker: No safe supplied mash footprint approved.; next verification: Revisit build only after site owner approval.; marked stale 2s ago: step 3 of #'..pj.id)
local fr=astra('board_focus',{agent='luna'})
has(fr.rows[1].stale,'marked stale 2s ago: step 3'); eq(fr.rows[1].stale_tick,tick-120)
local pv=astra('board_plan',{})
has(pv.plan.doing[1],'[marked stale 2s ago: step 3 of #'..pj.id)
-- Sol's focus on the task names none of it: unmarked
eq(runtime.progress.focus_row('sol').stale,nil)
-- Luna hears it once (her status reply above carried it in her team alerts), Astra (who made it) does not
local function alerts(who)
  local got={}
  for _,l in ipairs(runtime.progress.lines({index=0,name=who},{}) or {}) do got[#got+1]=l end
  return got
end
local la={}
for _,l in ipairs((st.team or {}).alerts or {}) do if l:find('marked stale',1,true) then la[#la+1]=l end end
eq(#la,2); has(la[1],'your focus on #'..pj.id..' is marked stale'); has(la[1],'the mark stays until board_focus {id} sets a focus')
has(la[2],'your team-plan line is marked stale'); has(la[2],'the mark stays until board_plan {doing} sets the line')
for _,l in ipairs((luna('status').team or {}).alerts or {}) do assert(not l:find('marked stale',1,true),l) end
eq(#alerts('astra'),0)
-- a new focus and a new line end the marks
luna('board_focus',{id=pj.id,step=3})
eq(runtime.progress.focus_row('luna').stale,nil)
luna('board_plan',{doing='#'..pj.id..' egg capacity first'})
eq(astra('board_plan',{}).plan.doing[1],'luna: #'..pj.id..' egg capacity first')
-- a dependency taken out: a blocker naming #id is marked; a removed focused step is marked by its number
local dep=astra('board_post',{kind='task',title='Mash cell scaffold'}).item
local t2=sol('board_post',{kind='task',title='Bioflux line',blocked_by=dep.id}).item
sol('board_focus',{id=t2.id,blocker='#'..dep.id..' first'})
r=sol('board_update',{id=t2.id,blocked_by={}})
eq(#r.stale,1); has(r.stale[1],'your focus on #'..t2.id..' marked stale 0s ago: #'..dep.id..' taken out of the blocked_by of #'..t2.id..' by sol (was: "Mash cell scaffold"); this text names #'..dep.id)
eq(#alerts('sol'),0,'the one who made the change reads it in the reply')
r=astra('board_update',{id=pj.id,remove_step=3})
has(r.stale[1],"luna's focus on #"..pj.id..' marked stale 0s ago: step 3 of #'..pj.id..' removed by astra (was: "'..new8..'"); this text names step 3')
-- an edit that leaves the words: no mark
luna('board_focus',{id=pj.id,step=1,blocker='source proof pending'})
r=luna('board_update',{id=pj.id,edit_step={n=1,text='source proof, pending the clean window'}})
eq(r.stale,nil)
print('d23_batch123: ok')
