-- mt301 (private: multi-team end of game). Run from the harness root: lua tests/mt301.lua
-- Edge arrival (solo, allied by the departure's pacts, home must hold), wipe detection (never a restore), the wipe
-- win, the deadline's milestone ranking, the frozen result, save/load, and the agents' lines naming only contacted
-- teams.
local n=0
local function eq(a,b,m) n=n+1;assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function ok(v,m) n=n+1;assert(v,m or 'expected true') end
local function fails(fn,text) n=n+1;local good,err=pcall(fn);assert(not good and tostring(err):find(text,1,true),tostring(err)) end
local function clone(v,seen)
  if type(v)~='table' then return v end
  seen=seen or {}
  if seen[v] then return seen[v] end
  -- engine objects (entities, forces, platforms) are references in storage, not copied
  if rawget(v,'__engine') then return v end
  local r={};seen[v]=r
  for k,x in pairs(v) do r[clone(k,seen)]=clone(x,seen) end
  return r
end

defines={entity_status={working=1,no_power=2,no_fuel=3,no_ingredients=4},inventory={chest=1}}
prototypes={item={},space_location={nauvis={type='planet'},vulcanus={type='planet'},fulgora={type='planet'},gleba={type='planet'},
  aquilo={type='planet'},['solar-system-edge']={type='space-location'},['shattered-planet']={type='space-location'}}}
local logged,files={},{}
log=function(t) logged[#logged+1]=t end
helpers={write_file=function(name,text,append) files[name]=(append and files[name] or '')..text end,
  table_to_json=function(v)
    local function enc(x)
      if type(x)=='table' then
        if rawget(x,'__engine') then return '"<entity>"' end
        local parts={}
        for k,y in pairs(x) do parts[#parts+1]=tostring(k)..'='..enc(y) end
        table.sort(parts);return '{'..table.concat(parts,',')..'}'
      end
      return tostring(x)
    end
    return enc(v)
  end}

local unit=0
local function entity(t)
  unit=unit+1
  t.__engine=true;t.valid=true;t.unit_number=unit;t.position=t.position or {x=0,y=0}
  return t
end
local surfaces={}
local function surface(name)
  local sf={name=name,list={}}
  sf.find_entities_filtered=function(f)
    local out={}
    local types
    if type(f.type)=='table' then types={};for _,v in ipairs(f.type) do types[v]=true end elseif f.type then types={[f.type]=true} end
    for _,e in ipairs(sf.list) do
      local near=not f.position or ((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2<=(f.radius or 0)^2)
      if e.valid and (not types or types[e.type]) and (not f.force or e.force.name==f.force) and near then
        out[#out+1]=e;if f.limit and #out>=f.limit then break end
      end
    end
    return out
  end
  surfaces[name]=sf
  return sf
end
local nauvis=surface('nauvis')
local function add(sf,t) local e=entity(t);sf.list[#sf.list+1]=e;return e end

local function force(name)
  local f={name=name,cease={},technologies={},platforms={},rockets_launched=0,__engine=true}
  f.set_cease_fire=function(o,v) f.cease[type(o)=='table' and o.name or o]=v end
  f.get_cease_fire=function(o) return f.cease[type(o)=='table' and o.name or o]==true end
  return f
end
local red,blue,green=force('red'),force('blue'),force('green')
game={tick=1000,forces={red=red,blue=blue,green=green},surfaces=surfaces,
  get_surface=function(name) return surfaces[name] end}

local s,facts,feed,P,MT
local team='red'
local function load_modules()
  local api={state=function() return s end,team_now=function() return team end,who=function() return 'agent' end,
    as_team=function(t,fn,...) local was=team;team=t;local r=fn(...);team=was;return r end,
    fact=function(t,text,wake) facts[#facts+1]={team=t,text=text,wake=wake} end}
  P=dofile('mod/agent-harness_0.1.0/pacts.lua')(api)
  MT=dofile('mod/agent-harness_0.1.0/multiteam.lua'){state=function() return s end,pacts=function() return P end,
    fact=function(t,text,wake) facts[#facts+1]={team=t,text=text,wake=wake,game=true} end,
    feed=function(e) feed[#feed+1]=e end}
end
local function lines(t) local out={} for _,f in ipairs(facts) do if f.team==t and f.game then out[#out+1]=f.text end end return out end
local function last(t) local l=lines(t);return l[#l] end
local function save_load() s=clone(s);load_modules() end
local function tick(t) game.tick=t;MT.game.tick(t) end
local function op(a) return MT.operator.mt_game(a or {}) end

local nextp=0
local function platform(f,at)
  nextp=nextp+1
  local pl={__engine=true,valid=true,index=nextp,name=f.name..'-ship'..nextp,hub={valid=true},
    space_location=at and {name=at,type=prototypes.space_location[at].type} or nil}
  f.platforms[nextp]=pl
  return pl
end
local function move(pl,to,conn)
  pl.space_location=to and {name=to,type=prototypes.space_location[to].type} or nil
  pl.space_connection=conn
end
-- a home: the landing pad and a powered building near it
local function home(f,powered)
  local pad=add(nauvis,{type='cargo-landing-pad',name='cargo-landing-pad',force=f,position={x=0,y=0}})
  local box=add(nauvis,{type='assembling-machine',name='assembling-machine-2',force=f,position={x=5,y=5},
    electric_buffer_size=100,energy=powered==false and 0 or 50,status=powered==false and defines.entity_status.no_power or defines.entity_status.working})
  return pad,box
end
local function fresh()
  s={mt={order={'red','blue','green'},teams={red=true,blue=true,green=true},first={}},bots={by_index={},by_name={}}}
  facts,feed,files,logged={},{},{},{}
  for _,sf in pairs(surfaces) do sf.list={} end
  for _,f in ipairs({red,blue,green}) do f.platforms={};f.technologies={};f.rockets_launched=0;f.cease={} end
  game.tick=1000
  load_modules()
  MT.operator.mt_game{config={check_s=1}}   -- each step a check (section 9 checks the cadence)
end

-- 1. Solo edge: the arrival counts with the home standing; 1.5 for the team, 0 for the rest; frozen.
fresh()
s.mt.first['chart red>blue']=10   -- red and blue have met; green has met no one
home(red);home(blue)
local ship=platform(red,'aquilo')
tick(1060);P.departures_now()
move(ship,nil,{from={name='aquilo'},to={name='solar-system-edge'}});game.tick=2000;P.departures_now()
eq(P.last_departure('red',ship.index).from,'aquilo','the last planet left')
tick(2060)
eq(op().standings[1].team,'red','edge-run is a milestone')
ok(s.mt.game.teams.red.milestones['edge-run'],'edge-run reached')
eq(s.mt.game.result,nil,'no result in flight')
move(ship,'solar-system-edge');tick(3000)
local res=s.mt.game.result
ok(res,'a result');eq(res.reason,'edge');eq(res.kind,'solo');eq(res.winner,'red')
eq(res.scores.red,1.5);eq(res.scores.blue,0);eq(res.scores.green,0)
ok(last('red'):find('We win alone',1,true),last('red'))
ok(last('blue'):find("red's platform reached the solar system edge",1,true),last('blue'))
-- secrecy: green has had no contact; its line names no other team
eq(last('green'),'The run is over. Our score: 0.')
ok(not last('green'):find('red',1,true) and not last('green'):find('blue',1,true),'green learns of no team')
ok(files['pog/mt-game-result.json'] and files['pog/mt-game-result.json']:find('reason=edge',1,true),'result file')
ok(files['pog/mt-game.jsonl']:find('game_over',1,true),'game over alert line')
eq(#feed,1);eq(feed[1].event,'game_over');ok(feed[1].text:find('red reached the solar system edge alone',1,true),feed[1].text)
local alerts=op().alerts;eq(alerts[#alerts].kind,'game_over')
-- frozen: a second arrival, settings and a later deadline change nothing
local blueship=platform(blue,'solar-system-edge')
tick(4000);eq(s.mt.game.result.winner,'red');eq(#lines('blue'),1,'one game-over line')
fails(function() op{config={solo=2}} end,'the result is frozen')
fails(function() op{end_now=true} end,'already frozen')
-- save/load keeps the frozen record and the stay at the target (no second arrival)
save_load();tick(5000);eq(s.mt.game.result.tick,3000);eq(#s.mt.game.arrivals,1)
-- the operator's deliberate undo needs the result's tick
fails(function() op{clear_result=1} end,'deliberate operator undo')
op{clear_result=3000};eq(s.mt.game.result,nil)
tick(5060);eq(s.mt.game.result.winner,'red','re-scored on the next step (red listed first)')

-- 2. Allied edge: the pact at departure counts, a betrayal after departure does not change it.
fresh()
s.mt.first['chart red>blue']=10;s.mt.first['chart green>red']=12
home(red);home(blue);home(green)
team='red';local pact=P.propose('red','agent',{with='blue',terms={cease_fire=true,shares={red=0.6,blue=0.4}}})
team='blue';P.accept('blue','agent',{id=pact.pact.id});team='red'
ship=platform(red,'gleba');P.departures_now()
move(ship,nil,{from={name='gleba'},to={name='aquilo'}});game.tick=1500;P.departures_now()
-- betrayal in flight: blue ends the pact after red left its last planet
P.finish(s.mt.pacts.by_id[pact.pact.id],'blue','agent','betrayal')
eq(#P.active_with('red'),0,'no pact now')
move(ship,'solar-system-edge');tick(2000)
res=s.mt.game.result
eq(res.kind,'allied');eq(res.scores.red,1.2);eq(res.scores.blue,0.8);eq(res.scores.green,0)
ok(last('red'):find('allied when it left its last planet with blue 0.8',1,true),last('red'))
ok(last('blue'):find('our team was allied with red',1,true),last('blue'))
ok(last('green'):find("red's platform reached",1,true),'green met red')
ok(not last('green'):find('blue',1,true),'green has not met blue: not named')
-- no shares: 1.0 each; a pact made after departure does not count
fresh()
s.mt.first['chart red>blue']=10;home(red)
team='red';pact=P.propose('red','agent',{with='blue',terms={cease_fire=true}})
team='blue';P.accept('blue','agent',{id=pact.pact.id});team='red'
ship=platform(red,'aquilo');P.departures_now();move(ship,nil);P.departures_now()
move(ship,'solar-system-edge');tick(2000)
eq(s.mt.game.result.scores.red,1.0);eq(s.mt.game.result.scores.blue,1.0)
fresh()
s.mt.first['chart red>blue']=10;home(red)
ship=platform(red,'aquilo');P.departures_now();move(ship,nil);P.departures_now()
team='red';pact=P.propose('red','agent',{with='blue',terms={cease_fire=true}})
team='blue';P.accept('blue','agent',{id=pact.pact.id});team='red'
move(ship,'solar-system-edge');tick(2000)
eq(s.mt.game.result.kind,'solo','alliance fixed at departure');eq(s.mt.game.result.scores.blue,0)
-- a pact with no cease-fire is no alliance
fresh()
s.mt.first['chart red>blue']=10;home(red)
team='red';pact=P.propose('red','agent',{with='blue',terms={shares={red=0.5,blue=0.5}}})
team='blue';P.accept('blue','agent',{id=pact.pact.id});team='red'
ship=platform(red,'aquilo');P.departures_now();move(ship,nil);P.departures_now()
move(ship,'solar-system-edge');tick(2000);eq(s.mt.game.result.kind,'solo')

-- 3. Home must hold: no pad, or no power at it: not counted, the game goes on; a later arrival with it counts.
fresh()
ship=platform(red,'aquilo');P.departures_now();move(ship,nil);P.departures_now()
move(ship,'solar-system-edge');tick(2000)
eq(s.mt.game.result,nil,'no pad: not counted')
ok(s.mt.game.arrivals[1].why:find('no cargo landing pad',1,true),s.mt.game.arrivals[1].why)
ok(last('red'):find('does not count',1,true),last('red'))
eq(op().alerts[1].kind,'arrival_refused')
local pad,box=home(red,false)
move(ship,nil);tick(2100);move(ship,'solar-system-edge');tick(2200)
eq(s.mt.game.result,nil,'unpowered: not counted')
ok(s.mt.game.arrivals[2].why:find('none powered',1,true),s.mt.game.arrivals[2].why)
box.energy=50;box.status=defines.entity_status.working
tick(2300);eq(s.mt.game.result,nil,'still at the edge: one arrival a stay')
move(ship,nil);tick(2400);move(ship,'solar-system-edge');tick(2500)
eq(s.mt.game.result.winner,'red','counted once home holds');eq(s.mt.game.result.arrival.departure.from,'aquilo')
-- the last planet stays the departure that counts after a hop away from the edge and back
-- home_power off: the pad alone
fresh();add(nauvis,{type='cargo-landing-pad',name='cargo-landing-pad',force=red})
op{config={home_power=false}}
ship=platform(red,'aquilo');P.departures_now();move(ship,nil);P.departures_now();move(ship,'solar-system-edge');tick(2000)
eq(s.mt.game.result.winner,'red')
-- another team's pad is not ours
fresh();home(blue)
ship=platform(red,'aquilo');P.departures_now();move(ship,nil);P.departures_now();move(ship,'solar-system-edge');tick(2000)
eq(s.mt.game.result,nil,"blue's pad is not red's home")

-- 4. No departure on record: the pacts now, and an alert.
fresh();home(red)
ship=platform(red,'solar-system-edge');tick(2000)
eq(s.mt.game.result.kind,'solo');ok(s.mt.game.result.arrival.departure_unrecorded)
local kinds={};for _,a in ipairs(op().alerts) do kinds[a.kind]=true end
ok(kinds.departure_unrecorded and kinds.game_over,'alerted')
-- the departures are kept per platform past the list's 50
fresh();home(red)
ship=platform(red,'aquilo');P.departures_now();move(ship,nil);P.departures_now()
local other=platform(blue,'nauvis')
for i=1,60 do move(other,'nauvis');P.departures_now();move(other,nil);P.departures_now() end
eq(#s.mt.pacts.departures,50);eq(P.last_departure('red',ship.index).from,'aquilo')
-- the target is a setting (Nick's alternative: the Shattered Planet)
fails(function() op{config={target='moon'}} end,'a space location')
op{config={target='shattered-planet'}}
move(ship,'solar-system-edge');tick(2000);eq(s.mt.game.result,nil,'the edge is not the target now')
move(ship,'shattered-planet');tick(2100);eq(s.mt.game.result.arrival.at,'shattered-planet')

-- 5. Wipe detection: production down 10 minutes AND every agent killed on respawn by another team. Never restored.
fresh()
s.mt.first['shot blue>red']=10
local _,rbox=home(red);home(blue);home(green)
local burner=add(nauvis,{type='furnace',name='stone-furnace',force=red,status=defines.entity_status.working})
local function bot(name,f,born)
  local c=add(nauvis,{type='character',name='character',force=f})
  local b={name=name,force=f.name,character=c,spawn_tick=born}
  s.bots.by_index[#s.bots.by_index+1]=b;s.bots.by_name[name]=b
  return b
end
local r1,r2=bot('r1',red,0),bot('r2',red,0)
tick(1060);eq(s.mt.game.teams.red.down_since,nil,'up')
rbox.status=defines.entity_status.no_power;tick(1120)
eq(s.mt.game.teams.red.down_since,nil,'a furnace with fuel still runs')
burner.status=defines.entity_status.no_fuel;tick(1180)
eq(s.mt.game.teams.red.down_since,1180,'down: unpowered and out of fuel')
local count=#nauvis.list
local function kill(b,killer,cause_name,age)
  b.character.valid=false
  local c=add(nauvis,{type='character',name='character',force=game.forces[b.force]})
  b.character=c;b.spawn_tick=game.tick-(age or 60)
  MT.game.on_died{entity=c,force=killer,cause={valid=true,name=cause_name or 'gun-turret'}}
end
game.tick=1300;kill(r1,blue)
game.tick=1310;kill(r2,{name='enemy'},'small-biter')
tick(1180+36000+60)
eq(s.mt.game.teams.red.wiped,nil,'r2 killed by biters, not a team')
game.tick=37300;kill(r2,blue,'gun-turret',9000)
tick(37360);eq(s.mt.game.teams.red.wiped,nil,'an old character is no kill on respawn')
game.tick=37400;kill(r2,blue,'gun-turret',30)
tick(37460)
ok(s.mt.game.teams.red.wiped,'wiped')
local a=op().alerts;local w;for _,x in ipairs(a) do if x.kind=='wipe' then w=x end end
ok(w and w.text:find('r1 by blue (gun-turret)',1,true) and w.text:find('nothing was restored',1,true),w and w.text)
eq(#nauvis.list,count+4,'no entity made by the harness but the test\'s four respawns')
eq(s.mt.game.result,nil,'one team wiped: no end')
eq(#lines('red'),0,'agents are not told of a wipe')
-- a kill before production went down does not count
fresh();s.mt.first['shot blue>red']=10
_,rbox=home(red);rbox.status=defines.entity_status.no_power
r1=bot('r1',red,0)
game.tick=500;kill(r1,blue)
tick(1060);tick(1060+36060);eq(s.mt.game.teams.red.wiped,nil,'killed before the down time')
-- recovery clears the flag (and nothing restores it)
game.tick=40000;kill(r1,blue);tick(40060);ok(s.mt.game.teams.red.wiped)
rbox.status=defines.entity_status.working;tick(40200)
eq(s.mt.game.teams.red.wiped,nil);eq(s.mt.game.teams.red.down_since,nil)
local kinds2={};for _,x in ipairs(op().alerts) do kinds2[x.kind]=true end;ok(kinds2.recovered)
-- a team without agents is never flagged; nothing at all (all destroyed) is down
fresh();tick(1060);tick(1060+36060);eq(s.mt.game.teams.green.wiped,nil);eq(s.mt.game.teams.green.down_since,1060)

-- 6. The wipe win: every other team wiped; the operator confirms (default), or auto.
local function wipe_all_but(winner)
  fresh()
  s.mt.first['shot '..winner..'>red']=10;s.mt.first['shot '..winner..'>blue']=10;s.mt.first['shot '..winner..'>green']=10
  local up=add(nauvis,{type='lab',name='lab',force=game.forces[winner],status=defines.entity_status.working})
  local bs={}
  for _,f in ipairs({red,blue,green}) do if f.name~=winner then bs[#bs+1]=bot(f.name..'1',f,0) end end
  tick(1060)
  game.tick=2000;for _,b in ipairs(bs) do kill(b,game.forces[winner]) end
  return up
end
wipe_all_but('blue');tick(1060+36060)
ok(s.mt.game.teams.red.wiped and s.mt.game.teams.green.wiped,'both wiped')
eq(s.mt.game.result,nil,'confirm: no end yet')
local pending;for _,x in ipairs(op().alerts) do if x.kind=='wipe_win_pending' then pending=x end end
ok(pending and pending.team=='blue',pending and pending.text)
fails(function() op{end_by_wipe='red'} end,'blue is not wiped')
op{end_by_wipe='blue'}
res=s.mt.game.result;eq(res.reason,'wipe');eq(res.winner,'blue');eq(res.scores.blue,1.5);eq(res.by,'operator')
eq(last('blue'),'The run is over: every other team is wiped. We win. Our score: 1.5.')
eq(last('red'),'The run is over: blue wiped every other team.')
wipe_all_but('green');op{config={wipe_win='auto'}};tick(1060+36060)
eq(s.mt.game.result.reason,'wipe');eq(s.mt.game.result.winner,'green')
-- only after a confirmed wipe of every other team
fresh();fails(function() op{end_by_wipe='red'} end,'is not wiped')

-- 7. Milestones and the deadline: count, then the time of the latest one.
fresh()
s.mt.first['chart red>blue']=10
red.technologies['automation-science-pack']={researched=true};blue.technologies['automation-science-pack']={researched=true}
tick(1060)
red.technologies['logistic-science-pack']={researched=true};tick(4660)
blue.technologies['logistic-science-pack']={researched=true};tick(8260)
local st=op().standings
eq(st[1].team,'red');eq(st[1].milestones,2);eq(st[2].team,'blue');eq(st[2].rank,2);eq(st[3].team,'green');eq(st[3].milestones,0)
-- planets and rockets
blue.rockets_launched=1;local bp=platform(blue,'vulcanus');tick(11860)
bp.space_location={name='fulgora',type='planet'};tick(15460)
st=op().standings;eq(st[1].team,'blue');eq(st[1].milestones,6,'red/logistic, rocket, platform, two planets')
ok(s.mt.game.teams.blue.milestones['second-planet'] and not s.mt.game.teams.blue.milestones['third-planet'])
fails(function() op{config={deadline_tick=5}} end,'false or a tick from now on')
op{config={deadline_h=1}};eq(s.mt.game.config.deadline_tick,15460+216000)
tick(15460+216000)
res=s.mt.game.result;eq(res.reason,'milestones');eq(res.winner,'blue');eq(res.winners[1],'blue')
eq(last('red'),'The run is over at its time limit, ranked by milestones toward the edge: blue 6, our team 2.')
eq(last('green'),'The run is over at its time limit; our team reached 0 milestones toward the edge.')
ok(feed[1].text:find('blue leads',1,true),feed[1].text)
-- a tie: equal counts at the same tick share the lead
fresh()
red.technologies['automation-science-pack']={researched=true};green.technologies['automation-science-pack']={researched=true}
tick(1060);op{end_now=true}
res=s.mt.game.result;eq(#res.winners,2);eq(res.winner,nil);ok(res.text:find('share the lead',1,true),res.text)
-- a deadline set after a save/load still ends the run
fresh();op{config={deadline_tick=2000}};save_load();tick(1060);eq(s.mt.game.result,nil);tick(2000);eq(s.mt.game.result.reason,'milestones')

-- 8. Settings: refused whole, nothing half set.
fresh()
fails(function() op{config={solo=2,wipe_win='never'}} end,'confirm or auto');eq(s.mt.game.config.solo,nil)
fails(function() op{config={nope=1}} end,'is no setting')
fails(function() op{end_now=1} end,'end_now: true')
-- no teams set up: nothing runs, nothing is made in storage
s={bots={by_index={}}};load_modules();MT.game.tick(60);MT.game.on_died{entity={valid=true,type='character',force={name='player'}}}
eq(s.mt,nil,'no mt state on an ordinary map')
fails(function() op() end,'no teams set up')

-- 9. Check cadence: a team's checks run every check_s, arrivals every step.
fresh();home(red)
op{config={check_s=600}}
tick(1060);local first=s.mt.game.last_check
tick(1120);eq(s.mt.game.last_check,first,'not yet')
ship=platform(red,'solar-system-edge');tick(1180);ok(s.mt.game.result,'arrival seen between checks')

print('mt301: '..n..' checks passed')
