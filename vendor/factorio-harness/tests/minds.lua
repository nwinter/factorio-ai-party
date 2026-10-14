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
  build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
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
r=sol('feed',{position={x=3.5,y=3.5}})
eq(r.corrected,'feed {"positions":[{"x":3.5,"y":3.5}]} (position is positions (a list))')
-- A plain position where position is taken, and anything with radius, are left alone.
eq(sol('inspect',{position={x=3.5,y=3.5}}).corrected,nil)
fails(function() sol('collect',{radius=5,position={x=1,y=1},item='copper-plate'}) end,'unknown argument position for collect')
-- Queue steps are corrected the same way; the reply lists them.
r=sol('queue_submit',{start=false,steps={{action='collect',args={position={x=3.5,y=3.5},item='copper-plate'}},{action='wait_ticks',args={ticks=60}}}})
eq(r.corrected[1],'step 1: collect {"item":"copper-plate","positions":[{"x":3.5,"y":3.5}]} (position is positions (a list))'); eq(#r.corrected,1)
local queued=sol('queue_status').pending[1].args
eq(queued.positions[1].x,3.5); eq(queued.position,nil)
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
eq(r.status_name,'unpowered'); eq(r.power,runtime.unpowered(port))
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
-- tells: by default, the ones since your last read.
luna('tell',{to='sol',text='one'}); luna('tell',{to='sol',text='two'})
r=sol('tells')
eq(#r.tells,2)
eq(#sol('tells').tells,0,'nothing new')
luna('tell',{to='sol',text='three'})
r=sol('tells'); eq(#r.tells,1); eq(r.tells[1].text,'three')
eq(#sol('tells',{since=0}).tells,3,'since=0: all of them')
-- Queue writes answer briefly: the next steps by id, the count, the note.
local steps={}
for i=1,7 do steps[i]={action='wait_ticks',args={ticks=600},label='w'..i} end
r=sol('queue_submit',{steps=steps,start=false})
eq(#r.pending,5); eq(r.pending_count,7); assert(r.pending[1]:find('wait_ticks [w1]',1,true),r.pending[1])
eq(r.note,'queue_status shows every step in full')
eq(#sol('queue_status').pending,7)
eq(sol('queue_cancel').pending_count,0)
print('minds: ok')
