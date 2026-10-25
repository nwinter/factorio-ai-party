-- Run from repository root: lua tests/queuetimed.lua
-- Every action whose handler can start a timed action, and the kinds of active action it starts: as a queue step it
-- waits for that action's end (Sol 22:45: a clear_cliffs step began and ended in tick 10668307 though its until_tick was
-- 10675507, and the next step, a move_to, stopped the throw). A read of the mod's sources finds every kind of timed
-- action built (a {kind=...} table with an until_tick); each must be one a listed action starts, so a new timed action
-- that the scheduler does not know fails here.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,text) assert(type(s)=='string' and s:find(text,1,true),'missing "'..text..'" in: '..tostring(s)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')

-- action -> the kinds of active action its handler starts.
local TIMED={
  walk={'walk'},move_to={'move_to'},build_path={'build_path'},construct={'construct'},kite={'kite'},spider_kite={'spider_kite'},mine={'mine'},
  pickup={'pickup'},repair={'repair'},wait_until={'wait_until'},wait_ticks={'wait_ticks'},
  rearm={'feed','gather'},refuel={'feed','gather'},transfer={'feed','gather'},collect={'gather'},feed={'gather'},
  build={'feed'},load_silo={'feed','gather'},recover={'gather'},
  clear_cliffs={'clear_cliffs'},use_item={'clear_cliffs'},vehicle={'drive'},
}
-- Kinds the scheduler reads apart: shoot (the combat channel) and drop (drop jobs).
local APART={shoot=true,drop=true}
local known={}
for action,kinds in pairs(TIMED) do
  for _,kind in ipairs(kinds) do
    assert(runtime.queue_waits(action,kind),'the scheduler does not wait for '..action..' ('..kind..')')
    known[kind]=true
  end
end
-- And waits for nothing else: a step whose handler started no timed action (a grenade thrown) is done at once.
assert(not runtime.queue_waits('use_item','walk'))
assert(not runtime.queue_waits('craft','craft'))
assert(not runtime.queue_waits('place_ghosts','place_ghosts'))
-- Every kind of timed action the sources build is one a listed action starts.
local files={}
local p=io.popen('ls mod/agent-harness_0.1.0/*.lua')
for f in p:lines() do files[#files+1]=f end
p:close()
assert(#files>20,'the mod sources: '..#files)
local found={}
for _,f in ipairs(files) do
  local lines={}
  for line in io.lines(f) do lines[#lines+1]=line end
  for i,line in ipairs(lines) do
    for kind in line:gmatch("{%s*kind%s*=%s*'([%w_]+)'") do
      -- (its until_tick in the table, or set later in the same function: construct's 60 lines on)
      local near=table.concat(lines,'\n',i,math.min(#lines,i+80))
      if near:find('until_tick',1,true) then found[kind]=(found[kind] or f..':'..i) end
    end
  end
end
local missing={}
for kind,where in pairs(found) do
  if not known[kind] and not APART[kind] then missing[#missing+1]=kind..' ('..where..')' end
end
table.sort(missing)
assert(#missing==0,'timed actions the scheduler does not know: '..table.concat(missing,', '))
-- The list is honest: every kind it names is built somewhere.
for kind in pairs(known) do assert(found[kind],'no timed action of kind '..kind..' in the sources') end
-- Each listed action is one the runtime answers.
local actions=runtime.dispatch{action='describe',args={},player=1}.actions
for action in pairs(TIMED) do assert(actions[action],'no action '..action) end
print('queuetimed: ok')
