-- d28 batch304 EC (Updates row endurance-cost, the plain platform_endurance under 10 ms on world n): one find a call of
-- the entities the read looks at, kept by platform in storage and checked each call by a count and their valid flags;
-- the thruster and tank fluids read once a call; the speed (and its geometry) once a call; the platform's own electric
-- network with no pole found; no statistics read for an item never counted; the status count by type; the ammunition
-- trace's belt count from the trace done; the hull's width by halving each strip.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

defines={flow_precision_index={one_minute=1,ten_minutes=2,five_seconds=0},inventory={hub_main=1,turret_ammo=1,assembling_machine_input=2},
  entity_status={low_power=7,no_power=8,working=1}}
game={tick=600000}
local SCAN_TYPES={'thruster','storage-tank','pump','ammo-turret','assembling-machine','furnace','inserter','electric-turret',
  'asteroid-collector','radar','roboport','lab','beacon','solar-panel'}
local entity_names={['thruster']='thruster',['storage-tank']='storage-tank',pump='pump',['ammo-turret']='gun-turret',
  ['assembling-machine']='chemical-plant',['solar-panel']='solar-panel',inserter='inserter',['transport-belt']='transport-belt'}
prototypes={item={['firearm-magazine']={type='ammo'},['repair-pack']={type='repair-tool'},['iron-plate']={type='item'},
    ['metallic-asteroid-chunk']={type='item'}},
  fluid={['thruster-fuel']={},['thruster-oxidizer']={}},
  space_location={nauvis={solar_power_in_space=100},fulgora={solar_power_in_space=120}},
  space_connection={a={from={name='nauvis'},to={name='fulgora'},length=15000}},
  entity=setmetatable({},{__index=function(_,n) for t,name in pairs(entity_names) do if name==n then return {type=t} end end end}),
  get_recipe_filtered=function() return {{category='chemistry'}} end,
  get_entity_filtered=function(f)
    local out={}
    local want=f[1].type or (f[1].crafting_category and 'assembling-machine')
    for _,t in ipairs(type(want)=='table' and want or {want}) do if entity_names[t] then out[entity_names[t]]=true end end
    return out
  end}

