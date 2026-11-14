-- mt301 (private): the market's records over a long game. Receipts keep their id and payload forever (a used id
-- never runs twice) but old ones drop their copied result; delivered transactions, credited deposits and counters of
-- orders no longer held fold away. Coin, goods, escrow, prices and recent fills read the same before and after.
local checks=0
local function eq(a,b,m) checks=checks+1;assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function ok(v,m) checks=checks+1;assert(v,m) end
local function refused(fn,msg) local fine,e=pcall(fn);ok(not fine,'expected refusal');ok(tostring(e):find(msg,1,true),tostring(e)) end
local function clone(v,seen)
 if type(v)~='table' then return v end
 seen=seen or {};if seen[v] then return seen[v] end
 if rawget(v,'__engine') then return v end
 local r={};seen[v]=r;for k,x in pairs(v) do r[clone(k,seen)]=clone(x,seen) end;return r
end
local s,P,K,teamname,requestid,serial,forces,surface
local function inventory()
 local i={items={},capacity=100000,__engine=true}
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
  roster=function() return {} end,request_id=function() return requestid end,on_market=function() end,
  as_team=function(t,fn) local prev=teamname;teamname=t;local r=fn();teamname=prev;return r end,fact=function() end};K=P.market
end
local function reset()
 defines={inventory={chest=1}};prototypes={item={}};forces={};serial=0;requestid='initial';teamname='red'
 surface={index=1,name='nauvis',find_non_colliding_position=function(_,at) return at end,__engine=true}
 local made=0
 surface.create_entity=function(a)
  made=made+1
  local i=inventory();local e={name=a.name,valid=true,position=a.position,force=a.force,surface=surface,unit_number=made,__engine=true}
  e.get_inventory=function() return i end;e.inv=i;return e
 end
 for idx,t in ipairs{'red','blue','green'} do forces[t]={name=t,index=idx,technologies={['mt-coinage']={enabled=false,researched=true}},add_chart_tag=function() end,get_spawn_position=function() return {x=0,y=0} end} end
 game={tick=0,forces=forces,get_surface=function() return surface end}
 s={mt={teams={red=true,blue=true,green=true},order={'red','blue','green'},first={['chart red>blue']=0},
  spawns={red={nauvis={x=0,y=0}},blue={nauvis={x=100,y=0}},green={nauvis={x=200,y=0}}}}}
 reload();for name in pairs(K.PRICES) do prototypes.item[name]={stack_size=100,spoil_ticks=0} end;K.tick(0)
 -- blue's buying power for a long game (minted, so the audit still balances)
 s.mt.market.teams.blue.wallet=s.mt.market.teams.blue.wallet+2000000;s.mt.market.issuance=s.mt.market.issuance+2000000
