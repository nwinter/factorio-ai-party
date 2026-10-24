-- d24 batch154 (the batch149 whole-harness review's sections 4 and 5). Run from the harness root: lua tests/d24_batch154.lua
-- Bug 3: build's blockers leave out what the collision test does not meet (flying robots). Bug 4 and improvement 5:
-- item "name@quality" read once (argforms.lua), or refused naming quality; transfer names an unknown item. Bug 7 and
-- improvement 6: the blueprint slot rule; inspect {name} that left out what stands there; a surface given a
-- platform's name; delivery watch, board and reminder ids dropped by retention. Improvement 4: platform where
-- another argument takes it (or refused naming what does); tells' after, unread, seq and from.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
prototypes={item={['submachine-gun']={type='gun',attack_parameters={ammo_categories={'bullet'},range=18}},
  ['rocket-launcher']={type='gun',attack_parameters={ammo_categories={'rocket'},range=36}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}},
  ['iron-plate']={type='item'}}}
local drawn={}
rendering={draw_text=function() local obj={valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,
  is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},selected_gun_index=1}
  c.insert=function(s) return s.count end
  c.get_item_count=function() return 0 end
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
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    if req.bot then pcall(runtime.stop_player,runtime.bots.index_of(req.bot)) end
    error(result,0)
  end
  return result
