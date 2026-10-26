-- Run from repository root: lua tests/d25_batch214.lua
-- d25 batch214 QZ1 (Sol #2379: a 600 s uptime watch of 20 machines gave machine_rows as a string above 16, so each
-- machine's shortage counters, coal against sulfur, could not be compared). uptime {read: true} reads a watch in
-- pages of structured rows (exact ticks, shortage counters per ingredient), by id any agent's, positions picking
-- machines of it; it never starts or replaces a watch, and the default read stays as it was. A queue step and dry_run
-- check it.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..'\n  lacks: '..x) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,'should be refused'); return tostring(err) end
game={tick=1000}
defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3}}
local recipe={name='explosives',ingredients={{type='item',name='coal',amount=1},{type='item',name='sulfur',amount=1},{type='fluid',name='water',amount=10}}}
-- 20 chemical plants; machine k holds coal k%3 and sulfur k%2 (so short of coal on k%3==0, of sulfur on even k)
local ms={}
for k=1,20 do
  local e={valid=true,name='chemical-plant',type='assembling-machine',position={x=k*4+0.5,y=10.5},products_finished=0,status='working',k=k}
  e.get_recipe=function() return recipe,{name='normal'} end
  e.get_fluid_count=function() return 100 end
  e.get_inventory=function() return {get_item_count=function(id) local n=type(id)=='table' and id.name or id; if n=='coal' then return k%3 end if n=='sulfur' then return k%2 end return 0 end,
    get_contents=function() return {} end} end
  ms[k]=e
end
local st={}
local api={state=function() return st end,remote_entity=function(_,t) for _,e in ipairs(ms) do if e.position.x==t.position.x then return e end end error('none') end,
  status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=30,productivity=0} end,who_index=function(i) return ({'sol','astra'})[i] end}
local U=dofile('mod/agent-harness_0.1.0/uptime.lua')(api)
local sol,astra={index=1},{index=2}
local positions={}
for k=1,20 do positions[k]={x=ms[k].position.x,y=10.5} end
U.handler(sol,{positions=positions,seconds=60})
local job=st.uptime[1]
local short_from=1300
local function run(to)
  while game.tick<to do
    game.tick=game.tick+1
    if game.tick>=job.next_tick then for _,e in ipairs(ms) do e.status=game.tick>=short_from and (e.k%3==0 or e.k%2==0) and 'item_ingredient_shortage' or 'working'; if e.status=='working' then e.products_finished=e.products_finished+1 end end end
    U.tick(game.tick)
  end
