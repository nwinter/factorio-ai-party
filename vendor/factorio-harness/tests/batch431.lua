-- Foundation-only witnesses reuse the loss ledger; no added scan, trajectory admission irrelevant.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local st, ghosts, finds = {}, {}, 0
local floor='space-platform-foundation'
local force={name='player'}
local s={index=9,name='platform-41'}
local pl={valid=true,index=41,name='Asterion',surface=s,force=force}; s.platform=pl
local asts={}
s.find_entities_filtered=function(f)
  if f.type=='asteroid' then return asts end
  if f.name=='tile-ghost' then finds=finds+1; return ghosts end
  return {}
end
game={tick=1000,get_surface=function() return s end}
defines={inventory={turret_ammo=1}}
prototypes={entity={['big-oxide-asteroid']={dying_trigger_effect={{type='create-entity',entity_name='medium-oxide-asteroid',offsets={{0,0}}}}},['medium-oxide-asteroid']={}}}
local api={state=function() return st end,on_platform=function() return {surface=s,force=force} end}
local A=require('asteroidwatch')(api)
A.hull=function() return {x0=-50,y0=-60,x1=50,y1=10} end
local G=require('ghostlog'){state=api.state}
local F=require('flightwatch'){state=api.state,floor_loss=function(p,e) A.on_floor_loss(p,e) end,
  ghost_owner=function(g) return G.owner(g) end,ghost_owner_at=function(sn,n,p) return G.owner_at(sn,n,p,true) end,
  ghost_forget_tile=function(sn,n,p) return G.forget_tile(sn,n,p) end}
local function start()
  A.handler({index=1},{platform=pl.name,asteroids=true,seconds=120,track_filter={area={{0,-100},{100,100}}}})
end
local function read() return A.handler({index=1},{platform=pl.name,asteroids=true}) end
local unit=100
local function ghost(x,y,user)
  unit=unit+1
  local g={valid=true,type='tile-ghost',name='tile-ghost',ghost_name=floor,unit_number=unit,position={x=x+0.5,y=y+0.5},surface=s,last_user=user,quality={name='normal'}}
  ghosts[#ghosts+1]=g; return g
end
local function build(g)
  for i,v in ipairs(ghosts) do if v==g then table.remove(ghosts,i); break end end
  F.on_built_tile{platform=pl,tick=game.tick,tile={name=floor},tiles={{position={x=math.floor(g.position.x),y=math.floor(g.position.y)}}}}
end
local function asteroid(u,name,x,y) return {valid=true,type='asteroid',unit_number=u,name=name,position={x=x,y=y},surface=s} end
start(); A.tick(1000)
-- Baseline ghosts and player/agent placements do not count. The original ledger performs every find.
local pre=ghost(-50,-60); F.loss_scan(pl,1000)
local placed=ghost(55,0); G.placed('astra',placed)
local human=ghost(56,0,{name='nick'})
game.tick=1060; F.loss_scan(pl,1060); build(pre); build(placed); build(human)
eq(read().floor_impacts,0)
-- Excluded west death and fragment remain candidates, with explicitly inferred parent and no false cause.
game.tick=1070
local parent=asteroid(1,'big-oxide-asteroid',-49.5,-56.5)
A.on_died{entity=parent,tick=1070}
asts={asteroid(2,'medium-oxide-asteroid',-48.5,-56.5)}
game.tick=1075; A.sample(st.asteroid_watch[1],1075)
local lost=ghost(-49,-57)
game.tick=1120; F.loss_scan(pl,1120)
local r=read(); eq(r.floor_impacts,1); eq(r.platform_hits_all,0); eq(r.platform_hits,0); eq(r.tracked,0)
eq(r.filtered_out,2); eq(#r.floor_witnesses,1)
local w=r.floor_witnesses[1]; eq(w.tick,1120); eq(w.tick_basis,'ghost_seen'); eq(w.after_tick,1060)
eq(w.tiles[1].x,-49); eq(w.tiles[1].y,-57); eq(w.cause,'unknown'); eq(#w.candidates,2)
eq(w.candidates[1].kind,'fragment'); eq(w.candidates[1].unit,2); eq(w.candidates[1].inferred,true)
eq(w.candidates[1].parent.unit,1); eq(w.candidates[1].parent.inferred,true)
eq(w.candidates[2].kind,'death'); eq(w.candidates[2].unit,1)
local scan_count=finds
game.tick=1140; build(lost); eq(read().floor_impacts,1); eq(read().floor_witnesses[1].rebuilt_tick,1140)
eq(finds,scan_count,'witness and rebuild did no scan')
-- Reload and between-check rebuild; repeated damage at one tile is a new loss.
local hull=A.hull; A=require('asteroidwatch')(api); A.hull=hull
local again=ghost(-49,-57); game.tick=1150; build(again)
r=read(); eq(r.floor_impacts,2); eq(r.floor_witnesses[2].tick_basis,'hub_rebuild'); eq(r.floor_witnesses[2].rebuilt_tick,1150)
-- Nearest three only; distant, future and expired evidence excluded; ring is strictly bounded.
for i=1,140 do A.on_died{entity=asteroid(1000+i,'medium-oxide-asteroid',-49+i/100,-57),tick=1160} end
eq(#st.asteroid_watch[1].floor_recent,128)
game.tick=1170; F.loss_rebuilt(pl,-49,-57,1170)
r=read(); eq(#r.floor_witnesses[3].candidates,3); eq(r.floor_witnesses[3].candidates[1].unit,1050)
for i=1,40 do F.loss_rebuilt(pl,20+i,0,1170) end
r=read(); eq(r.floor_impacts,43); eq(#r.floor_witnesses,32); eq(r.floor_witnesses_dropped,11)
eq(#r.floor_witnesses[32].candidates,0,'far candidates excluded')
-- A duplicate rebuild update of a dropped witness must not increment the total.
A.on_floor_loss(pl,{seq=1,pt=1120,x=-49,y=-57,rebuilt=1200}); eq(read().floor_impacts,43)
F.loss_rebuilt(pl,-49,-57,1100); eq(#read().floor_witnesses[32].candidates,0,'future candidates excluded')
game.tick=1800; F.loss_rebuilt(pl,-49,-57,1800); eq(#read().floor_witnesses[32].candidates,0,'expired candidates excluded')
-- Wrong platform/force, pre-watch and post-end discoveries cannot alter the watch.
local n=read().floor_impacts
for _,p in ipairs({{surface={index=8},force=force},{surface=s,force={name='enemy'}}}) do A.on_floor_loss(p,{seq=999,pt=1800,x=0,y=0}) end
A.on_floor_loss(pl,{seq=999,pt=999,x=0,y=0}); A.on_floor_loss(pl,{seq=999,pt=999999,x=0,y=0}); eq(read().floor_impacts,n)
-- Finished and closed segment reads retain bounded witnesses; pagination does not filter them.
local old=st.asteroid_watch[1]; game.tick=1810; start(); A.close(old,st.asteroid_watch[1],1810,'fixture edit')
r=A.handler({index=1},{platform=pl.name,asteroids=true,segment_start=1000,asteroid_names='big-oxide-asteroid'})
eq(r.floor_impacts,n); eq(#r.floor_witnesses,32); assert(r.line:find('floor_impacts '..n,1,true))
eq(read().floor_impacts,0)
assert(A.ARGS.asteroids_returns:find('floor_witnesses',1,true)); assert(r.floor_note:find('No new scan',1,true))
print('batch431: foundation loss/rebuild, exclusions, candidates, bounds, reload and segment scope ok')
