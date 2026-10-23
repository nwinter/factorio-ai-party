-- d22 batch110 BT1 (freight and shipment): the background reads make less garbage and say the same. On a copy of world
-- n, freight.belts made 53.5 KB a step (every 3 ticks), freight.tick 502 KB a call, shipment.tick 438 KB a call.
-- 1. hub_counts keeps the hub's inventories and the kinds of item each held, counts them with get_item_count, and reads
--    get_contents again when they do not add up to the total: the same counts as a full read at every step; a kind
--    gone to 0 stays counted; past HUB_KINDS kinds, read in full. 1b: two items spoiling into one share its rise in
--    name order (not in the order the counts were listed).
-- 2. phase_step writes the ammunition counts into last second's table: the same phases and counts as before.
-- 3. belt_tick: an empty line's contents are not read, a prototype's line count is read once, an underground exit's
--    buried lines are counted once, the platform is found once a job, and no platform is looked at with none due.
-- 4. shipment.tick reads a silo's request flags only for a request waiting where the platform is stopped.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function same(a,b,m)
  for k,v in pairs(a) do if type(v)=='table' then same(v,b[k] or {},(m or '')..'.'..tostring(k)) else eq(b[k],v,(m or '')..'.'..tostring(k)) end end
  for k in pairs(b) do assert(a[k]~=nil,(m or '')..'.'..tostring(k)..' extra') end
end

