-- Freight custody, side stickiness, orbital surface isolation and exact Post-stock wrecks.
local checks=0
local function eq(a,b,m) checks=checks+1;assert(a==b,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local function ok(v,m) checks=checks+1;assert(v,m or 'expected true') end
local function refused(fn,part) local fine,e=pcall(fn);ok(not fine);ok(tostring(e):find(part,1,true),tostring(e));return tostring(e) end
local function copy(v,seen)
 if type(v)~='table' or v.__engine then return v end
 seen=seen or {};if seen[v] then return seen[v] end
 local out={};seen[v]=out;for k,x in pairs(v) do out[k]=copy(x,seen) end;return out
end
local function inventory(size)
 local i={__engine=true}
 for n=1,size do
  local s={valid_for_read=false}
  s.clear=function() s.valid_for_read=false;s.count=0 end
  s.transfer_stack=function(other)
   for k,v in pairs(other) do if type(v)~='function' then s[k]=copy(v) end end
   other.clear();return true
  end
  i[n]=s
 end
 i.get_item_count=function(q)
  local total=0;for _,s in ipairs(i) do if s.valid_for_read and s.name==q.name and s.quality.name==(q.quality or 'normal') then total=total+s.count end end;return total
 end
 i.insert=function(q)
  local remain=q.count
  for _,s in ipairs(i) do
   if not s.valid_for_read or s.name==q.name and s.quality.name==(q.quality or 'normal') then
    local prior=s.valid_for_read and s.count or 0;local n=math.min(remain,100-prior)
    if n>0 then s.valid_for_read=true;s.name=q.name;s.count=prior+n;s.quality={name=q.quality or 'normal'};remain=remain-n end
   end
   if remain==0 then break end
  end
  return q.count-remain
 end
 i.remove=function(q)
  local remaining=q.count
  for _,s in ipairs(i) do if s.valid_for_read and s.name==q.name and s.quality.name==(q.quality or 'normal') then
   local n=math.min(remaining,s.count);s.count=s.count-n;remaining=remaining-n;if s.count==0 then s.clear() end
  end end
  return q.count-remaining
 end
 i.get_contents=function() local r={} for _,s in ipairs(i) do if s.valid_for_read then r[#r+1]={name=s.name,count=s.count,quality=s.quality.name} end end;return r end
 i.clear=function() for _,s in ipairs(i) do s.clear() end end
 return i
end
local S,P,K,current,seq,serial,objects,surfaces,facts,events,measured
local function reload()
 P=dofile('mod/agent-harness_0.1.0/pacts.lua'){
  state=function() return S end,team_now=function() return current end,request_id=function() return 'r'..seq end,
  fact=function(t,text) facts[#facts+1]={team=t,text=text} end,on_market=function(e) events[#events+1]=e end,
  roster=function() return {{name='one'},{name='two'}} end,market_measure=function(r) measured=r end}
 K=P.market
end
local function surface(name,index)
 local sf={name=name,index=index,valid=true,__engine=true};surfaces[name]=sf
 sf.find_non_colliding_position=function(_,p) return {x=p.x+2,y=p.y+2} end
 sf.request_path=function() serial=serial+1;return serial end
 sf.find_entities_filtered=function(q)
  local r={} for _,e in ipairs(objects) do if e.valid and e.surface==sf and e.type~='unit' and e.force.name==q.force
   and math.abs(e.position.x-(q.position.x or q.position[1]))<1 and math.abs(e.position.y-(q.position.y or q.position[2]))<1 then r[#r+1]=e end end;return r
 end
 sf.create_entity=function(a)
  serial=serial+1
  local e={name=a.name,type=a.name=='mt-shipment' and 'unit' or a.name=='character-corpse' and 'character-corpse' or 'container',
   force=type(a.force)=='string' and game.forces[a.force] or a.force or {name='neutral'},surface=sf,position=copy(a.position),
   valid=true,unit_number=serial,health=300,prototype={max_health=300,collision_box={},collision_mask={}},__engine=true}
  e.inv=inventory(a.inventory_size or 96);e.get_inventory=function() return e.inv end
  e.get_max_inventory_index=function() return 1 end
  e.destroy=function() e.valid=false end
  e.cancel_deconstruction=function() e.cancelled=true end
  e.commandable={set_command=function(c) e.command=c end}
  objects[#objects+1]=e;return e
 end
 return sf
end
local function reset(green)
 S={mt={teams={red=true,blue=true,green=true},order={'red','blue','green'},first={['chart red>blue']=0},spawns={
  red={nauvis={x=0,y=0}},blue={nauvis={x=800,y=0}},green={nauvis={x=1600,y=0}}}}}
 current='red';seq=0;serial=0;objects={};surfaces={};facts={};events={}
 defines={inventory={chest=1,character_corpse=2},command={go_to_location=1,stop=2},distraction={none=0},events={}}
 for n,k in ipairs{'on_entity_died','on_entity_damaged','on_object_destroyed','on_script_path_request_finished',
  'on_pre_player_mined_item','on_robot_pre_mined','on_player_mined_entity','on_robot_mined_entity',
  'on_marked_for_deconstruction','on_player_driving_changed_state','script_raised_destroy','on_gui_opened'} do defines.events[k]=n end
 prototypes={item={}};game={tick=0,forces={},surfaces=surfaces,get_surface=function(n) return surfaces[n] end}
 game.get_player=function(n) return {force=game.forces[n]} end
 for n,t in ipairs(S.mt.order) do
  local f={name=t,index=n,technologies={['mt-coinage']={enabled=true,researched=true},['logistic-science-pack']={researched=green~=false}},
   platforms={},relations={},get_spawn_position=function() return {x=0,y=0} end,add_chart_tag=function() end,
   is_chunk_charted=function() return false end,is_chunk_visible=function() return false end}
  f.get_cease_fire=function(o) return f.relations[o.name] or false end
  f.set_cease_fire=function(o,v) f.relations[o.name]=v end
  game.forces[t]=f
 end
 script={register_on_object_destroyed=function() serial=serial+1;return serial end}
 helpers={table_to_json=function() return '{}' end}
 surface('nauvis',1);reload()
 for n in pairs(K.PRICES) do prototypes.item[n]={stack_size=100} end
 prototypes.item['mt-coin']={stack_size=1000}
 K.tick(0)
end
local function call(t,a,args,id,actor)
 current=t;seq=id or seq+1;return K.handlers[a](actor,args or {})
end
local function tick(n) game.tick=n;K.tick(n) end
local function wallet(t) return S.mt.market.teams[t].wallet end
local function post(t) return S.mt.market.teams[t].post end
local function audit() local a=K.audit();eq(#a.faults,0,table.concat(a.faults,','));eq(a.total,a.issuance);return a end
local function sale(ap,bp)
 local src=ap and S.mt.market.teams.red.posts[ap] or post('red');src.inv.insert{name='iron-plate',count=100}
 call('red','sell',{item='iron-plate',price=20,keep=0,count=100,post=ap})
 call('blue','buy',{item='iron-plate',price=20,count=100,post=bp})
 tick(game.tick+600)
 local p=S.mt.market.pairs['blue>red'];local tx=p.transactions[#p.transactions];return tx,p,tx and tx.legs[1]
end
local function midway(l)
 K.on_event{name=defines.events.on_script_path_request_finished,id=l.path_request,path={{position={x=400,y=0}}}}
 l.entity.position={x=400,y=0};tick(game.tick+1);eq(l.entity.destructible,true)
end
local function event(l,name,killer)
 local e=l.entity;local registration=l.registration
 if name=='on_object_destroyed' then e.valid=false end
 K.on_event{name=defines.events[name],entity=e,registration_number=registration,force=killer and game.forces[killer]}
 return e
end

-- Both technology gates and persistent dispatch/reload. No distance ETA or unseen teams in the response.
reset(false);eq(K.schema('red').post,nil);eq(K.status('red').rung,'coinage')
reset();eq(K.status('red').rung,'freight');ok(K.schema('red').post);eq(K.status('red').transit_seconds,nil)
local tx,p,l=sale();eq(tx.escrow,2000);eq(l.entity.force.name,'blue');eq(l.entity.minable_flag,false);eq(l.entity.operable,false)
eq(l.entity.destructible,false);eq(wallet('red'),15000);eq(K.status('blue').inbound[1].arrival_tick,nil)
local ship=l.entity;S=copy(S);reload();p=S.mt.market.pairs['blue>red'];tx=p.transactions[1];l=tx.legs[1];eq(l.entity,ship)
midway(l);l.entity.position=copy(l.destination);tick(660);eq(tx.status,'delivered');eq(tx.escrow,0)
eq(wallet('red'),17000);eq(post('blue').inv.get_item_count{name='iron-plate'},100);eq(ship.valid,false);audit()

-- Every exit path uses the same side rule; duplicate object/death events do not pay or drop twice.
for _,exit in ipairs{'on_entity_died','on_player_mined_entity','on_robot_mined_entity','on_marked_for_deconstruction',
 'on_player_driving_changed_state','script_raised_destroy'} do
 for _,killer in ipairs{'red','blue','green','none'} do
  reset();local tx,p,l=sale();midway(l)
  local before=wallet('red');local buyer=wallet('blue');local e=event(l,exit,killer~='none' and killer or nil)
  if killer=='blue' and (exit=='on_marked_for_deconstruction' or exit=='on_player_driving_changed_state') then
   eq(tx.status,'in_transit');eq(tx.escrow,2000);ok(e.valid)
  else
   eq(tx.status,'lost');eq(tx.escrow,0);eq(l.wreck.inv.get_item_count{name='iron-plate'},100)
   eq(wallet('red'),before+(killer=='blue' and 2000 or 0));eq(wallet('blue'),buyer+(killer=='red' and 2000 or 0))
   eq(audit().destroyed,(killer=='green' or killer=='none') and 2000 or 0)
   K.loss(p,tx,l,'blue','duplicate');eq(l.wreck.inv.get_item_count{name='iron-plate'},100);audit()
   S=copy(S);reload();audit();eq(#K.status('blue').inbound,0)
  end
 end
end
reset();tx,p,l=sale();midway(l);event(l,'on_object_destroyed');eq(tx.status,'lost');eq(audit().destroyed,2000)
reset();tx,p,l=sale();midway(l);l.entity.valid=false;tick(602);eq(tx.status,'lost');eq(audit().destroyed,2000)
for _,name in ipairs{'on_pre_player_mined_item','on_robot_pre_mined'} do
 reset();tx,p,l=sale();midway(l);event(l,name,'blue');eq(tx.status,'in_transit');eq(tx.escrow,2000)
end
reset();tx,p,l=sale();event(l,'on_gui_opened','green');eq(tx.status,'in_transit','irrelevant events cannot lose cargo')

-- A former ally remains on its dispatch side; an ally acquired mid-flight remains sticky after ending.
for _,owner in ipairs{'blue','red'} do
 for _,when in ipairs{'before','during'} do
  reset()
  if when=='before' then game.forces[owner].relations.green=true end
  tx,p,l=sale();midway(l)
  if when=='during' then game.forces[owner].relations.green=true;K.capture_sides() end
  game.forces[owner].relations.green=false
  S=copy(S);reload();p=S.mt.market.pairs['blue>red'];tx=p.transactions[1];l=tx.legs[1]
  event(l,'on_entity_died','green');eq(tx.loss.side,owner=='blue' and 'buyer' or 'seller');eq(audit().destroyed,0)
 end
end
reset();tx,p,l=sale();midway(l)
S.mt.pacts={by_id={[1]={a='blue',b='green',status='active',terms={}}}}
K.capture_sides();S.mt.pacts.by_id[1].status='ended';event(l,'on_entity_died','green');eq(tx.loss.side,'buyer');audit()
reset();game.forces.blue.relations.green=true;game.forces.red.relations.green=true
tx,p,l=sale();midway(l);event(l,'on_entity_died','green');eq(tx.loss.side,'shared');eq(audit().destroyed,2000)

-- Unknown third-party identity/location is absent from all participant data and facts.
reset();tx,p,l=sale();midway(l);facts={};event(l,'on_entity_died','green')
local status=K.status('red');eq(status.fills[1].loss.killer,nil);eq(status.fills[1].loss.side,'unattributed')
eq(status.fills[1].loss.cargo.location,'uncharted');eq(S.mt.market.teams.green,nil)
for _,f in ipairs(facts) do ok(not f.text:find('green',1,true));ok(not f.text:find('400',1,true)) end
local missing=refused(function() call('red','buy',{item='iron-plate',price=20,count=1,from='green'}) end,'counterparty unavailable')
eq(missing,refused(function() call('red','buy',{item='iron-plate',price=20,count=1,from='invented'}) end,'counterparty unavailable'))

-- Native no-path fallback is fixed and private; full receiver pays only exact inserted goods.
reset();tx,p,l=sale();K.on_event{name=defines.events.on_script_path_request_finished,id=l.path_request}
eq(l.mode,'timer');eq(l.entity,nil);tick(2340);eq(tx.escrow,2000);tick(2400);eq(tx.status,'delivered');audit()
reset();tx,p,l=sale();midway(l);l.entity.position=copy(l.destination)
post('blue').inv=inventory(1);post('blue').get_inventory=function() return post('blue').inv end
post('blue').inv.insert{name='iron-plate',count=99};tick(660);eq(l.delivered,1);eq(tx.escrow,1980)
midway(l);event(l,'on_entity_died','blue');eq(l.wreck.inv.get_item_count{name='iron-plate'},99);eq(wallet('red'),17000);audit()

-- Orbital accepts own chests on planets/platforms, but matches never cross a surface.
reset();local vulcanus=surface('vulcanus',2);local platform=surface('platform-1',3)
local function forward(t,sf,x)
 local e=sf.create_entity{name='steel-chest',position={x=x,y=0},force=t}
 local a={surface=sf,position={x=x,y=0},force=game.forces[t]}
 return call(t,'post',{position={x=x,y=0}},nil,a).post,e
end
refused(function() forward('red',vulcanus,0) end,'Orbital opens')
game.forces.red.platforms={{valid=true,hub={valid=true}}};game.forces.blue.platforms={{valid=true,hub={valid=true}}}
local a,ap=forward('red',vulcanus,0);local b,bp=forward('blue',vulcanus,800)
eq(K.status('red').rung,'orbital');tx,p,l=sale(a,b);eq(l.surface,'vulcanus');midway(l)
l.entity.position=copy(l.destination);tick(660);eq(bp.inv.get_item_count{name='iron-plate'},100);eq(post('blue').inv.get_item_count{name='iron-plate'},0);audit()
local c,cp=forward('red',platform,0);eq(c,3)
call('red','sell',{post=c,item='copper-plate',price=20,count=100,keep=0});cp.inv.insert{name='copper-plate',count=100}
call('blue','buy',{post=b,item='copper-plate',price=20,count=100});tick(1200);eq(#p.transactions,1,'no cross-surface settlement')
eq(cp.inv.get_item_count{name='copper-plate'},100);audit()

-- All Post stock, including non-market stateful stacks, goes into the SAME wreck as raided coin.
reset();K.operator.mt_market{profile='full'}
local home=post('red');home.inv.insert{name='iron-plate',count=100};home.inv.insert{name='firearm-magazine',count=1,quality='rare'}
home.inv[2].ammo=3;home.inv[2].tags={custom='preserved'}
-- Fixture slots hold 100 items; reserve enough slots for the 3,750-coin raid in this mock.
local create=surfaces.nauvis.create_entity
surfaces.nauvis.create_entity=function(a) if a.inventory_size then a.inventory_size=a.inventory_size+40 end;return create(a) end
K.on_died{entity=home};home.valid=false
local rec=S.mt.market.teams.red.spills[tostring(home.unit_number)];local wreck=rec.wreck_entity
eq(wreck.inv.get_item_count{name='iron-plate'},100);eq(wreck.inv.get_item_count{name='mt-coin'},3750)
eq(wreck.inv[2].ammo,3);eq(wreck.inv[2].quality.name,'rare');eq(wreck.inv[2].tags.custom,'preserved')
eq(home.inv.get_item_count{name='iron-plate'},0);eq(wallet('red'),11250);audit()
S=copy(S);reload();tick(60);eq(post('red').inv.get_item_count{name='iron-plate'},0);eq(wreck.inv.get_item_count{name='iron-plate'},100)
eq(wreck.inv[2].ammo,3);audit()

-- Measures count short-wallet refusals, matched reference prices, losses and absent pool without agent disclosure.
reset();refused(function() call('blue','buy',{item='iron-plate',price=20,count=1000}) end,'not enough coin')
tx,p,l=sale();midway(l);event(l,'on_entity_died','green');local rows=K.measure();local row
for _,r in ipairs(rows) do if r.team=='blue' then row=r end end
eq(row.buy_attempts,2);eq(row.buy_short,1);eq(row.buy_short_share,.5);eq(row.reference_fills,1);eq(row.destroyed,2000)
eq(row.pool_in,0);eq(row.pool_out,0);eq(K.status('red').measurements,nil);eq(measured,rows)
-- A busy native pathfinder retries without making the cargo disappear or inferring distance.
reset();local production={['iron-plate']=10,['copper-plate']=20,['steel-plate']=3}
game.forces.blue.get_item_production_statistics=function() return {get_input_count=function(n) return production[n] end} end
tx,p,l=sale();K.measure();production['steel-plate']=13;game.tick=game.tick+3600
for _,row in ipairs(K.measure()) do if row.team=='blue' then
 eq(row.plate_coin_per_minute,1000);eq(row.escrow,2000);eq(row.accounted_coin,15000);eq(row.accounted_coin_minutes_of_plate_output,15)
end end
reset();tx,p,l=sale();local original=l.path_request;local e=l.entity
K.on_event{name=defines.events.on_script_path_request_finished,id=original,try_again_later=true}
eq(l.entity,e);eq(l.mode,'path_pending');tick(659);eq(l.path_request,nil)
tick(660);ok(l.path_request~=original);eq(l.entity,e)
K.on_event{name=defines.events.on_script_path_request_finished,id=original};eq(l.entity,e)
midway(l);tick(game.tick+1800);eq(l.mode,'path_pending');eq(l.entity,e)
K.on_event{name=defines.events.on_script_path_request_finished,id=l.path_request};eq(l.mode,'timer');eq(e.valid,false);audit()

-- A swap's surviving manifest continues after the other manifest is lost, without coin changes.
reset();post('red').inv.insert{name='iron-plate',count=100};post('blue').inv.insert{name='copper-plate',count=100}
call('red','offer',{give={item='iron-plate',count=100},get={item='copper-plate',count=100}})
call('blue','offer',{give={item='copper-plate',count=100},get={item='iron-plate',count=100}})
tick(600);p=S.mt.market.pairs['blue>red'];tx=p.transactions[1];l=tx.legs[1];local other=tx.legs[2]
midway(l);event(l,'on_entity_died','green');eq(tx.status,'in_transit');eq(l.loot,100);eq(other.loss,nil)
midway(other);other.entity.position=copy(other.destination);tick(660)
eq(tx.status,'lost');eq(other.delivered,100);eq(audit().destroyed,0)

-- Green science can precede Coinage; Post suggestions still point to an available action.
reset();game.forces.red.technologies['mt-coinage'].researched=false
local id,chest=forward('red',surfaces.nauvis,20);eq(id,2);eq(K.open_action('red','market'),false)
chest.valid=false
local replacement=surfaces.nauvis.create_entity{name='steel-chest',force='red',position={x=20,y=0}}
local restored=call('red','post',{position={x=20,y=0}},nil,{surface=surfaces.nauvis,position={x=20,y=0}})
eq(restored.post,id);eq(restored.restored,true);eq(restored.next.action,'status');eq(S.mt.market.teams.red.posts[id],replacement)
print('mt303 freight/orbital: '..checks..' checks passed')
