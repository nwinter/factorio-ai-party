-- d22 batch96 BF1 part 1: the platform read (dispatch platform: 40.6 ms on world n at 14:06, worst 83.5) on a copy of
-- world n's 13:05 autosave spent most of Asterion's 77-93 ms in freight.stock_places (its 6,651 belts found in 24 ms and
-- read in 44), then a find of every entity aboard for the damaged list (33 ms for 7,957, capped at 5,000), the hub
-- inserters (every inserter aboard, capped at 500) and the ammo model's quarter-minute stepping (5.9 ms a row).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={inventory={hub_main=1,hub_trash=2,turret_ammo=3,assembling_machine_output=4},flow_precision_index={ten_minutes=1}}
game={tick=3600*10}

-- 1. stock_places takes the census pass's belts and hands and its turrets and machines: no find over the platform
do
  local finds={}
  local function inv(list) return {get_contents=function() return list end} end
  local hub={valid=true,get_inventory=function(i) return i==1 and inv({{name='rocket',count=40}}) or nil end}
  local turret={valid=true,get_inventory=function() return inv({{name='rocket',count=10}}) end}
  local machine={valid=true,get_output_inventory=function() return inv({{name='rocket',count=2}}) end}
  local surface={index=7,find_entities_filtered=function(f) finds[#finds+1]=f; return {} end}
  local pl={surface=surface,force={name='player'},hub=hub}
  local idx={belts={rocket=300,['iron-plate']=50},hands={rocket=3},as_of=3600*9}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end,
    census_where=function(f,s) eq(s,surface); return idx end,
    census_typed=function(f,s,t) if t=='ammo-turret' then return {turret} end return {machine} end}
  local ALL=setmetatable({},{__index=function() return true end})
  local sp=F.stock_places(pl,ALL)
  eq(#finds,0,'no find over the platform')
  eq(sp.hub.rocket,40); eq(sp.turrets.rocket,10); eq(sp.belts.rocket,300); eq(sp.hands.rocket,3); eq(sp.machines.rocket,2)
  eq(sp.total.rocket,355); eq(sp.total['iron-plate'],50); eq(sp.from_census,true); eq(sp.as_of,3600*9)
  -- want: only those items
  sp=F.stock_places(pl,{rocket=true})
  eq(sp.belts['iron-plate'],nil); eq(sp.total.rocket,355)
  -- a surface the census has not walked: read now, as before
  local F2=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end,census_where=function() return nil end}
  sp=F2.stock_places(pl,ALL)
  assert(#finds>0,'read now'); eq(sp.from_census,nil); eq(sp.hub.rocket,40)
end
print('d22_batch96 BF1 stock_places from the census: ok')

-- 2. the census counts an underground exit's buried lines once (its entrance's), as stock_places does
do
  local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return {} end,walk={}}
  local function line(items) local function c() local o={} for _,x in ipairs(items) do o[#o+1]=x end return o end
    return {id=items.id,get_contents=c,line_equals=function(o) return o.id==items.id end} end
  local buried3,buried4={id=3,{name='coal',count=4}},{id=4,{name='coal',count=4}}
  local entrance={valid=true,type='underground-belt',name='underground-belt',position={x=0,y=0},belt_to_ground_type='input',
    get_max_transport_line_index=function() return 4 end}
  local lines_in={line({id=1,{name='coal',count=1}}),line({id=2}),line(buried3),line(buried4)}
  entrance.get_transport_line=function(i) return lines_in[i] end
  local exit={valid=true,type='underground-belt',name='underground-belt',position={x=0,y=5},belt_to_ground_type='output',neighbours=entrance,
    get_max_transport_line_index=function() return 4 end}
  local lines_out={line({id=5,{name='coal',count=2}}),line({id=6}),line(buried3),line(buried4)}
  exit.get_transport_line=function(i) return lines_out[i] end
  local job={belt_items={},where={}}
  local ctx={si=1,surface_name='platform-1'}
  C.read_entity(job,{index=1},entrance,ctx); C.read_entity(job,{index=1},exit,ctx)
  eq(job.belt_items[1].coal,1+8+2,'the buried 8 once')
end
print('d22_batch96 BF1 census underground lines once: ok')

-- 3. the damaged list: one read of every entity seeds it; then the game's damage events add to it, and a read checks
-- only those (healed or gone ones drop out); a full list reads every entity again
do
  local st={}
  local PA=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end}
  local own={name='player'}
  local pl={index=4,name='Asterion',valid=true}
  local surface={name='platform-4',platform=pl}
  pl.surface=surface
  local function ent(u,h,m) return {valid=true,unit_number=u,health=h,max_health=m,force=own,surface=surface,name='belt'..u,position={x=u,y=0}} end
  local a,b,c=ent(1,50,100),ent(2,100,100),ent(3,100,100)
  eq(PA.damaged(pl).seeded,false)
  PA.seed_damaged(pl,{a})
  eq(PA.damaged(pl).seeded,true)
  c.health=40
  PA.on_damaged({entity=c,force={name='enemy'},final_damage_amount=60,tick=game.tick})
  local set=PA.damaged(pl).set
  assert(set[1]==a and set[3]==c and set[2]==nil,'a and c')
  a.health=100  -- repaired
  PA.forget_damaged(pl,{1})
  assert(PA.damaged(pl).set[1]==nil)
  -- full: more than DAMAGED_MAX hit: not seeded any more (the next read reads every entity)
  for u=10,10+PA.DAMAGED_MAX do local e=ent(u,1,100); PA.on_damaged({entity=e,force={name='enemy'},final_damage_amount=1,tick=game.tick}) end
  eq(PA.damaged(pl).seeded,false)
