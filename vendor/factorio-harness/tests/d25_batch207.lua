-- d25 batch207. Run from the harness root: lua tests/d25_batch207.lua
-- QT1 (Sol #2344: Kestrel IVb plan14's pod_landed wait for 750 uranium magazines met at the pod's land tick 62193645;
-- delivery_watch 469 saw the pod received at 62193727): a pod counts once its cargo is delivered, the tick after
-- on_cargo_pod_delivered_cargo (podlog.tick), not at on_cargo_pod_finished_descending.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=62060809}
prototypes={item={['uranium-rounds-magazine']={}},quality={normal={},uncommon={},rare={},epic={},legendary={}}}
defines={events={on_cargo_pod_started_ascending=1,on_cargo_pod_finished_ascending=2,on_cargo_pod_finished_descending=3,on_cargo_pod_delivered_cargo=4},
  inventory={cargo_unit=1}}

local state={}
local podlog=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return state end}
local function inv(stacks) return {get_contents=function() return stacks end,get_item_count=function() return 0 end,count_empty_stacks=function() return 80 end} end
local aquilo={name='aquilo'}
local pad={valid=true,type='cargo-landing-pad',position={x=-8,y=-22},surface=aquilo,get_inventory=function() return inv({}) end}
local hub={valid=true,type='space-platform-hub',surface={platform={valid=true,name='Kestrel IVb',space_location={name='aquilo'}}}}
local function pod(unit,count)
  return {valid=true,unit_number=unit,position={x=-8,y=-22},surface=aquilo,cargo_pod_origin=hub,cargo_pod_destination={station=pad},
    get_inventory=function() return inv({{name='uranium-rounds-magazine',quality='normal',count=count}}) end}
end
local function event(name,p) podlog.on_event({name=defines.events[name],cargo_pod=p,tick=game.tick}) end
local since=62060809
do
  local a=pod(41052486,200)
  game.tick=62190000; event('on_cargo_pod_started_ascending',a)
  game.tick=62193645; event('on_cargo_pod_finished_descending',a)
  -- descending done, cargo not delivered: not counted
  local r=podlog.landed_from('Kestrel IVb',since,'uranium-rounds-magazine')
  eq(r.pods,0,'a landed pod before its delivery'); eq(r.items,0); eq(r.landing,1,'landed, cargo not delivered yet')
  game.tick=62193726; event('on_cargo_pod_delivered_cargo',a)
  eq(podlog.landed_from('Kestrel IVb',since,'uranium-rounds-magazine').pods,0,'the delivered_cargo tick: the pad takes it the tick after')
  game.tick=62193727; podlog.tick(game.tick)
  r=podlog.landed_from('Kestrel IVb',since,'uranium-rounds-magazine')
  eq(r.pods,1,'delivered'); eq(r.items,200); eq(r.landing,0); eq(r.last.delivered,62193727); eq(r.last.landed,62193645)
  -- since between the land tick and the delivery: the cargo delivered after it counts
  eq(podlog.landed_from('Kestrel IVb',62193700,'uranium-rounds-magazine').items,200,'delivered after since')
  eq(podlog.landed_from('Kestrel IVb',62193727,'uranium-rounds-magazine').items,0,'delivered at since does not count')
end

-- the wait: not met at the land tick, met at the receipt tick; saw names both
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
  receipts=function() return {} end,pods_landed=function(name,s,item,q) return podlog.landed_from(name,s,item,q) end}
local p={force={platforms={{valid=true,name='Kestrel IVb'}}}}
do
  local b=pod(41052490,200)
  game.tick=62194000; event('on_cargo_pod_started_ascending',b)
  game.tick=62196000; event('on_cargo_pod_finished_descending',b)
  local c={['until']='pod_landed',platform='Kestrel IVb',item='uranium-rounds-magazine',at_least=400,since_tick=since}
  C.validate(c)
  local met,saw=C.check(p,c,nil,{})
  eq(met,false,'the second pod landed, not delivered')
  eq(saw,'1 pod from Kestrel IVb landed and delivered since tick 62060809 with 200 uranium-rounds-magazine (the last delivered at tick 62193727, landing pad (-8,-22) on aquilo); 1 more landed, cargo not delivered yet')
  game.tick=62196081; event('on_cargo_pod_delivered_cargo',b)
  game.tick=62196082; podlog.tick(game.tick)
  met,saw=C.check(p,c,nil,{})
  eq(met,true,'met once delivered')
  eq(saw,'2 pods from Kestrel IVb landed and delivered since tick 62060809 with 400 uranium-rounds-magazine (the last delivered at tick 62196082, landing pad (-8,-22) on aquilo)')
end

