package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local function pos(p) return {x=p.x or p[1],y=p.y or p[2]} end
local function fails(fn,s) local ok,e=pcall(fn);assert(not ok);has(tostring(e),s) end
local state,shown,entities,reads={},true,{},0
game={tick=100}
defines={entity_status={working=0,no_power=1,low_power=2,no_fuel=3,no_minable_resources=9},inventory={},alert_type={}}
local force={name='player',players={},is_chunk_visible=function() return shown end}
local surface={name='nauvis',index=1}
game.surfaces={nauvis=surface};game.forces={player=force}
local p={force=force,surface=surface,position={x=200,y=200}}
surface.find_entities_filtered=function(f)
  assert(shown,'hidden entity query');reads=reads+1
  local out={};for _,e in ipairs(entities) do if e.valid then out[#out+1]=e end end;return out
end
local B=require('beltgaps'){state=function() return state end,position=pos}
local function belt(x,n)
  local e={valid=true,name='transport-belt',type='transport-belt',force=force,surface=surface,position={x=x+.5,y=.5},direction=4,status=0,
    unit_number=x+1,last_user={name='opus'},bounding_box={left_top={x=x+.1,y=.1},right_bottom={x=x+.9,y=.9}}}
  e.get_item_count=function() assert(shown,'hidden contents');return n end
  entities[#entities+1]=e;return e
end
local b0,b1,b2=belt(0,2),belt(1,1),belt(2,0)
B.read(p,{from={0,0},to={2,0}});eq(#B.alert_groups(force),0)
-- Empty samples preserve that the route carried items. An empty never-used belt is not a cut.
b0.get_item_count=function() return 0 end
game.tick=200;B.read(p,{from={0,0},to={2,0}})
b0.valid=false;b2.valid=false
game.tick=300;B.read(p,{from={0,0},to={2,0}})
local groups=B.alert_groups(force);eq(#groups,1);eq(groups[1].n,1);eq(groups[1].at[1].x,.5);eq(groups[1].by.opus,1)
has(groups[1].line,'carried items at tick 100');has(groups[1].line,'missing at tick 300')
shown=false;local before=reads;game.tick=400
B.read(p,{from={0,0},to={2,0}});eq(reads,before);eq(#B.alert_groups(force),1)
shown=true;b0.valid=true;B.observe(b0);eq(#B.alert_groups(force),0,'observed rebuild clears immediately')
-- Local sightings, without radar, seed remembered layout; hidden trace reads no engine data.
shown=true;B.read(p,{from={0,0},to={2,0}});shown=false
local r=B.trace(p,{position={x=.5,y=.5}});eq(#r.layout,2);eq(r.current,false);eq(reads,before+1)
-- Cached inspect is independent of the source object and every returned copy.
local R=require('readmemory'){state=function() return state end,position=pos,visible=function() return shown end,status_name=function() return 'working' end,
  belt_trace=B.trace,belt_observe=B.observe}
shown=true
local value={name='iron-chest',position={x=20.5,y=.5},inventories={chest={{name='coal',count=10}}},in_reach=true}
local live_calls=0
local function live() live_calls=live_calls+1;return value end
R.read(p,{position=value.position},'inspect',live)
value.inventories.chest[1].count=99;shown=false;game.tick=460
r=R.read(p,{position=value.position},'inspect',live)
eq(r.by,'last seen memory');eq(r.current,false);eq(r.age_ticks,60);eq(r.in_reach,nil);eq(r.inventories.chest[1].count,10);eq(live_calls,1)
r.inventories.chest[1].count=0
eq(R.read(p,{position=value.position},'inspect',live).inventories.chest[1].count,10)
fails(function() R.read(p,{position={90,90}},'inspect',live) end,'no recorded inspect observation')
fails(function() R.read(p,{position=value.position,name='wooden-chest'},'inspect',live) end,'no recorded inspect observation')
local other={force={name='other'},surface=surface}
fails(function() R.read(other,{position=value.position},'inspect',live) end,'no recorded inspect observation')
-- Merely seeing a belt is enough for a later remembered trace.
r=R.read(p,{position={.5,.5}},'trace',live);eq(#r.layout,2);eq(live_calls,1)
-- Refreshing a live entity supersedes old contents; unknown future state stays unknown.
shown=true;R.read(p,{position=value.position},'inspect',live);shown=false
eq(R.read(p,{position=value.position},'inspect',live).inventories.chest[1].count,99)
-- Status warnings clear without waiting for the background census; fog retains dated observations.
local machine={valid=true,name='assembling-machine-1',type='assembling-machine',status=1,unit_number=20,position={x=10,y=10},surface=surface,force=force}
entities={machine};shown=true;game.tick=500
local A=require('pushalerts'){state=function() return state end,agents=function() return {} end,who=function() return 'opus' end}
local alert=A.read(p,{kind='unconnected'});eq(#alert.groups,1)
machine.status=0;machine.electric_network_id=1
alert=A.read(p,{kind='unconnected'});eq(#alert.groups,0)
machine.status=1;machine.electric_network_id=nil
eq(#A.read(p,{kind='unconnected'}).groups,1)
shown=false;machine.status=0
alert=A.read(p,{kind='unconnected'});eq(#alert.groups,1);eq(alert.groups[1].stale,true);has(alert.groups[1].line,'last observed tick 500')
shown=true;machine.valid=false;eq(#A.read(p,{kind='unconnected'}).groups,0)
-- At most 2048 plain entity observations; none retains LuaEntity references.
for i=1,2050 do shown=true;R.read(p,{position={x=i,y=90}},'inspect',function() return {name='iron-chest',position={x=i,y=90}} end) end
local n=0;for _ in pairs(state.read_memory.read_entries) do n=n+1 end;eq(n,256)
for i=1,2050 do R.observe{valid=true,name='iron-chest',type='container',position={x=i,y=91},force=force,surface=surface} end
n=0;for _ in pairs(state.read_memory.entries) do n=n+1 end;eq(n,2048)
shown=false
r=R.read(p,{position={x=2050,y=90}},'inspect',live);eq(r.by,'last seen memory')
shown=true
-- Area predicates validate the box and bound the entity selection.
local C=require('conditions'){position=pos,known=function() return true end}
local area={left_top={x=-128,y=-128},right_bottom={x=128,y=128}}
C.validate{['until']='fuel_below',area=area,count=10}
local filter
surface.find_entities_filtered=function(f) filter=f;return {{valid=true,burner={},position={x=100,y=0},name='stone-furnace',get_fuel_inventory=function() return {get_item_count=function() return 0 end} end}} end
local met=C.check(p,{['until']='fuel_below',area=area,count=10});eq(met,true);eq(filter.area,area);eq(filter.radius,nil);eq(filter.limit,1025)
fails(function() C.validate{['until']='fuel_below',area=area,radius=32,count=10} end,'excludes position and radius')
fails(function() C.validate{['until']='fuel_below',area={{0,0},{257,2}},count=10} end,'at most 256x256')
surface.find_entities_filtered=function() local list={};for i=1,1025 do list[i]={} end;return list end
fails(function() C.check(p,{['until']='ammo_below',radius=256,count=10}) end,'exceeds 1024 entities')
-- The background pass evaluates one drill group per step, not per drill or reply.
local bg={push_drills={player={[1]='coal',[2]='coal'}}};local lookups=0
local drills={}
for i=1,2 do drills[i]={valid=true,type='mining-drill',name='electric-mining-drill',unit_number=i,position={x=i*4,y=0},status=9} end
surface.find_entities_filtered=function() return drills end;force.players={{}}
local A2=require('pushalerts'){state=function() return bg end,agents=function() return {} end,who=function() return 'opus' end,
  drill_site=function(f,g) lookups=lookups+1;eq(g.n,2);eq(g.ore,'coal');return {tick=game.tick,drill=g.drill.name,origin=g.drill.position,radius=24,site={position={x=20.5,y=.5},distance=16.5,amount=100}} end}
A2.tick(game.tick)
table.remove(bg.push_jobs.player.stages) -- a scan already running before this deployment
for _=1,200 do game.tick=game.tick+1;A2.tick(game.tick);if not bg.push_jobs.player then break end end
eq(lookups,1);local result=A2.read(p,{kind='out_of_ore'});eq(#result.groups,1);eq(result.groups[1].drill_site.site.amount,100)
has(result.groups[1].line,'nearest checked coal site with room');A2.read(p,{kind='out_of_ore'});eq(lookups,1)
-- Dense chunk work is sliced; fog cancels a partial refresh without reading it.
local dense_state,items_read={},0
local DB=require('beltgaps'){state=function() return dense_state end,position=pos}
entities={};shown=true
for x=0,15 do for y=0,15 do
  local e=belt(x,1);e.position.y=y+.5;e.bounding_box.left_top.y=y+.1;e.bounding_box.right_bottom.y=y+.9
  e.get_item_count=function() assert(shown,'hidden pending entity');items_read=items_read+1;return 1 end
end end
surface.find_entities_filtered=function() assert(shown,'hidden dense query');return entities end
local arg={from={0,0},to={15,0}}
local partial=DB.read(p,arg);eq(items_read,128);eq(partial.observations[1].pending.total,256);eq(partial.belts,0)
shown=false;DB.read(p,arg);eq(items_read,128);eq(dense_state.belt_memory.chunks['player|nauvis|0,0'].pending,nil)
shown=true;DB.read(p,arg);eq(items_read,256)
local full=DB.read(p,arg);eq(items_read,384);eq(full.belts,16);eq(full.observations[1].pending,nil)
-- A ghost sighting after an item-carrying belt is a gap, not a lost history.
local ghost={valid=true,type='entity-ghost',ghost_type='transport-belt',ghost_name='transport-belt',name='entity-ghost',force=force,surface=surface,
  position={x=.5,y=.5},direction=4,bounding_box={left_top={x=.1,y=.1},right_bottom={x=.9,y=.9}}}
DB.observe(ghost);eq(DB.alert_groups(force)[1].n,1)
DB.read(p,arg);game.surfaces={}
DB.tick(15);eq(dense_state.belt_memory.chunks['player|nauvis|0,0'].pending,nil,'deleted surface releases pending refresh')
game.surfaces={nauvis=surface}
print('d15_0450a: ok')
