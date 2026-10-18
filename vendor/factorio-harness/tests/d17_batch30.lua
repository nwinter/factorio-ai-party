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