end
print('d22_batch96 BF1 damaged list from damage events: ok')

-- 4. lasts: found by halving the quarter-minute steps, the same minute as stepping one at a time
do
  local AM=dofile('mod/agent-harness_0.1.0/ammomodel.lua'){}
  local function stepping(at)
    if at(1440)>0 then return nil end
    local lo,hi=0,0.25
    while at(hi)>0 do lo,hi=hi,hi+0.25 end
    for _=1,8 do local mid=(lo+hi)/2; if at(mid)>0 then lo=mid else hi=mid end end
    return hi
  end
  -- a model whose cap binds: made at most 50 over any time, used 3 a minute, from 400 aboard
  local cases={{stock=400,made=10,used=3,cap=50},{stock=5,made=1,used=3,cap=100},{stock=3000,made=2,used=4,cap=0},{stock=0,made=1,used=2,cap=0}}
  for _,c in ipairs(cases) do
    local m={held={x=c.stock},received={}}
    function m.made(name,made,t) return math.min(made*t,c.cap) end
    function m.cap(name) return {} end
    function m.left(name,made,used,t,stock) return (stock or m.held[name] or 0)+m.made(name,made,t)-used*t end
    -- the module's lasts on this model (its body reads m.cap, m.left)
    local new=AM.lasts_of(m,'x',c.made,c.used,c.stock)
    local old=stepping(function(t) return m.left('x',c.made,c.used,t,c.stock) end)
    eq(new,old,'stock '..c.stock)
  end
end
print('d22_batch96 BF1 lasts by halving: ok')

-- 5. thrust: the thrusters found once a tick, read and after_pumps share it
do
  local n=0
  local thr={valid=true,name='thruster',position={x=0,y=0},fluidbox=setmetatable({},{__len=function() return 0 end})}
  local s={index=9,find_entities_filtered=function(f) if f.type=='thruster' then n=n+1; return {thr} end return {} end,
    count_entities_filtered=function() return 0 end}
  local TH=dofile('mod/agent-harness_0.1.0/thrust.lua'){}
  local pl={surface=s,force={name='player'}}
  TH.read(pl); TH.read(pl)
  eq(n,1,'one find in the tick')
  game.tick=game.tick+1
  TH.read(pl)
  eq(n,2,'a new tick finds again')
end
print('d22_batch96 BF1 thrusters once a tick: ok')
defines,game=nil,nil
