-- Run from repository root: lua tests/equip.lua
-- Carried ammo (and a carried gun) goes into empty slots before combat and when the slots run dry mid-fight.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={character_guns=2,character_ammo=3},shooting={not_shooting=0,shooting_enemies=1},direction={north=0}}
prototypes={item={['pistol']={type='gun'},['submachine-gun']={type='gun'},['firearm-magazine']={type='ammo'},
  ['piercing-rounds-magazine']={type='ammo'},['shotgun-shell']={type='ammo'},['iron-plate']={type='item'}}}
-- Guns take magazines; a slot refuses what its gun cannot fire, as the engine's swap_stack does.
local fits={['firearm-magazine']=true,['piercing-rounds-magazine']=true}
local function slot(name,count) return {name=name,count=count or 0,valid_for_read=name~=nil} end
local function inventory(slots,accept)
  local inv={}
  for i,s in ipairs(slots) do
    inv[i]=s
    s.swap_stack=function(other)
      if accept and not accept(i,other.name) then return false end
      s.name,other.name=other.name,s.name; s.count,other.count=other.count,s.count
      s.valid_for_read,other.valid_for_read=s.name~=nil,other.name~=nil
      return true
    end
  end
  setmetatable(inv,{__len=function() return #slots end})
  inv.get_item_count=function() local n=0; for _,s in ipairs(slots) do if s.valid_for_read then n=n+s.count end end return n end
  inv.get_contents=function()
    local out={}
    for _,s in ipairs(slots) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end
    return out
  end
  inv.find_item_stack=function(name) for _,s in ipairs(slots) do if s.valid_for_read and s.name==name then return s end end end
  return inv
end
game={tick=0}
local guns,ammo,main
local function player(gun_slots,main_slots)
  guns=inventory(gun_slots)
  ammo=inventory({slot(),slot(),slot()},function(i,name) return guns[i].valid_for_read and fits[name] end)
  main=inventory(main_slots)
  return {get_inventory=function(i) return i==2 and guns or i==3 and ammo or nil end,get_main_inventory=function() return main end}
end
local K=dofile('mod/agent-harness_0.1.0/kite.lua'){directions={},distance=function() return 0 end,integer=function(v,d) return v or d end}
-- A pistol in slot 1, magazines carried: the stronger kind goes in.
local p=player({slot('pistol',1),slot(),slot()},{slot('iron-plate',50),slot('firearm-magazine',20),slot('piercing-rounds-magazine',5),slot('shotgun-shell',10)})
eq(K.auto_equip(p),'equipped from your inventory: 5 piercing-rounds-magazine to ammo slot 1')
eq(ammo[1].name,'piercing-rounds-magazine'); eq(K.ammo_count(p),5)
-- Nothing happens while the slots hold ammo.
eq(K.auto_equip(p),nil)
-- No gun equipped: a carried gun goes in first, then ammo that fits it; shells fit no gun here.
p=player({slot(),slot(),slot()},{slot('shotgun-shell',10),slot('submachine-gun',1),slot('firearm-magazine',20)})
eq(K.auto_equip(p),'equipped from your inventory: submachine-gun to gun slot 1, 20 firearm-magazine to ammo slot 1')
-- Nothing carried that fits: nil, and the slots stay empty.
p=player({slot('pistol',1),slot(),slot()},{slot('shotgun-shell',10)})
eq(K.auto_equip(p),nil); eq(K.ammo_count(p),0)
-- kite plans with carried ammo and says so; with none it fails naming the fix.
p=player({slot('pistol',1),slot(),slot()},{slot('firearm-magazine',20)})
p.character={valid=true,health=100,max_health=100}
local action=K.plan(p,{})
eq(action.equipped,'equipped from your inventory: 20 firearm-magazine to ammo slot 1'); eq(action.ammo_start,20)
p=player({slot('pistol',1),slot(),slot()},{})
local ok,err=pcall(K.plan,p,{})
assert(not ok and err:find('none carried that fits a gun',1,true),err)
-- Mid-fight: dry slots are refilled from carried ammo, counted into ammo_start.
p=player({slot('pistol',1),slot(),slot()},{slot('firearm-magazine',10)})
action={ammo_start=20}
eq(K.reload(p,action),true); eq(action.ammo_start,30); eq(action.reloads,1)
eq(K.reload(p,action),false)
print('equip: ok')