end
run(2200)
-- the default read: as before (above 16 machines no rows, each in lines)
local d=U.handler(sol,{})
eq(type(d.machine_rows),"string"); eq(d.machines,nil); eq(#d.lines,21,"a group line and 20 machines")
-- page 1: 16 structured rows, page 2 the other 4; the watch is not restarted
local start,samples=job.start,job.samples
local p1=U.handler(sol,{read=true})
eq(p1.read,true); eq(p1.id,'uptime@1000'); eq(p1.page,1); eq(p1.pages,2); eq(p1.page_size,16); eq(#p1.machines,16); eq(p1.machines_total,20); eq(p1.matched,20)
eq(p1.watching,true); eq(p1.started_tick,1000); eq(p1.to_tick,2200); eq(p1.sampled_tick,job.sampled); eq(p1.samples,job.samples)
eq(p1.machines[1].line,nil,'no line without details'); eq(p1.lines,nil)
local p2=U.handler(sol,{read=true,page=2})
eq(#p2.machines,4); eq(p2.machines[1].index,17); eq(p2.machines[4].index,20)
has(p2.line,'uptime watch uptime@1000 (watching, '..job.samples..' samples to tick '..job.sampled..'): page 2 of 2, machines 17-20 of 20')
eq(st.uptime[1],job,'the same watch'); eq(job.start,start); eq(job.samples,samples)
-- the shortage counters per ingredient, with their ticks: machine 6 short of both, 3 of coal, 4 of sulfur, 5 of none
local r6=p1.machines[6]
eq(r6.index,6); eq(r6.recipe,'explosives')
local c,s=r6.short_counts.coal,r6.short_counts.sulfur
eq(c.samples,r6.samples.item_ingredient_shortage); eq(c.least,0); eq(c.need,1); assert(c.first_tick>=short_from and c.last_tick<=2200 and c.first_tick<c.last_tick,'ticks')
eq(s.samples,c.samples); eq(s.first_tick,c.first_tick)
eq(p1.machines[3].short_counts.sulfur,nil); eq(p1.machines[3].short_counts.coal.samples,c.samples)
eq(p1.machines[4].short_counts.coal,nil)
eq(p1.machines[5].short_counts,nil)
eq(r6.status_runs.item_ingredient_shortage.first_tick,c.first_tick,'status runs keep their ticks')
-- details: each row's line and lines; positions pick machines of it (nearest centre within 2 tiles), the rest named
local pd=U.handler(sol,{read=true,details=true,page_size=2,positions={{x=24.5,y=10.5},{x=13,y=11},{x=500,y=0}}})
eq(pd.matched,2); eq(#pd.machines,2); eq(pd.machines[1].index,3,'in the watch\'s order'); eq(pd.machines[2].index,6)
has(pd.machines[2].line,'chemical-plant (24.5,10.5) explosives'); has(pd.machines[2].line,'coal short in')
eq(#pd.lines,2); eq(pd.not_found[1].x,500)
has(pd.line,'picked by positions from its 20; 1 position matches no machine of it (within 2 tiles)')
-- another agent reads it by id (named), never its own: astra has none
has(refused(function() U.handler(astra,{read=true}) end),'no uptime watch yet')
local pa=U.handler(astra,{read=true,id='uptime@1000',page=2})
eq(pa.agent,'sol'); eq(#pa.machines,4)
has(refused(function() U.handler(astra,{read=true,id='uptime@999'}) end),'no uptime watch uptime@999 is kept')
-- past the last page: none, said
local px=U.handler(sol,{read=true,page=3})
eq(#px.machines,0); has(px.line,'page 3 is past the last (2)')
-- done: counted to its end however late the read; the owner's read marks it read, another's does not
run(1000+60*60+600)
eq(job.result~=nil,true)
local f=U.handler(astra,{read=true,id='uptime@1000'})
eq(f.done,true); eq(f.to_tick,job.until_tick); eq(f.seconds,60); eq(job.read_tick,nil)
local fin=job.result
local f2=U.handler(sol,{read=true,page=2})
eq(job.read_tick,game.tick)
eq(f2.machines[4].completions,ms[20].products_finished,'its final completions')
eq(job.result,fin,'the final result is unchanged')
-- refused with no world, as at submit and in dry_run
has(refused(function() U.check_read({read=true,seconds=60}) end),'read: true takes id, agent, positions, page, page_size and details; seconds goes with a new watch')
has(refused(function() U.check_read({read=true,page_size=17}) end),'page_size: 1..16')
has(refused(function() U.check_read({read=true,page=0}) end),'page: 1..64')
has(refused(function() U.check_read({read=true,id='1000'}) end),'id: a watch\'s id as status work gives it, "uptime@START_TICK/AGENT"')
has(refused(function() U.check_read({read=false}) end),'read: true reads a watch in pages')
eq(U.starts({read=true,positions={{x=1,y=1}}}),false,'a read never starts a watch')
U.check_read({read=true,id='uptime@1000',page=4,page_size=16,details=true,positions={{x=1,y=2}}})
print('d25_batch214 QZ1 uptime read in pages: ok')

-- the queue: dry_run and submit check it as the call does
do
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
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
pcall(runtime.operator.bot_create,'astra')
local function plan(steps) return function() return runtime.dispatch{action='queue_submit',args={dry_run=true,steps=steps},bot='astra'} end end
local function no_check(fn) local ok,err=pcall(fn); assert(ok or not (tostring(err):find('read: true',1,true) or tostring(err):find('what uptime takes',1,true)),tostring(err)) end
has(refused(plan({{action='wait_ticks',args={ticks=60}},{action='uptime',label='page',args={read=true,page_size=17}}})),'steps[2] (uptime, label "page")')
has(refused(plan({{action='uptime',args={read=true,page_size=17}}})),'steps[1] (uptime): args: page_size: 1..16')
has(refused(plan({{action='uptime',args={read=true,page=65}}})),'page: 1..64')
has(refused(plan({{action='uptime',args={read=true,seconds=600}}})),'seconds goes with a new watch')
has(refused(plan({{action='uptime',args={read=true,id='x'}}})),'"uptime@START_TICK"')
no_check(plan({{action='uptime',args={read=true,id='uptime@1000',page=2,page_size=8,details=true}}}))
-- a constant moved moves both
runtime.uptime.ROWS=8
has(refused(plan({{action='uptime',args={read=true,page_size=9}}})),'page_size: 1..8')
runtime.uptime.ROWS=16
end
print('d25_batch214 QZ1 queue checks: ok')
