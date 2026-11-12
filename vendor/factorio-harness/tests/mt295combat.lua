-- Exercise the real target scan against force/type filters, including a cease-fire.
defines={inventory={character_ammo=1},shooting={shooting_enemies=1,not_shooting=0},direction={north=0}}
local cease=false;local rival={name='rival'}
local own={name='own',get_friend=function() return false end,get_cease_fire=function(f) return f==rival and cease end}
game={tick=0,forces={own,rival}}
local foes={};local p={position={x=0,y=0},force=own,character={health=250,max_health=250},surface={}}
p.get_inventory=function() return {get_item_count=function() return 10 end} end
p.surface.find_entities_filtered=function(f)
 local types,forces={},{};for _,v in ipairs(f.type or {}) do types[v]=true end;for _,v in ipairs(f.force or {}) do forces[v]=true end
 local out={};for _,v in ipairs(foes) do if v.valid and types[v.type] and forces[v.force] then out[#out+1]=v end end;return out
end
local K=dofile('mod/agent-harness_0.1.0/kite.lua'){
 integer=function(v,d) return v or d end,position=function(v) return v end,visible=function() return true end,
 distance=function(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end,
 directions={north=0,northeast=1,east=2,southeast=3,south=4,southwest=5,west=6,northwest=7}}
local character={valid=true,type='character',name='character',position={x=5,y=0},force=rival}
local turret={valid=true,type='ammo-turret',name='gun-turret',position={x=0,y=10},force=rival}
foes={character,turret};local action=K.plan(p,{})
assert(K.tick(p,action,1)==nil and p.shooting_state.position==character.position)
character.valid=false;assert(K.tick(p,action,7)==nil and p.shooting_state.position==turret.position)
cease=true;assert(K.tick(p,action,13)=='clear')
for _,kind in ipairs{'electric-turret','fluid-turret','artillery-turret'} do
 cease=false;turret.type=kind;action=K.plan(p,{})
 assert(K.tick(p,action,20)==nil and p.shooting_state.position==turret.position,kind)
end
print('mt295 kite targets hostile characters and player turrets, respects cease-fire: ok')
