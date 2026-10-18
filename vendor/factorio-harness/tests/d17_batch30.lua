-- d17 batch30. Run from the harness root: lua tests/d17_batch30.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A2 (Sol and viewer Foobator 05:47): programmable speaker alerts (the game's custom alerts) in the team block, a wait
-- on alert kinds speaker, game_alerts kind speaker; configure's speaker_alert.
do
  defines={entity_status={},inventory={},alert_type={custom=17,entity_destroyed=1}}
  storage={board={items={}}}
  local force={name='player',players={}}
  local nauvis={name='nauvis',index=1,find_entities_filtered=function() return {} end}
  local vulcanus={name='vulcanus',index=3,find_entities_filtered=function() return {} end}
  game={tick=36000,surfaces=setmetatable({nauvis,vulcanus},{__index=function(_,k) return ({nauvis=nauvis,vulcanus=vulcanus})[k] end})}
  local speaker={valid=true,type='programmable-speaker',name='programmable-speaker',unit_number=55,position={x=12.5,y=-3.5},last_user={name='sol'},
    alert_parameters={show_alert=true,show_on_map=true,icon_signal_id={type='item',name='rocket-part'},alert_message='silo 2 blocked'}}
  local alerts={}
  local reader={get_alerts=function(f) eq(f.type,17); return alerts end}
  local places={[1]={key='nauvis',position={x=0,y=0}},[2]={key='vulcanus',position={x=0,y=0}},[3]={key='nauvis',position={x=5,y=5}}}
  local A=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
    state=function() return storage end,
    agents=function() return {{index=1,name='astra'},{index=2,name='sol'},{index=3,name='luna'}} end,
    who=function(p) return p.name end,
    place=function(index) return places[index] end,
    alert_reader=function() return reader end}
  local function agent(name,s) return {name=name,force=force,surface=s} end
  local astra,sol,luna=agent('astra',nauvis),agent('sol',vulcanus),agent('luna',nauvis)
  local ha,hs,hl={},{},{}
  eq(#A.speaker_lines(astra,ha),0)
  local base=A.levels(astra,{'speaker'})
  eq(next(base),nil)
  -- the speaker alerts: its builder (on Vulcanus) and the agents on Nauvis hear it, once
  alerts={[1]={[17]={{tick=35400,target=speaker,message='ignored when the speaker has one'}}}}
  game.tick=game.tick+60
  local l=A.speaker_lines(astra,ha)
  eq(#l,1); eq(l[1],'speaker alert at (12.5,-3.5) (built by sol): "silo 2 blocked" [item:rocket-part], 11s ago')
  eq(A.speaker_lines(sol,hs)[1],'speaker alert on nauvis at (12.5,-3.5) (built by sol): "silo 2 blocked" [item:rocket-part], 11s ago')
  eq(#A.speaker_lines(luna,hl),1)
  eq(#A.speaker_lines(astra,ha),0,'told once while up')
  -- a wait on alert kinds speaker: new since it began
  local now=A.levels(astra,{'speaker'})
  local key,g=next(now)
  eq(key,'speaker|nauvis|55'); eq(base[key],nil); eq(g.level,35400); has(g.text,'"silo 2 blocked"')
  -- not read again within SPEAKER_TICKS (kept in storage)
  alerts={}
  game.tick=game.tick+30
  eq(#A.speakers(force),1)
  -- gone, then up again: news again
  game.tick=game.tick+60
  eq(#A.speakers(force),0); eq(#A.speaker_lines(astra,ha),0); eq(ha.speakers,nil)
  alerts={[1]={[17]={{tick=game.tick,target=speaker}}}}
  game.tick=game.tick+60
  eq(#A.speaker_lines(astra,ha),1)
  -- a custom alert of a script (no speaker target) is not a speaker alert
  alerts={[1]={[17]={{tick=game.tick,target=nil,position={x=1,y=1},message='script'}}}}
  game.tick=game.tick+60
  eq(#A.speakers(force),0)
  -- game_alerts kind speaker, with who hears it
  alerts={[1]={[17]={{tick=game.tick,target=speaker}}}}
  game.tick=game.tick+60
  storage.push_bg=true; storage.push_alerts={player={tick=game.tick,groups={}}}
  local r=A.read(astra,{kind='speaker'})
  eq(#r.groups,1); eq(r.groups[1].kind,'speaker'); eq(r.groups[1].message,'silo 2 blocked'); eq(r.groups[1].icon,'item:rocket-part')
  eq(table.concat(r.groups[1].to,', '),'astra (on nauvis), luna (on nauvis), sol (built)')
  eq(#A.read(astra,{kind='no_power'}).groups,0)
  defines,storage,game=nil,nil,nil
end
do
  prototypes={item={['rocket-part']={}},fluid={water={}},virtual_signal={['signal-A']={}},quality={normal={}}}
  defines={wire_connector_id={}}
  local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
  local cb={circuit_condition={first_signal={type='item',name='rocket-part'},comparator='<',constant=1,fulfilled=true}}
  local sp={valid=true,type='programmable-speaker',name='programmable-speaker',position={x=12.5,y=-3.5},
    alert_parameters={show_alert=false,show_on_map=true,alert_message=''},get_control_behavior=function() return cb end,get_or_create_control_behavior=function() return cb end}
  local after,before=C.set_speaker_alert(sp,{show_alert=true,message='silo 2 blocked',icon='rocket-part'})
  eq(before.line,'alert off (on the map): no message; circuit condition rocket-part < 1 (holds now)')
  eq(after.show_alert,true); eq(after.message,'silo 2 blocked'); eq(after.icon,'rocket-part'); eq(after.show_on_map,true)
  eq(sp.alert_parameters.icon_signal_id.name,'rocket-part'); eq(sp.alert_parameters.icon_signal_id.type,'item')
  eq(after.line,'alert on (on the map): "silo 2 blocked", icon rocket-part; circuit condition rocket-part < 1 (holds now)')
  after=C.set_speaker_alert(sp,{icon=false,show_on_map=false,condition='signal-A > 5'})
  eq(after.icon,nil); eq(after.message,'silo 2 blocked'); eq(cb.circuit_condition.first_signal.name,'signal-A'); has(after.line,'signal-A > 5')
  fails(function() C.set_speaker_alert(sp,{volume=3}) end,'speaker_alert takes show_alert')
  fails(function() C.set_speaker_alert(sp,{show_alert='yes'}) end,'must be true or false')
  fails(function() C.set_speaker_alert({valid=true,type='lamp',name='small-lamp',position={x=0,y=0}},{show_alert=true}) end,'is a lamp')
  prototypes,defines=nil,nil
end
print('d17_batch30 A2 speaker alerts: ok')

-- B1 (Sol, Astra and viewer Foobator 05:43): reminder checklists: named steps, each with its own ack and result and
-- optionally its own cadence; progress per recipient; the grouped read; done only when every step is recorded; leave
-- and resume.
do
  game={tick=1000}
  local st,sent={},{}
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua'){state=function() return st end,who=function(p) return p.name end,
    resolve=function(n) return n end,agents=function() return {{name='sol',index=1},{name='astra',index=2}} end,
    deliver=function(index,t) sent[#sent+1]={index=index,t=t} end}
  local sol,astra={name='sol'},{name='astra'}
  local r=R.handlers.reminder_add(sol,{name='launch',message='Petrel launch',due_in_ticks=600,recipients='sol, astra',
    steps={'fuel the silo',{name='load the rocket',every_ticks=1800},'launch'}})
  local id=r.added
  game.tick=1620; R.tick()
  eq(#sent,2)
  eq(sent[1].t.text,'launch (sol, once): Petrel launch; checklist, next step 1 of 3 "fuel the silo" (0 of 3 done); reminder_ack {id: 1, result} records it')
  -- a step a recipient; the next unfinished step by default
  local a=R.handlers.reminder_ack(sol,{id=id,result='4 rocket fuel in'})
  eq(a.recorded,1); eq(a.done,'1 of 3 steps'); has(a.next_step,'step 2 of 3 "load the rocket" (again every 30s while it is next)')
  eq(R.handlers.reminders(astra,{}).reminders[1].next_step,'step 1 of 3 "fuel the silo"','progress is per recipient')
  -- step 2's own cadence: its line again while it is sol's next step
  game.tick=1620+1800; R.tick()
  eq(#sent,3); eq(sent[3].index,1); has(sent[3].t.text,'next step 2 of 3 "load the rocket" (again every 30s while it is next) (1 of 3 done)')
  -- an emergency: leave; no step lines; the grouped read says so
  a=R.handlers.reminder_ack(sol,{id=id,leave=true})
  eq(a.at_step,2); has(a.note,'set aside at step 2 of 3')
  game.tick=game.tick+3600; R.tick()
  eq(#sent,3,'no step line while left')
  local pend=R.handlers.reminders(sol,{pending=true})
  eq(pend.count,1); has(pend.lines[1],'#1 launch: Petrel launch; next step 2 of 3 "load the rocket"'); has(pend.lines[1],'(1 of 3 done)'); has(pend.lines[1],'left 1m00s ago (resume')
  has(R.handlers.reminders(sol,{}).reminders[1].states,'sol left at step 2')
  -- resume at the next unfinished step, then the rest
  a=R.handlers.reminder_ack(sol,{id=id,resume=true})
  eq(a.recorded,nil); eq(a.resumed,true); has(a.next_step,'step 2 of 3')
  R.handlers.reminder_ack(sol,{id=id,step=3,result='launched'})
  a=R.handlers.reminder_ack(sol,{id=id})
  eq(a.recorded,2); eq(a.done,'all 3 steps'); eq(a.checklist_done,nil,'astra has not')
  eq(R.handlers.reminders(sol,{pending=true}).count,0)
  local row=R.handlers.reminders(sol,{}).reminders[1]
  eq(row.done,nil); eq(row.steps[3].result,'launched'); eq(row.steps[1].result,'4 rocket fuel in')
  for i=1,3 do R.handlers.reminder_ack(astra,{id=id}) end
  row=R.handlers.reminders(sol,{}).reminders[1]
  eq(row.done,true)
  local ok,err=pcall(R.handlers.reminder_ack,astra,{id=id})
  assert(not ok and tostring(err):find('has no run waiting for you',1,true),tostring(err))
  -- refusals
  ok,err=pcall(R.handlers.reminder_add,sol,{message='x',due_in_ticks=600,steps={{name='a',every_ticks=60}}})
  assert(not ok and tostring(err):find('step 1 every_ticks must be 1800',1,true),tostring(err))
  local plain=R.handlers.reminder_add(sol,{message='plain',due_in_ticks=600}).added
  ok,err=pcall(R.handlers.reminder_ack,sol,{id=plain,step=1})
  assert(not ok and tostring(err):find('for a checklist',1,true),tostring(err))
  game=nil
end
print('d17_batch30 B1 reminder checklists: ok')

-- B2 (Sonnet 05:39: 12 advanced-circuit assemblers starved the low-density-structure row of plastic; its requesters
-- asked for none): supply {item, requesters}: who gets it, and requesters feeding its users without asking for it.
do
  defines={flow_precision_index={ten_minutes=2},logistic_member_index={logistic_container=1}}
  prototypes={item={['plastic-bar']={},['copper-plate']={},['steel-plate']={}},recipe={
    ['advanced-circuit']={name='advanced-circuit',energy=6,ingredients={{type='item',name='plastic-bar',amount=2},{type='item',name='copper-cable',amount=4}}},
    ['low-density-structure']={name='low-density-structure',energy=15,ingredients={{type='item',name='plastic-bar',amount=5},{type='item',name='copper-plate',amount=20},{type='item',name='steel-plate',amount=2}}}}}
  local n=0
  local function asm(x,y,recipe,working)
    n=n+1
    return {valid=true,unit_number=n,name='assembling-machine-2',type='assembling-machine',position={x=x,y=y},crafting_speed=0.75,working=working,
      get_recipe=function() return prototypes.recipe[recipe] end}
  end
  local ac={asm(0,0,'advanced-circuit',true),asm(3,0,'advanced-circuit',true),asm(6,0,'advanced-circuit',true)}
  local lds={asm(0,20,'low-density-structure',false),asm(3,20,'low-density-structure',false)}
  local net={network_id=5,available_logistic_robots=12,all_logistic_robots=300,get_item_count=function(_,m) return 0 end}
  local function chest(u,x,y,filters,held,coming)
    return {valid=true,unit_number=u,type='logistic-container',name='requester-chest',position={x=x,y=y},prototype={logistic_mode='requester'},logistic_network=net,
      get_item_count=function(i) return i=='plastic-bar' and held or 0 end,
      get_logistic_point=function() return {filters=filters,targeted_items_deliver=coming and {{name='plastic-bar',count=coming}} or {}} end}
  end
  local A=chest(101,1.5,2.5,{{name='plastic-bar',count=200}},150,40)
  local B=chest(102,1.5,22.5,{{name='copper-plate',count=100},{name='steel-plate',count=20}},0)
  local C=chest(103,60.5,60.5,{{name='plastic-bar',count=100}},0)
  local D=chest(104,80.5,60.5,{{name='plastic-bar',count=50}},60)
  local inserters={}
  for _,m in ipairs(ac) do inserters[#inserters+1]={valid=true,type='inserter',position={x=m.position.x,y=1.5},drop_target=m,pickup_target=A} end
  for _,m in ipairs(lds) do inserters[#inserters+1]={valid=true,type='inserter',position={x=m.position.x,y=21.5},drop_target=m,pickup_target=B} end
  local function inside(e,ar) return e.position.x>=ar[1][1] and e.position.x<=ar[2][1] and e.position.y>=ar[1][2] and e.position.y<=ar[2][2] end
  local surface={name='nauvis',find_entities_filtered=function(f)
    local out={}
    if type(f.type)=='table' then for _,e in ipairs(ac) do out[#out+1]=e end; for _,e in ipairs(lds) do out[#out+1]=e end; return out end
    if f.type=='inserter' then for _,e in ipairs(inserters) do if inside(e,f.area) then out[#out+1]=e end end return out end
    if f.type=='logistic-container' then return {D,C,B,A} end
    return out
  end}
  local S=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return e.working and 'working' or 'item_ingredient_shortage' end,position=function(v) return v end,integer=function(v,d) return v or d end}
  local r=S.supply({surface=surface,force={}},{item='plastic-bar',requesters=true})
  eq(r.lines[1],'plastic-bar on nauvis: 3 requester or buffer chests ask for it; network #5: 0 free in providers and storage, 12 of 300 logistic robots idle, 3 chests asking')
  eq(r.lines[2],'requester-chest (1.5,2.5) #5: asks 200, holds 150; served now: robots bringing 40; feeds 3 assembling-machine-2 (advanced-circuit), 3 working, taking 45/min at full speed')
  eq(r.lines[3],'requester-chest (60.5,60.5) #5: asks 100, holds 0; unmet: none free in network #5; feeds none of the machines that use it')
  eq(r.lines[4],'requester-chest (80.5,60.5) #5: asks 50, holds 60; met; feeds none of the machines that use it')
  eq(r.lines[5],'requester-chest (1.5,22.5) feeds 2 assembling-machine-2 (low-density-structure), 0 working, taking 30/min at full speed, and asks for no plastic-bar (asks copper-plate 100, steel-plate 20)')
  eq(#r.lines,5)
  eq(r.requesters[1].coming,40); eq(r.requesters[1].use_per_min,45); eq(r.requesters[2].state,'unmet: none free in network #5')
  eq(r.unasked[1].asks,'copper-plate 100, steel-plate 20')
  fails(function() S.supply({surface=surface,force={}},{item='plastic-bar',requesters=1}) end,'requesters is true')
  defines,prototypes=nil,nil
end
print('d17_batch30 B2 who gets an item: ok')
