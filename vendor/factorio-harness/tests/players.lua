-- Run from repository root: lua tests/players.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local names={'on_built_entity','on_player_mined_entity','on_robot_mined_entity','on_entity_died','on_marked_for_deconstruction',
  'on_marked_for_upgrade','on_cancelled_deconstruction','on_cancelled_upgrade','on_gui_opened','on_gui_closed',
  'on_player_fast_transferred','on_player_main_inventory_changed','on_player_joined_game','on_player_left_game'}
defines={events={},inventory={chest=1,car_trunk=2,cargo_wagon=3,spider_trunk=4,character_main=5},build_check_type={manual_ghost=1}}
for i,n in ipairs(names) do defines.events[n]=100+i end
local function fire(name,event) event.name=defines.events[name]; return event end

-- The world: one surface, a force, entities that can be marked and mined.
local created,placeable={},{}
local entities={}
local surface={name='nauvis',index=1}
function surface.find_entities_filtered(f)
  for _,e in ipairs(entities) do
    if e.valid and (f.name==nil or e.name==f.name) and (f.ghost_name==nil or e.ghost_name==f.ghost_name)
      and math.abs(e.position.x-f.position.x)<=f.radius and math.abs(e.position.y-f.position.y)<=f.radius then return {e} end
  end
  return {}
