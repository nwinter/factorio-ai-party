-- d19 batch49. Run from the harness root: lua tests/d19_batch49.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- 1 (viewer Foobator 19:39): a programmable speaker's sound settings (volume, playback mode, polyphony, instrument,
-- note) in speaker_alert's view and configure's speaker_alert.speaker_sound.
do
  prototypes={item={['rocket-part']={}},fluid={water={}},virtual_signal={['signal-A']={}},quality={normal={}}}
  defines={wire_connector_id={}}
  local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
  -- as Sol's two alarm speakers on Aquilo read at 19:39 (Factorio 2.0.77)
  local cb={circuit_condition={first_signal={type='item',name='rocket-part'},comparator='<',constant=1,fulfilled=false},
    circuit_parameters={instrument_id=0,note_id=0,signal_value_is_pitch=false,stop_playing_sounds=false}}
  local sp={valid=true,type='programmable-speaker',name='programmable-speaker',position={x=29.5,y=31.5},
    alert_parameters={show_alert=true,show_on_map=true,alert_message='alarm'},
    parameters={allow_polyphony=false,playback_mode='local',playback_volume=1,volume_controlled_by_signal=false},
    prototype={instruments={{name='alarms',notes={'alarm-1','alarm-2','buzzer-1','buzzer-2','buzzer-3','ring','siren'}},
      {name='miscellaneous',notes={'achievement-unlocked','alert-destroyed'}}}},
    get_control_behavior=function() return cb end,get_or_create_control_behavior=function() return cb end}
  local v=C.speaker_alert(sp)
  eq(v.speaker_sound.line,'sound: alarms/alarm-1 at volume 100%, local')
  eq(v.line,'alert on (on the map): "alarm"; circuit condition rocket-part < 1 (does not hold now); sound: alarms/alarm-1 at volume 100%, local')
  eq(v.speaker_sound.volume,1); eq(v.speaker_sound.mode,'local'); eq(v.speaker_sound.polyphony,false)
  eq(v.speaker_sound.instrument,'alarms'); eq(v.speaker_sound.note,'alarm-1')
  -- set: names or numbers from 0; the rest kept, alert settings too
  local after,before=C.set_speaker_alert(sp,{speaker_sound={volume=0.5,mode='surface',polyphony=true,note='siren'}})
  eq(before.speaker_sound.line,'sound: alarms/alarm-1 at volume 100%, local')
  eq(after.speaker_sound.line,'sound: alarms/siren at volume 50%, surface, polyphony on')
  eq(sp.parameters.playback_volume,0.5); eq(sp.parameters.playback_mode,'surface'); eq(sp.parameters.allow_polyphony,true)
  eq(cb.circuit_parameters.note_id,6); eq(cb.circuit_parameters.instrument_id,0)
  eq(sp.alert_parameters.alert_message,'alarm'); eq(sp.alert_parameters.show_alert,true)
  -- another instrument: its first note unless one is named; the same instrument keeps the note
  after=C.set_speaker_alert(sp,{speaker_sound={instrument='alarms'}})
  eq(cb.circuit_parameters.note_id,6)
  after=C.set_speaker_alert(sp,{speaker_sound={instrument=1}})
  eq(cb.circuit_parameters.instrument_id,1); eq(cb.circuit_parameters.note_id,0)
  eq(after.speaker_sound.line,'sound: miscellaneous/achievement-unlocked at volume 50%, surface, polyphony on')
  after=C.set_speaker_alert(sp,{speaker_sound={instrument='alarms',note=2,mode='global',polyphony=false}})
  eq(after.speaker_sound.line,'sound: alarms/buzzer-1 at volume 50%, global')
  after=C.set_speaker_alert(sp,{speaker_sound={volume=0}})
  eq(after.speaker_sound.line,'sound: off (volume 0)'); has(after.line,'; sound: off (volume 0)')
  -- refusals change nothing
  fails(function() C.set_speaker_alert(sp,{show_alert=false,speaker_sound={volume=2}}) end,'volume is a number from 0 to 1')
  eq(sp.alert_parameters.show_alert,true)
  fails(function() C.set_speaker_alert(sp,{speaker_sound={mode='loud'}}) end,'local, surface or global, not loud')
  fails(function() C.set_speaker_alert(sp,{speaker_sound={polyphony='yes'}}) end,'polyphony must be true or false')
  fails(function() C.set_speaker_alert(sp,{speaker_sound={note='bell'}}) end,'note (of alarms): bell is none of this speaker\'s; it has alarm-1, alarm-2, buzzer-1')
  fails(function() C.set_speaker_alert(sp,{speaker_sound={instrument='drums'}}) end,'it has alarms, miscellaneous')
  fails(function() C.set_speaker_alert(sp,{speaker_sound={pitch=3}}) end,'speaker_sound takes volume, mode')
  fails(function() C.set_speaker_alert(sp,{speaker_sound='loud'}) end,'speaker_sound is {volume?')
  eq(sp.parameters.playback_mode,'global'); eq(sp.parameters.playback_volume,0)
  -- a volume or note from a signal, as its GUI shows them
  sp.parameters.volume_controlled_by_signal=true; sp.parameters.volume_signal_id={type='virtual',name='signal-A'}
  cb.circuit_parameters.signal_value_is_pitch=true
  has(C.speaker_alert(sp).speaker_sound.line,'at volume from signal signal-A, global, the note from the signal value')
  -- a speaker read with no sound settings (a mock without parameters) keeps the earlier line
  sp.parameters=nil
  eq(C.speaker_alert(sp).line,'alert on (on the map): "alarm"; circuit condition rocket-part < 1 (does not hold now)')
  prototypes,defines=nil,nil
end
print('d19_batch49 1 speaker sound: ok')
