-- Run with lua tests/lightning.lua: lightning attractors on Fulgora whose
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path  -- (walk.lua)
-- catches have nowhere to go, and full accumulators in their networks
-- (lightning.lua), through the push alert digest (pushalerts.lua). Gemini,
-- shift09 00:20. The shift world's Fulgora at 00:20 had a rod no pole reached
-- at (-5.5,2.5), a rod in a network of 11 accumulators at 54 of 55 MJ, 6 rods
-- in one of 46 at 54 of 230 MJ, and 2 ruin attractors (no energy source).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={flow_precision_index={one_minute=1},entity_status={working=0},inventory={},alert_type={}}
prototypes={entity={accumulator={type='accumulator'},['lightning-rod']={type='lightning-attractor'},['assembling-machine-2']={type='assembling-machine'}}}
local force={name='player',players={}}
local ents={fulgora={},nauvis={}}
local stats={}
local function surface(name)
  return {name=name,planet={name=name},find_entities_filtered=function(f)
    eq(f.force,force)
    local out={}
    if f.type=='electric-pole' then
      assert(f.position and f.radius and f.limit,'poles near one attractor, bounded')
      for _,e in ipairs(ents[name]) do
        if e.type=='electric-pole' and (e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2<=f.radius^2 then out[#out+1]=e end
      end
      return out
    end
    eq(f.type[1],'lightning-attractor'); eq(f.type[2],'accumulator'); assert(f.limit,'bounded'); eq(f.area,nil,'no area: by type only')
    for _,e in ipairs(ents[name]) do if e.type=='lightning-attractor' or e.type=='accumulator' then out[#out+1]=e end end
    return out
  end}
end
local fulgora,nauvis=surface('fulgora'),surface('nauvis')
game={tick=100000,surfaces={nauvis,fulgora}}
local function ent(s,name,type,x,y,net,f)
  local e={valid=true,name=name,type=type,position={x=x,y=y},electric_network_id=net,force=force,surface=s=='fulgora' and fulgora or nauvis}
  for k,v in pairs(f or {}) do e[k]=v end
  ents[s][#ents[s]+1]=e
  return e
end
local function rod(s,x,y,net,mj) return ent(s,'lightning-rod','lightning-attractor',x,y,net,{electric_buffer_size=5e8,energy=(mj or 0)*1e6}) end
local function acc(s,x,y,net,mj,cap) return ent(s,'accumulator','accumulator',x,y,net,{electric_buffer_size=(cap or 5)*1e6,energy=mj*1e6}) end
local function pole(s,x,y,net,drawing)
  stats[net]=drawing
  return ent(s,'medium-electric-pole','electric-pole',x,y,net,{electric_network_statistics={input_counts=drawing,
    get_flow_count=function(q) eq(q.category,'input'); eq(q.precision_index,1); return drawing[q.name] end}})
end
-- 1. A rod no pole reaches (with a ruin attractor beside it: no energy source, left out).
rod('fulgora',-5.5,2.5,nil)
ent('fulgora','fulgoran-ruin-attractor','lightning-attractor',-0.5,1.5,nil)
-- 2. Net 300: a rod and 11 accumulators at 54.9 of 55 MJ (99.8%).
rod('fulgora',-5.5,-3.5,300,120)
for i=1,11 do acc('fulgora',i*2,-10,300,54.9/11) end
-- 3. Net 301: 6 rods and 46 accumulators at 54 of 230 MJ: no alert.
for i=1,6 do rod('fulgora',-70+i*4,90,301) end
for i=1,46 do acc('fulgora',-80,i,301,54/46) end
-- 4. Net 400: a rod, no accumulator, its pole's network drew nothing but accumulator charge (none here) in the last minute.
rod('fulgora',100.5,100.5,400,500)
pole('fulgora',102.5,100.5,400,{})
-- 5. Net 500: a rod, no accumulator, an assembler drawing: no alert. Net 600: no pole within reach: unknown, no alert.
rod('fulgora',200.5,0.5,500)
pole('fulgora',203.5,0.5,500,{['assembling-machine-2']=12,accumulator=3})
rod('fulgora',300.5,0.5,600)
-- 6. Nauvis has no lightning: a rod there in no network is no alert.
rod('nauvis',0.5,0.5,nil)

local L=dofile('mod/agent-harness_0.1.0/lightning.lua'){}
local groups=L.alert_groups(force)
eq(#groups,3)
local by={}
for _,g in ipairs(groups) do by[g.kind]=g; eq(g.surface,'fulgora'); assert(g.center and g.at and g.by and g.names and g.key,'pushalerts group fields') end
eq(by.lightning_unconnected.line,'1 lightning-rod in no electric network (no pole reaches it) near (-5,3): a strike charges only its own buffer')
eq(by.lightning_unconnected.n,1)
eq(by.lightning_unused.line,'electric #400: 1 lightning-rod near (101,101) in a network with no accumulator and nothing drawing power in the last minute; their buffers hold 500 MJ of 500 MJ')
eq(by.lightning_storage_full.line,'electric #300: its 11 accumulators are full (54.9 MJ of 55 MJ) with 1 lightning-rod in the network near (-5,-3); their buffers hold 120 MJ of 500 MJ')
eq(by.lightning_storage_full.n,11,'level: the accumulators')
eq(by.lightning_storage_full.names.accumulator,11)
-- Below 99%: no alert.
for _,e in ipairs(ents.fulgora) do if e.electric_network_id==300 and e.type=='accumulator' then e.energy=e.energy*0.95 end end
local again=L.alert_groups(force)
for _,g in ipairs(again) do assert(g.kind~='lightning_storage_full','98.8% is not full') end
eq(#again,2)
-- Two rods no pole reaches in one 64-tile cell are one group.
rod('fulgora',-20.5,10.5,nil)
for _,g in ipairs(L.alert_groups(force)) do
  if g.kind=='lightning_unconnected' then eq(g.n,2); eq(g.line,'2 lightning-rod in no electric network (no pole reaches them) near (-13,7): a strike charges only their own buffer') end
end

-- Through the push alerts: the nearest agent on Fulgora hears them once.
storage={board={items={}}}
local A=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
  state=function() return storage end,
  agents=function() return {{index=1,name='gemini'},{index=2,name='sol'}} end,
  who=function(p) return p.name end,
  place=function(index) return ({{key='fulgora',position={x=0,y=0}},{key='nauvis',position={x=0,y=0}}})[index] end,
  network_groups=function(f) return L.alert_groups(f) end}
for _,s in pairs(game.surfaces) do s.platform=nil end
local gemini={name='gemini',force=force,surface=fulgora}
local sol={name='sol',force=force,surface=nauvis}
-- The base scan reads its own types: none here.
local base=fulgora.find_entities_filtered
fulgora.find_entities_filtered=function(f) if f.type[1]~='lightning-attractor' and f.type~='electric-pole' then return {} end return base(f) end
nauvis.find_entities_filtered=function() return {} end
local hg,hs={},{}
local lines=A.lines(gemini,hg)
eq(#lines,2)
assert(lines[1]:find('lightning-rod in no electric network',1,true) or lines[2]:find('lightning-rod in no electric network',1,true),table.concat(lines,' | '))
eq(#A.lines(sol,hs),0,'sol is on Nauvis')
local read=A.read(gemini,{kind='lightning_unused'})
eq(#read.groups,1); eq(read.groups[1].to[1],'gemini (nearest)')

-- Fulgora's sky (Gemini 12:20): storm while dark, from the surface's day cycle (world n: a 10800-tick day, dusk 0.25,
-- evening 0.45, morning 0.55, dawn 0.75, darkness up to 0.85); bolts near a position when one is given.
local sky={planet={name='fulgora'},ticks_per_day=10800,dusk=0.25,evening=0.45,morning=0.55,dawn=0.75,freeze_daytime=false}
sky.count_entities_filtered=function(f) eq(f.type,'lightning'); eq(f.radius,64); assert(f.position,'near a position'); return 4 end
local function at(d,dark) sky.daytime,sky.darkness=d,dark; return L.sky(sky) end
local r=at(0.1,0)
eq(r.state,'clear'); eq(r.phase,'day'); eq(r.darkness,0); eq(r.dusk_in_s,27); eq(r.evening_in_s,63); eq(r.dawn_in_s,117); eq(r.day_s,180); eq(r.bolts_near,nil)
eq(r.line,'fulgora sky: day, clear (no lightning in daylight); dusk in 27s, full dark in 1m03s; a 3m00s day: dark from dusk to dawn, 1m30s')
r=at(0.8,0)
eq(r.phase,'day'); eq(r.dusk_in_s,81,'past dawn: the next dusk')
r=at(0.3462,0.481)
eq(r.state,'storm'); eq(r.phase,'darkening'); eq(r.darkness,0.48)
eq(r.line,'fulgora sky: storm, darkening (darkness 0.48; lightning in the dark, most at full dark); full dark in 19s, dawn (clear) in 1m13s; a 3m00s day: dark from dusk to dawn, 1m30s')
r=at(0.5,0.85)
eq(r.phase,'full dark'); eq(r.morning_in_s,9); eq(r.dawn_in_s,45)
eq(r.line,'fulgora sky: storm, full dark (darkness 0.85; lightning); brightening in 9s, dawn (clear) in 45s; a 3m00s day: dark from dusk to dawn, 1m30s')
r=at(0.7,0.2)
eq(r.phase,'brightening'); eq(r.state,'storm')
eq(r.line,'fulgora sky: storm, brightening (darkness 0.20; lightning in the dark); dawn (clear) in 9s, next dusk in 1m39s; a 3m00s day: dark from dusk to dawn, 1m30s')
-- with a position (status): the bolts near it
sky.daytime,sky.darkness=0.5,0.85
r=L.sky(sky,{x=1,y=2})
eq(r.bolts_near,4); assert(r.line:find('; 4 lightning bolts within 64 tiles of you now; a 3m00s day',1,true),r.line)
-- frozen daytime: no times
sky.freeze_daytime=true
r=L.sky(sky)
eq(r.dawn_in_s,nil); eq(r.line,'fulgora sky: full dark, darkness 0.85, daytime frozen')
-- another planet: none
eq(L.sky(nauvis),nil)
eq(L.sky({planet=nil}),nil)
print('lightning ok')
