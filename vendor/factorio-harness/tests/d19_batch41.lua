-- d19 batch41. Run from the harness root: lua tests/d19_batch41.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A2 (Sol seq 868-869, Bastion: platform_rearm {item: firearm-magazine} put 10-magazine requests on 5 railgun and 6 rocket
-- turrets; configure {ammo: false} refused the built turrets and Sol rebuilt all 11). Gun, rocket and railgun turrets,
-- with old requests: an item a named turret does not take is refused with each kind and its items; with no positions the
-- others are left out and named; an old request a turret cannot use is shown, and clear removes it as a deconstruction
-- planner and a cancel do (order_deconstruction on the proxy, read on 2.0.77).
do
  game={tick=1000}
  defines={inventory={turret_ammo=1,hub_main=2,artillery_turret_ammo=3}}
  local ammo={['firearm-magazine']={'bullet','a'},['piercing-rounds-magazine']={'bullet','b'},rocket={'rocket','c'},['explosive-rocket']={'rocket','d'},['railgun-ammo']={'railgun','e'}}
  prototypes={item={},get_item_filtered=function() local t={} for n,_ in pairs(ammo) do t[n]=prototypes.item[n] end return t end}
  for n,c in pairs(ammo) do prototypes.item[n]={name=n,type='ammo',stack_size=100,order=c[2],ammo_category={name=c[1]}} end
  local function proto(name,cat) return {name=name,type='ammo-turret',attack_parameters={ammo_categories={cat}},automated_ammo_count=10,get_inventory_size=function() return 1 end} end
  local P={['gun-turret']=proto('gun-turret','bullet'),['rocket-turret']=proto('rocket-turret','rocket'),['railgun-turret']=proto('railgun-turret','railgun')}
  local ordered={}
  local function request(e,item,n)
    local px={valid=true,insert_plan={{id={name=item},items={in_inventory={{inventory=1,stack=0,count=n}}}}},removal_plan={}}
    px.order_deconstruction=function(f) ordered[#ordered+1]=f; px.valid=false; e.item_request_proxy=nil; return true end
    e.item_request_proxy=px
  end
  local function turret(name,x,y,held)
    local inv={items=held or {}}
    inv.get_item_count=function(n) return inv.items[n] or 0 end
    inv.get_contents=function() local out={} for k,v in pairs(inv.items) do out[#out+1]={name=k,count=v} end return out end
    return {valid=true,name=name,type='ammo-turret',position={x=x,y=y},prototype=P[name],get_inventory=function() return inv end}
  end
  local list={turret('gun-turret',-4.5,-20.5,{['firearm-magazine']=2}),turret('rocket-turret',0.5,-20.5),turret('railgun-turret',4.5,-20.5),turret('railgun-turret',8.5,-20.5)}
  -- Bastion's old requests: firearm-magazine*10 on a rocket turret and a railgun turret
  request(list[2],'firearm-magazine',10); request(list[3],'firearm-magazine',10)
  local T=dofile('mod/agent-harness_0.1.0/turretammo.lua'){state=function() return {} end}
  local hub={valid=true,get_inventory=function() return {get_item_count=function() return 500 end} end}
  local surface={platform={name='Bastion',valid=true,hub=hub},find_entities_filtered=function() return list end}
  local asked={}
  local R=dofile('mod/agent-harness_0.1.0/platrearm.lua'){state=function() return {} end,on_platform=function() return {surface=surface} end,
    remote_entity=function(_,a) for _,e in ipairs(list) do if e.position.x==a.position.x then return e end end error('nothing there',0) end,
    deliver_one=function(_,e,items) for k,n in pairs(items) do asked[#asked+1]=e.name..' '..k..' '..n end return {requested=true} end,
    takes=function(pr) return T.takes(pr) end,unusable=function(e) return T.unusable(e) end}
  local p={force={name='player'}}
  -- named turrets that do not take it: refused, each kind with what it takes
  fails(function() R.handler(p,{platform='Bastion',positions={{x=-4.5,y=-20.5},{x=4.5,y=-20.5}},item='firearm-magazine',ammo_below=5,target_count=10}) end,
    'item firearm-magazine: not taken by railgun-turret (1) takes railgun-ammo')
  eq(#asked,0)
  -- every turret aboard: the gun turret alone, the rest left out and named
  local r=R.handler(p,{platform='Bastion',item='firearm-magazine',ammo_below=5,target_count=10})
  eq(table.concat(asked,'; '),'gun-turret firearm-magazine 8')
  eq(r.turrets,1)
  eq(r.left_out,'left out, not taking firearm-magazine: rocket-turret (1) takes rocket, explosive-rocket; railgun-turret (2) takes railgun-ammo')
  -- nothing aboard takes it: refused
  asked={}
  fails(function() R.handler(p,{platform='Bastion',positions={{x=4.5,y=-20.5}},item='rocket',ammo_below=5,target_count=10}) end,'not taken by railgun-turret (1) takes railgun-ammo')
  -- what each holds (no item): the old requests shown on their rows
  list[1].item_request_proxy=nil
  r=R.handler(p,{platform='Bastion',ammo_below=1,target_count=10})
  eq(r.rows[2].unusable_request,'firearm-magazine*10'); eq(r.rows[3].unusable_request,'firearm-magazine*10'); eq(r.rows[4].unusable_request,nil)
  -- the clear: every request on it, as the planner does
  local c=T.clear(list[3],p.force)
  eq(c.into,'firearm-magazine*10'); eq(c.out,nil); eq(list[3].item_request_proxy,nil); eq(ordered[1],p.force)
  eq(T.clear(list[3],p.force),nil,'none left')
  eq(T.unusable(list[2]),'firearm-magazine*10')
  -- a request it takes is not unusable
  request(list[4],'railgun-ammo',5); eq(T.unusable(list[4]),nil)
  game,defines,prototypes=nil,nil,nil
end
print('d19_batch41 A2 platform_rearm ammunition by turret kind, requests cleared: ok')
