-- platform_rearm (batch24 A3, Sol request940): a platform's turrets under ammo_below, counting what is on the way,
-- get an item request up to target_count, filled from the hub as deliver's are; refills counted per platform.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok,'expected an error'); assert(tostring(err):find(text,1,true),tostring(err)) end
game={tick=1000}
defines={inventory={turret_ammo=1,hub_main=2}}
prototypes={item={['firearm-magazine']={type='ammo',stack_size=200},rocket={type='ammo',stack_size=100},['iron-plate']={type='item'}}}
local function Inv(items)
  local inv={items=items}
  inv.get_item_count=function(n) return inv.items[n] or 0 end
  inv.get_contents=function() local out={} for k,v in pairs(inv.items) do out[#out+1]={name=k,count=v} end table.sort(out,function(x,y) return x.name<y.name end) return out end
  return inv
end
local function turret(name,x,y,items)
  local e={valid=true,name=name,type='ammo-turret',position={x=x,y=y}}
  local inv=Inv(items or {})
  e.get_inventory=function(i) assert(i==1); return inv end
  e.inv=inv
  return e
end
local guns={turret('gun-turret',-6.5,-30.5,{['firearm-magazine']=4}),turret('gun-turret',6.5,-30.5,{['firearm-magazine']=150}),
  turret('rocket-turret',-13.5,-26.5,{rocket=10}),turret('gun-turret',0.5,-20.5,{})}
local hubinv=Inv({['firearm-magazine']=300,rocket=50})
local surface={platform={name='Swiftlet',valid=true,hub={valid=true,get_inventory=function(i) assert(i==2); return hubinv end}}}
surface.find_entities_filtered=function(f) eq(f.type,'ammo-turret'); return guns end
local storage={}
local delivered={}
local R=require('platrearm'){state=function() return storage end,
  on_platform=function(_,name) eq(name,'Swiftlet'); return {surface=surface} end,
  remote_entity=function(_,a) for _,g in ipairs(guns) do if g.position.x==a.position.x and g.position.y==a.position.y then return g end end error('no entity there',0) end,
  deliver_one=function(_,e,items)
    for item,n in pairs(items) do
      delivered[#delivered+1]=e.name..' '..item..' '..n
      -- the request now on the way (as deliver's item-request-proxy)
      e.item_request_proxy={valid=true,insert_plan={{id={name=item},items={in_inventory={{inventory=1,stack=0,count=n}}}}}}
    end
    return {requested=true}
  end}
local p={force='us'}
local r=R.handler(p,{platform='Swiftlet',ammo_below=20,target_count=100})
eq(r.turrets,4); eq(r.requested,2)
eq(table.concat(delivered,'; '),'gun-turret firearm-magazine 96; rocket-turret rocket 90')
-- reading order: top to bottom
eq(r.rows[1].name,'gun-turret'); eq(r.rows[1].held,4); eq(r.rows[1].requested,96)
eq(r.rows[2].held,150); eq(r.rows[2].requested,nil)
eq(r.rows[3].requested,90); eq(r.rows[4].note,'empty, and no item named: item names the ammunition')
eq(r.line,'2 of 4 turrets under 20: topped up to 100 (186 rounds asked from the hub)')
eq(r.hub[1],'the hub holds 300 firearm-magazine'); eq(r.hub[2],'the hub holds 50 rocket (fewer than the 90 asked: the rest waits for more in the hub)')
eq(r.refills,'2 item requests (186 rounds) since tick 1000')
-- Run again before the hub fills them: what is on the way counts; nothing asked twice.
delivered={}
r=R.handler(p,{platform='Swiftlet',ammo_below=20,target_count=100})
eq(r.requested,0); eq(#delivered,0); eq(r.rows[1].on_the_way,96)
-- Filled and spent again: asked again, the count goes on.
guns[1].item_request_proxy=nil; guns[1].inv.items['firearm-magazine']=10
r=R.handler(p,{platform='Swiftlet',positions={{x=-6.5,y=-30.5},{x=0.5,y=-20.5}},item='firearm-magazine',ammo_below=20,target_count=100})
eq(r.turrets,2); eq(r.requested,2); eq(table.concat(delivered,'; '),'gun-turret firearm-magazine 90; gun-turret firearm-magazine 100')
eq(r.refills,'4 item requests (376 rounds) since tick 1000')
-- Arguments.
fails(function() R.handler(p,{platform='Swiftlet',ammo_below=50,target_count=20}) end,'target_count: ammo_below..10000')
fails(function() R.handler(p,{platform='Swiftlet',ammo_below=0,target_count=20}) end,'ammo_below: 1..10000')
fails(function() R.handler(p,{platform='Swiftlet',item='iron-plate',ammo_below=5,target_count=20}) end,'item: an ammunition name')
fails(function() R.handler(p,{ammo_below=5,target_count=20}) end,'platform: the platform\'s name')
r=R.handler(p,{platform='Swiftlet',positions={{x=99,y=99}},ammo_below=5,target_count=20})
eq(r.rows[1].error,'no entity there')
print('platrearm: ok')