-- a journey that landed before this runtime kept delivery ticks counts at its land tick
do
  local l=state.podlog.by.aquilo
  state.podlog.seq=state.podlog.seq+1
  table.insert(l,1,{id=0,platform='Kestrel IVb',sent=62100000,landed=62100900,dest='landing pad (-8,-22)',items={['uranium-rounds-magazine']=150}})
  eq(state.podlog.delivered_since,62190000,'set at the first pod event')
  local r=podlog.landed_from('Kestrel IVb',since,'uranium-rounds-magazine')
  eq(r.pods,3); eq(r.items,550)
end
print('d25_batch207 QT1 pod_landed counts a pod at its cargo delivery: ok')

-- QT2 (Sol #2345: "Meridian-V 3 turrets low (under 10 rounds), turrets hold 396 rounds" counted magazines): the low
-- threshold and the turrets' totals in magazines (ammo items), the rounds left beside them (inventory_rounds), the
-- low turrets' own counts; empty and feed alerts keep their tests.
do
  game={tick=100000}
  defines={space_platform_state={on_the_path=4,waiting_at_station=6},inventory={turret_ammo=3,hub_main=1}}
  prototypes={item={['uranium-rounds-magazine']={type='ammo',magazine_size=10},['rocket']={type='ammo',magazine_size=1}}}
  local V=dofile('mod/agent-harness_0.1.0/vehicles.lua'){}
  local st={}
  local turrets={}
  -- a turret's ammo slot as the game has it: count items, the first part-used (ammo: rounds left in it)
  local function turret(name,item,count,ammo)
    local stack={valid_for_read=count>0,name=item,quality={name='normal'},count=count,ammo=ammo}
    local inv={valid=true,stack}
    inv.is_empty=function() return stack.count==0 end
    inv.get_item_count=function() return stack.count end
    local t={valid=true,name=name,type='ammo-turret',position={x=#turrets*3,y=0},get_inventory=function() return inv end}
    turrets[#turrets+1]=t
    return t
  end
  local surface={index=7,name='platform-7'}
  surface.count_entities_filtered=function() return #turrets end
  surface.find_entities_filtered=function() return turrets end
  local hub={valid=true,health=1000,max_health=1000,get_inventory=function() return {get_contents=function() return {{name='uranium-rounds-magazine',count=200}} end} end}
  local pl={valid=true,index=7,name='Meridian-V',state=6,surface=surface,force={name='player',index=1},hub=hub}
  local force={platforms={pl}}
  pl.force=force
  game.forces={player=force}
  local A=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end,who=function() return 'sol' end,agents=function() return {} end,
    inventory_rounds=V.inventory_rounds}
  turret('gun-turret','uranium-rounds-magazine',7,8); turret('gun-turret','uranium-rounds-magazine',7,10); turret('gun-turret','uranium-rounds-magazine',9,8)
  turret('gun-turret','uranium-rounds-magazine',10,10); turret('gun-turret','uranium-rounds-magazine',0)
  local d=A.defense(pl)
  eq(d.turrets,'5 gun-turrets: 1 empty, 3 low (under 10 magazines: 7 (68 rounds), 7 (70 rounds), 9 (88 rounds))')
  eq(d.ammo,'turrets hold 33 magazines (326 rounds), the hub uranium-rounds-magazine 200')
  -- the alert line to the platform's creator: the same words
  st.platform_alerts={by={[7]={minutes={},workers={},seq=0,creator='sol'}}}
  local lines=A.lines({force=force},{})
  local line
  for _,l in ipairs(lines) do if l:find('empty',1,true) then line=l end end
  eq(line,'platform Meridian-V (surface platform-7): 1 of 5 gun-turrets empty, 3 low (under 10 magazines: 7 (68 rounds), 7 (70 rounds), 9 (88 rounds)); turrets hold 33 magazines (326 rounds), the hub uranium-rounds-magazine 200')
  -- without the rounds read (a failed one): items alone, from the scan
  local A2=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end,who=function() return 'sol' end,agents=function() return {} end,
    inventory_rounds=function() error('no read') end}
  d=A2.defense(pl)
  eq(d.turrets,'5 gun-turrets: 1 empty, 3 low (under 10 magazines)'); eq(d.ammo,'turrets hold 33 magazines, the hub uranium-rounds-magazine 200')
  -- rocket turrets: rockets, one round each (no rounds named)
  for i=#turrets,1,-1 do turrets[i]=nil end
  turret('rocket-turret','rocket',4); turret('rocket-turret','rocket',12)
  local A3=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end,who=function() return 'sol' end,agents=function() return {} end,
    inventory_rounds=V.inventory_rounds}
  d=A3.defense(pl)
  eq(d.turrets,'2 rocket-turrets: 0 empty, 1 low (under 10 rockets: 4)'); eq(d.ammo,'turrets hold 16 rockets, the hub uranium-rounds-magazine 200')
end
print('d25_batch207 QT2 platform ammo counts in magazines with the rounds left: ok')