end
local function call(t,a,args,id) teamname=t;serial=serial+1;requestid=id or ('r'..serial);return K.handlers[a](nil,args or {}) end
local function stock(t,name,n) return s.mt.market.teams[t].post.inv.insert{name=name,count=n} end
local function count(t,name) return s.mt.market.teams[t].post.inv.get_item_count{name=name} end
local function tick(n) game.tick=n;K.tick(n) end
local function audit() local a=K.audit();eq(#a.faults,0,table.concat(a.faults,','));eq(a.total,a.issuance);return a end
local function json(v)
 if type(v)~='table' then return tostring(v) end
 local keys={};for k in pairs(v) do keys[#keys+1]=tostring(k) end;table.sort(keys)
 local out={};for _,k in ipairs(keys) do out[#out+1]=k..'='..json(v[k] or v[tonumber(k)]) end
 return '{'..table.concat(out,',')..'}'
end
local function prices() local o=K.operator.mt_market{};local r={};for _,v in ipairs(o.last_prices) do r[v.item]=v.price..'x'..v.count..'@'..v.tick..'#'..v.prints end;return r end

-- A long game: a standing ask and bid, one small lot a batch; an order replaced every batch; coin deposited often.
reset()
call('blue','buy',{item='iron-ore',price=12,count=100000},'standing-bid')
local issued=s.mt.market.issuance
local t,receipts=0,1   -- the standing bid's receipt
for round=1,1200 do
 t=t+600
 stock('red','iron-ore',1)
 -- a new ask each round (the last one filled): a receipt a round
 call('red','sell',{item='iron-ore',price=10+round%3,count=1,keep=0},'s'..round);receipts=receipts+1
 s.mt.market.physical=s.mt.market.physical+1;s.mt.market.issuance=s.mt.market.issuance+1;stock('blue','mt-coin',1)
 for k=t-540,t,60 do tick(k) end
end
-- every batch's lot is delivered 90 s after it matched; finish the last ones
for k=t+60,t+6000,60 do tick(k) end
local pair=s.mt.market.pairs['blue>red']
local sizes=K.sizes()
ok(#pair.transactions<=K.KEEP.transactions+K.KEEP.slack,'transactions folded as the game runs: '..#pair.transactions)
ok(sizes.folded_transactions>=1200-K.KEEP.transactions-K.KEEP.slack,'folded '..sizes.folded_transactions)
eq(sizes.transactions+sizes.folded_transactions,1200,'every lot counted once')
eq(sizes.receipts,receipts,'every receipt kept: a used id never runs twice')
ok(sizes.full_receipts<=K.KEEP.receipts+K.KEEP.slack+1,'old receipts drop their result: '..sizes.full_receipts)
ok(sizes.deposits<=K.KEEP.deposits+K.KEEP.slack,'deposits folded: '..sizes.deposits)
eq(sizes.deposits+sizes.folded_deposits,1200)
ok(sizes.order_counters<=K.KEEP.transactions+K.KEEP.slack+2,'counters of replaced orders dropped: '..sizes.order_counters)
eq(count('blue','iron-ore'),1200,'every lot arrived');eq(s.mt.market.deposit_totals.coin+#s.mt.market.deposits,1200)
audit()

-- Forced compaction (mt_market {compact=true}) reads the same.
local before_prices,before_fills,before_audit=prices(),json(K.status('blue').fills),json(K.audit())
local before_red=json(K.status('red'))
local o=K.operator.mt_market{compact=true}
eq(#pair.transactions,K.KEEP.transactions);eq(o.records.full_receipts,K.KEEP.receipts+1,'red 256 and the standing bid')
eq(json(prices()),json(before_prices),'last prices and print counts unchanged')
eq(json(K.status('blue').fills),before_fills,'the last 20 fills unchanged')
eq(json(K.audit()),before_audit,'audit unchanged')
eq(json(K.status('red')),before_red,'the status an agent reads unchanged')
eq(prices()['iron-ore']:match('#(%d+)$'),'1200','1200 prints')

-- Replays: a compacted receipt answers without running again; other arguments under its id refuse; a recent one
-- returns its full result.
local orders_before=s.mt.market.teams.red.next
local r=call('red','sell',{item='iron-ore',price=12,count=1,keep=0},'s2')
eq(r.compacted,true);eq(r.committed,true);eq(s.mt.market.teams.red.next,orders_before,'nothing ran again')
refused(function() call('red','sell',{item='iron-ore',price=11,count=1,keep=0},'s2') end,'different arguments')
r=call('red','sell',{item='iron-ore',price=10+1200%3,count=1,keep=0},'s1200');ok(r.order and r.order.id,'full recent receipt')
eq(s.mt.market.teams.red.next,orders_before)

-- Receipts past the newest KEEP.payloads become their tick: a replay (any arguments) answers committed, runs nothing.
K.KEEP.payloads=500;local slim=K.compact(true);K.KEEP.payloads=4096
eq(slim.slimmed,1200-500,'committed receipts slimmed to a tick')
eq(type(s.mt.market.requests.red.s3),'number');eq(type(s.mt.market.requests.red.s1200),'table')
r=call('red','sell',{item='copper-ore',price=99,count=7,keep=0},'s3')
eq(r.compacted,true);eq(r.tick,s.mt.market.requests.red.s3);eq(s.mt.market.teams.red.next,orders_before,'nothing ran')
eq(K.sizes().receipts,1201+0,'the ids are all still there')
eq(json(K.audit()),before_audit)

-- An old lot still waiting (the buyer's Post full) is never folded and arrives later; its id still resolves.
reset()
call('blue','buy',{item='iron-ore',price=12,count=100000},'bid')
s.mt.market.teams.blue.post.inv.capacity=0
stock('red','iron-ore',1);call('red','sell',{item='iron-ore',price=10,count=1,keep=0},'first');tick(600)
for k=660,6600,60 do tick(k) end
pair=s.mt.market.pairs['blue>red'];eq(pair.transactions[1].status,'waiting')
s.mt.market.teams.blue.post.inv.capacity=100000
local wait_id=pair.transactions[1].id
s.mt.market.teams.blue.post.inv.capacity=0
t=6600
for round=1,400 do
 t=t+600;stock('red','iron-ore',1);call('red','sell',{item='iron-ore',price=10,count=1,keep=0})
 for k=t-540,t,60 do tick(k) end
end
-- the receiver had no room: everything waits; nothing is folded
eq(K.compact(true).transactions,0,'nothing undelivered folds')
s.mt.market.teams.blue.post.inv.capacity=100000
for k=t+60,t+6000,60 do tick(k) end
K.compact(true)
eq(#s.mt.market.pairs['blue>red'].transactions,K.KEEP.transactions)
local escrow=K.audit().escrow;eq(escrow,0);audit()
eq(count('blue','iron-ore'),401)
-- the waiting one was delivered before it folded
eq(K.txget(s.mt.market.pairs['blue>red'],wait_id),nil,'folded once delivered')

-- A quarantined transaction is never folded; a lookup by id after compaction still finds a pending one.
reset()
call('blue','buy',{item='iron-ore',price=12,count=100000},'bid')
for round=1,300 do
 stock('red','iron-ore',1);call('red','sell',{item='iron-ore',price=10,count=1,keep=0});for k=round*600-540,round*600,60 do tick(k) end
 if round==1 then s.mt.market.pairs['blue>red'].transactions[1].status='quarantined' end
end
pair=s.mt.market.pairs['blue>red']
K.compact(true)
eq(pair.transactions[1].status,'quarantined','kept');eq(pair.transactions[1].id,1)
local last=pair.transactions[#pair.transactions]
eq(K.txget(pair,last.id),last);eq(K.txget(pair,1),pair.transactions[1]);eq(K.txget(pair,2),nil)

-- Save/load after compaction: trading goes on, ids continue, conservation holds.
reset()
call('blue','buy',{item='iron-ore',price=12,count=100000},'bid')
for round=1,320 do stock('red','iron-ore',1);call('red','sell',{item='iron-ore',price=10,count=1,keep=0});for k=round*600-540,round*600,60 do tick(k) end end
for k=192060,198000,60 do tick(k) end
K.compact(true)
local next_id=s.mt.market.pairs['blue>red'].next
s=clone(s);reload()
stock('red','iron-ore',1);call('red','sell',{item='iron-ore',price=10,count=1,keep=0})
tick(198600);eq(s.mt.market.pairs['blue>red'].transactions[#s.mt.market.pairs['blue>red'].transactions].id,next_id)
for k=198660,204600,60 do tick(k) end
eq(count('blue','iron-ore'),321);audit()

-- Compaction on the tick: once a game minute, never a fault (it moves no coin or goods).
reset();local calls=0;local real=K.compact;K.compact=function(...) calls=calls+1;return real(...) end
for k=60,7200,60 do tick(k) end;eq(calls,2,'tick 1800 and 5400')
K.compact=function() error('boom') end;tick(9000);eq(s.mt.market.fault,nil,'no quarantine from compaction')
print('mt301market: '..checks..' checks passed')
