-- Run from the harness root: lua tests/d24_batch181.lua
-- d24 batch181 QX1 (Sol #2013): the asteroid watch's by_name splits the asteroids in view at the first read from those
-- first seen later, and of those the fragments (first seen near where an asteroid whose dying effect creates that name
-- died: by name, place and time, as the game links them by no event); the headline says when the tracked set reached
-- its cap and untracked is defined; each ammo turret's rounds are read every 15 ticks, a change split into rounds fired
-- and items loaded (exact under the magazine size; a magazine of 1 with a load and no hit is unsure), beside the
-- platform's consumed ammunition from the item production statistics.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=1000}
defines={inventory={turret_ammo=1}}
local box={collision_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}}
prototypes={entity={['big-oxide-asteroid']={collision_box=box.collision_box,dying_trigger_effect={{type='create-explosion',entity_name='x'},
    {type='create-entity',entity_name='medium-oxide-asteroid',offsets={{-1,-0.25},{0,-0.5},{1,-0.25}}}}},
  ['medium-oxide-asteroid']=box,['small-oxide-asteroid']=box,
  ['gun-turret']={attack_parameters={cooldown=2.5}},['rocket-turret']={attack_parameters={cooldown=10}}},
  item={['firearm-magazine']={magazine_size=10},
    rocket={magazine_size=1,get_ammo_type=function() return {action={{type='direct',action_delivery={{type='projectile'}}}}} end},
    ['railgun-ammo']={magazine_size=1,get_ammo_type=function() return {action={{type='line',action_delivery={{type='instant'}}}}} end}},
  get_item_filtered=function() return {['firearm-magazine']=true,rocket=true,['railgun-ammo']=true} end}
prototypes.entity['railgun-turret']={attack_parameters={cooldown=97}}
local function foundation(x,y) return x>=0 and x<=19 and y>=0 and y<=39 end
local surface={index=7,name='platform-7',platform={name='Asterion'}}
function surface.get_chunks() local l={{area={left_top={x=0,y=0},right_bottom={x=32,y=32}}},{area={left_top={x=0,y=32},right_bottom={x=32,y=64}}}}; local i=0; return function() i=i+1; return l[i] end end
function surface.count_tiles_filtered(f)
  local a=f.area; local lt,rb=a.left_top or a[1],a.right_bottom or a[2]
  for x=math.floor(lt.x or lt[1]),math.ceil(rb.x or rb[1])-1 do for y=math.floor(lt.y or lt[2]),math.ceil(rb.y or rb[2])-1 do if foundation(x,y) then return 1 end end end
  return 0
