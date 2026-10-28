-- d27 batch273. Run from the harness root: lua tests/d27_batch273.lua
-- TL (Nick, d27; all nine agents asked for it): a tell holds up to 2000 bytes; one over 500 needs a summary line of at
-- most 120 characters (refused without it, nothing sent); recipients get the whole text (the team block, a tells read,
-- the wake), the operator read carries the summary for the stream; the unread list, open's examples, an owed item and
-- mention_counts' latest show the summary. Sol: the 500-byte cap split his Aquilo launch audit in parts.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function line(list,text) for _,l in ipairs(list or {}) do if l:find(text,1,true) then return l end end return nil end


storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
prototypes={item={['submachine-gun']={type='gun',attack_parameters={ammo_categories={'bullet'},range=18}},
  ['rocket-launcher']={type='gun',attack_parameters={ammo_categories={'rocket'},range=36}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}},
  ['iron-plate']={type='item'}}}
local drawn={}
rendering={draw_text=function() local obj={valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,
  is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},selected_gun_index=1}
  c.insert=function(s) return s.count end
  c.get_item_count=function() return 0 end
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
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    if req.bot then pcall(runtime.stop_player,runtime.bots.index_of(req.bot)) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local function op(action,args) return request{action=action,args=args or {},operator=true} end
for _,n in ipairs{'sol','astra','grok'} do runtime.operator.bot_create(n) end
local sol,astra,grok=as('sol'),as('astra'),as('grok')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
advance(1)
local function team(f) return (f('status').team or {}).tells or {} end
team(sol); team(astra); team(grok)

-- Sol's launch audit, whole: 1700 bytes (one line), with its summary
local audit=string.rep('Silo (-18.5,17.5) launch 14 at tick 71945279: 25 uranium rounds received by Asterion. ',20):gsub('%s+$','')
assert(#audit>1500 and #audit<=2000,#audit)
local summary='Aquilo launch audit: 20 launches, all received by Asterion; ammo reserve ok'
local cursor=op('tells',{}).cursor
local r=sol('tell',{to='astra',text=audit,summary=summary})
eq(r.seq,cursor+1); eq(r.cut,nil)
-- the recipient's next reply: the whole text in its team block
local shown=line(team(astra),'sol, ')
has(shown,audit)
-- the operator read (the stream service): text and summary
local row=op('tells',{since=cursor}).tells[1]
eq(row.text,audit); eq(row.summary,summary)
-- the recipient's tells read: both
row=astra('tells',{}).tells; row=row[#row]
eq(row.text,audit); eq(row.summary,summary)
print('1. a 1700-byte tell with its summary: whole in the team block and the reads, the summary beside it: ok')

-- refusals: over 500 without a summary, a summary over 120 characters, a text over 2000; nothing sent each time
cursor=op('tells',{}).cursor
fails(function() sol('tell',{to='astra',text=string.rep('x',501)}) end,'a tell over 500 bytes needs summary, one line of at most 120 characters')
fails(function() sol('tell',{to='astra',text=string.rep('x',501),summary='   '}) end,'needs summary')
fails(function() sol('tell',{to='astra',text=string.rep('x',600),summary=string.rep('s',121)}) end,'tell summary is 121 characters; at most 120')
fails(function() sol('tell',{to='astra',text=string.rep('x',2001),summary='s'}) end,'tell text is 2001 bytes; the limit is 2000: shorten it; nothing was sent')
fails(function() sol('tell',{to='astra',text=string.rep('é',1001),summary='s'}) end,'the limit is 2000')
fails(function() sol('tell',{to='astra',text='short',summary=7}) end,'summary must be a string')
eq(op('tells',{}).cursor,cursor)
eq(#team(astra),0)
-- characters, not bytes: 120 two-byte characters fit, 121 do not; 500 bytes need none; a short tell may carry one
eq(sol('tell',{to='astra',text=string.rep('y',600),summary=string.rep('é',120)}).seq,cursor+1)
fails(function() sol('tell',{to='astra',text=string.rep('y',600),summary=string.rep('é',121)}) end,'121 characters')
eq(sol('tell',{to='astra',text=string.rep('z',500)}).seq,cursor+2)
eq(sol('tell',{to='astra',text='ok',summary='fine'}).seq,cursor+3)
eq(op('tells',{since=cursor+2}).tells[1].summary,'fine')
-- control characters in a summary read as spaces: one line
eq(sol('tell',{to='astra',text=string.rep('w',501),summary='two\nlines'}).seq,cursor+4)
eq(op('tells',{since=cursor+3}).tells[1].summary,'two lines')
local d=runtime.dispatch{action='describe',args={},player=1}.actions.tell
has(d.text,'1..2000 bytes'); has(d.summary,'at most 120 characters'); has(d.summary,'over 500 bytes')
print('2. refused over 500 without a summary, a summary over 120 characters, a text over 2000: nothing sent: ok')

-- the unread list: a tell shown once and not marked read is listed again by its summary, not cut at 100 characters
team(grok)
local long=string.rep('Pad receipt pod 53243727 tick 71945279 spoil bands 4 red 0. ',12):gsub('%s+$','')
local seq=astra('tell',{to='grok',text=long,summary='pad receipt: pod 53243727, no reds'}).seq
has(line(team(grok),'astra, '),long)
local again=team(grok)
has(line(again,'unread #'..seq),'unread #'..seq..' astra, waiting ')
has(line(again,'unread #'..seq),': pad receipt: pod 53243727, no reds')
assert(not line(again,'Pad receipt pod'),'the whole text is not repeated in the unread list')
print('3. the unread list names a long tell by its summary: ok')

-- an asking tell is owed by its summary; mention_counts' latest names it by its summary
local ask=string.rep('Freight handoff: 400 rounds, reserve 200, at Asterion hub, next command load, finish test 0 missing. ',6)..'Can you take it?'
astra('tell',{to='sol',text=ask,summary='freight handoff to you: can you take it?'})
local counts
for _,a in ipairs(op('mention_counts').agents) do if a.name=='sol' then counts=a end end
eq(counts.latest,'astra: freight handoff to you: can you take it?')
local st=sol('status')
has(line(st.team.tells,'astra, '),'Can you take it?')
has(st.unanswered,'"freight handoff to you: can you take it?"')
print('4. owed and mention_counts: the summary: ok')

-- an operator tell (idle_nudge.py) follows the same rule
fails(function() op('tell',{to='sol',text=string.rep('n',700)}) end,'needs summary')
eq(op('tell',{to='sol',text=string.rep('n',700),summary='idle 12 min; 3 tells unread'}).to[1],'sol')
print('5. an operator tell over 500 bytes needs a summary too: ok')
print('d27_batch273: ok')