end
function surface.can_place_entity(a) return placeable[a.position.x..','..a.position.y]~=false end
function surface.create_entity(a)
  local g={valid=true,type='entity-ghost',name='entity-ghost',ghost_name=a.inner_name,position=a.position,surface=surface,direction=a.direction,args=a}
  g.set_recipe=function(r) g.recipe=r end
  created[#created+1]=g; entities[#entities+1]=g
  return g
end
local force={name='player'}
local function entity(name,type,x,y,extra)
  local e={valid=true,name=name,type=type,position={x=x,y=y},surface=surface,force=force,direction=4,marked=false,upgrading=false}
  e.to_be_deconstructed=function() return e.marked end
  e.to_be_upgraded=function() return e.upgrading end
  e.cancel_deconstruction=function() e.marked=false end
  e.cancel_upgrade=function() e.upgrading=false end
  for k,v in pairs(extra or {}) do e[k]=v end
  entities[#entities+1]=e
  return e
end
local function inventory(contents)
  local inv={items=contents}
  inv.get_contents=function() local out={}; for n,c in pairs(inv.items) do out[#out+1]={name=n,count=c,quality='normal'} end; return out end
  return inv
end
local groups={Default={name='Default',players={}},['pog-guest']={name='pog-guest',players={}}}
local function group_of(name) return groups[name] end
local nick={index=1,name='nick',valid=true,connected=true,position={x=5,y=5},surface=surface,force=force}
local cam={index=2,name='pog-cam1',valid=true,connected=true,position={x=0,y=0},surface=surface,force=force}
local eve={index=3,name='eve',valid=true,connected=false,position={x=0,y=0},surface=surface,force=force}
local main_inv=inventory({})
nick.get_main_inventory=function() return main_inv end
for _,g in pairs(groups) do g.add_player=function(p) p.permission_group=g end end
nick.permission_group=groups['pog-guest']; eve.permission_group=groups.Default; cam.permission_group=groups.Default
local players={nick,cam,eve}
game={tick=1000,players=players,permissions={get_group=group_of},
  get_player=function(k) for _,p in ipairs(players) do if p.index==k or p.name==k then return p end end end,
  get_surface=function(n) return n=='nauvis' and surface or nil end}
local s={}
local notices={}
local active={'luna','sol','grok'}
local M=dofile('mod/agent-harness_0.1.0/players.lua'){state=function() return s end,
  is_human=function(index) return index~=2 end,
  active_agents=function(window) eq(window,36000); local out={}; for i,n in ipairs(active) do out[i]=n end; return out end,
  notice=function(from,text) notices[#notices+1]=from..': '..text end}
local luna={index=1000001,name='luna',force=force}
local sol={index=1000002,name='sol',force=force}
local grok={index=1000003,name='grok',force=force}

-- Every forwarded event has a handler; events from a camera client or a bot (no player) are not logged.
for _,n in ipairs(names) do assert(M.events[defines.events[n]]==n,n) end
M.on_event(fire('on_built_entity',{player_index=2,entity=entity('transport-belt','transport-belt',0,0)}))
M.on_event(fire('on_built_entity',{entity=entity('transport-belt','transport-belt',0,1)}))
eq(s.humans,nil)

-- Builds, ghosts included, with counts by name and the area.
for x=10,12 do M.on_event(fire('on_built_entity',{player_index=1,entity=entity('transport-belt','transport-belt',x,3)})) end
M.on_event(fire('on_built_entity',{player_index=1,entity=entity('entity-ghost','entity-ghost',14,6,{ghost_name='inserter'})}))
local r=M.handlers.players(luna,{})
eq(#r.players,2); eq(r.players[1].name,'nick'); eq(r.players[1].group,'guest'); eq(r.players[1].online,true); eq(r.players[1].position.x,5)
eq(r.players[2].name,'eve'); eq(r.players[2].group,'normal'); eq(r.players[2].position,nil); eq(r.players[2].built,nil)
local b=r.players[1].built
eq(b.count,4); eq(b.items['transport-belt'],3); eq(b.items.inserter,1)
eq(b.area.left_top.x,10); eq(b.area.left_top.y,3); eq(b.area.right_bottom.x,14); eq(b.area.right_bottom.y,6)
eq(table.concat(r.active,','),'grok,luna,sol')

-- Removals: by hand (settings kept for the ghost), trees are play, not work; destroyed by the player's character.
local asm=entity('assembling-machine-2','assembling-machine',20,20,{get_recipe=function() return {name='iron-gear-wheel'} end})
local ug=entity('underground-belt','underground-belt',22,20,{belt_to_ground_type='output'})
local tree=entity('tree-01','tree',30,30)
for _,e in ipairs{asm,ug,tree} do M.on_event(fire('on_player_mined_entity',{player_index=1,entity=e})); e.valid=false end
local wall=entity('stone-wall','wall',25,25)
M.on_event(fire('on_entity_died',{entity=wall,cause={valid=true,type='character',player=nick}})); wall.valid=false
local biter=entity('small-biter','unit',26,26,{force={name='enemy'}})
M.on_event(fire('on_entity_died',{entity=biter,cause={valid=true,type='character',player=nick}}))
-- A car's driver is the cause too.
local fence=entity('small-electric-pole','electric-pole',27,25)
M.on_event(fire('on_entity_died',{entity=fence,cause={valid=true,type='car',get_driver=function() return {is_player=function() return false end,player=nick} end}})); fence.valid=false
local rm=s.humans.by_index[1].removed
eq(#rm,4); eq(rm[1].recipe,'iron-gear-wheel'); eq(rm[2].belt_type,'output'); eq(rm[3].how,'destroyed'); eq(rm[4].name,'small-electric-pole')

-- Deconstruction and upgrade orders: cancelled ones drop out, robot-mined ones become the orderer's removals.
local poles={}
for i=1,3 do poles[i]=entity('medium-electric-pole','electric-pole',40+i,0); poles[i].marked=true
  M.on_event(fire('on_marked_for_deconstruction',{player_index=1,entity=poles[i]})) end
local furnace=entity('stone-furnace','furnace',50,0); furnace.upgrading=true
M.on_event(fire('on_marked_for_upgrade',{player_index=1,entity=furnace}))
poles[1].marked=false; M.on_event(fire('on_cancelled_deconstruction',{player_index=4,entity=poles[1]}))
M.on_event(fire('on_robot_mined_entity',{entity=poles[2]})); poles[2].valid=false
-- A robot carrying out somebody else's order is not this player's removal.
local other=entity('pipe','pipe',60,0); M.on_event(fire('on_robot_mined_entity',{entity=other}))
eq(#s.humans.by_index[1].removed,5); eq(s.humans.by_index[1].removed[5].how,'robot')
r=M.handlers.players(luna,{player='nick'})
eq(#r.players,1)
local po=r.players[1].pending_orders
eq(po.deconstruct.count,1); eq(po.deconstruct.items['medium-electric-pole'],1); eq(po.upgrade.count,1)
local gone=r.players[1].removed
eq(gone.count,5); eq(gone.how.mined,2); eq(gone.how.destroyed,2); eq(gone.how.robot,1); eq(gone.not_restored,5)
eq(s.humans.order_count,2)

-- Big inventory moves: a chest opened by hand (its loss is the player's gain), from 50 items.
local chest=entity('iron-chest','container',70,70)
local chest_inv=inventory({['iron-plate']=200,coal=5})
chest.get_inventory=function(i) eq(i,1); return chest_inv end
M.on_event(fire('on_gui_opened',{player_index=1,entity=chest}))
chest_inv.items={['iron-plate']=50,coal=5,['copper-plate']=20}
M.on_event(fire('on_gui_closed',{player_index=1}))
local mv=s.humans.by_index[1].moves
eq(#mv,1); eq(mv[1].took['iron-plate'],150); eq(mv[1].put['copper-plate'],20); eq(mv[1].items,170); eq(mv[1].entity,'iron-chest')
M.on_event(fire('on_gui_opened',{player_index=1,entity=chest}))
chest_inv.items={['iron-plate']=40,coal=5,['copper-plate']=20}
M.on_event(fire('on_gui_closed',{player_index=1}))
eq(#s.humans.by_index[1].moves,1) -- 10 plates is not a big move
-- Ctrl-click transfers: the same tick's main inventory change gives the counts, in either order.
main_inv.items={['iron-plate']=10}
M.on_event(fire('on_player_main_inventory_changed',{player_index=1}))
game.tick=1100
main_inv.items={['iron-plate']=10,['iron-gear-wheel']=100}
M.on_event(fire('on_player_main_inventory_changed',{player_index=1}))
M.on_event(fire('on_player_fast_transferred',{player_index=1,entity=chest,from_player=false}))
game.tick=1200
M.on_event(fire('on_player_fast_transferred',{player_index=1,entity=chest,from_player=true}))
main_inv.items={['iron-plate']=10}
M.on_event(fire('on_player_main_inventory_changed',{player_index=1}))
mv=s.humans.by_index[1].moves
eq(#mv,3); eq(mv[2].took['iron-gear-wheel'],100); eq(mv[3].put['iron-gear-wheel'],100); eq(mv[3].position.x,70)
r=M.handlers.players(luna,{player='nick'})
eq(#r.players[1].moves,3); eq(r.players[1].moves[3].s_ago,0)
-- Humans joining and leaving are chat lines from `players`; camera clients are not.
M.on_event(fire('on_player_joined_game',{player_index=1})); eq(notices[#notices],'players: nick joined the game (guest group)')
M.on_event(fire('on_player_joined_game',{player_index=2})); eq(notices[#notices],'players: nick joined the game (guest group)')
M.on_event(fire('on_player_left_game',{player_index=3})); eq(notices[#notices],'players: eve left the game')
eq(M.handlers.players(luna,{player='eve'}).players[1].left_s_ago,0)
-- Errors name the player; the window drops older activity.
fails(function() M.handlers.players(luna,{player='pog-cam1'}) end,'no human player named pog-cam1')
fails(function() M.handlers.players(luna,{minutes=0}) end,'minutes must be a whole number 1..240')
game.tick=1000+11*3600
r=M.handlers.players(luna,{})
eq(r.players[1].built,nil); eq(r.players[1].removed,nil); eq(r.players[1].moves,nil); eq(r.players[1].pending_orders.deconstruct.count,1)
eq(M.handlers.players(luna,{minutes=20}).players[1].built.count,4)

-- Votes: a reason opens one; the operator reads every ballot and who is active.
fails(function() M.handlers.vote(luna,{kind='mute',player='nick',reason='x'}) end,'kind must be kick, ban or trust')
fails(function() M.handlers.vote(luna,{kind='kick',player='nick'}) end,'reason is required to open a vote')
fails(function() M.handlers.vote(luna,{kind='kick',player='nick',reason='x',yes=false}) end,'no open vote to kick nick to vote against')
fails(function() M.handlers.vote(luna,{kind='trust',player='eve',reason='helped'}) end,'eve is not in the guest group (group normal)')
fails(function() M.handlers.vote(luna,{kind='kick',player='luna',reason='x'}) end,'no human player named luna')
local v=M.handlers.vote(luna,{kind='kick',player='nick',reason='mined the [b]main[/b] bus'})
eq(v.id,1); eq(v.outcome,'open'); eq(v.yes[1],'luna'); eq(v.closes_in_s,600); eq(v.reason,'mined the (b)main(/b) bus')
eq(v.electorate,'3 agents active in the last 10 minutes; 2 yes carry it')
eq(notices[#notices],'vote: #1 kick nick: luna votes yes - mined the (b)main(/b) bus (yes 1, no 0; 3 agents active in the last 10 minutes; 2 yes carry it)')
active={'luna','sol','grok','haiku'}
v=M.handlers.vote(sol,{kind='kick',player='nick',yes=false})
eq(v.id,1); eq(#v.yes,1); eq(v.no[1],'sol')
local n=#notices
M.handlers.vote(sol,{kind='kick',player='nick',yes=false}); eq(#notices,n) -- the same ballot again says nothing
local open=M.operator.votes_open()
eq(#open.votes,1); eq(open.votes[1].ballots.luna,true); eq(open.votes[1].ballots.sol,false); eq(#open.active,4); eq(open.window_ticks,36000)
M.handlers.vote(grok,{kind='trust',player='nick',reason='rebuilt the bus'})
eq(#M.handlers.votes(luna).open,2)
-- The operator closes it; a closed vote stays closed and a new one may open.
fails(function() M.operator.vote_close({id=1,outcome='won'}) end,'outcome must be')
v=M.operator.vote_close({id=1,outcome='failed',note='1 of 3 needed'})
eq(v.outcome,'failed'); eq(notices[#notices],'vote: #1 kick nick failed (yes 1, no 1): 1 of 3 needed')
eq(M.operator.vote_close({id=1,outcome='carried'}).outcome,'failed')
eq(M.handlers.vote(luna,{kind='kick',player='nick',reason='again'}).id,3)
local list=M.handlers.votes(luna)
eq(#list.open,2); eq(#list.closed,1); eq(list.closed[1].note,'1 of 3 needed')
-- A vote nobody closed expires a minute after its 10.
game.tick=game.tick+11*3600+1
list=M.handlers.votes(luna)
eq(#list.open,0); eq(list.closed[3].outcome,'expired'); eq(list.closed[3].note,'no operator tally')

-- Restore: pending orders cancelled, ghosts where the player removed something, settings kept; nothing twice.
game.tick=1000+11*3600
local blocker=entity('stone-wall','wall',25,25) -- the team rebuilt the wall already
placeable['27,25']=false                          -- something else stands where the pole was
r=M.handlers.restore(luna,{player='nick',minutes=20})
eq(r.cancelled,2); eq(poles[3].marked,false); eq(furnace.upgrading,false)
eq(r.ghosts,3); eq(r.already,1); eq(r.blocked,1)
eq(created[1].ghost_name,'assembling-machine-2'); eq(created[1].recipe,'iron-gear-wheel'); eq(created[1].args.expires,false)
eq(created[2].args.type,'output'); eq(created[3].ghost_name,'medium-electric-pole'); eq(created[1].args.force,force)
eq(r.items['assembling-machine-2'],1); eq(r.note,'ghosts are orders: robots or agents build them with real items')
eq(notices[#notices],"vote: luna restored nick's last 20 minutes: 2 orders cancelled, 3 ghosts placed")
r=M.handlers.restore(luna,{player='nick',minutes=20})
eq(r.cancelled,0); eq(r.ghosts,0); eq(r.already,0); eq(r.blocked,1)
eq(blocker.valid,true); eq(#created,3)
eq(M.handlers.players(luna,{player='nick',minutes=20}).players[1].removed.not_restored,1)

-- Operator: trust moves a player to the normal group and remembers the name for later worlds' first join.
r=M.operator.player_group({name='nick',group='trusted'})
eq(r.group,'normal'); eq(s.trusted_names.nick,true)
r=M.operator.player_group({name='nick',group='guest'}); eq(r.group,'guest'); eq(s.trusted_names.nick,nil)
fails(function() M.operator.player_group({name='nick',group='admin'}) end,'group must be trusted or guest')
eq(#M.operator.players({}).players,2)
print('players: ok')