-- 1. hub counts
do
  defines={inventory={hub_main=1,hub_trash=2}}
  game={tick=100}
  -- an inventory: kinds {name, quality, count}; get_contents lists the kinds held, get_item_count counts as 2.0.77
  -- does (a plain name: normal alone; no argument: everything)
  local function mkinv(kinds)
    local inv={valid=true,reads=0,kinds=kinds}
    inv.get_contents=function() inv.reads=inv.reads+1; local out={} for _,x in ipairs(inv.kinds) do if x.count>0 then out[#out+1]={name=x.name,quality=x.quality,count=x.count} end end return out end
    inv.get_item_count=function(id)
      local n=0
      for _,x in ipairs(inv.kinds) do
        if id==nil or (type(id)=='string' and x.name==id and x.quality=='normal') or (type(id)=='table' and x.name==id.name and x.quality==(id.quality or 'normal')) then n=n+x.count end
      end
      return n
    end
    return inv
  end
  local main=mkinv({{name='iron-plate',quality='normal',count=10},{name='iron-plate',quality='rare',count=2},{name='copper-plate',quality='normal',count=5}})
  local trash=mkinv({{name='stone',quality='normal',count=3}})
  local hub={valid=true,get_inventory=function(i) return i==1 and main or i==2 and trash or nil end}
  local pl={index=5,hub=hub}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  -- what a full read says
  local function fresh(q)
    local out={}
    for _,inv in ipairs({main,trash}) do
      for _,x in ipairs(inv.kinds) do
        if x.count>0 then local k=q and x.name..'@'..x.quality or x.name; out[k]=(out[k] or 0)+x.count end
      end
    end
    return out
  end
  same(F.hub_counts(pl),fresh()); eq(main.reads,1); eq(trash.reads,1)
  same(F.hub_counts(pl),fresh()); same(F.hub_counts(pl,true),fresh(true))
  eq(main.reads,1,'the kinds counted, no full read'); eq(trash.reads,1)
  -- a count changes, a kind goes to 0: counted
  main.kinds[1].count=7; main.kinds[3].count=0
  same(F.hub_counts(pl),fresh()); eq(F.hub_counts(pl)['copper-plate'],nil); eq(main.reads,1)
  -- a new kind (a new quality of a kind held too): read in full
  main.kinds[#main.kinds+1]={name='coal',quality='normal',count=4}
  same(F.hub_counts(pl),fresh()); eq(main.reads,2)
  main.kinds[#main.kinds+1]={name='iron-plate',quality='epic',count=1}
  same(F.hub_counts(pl,true),fresh(true)); eq(main.reads,3)
  same(F.hub_counts(pl),fresh()); eq(main.reads,3)
  -- random steps: always the full read's counts
  local names={'iron-plate','copper-plate','coal','stone','rocket'}
  local quals={'normal','normal','rare','epic'}
  math.randomseed(110)
  for _=1,300 do
    local inv=math.random(4)==1 and trash or main
    local k=inv.kinds[math.random(#inv.kinds)]
    if math.random(5)==1 then inv.kinds[#inv.kinds+1]={name=names[math.random(#names)],quality=quals[math.random(#quals)],count=math.random(0,9)}
    else k.count=math.max(0,k.count+math.random(-5,5)) end
    local q=math.random(2)==1
    same(F.hub_counts(pl,q),fresh(q),'step')
  end
  -- an inventory whose counts and full read disagree is always read in full
  local odd=mkinv({{name='rocket',quality='normal',count=3}})
  odd.get_item_count=function() return 99 end
  local pl2={index=6,hub={valid=true,get_inventory=function(i) return i==1 and odd or nil end}}
  same(F.hub_counts(pl2),{rocket=3}); same(F.hub_counts(pl2),{rocket=3}); eq(odd.reads,2)
  odd.kinds[1].count=4; same(F.hub_counts(pl2),{rocket=4})
  -- another hub on the platform: its inventories
  local main3=mkinv({{name='rocket',quality='normal',count=1}})
  pl.hub={valid=true,get_inventory=function(i) return i==1 and main3 or nil end}
  same(F.hub_counts(pl),{rocket=1})
  main3.kinds[1].count=2; same(F.hub_counts(pl),{rocket=2}); eq(main3.reads,1)
  -- an inventory no longer valid: found again
  main3.valid=false
  local main4=mkinv({{name='coal',quality='normal',count=8}})
  pl.hub.get_inventory=function(i) return i==1 and main4 or nil end
  same(F.hub_counts(pl),{coal=8})
  -- the hub gone: nil
  pl.hub.valid=false; eq(F.hub_counts(pl),nil)
  -- a kind gone to 0 when a full read comes stays counted: its return reads nothing in full
  local inv5=mkinv({{name='coal',quality='normal',count=1},{name='stone',quality='normal',count=1}})
  local pl5={index=7,hub={valid=true,get_inventory=function(i) return i==1 and inv5 or nil end}}
  same(F.hub_counts(pl5),{coal=1,stone=1}); eq(inv5.reads,1)
  inv5.kinds[2].count=0; inv5.kinds[3]={name='rocket',quality='normal',count=2}
  same(F.hub_counts(pl5),{coal=1,rocket=2}); eq(inv5.reads,2)
  inv5.kinds[2].count=5
  same(F.hub_counts(pl5),{coal=1,rocket=2,stone=5}); eq(inv5.reads,2,'stone kept at 0, counted again')
  -- more kinds than HUB_KINDS: read in full each time
  F.HUB_KINDS=2
  local inv6=mkinv({{name='coal',quality='normal',count=1},{name='stone',quality='normal',count=1},{name='rocket',quality='normal',count=1}})
  local pl6={index=8,hub={valid=true,get_inventory=function(i) return i==1 and inv6 or nil end}}
  same(F.hub_counts(pl6),{coal=1,stone=1,rocket=1}); same(F.hub_counts(pl6),{coal=1,stone=1,rocket=1}); eq(inv6.reads,2)
  inv6.kinds[3].count=0
  same(F.hub_counts(pl6),{coal=1,stone=1}); same(F.hub_counts(pl6),{coal=1,stone=1}); eq(inv6.reads,3,'2 kinds: counted')
  inv6.kinds[3].count=4
  same(F.hub_counts(pl6),{coal=1,stone=1,rocket=4}); same(F.hub_counts(pl6),{coal=1,stone=1,rocket=4}); eq(inv6.reads,5)
  defines,game=nil,nil
end
print('d22_batch110_freight hub counts kept by kind: ok')

-- 1b. spoiled aboard: two items spoiling into one, both falling in a second, share its rise in name order
do
  defines={inventory={hub_main=1,hub_trash=2},space_platform_state={on_the_path=3}}
  game={tick=600,planets={},get_surface=function() return nil end}
  local spoil={['nutrients']='spoilage',['bioflux']='spoilage'}
  prototypes={item=setmetatable({},{__index=function(_,n) return {get_spoil_ticks=function() return spoil[n] and 100 or 0 end,spoil_result=spoil[n]} end})}
  local kinds={}
  local function set(t) for i=#kinds,1,-1 do kinds[i]=nil end for _,n in ipairs({'bioflux','nutrients','spoilage'}) do kinds[#kinds+1]={name=n,quality='normal',count=t[n] or 0} end end
  local inv={valid=true}
  inv.get_contents=function() local out={} for _,x in ipairs(kinds) do if x.count>0 then out[#out+1]={name=x.name,quality=x.quality,count=x.count} end end return out end
  inv.get_item_count=function(id) local n=0 for _,x in ipairs(kinds) do if id==nil or (type(id)=='table' and id.name==x.name and (id.quality or 'normal')==x.quality) then n=n+x.count end end return n end
  local pl={index=3,name='Sunward',valid=true,hub={valid=true,get_inventory=function(i) return i==1 and inv or nil end},space_location={name='gleba'},force={name='player'}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  set({bioflux=10,nutrients=10}); F.track(pl,600)
  set({bioflux=5,nutrients=5,spoilage=6}); F.track(pl,660)
  local seg=st.freight[3].segs[#st.freight[3].segs]
  eq(seg.spoiled.bioflux,5); eq(seg.spoiled.nutrients,1); eq(seg.into.nutrients,'spoilage')
  defines,game,prototypes=nil,nil,nil
end
print('d22_batch110_freight spoiled in name order: ok')

-- 2. ammunition by phase, written in place
do
  defines={inventory={hub_main=1,hub_trash=2}}
  game={tick=600}
  prototypes={item={['firearm-magazine']={type='ammo'},rocket={type='ammo'},['railgun-ammo']={type='ammo'},['iron-plate']={type='item'}}}
  local made,used={},{}
  local stats={valid=true,get_input_count=function(n) return made[n] or 0 end,get_output_count=function(n) return used[n] or 0 end}
  local force={get_item_production_statistics=function() return stats end}
  local hub={valid=true,get_inventory=function() return nil end}
  local pl={index=9,hub=hub,force=force,surface={},speed=1,paused=false}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  -- the step as it was (a new table of counts each second)
  local function old_step(rec,now,phase)
    local prev=rec.ammo_prev
    rec.ammo_prev=now
    if not (prev and phase) then return end
    rec.phase=rec.phase or {moving={s=0,by={}},still={s=0,by={}},stopped={s=0,by={}}}
    local ph=rec.phase[phase]
    ph.s=ph.s+1
    for name,c in pairs(now) do
      local p0=prev[name] or {made=0,used=0}
      local d=ph.by[name] or {made=0,used=0}
      d.made=d.made+math.max(0,c.made-p0.made); d.used=d.used+math.max(0,c.used-p0.used)
      ph.by[name]=d
    end
    local total=rec.phase.moving.s+rec.phase.still.s+rec.phase.stopped.s
    if total>F.PHASE_KEEP then
      for _,x in pairs(rec.phase) do
        x.s=x.s/2
        for _,d in pairs(x.by) do d.made=d.made/2; d.used=d.used/2 end
      end
    end
  end
  F.PHASE_KEEP=40
  local rec,ref={},{}
  math.randomseed(7)
  local names={'firearm-magazine','rocket','railgun-ammo'}
  for i=1,120 do
    local n=names[math.random(3)]
    made[n]=(made[n] or 0)+math.random(0,3); used[n]=(used[n] or 0)+math.random(0,4)
    if i==60 then made,used={},{} end  -- statistics cleared: every count 0
    local w=i%3==0 and {stopped=true,at='nauvis'} or {leg={from='nauvis',to='gleba'}}
    pl.speed=i%5==0 and 0 or 1
    local phase=w.stopped and 'stopped' or (pl.speed<=0 and 'still' or 'moving')
    old_step(ref,F.ammo_counts(pl),phase)
    F.phase_step(rec,pl,w)
    same(rec.ammo_prev,ref.ammo_prev,'ammo_prev '..i)
    same(rec.phase or {},ref.phase or {},'phase '..i)
  end
  defines,game,prototypes=nil,nil,nil
end
print('d22_batch110_freight ammunition phases in place: ok')

-- 3. the background belt read
do
  defines={inventory={}}
  game={tick=3600*10}
  local reads={max=0,contents=0,platforms=0}
  local function line(items,id)
    return setmetatable({id=id,get_contents=function() reads.contents=reads.contents+1; return items end,
      line_equals=function(o) return o.id==id end},{__len=function() local n=0 for _,r in ipairs(items) do n=n+r.count end return n end})
  end
  local function belt(name,lines,extra)
    local e={valid=true,type=extra and extra.type or 'transport-belt',name=name,
      get_max_transport_line_index=function() reads.max=reads.max+1; return #lines end,
      get_transport_line=function(i) return lines[i] end}
    for k,v in pairs(extra or {}) do e[k]=v end
    return e
  end
  local b1=belt('transport-belt',{line({{name='rocket',count=3}},1),line({},2)})
  local b2=belt('transport-belt',{line({},3),line({},4)})
  local buried={line({{name='rocket',count=4}},13),line({{name='rocket',count=2}},14)}
  local ug_in=belt('underground-belt',{line({},11),line({},12),buried[1],buried[2]},{type='underground-belt',belt_to_ground_type='input'})
  local ug_out=belt('underground-belt',{line({{name='coal',count=1}},15),line({},16),buried[1],buried[2]},{type='underground-belt',belt_to_ground_type='output',neighbours=ug_in})
  local ins={valid=true,type='inserter',held_stack={valid_for_read=true,name='rocket',count=1}}
  local bands={{b1,b2,ins},{ug_in,ug_out}}
  local bi=0
  local walk={band=function() bi=bi+1; return bands[bi] end}
  local surface={index=7,valid=true,get_chunks=function() local done=false; return function() if done then return nil end done=true; return {x=0,y=0} end end}
  local pl={index=4,valid=true,surface=surface,force={name='player'}}
  local pf=setmetatable({name='player'},{__index=function(t,k) if k=='platforms' then reads.platforms=reads.platforms+1; return {pl} end end})
  game.forces={player=pf}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end,walk=walk}
  -- none read lately: no platform looked at
  F.belt_tick(game.tick); eq(reads.platforms,0,'nothing due')
  st.platform_belts={[4]={wanted=game.tick}}
  local t=game.tick
  F.belt_tick(t); eq(st.platform_belts.active,4); eq(reads.platforms,1)
  for k=1,4 do F.belt_tick(t+k*F.BELT_STEP) end
  local done=st.platform_belts[4].done
  eq(done.belts.rocket,9,'3 on a belt, 4+2 buried once'); eq(done.belts.coal,1); eq(done.hands.rocket,1); eq(done.belt_entities,4)
  eq(reads.platforms,1,'the platform found once for the job')
  eq(reads.max,3,'a prototype\'s line count read once (an underground\'s once a side)')
  -- contents read for lines holding items alone: b1 line 1, ug_in lines 3 and 4, ug_out line 1
  eq(reads.contents,4)
  -- the same as the read now (stock_places without a background read or census)
  defines,game=nil,nil
end
print('d22_batch110_freight background belt read: ok')

-- 4. shipment.tick: the request flags read where the platform is stopped and a request waits
do
  defines={inventory={hub_main=1,rocket_silo_rocket=11},logistic_member_index={}}
  prototypes={quality={normal={level=0}}}
  game={tick=1000}
  local force={name='player',index=1}
  local function hub(filters)
    return {valid=true,get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=filters} end} end}
  end
  local filters={{value={name='rocket'},min=10,import_from='nauvis'},{value={name='coal'},min=5,import_from='gleba'}}
  local pl={valid=true,index=1,name='Tern',hub=hub(filters),force=force,schedule={current=1,records={{station='nauvis'},{station='gleba'}}}}
  force.platforms={pl}
  game.forces={player=force}
  local nauvis={index=1,name='nauvis'}
  local gleba={index=2,name='gleba'}
  game.planets={nauvis={surface=nauvis},gleba={surface=gleba}}
  local function silo(s,x) return {valid=true,type='rocket-silo',name='rocket-silo',surface=s,position={x=x,y=0},force=force,use_transitional_requests=true,
    get_inventory=function() return {get_contents=function() return {} end} end,get_logistic_point=function() return {} end} end
  local silos={[1]={silo(nauvis,1),silo(nauvis,2)},[2]={silo(gleba,3)}}
  local rr=0
  local where={}
  local st={}
  local SH=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return st end,
    census_typed=function(f,s) return silos[s.index] end,
    hub_counts=function(p,q) if q then return {['rocket@normal']=2} end return {rocket=2} end,
    where=function() return where end,
    request_rows=function(e,f,only) rr=rr+1; return {{platform=only,item='rocket',quality='normal',line='hub_full: Tern asks rocket 10'}} end}
  -- flying: no flags read; each request waits for the platform
  where={leg={from='gleba',to='nauvis'}}
  SH.tick()
  eq(rr,0,'not stopped: no request_rows')
  -- stopped at Nauvis: its two auto silos' flags (not Gleba's); the hub_full gate appearing is told
  where={stopped=true,at='nauvis'}
  SH.tick()
  eq(rr,2,'the stop\'s auto silos alone')
  eq(st.shipment.last['1|nauvis|rocket'],'waiting:hub_full')
  eq(st.shipment.events[1].text,'shipment: rocket from nauvis for Tern waits: hub_full: Tern asks rocket 10; the game\'s pick: no silo on nauvis fills a rocket for Tern now')
  -- delivered: no flags read
  SH = dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return {} end,census_typed=function(f,s) return silos[s.index] end,
    hub_counts=function(p,q) if q then return {['rocket@normal']=10,['coal@normal']=5} end return {rocket=10,coal=5} end,
    where=function() return where end,request_rows=function() rr=rr+1; return {} end}
  rr=0
  local _,rows=SH.platform(pl,{},nil,true)
  eq(rr,0); eq(#rows,2); eq(rows[1].state,'delivered'); eq(rows[2].state,'delivered')
  -- the ready read still reads them (its silos' lines)
  local out=SH.ready({force=force},pl)
  assert(rr>0,'ready reads the silos\' rows')
  eq(out.planet,'nauvis')
  defines,prototypes,game=nil,nil,nil
end
print('d22_batch110_freight shipment flags read where needed: ok')
