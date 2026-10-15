-- Run from repository root: lua tests/minds.lua
-- Agent-minds study fixes 6, 9 and 10 (pW): argument aliases with the call as
-- it ran, scan fields as one string, empty transfers that say why and the
-- third repeat, "unpowered" for a machine no pole reaches, the brief board
-- read, tells with a cursor, brief queue writes.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
  controllers={character=1,remote=27,spectator=2},direction={north=0,east=4},inventory={chest=1},build_mode={normal=1},
  build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1},entity_status={working=1,normal=2,low_power=14}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={['iron-plate']={},['copper-plate']={},['iron-gear-wheel']={}},fluid={},recipe={},entity={}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,recipes={}}
local surface={name='nauvis',index=1}
-- A chest holding copper plate, a roboport no pole reaches, a pole 7 tiles from it.
local chest_items={['copper-plate']=15}
local function chest_inv()
  local t={valid=true}
  t.get_item_count=function(q) local n=type(q)=='table' and q.name or q; return chest_items[n] or 0 end
  t.get_contents=function() local out={}; for n,c in pairs(chest_items) do out[#out+1]={name=n,count=c,quality='normal'} end; return out end
  t.is_empty=function() return next(chest_items)==nil end
  setmetatable(t,{__len=function() return 1 end})
  t[1]={valid_for_read=false}
  return t
end
local chest={valid=true,name='wooden-chest',type='container',position={x=3.5,y=3.5},force=force,surface=surface,
  get_inventory=function(i) if i==1 then return chest_inv() end end,get_fluid_contents=function() return {} end}
local port={valid=true,name='roboport',type='roboport',position={x=10,y=10},force=force,surface=surface,status=2,
  prototype={electric_energy_source_prototype={}},get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
local pole={valid=true,name='medium-electric-pole',type='electric-pole',position={x=17,y=10},force=force,surface=surface,electric_network_id=4}
local all={chest,port,pole}
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(all) do
    local ok=true
    if f.position then ok=((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5<=(f.radius or 0.5) end
    if ok and f.type and type(f.type)=='string' then ok=e.type==f.type end
    if ok and f.name and type(f.name)=='string' then ok=e.name==f.name end
    if ok then out[#out+1]=e end
  end
  return out
end
surface.count_entities_filtered=function(f) return #surface.find_entities_filtered(f) end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.can_place_entity=function() return true end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local function character(pos)
  local items={}
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=100,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) local n=type(q)=='table' and q.name or q; return items[n] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end,count_empty_stacks=function() return 10 end}
  setmetatable(inv,{__len=function() return 0 end})
  c.get_main_inventory=function() return inv end
  c.get_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  c.prototype={collision_mask={layers={player=true}}}
  return c
end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5}); nick.print=function() end
local players={nick}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
runtime.operator.bot_create('sol'); runtime.operator.bot_create('luna')
local function sol(action,args) return runtime.dispatch{action=action,args=args or {},bot='sol'} end
local function luna(action,args) return runtime.dispatch{action=action,args=args or {},bot='luna'} end
local body=runtime.bots.record(runtime.bots.index_of('sol')).character
body.position={x=5,y=5}

-- Fix 10: a wrong argument name the harness knows runs as meant; the reply shows the call as it ran.
local r=sol('move_to',{target={x=3,y=3}})
eq(r.corrected,'move_to {"position":{"x":3,"y":3}} (target is position)')
-- A collect waiting at one machine takes its one position as positions without a correction (collectwait).
do
  local A=dofile('mod/agent-harness_0.1.0/aliases.lua')({})
  local takes=function(_,k) return k=='positions' or k=='wait_ticks' end
  local _,fixed,notes=A.fix('collect',{position={x=18.5,y=-31.5},wait_ticks=60},takes)
  eq(notes,nil); eq(fixed.position,nil); eq(fixed.positions[1].x,18.5)
  local _,plain,noted=A.fix('collect',{position={x=18.5,y=-31.5}},takes)
  eq(noted.notes[1],'position is positions (a list)'); eq(plain.positions[1].y,-31.5)
end
-- Transfer's target named twice, alone, or as two places (Muse, Luna, shift11; operator 10:50 item 6).
do
  local A=dofile('mod/agent-harness_0.1.0/aliases.lua')({})
  local takes=function(action,k)
    local t={transfer={position=true,positions=true,direction=true,item=true,count=true,inventory=true,pick=true,items=true,to=true},
      recipes={prefix=true,limit=true},craftable={recipes=true}}
    return (t[action] or {})[k]==true
  end
  local P={x=15.5,y=59.5}
  -- the same place as position, as to_entity (17:18:52) or to (17:18:55): the one position
  local _,f,n=A.fix('transfer',{position=P,item='rocket-fuel',count=50,direction='to_entity',to_entity={x=15.5,y=59.5},inventory='rocket_silo_rocket'},takes)
  eq(f.to_entity,nil); eq(f.direction,'to_entity'); eq(n.notes[1],'to_entity at the same place as position is direction="to_entity"')
  _,f,n=A.fix('transfer',{position=P,item='rocket-fuel',count=50,direction='to_entity',to={x=15.5,y=59.5}},takes)
  eq(f.to,nil); eq(n.notes[1],'to at the same place as position is direction="to_entity"')
  -- to or from alone, without pick: the position and the side
  _,f,n=A.fix('transfer',{item='spoilage',count=200,to={x=34.5,y=34.5}},takes)
  eq(f.position.x,34.5); eq(f.direction,'to_entity'); eq(f.to,nil); eq(n.notes[1],'to={x,y} without pick is position=... direction="to_entity"')
  _,f=A.fix('transfer',{item='iron-plate',from={x=3.5,y=3.5}},takes)
  eq(f.position.y,3.5); eq(f.direction,'to_player')
  -- amount is count
  _,f,n=A.fix('transfer',{position=P,direction='to_entity',item='firearm-magazine',amount=40},takes)
  eq(f.count,40); eq(f.amount,nil)
  -- two places (friction2: Grok): a take at one and a give at the other, as the pick courier
  _,f,n=A.fix('transfer',{from_entity={x=52.5,y=45.5},to_entity={x=65.5,y=14.5},item='coal'},takes)
  eq(f.pick,'first_with_stock'); eq(f.positions[1].x,52.5); eq(f.to.y,14.5); eq(f.from_entity,nil); eq(f.to_entity,nil)
  eq(n.notes[1],'from_entity and to_entity without pick: a take there and a give at to_entity (pick="first_with_stock")')
  -- a form the docs give: quiet (no corrected on success; friction3), unless another note goes with it
  eq(n.quiet,true)
  _,f,n=A.fix('transfer',{from_entity={x=52.5,y=45.5},to_entity={x=65.5,y=14.5},item='coal',amount=5},takes)
  eq(f.count,5); eq(#n.notes,2); eq(n.quiet,nil)
  _,f,n=A.fix('transfer',{position={x=52.5,y=45.5},to={x=65.5,y=14.5},item='coal',count=5},takes)
  eq(f.pick,'first_with_stock'); eq(f.positions[1].x,52.5); eq(f.position,nil); eq(f.count,5)
  eq(n.notes[1],'position and to without pick: a take there and a give at to (pick="first_with_stock")')
  _,f,n=A.fix('transfer',{from={x=52.5,y=45.5},to={x=65.5,y=14.5},item='coal',direction='take'},takes)
  eq(f.pick,'first_with_stock'); eq(f.direction,nil)
  -- a give named with to elsewhere stays a refusal (which side is meant is not said)
  _,f,n=A.fix('transfer',{position={x=52.5,y=45.5},to={x=65.5,y=14.5},item='coal',direction='to_entity'},takes)
  eq(f.pick,nil)
  -- with pick, to stays pick's
  _,f,n=A.fix('transfer',{pick='first_with_stock',positions={P},item='coal',to={x=30.5,y=4.5}},takes)
  eq(n,nil)
  -- recipes {item} is prefix; craftable {item} is the recipes list
  _,f=A.fix('recipes',{item='pentapod-egg'},takes); eq(f.prefix,'pentapod-egg')
  _,f=A.fix('observe',{scope='craftable',item='roboport'},takes); eq(f.recipes[1],'roboport'); eq(#f.recipes,1)
end
-- round1820a item 3: build entries name what to place by name (Opus 00:42, Haiku 00:52, Grok 00:25, Gemini 23:10).
do
  local A=dofile('mod/agent-harness_0.1.0/aliases.lua')({})
  local takes=function(action,k) return action=='build' and ({builds=true,item=true,entity=true,position=true,direction=true,dry_run=true})[k]==true end
  local list={{name='electric-mining-drill',position={x=1,y=2}},{item='pipe',position={x=3,y=2}}}
  local _,f,n=A.fix('build',{builds=list},takes)
  eq(f.builds[1].item,'electric-mining-drill'); eq(f.builds[1].name,nil); eq(f.builds[2].item,'pipe'); eq(n.notes[1],'name is item')
  eq(list[1].name,'electric-mining-drill','the caller\'s list is left as it was')
  _,f,n=A.fix('build',{name='gun-turret',position={x=149,y=-26}},takes)
  eq(f.item,'gun-turret'); eq(f.name,nil); eq(n.notes[1],'name is item')
  _,f,n=A.fix('build',{entity='passive-provider-chest',position={x=-72.5,y=87.5}},takes)
  eq(f.item,'passive-provider-chest'); eq(f.entity,nil); eq(n.notes[1],"entity is item (entity names a rail planner's rail, with item)")
  -- A rail planner's entity stays: it names which rail.
  _,f,n=A.fix('build',{item='rail',entity='curved-rail-a',position={x=0,y=0}},takes); eq(n,nil)
  _,f,n=A.fix('build',{item='rail',builds={{entity='half-diagonal-rail',position={x=0,y=0}}}},takes); eq(n,nil)
  -- items as a list of entries is builds (Grok 00:25).
  _,f,n=A.fix('build',{items={{item='iron-chest',position={x=1,y=1}}}},takes)
  eq(f.builds[1].item,'iron-chest'); eq(f.items,nil); eq(n.notes[1],'items is builds')
end
sol('stop')
-- A scoped read (fh sends scan as observe {scope}): the view's own names.
r=sol('observe',{scope='scan',names='wooden-chest',radius=5})
eq(r.corrected,'observe {"name":"wooden-chest","radius":5,"scope":"scan"} (names is name)')
-- A valid argument is never touched; an unknown one still fails with the list.
eq(sol('observe',{scope='scan',name='wooden-chest',radius=5}).corrected,nil)
fails(function() sol('move_to',{position={x=3,y=3},bogus=1}) end,'unknown argument bogus for move_to')
-- A corrected call that still fails says how it ran.
fails(function() sol('craft',{item='iron-gear-wheel'}) end,'[ran as craft {"recipe":"iron-gear-wheel"}: item is recipe]')
-- board with an id and a note is board_update.
local id=sol('board_post',{kind='task',title='wire the north roboports'}).item.id
r=sol('board',{id=id,note='poles on the way'})
eq(r.item.notes[1].text,'poles on the way'); eq(r.corrected,'board_update {"id":'..id..',"note":"poles on the way"} (board with an id and a change is board_update)')
-- scan fields as one string, as describe's example reads.
r=sol('scan',{radius=8,fields='status|hp'})
eq(r.corrected,nil); assert(r.entities,'scan ran')
-- position and positions (Muse, shift08): one {x,y} as positions, a list as position, position where only positions
-- is taken, or both at once run as one list, with a note in corrected.
r=sol('inspect',{positions={x=3.5,y=3.5}})
eq(r.corrected,'inspect {"positions":[{"x":3.5,"y":3.5}]} (positions is a list: [{x,y}])'); eq(r.count,1)
r=sol('inspect',{position={x=3.5,y=3.5},positions={{x=10,y=10}}})
eq(r.corrected,'inspect {"positions":[{"x":3.5,"y":3.5},{"x":10,"y":10}]} (position and positions are one list (position first))')
eq(r.entities[1].name,'wooden-chest'); eq(r.entities[2].name,'roboport')
r=sol('transfer',{position={{x=3.5,y=3.5}},direction='to_player',item='copper-plate',count=1})
eq(r.corrected,'transfer {"count":1,"direction":"to_player","item":"copper-plate","positions":[{"x":3.5,"y":3.5}]} (position with a list is positions)')
assert(r.entities,'ran as a batch')
r=sol('collect',{position={3.5,3.5},item='copper-plate'})
eq(r.corrected,'collect {"item":"copper-plate","positions":[[3.5,3.5]]} (position is positions (a list))')
-- feed takes position itself since d15 (Muse 06:28: the radius's centre, or alone the machine there): no correction.
r=sol('feed',{position={x=3.5,y=3.5}})
eq(r.corrected,nil)
-- A plain position where position is taken, and anything with radius, are left alone.
eq(sol('inspect',{position={x=3.5,y=3.5}}).corrected,nil)
fails(function() sol('collect',{radius=5,position={x=1,y=1},item='copper-plate'}) end,'unknown argument position for collect')
-- Queue steps are corrected the same way; the reply lists them.
r=sol('queue_submit',{start=false,steps={{action='collect',args={position={x=3.5,y=3.5},item='copper-plate'}},{action='wait_ticks',args={ticks=60}}}})
eq(r.corrected[1],'step 1: collect {"item":"copper-plate","positions":[{"x":3.5,"y":3.5}]} (position is positions (a list))'); eq(#r.corrected,1)
local queued=sol('queue_status').pending[1].args
eq(queued.positions[1].x,3.5); eq(queued.position,nil)
sol('queue_cancel',{})
-- transfer's direction named any way (Haiku, shift09): a direction word for the same move, from_entity=true, or the
-- target given as to_entity / from_entity; a flag against the given direction still fails.
r=sol('transfer',{position={x=3.5,y=3.5},direction='from_entity',item='copper-plate',count=1})
eq(r.corrected,'transfer {"count":1,"direction":"to_player","item":"copper-plate","position":{"x":3.5,"y":3.5}} (direction from_entity is to_player)')
r=sol('transfer',{position={x=3.5,y=3.5},from_entity=true,item='copper-plate',count=1})
eq(r.corrected,'transfer {"count":1,"direction":"to_player","item":"copper-plate","position":{"x":3.5,"y":3.5}} (from_entity=true is direction="to_player")')
r=sol('transfer',{from_entity={x=3.5,y=3.5},item='copper-plate',count=1})
eq(r.corrected,'transfer {"count":1,"direction":"to_player","item":"copper-plate","position":{"x":3.5,"y":3.5}} (from_entity={x,y} is direction="to_player" position=...)')
fails(function() sol('transfer',{position={x=3.5,y=3.5},direction='to_entity',to_player=true,item='copper-plate'}) end,'unknown argument to_player for transfer')
r=sol('queue_submit',{start=false,steps={{action='transfer',args={to_entity={x=3.5,y=3.5},item='copper-plate'}}}})
eq(r.corrected[1],'step 1: transfer {"direction":"to_entity","item":"copper-plate","position":{"x":3.5,"y":3.5}} (to_entity={x,y} is direction="to_entity" position=...)')
sol('queue_cancel',{})

-- Fix 6: an empty take says why; the third identical one in 7 min says so.
r=sol('transfer',{position={x=3.5,y=3.5},direction='to_player',item='iron-plate'})
eq(r.transferred,0); eq(r.nothing_moved,'wooden-chest at (3.5,3.5) holds no iron-plate in chest; it holds copper-plate*15')
eq(r.repeated,nil); sol('transfer',{position={x=3.5,y=3.5},direction='to_player',item='iron-plate'})
eq(sol('transfer',{position={x=3.5,y=3.5},direction='to_player',item='iron-plate'}).repeated,
  'transfer 3 times in 7 min with nothing moved (same target and item)')
-- Another item is another move.
eq(sol('transfer',{position={x=3.5,y=3.5},direction='to_player',item='iron-gear-wheel'}).repeated,nil)
-- An electric machine no pole reaches is unpowered, whatever its status reads.
eq(runtime.unpowered(port),'unpowered: no pole reaches it; nearest pole medium-electric-pole at (17,10), 7 tiles')
body.position={x=8,y=8}
r=sol('inspect',{position={x=10,y=10}})
-- inspect pairs the engine's status number with its name (Muse, shift10); unpowered is said in power.
eq(r.status,2); eq(r.power,runtime.unpowered(port))
eq(r.status_name,'normal')
port.electric_network_id=4
eq(runtime.unpowered(port),nil); eq(sol('inspect',{position={x=10,y=10}}).power,nil)
eq(runtime.unpowered(pole),nil,'a pole is no machine')
body.position={x=5,y=5}

-- Fix 9: the plain board read is about 3 KB; full=true lists as before.
for i=1,30 do
  local n=sol('board_post',{kind='task',title=string.rep('t',100)..i}).item.id
  for k=1,3 do sol('board_update',{id=n,note=string.rep('n',190)..k}) end
end
r=sol('board',{})
local size=#runtime.aliases.encode(r)
assert(size<=3600,'brief board read is '..size..' bytes')
assert(r.more and r.more:find('more: board {full=true}',1,true),tostring(r.more))
eq(r.matched,31); eq(#r.items[1].notes,1); eq(r.items[1].note_count,3)
local full=sol('board',{full=true})
eq(#full.items,30); eq(#full.items[1].notes,2); eq(full.more,nil)
-- tells: by default the last 30 received, at every read (Muse, shift10: the
-- read since the last one lost tells missed in the team block).
luna('tell',{to='sol',text='one'}); luna('tell',{to='sol',text='two'})
r=sol('tells')
eq(#r.tells,2)
eq(#sol('tells').tells,2,'listed again')
luna('tell',{to='sol',text='three'})
r=sol('tells'); eq(#r.tells,3); eq(r.tells[3].text,'three')
eq(#sol('tells',{since=0}).tells,3,'since=0: all of them')
eq(#sol('tells',{since=r.tells[2].seq}).tells,1,'since: after that seq')
-- Queue writes answer briefly: the next steps by id, the count, the note.
local steps={}
for i=1,7 do steps[i]={action='wait_ticks',args={ticks=600},label='w'..i} end
r=sol('queue_submit',{steps=steps,start=false})
eq(#r.pending,5); eq(r.pending_count,7); assert(r.pending[1]:find('wait_ticks [w1]',1,true),r.pending[1])
eq(r.note,'queue_status: the active step, the next one and the last 3 in full (history, pending: a count or "all")')
eq(#sol('queue_status').pending,1); eq(sol('queue_status').pending_count,7); eq(#sol('queue_status',{pending='all'}).pending,7)
eq(sol('queue_cancel').pending_count,0)
-- round1650d near-misses (Opus, Sonnet, Sol, Astra, Gemini): the form each meant, in corrected.
do
  local A=dofile('mod/agent-harness_0.1.0/aliases.lua')({})
  local T={observe={position=true,radius=true,scope=true},tell={to=true,text=true},inspect={position=true,name=true,area=true},
    recipes={prefix=true},stock={item=true},scan={name=true,position=true,radius=true,fields=true,area=true},
    wait_until={['until']=true,item=true,at_least=true,below=true,count=true},circuit_set={position=true,settings=true},
    status={brief=true,alerts=true,inventory=true,machines=true}}
  local takes=function(action,k) return (T[action] or {})[k]==true end
  local _,f,n=A.fix('observe',{center={x=410,y=-270},radius=25},takes)
  eq(f.position.x,410); eq(f.center,nil); eq(n.notes[1],'center is position')
  _,f,n=A.fix('observe',{area={left_top={x=0,y=0},right_bottom={x=30,y=20}}},takes)
  eq(f.position.x,15); eq(f.position.y,10); eq(f.radius,15); eq(f.area,nil); eq(n.notes[1],'area is position (its centre) and radius (half its longer side)')
  _,f=A.fix('observe',{scope='scan',area={left_top={x=0,y=0},right_bottom={x=30,y=20}}},takes)
  eq(f.position,nil,'scan takes area')
  _,f,n=A.fix('tell',{to='astra',message='Understood'},takes)
  eq(f.text,'Understood'); eq(f.message,nil); eq(n.notes[1],'message is text')
  _,f=A.fix('inspect',{area={left_top={x=0,y=0},right_bottom={x=9,y=9}},names={'chemical-plant'}},takes)
  eq(f.name,'chemical-plant')
  _,f=A.fix('recipes',{names={'lightning-rod'}},takes); eq(f.prefix,'lightning-rod')
  _,f=A.fix('stock',{names={'heat-exchanger'}},takes); eq(f.item,'heat-exchanger')
  _,f=A.fix('observe',{scope='scan',entities={'chemical-plant'},position={x=1,y=2}},takes); eq(f.name,'chemical-plant')
  _,f,n=A.fix('wait_until',{['until']='item_count',item='nutrients',count=250},takes)
  eq(f.at_least,250); eq(f.count,nil); eq(n.notes[1],'count is at_least for item_count')
  _,f=A.fix('wait_until',{['until']='item_count',item='nutrients',count=250,below=10},takes); eq(f.count,250,'below given: left alone')
  _,f,n=A.fix('circuit_set',{position={x=1,y=2},settings={circuit_mode_of_operation='set_requests'}},takes)
  eq(f.settings.circuit_exclusive_mode_of_operation,'set_requests'); eq(f.settings.circuit_mode_of_operation,nil)
  eq(n.notes[1],'settings.circuit_mode_of_operation is circuit_exclusive_mode_of_operation')
  _,f,n=A.fix('status',{inventory=true,machines=false,alerts=false},takes)
  eq(f.brief,true); eq(n.notes[1],'alerts goes with brief: brief=true')
  _,f,n=A.fix('status',{brief=true,alerts=true},takes); eq(n,nil)
end
print('minds: ok')
