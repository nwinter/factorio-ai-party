-- d22 batch110 (BT1, the harness's garbage): the smaller tick parts. Run from the harness root:
-- lua tests/d22_batch110_misc.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

-- ammo_below and platform_energy_below on a platform: the turrets (each with its ammo inventory and get_item_count) and
-- the accumulators found once and kept while their count holds and each is valid; found again when one is gone or
-- another came; what each holds read live at each check. positions: kept while each turret is valid.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2},inventory={hub_main=1,turret_ammo=7}}
  prototypes={item={},fluid={},virtual_signal={}}
  game={tick=0}
  local ents={}
  local finds,counts,inv_reads=0,0,0
  local function turret(x,y,n)
    local e={valid=true,type='ammo-turret',name='gun-turret',position={x=x,y=y}}
    local inv={valid=true,n=n}
    inv.get_item_count=function() assert(e.valid and inv.valid,'read on an invalid turret'); return inv.n end
    inv.get_contents=function() return inv.n>0 and {{name='firearm-magazine',count=inv.n}} or {} end
    e.get_inventory=function(i) assert(i==7); inv_reads=inv_reads+1; return inv end
    e.inv=inv
    ents[#ents+1]=e
    return e
  end
  local function acc(energy,buffer)
    local e={valid=true,type='accumulator',name='accumulator',energy=energy,electric_buffer_size=buffer}
    ents[#ents+1]=e
    return e
  end
  local function match(e,f)
    if not e.valid or e.type~=f.type then return false end
    if f.area then
      local a=f.area
      return e.position.x>=a[1][1] and e.position.x<=a[2][1] and e.position.y>=a[1][2] and e.position.y<=a[2][2]
    end
    return true
  end
  local surface={index=9,name='platform-9'}
  surface.count_entities_filtered=function(f)
    counts=counts+1
    local n=0 for _,e in ipairs(ents) do if match(e,f) then n=n+1 end end
    return f.limit and math.min(n,f.limit) or n
  end
  surface.find_entities_filtered=function(f)
    finds=finds+1
    local out={} for _,e in ipairs(ents) do if match(e,f) then out[#out+1]=e end if f.limit and #out>=f.limit then break end end
    return out
  end
  local pl={valid=true,name='Asterion',surface=surface}
  local p={force={index=1,platforms={pl}}}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(q) return {x=q.x or q[1],y=q.y or q[2]} end}
  local t1,t2,t3=turret(1.5,1.5,20),turret(3.5,1.5,5),turret(-2.5,4.5,50)
  local a1,a2=acc(2e6,5e6),acc(1e6,5e6)
  local c={['until']='ammo_below',platform='Asterion',count=10}
  C.validate(c)
  local met,saw=C.check(p,c)
  eq(met,true); eq(saw,'1 turrets below 10 (of 3 on Asterion; lowest gun-turret (3.5,1.5): 5 firearm-magazine)'); eq(finds,1); eq(inv_reads,3)
  -- the same turrets: no find, no inventory read; what each holds now
  t2.inv.n=15; t1.inv.n=8
  met,saw=C.check(p,c)
  eq(met,true); eq(saw,'1 turrets below 10 (of 3 on Asterion; lowest gun-turret (1.5,1.5): 8 firearm-magazine)'); eq(finds,1); eq(inv_reads,3)
  -- a turret gone: found again
  t1.valid=false
  met,saw=C.check(p,c)
  eq(met,false); eq(saw,'0 turrets below 10 (of 2 on Asterion; lowest gun-turret (3.5,1.5): 15 firearm-magazine)'); eq(finds,2)
  -- one gone and one new in the same ticks (the count the same): the gone one is seen, found again
  t2.valid=false
  local t4=turret(6.5,6.5,0)
  met,saw=C.check(p,c)
  eq(met,true); eq(saw,'1 turrets below 10 (of 2 on Asterion; lowest gun-turret (6.5,6.5): no ammo)'); eq(finds,3)
  -- a new turret: the count differs, found again
  local t5=turret(8.5,8.5,3)
  met,saw=C.check(p,c)
  eq(saw,'2 turrets below 10 (of 3 on Asterion; lowest gun-turret (6.5,6.5): no ammo)'); eq(finds,4)
  met,saw=C.check(p,c); eq(finds,4)
  -- an area: its own list, kept by the condition's area
  local ca={['until']='ammo_below',platform='Asterion',count=10,area={{0,0},{7,7}}}
  met,saw=C.check(p,ca)
  eq(saw,'1 turrets below 10 (of 1 on Asterion; lowest gun-turret (6.5,6.5): no ammo)'); eq(finds,5)
  met,saw=C.check(p,ca); eq(finds,5)
  t4.inv.n=30
  met,saw=C.check(p,ca); eq(saw,'0 turrets below 10 (of 1 on Asterion; lowest gun-turret (6.5,6.5): 30 firearm-magazine)'); eq(finds,5)
  -- the whole platform's list is still kept
  met,saw=C.check(p,c); eq(saw,'1 turrets below 10 (of 3 on Asterion; lowest gun-turret (8.5,8.5): 3 firearm-magazine)'); eq(finds,5)
  -- positions: one find a position, then none while each is valid; a gone one is said as before
  local cp={['until']='ammo_below',platform='Asterion',count=10,positions={{x=-2.5,y=4.5},{x=8.5,y=8.5}}}
  met,saw=C.check(p,cp)
  eq(saw,'1 turrets below 10 (of 2 on Asterion; lowest gun-turret (8.5,8.5): 3 firearm-magazine)'); eq(finds,7)
  local before=counts
  met,saw=C.check(p,cp); eq(finds,7); eq(counts,before)
  t5.valid=false
  local ok,err=pcall(C.check,p,cp)
  eq(ok,false); eq(err,'no ammo turret of ours at (8.5,8.5) on Asterion')
  -- a surface that cannot count: found at each check, as before
  local plain={index=10,find_entities_filtered=surface.find_entities_filtered}
  local pl2={valid=true,name='Bare',surface=plain}
  local p2={force={index=1,platforms={pl2}}}
  local cb={['until']='ammo_below',platform='Bare',count=10}
  local f0=finds
  C.check(p2,cb); C.check(p2,cb); eq(finds,f0+2)

  -- accumulators: kept the same way
  local ce={['until']='platform_energy_below',platform='Asterion',fraction=0.5}
  C.validate(ce)
  f0=finds
  met,saw=C.check(p,ce)
  eq(met,true); eq(saw,'platform Asterion: 2 accumulators hold 3.0 of 10.0 MJ (30%; met under 50%)'); eq(finds,f0+1)
  a1.energy=5e6
  met,saw=C.check(p,ce)
  eq(met,false); eq(saw,'platform Asterion: 2 accumulators hold 6.0 of 10.0 MJ (60%; met under 50%)'); eq(finds,f0+1)
  a2.valid=false; acc(0,5e6)
  met,saw=C.check(p,ce)
  eq(saw,'platform Asterion: 2 accumulators hold 5.0 of 10.0 MJ (50%; met under 50%)'); eq(finds,f0+2)
  acc(5e6,5e6)
  met,saw=C.check(p,ce)
  eq(saw,'platform Asterion: 3 accumulators hold 10.0 of 15.0 MJ (66%; met under 50%)'); eq(finds,f0+3)
  C.check(p,ce); eq(finds,f0+3)
end
print('d22_batch110 BT1 ammo_below and platform_energy_below kept: ok')

-- flightwatch: a watch's platform kept while valid and still its force's of that index; each turret's ammo inventory,
-- get_item_count and first slot read once and kept while valid; the count and the slot's ammo read live each sample.
do
  defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2}}
  prototypes={item={['repair-pack']={type='repair-tool'}}}
  local inv_reads,plat_reads=0,0
  local function turret(x,y,n,ammo)
    local t={valid=true,name='gun-turret',type='ammo-turret',unit_number=1000+math.floor(x),position={x=x,y=y}}
    local slot={valid=true}
    local inv={valid=true}
    t.n,t.ammo=n,ammo
    inv.get_item_count=function() assert(inv.valid,'read on an invalid inventory'); return t.n end
    setmetatable(slot,{__index=function(_,k) if k=='valid_for_read' then return t.n>0 elseif k=='name' then return t.ammo end end})
    inv[1]=slot
    t.get_inventory=function() inv_reads=inv_reads+1; return inv end
    t.inv=inv
    return t
  end
  local a,b=turret(1.5,2.5,10,'firearm-magazine'),turret(5.5,2.5,0,'firearm-magazine')
  local list={a,b}
  local surface={name='platform-3',find_entities_filtered=function(f) if f.type=='ammo-turret' then return list end return {} end}
  local force={name='player'}
  local pl={valid=true,index=3,name='Asterion',surface=surface,force=force,state=1,space_connection={from={name='nauvis'},to={name='gleba'}}}
  local plats={[3]=pl}
  force.platforms=setmetatable({},{__index=function(_,k) plat_reads=plat_reads+1; return plats[k] end})
  game={tick=1000,forces={player=force}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
    platform=function() return pl end,leg=function() return {from='nauvis',to='gleba'} end}
  local p={name='sol',force=force,index=1}
  F.call(p,{platform='Asterion'})
  local w=st.flightwatch.list[1]
  eq(w.turrets[1].now,10); eq(w.turrets[2].now,0); eq(w.turrets[1].ammo,'firearm-magazine')
  local function run(to) while game.tick<to do game.tick=game.tick+1; if game.tick%60==51 then F.tick(game.tick) end end end
  run(1060)
  local reads,pr=inv_reads,plat_reads
  -- the kept inventories and slots: no inventory read, the counts and the ammo as they are now
  a.n,a.ammo=3,'piercing-rounds-magazine'; b.n=7
  run(1400)
  eq(w.turrets[1].now,3); eq(w.turrets[1].min,3); eq(w.turrets[1].ammo,'piercing-rounds-magazine'); eq(w.turrets[2].now,7)
  eq(inv_reads,reads,'the inventories kept')
  eq(plat_reads,pr,'the platform kept')
  -- an inventory no longer valid: read again
  a.inv.valid=false
  local fresh={valid=true,get_item_count=function() return 42 end}
  fresh[1]={valid=true,valid_for_read=true,name='uranium-rounds-magazine'}
  a.get_inventory=function() inv_reads=inv_reads+1; return fresh end
  run(1460)
  eq(w.turrets[1].now,42); eq(w.turrets[1].ammo,'uranium-rounds-magazine'); eq(inv_reads,reads+1)
  -- the platform gone (invalid): the watch ends as before
  pl.valid=false; plats[3]=nil
  run(1520)
  eq(w.why,'the platform is gone')
