-- Run from repository root: lua tests/d28_batch317.lua
-- (d28 batch317 PD, Nick: the kit grows with each team) progressive disclosure (disclosure.lua, docs/DISCLOSURE.md):
-- off by default (everything open, nothing kept); in filter mode a fresh force sees the small tick-0 set, each trigger
-- kind opens its units once per force, a call to a unit not open yet is refused naming its condition (refuse=false:
-- allowed, undocumented), describe shows the open set, and each unlock reaches an agent once as a `new:` line; observe
-- mode keeps the state and filters nothing. On main: no disclosure.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end
defines={events={on_research_finished=1,on_entity_damaged=2,on_entity_died=3,on_unit_group_finished_gathering=4,
  on_cargo_pod_finished_descending=5}}
prototypes={entity=setmetatable({},{__index=function(_,k) return {name=k} end})}
script={active_mods={base='2.0.77',['space-age']='2.0.77',quality='2.0.77'}}
local function make_force(name)
  local counts,techs={},{}
  local f={name=name,valid=true,platforms={},technologies=techs,counts=counts}
  f.get_entity_count=function(n) return counts[n] or 0 end
  f.get_item_production_statistics=function() return {get_input_count=function() return 0 end} end
  return f
end
local player,red=make_force('player'),make_force('red')
local nauvis={name='nauvis',peaceful_mode=false,no_enemies_mode=false,
  count_entities_filtered=function() return 0 end}
game={tick=0,forces={player=player,red=red,enemy={name='enemy',valid=true}},surfaces={nauvis=nauvis},
  get_surface=function(n) return n=='nauvis' and nauvis or nil end}
storage={agent_harness={}}
local units=dofile('mod/agent-harness_0.1.0/disclosure_units.lua')
local forces={player}
local D=dofile('mod/agent-harness_0.1.0/disclosure.lua'){state=function() return storage.agent_harness end,units=units,
  forces=function() return forces end,is_team=function(f) return f.name=='player' or f.name=='red' end,
  team_size=function() return 3 end,characters=function() return {} end,push_groups=function() return nil end}

-- off (the default): everything open, nothing kept, nothing said
eq(D.mode(),'off'); eq(D.gate({action='belt_route',args={}},player),nil)
eq(D.action_open(player,'belt_route'),true)
D.count({action='craft',args={recipe='iron-gear-wheel',count=50}},true,{},player)
eq(storage.agent_harness.disclosure,nil,'off keeps no state')
eq(D.read(player).mode,'off')
local desc={bundle='B1',actions={walk={position='x'},belt_route={from='a'},train={},build={item='i',rail_layer='q',dry_run='d'},
  attach={}}}
eq(D.filter_describe(desc,player,'B1'),desc,'off: describe as it was')

-- filter, world n's flags (Space Age, Quality, enemies, a team) plus a stream
D.operator.disclosure_set({mode='filter',world={stream=true}})
local o=D.open_set(player)
for _,a in ipairs({'walk','move_to','mine','craft','build','transfer','inspect','observe','research','say','tell','board_post',
  'profile','shoot','sleep','status'}) do assert(o.actions[a],a..' is open at tick 0') end
for _,a in ipairs({'belt_route','train','place_ghosts','circuit_set','platform_create','queue_submit','wait_until',
  'bottleneck','labs'}) do assert(not o.actions[a],a..' is shut at tick 0') end
local why=D.gate({action='belt_route',args={}},player)
eq(why,'belt_route is not available yet: it opens when your team has placed 10 belts with build, or when your team has 40 belts '
  ..'(the same rule for every team; ./fh help lists what is open)')
eq(D.gate({action='walk',args={position={x=1,y=2}}},player),nil)
eq(D.gate({action='attach',args={}},player),nil,'never units are not gated (setup calls)')
eq(D.gate({action='describe',args={}},player),nil)
eq(D.gate({action='belt_route',args={},operator=true},player),nil,'operator calls pass')
eq(D.gate({action='belt_route',args={},reader='stream'},player),nil,'reader calls pass')
-- an argument not open yet
has(D.gate({action='feed',args={item='coal',quality='rare'}},player),
  "feed's argument quality is not available yet: it opens when your team has researched quality-module")
