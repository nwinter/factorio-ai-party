-- One ammunition model for a trip (d20 batch51 H1, viewer Aurora 09:36: "Could departure and route forecasts use the same
-- ingredient limits as endurance, including shared stock?"). Shift46 15:48, Kestrel IVa: one platform_endurance reply
-- gave firearm-magazine "1461 aboard and about 828 made on the way: 1438 to spare" (departure) while its own row capped
-- what the ingredients aboard make at about 444 and its forecast ended at -1226. Here one ship read by endurance (rows,
-- departure, flight, forecast) and by freight.ammo (preflight's and the platforms read's ammo_rates) comes to the same
-- numbers: stock less what can reach no turret, rockets on their way up once, made at most what the ingredients allow
-- (iron plates split between magazines and rockets by their rates, other machines' use first), and which limit binds.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or '')..' expected '..tostring(b)..' got '..tostring(a),2) end end
local function has(s,sub,m) assert(type(s)=='string' and s:find(sub,1,true),(m and m..': ' or '')..tostring(s)..' lacks '..sub) end
local function inv(t) return {get_contents=function() local o={} for k,v in pairs(t) do if v>0 then o[#o+1]={name=k,count=v} end end return o end} end

defines={flow_precision_index={ten_minutes=2,five_seconds=0},inventory={hub_main=1,turret_ammo=9,assembling_machine_input=2}}
game={tick=100000}
local spawn={{asteroid='medium-metallic-asteroid',type='entity',spawn_points={{distance=0,probability=0.01},{distance=1,probability=0.01}}}}
local bullet={category='bullet',action={{action_delivery={{type='instant',target_effects={{type='damage',damage={amount=5,type='physical'}}}}}}}}
prototypes={item={['firearm-magazine']={type='ammo',weight=10000,get_ammo_type=function() return bullet end},rocket={type='ammo',weight=20000},
    ['iron-plate']={type='item'},explosives={type='item'}},
  fluid={['thruster-fuel']={},['thruster-oxidizer']={}},
  entity={['medium-metallic-asteroid']={get_max_health=function() return 400 end,resistances={}}},
  space_location={nauvis={solar_power_in_space=100},gleba={solar_power_in_space=100}},
  space_connection={ng={from={name='nauvis'},to={name='gleba'},length=15000,asteroid_spawn_definitions=spawn}},
  utility_constants={rocket_lift_weight=1000000}}

-- Kestrel IVa flying Nauvis -> Gleba, 15000 km left at 1500 km/min (10 min), then back (10 min): 20 minutes.
-- Per minute over the last 10: magazines made 60, used 70; rockets made 10, used 20; iron plates made 50 (furnaces),
-- used 300 (240 by the magazine makers at 4 a craft, 20 by the rocket makers at 2, 40 by other machines); explosives used
-- 10 (the rocket makers').
local per={['firearm-magazine']={60,70},rocket={10,20},['iron-plate']={50,300},explosives={0,10}}
local stats={get_flow_count=function(a) local r=per[a.name]; return r and (a.category=='input' and r[1] or r[2])*10 or 0 end,
  get_input_count=function(n) return 0 end,get_output_count=function(n) return 0 end}
local main={['firearm-magazine']=1400,rocket=200,['iron-plate']=400,explosives=100}
local hubinv=setmetatable({get_contents=function() return inv(main).get_contents() end,count_empty_stacks=function() return 10 end},{__len=function() return 60 end})
local hub={valid=true,get_inventory=function(id) assert(id==1); return hubinv end}
local turret={name='gun-turret',get_inventory=function() return inv({['firearm-magazine']=61}) end}
local function asm(recipe) return {get_recipe=function() return recipe end,get_inventory=function() return inv({}) end,get_output_inventory=function() return inv({}) end,fluidbox={}} end
local mags=asm({products={{name='firearm-magazine',amount=1}},ingredients={{type='item',name='iron-plate',amount=4}}})
local rockets=asm({products={{name='rocket',amount=1}},ingredients={{type='item',name='explosives',amount=1},{type='item',name='iron-plate',amount=2}}})
local surf={name='platform-12',find_entities_filtered=function(f)
  if f.type=='ammo-turret' then return {turret} end
  if f.type=='assembling-machine' then return {mags,rockets} end
  if type(f.type)=='table' and f.type[1]=='assembling-machine' then return {mags,rockets} end
  return {} end}
local force={get_item_production_statistics=function() return stats end,get_fluid_production_statistics=function() return {get_flow_count=function() return 0 end} end,
  get_ammo_damage_modifier=function() return 0 end,get_turret_attack_modifier=function() return 0 end}
local pl={valid=true,index=12,name='Kestrel IVa',surface=surf,force=force,hub=hub,speed=25/60,distance=0,
  space_connection={from={name='nauvis'},to={name='gleba'},length=15000},schedule={current=2,records={{station='nauvis'},{station='gleba'}}}}
-- a rocket from Nauvis on its way up with 100 magazines
local incoming={rockets=1,rows={{cargo={['firearm-magazine']=100},from='nauvis',tick=99000}}}
-- the leg it flew last (for the forecast's scale): the same connection, 10 minutes, finished 4000 ticks ago
local segs={{kind='leg',from='gleba',to='nauvis',start=60000,['end']=96000}}
local stranded={}
local feed=function() return {reaches=1461,stranded=0,stranded_by={},hub_stranded=stranded,stranded_groups={}} end

local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
local bgs={}  -- each trace asked for: background or in the call
local AM=dofile('mod/agent-harness_0.1.0/ammomodel.lua'){stock_places=F.stock_places,ammofeed={get=function(p,age,bg) bgs[#bgs+1]=bg or false; return feed(p) end},incoming=function() return incoming end}
-- freight.lua's record: the leg it flies, opened before its counts were kept (its rates: the last 10 minutes)
local fst={freight={[12]={segs={{kind='leg',from='nauvis',to='gleba',start=64000}}}}}
local F2=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return fst end,ammomodel=function() return AM end}
local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){platform=function() return pl end,leg=function() return {from='nauvis',to='gleba',left_km=15000} end,
  segments=function() return segs end,stock_places=F.stock_places,places_text=F.places_text,moved_text=F.moved_text,ammomodel=AM,
  phase_rates=function(_,name) return name=='firearm-magazine' and {moving={minutes=30,used=70,made=60}} or name=='rocket' and {moving={minutes=30,used=20,made=10}} or nil end}

-- The model alone: the iron plates' pool is 400 aboard + 50/min made - 40/min other machines' use = 400 + 10t; the
-- magazines' share 240/260, the rockets' 20/260.
do
  local m=AM.new(pl)
  m.make('firearm-magazine',60); m.make('rocket',10)
  eq(m.held['firearm-magazine'],1461,'hub and turrets'); eq(m.received['firearm-magazine'],100,'on its way up')
  local c=m.cap('firearm-magazine')
  eq(c.item,'iron-plate'); eq(c.more,92,'floor(400 x 240/260 / 4)'); eq(c.share,0.92); eq(c.shared.rocket,0.08); eq(c.other_use_per_min,40)
  eq(c.at(20),138,'floor(600 x 240/260 / 4)')
  eq(m.made('firearm-magazine',60,20),138); eq(m.made('firearm-magazine',60,1),60,'the rate binds over a minute')
  eq(m.cap('rocket').at(20),23,'iron binds rockets too: floor(600 x 20/260 / 2), explosives 100')
  eq(m.left('firearm-magazine',60,70,20),1461+100+138-1400)
  local b=m.binds('firearm-magazine',60,20)
  eq(b.kind,'ingredients')
  eq(b.line,'binds: the ingredients: iron-plate (400 aboard, shared with rocket 8% by make rate: this one 92%; other machines use 40/min of it): at most 138 more over 20m00s, against 1200 at 60/min')
  eq(m.binds('firearm-magazine',60,1).kind,'rate'); has(m.binds('firearm-magazine',60,1).line,'binds: the make rate (60/min; the ingredients aboard cover 1m00s')
  eq(m.binds('rocket',0,20).line,'binds: the stock (none made aboard)')
  -- alone (the rockets not made): the magazines get the whole pool
  m.make('rocket',0)
  eq(m.cap('firearm-magazine').at(20),50,'floor((400 + 50t - 60t) / 4): what the rockets were measured using counts as other use'); eq(m.cap('firearm-magazine').shared,nil)
end
print('ammomodel model: ok')

-- Endurance: the rows, the departure line, the flight line and the forecast all count the same 138 made and 100 received.
do
  local r=E.read({},{platform='Kestrel IVa',route={'nauvis','gleba','nauvis'},forecast=true})
  eq(r.total_minutes,20); eq(bgs[#bgs],false,'endurance traces in the call, as before')
  local by={}; for _,x in ipairs(r.resources) do by[x.name]=x end
  local fm=by['firearm-magazine']
  eq(fm.stock,1461); eq(fm.received,100); eq(fm.at_end,299,'1461 + 100 + 138 - 1400')
  eq(fm.ingredient_limited.more,92); eq(fm.ingredient_limited.shared.rocket,0.08)
  has(fm.line,'; 100 more on rockets on their way up, counted')
  has(fm.line,'; at the route\'s end about 299; binds: the ingredients: iron-plate (400 aboard, shared with rocket 8%')
  local dep
  for _,l in ipairs(r.departure) do if l:find('^firearm%-magazine') then dep=l end end
  has(dep,'firearm-magazine over the route (20m00s): uses about 1400 at 70/min; 1461 aboard, 100 on rockets on their way up and about 138 made on the way: 299 to spare (binds: the ingredients: iron-plate')
  has(fm.flight,'uses about 1400, with 1461 aboard, 100 on rockets on their way up and about 138 made: 299 to spare (binds: the ingredients: iron-plate')
  -- the forecast: 115 made by Gleba (the cap at 10 min), 23 more by Nauvis; 299 left at the end, as the row
  local text=table.concat(r.forecast,'\n')
  has(text,'uses about 700 (70/min on the legs flown x1.00 for these asteroids), about 115 made (the ingredients bind: iron-plate); 976 left at gleba')
  has(text,'uses about 700 (70/min on the legs flown x1.00 for these asteroids), about 23 made (the ingredients bind: iron-plate); 299 left at nauvis')
  has(text,'firearm-magazine over the forecast (20m00s, 100 on rockets on their way up counted at the start): binds: the ingredients: iron-plate')
  -- rockets: 200 + 23 - 400, gone on the way back
  eq(by.rocket.at_end,-177); eq(by.rocket.runs_out_on,'gleba->nauvis'); has(by.rocket.line,'binds: the ingredients: iron-plate')
end
print('ammomodel endurance: ok')

-- freight.ammo (preflight's and the platforms read's ammo_rates): the same leg comes to Gleba with 976, as the forecast.
do
  local a=F2.ammo(pl)
  local fm
  for _,l in ipairs(a) do if l:find('^firearm%-magazine') then fm=l end end
  has(fm,'firearm-magazine: made 60/min, used 70/min'); eq(bgs[#bgs],true,'ammo_rates takes the background trace: preflight and the platforms read trace nothing more')
  has(fm,'1461 aboard: hub 1400, turrets 61; 100 more on rockets on their way up, counted')
  has(fm,'; at the arrival at gleba in 10m00s about 976 at that rate; binds: the ingredients: iron-plate (400 aboard, shared with rocket 8%')
  -- 400 magazines in a hub no inserter takes from toward a turret: left out by every reader alike
  stranded['firearm-magazine']=400
  fm=nil
  for _,l in ipairs(F2.ammo(pl)) do if l:find('^firearm%-magazine') then fm=l end end
  has(fm,'1461 aboard: hub 1400, turrets 61; 400 of it can reach no turret (stranded), not counted: 1061')
  has(fm,'about 576 at that rate')
  local r=E.read({},{platform='Kestrel IVa',route={'nauvis','gleba','nauvis'}})
  for _,x in ipairs(r.resources) do if x.name=='firearm-magazine' then eq(x.stock,1061); eq(x.at_end,-101,'1061 + 100 + 138 - 1400') end end
  stranded['firearm-magazine']=nil
  -- without the model (an older caller): the rate times the time, as before
  local F3=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return fst end}
  for _,l in ipairs(F3.ammo(pl)) do if l:find('^firearm%-magazine') then has(l,'about 1361 at that rate'); assert(not l:find('binds',1,true),l) end end
end
print('ammomodel freight: ok')
prototypes,defines,game=nil,nil,nil
