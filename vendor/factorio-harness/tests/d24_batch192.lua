-- d24 batch192 QAH1 (Sol #2264): at tick 59185129 watch 384, 3 asteroid-collector@legendary from Kestrel IVc to
-- Aquilo's pad, warned "hub section 24 keeps asteroid-collector 1..1 at fulgora, so all above 1 goes down there":
-- section 24 asks asteroid-collector@rare 1..1 from fulgora, section 23 asteroid-collector@legendary 0..3 from nauvis
-- (runs/shift71/sol/tools/shift71-IVc-quality-retention.json). A hub section's max is for its own quality, as 2.0.77
-- did on a copy of world n (d24, Kestrel IVc at Fulgora): 6 legendary stayed while 3 rare went to 1; a second section
-- of rare 0..2 kept 3 rare.
-- Run from the harness root: lua tests/d24_batch192.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end
prototypes={item={['asteroid-collector']={stack_size=10}},quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5},['quality-unknown']={level=0,hidden=true}}}
game={tick=59185129}
local function secs(list) return {sections_count=#list,get_section=function(i) return list[i] end} end
local function slot(q,min,max,from) return {value={type='item',name='asteroid-collector',quality=q,comparator='='},min=min,max=max,import_from=from} end
-- Kestrel IVc's sections 1, 23 and 24 (2..22 hold none of it)
local list={{active=true,filters={slot('normal',4,4,'nauvis')}}}
for i=2,22 do list[i]={active=true,filters={}} end
list[23]={active=true,filters={slot('legendary',0,3,'nauvis')}}
list[24]={active=true,filters={slot('rare',1,1,'fulgora')}}
local kestrel=secs(list)

do
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local keeps=F.hub_keeps_at(kestrel,'fulgora')
  -- legendary: no section for fulgora names that quality; no pad asks: none goes down
  local n,row=F.hub_gives(keeps,'asteroid-collector',3,0,false,'legendary')
  eq(n,0,'legendary under a rare max'); eq(row,nil)
  -- rare: all above 1 goes down, the section named with item@quality
  n,row=F.hub_gives(keeps,'asteroid-collector',3,0,false,'rare')
  eq(n,2); eq(F.keep_text(row),'hub section 24 keeps asteroid-collector@rare 1..1 at fulgora'); eq(row.max,1)
  -- by quality: 6 legendary, 3 rare, 4 normal (the copy's hub): 2 rare go down
  n,row=F.hub_gives(keeps,'asteroid-collector',13,0,false,{legendary=6,rare=3,normal=4})
  eq(n,2); eq(row.max,1)
  -- the pads' ask takes from the qualities no section names
  eq((F.hub_gives(keeps,'asteroid-collector',13,5,false,{legendary=6,rare=3,normal=4})),7)
  -- at nauvis: normal 4..4 and legendary 0..3, each its own
  local kn=F.hub_keeps_at(kestrel,'nauvis')
  eq((F.hub_gives(kn,'asteroid-collector',5,0,false,'legendary')),2)
  eq((F.hub_gives(kn,'asteroid-collector',4,0,false,'normal')),0)
  n,row=F.hub_gives(kn,'asteroid-collector',3,0,false,'rare'); eq(n,0); eq(row,nil)
  -- maxes of one quality add up (rare 1..1 and rare 0..2 kept 3 on the copy)
  local two=F.hub_keeps_at(secs({{active=true,filters={slot('rare',1,1,'fulgora')}},{active=true,filters={slot('rare',0,2,'fulgora')}}}),'fulgora')
  n,row=F.hub_gives(two,'asteroid-collector',5,0,false,'rare'); eq(n,2); eq(row.max,3)
  eq(F.keep_text(row),'hub section 1 keeps asteroid-collector@rare 1..1 at fulgora; hub section 2 keeps asteroid-collector@rare 0..2 at fulgora')
  -- kept: what the rows hold back
  eq((F.hub_kept(keeps,'asteroid-collector',{legendary=6,rare=3})),1)
  -- a quality comparator (a max only): not forecast, named
  local cmp=F.hub_keeps_at(secs({{active=true,filters={{value={type='item',name='asteroid-collector',quality='rare',comparator='≥'},min=0,max=1,import_from='fulgora'}}}}),'fulgora')
  n,row=F.hub_gives(cmp,'asteroid-collector',6,0,false,'legendary'); eq(n,0); eq(row.ranged,true)
  eq(F.keep_text(row),'hub section 1 keeps asteroid-collector of quality >= rare 0..1 at fulgora (a quality comparator: what it keeps is not forecast)')
  n,row=F.hub_gives(cmp,'asteroid-collector',6,0,false,'normal'); eq(n,0); eq(row,nil)
  -- by_item: hub_counts(pl, true) keys
  local b=F.by_item({['asteroid-collector@legendary']=3,['asteroid-collector@normal']=4,['iron-plate@normal']=5})
  eq(b['asteroid-collector'].legendary,3); eq(b['asteroid-collector'].normal,4); eq(b['iron-plate'].normal,5)
  -- by name (no quality given): every quality together, as before
  eq((F.hub_gives(keeps,'asteroid-collector',3,0)),2)
end
print('d24_batch192 QAH1 hub keep rule by quality: ok')

-- watch 384: Kestrel IVc stopped at fulgora (stop 2) before aquilo with 3 legendary in its hub: no warning from the
-- rare section; a rare watch there gets it, named with item@quality
do
  defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
  local held={normal=4,legendary=3,rare=0}
  local function hubinv()
    return {get_item_count=function(x) local q=type(x)=='table' and x.quality or 'normal'; local nm=type(x)=='table' and x.name or x; return nm=='asteroid-collector' and held[q] or 0 end,
      get_item_count_filtered=function(f) local c=0; for _,v in pairs(held) do c=c+v end; return c end}
  end
  local function inv0() return {get_item_count=function() return 0 end,can_insert=function() return true end} end
  local aquilo={name='aquilo',find_logistic_network_by_position=function() return {network_id=1} end}
  local fulgora={name='fulgora',find_entities_filtered=function() return {} end}
  local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=-8,y=-22},surface=aquilo,unit_number=77,
    get_inventory=function() return inv0() end,get_item_count=function() return 0 end,get_logistic_sections=function() return secs({}) end}
  aquilo.find_entities_filtered=function(f) if f.position and f.position.x==-8 then return {pad} end return {} end
  local force={name='player',is_chunk_charted=function() return true end}
  local kes={valid=true,name='Kestrel IVc',index=9,surface={name='platform-9'},paused=false,space_location={name='fulgora'},
    schedule={current=2,records={{station='nauvis'},{station='fulgora'},{station='aquilo'}}},
    hub={valid=true,type='space-platform-hub',get_inventory=function() return hubinv() end,get_logistic_sections=function() return kestrel end}}
  force.platforms={kes}
  game.forces={player=force}; game.planets={aquilo={surface=aquilo},fulgora={surface=fulgora},nauvis={surface={name='nauvis'}}}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local st={}
  local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,
    census_typed=function(_,s) return s==aquilo and {pad} or {} end,
    freight={where=function() return {} end,receipts_since=function() return {} end,followed=function() return {down={},up={}} end,spoils=function() return false end,
      hub_keeps_at=F.hub_keeps_at,hub_gives=F.hub_gives,keep_text=F.keep_text,no_unload=F.no_unload,by_item=F.by_item,
      hub_counts=function() local o={}; for q,v in pairs(held) do if v>0 then o['asteroid-collector@'..q]=v end end; return o end}}
  local sol={name='sol',index=1,force=force,surface=aquilo}
  W.call(sol,{item='asteroid-collector',quality='legendary',count=3,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=80,from='Kestrel IVc'})
  local id=st.delivwatch.list[1].id
  game.tick=game.tick+60; W.tick(game.tick-game.tick%60)
  local row=W.call(sol,{id=id}).watches[1]
  local said=table.concat(row.blockers or {},' | ')..' || '..table.concat(row.risks or {},' | ')
  lacks(said,'hub section 24'); lacks(said,'goes down there')
  -- the same hub with 3 rare and a rare watch: the warning, the section named with item@quality
  held.rare=3
  W.call(sol,{item='asteroid-collector',quality='rare',count=1,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=80,from='Kestrel IVc'})
  local id2=st.delivwatch.list[2].id
  game.tick=game.tick+60; W.tick(game.tick-game.tick%60)
  row=W.call(sol,{id=id2}).watches[1]
  has(table.concat(row.blockers or {},' | '),'Kestrel IVc is stopped at fulgora (stop 2 of its schedule) with 3 asteroid-collector@rare in its hub, before aquilo: hub section 24 keeps asteroid-collector@rare 1..1 at fulgora, so all above 1 goes down there, a landing pad asking or not')
  -- no quality given: by the hub's qualities, the 2 rare above the max (3 legendary and 4 normal named by no fulgora section)
  W.call(sol,{item='asteroid-collector',count=10,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=80,from='Kestrel IVc'})
  local id3=st.delivwatch.list[3].id
  game.tick=game.tick+60; W.tick(game.tick-game.tick%60)
  row=W.call(sol,{id=id3}).watches[1]
  has(table.concat(row.blockers or {},' | '),'with 10 asteroid-collector in its hub, before aquilo: hub section 24 keeps asteroid-collector@rare 1..1 at fulgora, so all above 1 goes down there')
  held.rare=0
  game.tick=game.tick+60; W.tick(game.tick-game.tick%60)
  row=W.call(sol,{id=id3}).watches[1]
  lacks(table.concat(row.blockers or {},' | '),'hub section 24')
