-- Run from repository root: lua tests/d29_batch341.lua
-- (d29 batch341 PW, viewer Aurora: Asterion lost its only power mid-refit) powerleft.lua: a removal that takes a
-- generator says when it leaves an electric network with consumers and no generation, as facts.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={flow_precision_index={one_minute=1,ten_minutes=2}}
prototypes={entity={accumulator={type='accumulator'},['laser-turret']={type='electric-turret'},['railgun-turret']={type='ammo-turret'}}}
local units=0
local function ent(surface,type_,name,net,extra)
  units=units+1
  local e={valid=true,type=type_,name=name,unit_number=units,surface=surface,electric_network_id=net,marked=false}
  e.to_be_deconstructed=function() return e.marked end
  for k,v in pairs(extra or {}) do e[k]=v end
  surface.list[#surface.list+1]=e
  return e
end
-- the network's statistics: kW a consumer drew, as J a tick (x60/1000 = kW)
local function stats(draw,made)
  local out,inp={},{}
  for n in pairs(draw) do out[n]=1 end
  for n in pairs(made or {}) do inp[n]=1 end
  -- as 2.0.77 counts an electric network: consumers' use as input, generators' output as output
  return {input_counts=out,output_counts=inp,draw=draw,made=made or {}}
end
local function flow(st,name,cat,pi) local kw=(cat=='output' and st.made or st.draw)[name] or 0; return kw*1000/60 end
local finds=0
local function surface(name,platform)
  local s={name=name,index=#name,list={},platform=platform}
  s.find_entities_filtered=function(f)
    finds=finds+1
    local want={} for _,t in ipairs(f.type) do want[t]=true end
    local out={} for _,e in ipairs(s.list) do if want[e.type] then out[#out+1]=e end end
    return out
  end
  return s
end
local census={}
local nets={}
local P=dofile('mod/agent-harness_0.1.0/powerleft.lua'){flow=flow,typed=function(f,s,types) return census[s.name] end,stats=function(id) return nets[id] end}
local force={}

-- 1. Asterion's strip paste: 9 solar panels and 143 accumulators (its only power) go; lasers and railguns drew 1.06 MW
local ast=surface('platform-16',{name='Asterion',space_location={solar_power_in_space=60}})
local st=stats({['laser-turret']=634,['railgun-turret']=425,accumulator=50},{['solar-panel']=1059}); nets[7]=st
local going={}
local panel={get_max_energy_production=function() return 1000 end}
for i=1,9 do going[#going+1]=ent(ast,'solar-panel','solar-panel',7,{prototype=panel}) end
for i=1,3 do going[#going+1]=ent(ast,'accumulator','accumulator',7,{energy=1e6,electric_network_statistics=st}) end
local belt=ent(ast,'transport-belt','turbo-transport-belt',nil); going[#going+1]=belt
local lines=P.after(force,going,false)
eq(#lines,1)
eq(lines[1],'removing these leaves electric network 7 on Asterion with no generation: 9 solar-panel go with 3 accumulators, none other there (marked: they go as robots take them); its consumers drew 1.06 MW over the last minute (laser-turret 634 kW, railgun-turret 425 kW); accumulators left 0.0 MJ')
-- a dry run says the same without "marked"
has(P.after(force,going,true)[1],'none other there; its consumers drew 1.06 MW')

-- 2. a bridge kept: 30 new solar panels stand (not marked): nothing to say
local bridge={}
for i=1,30 do bridge[i]=ent(ast,'solar-panel','solar-panel',7,{prototype=panel}) end
st.made['solar-panel']=39*117.7   -- the 39 panels standing made the network's output (117.7 kW each)
eq(P.after(force,going,false),nil)
-- an undersized bridge: 3 of 12 panels left make about 353 kW against 1.06 MW drawn
for i=4,30 do bridge[i].valid=false end
st.made['solar-panel']=12*117.7
local under=P.after(force,going,false)[1]
has(under,'with generation of about 108 kW (3 solar-panel in this sunlight 108 kW): 9 solar-panel go with 3 accumulators (marked')   -- 3 x 60 kW x 60%
for i=4,30 do bridge[i].valid=true end
st.made['solar-panel']=39*117.7
-- the bridge marked too (to_be_deconstructed): it counts as going
for _,e in ipairs(bridge) do e.marked=true end
has(P.after(force,going,false)[1],'no generation')
-- accumulators that stay: their charge and how long it lasts
for _,e in ipairs(bridge) do e.marked=false; e.valid=false end
local acc=ent(ast,'accumulator','accumulator',7,{energy=63.6e6})
local l=P.after(force,going,false)[1]
has(l,'accumulators left 63.6 MJ, about 1m00s at the 1.06 MW short')   -- 63.6 MJ / 1.059 MW
acc.valid=false

-- 3. only accumulators going, or nothing that makes power: no read at all
local f0=finds
eq(P.after(force,{going[10],belt},false),nil); eq(finds,f0)
-- consumers that drew nothing in 10 minutes: nothing to say
local quiet=surface('platform-3',{name='Weaver'})
nets[9]=stats({})
local q=ent(quiet,'solar-panel','solar-panel',9)
eq(P.after(force,{q},false),nil)

-- 4. an unrelated case on a planet: Vulcanus's steam engines on pole network 840 go, a fusion generator on another
-- network stays; the census lists the steam engines, a search the fusion generator
local vul=surface('vulcanus')
local st2=stats({['assembling-machine-3']=900,['electric-mining-drill']=300},{['steam-engine']=1200}); nets[840]=st2
local e1=ent(vul,'generator','steam-engine',840,{electric_network_statistics=st2})
local e2=ent(vul,'generator','steam-engine',840,{electric_network_statistics=st2})
local fus=ent(vul,'fusion-generator','fusion-generator',841,{prototype={get_max_energy_production=function() return 50e6/60 end}})
census.vulcanus={e1,e2}
l=P.after(force,{e1,e2},true)[1]
eq(l,'removing these leaves electric network 840 on vulcanus with no generation: 2 steam-engine go, none other there; its consumers drew 1.20 MW over the last minute (assembling-machine-3 900 kW, electric-mining-drill 300 kW); accumulators left 0.0 MJ')
-- a fusion generator on network 840 that made nothing there (no plasma: Asterion's case) is named, and counts for nothing
fus.electric_network_id=840
eq(P.after(force,{e1,e2},true)[1],'removing these leaves electric network 840 on vulcanus with no generation: 2 steam-engine go, 1 fusion-generator stay, of kinds that made no power there in the last 10 minutes; its consumers drew 1.20 MW over the last minute (assembling-machine-3 900 kW, electric-mining-drill 300 kW); accumulators left 0.0 MJ')
-- making power: kept, nothing to say (found by the search the census list lacks)
st2.made['fusion-generator']=500; st2.output_counts['fusion-generator']=1
eq(P.after(force,{e1,e2},true),nil)   -- it made 500 kW, and is rated 50 MW
print('d29_batch341 PW powerleft: ok')