eq(D.arg_hidden(player,'feed','quality'),true); eq(D.arg_hidden(player,'feed','item'),false)

-- describe: the open set, the locked by name with their condition, a bundle id with the revision
local fd=D.filter_describe(desc,player,'B1')
assert(fd.actions.walk and fd.actions.build and fd.actions.attach and not fd.actions.belt_route and not fd.actions.train)
eq(fd.actions.build.rail_layer,nil); eq(fd.actions.build.item,'i'); eq(fd.actions.build.dry_run,nil,'dry_run opens with a refusal')
has(fd.locked.belt_route,'placed 10 belts with build'); eq(fd.bundle,'B1@d0')
has(fd.disclosure,'actions and'); eq(desc.actions.build.rail_layer,'q','the source table is untouched')

-- the agent's first reply sets its cursor; nothing is said for the set it started with
eq(D.reply_line('astra',player),nil)
-- habit: 10 belts placed with build open belt_route, once
for i=1,9 do D.count({action='build',args={item='transport-belt',position={x=i,y=0}}},true,{},player) end
assert(not D.open_set(player).actions.belt_route)
local rev=D.fstate(player).rev
D.count({action='build',args={item='transport-belt',position={x=10,y=0}}},true,{},player)
assert(D.open_set(player).actions.belt_route,'10 belts open belt_route')
assert(D.fstate(player).rev>rev)
rev=D.fstate(player).rev
local line=D.reply_line('astra',player)
has(line,'belt_route (lays a belt line as ghosts)'); has(line,'docs: '); has(line,'./fh help building')
lacks(line,'new:')
-- the same calls also made 5 similar calls in a row: the queue opened with them
assert(D.open_set(player).actions.queue_submit); has(line,'queue_submit')
eq(D.reply_line('astra',player),nil,'said once')
for i=11,60 do D.count({action='build',args={item='transport-belt'}},true,{},player) end
eq(D.fstate(player).rev,rev,'a met threshold does not grow the revision again')
-- each entry of a batch build counts (an entry with no item takes the call's)
D.count({action='build',args={builds={{item='small-electric-pole'},{item='small-electric-pole'},{item='small-electric-pole'}}}},true,{},player)
eq(D.fstate(player).counts['habit:hand_poles'],3)
D.count({action='build',args={item='medium-electric-pole',builds={{position={x=1,y=1}},{position={x=8,y=1}}}}},true,{},player)
eq(D.fstate(player).counts['habit:hand_poles'],5)

-- a refused build opens build's dry_run (and its skip_failed); our own refusals do not count
D.count({action='build',args={item='x'}},false,'build is not available yet: ...',player)
eq(D.fstate(player).counts['habit:refused:build'],nil)
D.count({action='build',args={item='x'}},false,'blocked by a tree at (3,4)',player)
eq(D.fstate(player).counts['habit:refused:build'],1)
eq(D.arg_open(player,'build','dry_run'),true); eq(D.arg_open(player,'mine','dry_run'),false,'per action')

-- research (the engine's event): train opens; a second event changes nothing
rev=D.fstate(player).rev
D.on_event({name=1,research={valid=true,name='railway',force=player}})
assert(D.open_set(player).actions.train); eq(D.fstate(player).rev,rev+1)
D.on_event({name=1,research={valid=true,name='railway',force=player}})
eq(D.fstate(player).rev,rev+1,'once per force')
has(D.reply_line('astra',player),'train')

-- built (the sweep): a lab opens labs and science
player.counts.lab=1
D.sweep(600)  -- part 1: buildings
assert(D.open_set(player).actions.labs and D.open_set(player).actions.science)
eq(D.fstate(player).met['built:lab'],0)

-- an attack (on_entity_damaged by the enemy force): attacked, enemy_seen, spitters by the cause's name
local wall={valid=true,force=player,type='wall',surface={platform=nil}}
D.on_event({name=2,entity=wall,force=game.forces.enemy,cause={valid=true,name='small-spitter',type='unit'}})
local met=D.fstate(player).met
assert(met['event:attacked'] and met['event:enemy_seen'] and met['event:spitters'])
assert(D.open_set(player).actions.kite,'kite opens on the first attack')
-- an asteroid on a platform is not an attack
local tile={valid=true,force=player,type='wall',surface={platform={}}}
D.on_event({name=2,entity=tile,force=game.forces.enemy,cause={valid=true,name='small-metallic-asteroid',type='asteroid'}})
assert(met['event:asteroids'])
-- a death of ours: died; a building destroyed: loss
D.on_event({name=3,entity={valid=true,force=player,type='character',surface={}},force=game.forces.enemy})
D.on_event({name=3,entity={valid=true,force=player,type='assembling-machine',surface={}},force=game.forces.enemy})
assert(met['event:died'] and met['event:loss'])
-- freight
D.on_event({name=5,cargo_pod={valid=true,force=player}})
assert(met['event:freight'])

-- per force: red has none of it
forces={player,red}
for t=0,1800,600 do D.sweep(t) end
local rf=D.fstate(red)
eq(rf.met['research:railway'],nil); eq(rf.counts['habit:hand_belts'],nil)
assert(not D.open_set(red).actions.belt_route and not D.open_set(red).actions.train)
D.on_event({name=1,research={valid=true,name='railway',force=red}})
assert(D.open_set(red).actions.train)
forces={player}

-- the host's read: open names and ids
local r=D.read(player)
eq(r.mode,'filter'); assert(#r.actions>40 and #r.docs>40 and #r.brief>40)
local docs={}
for _,id in ipairs(r.docs) do docs[id]=true end
assert(docs['moving-items#transfer'],'transfer\'s entry')
local shut={}
for _,id in ipairs(r.docs_shut) do shut[id]=true end
assert(shut['space-age#platform_create'] and not shut['moving-items#transfer'] and not shut['building#belt_route'])
assert(#r.actions_shut>100 and #r.brief_shut>0); assert(r.args_locked.build,'build has shut arguments')
-- the operator's read
local op=D.operator.disclosure({}).forces.player
has(op.line,'player: '); assert(op.open.actions>50 and #op.met>5 and #op.newest>=1)
local nexts=table.concat(op.next,'; ')
has(nexts,'habit:board_items 0 of 20'); lacks(nexts,'habit:hand_poles')
lacks(nexts,'habit:hand_belts 60 of')

-- refuse=false: allowed but undocumented
D.operator.disclosure_set({refuse=false})
eq(D.gate({action='platform_create',args={}},player),nil)
eq(D.filter_describe(desc,player,'B1').locked,nil)
D.operator.disclosure_set({refuse=true})

-- the world gate: a peaceful one-agent world without a stream
D.operator.disclosure_set({world={team=false,enemies=false,stream=false}})
eq(D.gate({action='tell',args={}},player),'tell is not available yet: not part of this world (team is off) '
  ..'(the same rule for every team; ./fh help lists what is open)')
assert(not D.open_set(player).actions.shoot)
D.operator.disclosure_set({world={team=true,enemies=true,stream=true}})

-- observe: kept and logged, nothing filtered or said
D.operator.disclosure_set({mode='observe',reset=true})
eq(D.gate({action='platform_create',args={}},player),nil)
eq(D.filter_describe(desc,player,'B1'),desc)
eq(D.reply_line('astra',player),nil)
rev=D.fstate(player).rev
D.on_event({name=1,research={valid=true,name='circuit-network',force=player}})
eq(D.fstate(player).rev,rev+1,'observe keeps the state')
assert(#D.fstate(player).log>=1,'and logs the unlock')
-- off again: nothing kept from then on
D.operator.disclosure_set({mode='off'})
D.on_event({name=1,research={valid=true,name='logistics-2',force=player}})
eq(D.fstate(player).met['research:logistics-2'],nil)
print('d28_batch317 ok')
