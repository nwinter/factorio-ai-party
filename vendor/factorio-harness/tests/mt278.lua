-- mt278 (private: multi-team part H). Run from the harness root: lua tests/mt278.lua
-- A human team (humans.lua): roster players join into its force at its spawn; the freeze is asked by chat or comes by
-- itself, waits out a fight, warms up, then holds a cease-fire both ways, the players' frozen group and the core
-- entities indestructible (in steps), and ends on its hours, a returning player, "!unfreeze" or the day's budget.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

local H_TICKS, MIN = 216000, 3600
defines={events={on_player_joined_game=1,on_console_chat=2,on_built_entity=3,on_robot_built_entity=4,script_raised_built=5,
  script_raised_revive=6},controllers={god=3,character=1},input_action={write_to_console=1,build=2,import_blueprint=3,
  open_blueprint_library_gui=4,import_blueprint_string=5,import_blueprints_filtered=6,import_permissions_string=7,
  grab_blueprint_record=8,delete_blueprint_library=9,delete_blueprint_record=10}}
local function force(name)
  local f={name=name,players={},cease={},printed={}}
  f.set_cease_fire=function(o,v) f.cease[type(o)=='table' and o.name or o]=v end
  f.get_cease_fire=function(o) return f.cease[type(o)=='table' and o.name or o]==true end
  f.get_spawn_position=function() return {x=0,y=2830} end
  f.print=function(t) f.printed[#f.printed+1]=t end
  return f
end
local white,red,blue=force('white'),force('red'),force('blue')
red.set_cease_fire('white',false)
local groups={}
local permissions={get_group=function(n) return groups[n] end,create_group=function(n)
  local g={name=n,allows={}}; g.set_allows_action=function(id,v) g.allows[id]=v end; groups[n]=g; return g end}
local ents={}
for i=1,5 do ents[i]={valid=true,type=i<=4 and 'assembling-machine' or 'electric-pole',unit_number=100+i,destructible=true,force={name='white'}} end
ents[6]={valid=true,type='assembling-machine',unit_number=106,destructible=false,force={name='white'}}  -- the map's own: stays so
local surface={name='nauvis',find_entities_filtered=function(f)
  assert(f.force==white and f.type,'a find by force and type'); return ents end,
  find_non_colliding_position=function(_,p) return p end}
local nick={name='nick',index=1,connected=true,force=force('player'),valid=true}
nick.set_controller=function() end
nick.teleport=function(p) nick.at=p end
nick.create_character=function() nick.character={valid=true,destroy=function() nick.character=nil end} end
local stranger={name='bob',index=2,connected=true,force=nick.force}
local connected={nick}
game={tick=1000,forces={white=white,red=red,blue=blue},permissions=permissions,players={nick,stranger},connected_players=connected,
  surfaces={nauvis=surface},get_surface=function() return surface end,get_player=function(i) return ({nick,stranger})[i] end}
local s={mt={order={'red','blue','white'},teams={red=true,blue=true,white=true}}}
local H=dofile('mod/agent-harness_0.1.0/humans.lua'){state=function() return s end}
H.STEP=4

local r=H.operator.mt_humans({team='white',players={'nick'},budget_h=3,block_h=1,offline_min=30,warm_min=10,quiet_min=10})
eq(r.placed[1].force,'white','a roster player online is placed'); eq(nick.force,white); eq(nick.at.y,2830,'at the team spawn')
eq(nick.permission_group.name,'pog-humans'); eq(groups['pog-humans'].allows[3],false,'no blueprint import')
eq(stranger.force.name,'player','someone not on the roster is left alone')
H.on_event({name=1,player_index=2}); eq(stranger.force.name,'player')

local function tick_to(t) while game.tick<t do game.tick=game.tick+1; H.tick(game.tick) end end
local function state() return H.operator.mt_freeze({}) end

-- a fight 2 minutes ago: the request waits, then warms up 10 min after the fight, then freezes
s.mt.humans.last_fight=game.tick-2*MIN
H.on_event({name=2,player_index=1,message='!freeze 2'})
eq(state().state,'waiting','a fight within quiet_min: the freeze waits')
tick_to(game.tick+8*MIN+60); eq(state().state,'warming','10 min after the fight: the warm-up')
-- a hit during the warm-up (by red on a white entity) puts it back
tick_to(game.tick+60)
H.on_damaged({force=red,entity={valid=true,force={name='white'}}})
local first_warm=s.mt.humans.warm_until
tick_to(first_warm); eq(state().state,'waiting','a fight in the warm-up: waiting again, not frozen')
-- biters or the team's own hits are no fight
H.on_damaged({force={name='enemy'},entity={valid=true,force={name='white'}}})
H.on_damaged({force=white,entity={valid=true,force={name='white'}}})
local lf=s.mt.humans.last_fight
tick_to(lf+10*MIN+60); eq(state().state,'warming','10 min after that fight: a new warm-up')
assert(s.mt.humans.warm_until>first_warm,'announced again')
tick_to(s.mt.humans.warm_until+60)
local f=state()
eq(f.state,'frozen'); eq(f.until_tick-s.mt.humans.since,2*H_TICKS,'the hours asked')
eq(white.get_cease_fire('red'),true); eq(red.get_cease_fire('white'),true,'a cease-fire both ways'); eq(blue.get_cease_fire('white'),true)
eq(nick.permission_group.name,'pog-frozen'); eq(groups['pog-frozen'].allows[1],true,'chat allowed'); eq(groups['pog-frozen'].allows[2],false,'no build')
tick_to(game.tick+2)
eq(ents[1].destructible,false,'core entities indestructible'); eq(ents[5].destructible,false,'in steps of STEP')
eq(state().queue,nil,'all queued done')
-- a core entity built while frozen
local new={valid=true,type='furnace',unit_number=200,destructible=true,force={name='white'}}
H.on_event({name=4,entity=new}); eq(new.destructible,false)
-- "!unfreeze" before a block is up: refused; after: thawed
H.on_event({name=2,player_index=1,message='!unfreeze'}); tick_to(game.tick+120); eq(state().state,'frozen','a block is 1 h')
tick_to(s.mt.humans.since+H_TICKS+10)
H.on_event({name=2,player_index=1,message='!unfreeze'}); tick_to(game.tick+120)
eq(state().state,'off','unfrozen when asked after a block')
eq(red.get_cease_fire('white'),false,'the earlier cease-fires back'); eq(white.get_cease_fire('red'),false)
tick_to(game.tick+3)
eq(ents[1].destructible,true); eq(ents[6].destructible,false,'one the freeze did not set stays as it was')
eq(nick.permission_group.name,'pog-humans')
local used=state().used_h
assert(used>1 and used<1.1,'about 1 h of budget used: '..used)

-- everyone offline 30 min: an automatic freeze, held while nobody is back, ended by the day's budget (3 h)
connected[1]=nil; nick.connected=false
tick_to(game.tick+30*MIN+120); eq(state().state,'warming','offline 30 min: the warm-up'); eq(state().reason,'auto')
tick_to(s.mt.humans.warm_until+60); eq(state().state,'frozen')
tick_to(s.mt.humans.until_tick+600); eq(state().state,'frozen','an automatic freeze holds while nobody is back')
tick_to(s.mt.humans.since+2*H_TICKS+60); eq(state().state,'off','the budget spent (1 h used before, 2 h now)')
-- no budget left today: refused
local msg=H.operator.mt_freeze({start=true})
eq(msg.state,'off','no block left today')
-- the next game day: a returning player ends an automatic freeze after its first hour
game.tick=(math.floor(game.tick/(24*H_TICKS))+1)*24*H_TICKS
s.mt.humans.offline_since=game.tick-31*MIN
tick_to(game.tick+120); tick_to(s.mt.humans.warm_until+60); eq(state().state,'frozen','a new day: budget again')
connected[1]=nick; nick.connected=true
tick_to(game.tick+120); eq(state().state,'frozen','back before the first hour: still frozen')
tick_to(s.mt.humans.since+H_TICKS+120); eq(state().state,'off','back after the first hour: unfrozen')
game=nil; defines=nil
print('mt278 human team and freeze: ok')
