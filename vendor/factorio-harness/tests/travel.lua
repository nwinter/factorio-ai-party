-- Run from repository root: lua tests/travel.lua
-- Bot travel (Space Age) against a fake engine: a bot boards a rocket (armor
-- and guns kept, body removed), follows the rocket's cargo pod up, sits
-- aboard with remote view only, drops in a hub cargo pod and gets its body
-- back where the pod comes down; it respawns on the planet it last stood on.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={}}
defines={inventory={character_main=1,character_guns=3,character_ammo=4,character_armor=5},cargo_destination={orbit=1,surface=4},
  controllers={character=1,spectator=2,remote=27}}
remote={interfaces={}}
local function slot()
  local s={valid_for_read=false,count=0}
  s.transfer_stack=function(o)
    if s.valid_for_read or not o.valid_for_read then return false end
    s.name,s.count,s.grid,s.valid_for_read=o.name,o.count,o.grid,true
    o.clear(); return true
  end
  s.clear=function() s.name=nil; s.count=0; s.grid=nil; s.valid_for_read=false end
  return s
end
local function inventory(n)
  local inv={valid=true}
  for i=1,n do inv[i]=slot() end
  inv.destroy=function() inv.valid=false end
  return inv
end
local kits={}
local charts=0
local surfaces={}
local function surface(name,planet)
  local s={name=name,valid=true,planet=planet and {name=name} or nil,pads={}}
  s.find_non_colliding_position=function(_,pos) return {x=pos.x,y=pos.y} end
  s.find_entities_filtered=function(f) if f.type=='cargo-landing-pad' then return s.pads end return {} end
  s.create_entity=function(args)
    assert(args.name=='character')
    local c={valid=true,name='character',type='character',surface=s,position=args.position,force=args.force,crafting_queue_size=0,items={}}
    local invs={[1]=inventory(10),[3]=inventory(3),[4]=inventory(3),[5]=inventory(1)}
    c.invs=invs
    c.get_inventory=function(i) return invs[i] end
    c.insert=function(st) c.items[st.name]=(c.items[st.name] or 0)+st.count; return st.count end
    c.cursor_stack={valid_for_read=false}
    c.destroy=function() c.valid=false end
    return c
  end
  surfaces[name]=s
  return s