end
as=function(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local grok=as('grok')
runtime.operator.bot_create('grok')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
prototypes.quality={normal={name='normal',level=0},uncommon={name='uncommon',level=1},rare={name='rare',level=2},epic={name='epic',level=3},
  legendary={name='legendary',level=5},['quality-unknown']={name='quality-unknown',level=0}}
prototypes.item['iron-chest']={type='item'}
prototypes.fluid={water={name='water'}}
force.platforms={{valid=true,name='Asterion',index=16,surface={valid=true,name='platform-16'}}}

-- Bug 3 (Sonnet 14:44Z: "placement blocked by logistic-robot (-21.76,-21.20), logistic-robot (-21.80,-21.16), boompuff
-- (-20.56,-20.88)"): two flying robots over the footprint are no blocker; the boompuff is, named alone.
do
  local building={layers={item=true,meltable=true,object=true,player=true,water_tile=true,is_object=true,is_lower_object=true}}
  local proto={name='assembling-machine-1',type='assembling-machine',collision_box={left_top={x=-1.2,y=-1.2},right_bottom={x=1.2,y=1.2}},collision_mask=building}
  local robot={collision_mask={layers={}}}
  local tree={collision_mask={layers={item=true,object=true,player=true,water_tile=true}}}
  local found={{valid=true,name='logistic-robot',type='logistic-robot',position={x=-21.76,y=-21.2},prototype=robot},
    {valid=true,name='logistic-robot',type='logistic-robot',position={x=-21.8,y=-21.16},prototype=robot},
    {valid=true,name='boompuff',type='tree',position={x=-20.56,y=-20.88},prototype=tree}}
  local s={name='gleba',find_entities_filtered=function(f) if f.area then return found end return {} end,find_tiles_filtered=function() return {} end}
  local text=runtime.placement_error({surface=s,force=force},proto,{x=-21.5,y=-21.5},0,false)
  has(text,'placement blocked by boompuff (-20.56,-20.88); it needs the tree mined first')
  assert(not text:find('robot',1,true),text)
  -- robots alone over it: nothing in the way by the collision test
  found={found[1],found[2]}
  text=runtime.placement_error({surface=s,force=force},proto,{x=-21.5,y=-21.5},0,false)
  assert(not text:find('robot',1,true),text)
end

-- Bug 4, improvement 5: item "name@quality" is item and quality where quality is taken (transfer, build entries ...),
-- refused naming quality where it is not (where_is); a quality that is none, and two qualities that differ, refused.
local check=runtime.check_args
do
  local a={item='iron-plate@uncommon',position={x=1,y=1},direction='to_player'}
  check('transfer',a); eq(a.item,'iron-plate'); eq(a.quality,'uncommon')
  fails(function() check('where_is',{item='iron-plate@uncommon'}) end,'item iron-plate@uncommon: where_is takes no quality (no quality argument, and no name@quality): item is the name alone, iron-plate')
  fails(function() check('transfer',{item='iron-plate@shiny',position={x=1,y=1}}) end,'no quality named shiny (qualities: normal, uncommon, rare, epic, legendary)')
  fails(function() check('transfer',{item='iron-plate@rare',quality='uncommon',position={x=1,y=1}}) end,'item iron-plate@rare says quality rare, and quality says uncommon')
  local b={builds={{item='iron-chest@rare',position={x=1,y=1}}}}
  check('build',b); eq(b.builds[1].item,'iron-chest'); eq(b.builds[1].quality,'rare')
  local r={set={{item='iron-plate@epic',min=10}}}
  check('requests',r); eq(r.set[1].item,'iron-plate'); eq(r.set[1].quality,'epic')
  -- transfer: the engine's "Unknown item name: X" said as the harness's (other errors as they were)
  local F=runtime.argforms
  eq(F.unknown_item({item='iron-plat'},'...: Unknown item name: iron-plat'),'item iron-plat: no item named iron-plat')
  has(F.unknown_item({item='water'},'Unknown item name: water'),'no item named water (a fluid')
  eq(F.unknown_item({item='coal'},'no coal in inventory'),'no coal in inventory')
end

-- Improvement 4: platform given where the action takes it under another argument runs that way (corrected); where
-- nothing takes it, the refusal names what does. tells: after is since; unread, seq, from refused naming since.
do
  local fix=function(action,args) return runtime.aliases.fix(action,args,runtime.takes) end
  local _,out,c=fix('min_payload',{platform='Asterion'}); eq(out.platforms,'Asterion'); eq(out.platform,nil); has(c.call,'min_payload')
  _,out=fix('queue_status',{platform='Asterion'}); eq(out.lane,'platform:Asterion')
  _,out=fix('supply',{platform='Asterion',item='iron-plate'}); eq(out.surface,'platform-16')
  _,out=fix('fuel_budget',{platform='Asterion'}); eq(out.surface,'platform-16')
  _,out=fix('stock',{platform='Asterion',item='iron-plate'}); eq(out.surface,'Asterion')
  -- a platform that is none: left as given, and refused naming the argument
  _,out=fix('supply',{platform='Nowhere',item='iron-plate'}); eq(out.platform,'Nowhere')
  fails(function() check('supply',{platform='Nowhere',item='iron-plate'}) end,'unknown argument platform for supply: supply takes no platform argument; it takes the platform as surface (the platform\'s surface name, platform-N, as platforms lists it): no platform of ours is named Nowhere')
  fails(function() check('min_payload',{platform='Asterion'}) end,'it takes the platform as platforms (a platform name, or a list of names)')
  fails(function() check('freight_audit',{platform='Asterion',item='iron-plate'}) end,'freight_audit takes no platform argument: freight_audit reads one item on every planet and every platform at once')
  fails(function() check('pods',{platform='Asterion'}) end,'delivery_watch counts the pods a platform sends down (from: the platform)')
  fails(function() check('delivery_watch',{platform='Asterion',item='calcite',count=10}) end,'delivery_watch takes a platform as from')
  fails(function() check('build',{platform='Asterion',item='iron-chest',position={x=1,y=1}}) end,'on a platform, place_ghosts, paste and blueprint_place take platform')
  _,out=fix('tells',{after=12}); eq(out.since,12); eq(out.after,nil)
  fails(function() check('tells',{unread=true}) end,'unknown argument unread for tells: tells takes since: without since it lists the last 30 tells you received')
  fails(function() check('tells',{seq=4}) end,'since=N lists the tells after seq N')
  fails(function() check('tells',{from='sol'}) end,'tells has no filter by sender')
  -- a direct call runs corrected
  local r=grok('tells',{after=0})
  has(r.corrected,'after is since')
end

-- Bug 7: the blueprint slot's rule (blueprint_capture, save, import and place read it alike).
fails(function() grok('blueprint_import',{slot='Sol test slot',blueprint='0eNq'}) end,'slot "Sol test slot": a blueprint slot is 1..64 letters, digits, _ and - (no spaces); this one: " " at character 4')

-- Bug 7: inspect {name} where what stands there is another entity.
do
  local pole={valid=true,name='small-electric-pole',type='electric-pole',position={x=65.5,y=14.5},unit_number=901,force=force,surface=surface,
    prototype={selectable_in_game=true}}
  local saved=surface.find_entities_filtered
  surface.find_entities_filtered=function(f)
    if f.name or f.ghost_name or f.area then return {} end
    if f.position and (f.radius==nil or f.radius<=3) then return {pole} end
    return {}
  end
  body=runtime.lookup(runtime.bots.index_of('grok')).character
  body.position={x=64,y=14}
  fails(function() grok('inspect',{position={x=65.5,y=14.5},name='rocket-silo'}) end,
    'entity not found at (65.5,14.5): no rocket-silo there; name=rocket-silo left out what stands there: small-electric-pole (65.5,14.5) unit_number 901')
  surface.find_entities_filtered=saved
end

-- Bug 7: a surface given a platform's name: the refusal names platform (or the surface's own name).
has(runtime.surface_hint('observe',{surface='Asterion'},'no surface Asterion'),'no surface Asterion; Asterion is a platform (its surface: platform-16): observe takes it as platform="Asterion"')
has(runtime.surface_hint('rates',{surface='Asterion'},'no surface named Asterion'),'surface="platform-16" names its surface')
eq(runtime.surface_hint('observe',{surface='Nowhere'},'no surface Nowhere'),'no surface Nowhere')
has(runtime.surface_hint('observe',{surface='Asterion'},'observe with surface needs position there (your character stands on another surface)'),
  'needs position there (your character stands on another surface); Asterion is a platform (its surface: platform-16): observe takes it as platform="Asterion"')
eq(runtime.surface_hint('map',{surface='Asterion'},'map with surface needs position there'),'map with surface needs position there')

-- Bug 7, improvement 6: ids dropped by retention say when and the keep rule.
do
  -- a delivery watch ended, then dropped 10 minutes later; one cleared; one never set
  local st=storage.agent_harness.delivwatch or {}
  storage.agent_harness.delivwatch=st
  st.seq=st.seq or 0; st.list=st.list or {}; st.events=st.events or {}; st.eseq=st.eseq or 0; st.rr=st.rr or 0
  st.seq=st.seq+1
  local id=st.seq
  st.list[#st.list+1]={id=id,item='calcite',setter='luna',index=1,force='player',state='received',ended=game.tick,deadline=game.tick+36000,stages={}}
  local t0=game.tick
  advance(36000+120)
  fails(function() grok('delivery_watch',{id=id}) end,string.format('no delivery watch #%d: #%d (calcite, set by luna): it ended received at tick %d',id,id,t0))
  fails(function() grok('delivery_watch',{id=id}) end,'a watch is kept 10 minutes after it ends (received or reached), or 10 minutes past its deadline while late; clear ends it at once')
  fails(function() grok('delivery_watch',{id=id+5}) end,string.format('no delivery watch #%d: none set with that number (the last set is #%d)',id+5,id))
end
do
  -- a reminder removed by its owner
  local r=grok('reminder_add',{message='check the furnaces',due_in_ticks=600,name='furnaces'})
  local id=r.reminder and r.reminder.id or r.id
  grok('reminder_remove',{id=id})
  fails(function() grok('reminders',{id=id}) end,string.format('no reminder #%d: "furnaces" (grok\'s) removed by grok',id))
  fails(function() grok('reminder_edit',{id=id,message='x'}) end,'a reminder is kept until its owner (or the operator) removes it with reminder_remove')
  fails(function() grok('reminders',{id=id+3}) end,'none set with that number (the last set is #'..id..')')
end
do
  -- board items pruned past the cap: the first done item goes first
  local first=grok('board_post',{kind='task',title='first task'}).item.id
  grok('board_update',{id=first,status='done'})
  for i=1,300 do grok('board_post',{kind='note',title='note '..i}) end
  fails(function() grok('board',{id=first}) end,string.format('no board item #%d: pruned',first))
  fails(function() grok('board',{id=first}) end,'a done task "first task" last updated')
  fails(function() grok('board_update',{id=first,note='x'}) end,'the board keeps 300 items: past that, done and dropped items are pruned first')
  fails(function() grok('board',{id=99999}) end,'no board item #99999: none posted with that number')
end
print('d24_batch154 review fixes: ok')
