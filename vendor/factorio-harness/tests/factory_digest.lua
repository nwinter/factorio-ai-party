package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function no_scan() error('digest must not query world entities or tiles') end
local surfaces={[1]={index=1,name='nauvis',find_entities_filtered=no_scan,find_tiles_filtered=no_scan},
  [2]={index=2,name='gleba'},[3]={index=3,name='platform-1',platform={}}}
local force={name='player'}
game={tick=6000,forces={player=force},get_surface=function(i) return surfaces[i] end}
local st={survey_cache={['player/1']={tick=5999,digest={tick=3000,machines={lab={type='lab',total=2,counts={no_power=2}}},fuel={},belts={ends=1}}},
  ['enemy/2']={tick=6000,digest={machines={}}},['player/2']={tick=4000},['player/3']={tick=6000,digest={machines={}}}}}
local D=require('factory_digest'){state=function() return st end,use_lines=function(f)
  eq(f,force);return {'Agent equipment: armor researched: power-armor-mk2; worn: modular-armor x6',
    'Building tiers: nauvis stone-furnace 140, steel-furnace 60, electric-furnace 0'} end}
D.end_seen(force,surfaces[1],{x=1.5,y=2},{left_empty=true,right_full=true})
D.end_seen(force,surfaces[1],{x=1.5,y=2},{left_empty=true,right_full=false})
local out=D.operator.factory_digest{}
eq(#out.research_use,2);assert(out.research_use[1]:find('power-armor-mk2',1,true))
eq(#out.surfaces,2);eq(out.surfaces[1].surface,'gleba');assert(out.surfaces[1].survey_unknown)
eq(out.surfaces[2].survey_age_s,50,'cache retry tick does not falsify sample age')
eq(out.surfaces[2].machines.lab.counts.no_power,2)
eq(#out.surfaces[2].ends,1);eq(out.surfaces[2].ends[1].lanes.right_full,false)
for n=1,140 do game.tick=game.tick+1;D.end_seen(force,surfaces[1],{x=n,y=4},{left_empty=true}) end
out=D.operator.factory_digest{};eq(#out.surfaces[2].ends,128)
game.tick=game.tick+18001;out=D.operator.factory_digest{};eq(#out.surfaces[2].ends,0);eq(out.old_end_observations,128)
st.survey_cache={};out=D.operator.factory_digest{};eq(#out.surfaces,0)
print('factory_digest: ok')
