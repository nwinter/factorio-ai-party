-- Run from repository root: lua tests/d25_batch214b.lua
-- d25 batch214 QZ2 (Astra #2380: dock baseline 196's dry_run passed 9 uptime items; live, the queue enabled two sinks,
-- then uptime refused more than 8). A sweep of the limits the actions check when they run against the queue's checks
-- (runtime.lua step_lengths, step_ranges): uptime items, and the other list, text and number limits dry_run took past
-- their end, each from the action's own bound.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
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
prototypes=prototypes or {}
local function has(s,part) assert(type(s)=="string" and s:find(part,1,true),tostring(s).."\n  lacks: "..part) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,"should be refused"); return tostring(err) end
local function no_limit(fn) local ok,err=pcall(fn); assert(ok or not tostring(err):find('takes when it runs',1,true),tostring(err)) end
local function plan(steps) return function() return runtime.dispatch{action='queue_submit',args={dry_run=true,steps=steps},bot='astra'} end end
local function list(n,f) local t={} for i=1,n do t[i]=f and f(i) or ('n'..i) end return t end
local P={x=0,y=0}
-- Astra's queue: two steps that change the factory, then a watch of 9 items: refused before anything runs, the step
-- named; 8 is taken
local nine=list(9,function(i) return 'item-'..i end)
local e=refused(plan({{action='wait_ticks',args={ticks=60}},{action='wait_ticks',args={ticks=60}},{action='uptime',label='baseline',args={items=nine,seconds=600}}}))
has(e,'steps[3] (uptime, label "baseline")'); has(e,'items has 9 entries, outside 1..8, what uptime takes when it runs')
table.remove(nine)
no_limit(plan({{action='uptime',args={items=nine,seconds=600}}}))
-- the bound is the action's own: uptime.ITEMS moves the step's check and the call's
local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return {} end}
has(refused(function() U.flows_start({name='player'},{name='nauvis'},list(9)) end),'items: 1..8 items')
runtime.uptime.ITEMS=4
has(refused(function() runtime.step_length_check('uptime',{items=list(5),seconds=60}) end),'items has 5 entries, outside 1..4')
runtime.uptime.ITEMS=8
-- a read of the watch takes no items limit (it starts nothing)
runtime.step_length_check('uptime',{read=true,page=1})
print('d25_batch214b QZ2 uptime items: ok')
-- lists: one past refused, the limit taken
local lists={
  {'inspect','name',16,{area={left_top=P,right_bottom={x=8,y=8}}}},
  {'recipes','name',64},{'technologies','name',64},
  {'transfer','via',16,{},function(i) return {x=i,y=0} end},
  {'transfer','items',16,{pick=true}},{'collect','items',16,{pick=true}},
}
for _,c in ipairs(lists) do
  local action,key,hi,mode,f=c[1],c[2],c[3],c[4] or {},c[5]
  local function args(n) local a={} for k,v in pairs(mode) do a[k]=v end a[key]=list(n,f) return a end
  has(refused(function() runtime.step_length_check(action,args(hi+1)) end),key..' has '..(hi+1)..' entries, outside 1..'..hi..', what '..action..' takes when it runs')
  runtime.step_length_check(action,args(hi))
end
-- inspect's name is counted with an area or radius only (one name counts as one)
runtime.step_length_check('inspect',{name=list(17),position=P})
runtime.step_length_check('inspect',{name='iron-chest',radius=8})
-- fields: a list, or one string with | or , (the pieces counted, as the read counts them)
for _,action in ipairs({'platforms','status','inspect'}) do
  has(refused(function() runtime.step_length_check(action,{fields=list(33)}) end),'fields: 1..32 names, what '..action..' takes when it runs')
  has(refused(function() runtime.step_length_check(action,{fields=table.concat(list(33),'|')}) end),'fields: 1..32 names')
  runtime.step_length_check(action,{fields=table.concat(list(32),',')})
