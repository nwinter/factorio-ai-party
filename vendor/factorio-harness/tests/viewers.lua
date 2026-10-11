-- Run from repository root: lua tests/viewers.lua
-- Viewer lines in the game (a wake only on @name) and the agents' mute
-- vote (audience.lua), through the runtime against a fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
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
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
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
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
-- As control.lua does: a failed request stops its player unless the runtime
-- marked it passive.
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.player or (req.bot==nil and 1 or nil)
    if req.bot then who=runtime.bots.index_of(req.bot) end
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local astra,sol,grok=as('astra'),as('sol'),as('grok')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sunny',glyph='S',color='#ffcb45'})


-- Every agent has made a request: all three are active.
astra('status'); sol('status'); grok('status')
local function lines(who) local out={} for _,m in ipairs(who('chat',{limit=100,peek=true}).messages) do out[#out+1]=m end return out end
local function last(who) local l=lines(who); return l[#l] end

-- A viewer's @name reaches that agent as a mention and wakes it; nobody else.
sol('sleep',{seconds=60}); grok('sleep',{seconds=60})
eq(op('viewer_say',{name='factoryfan',text='@sol are the labs fed?'}).posted,true)
local r=sol('sleep_check',{peek=true}); eq(r.woke,'mentioned'); eq(r.mention,'viewer factoryfan: @sol are the labs fed?')
eq(grok('sleep_check',{peek=true}).woke,nil)
eq(op('viewer_say',{name='cy',text='grok and everyone, nice base'}).posted,true) -- no @: no wake
eq(grok('sleep_check',{peek=true}).woke,nil)
sol('sleep_check',{}); jump(601)

-- Voting: a majority of the agents active in the last 10 minutes (3 here: 2).
r=astra('vote',{kind='mute',viewer='viewer Troll42',reason='slurs in chat'})
eq(r.viewer,'Troll42'); eq(r.votes,1); eq(r.needed,2); eq(r.active,3); eq(r.result,nil)
local n=last(grok); eq(n.from,'vote'); eq(n.notice,true); eq(n.text,'astra votes to mute viewer Troll42 (1 of 2 needed): slurs in chat')
eq((grok('status').team or {}).mentions,nil) -- a notice naming astra mentions nobody
eq(astra('vote',{kind='mute',viewer='troll42',reason='again'}).votes,1) -- a second vote by the same agent counts once
eq(#astra('votes').open,1); eq(astra('votes').open[1].voters[1],'astra')
eq(op('viewer_say',{name='Troll42',text='still here'}).posted,true)
jump(1300)
r=sol('vote',{kind='mute',viewer='TROLL42',reason='spam'})
eq(r.votes,2); eq(r.result,'muted')
eq(last(astra).text,'viewer Troll42 is muted for the rest of the run (2 of 3 active agents: astra, sol)')
local v=op('votes',{}); eq(v.muted[1].viewer,'Troll42'); eq(v.muted[1].by[2],'sol'); eq(#v.open,0)
-- A muted viewer's lines are refused, whatever the case of the name.
r=op('viewer_say',{name='troll42',text='hello?'}); eq(r.posted,false); eq(r.dropped,'muted'); eq(r.reason,'spam')
fails(function() grok('vote',{kind='mute',viewer='Troll42',reason='x'}) end,'already muted')
fails(function() grok('vote',{kind='unmute',viewer='nobody',reason='x'}) end,'is not muted')
fails(function() grok('vote',{kind='ban',viewer='x',reason='x'}) end,'kind must be mute or unmute')
fails(function() grok('vote',{kind='mute',viewer='x',reason=' '}) end,'reason is required')
fails(function() grok('vote',{kind='mute',viewer=' [b] ',reason='x'}) end,'viewer is required')
fails(function() request{action='vote',args={kind='mute',viewer='x',reason='x'},player=2} end,'living survival character') -- a director

-- Agents idle for over 10 minutes do not count: after astra and sol go
-- quiet, grok alone is the majority of the active agents.
jump(36001)
r=grok('vote',{kind='unmute',viewer='troll42',reason='apologised'})
eq(r.active,1); eq(r.needed,1); eq(r.result,'unmuted')
eq(op('viewer_say',{name='Troll42',text='sorry everyone'}).posted,true)
-- A vote from an agent that went quiet stops counting.
astra('vote',{kind='mute',viewer='bob',reason='links'})
jump(36001)
sol('status'); grok('status')
r=grok('vote',{kind='mute',viewer='bob',reason='links'}); eq(r.active,2); eq(r.votes,1); eq(r.needed,2); eq(r.result,nil)
r=sol('vote',{kind='mute',viewer='bob',reason='links'}); eq(r.result,'muted')
print('viewers: ok')
