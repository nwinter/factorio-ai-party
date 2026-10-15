-- Run from repository root: lua tests/chronicle.lua
-- The chronicle (chronicle.lua; viewer Alex 22:24: the agents' own narrative history of the run; viewer syndesis 22:24:
-- each platform's creation and loss on the timeline, with where, what killed it and the cargo lost): an agent's entry
-- with its stamp and the events it is filed beside, the events the harness picks up, and the operator read.
-- Fake engine and bot as tests/round0320a.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={stone={}},entity={stone={name='stone',type='resource'},['iron-chest']={name='iron-chest',type='container'}}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end}
local neutral={name='neutral'}
local surface={name='nauvis',index=1}
local world={}
local function box_distance(pos,e)
  local b=e.bounding_box
  local dx=math.max(b.left_top.x-pos.x,0,pos.x-b.right_bottom.x)
  local dy=math.max(b.left_top.y-pos.y,0,pos.y-b.right_bottom.y)
  return (dx*dx+dy*dy)^0.5
end
local function dist(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
surface.find_non_colliding_position=function(_,pos) return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    local near=f.position and ((f.radius and f.radius>=1) and dist(e.position,f.position)<=f.radius
      or math.abs(e.position.x-f.position.x)<0.3 and math.abs(e.position.y-f.position.y)<0.3)
    if e.valid and near and (not f.name or f.name==e.name) and (not f.type or f.type==e.type) then out[#out+1]=e end
  end
  return out
end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=501,health=250,max_health=250,
    driving=false,build_distance=10,reach_distance=10,resource_reach_distance=2.7,character_running_speed=0.15,walking_state={walking=false},
    prototype={mining_speed=0.5,collision_mask={layers={player=true}}}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  c.can_insert=function() return true end
  c.can_reach_entity=function(e) return box_distance(c.position,e)<=2.7 end
  -- One unit a cycle, as the engine's mine_entity on a resource.
  c.mine_entity=function(e) e.amount=e.amount-1; if e.amount<=0 then e.valid=false end; return not e.valid end
  c.destroy=function() c.valid=false end
  return c
end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local players={nick}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then error(result,0) end
  return result
end
runtime.operator.bot_create('grok')
local function grok(action,args) return request{action=action,args=args or {},bot='grok'} end
local body=runtime.bots.lookup(runtime.bots.index_of('grok')).character
for k,v in pairs(character({x=0,y=0})) do if type(v)=='function' and k~='destroy' then body[k]=v end end
body.prototype={mining_speed=0.5,collision_mask={layers={player=true}}}
body.can_reach_entity=function(e) return box_distance(body.position,e)<=2.7 end
local function stone(x,y,amount)
  local e={valid=true,name='stone',type='resource',position={x=x,y=y},force=neutral,amount=amount,minable=true,
    bounding_box={left_top={x=x-0.4,y=y-0.4},right_bottom={x=x+0.4,y=y+0.4}},
    prototype={mineable_properties={mining_time=1,products={{type='item',name='stone',amount=1}}}}}
  world[#world+1]=e
  return e
end

local function op(action,args) return request{action=action,args=args or {},operator=true} end
local st=storage.agent_harness
defines.inventory.hub_main,defines.inventory.hub_trash=21,22
-- 1. An entry: stamped, its text cut at 600, a title; empty text refused; one an agent a game minute.
local r=grok('chronicle',{text='The furnaces lit at dawn. '..string.rep('x',700),title='First light'})
eq(r.seq,1); eq(r.where,'nauvis'); eq(r.linked,nil)
local e=st.chronicle.entries[1]
eq(e.agent,'grok'); eq(e.title,'First light'); eq(#e.text,600); eq(e.planet,'nauvis'); eq(e.game_time,'0h00m')
fails(function() grok('chronicle',{text='again'}) end,'one chronicle entry every 60 s of game time; next in')
fails(function() grok('chronicle',{text='   '}) end,'text is required')
fails(function() grok('chronicle',{text='x',bogus=1}) end,'unknown argument bogus')
-- 2. The events: research finished, a rocket, a platform stopped, from the lists the harness keeps (polled once a
-- second; what was there before the chronicle is not news).
-- (a platform the force has at the chronicle's first look: not news either)
local function platform(index,name,at)
  local surf={name='platform-'..index,index=10+index}
  local pl={valid=true,index=index,name=name,surface=surf,space_location=at and {name=at} or nil,state=1}
  surf.platform=pl
  return pl
end
local old=platform(1,'Old','nauvis')
force.platforms={old}
st.research_news={seq=4,list={{seq=4,tick=10,force='player',name='automation',unlocks={}}}}
st.silo_launches={[77]={tick=20,surface='nauvis',to='a platform',cargo='empty'}}
st.platform_events={seq=2,list={{seq=2,platform='Old',force='player',kind='arrived',at='nauvis',tick=30}}}
advance(60)
eq(#st.chronicle.events,0,'the backlog is not news')
table.insert(st.research_news.list,{seq=5,tick=game.tick,force='player',name='rocket-silo',queued_by='sol',unlocks={}}); st.research_news.seq=5
st.silo_launches[78]={tick=game.tick,surface='nauvis',to='platform Starling',cargo='120 iron-plate',by='grok'}
table.insert(st.platform_events.list,{seq=3,platform='Starling',force='player',kind='left',at='nauvis',to='vulcanus',tick=game.tick}); st.platform_events.seq=3
advance(60)
local kinds={}
for _,ev in ipairs(st.chronicle.events) do kinds[#kinds+1]=ev.kind end
eq(table.concat(kinds,','),'research,rocket,platform_left')
eq(st.chronicle.events[1].name,'rocket-silo'); eq(st.chronicle.events[2].to,'platform Starling')
-- 3. The next entry is filed beside the events of the last 15 min on its planet, newest first.
advance(3600)
r=grok('chronicle',{text='The silo is ours.'})
eq(#r.linked,3); assert(r.linked[1]:find('platform Starling left nauvis for vulcanus',1,true),r.linked[1])
assert(r.linked[3]:find('research finished: rocket-silo',1,true),r.linked[3])
eq(st.chronicle.entries[2].refs[1].kind,'platform_left')
-- 4. Platforms: the first look takes the list as it is; a new one is made (by platform_create's agent when it made it);
-- its hub's death is a loss with where it was, what killed it, the asteroids that hit it most and its hub's items.
eq(st.chronicle.events[#st.chronicle.events].kind,'platform_left','a platform there at the first look is not made')
local star=platform(2,'Starling','nauvis')
force.platforms={old,star}
runtime.chronicle.created_by(star,'luna')
advance(60)
local made=st.chronicle.events[#st.chronicle.events]
eq(made.kind,'platform_created'); eq(made.platform,'Starling'); eq(made.at,'nauvis'); eq(made.by,'luna')
st.platform_alerts={by={[2]={total={by={['medium-metallic-asteroid']=40,['small-metallic-asteroid']=12,['big-carbonic-asteroid']=3,['x']=1}}}}}
star.space_location=nil  -- flying to Vulcanus, 40% of the leg flown
star.space_connection={from={name='nauvis'},to={name='vulcanus'},length=15000}; star.distance=0.4
star.schedule={current=1,records={{station='vulcanus'}}}; star.last_visited_space_location={name='nauvis'}; star.speed=0.1
local inv={[21]={get_contents=function() return {{name='iron-plate',count=400},{name='rocket-fuel',count=20}} end},
           [22]={get_contents=function() return {{name='iron-plate',count=50}} end}}
local hub={valid=true,type='space-platform-hub',name='space-platform-hub',force=force,surface=star.surface,position={x=0,y=0},
  get_inventory=function(i) return inv[i] end}
local rock={valid=true,name='medium-metallic-asteroid',force={name='enemy'}}
runtime.on_event{name=defines.events.on_entity_died,tick=game.tick,entity=hub,cause=rock}
local lost=st.chronicle.events[#st.chronicle.events]
eq(lost.kind,'platform_lost'); eq(lost.platform,'Starling'); eq(lost.by,'medium-metallic-asteroid'); eq(lost.creator,'luna')
eq(lost.cargo[1].name,'iron-plate'); eq(lost.cargo[1].count,450); eq(lost.cargo_items,470); eq(lost.cargo_kinds,2)
eq(lost.hit_by[1].name,'medium-metallic-asteroid'); eq(lost.hit_by[1].count,40); eq(#lost.hit_by,3)
eq(lost.where,'flying nauvis->vulcanus 40%'); eq(lost.from,'nauvis'); eq(lost.to,'vulcanus'); eq(lost.flown,40)
force.platforms={old}
advance(60)
eq(st.chronicle.events[#st.chronicle.events].kind,'platform_lost','a lost platform is not deleted again')
force.platforms={}
advance(60)
local del=st.chronicle.events[#st.chronicle.events]
eq(del.kind,'platform_deleted'); eq(del.platform,'Old')
-- 5. An agent's death: who, where, by what.
local body=runtime.bots.lookup(runtime.bots.index_of('grok')).character
local biter={valid=true,name='small-biter',force={name='enemy'}}
runtime.on_event{name=defines.events.on_entity_died,tick=game.tick,entity=body,cause=biter}
local d=st.chronicle.events[#st.chronicle.events]
eq(d.kind,'death'); eq(d.agent,'grok'); eq(d.by,'small-biter'); eq(d.planet,'nauvis')
-- 6. The operator read: entries and events after their cursors, oldest first, each event with its line; describe lists it.
r=op('chronicle',{since=1})
eq(#r.entries,1); eq(r.entries[1].text,'The silo is ours.'); eq(r.cursor,2)
eq(r.events_cursor,#st.chronicle.events)
r=op('chronicle',{events_since=r.events_cursor-2})
eq(#r.events,2); eq(r.events[2].line,'grok died on nauvis (small-biter)')
local listed=false
for _,x in ipairs(grok('describe').operator_reads or {}) do listed=listed or x=='chronicle' end
eq(listed,true)
assert(grok('describe').actions.chronicle,'describe lists the action')
print('chronicle: ok')
