-- Run from repository root: lua tests/d24_batch136.lua
-- d24 batch136 PH1 (Sol #2104: the native quota decider at (51.5,48) on nauvis is on red network 1258 with 242
-- signals; inspect listed 30 and circuit_audit 24, so signal-R could not be read, nor its absence told from the cut):
-- signals names signals, and each one's count on every network comes back (the game's get_signal, 0 when absent),
-- whatever the cap, by wire colour and side in inspect; the lists and their counts are unchanged.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={wire_type={red=1,green=2,copper=3},
  wire_connector_id={circuit_red=1,circuit_green=2,combinator_input_red=1,combinator_input_green=2,combinator_output_red=3,combinator_output_green=4,
    power_switch_left_copper=5,power_switch_right_copper=6},wire_origin={player=0}}
local items={['iron-plate']=true,calcite=true,['copper-plate']=true}
for k=1,240 do items['filler-'..k]=true end
prototypes={item=items,fluid={water=true},virtual_signal={['signal-R']=true,['signal-A']=true},recipe={},entity={},
  quality={normal={level=0},rare={level=2}}}
-- a network: its signals ({signal, count}, the game's list) and get_signal by {type, name, quality}
local function net(id,list)
  return {network_id=id,signals=list,connected_circuit_count=3,
    get_signal=function(sig)
      assert(type(sig)=='table' and sig.name,'get_signal takes a SignalID')
      for _,s in ipairs(list) do
        if s.signal.name==sig.name and (s.signal.type or 'item')==(sig.type or 'item') and (s.signal.quality or 'normal')==(sig.quality or 'normal') then return s.count end
      end
      return 0
    end}
end
-- red 1258 on the decider's input: 242 signals, signal-R 3 among the smallest, calcite at rare quality only
local red={}
for k=1,240 do red[#red+1]={signal={name='filler-'..k},count=1000+k} end
red[#red+1]={signal={type='virtual',name='signal-R'},count=3}
red[#red+1]={signal={name='calcite',quality='rare'},count=7}
local nets={[1]=net(1258,red),[2]=net(77,{{signal={name='iron-plate'},count=5}}),[3]=net(901,{{signal={type='virtual',name='signal-A'},count=1}})}
local other={name='constant-combinator',type='constant-combinator',position={x=50.5,y=48}}
local function conn(id,wt) return {wire_type=wt,connections={{target={owner=other,wire_connector_id=id}}}} end
local decider={valid=true,name='decider-combinator',type='decider-combinator',position={x=51.5,y=48},unit_number=9,
  get_wire_connectors=function() return {[1]=conn(1,1),[2]=conn(2,2),[3]=conn(3,1)} end,
  get_circuit_network=function(id) return nets[id] end,get_control_behavior=function() return nil end}
local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}

-- parsing: names as conditions take them, a list or one string, 1..32, deduplicated
local picks=C.parse_signals('signal-R, calcite|calcite@rare,iron-plate')
eq(#picks,4); eq(picks[1].text,'signal-R'); eq(picks[1].id.type,'virtual'); eq(picks[3].text,'calcite@rare'); eq(picks[3].id.quality,'rare')
eq(#C.parse_signals({'signal-R','signal-R',{type='fluid',name='water'}}),2)
fails(function() C.parse_signals({}) end,'signals: 1..32 signal names')
local many={} for k=1,33 do many[k]='filler-'..k end
fails(function() C.parse_signals(many) end,'signals: 1..32 signal names')
fails(function() C.parse_signals({'signal-Q'}) end,'signals[1]: unknown signal signal-Q')
fails(function() C.parse_signals({'calcite@shiny'}) end,'unknown quality shiny')

-- inspect's circuit block: the list stays cut at 30 with more; picked has every network by colour and side
local r=C.read(decider,nil,picks)
local ri=r.networks.red_input
eq(ri.id,1258); eq(#ri.signals,30); eq(ri.more,212)
for _,s in ipairs(ri.signals) do assert(s.name~='signal-R','signal-R is past the cut') end
eq(ri.picked[1].name,'signal-R'); eq(ri.picked[1].count,3)
eq(ri.picked[2].name,'calcite'); eq(ri.picked[2].count,0)  -- normal calcite: absent
eq(ri.picked[3].name,'calcite@rare'); eq(ri.picked[3].count,7)
eq(r.networks.green_input.picked[4].count,5); eq(r.networks.red_output.picked[1].count,0)
eq(r.signals_picked,'green_input #77: signal-R 0, calcite 0, calcite@rare 0, iron-plate 5; red_input #1258: signal-R 3, calcite 0, calcite@rare 7, iron-plate 0; red_output #901: signal-R 0, calcite 0, calcite@rare 0, iron-plate 0')
-- without signals: no picked, nothing else changes
local plain=C.read(decider)
eq(plain.networks.red_input.picked,nil); eq(plain.signals_picked,nil); eq(#plain.networks.red_input.signals,30); eq(plain.networks.red_input.more,212)

-- circuit_audit with area: each network row adds picked and the line says named:, the 24 listed and the total unchanged
local s={find_entities_filtered=function() return {decider} end}
local A=dofile('mod/agent-harness_0.1.0/circaudit.lua'){
  platform=function() error('no platform') end,
  parse_signals=function(v) return C.parse_signals(v,'signals') end,picked_counts=C.picked_counts,picked_text=C.picked_text}
local p={surface=s,force='player'}
local a=A.read(p,{area={{40,40},{60,60}},signals={'signal-R','calcite@rare'}})
local row
for _,n in ipairs(a.networks) do if n.id==1258 then row=n end end
eq(#row.signals,24); eq(row.signals_total,242); eq(row.picked[1].count,3); eq(row.picked[2].count,7)
local line
for _,l in ipairs(a.lines) do if l:find('#1258',1,true) then line=l end end
has(line,'red #1258: signals filler-240 1240'); has(line,'(+218 more); named: signal-R 3, calcite@rare 7; of these, 1 on it')
a=A.read(p,{area={{40,40},{60,60}}})
for _,n in ipairs(a.networks) do eq(n.picked,nil) end
fails(function() A.read(p,{platform='X',signals={'signal-R'}}) end,'signals goes with area or positions')
defines=nil; prototypes=nil
print('d24 batch136: ok (signals named read on every network past the caps, 0 when absent; lists and counts unchanged)')
