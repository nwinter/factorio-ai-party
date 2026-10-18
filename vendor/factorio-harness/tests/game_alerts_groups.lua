-- Run from the harness root: lua tests/game_alerts_groups.lua
-- game_alerts {} with a group of every kind (shift23 16:20, Muse: game_alerts {} failed "attempt to index field
-- 'center' (a nil value)"). The group without one was outpost_turret_lost: a cell add() makes from a remote turret's
-- death (turret_died), joined to the read's groups after the merge that centres the scan's cells, so it had sx and sy
-- but no center, and the read's line (and the nearest-agent lookup) read g.center.x. Two gun turrets with no robots
-- near died on Nauvis minutes before that call.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local module=arg and arg[1] or 'mod/agent-harness_0.1.0/pushalerts.lua'
defines={entity_status={working=0,no_power=1,low_power=2,no_fuel=3},inventory={turret_ammo=7},alert_type={}}
storage={board={items={}}}
local force={name='player',players={{}},is_chunk_visible=function() return true end}
local function surface(name,index)
  return {name=name,index=index,find_entities_filtered=function() return {} end,
    find_logistic_networks_by_construction_area=function() return {} end}
end
local nauvis,fulgora=surface('nauvis',1),surface('fulgora',2)
game={tick=100000,surfaces={nauvis,fulgora},forces={player=force}}
local places={[1]={key='nauvis',position={x=-100,y=480}},[2]={key='fulgora',position={x=0,y=0}}}
local extra={}
local A=dofile(module){
  state=function() return storage end,
  agents=function() return {{index=1,name='muse'},{index=2,name='sol'}} end,
  who=function(p) return p.name end,
  place=function(index) return places[index] end,
  network_groups=function() return extra end}
local muse={name='muse',force=force,surface=nauvis}

-- The call that failed: two remote turrets lost (no construction robot reaches them), then game_alerts {}.
local function turret(x,y) return {valid=true,name='gun-turret',type='ammo-turret',force=force,surface=nauvis,position={x=x,y=y}} end
A.turret_died(turret(-120,489))
game.tick=game.tick+60*84
A.turret_died(turret(-238,-79))
game.tick=game.tick+60*60
local rows=A.read(muse,{}).groups
local lost={}
for _,r in ipairs(rows) do if r.kind=='outpost_turret_lost' then lost[#lost+1]=r end end
eq(#lost,2,'one group a cell')
table.sort(lost,function(a,b) return a.center.x>b.center.x end)
eq(lost[1].center.x,-120); eq(lost[1].center.y,489)
has(lost[1].line,'1 gun-turret turrets no construction robots reached destroyed in the last 10 minutes near (-120,489)')
eq(lost[1].to[1],'muse (nearest)')
eq(lost[2].center.x,-238); eq(lost[2].center.y,-79)
print('game_alerts_groups outpost_turret_lost: ok')
-- (Against the code before the fix: lua tests/game_alerts_groups.lua OLD_PUSHALERTS.lua fails above, at A.read, with
-- "attempt to index field 'center' (a nil value)".)

-- Every kind's group, as its maker hands it over: the scan's cells (merged and centred), the network, lightning,
-- science-line and belt groups (their own center and line), and the same groups without a center (a mean of their
-- positions, or their first), or with no position at all (said so). Each reads with a line; none fails the call.
local CELL_KINDS={'no_power','unconnected','low_power','no_fuel','no_ammo','flamer_dry','rebuilt_empty','burnt_full',
  'no_material_for_construction','not_enough_construction_robots','not_enough_repair_packs','no_storage','train_out_of_fuel',
  'unclaimed_cargo','collector_path_blocked','input_spoilage','off_by_condition','output_full','captive_starving','captive_urgent','captive_died','output_chest_full','catalyst_gone','heat_no_fuel',
  'outpost_ammo_low','outpost_turret_lost','lost_source.boiler','lost_target.furnace','out_of_ore.iron-ore','out_of_ore.unknown',
  'some_new_game_alert'}
local LINE_KINDS={'power_high','boiler_fuel','feed_chest_low','accumulators_draining','no_power.network','construction_wait',
  'deliveries_wait','requester_full','robots_busy','science_idle','belt_cut','lightning_unconnected','lightning_unused',
  'lightning_storage_full'}
local function cell(kind,x,y,centre)
  local g={key=kind..'|nauvis|'..x..','..y,kind=kind,surface='nauvis',n=2,names={['some-entity']=2},by={},sx=2*x,sy=2*y,
    at={{x=x,y=y},{x=x,y=y}},lost={'some-entity ('..x..','..y..'): what it reads'}}
  if kind:match('^out_of_ore%.') then g.ore=kind:match('^out_of_ore%.(.+)$'); g.still=1 end
  if centre then g.center={x=x,y=y}; g.sx,g.sy=nil,nil end
  return g
end
local function lined(kind,x,y,centre)
  local g={key=kind..'|fulgora|1',kind=kind,surface='fulgora',n=1,names={},by={},at={{x=x,y=y}},line=kind..' line at ('..x..','..y..')'}
  if centre then g.center={x=x,y=y} end
  return g
end
local want={}
for i,k in ipairs(CELL_KINDS) do
  extra[#extra+1]=cell(k,10*i,5,true); want[#want+1]={k,10*i,5}
  extra[#extra+1]=cell(k,10*i,-5,false); want[#want+1]={k,10*i,-5}
end
for i,k in ipairs(LINE_KINDS) do
  extra[#extra+1]=lined(k,7*i,3,true); want[#want+1]={k,7*i,3}
  extra[#extra+1]=lined(k,7*i,-3,false); want[#want+1]={k,7*i,-3}
end
-- No position at all.
extra[#extra+1]={key='no_ammo|nauvis|x',kind='no_ammo',surface='nauvis',n=3,names={['gun-turret']=3},by={},at={}}
extra[#extra+1]={key='robots_busy|nauvis|x',kind='robots_busy',surface='nauvis',n=1,names={},by={},at={},line='logistic #4: no idle logistic robot for 10 min'}
storage.push_alerts=nil
game.tick=game.tick+1800
rows=A.read(muse,{}).groups
local by={}
for _,r in ipairs(rows) do
  assert(type(r.line)=='string' and r.line~='','a line for '..tostring(r.kind))
  assert(not r.line:find('could not be read',1,true),r.line)
  local c=r.center
  by[r.kind..'|'..(c and c.x..','..c.y or 'none')]=r
end
for _,w in ipairs(want) do
  local r=by[w[1]..'|'..w[2]..','..w[3]]
  assert(r,'no row for '..w[1]..' at ('..w[2]..','..w[3]..')')
  if not r.line:find(' line at ',1,true) then has(r.line,string.format('(%d,%d)',w[2],w[3])) end
  assert(r.to and #r.to>0,'someone hears '..w[1])
end
has(by['no_ammo|none'].line,'3 out of ammo on nauvis (no position recorded)')
eq(by['robots_busy|none'].line,'logistic #4: no idle logistic robot for 10 min')
eq(#rows,#want+2+2,'every group read (the two lost turrets too)')
-- The team block, the levels a sleep waits on and the claim lines read the same groups.
eq(#A.lines(muse,{})>0,true)
local levels=A.levels(muse,{'outpost_turret_lost','no_ammo'})
assert(next(levels),'levels')
print('game_alerts_groups every kind: ok')
