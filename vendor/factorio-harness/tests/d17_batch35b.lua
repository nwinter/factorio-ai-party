-- d17 batch35, Groups B and D (the 13:50 poll). Run from the harness root: lua tests/d17_batch35b.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- B1 (Opus): a logistic gate that holds an entity off says where the network's count sits: supply counts, robots'
-- reserved pickups and the requester chests' holdings, neither of which the count includes. ----------------------
do
  game={tick=100}
  defines={logistic_mode={requester=1,buffer=2},entity_status={disabled_by_control_behavior=9},inventory={chest=1}}
  local function chest(n) return {valid=true,type='logistic-container',get_item_count=function() return n end} end
  local net={network_id=243,get_item_count=function() return 732 end,
    get_supply_counts=function() return {storage=-2,['passive-provider']=714,['active-provider']=0,buffer=20} end,
    provider_points={{targeted_items_pickup={{name='steel-plate',count=100},{name='coal',count=9}}},{targeted_items_pickup={{name={name='steel-plate'},count=72}}}},
    requester_points={{mode=1,owner=chest(2000)},{mode=1,owner=chest(529)},{mode=2,owner=chest(40)},{mode=1,owner={valid=true,type='character'}}},
    storages={},passive_provider_points={}}
  local furnace={valid=true,name='electric-furnace',position={x=-64.5,y=-67.5},status=9,
    surface={find_logistic_network_by_position=function() return net end},
    get_control_behavior=function() return {logistic_condition={comparator='<',constant=4000,first_signal={type='item',name='steel-plate'}}} end}
  local G=dofile('mod/agent-harness_0.1.0/gates.lua'){circuit_read=function() return {logistic='steel-plate < 4000',logistic_met=false} end}
  local r=G.row(furnace)
  has(r.line,'logistic condition steel-plate < 4000 (network 243: steel-plate 732; the count: storage -2, passive providers 714, active providers 0, buffers 20; robots have reserved 172 for pickup at its provider points (not in the count); requester chests hold 2529 more (not in the count; 2 read); requester chests hold more of it (2529) than the count)')
  has(r.line,'false now; it is off by it')
  -- the condition holds: no split
  local G2=dofile('mod/agent-harness_0.1.0/gates.lua'){circuit_read=function() return {logistic='steel-plate < 4000',logistic_met=true} end}
  eq(G2.row(furnace).line:find('the count:',1,true),nil)
  game,defines=nil,nil
end

