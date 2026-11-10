package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
script={active_mods={base='2.1.24'}}
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
defines={inventory={hub_main=1,hub_trash=2},logistic_member_index={rocket_silo_requester=1,space_platform_hub_requester=2},
 space_platform_state={waiting_at_station=6,no_schedule=4},entity_status={working=1}}
prototypes={item={iron={weight=1000,stack_size=100}},quality={normal={level=0}},utility_constants={default_rocket_lift_weight=1000000}}
local filter={value={name='iron',quality='normal',comparator='='},min=10}
local sec={active=true,multiplier=1,filters={filter}}
local secs={sections_count=1,get_section=function() return sec end}
local hub={valid=true,get_logistic_sections=function() return secs end,get_item_count=function() return 0 end,
 get_inventory=function() return {count_empty_stacks=function() return 20 end} end}
local pl={valid=true,index=1,name='ship',space_location={name='nauvis'},hub=hub}
local net={network_id=1,get_item_count=function() return 20 end}
local force={platforms={pl},logistic_networks={nauvis={net}}}
local silo={force=force,prototype={lift_weight=1000000},position={x=0,y=0},surface={name='nauvis',planet={name='nauvis'}}}
game={tick=2000,planets={nauvis={surface={}}}}
local S=dofile('mod/agent-harness_0.1.0/silo.lua'){}
local native=S.auto_filters({sections={sec}});eq(native[1].name,'iron');eq(native[1].count,10)
local raw={{name='iron',quality='normal',count=180},{name='copper',quality='normal',count=180}}
eq(S.auto_filters({filters=raw}),raw)
local rows=S.request_rows(silo,force,net);eq(#rows,1);eq(rows[1].flag,'native_batch');eq(rows[1].payload,nil)
has(rows[1].line,'full rocket of this item is not required')
filter.request_from='platforms';eq(#S.request_rows(silo,force,net),0);filter.request_from='planet'
-- Native gates wait for trash even when the harness fluid/time conditions hold.
local state={};local trash={{name='iron',count=1}};local goes=0
local W=dofile('mod/agent-harness_0.1.0/platwait.lua'){state=function() return state end}
hub.get_inventory=function() return {get_contents=function() return trash end} end
pl.state=6;pl.paused=false;pl.schedule={records={{station='nauvis',wait_conditions={{type='circuit',condition=W.NEVER}}},{station='vulcanus'}}}
local sch={current=1,get_record_count=function() return 2 end,go_to_station=function() goes=goes+1 end,tick_of_last_activity=0}
pl.get_schedule=function() return sch end
game.forces={player=force};W.set(pl,{[1]={station='nauvis',conds={{kind='time',ticks=0}}}})
W.tick(60);eq(goes,0);has(W.line('ship'),'orbital trash')
trash={};W.tick(120);eq(goes,1)
-- In-flight deliveries reset inactivity even if the latest activity tick has not advanced yet.
local incoming={{name='iron',count=10}}
hub.get_logistic_point=function() return {targeted_items_deliver=incoming} end
pl.schedule.current=1;pl.schedule.records[1].wait_conditions={{type='inactivity',ticks=600}}
local SP=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {platform_stops={[1]={at='nauvis',tick=1}}} end,platwait=function() return W end}
local wait=SP.waiting_now(pl);eq(wait.met,false);has(wait.line,'deliveries in flight reset inactivity')
incoming={};eq(SP.waiting_now(pl).met,true)
-- Preserve, but never reuse, pre-port empirical histories. Repeated reads keep new data intact.
local oldfreight={[1]={segs={{kind='leg',start=1,['end']=100}},phase={moving={s=100,by={}}}}}
local oldengine={[1]={samples={{tick=1},{tick=100}}}}
local oldlegs={[1]={completed={{id=1}}}}
local st={freight=oldfreight,engine=oldengine,production_legs=oldlegs}
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
eq(#F.segments(pl),0);eq(st.freight_history['2.0-unversioned'],oldfreight);eq(st.port21_started_tick,2000)
st.freight[1]={segs={{engine_version='2.1.24'}}};eq(#F.segments(pl),1)
local E=dofile('mod/agent-harness_0.1.0/engine.lua'){state=function() return st end}
eq(E.read(pl),nil);eq(st.engine_history['2.0-unversioned'],oldengine)
local P=dofile('mod/agent-harness_0.1.0/productionlegs.lua'){state=function() return st end}
eq(#P.read(pl,1).legs,0);eq(st.production_legs_history['2.0-unversioned'],oldlegs)
local EN=dofile('mod/agent-harness_0.1.0/endurance.lua'){state=function() return st end}
local fo=EN.fuel_outlook(pl);eq(fo.rate_unknown,true);eq(#fo.rows,0);has(fo.line,'less than one minute')
local T=dofile('mod/agent-harness_0.1.0/thrust.lua'){};has(T.RULE,'Measured on 2.1.24');assert(not T.RULE:find('170 t',1,true))
local R=dofile('mod/agent-harness_0.1.0/routeammo.lua'){}
eq(R.EXTRA,0);eq(R.ON_PATH[1],.9);has(R.CALIBRATION,'2.1.24');has(R.CALIBRATION,'unmeasured')
script.active_mods.base='2.0.77';R=dofile('mod/agent-harness_0.1.0/routeammo.lua'){};eq(R.EXTRA,20);eq(R.ON_PATH[1],1.19)
S=dofile('mod/agent-harness_0.1.0/silo.lua'){};filter.import_from='nauvis';rows=S.request_rows(silo,force,net);eq(rows[1].payload,1000);eq(rows[1].flag,'below_min_payload')
print('port21 space rules: native mixed batches, source eligibility, trash departure, inactivity deliveries, preserved/versioned histories and calibrated native/legacy models passed')