-- The engine as far as the read touches it, counting its finds, counts, fluid box and statistics reads.
local calls
local function reset() calls={finds={},counts={},fluidbox=0,flow={},tiles=0} end
reset()
local world={}
local function ent(t,o) o=o or {}; o.type=t; o.name=o.name or entity_names[t]; o.valid=true; world[#world+1]=o; return o end
local function boxes(list)
  return setmetatable({},{__len=function() return #list end,__index=function(_,i) if type(i)=='number' then calls.fluidbox=calls.fluidbox+1 end return list[i] end})
end
local function inv(t) return {get_contents=function() local out={} for n,c in pairs(t) do out[#out+1]={name=n,count=c} end return out end} end
local thruster=ent('thruster',{fluidbox=boxes({{name='thruster-fuel',amount=1000},{name='thruster-oxidizer',amount=800}})})
local tank=ent('storage-tank',{fluidbox=boxes({{name='thruster-fuel',amount=5000}})})
local turret=ent('ammo-turret',{status=7,electric_buffer_size=0,get_inventory=function() return inv({['firearm-magazine']=50}) end})
local maker=ent('assembling-machine',{name='assembler',status=1,get_recipe=function() return {name='firearm-magazine',energy=1,
    products={{type='item',name='firearm-magazine',amount=1}},ingredients={{type='item',name='iron-plate',amount=4}}} end,
  get_inventory=function() return inv({}) end,get_output_inventory=function() return inv({}) end,fluidbox=boxes({})})
local hand=ent('inserter',{status=7})
local panel=ent('solar-panel',{quality={name='normal'},prototype={get_max_energy_production=function() return 1000 end}})
local function matches(e,f)
  if f.type then
    local ok=false
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if e.type==t then ok=true end end
    if not ok then return false end
  end
  if f.name then
    local ok=false
    for _,n in ipairs(type(f.name)=='table' and f.name or {f.name}) do if e.name==n then ok=true end end
    if not ok then return false end
  end
  return e.valid
end
local function key(f)
  local t=f.type or f.name
  return type(t)=='table' and table.concat(t,',') or tostring(t)
end
local belts=3
local foundation={lo=-20,hi=19}
local surface={index=5,name='platform-5',has_global_electric_network=true,
  global_electric_network_statistics={output_counts={['solar-panel']=1},input_counts={inserter=1},
    get_flow_count=function(a) return a.category=='output' and 1000 or 500 end,
    get_input_count=function() return 1 end,get_output_count=function() return 1 end},
  find_entities_filtered=function(f)
    local k=key(f); calls.finds[k]=(calls.finds[k] or 0)+1
    local out={}
    for _,e in ipairs(world) do if matches(e,f) then out[#out+1]=e end end
    return out
  end,
  count_entities_filtered=function(f)
    local k=key(f); calls.counts[k]=(calls.counts[k] or 0)+1
    if f.name and type(f.name)=='table' and f.name[1]=='transport-belt' then return belts end
    local n=0
    for _,e in ipairs(world) do if matches(e,f) then n=n+1 end end
    return n
  end,
  count_tiles_filtered=function(f)
    calls.tiles=calls.tiles+1
    local x0,x1=f.area[1][1],f.area[2][1]
    return (x0<=foundation.hi and x1>foundation.lo) and 1 or 0
  end}
-- items: magazines made 10 and used 20 a minute (normal only), iron plates made 5; nothing else ever counted
local per={['firearm-magazine']={10,20},['iron-plate']={5,0}}
local items={input_counts={['firearm-magazine']=1000,['iron-plate']=500},output_counts={['firearm-magazine']=900},
  get_flow_count=function(a)
    local name=type(a.name)=='table' and a.name.name or a.name
    calls.flow[name]=(calls.flow[name] or 0)+1
    if type(a.name)=='table' then calls.pairs=(calls.pairs or 0)+1 end
    local r=per[name]
    if type(a.name)=='table' then return 0 end
    return r and (a.category=='input' and r[1] or r[2])*(a.precision_index==2 and 10 or 1) or 0
  end,
  get_input_count=function(n) return type(n)=='string' and 1000 or 0 end,get_output_count=function(n) return type(n)=='string' and 900 or 0 end}
local fluids={get_flow_count=function() return 0 end}
local force={index=1,get_item_production_statistics=function() return items end,get_fluid_production_statistics=function() return fluids end}
local hub=setmetatable({get_contents=function() return {{name='firearm-magazine',count=200},{name='iron-plate',count=40}} end,
  count_empty_stacks=function() return 9 end},{__len=function() return 50 end})
local pl={valid=true,index=5,name='Tern',surface=surface,force=force,hub={valid=true,get_inventory=function() return hub end},speed=0,
  space_location={name='nauvis'},schedule={current=1,records={{station='nauvis'},{station='fulgora'}}}}
local state={}
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return state end}
local geometry_calls,thruster_lists=0,{}
local leg
local segs={{kind='leg',from='fulgora',to='nauvis',start=0,['end']=36000,km0=0,km1=15000,thrusters=1,width=40,
  ammo0={['firearm-magazine']={made=0,used=0}},ammo1={['firearm-magazine']={made=100,used=200}}},{kind='stop',at='nauvis',start=36000}}
local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){state=function() return state end,platform=function() return pl end,
  leg=function() return leg end,segments=function() return segs end,stock_places=F.stock_places,places_text=F.places_text,
  geometry=function(p,list) geometry_calls=geometry_calls+1; return F.geometry(p,list) end,
  thrusters=function(p,list) thruster_lists[#thruster_lists+1]=list; return {line='1 thruster',per_min=7200} end}

-- 1: the first call finds once, by every type it reads; nothing else is found
local r=E.read({},{platform='Tern'})
eq(calls.finds[table.concat(SCAN_TYPES,',')],1,'one find of the types the read looks at')
-- (belts: freight's background read when it has one; this platform has none yet, so its belts are found, as before)
local others=0 for k,n in pairs(calls.finds) do if k~=table.concat(SCAN_TYPES,',') and not k:find('^transport%-belt') then others=others+n end end
eq(others,0,'no other find: the pole, turrets, machines, panels, tanks and thrusters all come from it')
eq(calls.fluidbox,6,'the thrusters\' and tanks\' boxes read for the stock once a call (the fluid rows and the outlook ask it), and once by the outlook\'s segment read')
eq(geometry_calls,1); eq(calls.tiles<=20,true,'the hull width by halving: '..calls.tiles..' counts')
has(r.speed_from,'the last leg fulgora->nauvis')
eq(thruster_lists[1][1],thruster,'the outlook\'s thrusters from the call\'s find')
eq(r.low_power,2,'the inserter and the turret with no buffer on low power'); eq(r.no_power,0)
has(r.solar,'1 solar panels: 60 kW at full sun'); eq(r.solar:find('firing from a buffer',1,true),nil)
print('d28_batch304 first call: ok')

-- 2: the next call finds nothing: one count of those types, and the kept ones still valid
reset(); game.tick=game.tick+600
local r2=E.read({},{platform='Tern'})
eq(next(calls.finds) and calls.finds[table.concat(SCAN_TYPES,',')] or 0,0,'no find')
eq(calls.counts[table.concat(SCAN_TYPES,',')],1,'one count')
eq(state.endurance_scan[5].n,6); eq(state.endurance_scan[5].tick,game.tick)
-- the same reply as the first call (nothing aboard changed)
eq(r2.solar,r.solar); eq(r2.fuel_outlook,r.fuel_outlook); eq(#r2.resources,#r.resources)
for i,x in ipairs(r.resources) do eq(r2.resources[i].line,x.line) end
-- statistics: an item never counted is not read; one only ever counted at normal is read at normal alone
eq(calls.flow['repair-pack'],nil,'never counted: no read'); eq(calls.flow['metallic-asteroid-chunk'],nil)
eq(calls.pairs,nil,'magazines and plates only ever counted at normal: no quality read')
local mag; for _,x in ipairs(r2.resources) do if x.name=='firearm-magazine' then mag=x end end
eq(mag.stock,250,'hub 200 and turret 50'); eq(mag.made_per_min,10); eq(mag.used_per_min,20)
print('d28_batch304 kept lists: ok')

-- 3: one built since: the count differs, so they are found again, the new one among them
reset(); game.tick=game.tick+600
ent('inserter',{status=7})
local r3=E.read({},{platform='Tern'})
eq(calls.finds[table.concat(SCAN_TYPES,',')],1,'found again'); eq(state.endurance_scan[5].n,7); eq(r3.low_power,3)
-- one replaced (the old one gone, a new one in its place): the count is the same, the gone one is not valid: found again
reset(); game.tick=game.tick+600
hand.valid=false; ent('inserter',{status=1})
local r4=E.read({},{platform='Tern'})
eq(calls.finds[table.concat(SCAN_TYPES,',')],1,'found again'); eq(state.endurance_scan[5].n,7); eq(r4.low_power,2)
-- a platform not read for 10 minutes: its lists dropped at the next find of any
state.endurance_scan[99]={key='x',n=0,by={},tick=game.tick-36001}
reset(); game.tick=game.tick+600; ent('inserter',{status=1})
E.read({},{platform='Tern'})
eq(state.endurance_scan[99],nil)
print('d28_batch304 found again: ok')

-- 4: flying: the speed (and the ship's geometry it compares) once a call, the read and its fuel outlook sharing it
reset(); game.tick=game.tick+600; geometry_calls=0
leg={from='nauvis',to='fulgora',left_km=6000}
pl.speed=25/60; pl.space_connection={}; pl.space_location=nil
segs[#segs]={kind='stop',at='nauvis',start=36000,['end']=game.tick-3600}
segs[#segs+1]={kind='leg',from='nauvis',to='fulgora',start=game.tick-3600}
local r5=E.read({},{platform='Tern'})
eq(geometry_calls,1,'one geometry a call'); has(r5.fuel_outlook,'Tern: leg nauvis->fulgora, 6000 km left')
eq(r5.speed_km_per_min,1500)
print('d28_batch304 speed once: ok')

-- 5: the ammunition trace: asked for its background read with one done, the belts it read and no count now
do
  local st={}
  local AF=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){state=function() return st end}
  reset()
  st.ammofeed={jobs={},done={[5]={tick=game.tick-60,started=game.tick-120,tr={reaches=0,stranded=0},belts=7322}}}
  local tr=AF.get(pl,nil,true)
  eq(tr.belts,7322); has(tr.as_of,'(7322 belts,'); eq(next(calls.counts),nil,'no count')
  -- a done read from before batch304 (no belts kept): counted, by the belt names
  st.ammofeed.done[5].belts=nil
  tr=AF.get(pl,nil,true)
  eq(tr.belts,3); eq(calls.counts['transport-belt'],1,'counted by name (the fake\'s one belt name)')
end
print('d28_batch304 belt count: ok')

-- 6: the hull's width by halving each strip: the first and last column with foundation, as the column walk found them
for _,ext in ipairs({{-20,19},{-128,127},{0,0},{-51,50},{-17,64},{31,32},{-33,-32}}) do
  foundation.lo,foundation.hi=ext[1],ext[2]
  reset()
  local g=F.geometry(pl,{thruster})
  eq(g.width,ext[2]-ext[1]+1,'width of '..ext[1]..'..'..ext[2]); eq(g.thrusters,1)
  eq(calls.tiles<=20,true,calls.tiles..' counts'); eq(next(calls.finds),nil,'the thrusters given, none found')
end
print('d28_batch304 hull width: ok')
