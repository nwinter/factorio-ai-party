-- d24 batch139 PK1 (Sol #2115): delivery watch 284 said Petrel, paused while docked at Nauvis (the destination), "goes
-- nowhere until unpaused"; its hub sends pods down while paused (watch 283 saw 2000 land). A paused carrier is a blocker
-- only away from the destination's planet; stopped there, paused or not, the watch reads what goes down now by
-- batch137's rule (freight.lua hub_keeps_at, hub_gives): the pads' ask less what they hold, a hub section for that planet
-- that keeps it (an infinite max keeps it all; a finite max sends all above it, asked or not), and says it.
-- Run from the harness root: lua tests/d24_batch139.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end
game={tick=1000}
defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
prototypes={item={calcite={stack_size=50}}}
local function stack(name,count) return {valid_for_read=true,name=name,count=count,quality={name='normal'}} end
local function inv(list) local t={} for i,x in ipairs(list) do t[i]=x end
  t.get_item_count=function(n) local c=0 for _,x in ipairs(list) do if x.name==n then c=c+x.count end end return c end
  t.can_insert=function() return true end return t end
local nauvis={name='nauvis'}
nauvis.find_logistic_network_by_position=function() return {network_id=1} end
-- the pad's request (min) and what it holds
local pad_min,pad_held=2000,0
local function sections(list)
  return {sections_count=#list,get_section=function(i) return list[i] end}
end
local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=-12,y=40},surface=nauvis,unit_number=77,
  get_inventory=function() return inv({}) end,get_item_count=function() return pad_held end,
  get_logistic_sections=function() return sections(pad_min>0 and {{active=true,filters={{value={name='calcite'},min=pad_min}}}} or {}) end}
nauvis.find_entities_filtered=function(f) if f.position and f.position.x==-12 then return {pad} end return {} end
local force={name='player',is_chunk_charted=function() return true end}
-- the hub's sections: {name, min, max, from}
local hub_secs={}
local function hub_sections()
  local list={}
  for _,f in ipairs(hub_secs) do list[#list+1]={active=true,filters={{value={name=f[1]},min=f[2],max=f[3],import_from=f[4]}}} end
  return sections(list)
end
local function platform(name,index,n,paused,at)
  return {valid=true,name=name,index=index,surface={name='platform-'..index},paused=paused,space_location={name=at},
    schedule={current=1,records={{station='nauvis'},{station='gleba'}}},
    hub={valid=true,type='space-platform-hub',get_inventory=function() return inv({stack('calcite',n)}) end,get_logistic_sections=hub_sections}}
end
local petrel=platform('Petrel',5,1980,true,'nauvis')
force.platforms={petrel}
game.forces={player=force}; game.planets={nauvis={surface=nauvis},gleba={surface={name='gleba'}}}
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
local st={}
local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,census_typed=function() return {pad} end,
  freight={where=function() return {} end,receipts_since=function() return {} end,followed=function() return {down={},up={}} end,spoils=function() return false end,
    hub_keeps_at=F.hub_keeps_at,hub_gives=F.hub_gives,keep_text=F.keep_text}}
local sol={name='sol',index=1,force=force,surface=nauvis}
local function read(id) game.tick=game.tick+60; W.tick(game.tick-game.tick%60); return W.call(sol,{id=id}).watches[1] end
local function blocked(row) return table.concat(row.blockers or {},' | ') end

-- Sol's watch 284 (5000 here, so the pad filling does not end it): calcite to Nauvis's pad from Petrel, paused at Nauvis; no hub section keeps calcite at nauvis
W.call(sol,{item='calcite',count=5000,to={position={x=-12,y=40},surface='nauvis'},deadline_min=60,from='Petrel'})
local id=st.delivwatch.list[1].id
local row=read(id)
lacks(blocked(row),'goes nowhere until unpaused')
eq(row.at_destination.sends,1980); eq(row.at_destination.asked,2000); eq(row.at_destination.held,1980)
has(row.at_destination.line,'Petrel is stopped at nauvis (paused: its hub sends pods down at the planet it is stopped at all the same) with 1980 calcite in its hub: its hub sends 1980 down now')
has(row.at_destination.line,'no hub section keeps calcite at nauvis: it goes down as far as the pads ask (the landing pad (-12,40) asks 2000, holds 0)')
has(row.line,'at the destination: Petrel is stopped at nauvis')
-- batch137's case: calcite 200..inf from nauvis keeps it all: a blocker naming the section, not the pause
hub_secs={{'calcite',200,nil,'nauvis'},{'calcite',0,nil,'gleba'}}
row=read(id)
eq(row.at_destination.sends,0)
has(blocked(row),'Petrel is stopped at nauvis (paused: its hub sends pods down at the planet it is stopped at all the same) with 1980 calcite in its hub: none of it goes down now (hub section 1 keeps calcite 200..inf at nauvis: an infinite max keeps it all)')
lacks(blocked(row),'goes nowhere'); lacks(row.line,'at the destination:')
-- a finite max: all above it goes down, asked or not
hub_secs={{'calcite',200,500,'nauvis'}}; pad_min=0
row=read(id)
eq(row.at_destination.sends,1480); eq(row.blockers,nil)
has(row.at_destination.line,'its hub sends 1480 down now (hub section 1 keeps calcite 200..500 at nauvis: all above 500 goes down, asked or not)')
-- no section and no pad asking: none goes down, said
hub_secs={}
row=read(id)
has(blocked(row),'none of it goes down now (no hub section keeps calcite at nauvis and no landing pad of ours there asks it: it goes down as far as the pads ask)')
-- the pad holding what it asks: none goes down
pad_min,pad_held=2000,2000
row=read(id)
has(blocked(row),'none of it goes down now (no hub section keeps calcite at nauvis: it goes down as far as the pads ask (the landing pad (-12,40) asks 2000, holds 2000))')
-- not paused, stopped there: the same read, no pause words
petrel.paused=false; pad_held=0
row=read(id)
has(row.at_destination.line,'Petrel is stopped at nauvis with 1980 calcite in its hub: its hub sends 1980 down now'); lacks(row.at_destination.line,'paused')
-- paused away from the destination: a blocker, as before, saying where
petrel.paused=true; petrel.space_location={name='gleba'}
row=read(id)
has(blocked(row),'Petrel is paused at gleba: it goes nowhere until unpaused'); eq(row.at_destination,nil)
petrel.space_connection={name='gleba-nauvis'}
row=read(id)
has(blocked(row),'Petrel is paused in flight: it goes nowhere until unpaused')
print('d24_batch139 PK1 paused carrier docked at the destination: ok')
