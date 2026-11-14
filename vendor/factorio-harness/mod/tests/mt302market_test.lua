-- mt302 (private): the market's full-game settings. mt_market {profile="full"}: home Posts destructible, 25% of the
-- wallet spilled into a coin wreck (a character corpse no robot or inserter reaches) when the home Post dies, tier
-- grants, research income. Any other entity's coin goes into a wreck too; a character keeps its coin in its corpse.
-- Prepared-base fixtures (no profile) keep ground spills. Run from the harness root: lua mod/tests/mt302market_test.lua
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
local s,P,K,teamname,requestid,serial,forces,surface,facts,grounds,corpses,corpse_fails
local function inventory(capacity)
 local i={items={},capacity=capacity or 100000,__engine=true}
 i.get_item_count=function(q) return i.items[q.name..'@'..(q.quality or 'normal')] or 0 end
 i.insert=function(q)
  local total=0;for _,n in pairs(i.items) do total=total+n end
  local n=math.min(q.count,math.max(0,i.capacity-total));local k=q.name..'@'..(q.quality or 'normal');i.items[k]=(i.items[k] or 0)+n;return n
 end
 i.remove=function(q) local n=math.min(q.count,i.get_item_count(q));local k=q.name..'@'..(q.quality or 'normal');i.items[k]=(i.items[k] or 0)-n;return n end
 i.get_contents=function()
  local r={};for k,n in pairs(i.items) do if n>0 then local name,q=k:match('^(.-)@(.*)$');r[#r+1]={name=name,quality=q,count=n} end end;return r
 end
 i.clear=function() i.items={} end
 return i
end
local function reload()
 P=dofile('mod/agent-harness_0.1.0/pacts.lua'){state=function() return s end,team_now=function() return teamname end,
  roster=function() return {} end,request_id=function() return requestid end,on_market=function() end,
  as_team=function(t,fn) local prev=teamname;teamname=t;local r=fn();teamname=prev;return r end,
  fact=function(t,text,wake) facts[#facts+1]={team=t,text=text,wake=wake} end};K=P.market
end
local function reset()
 defines={inventory={chest=1,character_corpse=9},events={on_entity_died=4}};prototypes={item={}};forces={};serial=0;requestid='initial';teamname='red'
 facts,grounds,corpses,corpse_fails={},{},{},false
 surface={index=1,name='nauvis',find_non_colliding_position=function(_,at) return at end,__engine=true}
 surface.spill_item_stack=function(a)
  grounds[#grounds+1]={count=a.stack.count,quality=a.stack.quality,looted=a.enable_looted}
  return {{valid=true,stack={valid_for_read=true,count=a.stack.count}}}
 end
 local made=0
 surface.create_entity=function(a)
  made=made+1
  if a.name=='character-corpse' then
   if corpse_fails then return nil end
   local i=inventory(a.inventory_size*1000)
   local c={name=a.name,type='character-corpse',valid=true,position={x=a.position.x,y=a.position.y},surface=surface,__engine=true,inv=i}
   c.get_inventory=function(id) assert(id==defines.inventory.character_corpse,'corpse inventory');return i end
   c.destroy=function() c.valid=false end
   corpses[#corpses+1]=c;return c
  end
  local i=inventory();local e={name=a.name,type='container',valid=true,position=a.position,force=a.force,surface=surface,unit_number=made,__engine=true}
  e.get_inventory=function() return i end;e.inv=i;return e
 end
 for idx,t in ipairs{'red','blue','green'} do forces[t]={name=t,index=idx,technologies={['mt-coinage']={enabled=false,researched=true}},add_chart_tag=function() end,get_spawn_position=function() return {x=0,y=0} end} end
 game={tick=0,forces=forces,get_surface=function() return surface end}
 s={mt={teams={red=true,blue=true,green=true},order={'red','blue','green'},first={['chart red>blue']=0,['chart blue>green']=0},
  spawns={red={nauvis={x=0,y=0}},blue={nauvis={x=100,y=0}},green={nauvis={x=200,y=0}}}}}
 reload();for name in pairs(K.PRICES) do prototypes.item[name]={stack_size=100,spoil_ticks=0} end;K.tick(0)
end
local function call(t,a,args,id) teamname=t;serial=serial+1;requestid=id or ('r'..serial);return K.handlers[a](nil,args or {}) end
local function tick(n) game.tick=n;K.tick(n) end
local function audit() local a=K.audit();eq(#a.faults,0,table.concat(a.faults,','));eq(a.total,a.issuance,'conservation');return a end
local function post(t) return s.mt.market.teams[t].post end
local function kill(e,force) e.surface=e.surface or surface;K.on_died{name=4,entity=e,force=force and forces[force]};e.valid=false end
local function wallet(t) return s.mt.market.teams[t].wallet end
local function entity(type,unit,inv)
 local e={type=type,name=type,valid=true,position={x=5,y=5},surface=surface,unit_number=unit,__engine=true}
 e.get_max_inventory_index=function() return inv and 1 or 0 end
 e.get_inventory=function(id) return id==1 and inv or nil end
 return e
end

-- 1. The profile, in one call. Unknown profiles and a profile beside config refuse; the reply shows the settings.
reset()
eq(K.operator.mt_market{}.settings.destructible,false,'a fixture default: Posts indestructible')
eq(K.operator.mt_market{}.settings.wreck,false,'a fixture default: ground spills')
refused(function() K.operator.mt_market{profile='short'} end,'profile: full')
refused(function() K.operator.mt_market{profile='full',config={wreck=false}} end,'one at a time')
refused(function() K.operator.mt_market{config={raid_share=1.5}} end,'raid_share: a number 0..1')
local o=K.operator.mt_market{profile='full'}
eq(o.settings.profile,'full');eq(o.settings.destructible,true);eq(o.settings.wreck,true);eq(o.settings.raid_share,.25)
eq(o.settings.research_enabled,true);eq(o.settings.enabled,true);eq(o.settings.grants['mt-coinage'],10000);eq(o.settings.grants['space-science-pack'],10000)
eq(o.pact_settings.end_notice_s,0,'pacts: the DEFAULTS');eq(o.pact_settings.share_max_score,1.4);eq(o.pact_settings.terms.cease_fire,true)
eq(post('red').destructible,true,'the Posts made destructible');eq(post('blue').destructible,true)
eq(wallet('red'),10000,'the Coinage grant');audit()

-- 2. The home Post raided (full profile): 25% of the wallet into a coin wreck, nothing on the ground; the team told.
s.mt.market.teams.red.wallet=s.mt.market.teams.red.wallet+4000;s.mt.market.issuance=s.mt.market.issuance+4000   -- 14,000 (design v3's example)
local p=post('red');p.inv.insert{name='mt-coin',count=0}
kill(p,'blue')
eq(wallet('red'),10500,'14,000 loses 3,500');eq(#grounds,0,'nothing on the ground');eq(#corpses,1,'one wreck')
eq(corpses[1].inv.get_item_count{name='mt-coin'},3500,'the coin in the wreck');eq(corpses[1].position.x,p.position.x)
eq(s.mt.market.physical,3500,'physical coin');audit()
local rec=s.mt.market.teams.red.spills[tostring(p.unit_number)];eq(rec.status,'spilled');eq(rec.wreck.surface,'nauvis')
eq(facts[#facts].team,'red','the raided team is told');ok(facts[#facts].text:find('3500 coin spilled',1,true))
for _,f in ipairs(facts) do ok(not f.text:find('blue',1,true),'no line names the raider') end
-- the Post comes back on the next pass, empty; a second raid takes 25% of what is left
tick(60);ok(post('red').valid and post('red')~=p,'rebuilt');eq(post('red').destructible,true)
kill(post('red'),'blue');eq(wallet('red'),10500-2625,'then 2,625');eq(corpses[2].inv.get_item_count{name='mt-coin'},2625);audit()

-- 3. The raider loots the wreck (its character takes it) and puts it in its own Post: credited, physical back down.
local carried=corpses[1].inv.remove{name='mt-coin',count=3500}
post('blue').inv.insert{name='mt-coin',count=carried}
local before=wallet('blue');tick(120)
eq(wallet('blue'),before+3500,'the raider credited');eq(s.mt.market.physical,2625,'the second wreck still out');audit()
-- a third team takes the second wreck from the raider's corpse and banks it
post('green').inv.insert{name='mt-coin',count=corpses[2].inv.remove{name='mt-coin',count=2625}}
tick(180);eq(s.mt.market.physical,0);audit()

-- 4. A raid with buy orders reserving the coin: bids cancelled to free the stolen part; matched coin is untouched.
reset();K.operator.mt_market{profile='full'}
call('red','buy',{item='iron-ore',price=12,count=800})   -- reserves 9,600 of 10,000
eq(s.mt.market.teams.red.reserved,9600)
kill(post('red'),'blue')
eq(s.mt.market.teams.red.reserved,0,'the bid cancelled');eq(wallet('red'),7500);eq(corpses[1].inv.get_item_count{name='mt-coin'},2500);audit()
ok(facts[#facts].text:find('2500',1,true))

-- 5. No wreck can be made: the coin goes on the ground instead (never lost, no quarantine).
reset();K.operator.mt_market{profile='full'};corpse_fails=true
kill(post('red'),'blue');eq(#grounds,1);eq(grounds[1].count,2500);eq(grounds[1].looted,true);eq(s.mt.market.fault,nil);audit()

-- 6. No profile (a prepared-base fixture): the spill goes on the ground as before.
reset();post('red').destructible=true
kill(post('red'),'blue');eq(#grounds,1,'fixtures: ground');eq(#corpses,0);eq(grounds[1].count,2500);audit()

-- 7. Other entities holding coin (full profile): a chest's coin into a wreck; an inserter's hand too; a character
--    keeps its coin (the game puts it in the character's corpse); every one spilled once.
reset();K.operator.mt_market{profile='full'}
local chest_inv=inventory();chest_inv.insert{name='mt-coin',count=1500};chest_inv.insert{name='iron-plate',count=50}
s.mt.market.physical=s.mt.market.physical+1500;s.mt.market.issuance=s.mt.market.issuance+1500
local chest=entity('container',901,chest_inv)
kill(chest,'blue')
eq(#corpses,1);eq(corpses[1].inv.get_item_count{name='mt-coin'},1500);eq(chest_inv.get_item_count{name='mt-coin'},0)
eq(chest_inv.get_item_count{name='iron-plate'},50,'other goods are the game\'s (they go with the chest)');audit()
kill(chest,'blue');eq(#corpses,1,'a death is spilled once')
local held={valid_for_read=true,name='mt-coin',count=40,quality={name='normal'}};held.clear=function() held.valid_for_read=false end
local ins=entity('inserter',902,nil);ins.held_stack=held
s.mt.market.physical=s.mt.market.physical+40;s.mt.market.issuance=s.mt.market.issuance+40
kill(ins,'blue');eq(#corpses,2);eq(corpses[2].inv.get_item_count{name='mt-coin'},40);eq(held.valid_for_read,false);audit()
local char_inv=inventory();char_inv.insert{name='mt-coin',count=700}
s.mt.market.physical=s.mt.market.physical+700;s.mt.market.issuance=s.mt.market.issuance+700
kill(entity('character',903,char_inv),'green')
eq(#corpses,2,'no wreck for a character');eq(char_inv.get_item_count{name='mt-coin'},700,'its coin stays for its corpse');audit()

-- 8. Save and load in the middle: a wreck out, a bid reserved, a Post rebuilt; the same audit after reload.
reset();K.operator.mt_market{profile='full'}
call('blue','buy',{item='iron-ore',price=12,count=100})
kill(post('red'),'blue');tick(60)
local snap=clone(s);local a1=K.audit()
s=snap;reload();tick(120)
local a2=audit();eq(a2.issuance,a1.issuance);eq(a2.physical,2500);eq(a2.reserved,1200);eq(K.operator.mt_market{}.settings.profile,'full','the profile survives a save')
post('red').inv.insert{name='mt-coin',count=2500};tick(180);eq(wallet('red'),10000,'the defender took its coin back');audit()

defines,prototypes,game=nil,nil,nil
print('mt302 market full-game profile: ok ('..checks..' checks)')
