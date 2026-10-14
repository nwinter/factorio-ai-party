-- Run from repository root: lua tests/turretammo.lua
-- Ammo requests on turret ghosts (turretammo.lua; Astra, shift10: "15+ guns repeatedly rebuilt empty and destroyed
-- while bots waste gun stock"): the insert plan a turret ghost gets, which ammo and how much, a blueprint's own
-- request kept, and the ghost of a turret that died requesting the ammo it held.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok,'expected a failure'); assert(tostring(err):find(text,1,true),tostring(err)) end
defines={inventory={turret_ammo=7,artillery_turret_ammo=9}}
local items={
  ['firearm-magazine']={type='ammo',order='a[basic-clips]-a[firearm-magazine]',stack_size=200,ammo_category={name='bullet'}},
  ['piercing-rounds-magazine']={type='ammo',order='a[basic-clips]-b[piercing-rounds-magazine]',stack_size=200,ammo_category={name='bullet'}},
  ['rocket']={type='ammo',order='d[rocket-launcher]-a[basic]',stack_size=200,ammo_category={name='rocket'}},
  ['artillery-shell']={type='ammo',order='d[explosive-cannon-shell]-d[artillery]',stack_size=1,ammo_category={name='artillery-shell'}},
  ['iron-plate']={type='item',order='b',stack_size=100}}
local filtered=0
prototypes={item=items,get_item_filtered=function(f)
  filtered=filtered+1; eq(f[1].filter,'type'); eq(f[1].type,'ammo')
  local out={} for n,i in pairs(items) do if i.type=='ammo' then out[n]=i end end return out end}
local function turret(name,type,cats,count,slots)
  return {name=name,type=type,attack_parameters=cats and {ammo_categories=cats} or nil,automated_ammo_count=count,
    get_inventory_size=function(inv) return slots end}
end
local gun=turret('gun-turret','ammo-turret',{'bullet'},10,1)
local rocketeer=turret('rocket-turret','ammo-turret',{'rocket'},10,2)
local artillery=turret('artillery-turret','artillery-turret',{'artillery-shell'},5,1)
local laser=turret('laser-turret','electric-turret',nil,nil,0)
local flamer=turret('flamethrower-turret','fluid-turret',nil,nil,0)
storage={}
local T=dofile('mod/agent-harness_0.1.0/turretammo.lua'){state=function() return storage end}
local force={name='player'}
local held_in={}   -- the logistic network over x < 100: what it holds
local network={get_item_count=function(name) return held_in[name] or 0 end}
local surface={index=1,find_logistic_network_by_position=function(pos,f) eq(f,force); return pos.x<100 and network or nil end}
local function ghost(proto,x,y,plan)
  return {valid=true,type='entity-ghost',ghost_name=proto.name,ghost_prototype=proto,position={x=x,y=y},surface=surface,force=force,insert_plan=plan or {}}
end

