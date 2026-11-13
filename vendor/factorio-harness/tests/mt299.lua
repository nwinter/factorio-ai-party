-- Research income: actual market factory, deterministic force research; no inventories/statistics are read.
local n=0
local function eq(a,b,label) n=n+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,label) n=n+1;assert(math.abs(a-b)<1e-6,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function clone(v) if type(v)~='table' then return v end local r={} for k,x in pairs(v) do r[k]=clone(x) end return r end
local s,K,f,facts,events
local function reload()
 K=dofile('mod/agent-harness_0.1.0/pacts.lua'){
  state=function() return s end, fact=function(t,text) facts[#facts+1]={team=t,text=text} end,
  on_market=function(e) events[#events+1]=e end,
  research_units=dofile('mod/agent-harness_0.1.0/researchcost.lua').units}.market
end
local function tech(name,count,packs,level)
 local t={name=name,force=f,level=level or 1,researched=false,saved_progress=0,research_unit_count=count,
  research_unit_ingredients=packs or {{name='automation-science-pack',amount=1}},prototype={level=level or 1,max_level=level or 1}}
 f.technologies[name]=t;return t
end
local function reset(coinage)
 facts={};events={};game={tick=0};defines={inventory={chest=1}};prototypes={item={}}
 f={name='red',technologies={['mt-coinage']={enabled=true,researched=coinage~=false}}}
 -- Any rival force access fails, including a pack-consumption or lab-statistics path.
 game.forces=setmetatable({red=f},{__index=function(_,k) error('read rival force '..k) end})
 local inv={get_item_count=function() return 0 end}
 s={mt={order={'red'},teams={red=true,blue=true},first={['chart red>blue']=0},market={teams={red={wallet=0,reserved=0,
  orders={},next=1,spills={},post={valid=true,surface={name='nauvis'},position={x=0,y=0},get_inventory=function() return inv end}}},pairs={},requests={},issuance=0,physical=0,spills={}}}}
 reload();K.sync('red')
end
local function income() return s.mt.market.teams.red.research_income end
local function sync(tick) game.tick=tick or game.tick;K.sync('red') end
local function progress(t,p,tick) f.current_research=t;f.research_progress=p;sync(tick) end
local function audit()
 local a=K.audit();eq(#a.faults,0);eq(a.issuance,a.total)
 local grants=0;for _,p in pairs(s.mt.market.teams.red.payments or {}) do grants=grants+p.amount end
 eq(a.issuance,grants+income().paid,'issuance = grants + income')
 near(income().paid+income().remainder,income().growth+income().level,'fraction conserved')
end
local function save_load()
 local post=s.mt.market.teams.red.post;s.mt.market.teams.red.post=nil;s=clone(s);s.mt.market.teams.red.post=post;reload()
end
local function finish(t,tick,scripted)
 game.tick=tick;f.current_research=nil;f.research_progress=0;t.researched=true
 K.on_research_finished{research=t,by_script=scripted,tick=tick}
end
reset();local t=tech('partial',1000)
progress(t,.1,60);near(income().value,6000);near(income().growth,250);near(income().level,6);eq(income().paid,256);audit()
save_load();sync(60);eq(income().paid,256);finish(t,120);near(income().value,60000);eq(income().paid,2560);audit()
K.on_research_finished{research=t,tick=120};eq(income().paid,2560)
-- Finished technologies that start and finish between samples are counted, too.
local fast=tech('fast',10,{{name='automation-science-pack',amount=2},{name='logistic-science-pack',amount=3}})
finish(fast,121);near(income().value,66000);audit()
-- Cancel/switch/resume and explicit reversal never mint a second payment for the same progress.
reset();t=tech('switch',100);progress(t,.25,60);t.saved_progress=.3;f.current_research=nil;sync(120)
near(income().value,1800);progress(t,.3,180);near(income().value,1800)
progress(t,.2,240);progress(t,.4,300);near(income().value,2400)
finish(t,360);t.researched=false;progress(t,.5,420);finish(t,480);near(income().value,6000);audit()
-- Pre-Coinage current and saved progress are excluded; tier back-pay is still paid exactly once.
reset(false);t=tech('prior',1000);local cancelled=tech('cancelled-before-coinage',1000)
progress(t,.8,60);t.saved_progress=.8;progress(cancelled,.4,120);cancelled.saved_progress=.4
f.technologies['chemical-science-pack']={researched=true};sync(180);eq(s.mt.market.issuance,0)
f.technologies['mt-coinage'].researched=true;sync(240);eq(s.mt.market.issuance,15000);eq(income().value,0)
progress(cancelled,.5,300);near(income().value,6000);progress(t,.9,360);near(income().value,12000);audit()
-- An existing save starts from its current progress, without research-income back-pay.
s.mt.market.teams.red.research_income=nil;save_load();sync(420);eq(income().value,0)
-- Explicit script unlocks change the baseline but pay no research income (tier grants still work).
reset();t=tech('scripted',1000);finish(t,60,true);eq(income().value,0);eq(s.mt.market.issuance,10000)
-- Infinite levels use their completed level's cost, not the next level's doubled cost.
reset();t=tech('infinite',100);t.prototype.max_level=4294967295;t.prototype.research_unit_count_formula='100*2^(L-1)'
helpers={evaluate_expression=function(_,v) return 100*2^(v.L-1) end}
progress(t,.5,60);t.level=2;t.research_unit_count=200;f.research_progress=0
K.on_research_finished{research=t};near(income().value,6000)
progress(t,.25,120);near(income().value,9000);t.level=4;t.research_unit_count=800;f.research_progress=0;sync(180)
near(income().value,42000);audit()
-- A constant 60 value/min warms up over two hours, then earns only level income.
reset();t=tech('flat',1000000)
for minute=1,120 do progress(t,minute/1000000,minute*3600) end
near(income().rate,60);near(income().growth,300);local paid=income().paid
save_load()
for minute=121,240 do progress(t,minute/1000000,minute*3600) end
near(income().rate,60);near(income().growth,300);near(income().level,14.4);eq(income().paid-paid,7);audit()
-- One hour-boundary line, not a line per research sample, even after repeated ticks/reload.
local lines=0;for _,e in ipairs(events) do if e.kind=='research_income' then
 lines=lines+1;assert(e.text:match('Wallet %+%d+ coin: research income this hour'));eq(e.a,'red');eq(e.b,nil)
end end;eq(lines,4);local before=#events;save_load();sync(game.tick);eq(#events,before)
-- Burst: 120000 value in one second buys a 1000/min high (5000 coin), not 7200000/min.
reset();t=tech('burst',2000);finish(t,60);near(income().rate,1000);near(income().growth,5000);eq(income().paid,5120)
save_load();sync(432059);near(income().rate,1000);sync(432060);near(income().rate,0)
local t2=tech('same-burst',2000);finish(t2,432120);near(income().growth,5000);eq(income().paid,5240);audit()
-- Fractional coin is retained across many samples and actual table serialization/reload.
reset();K.operator.mt_market{config={growth_coin_per_rate=0,level_rate=.001}};t=tech('tiny',1000)
for i=1,100 do progress(t,i/1000,i*60);save_load() end
eq(income().paid,6);near(income().remainder,0);audit()
-- Disabled income, old prepared fixtures, and market off/on never repay the disabled interval.
reset();K.operator.mt_market{config={research_enabled=false}};t=tech('disabled',1000);progress(t,.5,60)
K.operator.mt_market{config={research_enabled=true}};progress(t,.6,120);near(income().value,6000)
K.operator.mt_market{config={enabled=false}};f.research_progress=.9;game.tick=180
K.operator.mt_market{config={enabled=true}};near(income().value,6000);finish(t,240);near(income().value,12000);audit()
reset();s.mt.market.config={growth_enabled=false};t=tech('legacy-fixture',1000);progress(t,.5,60);eq(income().paid,0)
K.operator.mt_market{config={research_enabled=true}};progress(t,.6,120);near(income().value,6000);audit()
-- Validation is atomic; zero/fractional rates accepted, NaN/infinity/negative/string/old keys refused.
for _,key in ipairs{'growth_coin_per_rate','level_rate'} do
 for _,v in ipairs{-1,math.huge,0/0,'5',false,1000001} do
  local prior=clone(s.mt.market.config);local ok=pcall(K.operator.mt_market,{config={[key]=v,research_enabled=false}})
  eq(ok,false);eq(s.mt.market.config.research_enabled,prior.research_enabled)
 end
 K.operator.mt_market{config={[key]=.125}};eq(s.mt.market.config[key],.125)
 K.operator.mt_market{config={[key]=0}};eq(s.mt.market.config[key],0)
end
for _,key in ipairs{'growth_amount','growth_start_hours','growth_every_hours','growth_enabled'} do
 eq(pcall(K.operator.mt_market,{config={[key]=1}}),false)
end
local packs={'automation','logistic','military','chemical','production','utility','space','metallurgic','electromagnetic','agricultural','cryogenic','promethium'}
for _,name in ipairs(packs) do assert(K.PRICES[name..'-science-pack']>0) end
near(K.PRICES['production-science-pack'],5950/3);near(K.PRICES['utility-science-pack'],5870/3)
print('mt299 research income: '..n..' assertions passed')
-- Dense second-by-second windows compact their expired prefix and survive reload after compaction.
reset();t=tech('dense',1000000)
for second=1,12000 do
 progress(t,second/1000000,second*60)
 if second==11400 then save_load() end
end
near(income().rate,3600);near(income().growth,18000);near(income().level,720);eq(income().paid,18720)
assert(income().last<12000 and income().last-income().first+1==7200,'bounded rolling window')
audit();save_load();sync(12000*60+432000);near(income().rate,0);eq(income().paid,18720);audit()
print('mt299 dense-window total: '..n..' assertions passed')