end
print('d22_batch110 BT1 flightwatch platform and turret inventories kept: ok')

-- platalerts: the background step reads no force's platforms while no scan is due; a scan's turrets (each with its
-- inventory and get_item_count) kept while their count holds and each is valid; the rounds read live; the hub's item
-- types by name once.
do
  game={tick=100000}
  defines={space_platform_state={on_the_path=4,waiting_at_station=6},inventory={turret_ammo=3,hub_main=1}}
  local type_reads=0
  prototypes={item=setmetatable({},{__index=function(_,k) type_reads=type_reads+1; return {type=k=='repair-pack' and 'repair-tool' or 'ammo'} end})}
  local st={}
  local finds,counts,inv_reads,plat_reads=0,0,0,0
  local turrets={}
  local function turret(n)
    local t={valid=true,name='gun-turret',type='ammo-turret'}
    local inv={valid=true}
    t.n=n
    inv.get_item_count=function() return t.n end
    t.get_inventory=function() inv_reads=inv_reads+1; return inv end
    t.inv=inv
    turrets[#turrets+1]=t
    return t
  end
  local surface={index=4,name='platform-4'}
  surface.count_entities_filtered=function(f) counts=counts+1; local n=0 for _,t in ipairs(turrets) do if t.valid then n=n+1 end end return n end
  surface.find_entities_filtered=function(f) finds=finds+1; local o={} for _,t in ipairs(turrets) do if t.valid then o[#o+1]=t end end return o end
  local hub={valid=true,health=1000,max_health=1000,get_inventory=function() return {get_contents=function() return {{name='repair-pack',count=12},{name='firearm-magazine',count=200}} end} end}
  local pl={valid=true,index=4,name='P4',state=6,surface=surface,force={name='player',index=1},hub=hub}
  local list={pl}
  local force={platforms=nil}
  setmetatable(force,{__index=function(_,k) if k=='platforms' then plat_reads=plat_reads+1; return list end end})
  game.forces={player=force}
  local A=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end,who=function() return 'sol' end}
  local t1,t2=turret(0),turret(30)
  st.platform_alerts={by={[4]={scan={tick=game.tick-100},scan_wanted=game.tick-100,seq=0,minutes={},workers={}}}}
  game.tick=game.tick+20-(game.tick%20)
  A.tick(game.tick)
  eq(plat_reads,0,'no scan due: no platform read'); eq(st.platform_alerts.scan_bg,game.tick)
  -- due: the platforms read, the oldest scanned
  game.tick=game.tick+600
  A.tick(game.tick)
  eq(plat_reads,1); eq(finds,1); eq(st.platform_alerts.by[4].scan.tick,game.tick)
  eq(st.platform_alerts.by[4].scan.empty,1); eq(st.platform_alerts.by[4].scan.rounds,30); eq(st.platform_alerts.by[4].scan.packs,12)
  eq(st.platform_alerts.by[4].scan.hub_ammo['firearm-magazine'],200)
  -- the same turrets: no find, no inventory read; the rounds as they are now; the item types not read again
  local reads,tr=inv_reads,type_reads
  t1.n=5
  local d=A.defense(pl)
  eq(d.turrets,'2 gun-turrets: 0 empty, 1 low (under 10 rounds)'); eq(finds,1); eq(inv_reads,reads); eq(type_reads,tr)
  -- one gone and one new (the count the same): found again
  t2.valid=false; turret(0)
  d=A.defense(pl)
  eq(d.turrets,'2 gun-turrets: 1 empty, 1 low (under 10 rounds)'); eq(finds,2)
  -- one more: found again
  turret(50)
  d=A.defense(pl)
  eq(d.turrets,'3 gun-turrets: 1 empty, 1 low (under 10 rounds)'); eq(finds,3)
  A.defense(pl); eq(finds,3)
  defines,prototypes=nil,nil
end
print('d22_batch110 BT1 platalerts scans: ok')

-- threat: the background sweep reads each force and surface once while they are valid; its chunk positions filled in
-- place give the same chart; the sorted keys follow keys added and removed.
do
  local force_reads,surface_reads=0,0
  local function new_force()
    return {valid=true,name='player',get_spawn_position=function() return {x=0,y=0} end,
      is_chunk_charted=function(s,c) return true end,is_chunk_visible=function(s,c) return c.x==0 and c.y==0 end}
  end
  local force=new_force()
  local surfaces={}
  local function surface(i)
    surfaces[i]={valid=true,index=i,name='s'..i,is_chunk_generated=function(c) return c.x>=-1 and c.x<=1 and c.y>=-1 and c.y<=1 end,
      get_pollution=function(pos) return (pos.x==16 and pos.y==16) and 2.5 or (pos.x==48 and pos.y==-16) and 1 or 0 end,
      find_entities_filtered=function() return {} end}
    return surfaces[i]
  end
  surface(1); surface(2)
  game={tick=10000,players={},forces=setmetatable({},{__index=function(_,k) force_reads=force_reads+1; return k=='player' and force or nil end}),
    get_surface=function(i) surface_reads=surface_reads+1; return surfaces[i] end}
  local st={}
  local T=dofile('mod/agent-harness_0.1.0/threat.lua'){state=function() return st end,distance=function(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end}
  local function shared(i) return {force='player',surface=i,chart={tick=0,gen={left=0,right=0,top=0,bottom=0}}} end
  st.threat_shared={['player/1']=shared(1)}
  local function run() local n=0 repeat game.tick=game.tick+1; T.tick(game.tick); n=n+1 until not next(st.chart_jobs) or n>100 end
  run()
  local ch=st.threat_shared['player/1'].chart
  eq(ch.charted_chunks,9); eq(ch.visible_chunks,1); eq(ch.cloud.chunks,2); eq(#ch.cells,2)
  local cells={} for _,c in ipairs(ch.cells) do cells[#cells+1]=string.format('%d,%d=%g',c[1],c[2],c[3]) end
  table.sort(cells); eq(table.concat(cells,' '),'0,0=2.5 1,-1=1')
  eq(force_reads,1,'the force read once'); eq(surface_reads,1,'the surface read once')
  -- a key added: swept too; a force no longer valid: read again
  st.threat_shared['player/2']=shared(2)
  force.valid=false; force=new_force()
  game.tick=game.tick+3600; T.tick(game.tick)
  assert(st.chart_jobs['player/1'] and st.chart_jobs['player/2'],'both swept')
  eq(force_reads,2); eq(surface_reads,2)
  run()
  eq(st.threat_shared['player/2'].chart.charted_chunks,9)
  -- a key removed: not swept
  st.threat_shared['player/1']=nil
  game.tick=game.tick+3600; T.tick(game.tick)
  assert(st.chart_jobs['player/2'] and not st.chart_jobs['player/1'],'only the key there')
  -- a surface gone: read again (nil), its sweep ends
  surfaces[2].valid=false; surfaces[2]=nil
  game.tick=game.tick+1; T.tick(game.tick)
  eq(st.chart_jobs['player/2'],nil)
end
print('d22_batch110 BT1 threat sweep reads: ok')

-- spoil: the egg watch's holders read without a closure a read: the same rows (an inserter's hand and a ground stack
-- only when their item hatches; a belt or an inventory only when it holds one); between sweeps the force is not read.
do
  game={tick=1000,surfaces={},forces={}}
  defines={inventory={chest=1,assembling_machine_input=2,assembling_machine_output=3,character_main=4,character_trash=5,hub_main=6,
    furnace_source=7,furnace_result=8,cargo_wagon=9,car_trunk=10,spider_trunk=11,cargo_landing_pad_main=12,rocket_silo_rocket=13,robot_cargo=21}}
  local trig={items_per_trigger=1,trigger={{type='create-entity',entity_name='big-wriggler-pentapod-premature',as_enemy=true}}}
  prototypes={item={['pentapod-egg']={get_spoil_ticks=function() return 54000 end,spoil_to_trigger_result=trig},
    yumako={get_spoil_ticks=function() return 216000 end},['iron-plate']={get_spoil_ticks=function() return 0 end}}}
  local force_reads=0
  local st={}
  local S=dofile('mod/agent-harness_0.1.0/spoil.lua'){state=function() return st end,force=function() force_reads=force_reads+1; return nil end,
    characters=function() return {} end}
  local function stack(name,count,left,pct) return {valid_for_read=true,name=name,count=count,quality={name='normal'},spoil_tick=game.tick+left,spoil_percent=pct} end
  local function inv(list)
    local t={valid=true}
    for i,s in ipairs(list) do t[i]=s end
    t.get_item_count=function(name) local n=0; for i=1,#t do if t[i].valid_for_read and t[i].name==name then n=n+t[i].count end end; return n end
    return t
  end
  local names={'pentapod-egg'}
  local hand=S.hatching_in({valid=true,type='inserter',held_stack=stack('pentapod-egg',2,600,0.9)},names)
  eq(#hand,1); eq(hand[1].name,'pentapod-egg'); eq(hand[1].count,2)
  eq(#S.hatching_in({valid=true,type='inserter',held_stack=stack('yumako',5,600,0.9)},names),0)
  eq(#S.hatching_in({valid=true,type='inserter',held_stack={valid_for_read=false}},names),0)
  local ground=S.hatching_in({valid=true,type='item-entity',stack=stack('pentapod-egg',1,6000,0.5)},names)
  eq(#ground,1); eq(ground[1].count,1)
  local box=inv{stack('yumako',3,900,0.2),stack('pentapod-egg',4,1200,0.6)}
  local chest=S.hatching_in({valid=true,type='container',get_inventory=function(i) return i==1 and box or nil end},names)
  eq(#chest,1); eq(chest[1].count,4); eq(chest[1].name,'pentapod-egg')
  local plain=inv{stack('yumako',3,900,0.2)}
  eq(#S.hatching_in({valid=true,type='container',get_inventory=function() return plain end},names),0)
  eq(#S.hatching_in({valid=true,type='container',get_inventory=function() error('gone') end},names),0)
  eq(#S.hatching_in({valid=true,type='lamp'},names),0)
  -- between sweeps: the force not read
  st.eggs={anchors={},places={},told={},seq=0,tick=1000,anchor_tick=1000}
  S.tick(1500); eq(force_reads,0)
  S.tick(1000+S.SWEEP_TICKS); eq(force_reads,1)
end
print('d22_batch110 BT1 spoil egg watch reads: ok')

-- beltgaps: a one-tile belt's tile without its bounding box read; a refresh read in one step brings a row of a belt
-- standing as it says up to date in place (the same fields as a new row); a belt turned gets a new row; one gone is a
-- cut as before.
do
  prototypes={entity={['transport-belt']={collision_box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}},
    splitter={collision_box={left_top={x=-0.9,y=-0.4},right_bottom={x=0.9,y=0.4}}}}}
  local box_reads=0
  local force={name='player',is_chunk_visible=function() return true end}
  local surface={name='nauvis'}
  local ents={}
  local function belt(x,y,name,n,dir)
    local e={valid=true,type=name,name=name,position={x=x,y=y},direction=dir or 4,force=force,surface=surface,items=n,last_user={name='sol'}}
    e.get_item_count=function() return e.items end
    local box=name=='splitter' and {left_top={x=x-0.9,y=y-0.4},right_bottom={x=x+0.9,y=y+0.4}} or {left_top={x=x-0.4,y=y-0.4},right_bottom={x=x+0.4,y=y+0.4}}
    setmetatable(e,{__index=function(_,k) if k=='bounding_box' then box_reads=box_reads+1; return box end end})
    ents[#ents+1]=e
    return e
  end
  local b1,b2,sp=belt(1.5,1.5,'transport-belt',3),belt(2.5,1.5,'transport-belt',0),belt(5,3.5,'splitter',2)
  surface.find_entities_filtered=function() local o={} for _,e in ipairs(ents) do if e.valid then o[#o+1]=e end end return o end
  game={tick=15,forces={player=force},surfaces={nauvis=surface}}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/beltgaps.lua'){state=function() return st end}
  st.belt_memory={chunks={['player|nauvis|0,0']={force='player',surface='nauvis',x=0,y=0}},order={'player|nauvis|0,0'},next=1}
  local c=st.belt_memory.chunks['player|nauvis|0,0']
  B.tick(15)
  eq(box_reads,1,'only the splitter\'s box read')
  local r1=c.tiles['1,1']
  eq(r1.name,'transport-belt'); eq(r1.items,3); eq(r1.carried_tick,15); eq(r1.position.x,1.5); eq(r1.by,'sol')
  eq(c.tiles['4,3'],c.tiles['5,3'],'the splitter on its two tiles'); eq(c.tiles['4,3'].items,2)
  -- the next read: the same rows, up to date
  b1.items=0; b2.items=5; b2.last_user=nil
  game.tick=30; B.tick(30)
  eq(c.tiles['1,1'],r1,'the row kept'); eq(r1.items,0); eq(r1.carried_tick,15); eq(r1.tick,30)
  eq(c.tiles['2,1'].items,5); eq(c.tiles['2,1'].carried_tick,30); eq(c.tiles['2,1'].by,nil)
  -- turned: a new row
  b1.direction=8
  game.tick=45; B.tick(45)
  assert(c.tiles['1,1']~=r1,'a new row'); eq(c.tiles['1,1'].direction,8); eq(c.tiles['1,1'].carried_tick,15)
  -- gone after carrying: a cut
  b2.valid=false
  game.tick=60; B.tick(60)
  eq(c.tiles['2,1'],nil); assert(c.cuts['2,1'] and c.cuts['2,1'].carried_tick==45,'the cut')
end
print('d22_batch110 BT1 beltgaps rows: ok')