-- 1. What a turret takes: its ammo items in prototype order, the default count (automated_ammo_count), its slots.
local t=T.takes(gun)
eq(t.inventory,7); eq(#t.items,2); eq(t.items[1],'firearm-magazine'); eq(t.items[2],'piercing-rounds-magazine'); eq(t.count,10); eq(t.slots,1)
eq(T.takes(artillery).inventory,9); eq(T.takes(artillery).items[1],'artillery-shell')
eq(T.takes(laser),nil,'a laser turret takes no ammo items'); eq(T.takes(flamer),nil,'a flamethrower takes fluid'); eq(T.takes(nil),nil)
eq(filtered,1,'the ammo items are read once')

-- 2. The default: what the network at the ghost holds most of; with none there (or no network), the first.
held_in={['firearm-magazine']=400,['piercing-rounds-magazine']=50}
local c=T.choose(t,surface,force,{x=10,y=0})
eq(c.name,'firearm-magazine'); eq(c.count,10); eq(c.network_holds,400)
held_in={['piercing-rounds-magazine']=50}
c=T.choose(t,surface,force,{x=10,y=0}); eq(c.name,'piercing-rounds-magazine'); eq(c.network_holds,50)
c=T.choose(t,surface,force,{x=500,y=0}); eq(c.name,'firearm-magazine','no network covers it'); eq(c.network_holds,nil)
-- A name and a count; a name the turret does not take gives its default; the count is at most what its slots hold.
c=T.choose(t,surface,force,{x=10,y=0},{name='firearm-magazine',count=25}); eq(c.name,'firearm-magazine'); eq(c.count,25); eq(c.network_holds,0)
c=T.choose(t,surface,force,{x=10,y=0},'rocket'); eq(c.name,'piercing-rounds-magazine','rockets do not fit a gun turret')
eq(T.choose(t,surface,force,{x=10,y=0},{count=500}).count,200,'one slot of 200')
eq(T.choose(t,surface,force,{x=10,y=0},false),nil,'ammo=false: none')
-- What it held (a turret that died) comes before the network's choice; a call's name before that.
eq(T.choose(t,surface,force,{x=10,y=0},nil,'firearm-magazine').name,'firearm-magazine')
eq(T.choose(t,surface,force,{x=10,y=0},'piercing-rounds-magazine','firearm-magazine').name,'piercing-rounds-magazine')

-- 3. The request: an insert plan into the ammo slots.
held_in={['firearm-magazine']=400}
local g=ghost(gun,10,0)
c=T.request(g)
eq(c.name,'firearm-magazine'); eq(c.count,10)
eq(#g.insert_plan,1); eq(g.insert_plan[1].id.name,'firearm-magazine'); eq(g.insert_plan[1].id.quality,'normal')
local at=g.insert_plan[1].items.in_inventory
eq(#at,1); eq(at[1].inventory,7); eq(at[1].stack,0); eq(at[1].count,10)
-- A ghost that requests ammo already (a blueprint's) keeps it; other requests stay and the ammo is added.
local kept=ghost(gun,12,0,{{id={name='piercing-rounds-magazine'},items={in_inventory={{inventory=7,stack=0,count=5}}}}})
local none,why=T.request(kept); eq(none,nil); eq(why,'kept'); eq(#kept.insert_plan,1); eq(kept.insert_plan[1].id.name,'piercing-rounds-magazine')
local other=ghost(gun,14,0,{{id={name='iron-plate'},items={in_inventory={{inventory=3,stack=0,count=1}}}}})
T.request(other); eq(#other.insert_plan,2); eq(other.insert_plan[2].id.name,'firearm-magazine')
-- More than a slot holds: a stack per slot.
local r=ghost(rocketeer,20,0)
c=T.request(r,{count=300}); eq(c.count,300)
at=r.insert_plan[1].items.in_inventory; eq(#at,2); eq(at[1].count,200); eq(at[2].stack,1); eq(at[2].count,100)
-- Not a turret, not a ghost, ammo=false, the game refusing the plan.
local chest={valid=true,type='entity-ghost',ghost_prototype={type='container'},position={x=0,y=0},surface=surface,force=force}
none,why=T.request(chest); eq(none,nil); eq(why,'not a turret')
none,why=T.request({valid=true,type='container'}); eq(why,'not a turret')
none,why=T.request(ghost(gun,16,0),false); eq(why,'none')
local refusing=setmetatable({},{__index=ghost(gun,18,0),__newindex=function(_,k) error('refused '..k) end})
none,why=T.request(refusing); eq(none,nil); assert(why:find('refused insert_plan',1,true),why)
-- The rows a call reports.
local rows={}
T.add(rows,{name='firearm-magazine',count=10,network_holds=400}); T.add(rows,{name='firearm-magazine',count=10,network_holds=390})
T.add(rows,{name='firearm-magazine',count=20})
eq(#rows,2); eq(rows[1].ghosts,2); eq(rows[1].network_holds,400); eq(rows[2].count,20)
-- What a call's ammo may be.
T.check(nil); T.check(false); T.check('firearm-magazine'); T.check({count=5}); T.check({name='rocket',count=1})
fails(function() T.check('iron-plate') end,'ammo: not an ammo item: iron-plate')
fails(function() T.check('nothing') end,'not an ammo item: nothing')
fails(function() T.check({count=0}) end,'whole number of at least 1')
fails(function() T.check({count=1.5}) end,'whole number of at least 1')
fails(function() T.check(7) end,'ammo is an ammo item name')

-- 4. One of our turrets died holding piercing rounds: on the next tick its ghost requests them.
game={tick=1000}
local dead_ghost=ghost(gun,40.5,0.5)
local finds={}
surface.find_entities_filtered=function(f)
  finds[#finds+1]=f; eq(f.type,'entity-ghost'); eq(f.ghost_name,'gun-turret'); eq(f.force,'player'); eq(f.limit,1); eq(f.radius,0.5)
  return f.position.x==40.5 and {dead_ghost} or {}
end
game.get_surface=function(i) eq(i,1); return surface end
local function died(proto,x,y,contents)
  return {valid=true,name=proto.name,prototype=proto,position={x=x,y=y},surface=surface,force=force,
    get_inventory=function(i) eq(i,7); return {get_contents=function() return contents end} end}
end
T.on_died(died(gun,40.5,0.5,{{name='piercing-rounds-magazine',count=3,quality='normal'}}))
T.on_died(died(gun,60.5,0.5,{}))          -- its force does not rebuild the dead: no ghost
T.on_died(died(laser,70,0,{}))            -- takes no ammo items: not noted
eq(#storage.turret_deaths,2)
T.tick(1000); eq(#finds,0,'the ghost comes after the death: the next tick'); eq(#storage.turret_deaths,2)
T.tick(1001)
eq(storage.turret_deaths,nil); eq(#finds,2)
eq(dead_ghost.insert_plan[1].id.name,'piercing-rounds-magazine','the ammo it held'); eq(dead_ghost.insert_plan[1].items.in_inventory[1].count,10)
eq(storage.turret_ammo.requested,1); eq(storage.turret_ammo.no_ghost,1); eq(storage.turret_ammo.last.item,'piercing-rounds-magazine')
-- Its ghost requested ammo already (the game kept a request): kept, counted.
dead_ghost.insert_plan={{id={name='firearm-magazine'},items={in_inventory={{inventory=7,stack=0,count=10}}}}}
T.on_died(died(gun,40.5,0.5,{})); game.tick=1002; T.tick(1003)
eq(storage.turret_ammo.kept,1); eq(dead_ghost.insert_plan[1].id.name,'firearm-magazine')
-- At most 64 deaths wait at once (a big attack): the rest are not noted.
for i=1,70 do T.on_died(died(gun,100+i,0,{})) end
eq(#storage.turret_deaths,64)
print('turretammo: ok')
