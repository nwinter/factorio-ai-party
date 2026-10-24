-- d20 batch71 AG1 (#1686, Sol). Run from the harness root: lua tests/d21_batch71.lua
-- Rail and chain signals on a rail layer: the signal spots of rail ends, the game's check on the layer asked (else
-- ground then elevated), the spot's facing when none is given, placements, inspect's read. Fake engine.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,err=pcall(f); assert(not ok,'did not fail'); has(err,x) end
defines={rail_direction={front=0,back=1},build_check_type={manual=1,manual_ghost=2},signal_state={open=0,closed=1,reserved=2,reserved_by_circuit_network=3},
  chain_signal_state={none=0,all_open=1,partially_open=2,none_open=3}}
prototypes={entity={['rail-signal']={type='rail-signal'},['rail-chain-signal']={type='rail-chain-signal'},['elevated-straight-rail']={type='elevated-straight-rail'}}}
-- an elevated east-west line at y=1: rails at x=-151,-149,-147; each joint has an out spot below (facing west) and an in
-- spot above (facing east), on the elevated layer (as 2.0.77 gave them)
local rails={}
local function rail(x)
  local r={valid=true,name='elevated-straight-rail',type='elevated-straight-rail',position={x=x,y=1}}
  r.get_rail_end=function(rd)
    local jx=rd==0 and x+1 or x-1
    local sx=rd==0 and jx-0.5 or jx+0.5
    return {in_signal_location={position={x=sx,y=-0.5},direction=4,rail_layer=1},out_signal_location={position={x=sx,y=2.5},direction=12,rail_layer=1}}
  end
  rails[#rails+1]=r
end
rail(-151); rail(-149); rail(-147)
local taken={}
local surface={find_entities_filtered=function(f)
    local out={}
    for _,r in ipairs(rails) do if (r.position.x-f.position.x)^2+(r.position.y-f.position.y)^2<=f.radius^2 then out[#out+1]=r end end
    return out
  end,
  can_place_entity=function(a)
    if a.rail_layer~=1 then return false end
    if taken[a.position.x..','..a.position.y] then return false end
    for _,r in ipairs(rails) do for rd=0,1 do local e=r.get_rail_end(rd)
      for _,l in ipairs({e.in_signal_location,e.out_signal_location}) do
        if math.abs(l.position.x-a.position.x)<0.01 and math.abs(l.position.y-a.position.y)<0.01 and l.direction==a.direction then return true end
      end
    end end
    return false
  end}
local R=require('railsignal'){position=function(p) return {x=p.x or p[1],y=p.y or p[2]} end,integer=function(v,d) return v or d end}
eq(R.layer_arg('elevated'),1); eq(R.layer_arg('ground'),0); eq(R.layer_arg(nil),nil)
fails(function() R.layer_arg('up') end,'rail_layer is ground or elevated')
-- the game's check: none asked, ground first then elevated
local c=R.check(surface,nil,'rail-signal',{x=-148.5,y=2.5},12,nil,true)
eq(c.ok,true); eq(c.layer,1)
c=R.check(surface,nil,'rail-signal',{x=-148.5,y=2.5},12,0,true)
eq(c.ok,false); has(c.why,'on the ground rail layer (its ghost check)'); has(c.why,'of 0 signal spots within 6 tiles on that layer, the game takes it on none now')
c=R.check(surface,nil,'rail-signal',{x=-148.5,y=2.5},0,1,false)
eq(c.ok,false); has(c.why,'facing north on the elevated rail layer; spots within 6 tiles the game takes it on now: (-148.5,2.5) facing west (elevated, beside elevated-straight-rail')
-- no direction: the facing of the spot there
local r=R.resolve(surface,nil,'rail-chain-signal',{x=-148.5,y=-0.5},nil,nil,true)
eq(r.direction,4); eq(r.layer,1); has(r.line,'facing east on the elevated rail layer (direction east: the signal spot there faces so)')
-- placements: the spots on that layer the game takes, nearest first; ground has none here
local p={surface=surface,position={x=-148,y=2}}
local pl=R.placements(p,{name='rail-signal',near={x=-148,y=2},radius=6,limit=50},prototypes.entity['rail-signal'])
eq(pl.count,12); eq(pl.placements[1].rail_layer,'elevated'); eq(pl.placements[1].position.y,2.5)
taken['-148.5,2.5']=true
pl=R.placements(p,{name='rail-signal',near={x=-148,y=2},radius=6,limit=50},prototypes.entity['rail-signal'])
eq(pl.count,11); eq(pl.refused,1)
eq(R.placements(p,{name='rail-signal',near={x=-148,y=2},radius=6,rail_layer='ground'},prototypes.entity['rail-signal']).count,0)
-- inspect's read
local sig={valid=true,type='rail-chain-signal',name='rail-chain-signal',position={x=-146.5,y=-0.5},rail_layer=1,signal_state=0,chain_signal_state=1,
  get_connected_rails=function() return {rails[3]} end}
local rd=R.read(sig)
eq(rd.rail_layer,'elevated'); eq(rd.rails[1].name,'elevated-straight-rail'); eq(rd.signal_state,'open'); eq(rd.state,'all_open')
has(rd.line,'rail-chain-signal (-146.5,-0.5) on the elevated rail layer, attached to elevated-straight-rail (-147,1); block open, chain all_open')
eq(R.read({valid=true,type='entity-ghost',ghost_type='rail-signal'}).note,'a ghost: its rail layer and rails are read once built')
eq(R.read({valid=true,type='assembling-machine'}),nil)
-- a ghost entry and a build entry take rail_layer
local A=dofile('mod/agent-harness_0.1.0/argshapes.lua')()
A.check('place_ghosts',{entities={{name='rail-signal',position={x=1,y=2},rail_layer='elevated'}}})
A.check('build',{builds={{item='rail-signal',position={x=1,y=2},rail_layer='elevated'}}})
print('d21_batch71 AG1 signals on a rail layer: ok')

-- AG2 (#1688, Sol): rolling stock's facing is orientation; rotate flips it 180 degrees, uncoupling and coupling again
-- (the game's rotate refuses one coupled to another); readback of the train's locomotives each way.
defines.train_state={on_the_path=0,manual_control=9}
local K=require('rollingstock'){}
eq(K.direction_of_orientation(0.5),8); eq(K.direction_of_orientation(0.6),10); eq(K.direction_of_orientation(1),0)
fails(function() K.direction_of_orientation(2) end,'orientation is 0..1')
eq(K.facing(0.25),'east'); eq(K.opposite(0,8),true); eq(K.opposite(0.5,8),false); eq(K.opposite(0.5,4),false)
-- a fake train of A (facing north) and B (north) coupled B front to A
local A,B
local train={id=31,carriages={},speed=0,manual_mode=true,state=9}
local function locos()
  local f,b={},{}
  for _,c in ipairs(train.carriages) do if c.orientation==0 then f[#f+1]=c else b[#b+1]=c end end
  return {front_movers=f,back_movers=b}
end
setmetatable(train,{__index=function(_,k) if k=='locomotives' then return locos() end end})
local function loco(y,o)
  local e={valid=true,type='locomotive',name='locomotive',position={x=-151,y=y},orientation=o,train=train,links={}}
  e.get_connected_rolling_stock=function(rd) return e.links[rd] end
  e.disconnect_rolling_stock=function(rd) local o2=e.links[rd]; if not o2 then return false end; e.links[rd]=nil
    for k,v in pairs(o2.links) do if v==e then o2.links[k]=nil end end; return true end
  e.connect_rolling_stock=function(rd)
    -- the other one stands north of B: B's front when it faces north, its back when south
    local side=e.orientation==0 and 0 or 1
    if rd~=side or e.links[rd] then return false end
    e.links[rd]=A; A.links[1]=e; return true end
  e.rotate=function() if e.links[0] or e.links[1] then return false end; e.orientation=(e.orientation+0.5)%1; return true end
  return e
end
A=loco(-5,0); B=loco(2,0)
B.links[0]=A; A.links[1]=B
train.carriages={A,B}
local rd0=K.read(B)
eq(rd0.train.front_locomotives,2); eq(rd0.train.back_locomotives,0); eq(rd0.facing,'north')
local out=K.rotate(B,nil,nil)
eq(out.flipped,'uncoupled from locomotive (-151,-5); flipped from north to south; coupled to locomotive (-151,-5)')
eq(out.rolling_stock.orientation,0.5); eq(out.rolling_stock.train.front_locomotives,1); eq(out.rolling_stock.train.back_locomotives,1)
has(out.rolling_stock.line,'faces south (orientation 0.5); coupled: front none, back locomotive (-151,-5)')
has(K.rotate(B,8,nil).unchanged,'already faces south')
train.speed=0.2
fails(function() K.rotate(B,0,nil) end,'its train moves (speed 0.2)')
print('d21_batch71 AG2 rolling stock: ok')

-- d20 batch71 AG4 (#1699, Astra): a platform's own network read whole from its surface. As on 2.0.77: 3 solar panels,
-- 2 assemblers on low power and an accumulator on network 1456 (one assembler under a pole); 2 poles on network 1457
-- with nothing on it, and 1 pole on 1460 with a panel on it (electrically apart).
game={tick=43217816}
defines.entity_status={working=1,low_power=14,no_power=2}
defines.flow_precision_index={five_seconds=0}
prototypes.surface_property={['solar-power']={default_value=100}}
local stats={input_counts={['assembling-machine-1']=2},output_counts={['solar-panel']=3},
  get_flow_count=function(a) return ({['assembling-machine-1']=3000,['solar-panel']=3000})[a.name] end}
local function ent(t,id,x) return {valid=true,type=t,name=t,position={x=x,y=0},electric_network_id=id,
  prototype={get_max_energy_production=function() return 1000 end}} end
local list={ent('solar-panel',1456,1),ent('solar-panel',1456,2),ent('solar-panel',1456,3),ent('electric-pole',1457,4),ent('electric-pole',1457,5),
  ent('assembling-machine',1456,6),ent('assembling-machine',1456,7),ent('accumulator',1456,8),ent('electric-pole',1460,9),ent('solar-panel',1460,10)}
list[6].electric_buffer_size,list[6].energy,list[6].status=1000,250,14
list[7].electric_buffer_size,list[7].energy,list[7].status=1000,350,14
list[8].electric_buffer_size,list[8].energy=5000000,2500000
local plat_surface={name='platform-7',has_global_electric_network=true,global_electric_network_statistics=stats,
  platform={name='Prospect',space_location={name='nauvis',solar_power_in_space=300}},find_entities_filtered=function() return list end}
local NW=require('networks'){state=function() return {} end}
local pp=NW.platform_power(plat_surface,{name='player'})
eq(pp.network,1456); eq(pp.tick,43217816); eq(pp.draw_kw,180); eq(pp.production_kw,180)
eq(pp.solar.count,3); eq(pp.solar.kw,540); eq(pp.capacity_kw,540); eq(pp.accumulators.pct,50)
eq(pp.satisfaction.machines,2); eq(pp.satisfaction.low_power,2); eq(pp.satisfaction.power_bars_pct,30); eq(pp.satisfaction.low_power_bars_pct,30)
eq(pp.poles,3); eq(pp.separate_pole_networks[1],1460)
has(pp.line,'Prospect electric #1456, the platform\'s own network (every machine, panel and accumulator of ours on it; no pole needed), at tick 43217816')
has(pp.line,'draw 180 kW now, production 180 kW (the last 5 s, every quality)')
has(pp.line,'capacity 540 kW: 3 solar panels giving up to 540 kW at solar power 300% at nauvis')
has(pp.line,'machines 2: 2 low power, 0 no power; their power bars 30% full on average, those on low power 30%')
has(pp.line,'3 poles of ours (network #1457: no machine, panel or accumulator on them; a pole\'s statistics there are this network\'s); electrically apart with machines or panels on them: #1460 (their own rows)')
plat_surface.has_global_electric_network=false
eq(NW.platform_power(plat_surface,{name='player'}),nil)
print('d21_batch71 AG4 platform power: ok')
