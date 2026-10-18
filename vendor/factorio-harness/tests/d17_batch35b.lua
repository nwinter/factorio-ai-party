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

print('d17 batch35b ok')
