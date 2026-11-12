-- Deterministic adversarial suites; engine save/load acceptance is separately required.
local checks=0
local function eq(a,b,m) checks=checks+1;assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function ok(v,m) checks=checks+1;assert(v,m) end
local function refused(fn,msg) local fine,e=pcall(fn);ok(not fine,'expected refusal');ok(tostring(e):find(msg,1,true),tostring(e));return tostring(e) end
local s,P,K,teamname,requestid,serial,made,spilled,forces,surface,news
local function inventory()
 local i={items={},capacity=100000}
 i.get_item_count=function(q) return i.items[q.name..'@'..(q.quality or 'normal')] or 0 end
 i.insert=function(q)
  local total=0;for _,n in pairs(i.items) do total=total+n end
  local n=math.min(q.count,math.max(0,i.capacity-total));local k=q.name..'@'..(q.quality or 'normal');i.items[k]=(i.items[k] or 0)+n;return n
 end
 i.remove=function(q) local n=math.min(q.count,i.get_item_count(q));local k=q.name..'@'..(q.quality or 'normal');i.items[k]=(i.items[k] or 0)-n;return n end
 return i
end
local function reload()
 P=dofile('mod/agent-harness_0.1.0/pacts.lua'){state=function() return s end,team_now=function() return teamname end,
 request_id=function() return requestid end,on_market=function(e) news[#news+1]=e end,
 as_team=function(t,fn) local prev=teamname;teamname=t;local r=fn();teamname=prev;return r end,fact=function() end};K=P.market
end
local function reset(contact,coinage)
 defines={inventory={chest=1}};prototypes={item={}};forces={};made={};spilled={};news={};serial=0;requestid='initial';teamname='red'
 surface={index=1,name='nauvis',find_non_colliding_position=function(_,at) return at end}
 surface.create_entity=function(a)
  local i=inventory();local e={name=a.name,valid=true,position=a.position,force=a.force,surface=surface,unit_number=#made+1}
  e.get_inventory=function() return i end;e.inv=i;made[#made+1]=e;return e
 end
 surface.spill_item_stack=function(a) local e={valid=true,stack={valid_for_read=true,count=a.stack.count,name=a.stack.name}};spilled[#spilled+1]=e;return {e} end
 for idx,t in ipairs{'red','blue','green'} do forces[t]={name=t,index=idx,technologies={['mt-coinage']={enabled=false,researched=coinage or false}},add_chart_tag=function() end,get_spawn_position=function() return {x=0,y=0} end} end
 game={tick=0,forces=forces,get_surface=function() return surface end}
 s={mt={teams={red=true,blue=true,green=true},order={'red','blue','green'},first={},spawns={red={nauvis={x=0,y=0}},blue={nauvis={x=100,y=0}},green={nauvis={x=200,y=0}}}}}
 if contact then s.mt.first['chart red>blue']=0 end
 reload();for name in pairs(K.PRICES) do prototypes.item[name]={stack_size=100,spoil_ticks=0} end;K.tick(0)
end
local function call(t,a,args,id) teamname=t;serial=serial+1;requestid=id or ('r'..serial);return K.handlers[a](nil,args or {}) end
local function stock(t,name,n,q) return s.mt.market.teams[t].post.inv.insert{name=name,count=n,quality=q} end
local function count(t,name,q) return s.mt.market.teams[t].post.inv.get_item_count{name=name,quality=q} end
local function tick(n) game.tick=n;K.tick(n) end
local function totalgoods(name)
 local n=0;for t in pairs(s.mt.market.teams) do n=n+count(t,name) end
 for _,p in pairs(s.mt.market.pairs) do for _,tx in ipairs(p.transactions) do for _,l in ipairs(tx.legs) do if l.item==name then n=n+(l.removed or 0)-l.delivered end end end end;return n
end
local function audit() local a=K.audit();eq(#a.faults,0,table.concat(a.faults,','));eq(a.total,a.issuance);return a end
local function firsttx() for _,p in pairs(s.mt.market.pairs) do if #p.transactions>0 then return p.transactions[1],p end end end
local function sell(t,itemname,n,price,keep,id) return call(t,'sell',{item=itemname,count=n,price=price or 10,keep=keep or 0},id) end
local function buy(t,itemname,n,price,id) return call(t,'buy',{item=itemname,count=n,price=price or 10},id) end

-- No market surface or issuance before contact, even if technology was researched prematurely.
reset(false,true);eq(K.rung('red'),0);eq(next(K.schema('red')),nil);eq(K.status('red'),nil);eq(s.mt.market,nil)
for action in pairs(K.names()) do refused(function() call('red',action,{}) end,'unsupported action') end
s.mt.first['shot red>blue']=1;tick(60);eq(K.rung('red'),2);eq(forces.red.technologies['mt-coinage'].enabled,true)
eq(s.mt.market.issuance,20000);tick(120);reload();tick(180);eq(s.mt.market.issuance,20000,'one grant per force, not contact/reload')
eq(s.mt.market.teams.green,nil);eq(K.schema('red').buy.from,nil);eq(K.schema('red').sell.to,nil);eq(K.schema('red').offer.to,nil)
local e1=refused(function() call('red','buy',{item='iron-ore',price=10,count=1,from='green'}) end,'counterparty unavailable')
local e2=refused(function() call('red','buy',{item='iron-ore',price=10,count=1,from='invented'}) end,'counterparty unavailable');eq(e1,e2)

-- Swaps open before money. Exact inverse offer accepts, no depot cut, one durable receipt.
reset(true,false);eq(K.rung('red'),1);ok(K.schema('red').offer);eq(K.schema('red').buy,nil);eq(K.schema('red').market,nil)
stock('red','iron-plate',100);stock('blue','copper-plate',80)
local offer={give={item='iron-plate',count=100},get={item='copper-plate',count=80}}
call('red','offer',offer,'swap');local ac=K.status('blue').offers[1].accept;eq(ac.action,'offer');eq(ac.args.to,nil);eq(ac.args.give.count,80)
call('blue',ac.action,ac.args);tick(600);eq(count('red','iron-plate'),0);eq(totalgoods('iron-plate'),100)
local tx=firsttx();eq(tx.status,'in_transit');eq(tx.eta-tx.tick,5400);tick(5940);eq(count('blue','iron-plate'),0)
tick(6000);eq(count('blue','iron-plate'),100);eq(count('red','copper-plate'),80);eq(tx.status,'delivered')
for i=1,300 do requestid='nonmarket'..i end
call('red','offer',offer,'swap');eq(#s.mt.market.pairs['blue>red'].transactions,1,'replay beyond transport cache');audit()

-- Required keep/count; price bounds; strict normal/stateless allowlist; no wire/NPC/commission/withdrawal.
reset(true,true)
for _,a in ipairs{{item='iron-ore',price=10,count=100},{item='iron-ore',price=10,keep=0},{item='iron-ore',price=900,keep=0,count=1},
 {item='iron-plate',price=1,keep=0,count=5000},{item='firearm-magazine',price=20,keep=0,count=1},
 {item='iron-plate',price=20,keep=0,count=1,quality='legendary'}} do refused(function() call('red','sell',a) end,'call ') end
for _,n in ipairs{'pay','withdraw','commission','npc_buy'} do eq(K.handlers[n],nil) end
stock('red','iron-plate',300);stock('red','iron-plate',500,'rare');sell('red','iron-plate',250,20,100,'ask')
game.tick=1;buy('blue','iron-plate',250,30,'bid');eq(s.mt.market.teams.blue.reserved,7500);eq(s.mt.market.teams.blue.wallet,10000)
refused(function() buy('blue','copper-plate',126,20) end,'insufficient')
refused(function() sell('red','iron-plate',5,20) end,'shared order already exists')
refused(function() sell('red','iron-plate',250,21,100,'ask') end,'request id already used')
tick(600);tx=firsttx();eq(tx.count,200);eq(tx.price,20,'resting ask');eq(count('red','iron-plate'),100);eq(count('red','iron-plate','rare'),500)
eq(s.mt.market.teams.red.wallet,10000,'unpaid before arrival');eq(s.mt.market.teams.blue.wallet,6000);eq(s.mt.market.teams.blue.reserved,1500)
eq(audit().escrow,4000);eq(totalgoods('iron-plate'),300)
s.mt.market.teams.red.post.inv.remove{name='iron-plate',count=100};tick(1200);eq(#s.mt.market.pairs['blue>red'].transactions,1,'teammates cannot remove escrow')
call('blue','cancel',{side='buy',item='iron-plate'},'cancel');eq(s.mt.market.teams.blue.reserved,0);eq(tx.status,'in_transit')
call('blue','cancel',{side='buy',item='iron-plate'},'cancel');eq(s.mt.market.teams.blue.wallet,6000)
-- Full/partial receivers: exact counts pay exactly, no retries after completion. Reload retains journals.
s.mt.market.teams.blue.post.inv.capacity=30;reload();tick(6000);eq(count('blue','iron-plate'),30);eq(tx.legs[1].delivered,30)
eq(tx.status,'waiting');eq(s.mt.market.teams.red.wallet,10600);eq(tx.escrow,3400);audit()
tick(6060);eq(s.mt.market.teams.red.wallet,10600);eq(tx.legs[1].delivered,30)
s.mt.market.teams.blue.post.inv.capacity=1000;tick(6120);eq(tx.status,'delivered');eq(s.mt.market.teams.red.wallet,14000);eq(tx.escrow,0);audit()
local wallets=K.audit().wallets;tick(6180);eq(K.audit().wallets,wallets);eq(count('blue','iron-plate'),200)
sell('red','iron-plate',250,20,100,'ask');eq(s.mt.market.teams.red.next,2)

-- Belt-fed reserve and lifetime count, including inbound shipments.
reset(true,true);stock('red','iron-ore',500);sell('red','iron-ore',300,10,300);buy('blue','iron-ore',300)
tick(600);stock('red','iron-ore',200);tick(1200);eq(count('red','iron-ore'),400)
local pp=s.mt.market.pairs['blue>red'];eq(#pp.transactions,2);eq(pp.transactions[1].count+pp.transactions[2].count,300)
for n=1800,5400,600 do tick(n) end;eq(#pp.transactions,2);eq(totalgoods('iron-ore'),700);audit()

-- One-pass stock/coin across pairs; resting bid. Addressed and unaddressed orders coexist.
reset(true,true);s.mt.first['chart red>green']=1;tick(60);ok(K.schema('red').buy.from);eq(K.schema('blue').buy.from,nil)
stock('blue','iron-ore',800);stock('green','iron-ore',800);buy('red','iron-ore',1000);game.tick=61
sell('blue','iron-ore',800,5);sell('green','iron-ore',800,5);tick(600)
eq(s.mt.market.teams.red.wallet,0);eq(s.mt.market.teams.red.reserved,0);eq(totalgoods('iron-ore'),1600)
local n=0;for _,p in pairs(s.mt.market.pairs) do for _,x in ipairs(p.transactions) do n=n+x.count;eq(x.price,10,'resting bid') end end;eq(n,1000);audit()
sell('red','copper-ore',3);call('red','sell',{item='copper-ore',price=10,keep=0,count=3,to='blue'});eq(#K.status('red').orders,3)
local d=dofile('mod/agent-harness_0.1.0/discovery.lua'){state=function() return s end,bots=function() return {} end}
eq(d.project({seller='green',x=800,order_id=9,count=8},'blue'),nil)
for _,f in ipairs(K.status('blue').fills) do eq(f.team,nil);eq(f.id,1) end
eq(s.mt.market.pairs['blue>red'].transactions[1].id,1,'pair-local fill ids')

-- Rolling cap survives cancel/relist.
reset(true,true);stock('red','iron-ore',10000);sell('red','iron-ore',10000,5);buy('blue','iron-ore',2000,5)
tick(600);eq(firsttx().count,1000);tick(1200);eq(#s.mt.market.pairs['blue>red'].transactions,1)
call('blue','cancel',{item='iron-ore',side='buy'});buy('blue','iron-ore',1000,5);tick(1800);eq(#s.mt.market.pairs['blue>red'].transactions,1)
tick(4200);eq(#s.mt.market.pairs['blue>red'].transactions,2);audit()

-- Freeze/embargo stop new commitments without trapping counterparties' cargo.
reset(true,true);stock('red','iron-ore',500);sell('red','iron-ore',500);buy('blue','iron-ore',100);tick(600);s.mt.humans={team='blue',state='frozen'}
refused(function() buy('blue','iron-ore',1) end,'frozen');tick(6000);eq(count('blue','iron-ore'),100);audit();s.mt.humans.state='active'
buy('blue','iron-ore',100);call('blue','embargo',{team='red'});tick(6600);eq(#s.mt.market.pairs['blue>red'].transactions,1);audit()
-- Same-surface restriction.
reset(true,true);stock('red','iron-ore',100);s.mt.market.teams.blue.post.surface={index=2,name='vulcanus'}
sell('red','iron-ore',100);buy('blue','iron-ore',100);tick(600);eq(firsttx(),nil);audit()

-- 14,000 -> 10,500 -> 7,875. Deposit transfers custody. Duplicate deaths cannot mint coin.
reset(true,true);s.mt.market.teams.red.wallet=14000;s.mt.market.teams.blue.wallet=6000
local post=s.mt.market.teams.red.post;K.on_died{entity=post};eq(s.mt.market.teams.red.wallet,10500);eq(spilled[1].stack.count,3500)
K.on_died{entity=post};eq(#spilled,1);audit();post.valid=false;tick(60)
K.on_died{entity=s.mt.market.teams.red.post};eq(s.mt.market.teams.red.wallet,7875);eq(spilled[2].stack.count,2625);audit()
stock('blue','mt-coin',6125);tick(120);eq(s.mt.market.teams.blue.wallet,12125);eq(K.audit().physical,0);audit()
reset(true,true);buy('red','iron-ore',1000);K.on_died{entity=s.mt.market.teams.red.post};eq(s.mt.market.teams.red.wallet,7500);eq(s.mt.market.teams.red.reserved,0);audit()
-- Terminal quarantine records and propagates engine errors; reload/ticks never repeat uncertain insertion.
reset(true,true);stock('red','iron-ore',100);sell('red','iron-ore',100);buy('blue','iron-ore',100);tick(600)
tx=firsttx();local attempts=0;s.mt.market.teams.blue.post.inv.insert=function() attempts=attempts+1;error('engine fault') end
refused(function() tick(6000) end,'engine fault');eq(tx.status,'quarantined');ok(#K.audit().faults>0);reload();tick(6060);eq(attempts,1)
-- Control switches off every market surface and issuance on the same contacted map.
reset(false,true);K.operator.mt_market{config={enabled=false}};s.mt.first['chart red>blue']=1;tick(600)
eq(K.status('red'),nil);eq(#made,0);eq(K.audit().issuance,0)
print('mt296 market: '..checks..' assertions passed')
-- A-B responses must not reveal B-C fills, balances, positions or global ids.
reset(true,true);s.mt.first['chart blue>green']=1;tick(60)
stock('blue','copper-ore',100);sell('blue','copper-ore',100)
local prior=K.status('red').offers[1];eq(prior.accept.args.count,100)
buy('green','copper-ore',100);tick(600)
local after=K.status('red').offers[1];eq(after.id,prior.id);eq(after.accept.args.count,100)
eq(#K.status('red').fills,0);eq(#K.status('red').inbound,0)
eq(after.team,nil);eq(after.wallet,nil);eq(after.position,nil)
-- Incoming scripts cannot trade partially used science tools or spoilable/quality items.
refused(function() sell('red','automation-science-pack',1,60) end,'item unavailable')
prototypes.item['iron-ore'].get_spoil_ticks=function() return 600 end
refused(function() sell('red','iron-ore',1) end,'item unavailable')
-- Swaps count both legs toward pair capacity.
reset(true,false);stock('red','iron-plate',600);stock('blue','copper-plate',600)
refused(function() call('red','offer',{give={item='iron-plate',count=600},get={item='copper-plate',count=600}}) end,'pair capacity')
call('red','offer',{give={item='iron-plate',count=500},get={item='copper-plate',count=500}})
call('blue','offer',{give={item='copper-plate',count=500},get={item='iron-plate',count=500}});tick(600);ok(firsttx())
-- New commitments between duplicate tick notifications wait for the next batch.
reset(true,true);stock('red','iron-ore',100);tick(600);sell('red','iron-ore',100);buy('blue','iron-ore',100);tick(600)
eq(firsttx(),nil);tick(1200);eq(firsttx().count,100)
print('mt296 additional privacy/item/batch checks: '..checks..' total assertions passed')
reset(true,true);stock('red','iron-ore',100);sell('red','iron-ore',100);buy('blue','iron-ore',100);tick(600)
local view=K.operator.mt_market{}
eq(#view.markers,1);eq(view.last_prices[1].thin,true);eq(view.markers[1].count,100);eq(view.markers[1].arrival_tick,6000)
tick(6000);view=K.operator.mt_market{};eq(#view.markers,0)
print('mt296 total assertions: '..checks)
-- Operator risk switch applies to existing Posts, without creating a new treasury/grant.
local oldpost=s.mt.market.teams.red.post
K.operator.mt_market{config={destructible=true}};eq(oldpost.destructible,true);eq(s.mt.market.issuance,20000)
-- Failed custody mutations quarantine all later custody, including deposits after reload.
reset(true,true)
surface.spill_item_stack=function() return {} end
refused(function() K.on_died{entity=s.mt.market.teams.red.post} end,'coin spill incomplete')
eq(s.mt.market.teams.red.wallet,7500);eq(s.mt.market.teams.red.spills['1'].status,'quarantined')
stock('blue','mt-coin',1);reload();tick(60);eq(count('blue','mt-coin'),1);eq(s.mt.market.teams.blue.wallet,10000)
-- One seller's public stock cannot be dispatched twice to different pairs.
reset(true,true);s.mt.first['chart red>green']=1;tick(60);stock('red','iron-ore',120)
sell('red','iron-ore',200,10,20);buy('blue','iron-ore',100);buy('green','iron-ore',100);tick(600)
eq(count('red','iron-ore'),20);eq(totalgoods('iron-ore'),120)
local dispatched=0;for _,p in pairs(s.mt.market.pairs) do for _,t in ipairs(p.transactions) do dispatched=dispatched+t.count end end
eq(dispatched,100);audit()
-- Best price precedes age; equal-time resting-price ties use force index.
reset(true,true);s.mt.first['chart red>green']=1;tick(60);stock('red','iron-ore',10)
sell('red','iron-ore',10,20)
call('red','sell',{item='iron-ore',count=10,price=10,keep=0,to='blue'})
buy('blue','iron-ore',10,30);tick(600);eq(firsttx().price,10)
reset(true,true);stock('red','iron-ore',1);buy('blue','iron-ore',1,20);sell('red','iron-ore',1,10);tick(600)
eq(firsttx().price,10,'lower force index sets resting price at equal tick')
-- Human commands use the same shared-order race/refusal and freeze validators.
reset(true,true);local printed={};local pl={name='human',force=forces.red}
pl.force.print=function(v) printed[#printed+1]=v end;game.get_player=function() return pl end
helpers={json_to_table=function() return {item='iron-ore',price=10,keep=0,count=5} end,table_to_json=function(v) return v.order and 'order' or 'status' end}
s.mt.humans={team='red',state='active',players={human=true}}
K.on_console_chat{player_index=1,message='!market sell {}'};eq(printed[1],'[market] order')
K.on_console_chat{player_index=1,message='!market sell {}'};ok(printed[2]:find('shared order',1,true))
eq(s.mt.market.teams.red.next,2);eq(s.mt.market.chat_seq,2)
s.mt.humans.state='frozen';K.on_console_chat{player_index=1,message='!market sell {}'};ok(printed[3]:find('frozen',1,true))
print('mt296 final assertions: '..checks)
-- Accepting calls honor the observer's available budget; zero funds never advertises an invalid buy.
reset(true,true);sell('red','iron-ore',100000,30)
eq(K.status('blue').offers[1].accept.args.count,333)
buy('blue','copper-ore',1000,10);local opportunity=K.status('blue').offers[1]
eq(opportunity.accept,false);eq(opportunity.next.action,'status')
print('mt296 all assertions: '..checks)
-- Replacing a cancelled/filled order cannot reuse its revision and accept a stale teammate cancellation.
reset(true,true);local original=sell('red','iron-ore',10).order
call('red','cancel',{item='iron-ore',side='sell',revision=original.revision})
local replacement=sell('red','iron-ore',20).order;ok(replacement.revision>original.revision)
refused(function() call('red','cancel',{item='iron-ore',side='sell',revision=original.revision}) end,'order changed')
eq(K.status('red').orders[1].status,'open')
reset(true,false);eq(K.schema('red').cancel.side,'offer')
refused(function() call('red','cancel',{item='iron-ore',side='buy'}) end,'side: offer')
-- Unrelated fault details/transaction ids never enter agent projections.
reset(true,true);s.mt.market.fault={transaction=1337,error='green hidden coordinate 900,900'}
eq(K.status('red').fault.transaction,nil);eq(K.status('red').fault.error,nil)
print('mt296 comprehensive assertions: '..checks)
-- Authoritative moments are emitted once; blocked books never recommend new orders.
reset(true,true);eq(#news,2);eq(news[1].kind,'coinage');eq(news[1].b,nil)
sell('blue','iron-ore',10);call('red','embargo',{team='blue'});eq(#news,3);eq(news[3].kind,'embargo')
call('red','embargo',{team='blue'});eq(#news,3)
eq(K.status('red').offers[1].accept,false);eq(#K.status('red').embargoed,1)
K.on_died{entity=s.mt.market.teams.red.post};eq(#news,4);eq(news[4].kind,'raid')
local feed=dofile('mod/agent-harness_0.1.0/teamfeed.lua'){state=function() return s end}
feed.market(news[1]);feed.market(news[3]);local lines=feed.operator.mt_feed{}.lines
eq(#lines[1].to,0);eq(lines[1].event,'coinage');eq(lines[1].source_seq,1);eq(lines[2].to[1],'blue')
print('mt296 acceptance assertions: '..checks)
-- Coins inserted immediately before a raid are credited before the chest disappears.
reset(true,true);K.on_died{entity=s.mt.market.teams.blue.post};stock('red','mt-coin',2500)
K.on_died{entity=s.mt.market.teams.red.post}
eq(s.mt.market.teams.red.wallet,9375);eq(K.audit().physical,3125);eq(count('red','mt-coin'),0);audit()
print('mt296 final total: '..checks)
-- mt_setup's saved MapPosition may be an array; the Post offset normalizes both forms.
reset(false,false);s.mt.spawns.red.nauvis={100,200};s.mt.first['chart red>blue']=1;tick(60)
eq(s.mt.market.teams.red.post.position.x,104);eq(s.mt.market.teams.red.post.position.y,200)
print('mt296 engine regression total: '..checks)