-- B3 (Sol): a removal of a pipe names the parts its segment splits into, what takes from and puts into each, and a
-- part left with takers and no source. ------------------------------------------------------------------------------
do
  local force={}
  local n=0
  local function ent(name,type_,x,flowmap)
    n=n+1
    local e={valid=true,name=name,type=type_,position={x=x,y=0.5},force=force,unit_number=n,links={},flow=flowmap or {}}
    e.fluidbox={[1]=type_=='pipe' and {name='water',amount=10} or nil}
    setmetatable(e.fluidbox,{__len=function() return 1 end})
    e.fluidbox.get_pipe_connections=function() local out={} for _,t in ipairs(e.links) do out[#out+1]={target=t,flow_direction=e.flow[t] or 'input-output'} end return out end
    return e
  end
  local function link(a,b) a.links[#a.links+1]=b; b.links[#b.links+1]=a end
  local pump=ent('offshore-pump','offshore-pump',0.5)
  local p1,p2,p3,p4=ent('pipe','pipe',1.5),ent('pipe','pipe',2.5),ent('pipe','pipe',3.5),ent('pipe','pipe',4.5)
  local plant=ent('chemical-plant','assembling-machine',5.5)
  link(pump,p1); link(p1,p2); link(p2,p3); link(p3,p4); link(p4,plant)
  pump.flow[p1]='output'; plant.flow[p4]='input'
  local FJ=dofile('mod/agent-harness_0.1.0/fluidjoin.lua'){}
  local lines,starved=FJ.removal(force,{p2})
  eq(lines[1],'removing pipe (2.5,0.5) splits its water segment in 2: part 1: 1 pipe; takes from it: nothing; puts into it: offshore-pump (0.5,0.5); part 2: 2 pipes; takes from it: chemical-plant (5.5,0.5); puts into it: nothing; with no source left: part 2 (chemical-plant (5.5,0.5))')
  eq(starved[1],lines[1])
  -- a loop round it: no split
  local by=ent('pipe','pipe',2.5); link(p1,by); link(by,p3)
  eq(FJ.removal(force,{p2}),nil)
  -- removing a run: one line, not one a pipe
  local q1,q2,q3=ent('pipe','pipe',11.5),ent('pipe','pipe',12.5),ent('pipe','pipe',13.5)
  local src=ent('offshore-pump','offshore-pump',10.5); local m2=ent('boiler','boiler',14.5)
  link(src,q1); link(q1,q2); link(q2,q3); link(q3,m2); src.flow[q1]='output'; m2.flow[q3]='input'
  lines=FJ.removal(force,{q2,q3})
  eq(#lines,1); has(lines[1],'removing 2 pieces from pipe (12.5,0.5) splits its water segment in 2')
  -- a machine with two ports on the line: one port's pipe removed, the line still reaches it: no split
  local r1,r2,r3=ent('pipe','pipe',21.5),ent('pipe','pipe',22.5),ent('pipe','pipe',23.5)
  local s3=ent('offshore-pump','offshore-pump',20.5); local m3=ent('chemical-plant','assembling-machine',24.5)
  link(s3,r1); link(r1,r2); link(r2,m3); link(r1,r3); link(r3,m3); s3.flow[r1]='output'; m3.flow[r2]='input'; m3.flow[r3]='input'
  eq(FJ.removal(force,{r2}),nil)
end

-- B4 (Luna): game_alerts by claim (an id, or mine: your own) and since a cursor: only new groups, compact. ----------
do
  defines={entity_status={},inventory={},alert_type={}}
  storage={board={items={[7]={id=7,kind='claim',status='claimed',owner='luna',surface='nauvis',area={left_top={x=0,y=-10},right_bottom={x=50,y=10}}},
    [8]={id=8,kind='claim',status='open',owner='sol',surface='nauvis',area={left_top={x=190,y=-10},right_bottom={x=210,y=10}}}}}}
  local force={name='player',players={}}
  game={tick=36000,surfaces={}}
  local function grp(kind,surface,n,x,name) return {key=kind..'|'..surface..'|'..x..',0',kind=kind,surface=surface,n=n,names={[name]=n},sx=x*n,sy=0,at={{x=x,y=0}},by={},center={x=x,y=0},observed_tick=35000} end
  storage.push_bg=true
  local groups={grp('no_power','nauvis',12,10,'assembling-machine-2'),grp('no_power','nauvis',3,200,'inserter'),grp('no_storage','nauvis',1,40,'logistic-robot'),grp('no_power','vulcanus',5,0,'electric-mining-drill')}
  storage.push_alerts={player={tick=35400,groups=groups}}
  local A=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return storage end,agents=function() return {} end,who=function(p) return p.name end,place=function() return nil end}
  local p={name='luna',force=force,surface={name='nauvis'}}
  local r=A.read(p,{mine=true})
  eq(r.counts,'2 groups: no_power 1, no_storage 1'); eq(#r.lines,2); eq(r.groups,nil); eq(r.cursor,1)
  r=A.read(p,{claim=8})
  eq(r.counts,'1 group: no_power 1'); has(r.lines[1],'no_power nauvis: '); eq(r.cursor,2)
  -- since an older cursor: said, and every group listed; then since the last one: nothing new, then a new group
  game.tick=36600
  r=A.read(p,{mine=true,since=1})
  eq(#r.lines,2); has(r.since_note,'not the cursor of your last game_alerts reply (that was 2)')
  r=A.read(p,{mine=true}); local cur=r.cursor
  game.tick=37200
  r=A.read(p,{mine=true,since=cur})
  eq(r.new,0); eq(r.gone_since,0); eq(r.note,'no new alert or warning since the cursor in the claims named')
  groups[#groups+1]=grp('no_fuel','nauvis',2,30,'boiler')
  table.remove(groups,3)
  r=A.read(p,{mine=true,since=r.cursor})
  eq(r.new,1); eq(r.gone_since,1); eq(#r.lines,1); has(r.lines[1],'no_fuel nauvis: ')
  local ok,err=pcall(A.read,p,{claim=99}); assert(not ok and tostring(err):find('no open claim #99 on the board',1,true),tostring(err))
  defines,storage,game=nil,nil,nil
end

-- B6 (viewer Aurora): platform_defense's damage per asteroid on the route, apart from reach: after its resistances,
-- against the turret's listed damage; a size only little damaged says so. ---------------------------------------------
do
  defines={inventory={turret_ammo=1}}
  local function ammo_item(cat,amount,dtype,projectile)
    local action=projectile and {{action_delivery={{type='projectile',projectile=projectile}}}} or {{action_delivery={{target_effects={{type='damage',damage={amount=amount,type=dtype}}}}}}}
    return {ammo_category={name=cat},get_ammo_type=function() return {action=action} end}
  end
  prototypes={item={['firearm-magazine']=ammo_item('bullet',5,'physical'),rocket=ammo_item('rocket',nil,nil,'rocket')},
    entity={['big-metallic-asteroid']={get_max_health=function() return 2000 end,resistances={physical={decrease=2000,percent=0.1},explosion={decrease=0,percent=0.1}}},
      ['small-metallic-asteroid']={get_max_health=function() return 100 end,resistances={physical={decrease=0,percent=0.1}}}}}
  local force={get_ammo_damage_modifier=function(c) return c=='bullet' and 1.6 or 0 end,get_gun_speed_modifier=function(c) return c=='bullet' and 1.5 or 0 end,
    get_turret_attack_modifier=function(n) return n=='gun-turret' and 1.6 or 0 end}
  local function turret(name,item,cooldown,only)
    local inv={{valid_for_read=item~=nil,name=item}}
    return {name=name,only=only,entity={valid=true,type='ammo-turret',prototype={attack_parameters={cooldown=cooldown}},get_inventory=function() return inv end}}
  end
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){}
  local conn={asteroid_spawn_definitions={{type='entity',asteroid='small-metallic-asteroid'},{type='entity',asteroid='big-metallic-asteroid'},{type='asteroid-chunk',asteroid='metallic-asteroid-chunk'}}}
  local lines,rows=D.damage(force,{turret('gun-turret','firearm-magazine',6),turret('gun-turret','firearm-magazine',6)},conn)
  eq(#rows,2)
  eq(lines[1],'small-metallic-asteroid (100 hp; resists physical 0/10%): 2 gun-turret with firearm-magazine: 761/s each (90.0% of its listed 845/s): 1521/s together, one in 0.0657 s')
  eq(lines[2],'big-metallic-asteroid (2000 hp; resists physical 2000/10%, explosion 0/10%): 2 gun-turret with firearm-magazine: 0.0114/s each (0.00135% of its listed 845/s): reached, little damage: 0.0229/s together, one in 87476 s')
  eq(rows[2].little,true)
  -- a rocket turret: the projectile's damage from the base game's data; a turret listing only small asteroids does not engage the big
  lines=D.damage(force,{turret('rocket-turret','rocket',120),turret('gun-turret','firearm-magazine',6,{['small-metallic-asteroid']=true})},conn)
  eq(lines[2],"big-metallic-asteroid (2000 hp; resists physical 2000/10%, explosion 0/10%): 1 rocket-turret with rocket: 90.0/s each (90.0% of its listed 100/s) (the rocket's damage from the base game's data): 90.0/s together, one in 22.2 s")
  prototypes,defines=nil,nil
end


-- D3 (viewer Aurora, Sol 14:07: reminder 59 reached 10 missed runs for Grok and 16 for Sonnet before a viewer asked): at 2
-- runs missed, one line to the owner; once until that recipient acknowledges or the recipients change. -----------------
do
  game={tick=0}
  local st,boxes={}, {}
  local agents={{name='sol',index=2},{name='grok',index=1},{name='sonnet',index=3}}
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua'){state=function() return st end,
    resolve=function(w) for _,a in ipairs(agents) do if a.name==w then return w end end error('no teammate '..w,0) end,
    agents=function() return agents end,who=function(p) return p.name end,
    deliver=function(index,t) boxes[index]=boxes[index] or {}; table.insert(boxes[index],t) end}
  local sol,grok,sonnet={name='sol',index=2},{name='grok',index=1},{name='sonnet',index=3}
  local function run(ticks) for _=1,ticks do game.tick=game.tick+1; R.tick() end end
  local function told(name) local n=0 for _,t in ipairs(boxes[2] or {}) do if t.text:find(name..' has missed',1,true) then n=n+1 end end return n end
  R.handlers.reminder_add(sol,{name='shared review',message='review the board',every_ticks=3600,recipients='sol,grok,sonnet'})
  run(3600); R.handlers.reminder_ack(sol,{id=1})
  run(3600); R.handlers.reminder_ack(sol,{id=1})
  eq(told('grok'),0,'one run missed: no owner line')
  run(3600); R.handlers.reminder_ack(sol,{id=1})
  eq(told('grok'),1); eq(told('sonnet'),1); eq(told('sol'),0,'the owner is not told of their own runs')
  local line
  for _,t in ipairs(boxes[2]) do if t.text:find('grok has missed',1,true) then line=t.text end end
  has(line,'grok has missed 2 runs of your reminder #1 (shared review, every 1m00s): not acknowledged for 120s; last result: none yet; reminder_edit {id: 1, recipients: ["sol", "sonnet"]} changes its recipients')
  run(3600); R.handlers.reminder_ack(sol,{id=1})
  eq(told('grok'),1,'once while grok has not acknowledged')
  local r=R.handlers.reminders(sol,{}).reminders[1]
  eq(r.missed.grok,3); has(r.states,'grok overdue (3 runs missed, the owner told)')
  -- grok acknowledges: missing 2 runs again tells the owner again
  R.handlers.reminder_ack(grok,{id=1,result='board fine'})
  run(3600*3); R.handlers.reminder_ack(sol,{id=1})
  eq(told('grok'),2)
  has(boxes[2][#boxes[2]].text,'last result: board fine (by grok, ')
  -- a change of recipients: told again at the next missed run
  R.handlers.reminder_edit(sol,{id=1,recipients='sol,grok,sonnet'})
  run(3600)
  eq(told('grok'),3); eq(told('sonnet'),2)
  game=nil
end
print('d17_batch35b D3 missed reminder runs to the owner: ok')
print('d17 batch35b ok')