end
-- a transfer chain: the chests in all its steps, as the chain counts its legs
local TC=dofile('mod/agent-harness_0.1.0/transferchain.lua'){integer=function(v,d) return v or d end,position=function(q) return q end}
local steps={{take=list(20,function(i) return {x=i,y=0} end),item='coal'},{give=list(12,function(i) return {x=i,y=5} end),item='coal'},{give={x=0,y=9},item='coal'}}
eq(TC.count_legs(steps),33)
has(refused(function() runtime.step_length_check('transfer',{steps=steps}) end),'steps has 33 chests in all its steps, outside 1..32, what transfer takes when it runs')
prototypes.item=prototypes.item or {}; prototypes.item.coal=prototypes.item.coal or {name='coal'}
has(refused(function() TC.plan({steps=steps}) end),'a chain takes at most 32 chests in all')
table.remove(steps)
runtime.step_length_check('transfer',{steps=steps})
-- a sleep's until=any: its conditions, as the sleep counts them
local cond=function() return {['until']='ticks',ticks=60} end
has(refused(function() runtime.step_length_check('sleep',{seconds=60,condition={['until']='any',conditions=list(9,cond)}}) end),'until=any takes conditions: 1..8 wait_until conditions')
has(refused(function() runtime.step_length_check('sleep',{seconds=60,condition=list(9,cond)}) end),'1..8 wait_until conditions')
runtime.step_length_check('sleep',{seconds=60,condition={['until']='any',conditions=list(8,cond)}})
runtime.step_length_check('sleep',{seconds=60,condition=cond()})
eq(#runtime.waits.members(list(8,cond)),8)
print('d25_batch214b QZ2 lists: ok')
-- numbers: past the end refused, the ends taken (each handler's bound)
local ranges={
  {'scan','limit',1,1024},{'scan','radius',1,64},{'scan','page',1,4},{'nearest','limit',1,64},{'nearest','radius',1,128},
  {'inspect','radius',1,64},{'stock','limit',1,64},{'stock','radius',1,1024},{'map','radius',32,1024},{'map','limit',1,256},
  {'recipes','limit',1,256},{'technologies','limit',1,256},{'shipment','limit',1,128,{ledger=true}},{'damage_log','radius',1,64},
  {'grid','radius',1,64},{'artillery','radius',1,4096},{'alerts_digest','limit',1,64},{'danger','radius',8,128},{'danger','quiet_s',10,3600},
  {'power','radius',1,64},{'power','radius',8,512,{fragile=true}},{'power','limit',1,256},{'belt_upgrade','tiles',1,512},
  {'blueprint_list','limit',1,256},{'blueprint_list','from',1,256},{'sleep','seconds',1,900},{'flight_watch','minutes',1,480},
  {'craft','count',1,1000},{'construct','ticks',1,216000},{'build_path','ticks',1,36000},{'clear_cliffs','ticks',1,36000},
  {'assembler_batch','count',1,10000},{'heat_budget','add_pipes',0,5000},{'outpost','radius',4,128},{'drill_sites','limit',1,16},
  {'drill_sites','radius',2,24},{'supply','radius',1,512},{'trace','radius',1,512},{'spider_kite','radius',8,64},
  {'spider_kite','ticks',1,36000},{'spider_kite','ammo_below',1,100000},{'delivery_watch','count',1,1000000,{item='coal'}},
  {'belt_route','avoid_enemies',0,32},{'move_to','avoid_enemies',0,32},{'recover','avoid_enemies',0,32},{'refuel','from_radius',1,128},
  {'where_is','limit',1,50},{'vehicle','ticks',1,36000,{drive=P}},{'vehicle','avoid_enemies',0,32,{drive=P}},
}
for _,c in ipairs(ranges) do
  local action,key,lo,hi,mode=c[1],c[2],c[3],c[4],c[5] or {}
  local function args(v) local a={} for k,x in pairs(mode) do a[k]=x end a[key]=v return a end
  has(refused(function() runtime.step_range_check(action,args(hi+1)) end),key..' '..(hi+1)..' is outside '..lo..'..'..hi)
  has(refused(function() runtime.step_range_check(action,args(lo-1)) end),key..' '..(lo-1)..' is outside '..lo..'..'..hi)
  runtime.step_range_check(action,args(lo)); runtime.step_range_check(action,args(hi))
end
-- true, false or a {distance} keep going to the action
runtime.step_range_check('move_to',{avoid_enemies=true}); runtime.step_range_check('move_to',{avoid_enemies={distance=40}})
-- a mode's own: power's radius 1..64, with fragile 8..512; shipment's limit with ledger; vehicle's with drive
runtime.step_range_check('power',{radius=200,fragile=true}); runtime.step_range_check('shipment',{limit=500})
runtime.step_range_check('vehicle',{ticks=50000})
-- the constants move both: the flight watch's minutes, the sleep's ticks
runtime.flightwatch.MAX_MIN=60
has(refused(function() runtime.step_range_check('flight_watch',{minutes=61}) end),'minutes 61 is outside 1..60')
runtime.flightwatch.MAX_MIN=480
-- through queue_submit: the step named
has(refused(function() return runtime.dispatch{action='queue_submit',args={dry_run=true,lane='remote',steps={{action='wait_ticks',args={ticks=60}},{action='scan',label='ore',args={limit=2000}}}},bot='astra'} end),'steps[2] (scan, label "ore"): args: limit 2000 is outside 1..1024 (a whole number), what scan takes when it runs')
print('d25_batch214b QZ2 numbers: ok ('..#ranges..' ranges, '..#lists..' lists)')