end
function surface.get_tile(x,y) return {name=foundation(x,y) and 'space-platform-foundation' or 'empty-space'} end
game.get_surface=function(i) return i==7 and surface or nil end
local asts={}
local function asteroid(u,name,x,y) local e={valid=true,unit_number=u,name=name,type='asteroid',surface=surface,position={x=x,y=y}}; asts[u]=e; return e end
-- a gun turret (magazines of 10, 2.5-tick cooldown as world n's with its shooting speed bonus: at most 6 rounds in 15 ticks, read every 15) and a rocket turret (rockets, magazine 1)
local function turret(u,name,x,item,count,left)
  local t={valid=true,unit_number=u,name=name,type='ammo-turret',position={x=x,y=2},surface=surface,force={name='player'},item=item,count=count,left=left}
  -- live as a LuaInventory is
  local stack=setmetatable({quality={name='normal'}},{__index=function(_,k) if k=='valid_for_read' then return t.count>0 elseif k=='name' then return t.item elseif k=='count' then return t.count elseif k=='ammo' then return t.left end end})
  local inv={stack}
  t.get_inventory=function() return inv end
  return t
end
local gun=turret(900,'gun-turret',-1,'firearm-magazine',5,10)
local rk=turret(901,'rocket-turret',21,'rocket',10,1)
local rail=turret(902,'railgun-turret',10,'railgun-ammo',10,1)
surface.find_entities_filtered=function(f)
  if f.type=='asteroid' then local out={}; for _,e in pairs(asts) do if e.valid then out[#out+1]=e end end; table.sort(out,function(a,b) return a.unit_number<b.unit_number end); return out end
  return {gun,rk,rail}
end
-- the platform's consumed counts (get_output_count at every quality, as qflow.count_by reads them)
local consumed={['firearm-magazine']=500,rocket=40}
local force={name='player',get_item_production_statistics=function() return {} end}
game.forces={player=force}
local st={}
local A=require('asteroidwatch'){state=function() return st end,on_platform=function() return {surface=surface,force=force} end,
  count_by=function(stats,n,c) eq(c,'output'); return consumed[n] or 0, nil end}
A.MAX_ASTEROIDS=4
local start=A.handler({index=1},{platform='Asterion',asteroids=true,seconds=60})
eq(start.turrets,3)
-- the first read: 2 in view
asteroid(1,'big-oxide-asteroid',5,-30); asteroid(2,'small-oxide-asteroid',30,-30)
A.tick(1000)
-- asteroid 1 dies at (5,-25); its 3 fragments appear round it; a new big one comes in at the front edge
game.tick=1010; asts[1].position={x=5,y=-25}
A.on_died({entity=asts[1],cause=gun,tick=1010}); asts[1].valid=false
asteroid(3,'medium-oxide-asteroid',4,-25.3); asteroid(4,'medium-oxide-asteroid',5,-25.6); asteroid(5,'medium-oxide-asteroid',6,-25.3)
asteroid(6,'big-oxide-asteroid',10,-60)
-- the gun fires 3 rounds (50 -> 47); the rocket turret is loaded one rocket and fires one: 10 -> 10, its hit shows the shot
gun.count,gun.left=5,7
A.on_damaged({entity=asts[2],cause=rk,final_damage_amount=10,tick=1012})
-- the railgun turret (instant: its hit lands as it fires) is loaded one and fires one: 10 -> 10
A.on_damaged({entity=asts[2],cause=rail,final_damage_amount=10,tick=1013})
game.tick=1015; A.tick(1015)
-- next read: the gun takes a magazine and fires 2 (47 -> 55: loaded 1, fired 2); the rocket turret is loaded one with no hit (unsure)
gun.count,gun.left=6,5
rk.count=11
consumed['firearm-magazine'],consumed.rocket=500,41
game.tick=1030; A.tick(1030)
local r=A.handler({index=1},{platform='Asterion',asteroids=true})
-- cohorts
local by={}
for _,t in ipairs(r.by_name) do by[t.name]=t end
eq(by['big-oxide-asteroid'].in_first_sample,1); eq(by['big-oxide-asteroid'].later,1); eq(by['big-oxide-asteroid'].later_other,1); eq(by['big-oxide-asteroid'].later_fragments,0)
eq(by['medium-oxide-asteroid'].in_first_sample,0); eq(by['medium-oxide-asteroid'].later_fragments,3,'one of them untracked: counted the same'); eq(by['medium-oxide-asteroid'].later_other,0)
eq(by['small-oxide-asteroid'].in_first_sample,1)
local frag=0
for _,t in ipairs(r.by_name) do frag=frag+(t.later_fragments or 0) end
has(table.concat(r.by_name_lines,' | '),'medium-oxide-asteroid: 3 seen (1 untracked; 0 in view at the first read, 3 first seen later: 3 fragments, 0 other)')
has(r.cohort_note,'told by name, place and time')
-- the cap
eq(r.capped,true); eq(r.capped_at_tick,1015); eq(r.capped_at_s,0.3); eq(r.tracked,4); eq(r.untracked,2)
has(r.line,'; tracked capped at 4 from +0.3s: the 2 first seen after that are counted (unique asteroids, each once), not followed')
has(r.untracked_unit,'each counted once however many reads saw it')
-- the turrets' rounds
local rows={}
for _,t in ipairs(r.turrets) do rows[t.name]=t end
local g=rows['gun-turret']
eq(g.rounds_start,50); eq(g.rounds_end,55); eq(g.rounds_used,5); eq(g.ammo_loaded,1); eq(g.ammo_used,0.5); eq(g.exact,true); eq(g.unsure_reads,0); eq(g.reads,2,"the start read its rounds")
local k=rows['rocket-turret']
eq(k.rounds_used,0,'a rocket\'s hit does not date its shot'); eq(k.ammo_loaded,1); eq(k.unsure_reads,2); eq(k.exact,nil)
eq(k.rounds_used_most,4,'each unsure read could hide as many shots as fit in 15 ticks at a 10-tick cooldown: 2'); eq(g.rounds_used_most,nil)
local rg=rows['railgun-turret']
eq(rg.rounds_used,1,'an instant hit shows the shot'); eq(rg.ammo_loaded,1); eq(rg.unsure_reads,0); eq(rg.exact,true)
has(r.ammo_note,'exact (unsure_reads 0) while the most rounds the turret fires between two reads')
-- the platform's consumed ammunition beside the turrets' reads
local c={}
for _,x in ipairs(r.platform_consumed) do c[x.ammo]=x end
eq(c['rocket@normal'].consumed,1); eq(c['rocket@normal'].turrets_used,0); eq(c['railgun-ammo@normal'].turrets_used,1); eq(c['firearm-magazine@normal'].turrets_used,0.5); eq(c['firearm-magazine@normal'].consumed,0)
has(table.concat(r.platform_consumed_lines,' | '),'rocket@normal: 1 consumed on Asterion (item production statistics), 0 used by the turrets\' reads')
print('d24_batch181 QX1 asteroid watch: cohorts, fragments, the cap, rounds by turret, consumed: ok')
-- the dying effect read: what a big oxide asteroid makes
eq(A.kids_of('big-oxide-asteroid')['medium-oxide-asteroid'],3); eq(A.kids_of('small-oxide-asteroid'),false)
print('d24_batch181 QX1 fragments from the dying effect: ok')
-- how often each turret is read: the gun every 15 ticks (12 rounds in 30 would reach its magazine of 10); a
-- railgun-like turret with a 97-tick cooldown and magazines of 1 every 60 (one shot at most)
eq(st.asteroid_watch[1].turrets[900].every,15)
prototypes.entity['rocket-turret'].attack_parameters.cooldown=97
st.asteroid_watch[1].rate=nil
rk.count=12; game.tick=1045; A.tick(1045)
eq(st.asteroid_watch[1].turrets[901].every,60)
print('d24_batch181 QX1 read intervals: ok')
game,defines,prototypes=nil,nil,nil
