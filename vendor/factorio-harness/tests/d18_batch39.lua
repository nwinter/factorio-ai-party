-- d18 batch39. Run from the harness root: lua tests/d18_batch39.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- B1 (Astra 138h31: silo read ready and not launched, last launch 3 min ago, while shipment showed 1000 cryo launched 32 s
-- before; the journal: the silo read came 14 s before that launch). Both lines name the launch by its ledger id and tick,
-- and the silo line says the tick it was read.
do
  defines={rocket_silo_status={building_rocket=0,rocket_ready=7},inventory={cargo_unit=1},cargo_destination={invalid=0,orbit=1,station=2,surface=3,space_platform=4}}
  game={tick=1000}
  local st={}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return st end}
  local L=dofile('mod/agent-harness_0.1.0/ledger.lua'){state=function() return st end}
  local surface={name='aquilo'}
  local silo={valid=true,unit_number=77,name='rocket-silo',surface=surface,position={x=17.5,y=-13.5},rocket_silo_status=7,rocket_parts=0,
    prototype={rocket_parts_required=50}}
  local pod={get_inventory=function() return {get_contents=function() return {{name='cryogenic-science-pack',count=1000}} end} end,cargo_pod_destination={type=1}}
  local event={rocket_silo=silo,rocket={attached_cargo_pod=pod}}
  local id=L.on_launch(event)
  eq(id,1)
  event.harness_up=id
  game.tick=1600
  S.on_launch_ordered(event)
  game.tick=3520
  local r=S.rocket(silo)
  has(r.last,'last launch 32s ago (up #1, tick 1600)')
  eq(r.last_launch.up,1); eq(r.read_tick,3520)
  defines,game=nil,nil
end
print('d18_batch39 B1 silo and shipment name the same launch: ok')

-- B2 (Grok: the nutrient chamber at (7.5,24.5) at energy 0 with spoilage in its slots, status busy, the egg loop stalled):
-- a burner with nothing burning and only unusable fuel reads fuel_unusable; a stopped burner crafter is told once to its
-- builder (the burner alert), and again only after it ran.
do
  local B=dofile('mod/agent-harness_0.1.0/burnt.lua'){}
  local function stack(name,count,cat) return {valid_for_read=true,name=name,count=count,quality={name='normal'},prototype={fuel_category=cat,stack_size=200}} end
  local fuel={stack('spoilage',40,'chemical')}; fuel.is_empty=function() return #fuel==0 end
  local burnt={{valid_for_read=false}}
  local ch={name='biochamber',position={x=7.5,y=24.5},unit_number=55,valid=true,
    burner={remaining_burning_fuel=0,inventory=fuel,burnt_result_inventory=burnt,fuel_categories={nutrients=true}},
    prototype={burner_prototype={}},last_user={name='grok'},get_recipe=function() return {name='nutrients-from-bioflux'} end}
  local f=B.stuck(ch)
  assert(f and f.unusable,'unusable fuel')
  has(B.line(ch,f,'working'),'its fuel slot holds spoilage*40, which it does not burn (it burns nutrients): nothing burns, it has no energy (the game\'s status reads working)')
  -- nutrients there: it burns them, not stuck
  fuel[2]=stack('nutrients',5,'nutrients')
  eq(B.stuck(ch),nil); fuel[2]=nil
  -- the alert, once
  game={tick=600}
  local st,told={},{}
  local S=dofile('mod/agent-harness_0.1.0/seeds.lua'){state=function() return st end,crafters=function() return {ch} end,
    burnt_stuck=function(e) return B.stuck(e) end,burnt_line=function(e,x) return B.line(e,x) end,
    deliver=function(i,t) told[#told+1]=t.text end,index_of=function(n) return n=='grok' and 3 or nil end}
  local force,surface={name='player'},{name='gleba'}
  eq(S.burnt_check(force,surface),1)
  has(told[1],'burner alert: biochamber (7.5,24.5) on gleba making nutrients-from-bioflux stopped: its fuel slot holds spoilage*40')
  eq(S.burnt_check(force,surface),0,'told once')
  fuel[2]=stack('nutrients',5,'nutrients'); S.burnt_check(force,surface); fuel[2]=nil
  eq(S.burnt_check(force,surface),1,'again after it ran')
  game=nil
end
print('d18_batch39 B2 a burner stopped by its own spoilage: ok')