end
local nauvis=surface('nauvis',true)
local platform_surface=surface('platform-1',false)
local hub={valid=true,position={x=0.5,y=0.5}}
local platform={valid=true,name='alpha',surface=platform_surface,hub=hub,space_location={name='nauvis',type='planet'}}
local force={name='player',platforms={platform},chart=function() charts=charts+1 end,get_spawn_position=function() return {x=0,y=0} end}
local planets={nauvis={surface=nauvis},vulcanus={create_surface=function() local s=surface('vulcanus',true); return s end}}
game={tick=0,forces={player=force},planets=planets,players={},
  get_surface=function(n) return surfaces[n] end,
  create_inventory=function(n) local inv=inventory(n); kits[#kits+1]=inv; return inv end}
local stopped={}
-- (the runtime's read-only list, as M.reads; a part of it)
local READS={scan=true,science=true,supply=true,observe=true,inspect=true,status=true,inventory=true,craftable=true,networks=true}
local bots=dofile('mod/agent-harness_0.1.0/bots.lua'){state=function() return storage.agent_harness end,read_only=function(a) return READS[a]==true end,
  stop=function(index,outcome) stopped[#stopped+1]=outcome end}
local cameras=dofile('mod/agent-harness_0.1.0/cameras.lua'){state=function() return storage.agent_harness end,
  bot=function(name) return bots.named(name) end,controlled=function() return false end}
local function advance(n) for _=1,n do game.tick=game.tick+1; bots.tick(game.tick) end end

bots.create('astra')
local b=bots.named('astra')
eq(b.surface,'nauvis'); eq(b.planet,'nauvis')
local c=b.character
-- Worn armor (with its equipment grid) and a gun ride along.
local armor=c.invs[5][1]; armor.valid_for_read=true; armor.name='modular-armor'; armor.count=1; armor.grid='grid-1'
local gun=c.invs[3][2]; gun.valid_for_read=true; gun.name='pistol'; gun.count=1
-- Hand crafting in progress or a held stack would be lost with the body.
c.crafting_queue_size=2
fails(function() bots.can_board(b) end,'finish or cancel hand crafting')
c.crafting_queue_size=0
c.cursor_stack={valid_for_read=true}
fails(function() bots.can_board(b) end,'held stack')
c.cursor_stack={valid_for_read=false}

-- Boarding: the body goes, armor and gun wait in the kit, the bot rides the pod.
local pod={valid=true,position={x=10,y=10},surface=nauvis}
game.tick=100
bots.board(b,platform,pod)
eq(c.valid,false); eq(b.character,nil); eq(b.travel.state,'ascending'); eq(b.trips,1)
eq(stopped[#stopped],'boarded')
eq(kits[1][1].name,'modular-armor'); eq(kits[1][1].grid,'grid-1'); eq(kits[1][3].name,'pistol')
local st=bots.status(b.index,{})
eq(st.travel.state,'ascending'); eq(st.travel.from,'nauvis'); eq(st.platform,'alpha'); eq(st.surface,'nauvis')
eq(bots.carrier(b),pod,'the name tag rides the pod')
fails(function() bots.actor(b.index) end,'riding a cargo pod (ascending since tick 100)')
fails(function() bots.check_action(b.index,'platforms',{}) end,'riding a cargo pod')
bots.check_action(b.index,'status',{})
-- Not a death: no respawn timer while it rides.
advance(700); eq(b.dead_until_tick,nil); eq(b.deaths,nil)
-- The pod reaches the platform's surface; cameras follow it there.
pod.surface=platform_surface; pod.position={x=0,y=-3}
advance(1); eq(b.surface,'platform-1'); eq(b.position.y,-3)
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,surface=nauvis,position={x=0,y=0},show_on_map=false,game_view_settings={}}
director.teleport=function(pos,surf) director.position={x=pos.x,y=pos.y}; if surf then director.surface=surf end; return true end
director.set_controller=function() end
game.get_player=function(i) if i==2 or i=='pog-director' then return director end end
game.connected_players={director}
cameras.set{player=2,follow='astra'}
eq(director.surface,platform_surface,'the camera jumps to the platform')
eq(cameras.describe(2).surface,'platform-1')
-- Delivered: aboard, at the hub, remote view only.
pod.valid=false
advance(1)
eq(b.travel.state,'ascending','a ride lasts at least 20 s, whatever the pod entity does')
advance(100+1200-game.tick)
eq(b.travel.state,'aboard'); eq(b.surface,'platform-1'); eq(b.position.x,0.5)
st=bots.status(b.index,{})
eq(st.travel.state,'aboard'); eq(st.platform,'alpha'); eq(st.surface,'platform-1')
eq(bots.carrier(b),hub,'aboard, the name tag rides the hub')
local proxy=bots.actor(b.index)
eq(proxy.surface,platform_surface); eq(proxy.character,nil); eq(proxy.force,force)
fails(function() return proxy.get_main_inventory() end,'aboard platform alpha with no body')
for _,ok in ipairs({{'platforms',{}},{'platform_schedule',{platform='alpha'}},{'land',{}},{'research',{}},{'requests',{platform='alpha'}},
  {'place_ghosts',{platform='alpha'}},{'observe',{scope='platforms'}},{'chat',{}},{'platform_rearm',{platform='alpha',ammo_below=10,target_count=20}}}) do bots.check_action(b.index,ok[1],ok[2]) end
for _,no in ipairs({{'move_to',{}},{'craft',{}},{'requests',{}},{'place_ghosts',{}},{'platform_rearm',{ammo_below=10,target_count=20}},{'build',{}},{'inventory',{}},{'craftable',{}},
  {'wait_until',{['until']='crafting_done'}},{'wait_until',{['until']='item_count',item='coal',at_least=5}},{'collect',{}}}) do
  fails(function() bots.check_action(b.index,no[1],no[2]) end,'remote view only')
end
-- Astra, 18:16: the team's calls, every read, scan with platform or surface, and waits needing no body work aboard.
for _,ok in ipairs({{'tell',{to='sol',text='x'}},{'operator',{text='x'}},{'board',{}},{'board_post',{}},{'votes',{}},
  {'science',{}},{'supply',{item='coal'}},{'scan',{platform='alpha'}},{'scan',{surface='nauvis'}},{'scan',{}},{'observe',{scope='scan'}},
  {'networks',{}},{'inspect',{surface='nauvis',position={x=0,y=0}}},
  {'wait_until',{['until']='platform_arrived',platform='alpha'}},{'wait_until',{['until']='platform_left',platform='alpha'}},
  {'wait_until',{['until']='item_count',item='coal',at_least=5,platform='alpha'}},
  {'wait_until',{['until']='researched'}},{'wait_until',{['until']='item_count',item='coal',at_least=5,positions={{x=0,y=0}}}},
  {'dry_run',{action='scan',args={}}}}) do bots.check_action(b.index,ok[1],ok[2]) end
-- (d23 batch120 CC2, Sol #1986) chat_ack, and flight_watch reading, listing or clearing a watch; a new watch is refused.
for _,ok in ipairs({{'chat_ack',{seq='all'}},{'flight_watch',{id=3}},{'flight_watch',{id=3,clear=true}},{'flight_watch',{}}}) do bots.check_action(b.index,ok[1],ok[2]) end
fails(function() bots.check_action(b.index,'flight_watch',{platform='alpha'}) end,'remote view only')
-- Sol, 23:13: every remote-view call with platform= or surface= works aboard (place_ghosts with surface=nauvis and its
-- dry run were refused), as runtime.lua wraps them; without either, it is refused.
for _,name in ipairs(bots.PLATFORM_ACTIONS) do bots.check_action(b.index,name,{platform='alpha'}) end
for _,name in ipairs(bots.SURFACE_ACTIONS) do bots.check_action(b.index,name,{surface='nauvis',position={x=0,y=0}}) end
for _,ok in ipairs({{'place_ghosts',{surface='nauvis'}},{'dry_run',{action='place_ghosts',args={surface='nauvis'}}},{'deconstruct',{surface='nauvis'}},
  {'cancel_deconstruction',{surface='nauvis'}},{'configure',{surface='nauvis'}},{'circuit_set',{surface='nauvis'}},{'trace',{surface='nauvis',item='coal'}},
  -- Sol, 23:20: modules into a lab on Nauvis from Sunward (an item request: robots bring them).
  {'configure',{surface='nauvis',positions={{x=37.5,y=44.5}},modules={'productivity-module','productivity-module'}}}}) do
  bots.check_action(b.index,ok[1],ok[2])
end
for _,no in ipairs({{'deconstruct',{}},{'circuit_set',{}},{'place_ghosts',{}}}) do
  fails(function() bots.check_action(b.index,no[1],no[2]) end,'remote view only')
end
bots.check_action(b.index,'configure',{}) -- the aboard surface's GUI, no body inventory
-- The refusal names what works, from the same lists.
local ok,err=pcall(bots.check_action,b.index,'move_to',{})
assert(not ok and tostring(err):find('every read',1,true) and tostring(err):find('tell, chat, chat_ack, say, operator, board',1,true)
  and tostring(err):find('wait_until on platform_arrived, platform_left',1,true),tostring(err))
assert(tostring(err):find('by remote view with platform=NAME: '..table.concat(bots.PLATFORM_ACTIONS,', '),1,true),tostring(err))
assert(tostring(err):find('with surface=NAME (a planet): '..table.concat(bots.SURFACE_ACTIONS,', '),1,true),tostring(err))
-- Landing needs the platform stopped at a planet.
platform.space_location=nil
fails(function() bots.land(b) end,'not stopped at a planet')
-- At Vulcanus: a hub cargo pod bound for the spawn point there (no pad, never stood there).
platform.space_location={name='vulcanus',type='planet'}
local hub_pod={valid=true,position={x=0,y=0},surface=platform_surface,cargo_pod_state='awaiting_launch'}
hub_pod.force_finish_ascending=function() hub_pod.pushed=true end
hub.create_cargo_pod=function() return hub_pod end
local landing=bots.land(b)
eq(landing.landing,'vulcanus'); eq(landing.pad,nil)
local vulcanus=surfaces.vulcanus
eq(hub_pod.cargo_pod_destination.surface,vulcanus); eq(hub_pod.cargo_pod_destination.type,4); eq(hub_pod.cargo_pod_destination.position.x,0)
eq(b.travel.state,'descending'); eq(bots.status(b.index,{}).travel.to,'vulcanus')
fails(function() bots.check_action(b.index,'land',{}) end,'riding a cargo pod (descending')
-- A pod that sits in the hatch is pushed off once, after 5 s.
advance(300); eq(hub_pod.pushed,nil); advance(1); eq(hub_pod.pushed,true)
hub_pod.cargo_pod_state='descending'; hub_pod.surface=vulcanus; hub_pod.position={x=3,y=4}
advance(1); eq(b.surface,'vulcanus')
-- Down: the body stands where the pod landed, wearing what it rode up in.
hub_pod.valid=false
advance(1)
eq(b.travel.state,'descending','a descent lasts at least 10 s')
advance(600-(game.tick-b.travel.since))
eq(b.travel,nil); eq(b.planet,'vulcanus'); eq(b.surface,'vulcanus')
local c2=b.character
eq(c2.surface,vulcanus); eq(c2.position.x,3); eq(c2.position.y,4)
eq(c2.invs[5][1].name,'modular-armor'); eq(c2.invs[5][1].grid,'grid-1'); eq(c2.invs[3][2].name,'pistol')
eq(c2.items['iron-plate'],nil,'a landing brings no starting items')
eq(kits[1].valid,false)
st=bots.status(b.index,{})
eq(st.travel,nil); eq(st.surface,'vulcanus'); eq(st.planet,'vulcanus'); eq(st.landed.surface,'vulcanus'); eq(st.landed.ticks,600)
-- Deaths on Vulcanus respawn on Vulcanus, as for a player.
c2.valid=false
advance(1); eq(b.dead_until_tick,game.tick+600)
advance(600)
eq(b.character.surface,vulcanus); eq(b.surface,'vulcanus'); eq(b.deaths,1)
-- Its last spot on a planet is remembered (for the next landing there).
b.character.position={x=-7,y=2}
advance(30-game.tick%30)
eq(b.spots.vulcanus.x,-7)
-- A platform lost while aboard kills the bot; it respawns on its last planet.
platform.space_location={name='vulcanus',type='planet'}
bots.board(b,platform,nil)
advance(2399); eq(b.travel.state,'ascending','no pod handle: a fixed 40 s ride')
advance(1); eq(b.travel.state,'aboard')
platform_surface.valid=false
advance(1)
eq(b.travel,nil); eq(b.lost,'platform alpha is gone'); eq(b.deaths,2); eq(kits[2].valid,false)
advance(600); eq(b.character.surface,vulcanus)
platform_surface.valid=true
-- With a landing pad, the hub pod goes to the pad (no fixed position).
bots.board(b,platform,nil); advance(2400)
eq(b.lost,nil,'a new ride clears the last loss (live on sa it stayed in status)'); eq(bots.status(b.index,{}).lost,nil)
platform.space_location={name='nauvis',type='planet'}
nauvis.pads={{position={x=20,y=20}}}
hub_pod={valid=true,position={x=0,y=0},surface=platform_surface,cargo_pod_state='ascending'}
hub.create_cargo_pod=function() return hub_pod end
eq(bots.land(b).pad.x,20); eq(hub_pod.cargo_pod_destination.position,nil)
hub_pod.surface=nauvis; hub_pod.position={x=20,y=19}; hub_pod.cargo_pod_state='descending'
advance(1); eq(b.travel.state,'descending')
hub_pod.cargo_pod_state='parking' -- parked at the pad, still valid: down all the same
advance(600)
eq(b.character.surface,nauvis); eq(b.character.position.y,19); eq(b.planet,'nauvis')
-- No body can be made where the pod came down: a death, not an error in the tick.
bots.board(b,platform,nil); advance(2400)
hub_pod={valid=true,position={x=0,y=0},surface=platform_surface,cargo_pod_state='ascending'}
hub.create_cargo_pod=function() return hub_pod end
bots.land(b)
local real_create=nauvis.create_entity
nauvis.create_entity=function() return nil end
local deaths=b.deaths
hub_pod.valid=false; advance(600)
eq(b.travel,nil); eq(b.deaths,deaths+1); assert(b.lost:find('no body could be made on nauvis',1,true),b.lost)
nauvis.create_entity=real_create
advance(600); eq(b.character.surface,nauvis)
-- A renamed platform keeps its riders (rides follow the index).
platform.index=7
bots.board(b,platform,nil); advance(2400)
platform.name='alpha-2'
advance(1); eq(b.travel.state,'aboard'); eq(b.travel.platform,'alpha-2')
platform.name='alpha'
-- No free hatch: nothing changes (still aboard from above).
hub.create_cargo_pod=function() return nil end
fails(function() bots.land(b) end,'no free cargo hatch')
eq(b.travel.state,'aboard')
-- A fixed camera view on another surface (a pair framed on Vulcanus).
cameras.set{player=2,position={x=5,y=5},surface='vulcanus',smooth=false}
eq(director.surface,surfaces.vulcanus); eq(cameras.describe(2).surface,'vulcanus')
fails(function() cameras.set{player=2,position={x=5,y=5},surface='moon'} end,'no surface named moon')
-- friction6: aboard plans accept bodyless steps, reject body actions before queuing,
-- and check again at execution if the agent's travel state changes.
do
  local before=b.travel
  b.travel={state='aboard',platform='alpha-2'}
  bots.check_action(b.index,'configure',{platform='alpha-2'})
  bots.check_action(b.index,'configure',{surface='nauvis'})
  bots.check_action(b.index,'queue_submit',{})
  bots.check_action(b.index,'configure',{})
  local state,dropped,departed={},0,false
  local s=dofile('mod/agent-harness_0.1.0/scheduler.lua'){
    state=function() return state end,player=function() return {index=b.index} end,
    handlers={drop=function() dropped=dropped+1; return {} end,craft=function() error('body action ran') end},
    check_action=bots.check_action,validate_condition=function() end,
    condition=function(_,a) if a['until']=='platform_left' then return departed end return true end,
    stop=function() end,busy=function() return false end}
  local p={index=b.index}
  local steps={{action='wait_until',args={['until']='platform_arrived',platform='alpha-2'}},{action='drop',args={platform='alpha-2'}}}
  s.handlers.queue_submit(p,{steps=steps})
  s.tick(); game.tick=game.tick+1; s.tick()
  eq(dropped,1)
  local rev=s.handlers.queue_status(p).revision
  fails(function() s.handlers.queue_submit(p,{steps={steps[1],{action='craft',args={recipe='iron-gear-wheel'}}}}) end,'steps[2] (craft)')
  eq(s.handlers.queue_status(p).revision,rev)
  fails(function() s.handlers.queue_submit(p,{steps={},guards={{when={['until']='crafting_done'}}}}) end,'guards[1]')
  -- Repeat modes keep the aboard checks and contextual errors before any preemption.
  s.handlers.queue_repeat(p,{name='aboard-loop',steps=steps,interval_ticks=60,
    condition={['until']='platform_left',platform='alpha-2'}})
  s.tick()
  rev=s.handlers.queue_status(p).revision
  fails(function() s.handlers.queue_submit(p,{steps={{action='drop'}}}) end,'repeating job "aboard-loop"')
  fails(function() s.handlers.queue_submit(p,{mode='replace',steps={{action='craft'}}}) end,'steps[1] (craft)')
  fails(function() s.handlers.queue_submit(p,{mode='ahead',steps={},guards={{when={['until']='crafting_done'}}}}) end,'guards[1]')
  fails(function() s.handlers.queue_repeat(p,{condition={['until']='crafting_done'},steps=steps}) end,'condition:')
  eq(s.handlers.queue_status(p).revision,rev)
  eq(s.handlers.queue_status(p).active.action,'wait_until')
  local ahead=s.handlers.queue_submit(p,{mode='ahead',steps={{action='drop',label='urgent'}}})
  eq(ahead.repeating,true); eq(ahead.pending[1].label,'urgent'); eq(ahead.pending[2].action,'wait_until')
  s.tick(); eq(dropped,2)
  game.tick=game.tick+1; s.tick(); eq(dropped,3)
  game.tick=game.tick+1; s.tick()
  departed=true; game.tick=game.tick+60; s.tick()
  eq(s.handlers.queue_status(p).repeating,false); eq(s.handlers.queue_status(p).loop_done.rounds,1)
  departed=false
  s.handlers.queue_repeat(p,{steps=steps})
  local replacement=s.handlers.queue_submit(p,{mode='replace',steps={{action='drop'}}})
  eq(replacement.repeating,false); eq(#replacement.pending,1)
  b.travel.state='descending'; game.tick=game.tick+1; s.tick()
  eq(dropped,3); eq(s.handlers.queue_status(p).paused,true)
  b.travel=before
end

-- Removing a bot in transit drops its kit.
bots.remove('astra'); eq(kits[#kits].valid,false)
print('travel: ok')