end
print('d24_batch192 QAH1 delivery_watch 384: ok')

-- shipment {platform, ready}: Kestrel IVc at fulgora with 3 legendary and 4 normal: the rare section sends none down
do
  defines={space_platform_state={waiting_at_station=4},inventory={hub_main=1,hub_trash=2,cargo_landing_pad_main=1}}
  game={tick=59185129}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local force={}
  local padinv={count_empty_stacks=function() return 10 end,get_insertable_count=function() return 100 end,get_contents=function() return {} end}
  setmetatable(padinv,{__len=function() return 80 end})
  local pad={valid=true,type='cargo-landing-pad',force=force,name='cargo-landing-pad',position={x=74,y=208},get_inventory=function() return padinv end,
    get_logistic_sections=function() return secs({}) end}
  local fs={index=3,name='fulgora',find_entities_filtered=function(f) if type(f.type)=='table' then return {pad} end return {} end}
  game.planets={fulgora={surface=fs}}
  local held={['asteroid-collector@legendary']=3,['asteroid-collector@normal']=4}
  local pl={valid=true,name='Kestrel IVc',index=9,state=4,space_location={name='fulgora'},force=force,paused=false,
    schedule={current=2,records={{station='nauvis'},{station='fulgora'},{station='aquilo'}}},
    hub={valid=true,get_logistic_sections=function() return kestrel end}}
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return {} end,freight=function() return F end,
    hub_counts=function(_,q) if q then return held end local o={}; for k,v in pairs(held) do local n=k:match('^(.*)@'); o[n]=(o[n] or 0)+v end; return o end,
    where=function() return {at='fulgora',stopped=true,text='at fulgora'} end,
    request_rows=function() return {} end,gate=function() return {lines={}} end,gate_row=function() return nil end,rocket=function() return nil end}
  local r=S.read({force={platforms={pl}}},{platform='Kestrel IVc',ready=true})
  eq(#r.down,0,'none goes down')
  -- 3 rare more: the 2 above section 24's max go down
  held['asteroid-collector@rare']=3
  r=S.read({force={platforms={pl}}},{platform='Kestrel IVc',ready=true})
  eq(r.down[1].item,'asteroid-collector'); eq(r.down[1].count,2); eq(r.down[1].keep,'hub section 24 keeps asteroid-collector@rare 1..1 at fulgora')
end
print('d24_batch192 QAH1 shipment ready: ok')
