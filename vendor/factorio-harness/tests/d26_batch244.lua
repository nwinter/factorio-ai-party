-- d26 batch244 (Astra #2455): a short machine whose feeder is off by its circuit or logistic condition while the
-- feeder's source holds the ingredient is said apart from missing stock, with the feeder, its condition and the
-- signal's value, and what its source holds. Run from the harness root: lua tests/d26_batch244.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end

local GATED, WORKING = 37, 1
local function setup()
  game={tick=1000}
  defines={inventory={assembling_machine_input=2,furnace_source=2,crafter_input=2,chest=1},
    entity_status={disabled_by_control_behavior=GATED,working=WORKING,item_ingredient_shortage=7}}
end
-- A world of one surface: crafters and inserters a find returns by area and type.
local function world()
  local w={crafters={},inserters={},finds=0}
  w.surface={name='aquilo',index=1,find_entities_filtered=function(f)
    if f.type=='inserter' then
      w.finds=w.finds+1
      local out={}
      for _,i in ipairs(w.inserters) do
        local a=f.area
        if i.position.x>=a.left_top.x and i.position.x<=a.right_bottom.x and i.position.y>=a.left_top.y and i.position.y<=a.right_bottom.y then out[#out+1]=i end
      end
      return out
    end
    return w.crafters
  end}
  w.surface.find_entity=function(name,pos)
    for _,e in ipairs(w.crafters) do if e.name==name and e.position.x==pos.x and e.position.y==pos.y then return e end end
  end
  return w
end
local function chest(x,y,counts)
  return {valid=true,name='requester-chest',type='logistic-container',position={x=x,y=y},get_item_count=function(n) return counts[n] or 0 end}
end
-- A cryogenic plant at (x,y) (5x5) making cryogenic-science-pack: 6 ice and 3 lithium-plate a craft, holding held.
local function plant(w,x,y,held,st)
  local e={valid=true,type='assembling-machine',name='cryogenic-plant',position={x=x,y=y},st=st or 'item_ingredient_shortage',fluidbox={{name='fluoroketone-cold',amount=100}},
    status=7,unit_number=#w.crafters+100,surface=w.surface,force='player',
    bounding_box={left_top={x=x-2.5,y=y-2.5},right_bottom={x=x+2.5,y=y+2.5}},
    get_recipe=function() return {name='cryogenic-science-pack',ingredients={{type='item',name='ice',amount=6},{type='item',name='lithium-plate',amount=3},
      {type='fluid',name='fluoroketone-cold',amount=6}}} end}
  local inv={get_item_count=function(n) return held[n] or 0 end}
  e.get_inventory=function() return inv end
  w.crafters[#w.crafters+1]=e
  return e
end
local function inserter(w,x,y,into,src,status,hand)
  local i={valid=true,name='stack-inserter',type='inserter',position={x=x,y=y},status=status,drop_target=into,pickup_target=src,surface=w.surface,
    held_stack={valid_for_read=hand~=nil,name=hand}}
  w.inserters[#w.inserters+1]=i
  return i
end
-- thrust.state_text's words for a gated arm (its own test is in thrust's suites)
local function state_text(i)
  if i.status==GATED then return 'off by its circuit condition cryogenic-science-pack >= 2000 (cryogenic-science-pack '..(i.csp or 2140)..' on its wires)' end
  return 'working'
end
local function modules(w)
  local F=dofile('mod/agent-harness_0.1.0/feeders.lua'){}
  local S=dofile('mod/agent-harness_0.1.0/supply.lua'){feeders_of=F.of,state_text=state_text,status_name=function(e) return e.st end}
  local SH=dofile('mod/agent-harness_0.1.0/shortages.lua'){reuse=function(_,fn) return fn() end,status_name=function(e) return e.st end,
    held_feeders=S.held_feeders,held_line=S.held_line}
  return F,S,SH
end

-- shortages: Astra's two plants (feeders at (7.5,-0.5) and (37.5,-1.5) off, their requesters holding 101 and 103 ice)
-- held back; a plant whose running feeder's source is empty, one whose gated feeder's source holds no ice, and one
-- with a running feeder holding ice beside a gated one are missing stock; a plant short of both, one held and one not.
do
  setup()
  local w=world()
  local p1=plant(w,6.5,2.5,{ice=2,['lithium-plate']=5})
  inserter(w,7.5,-0.5,p1,chest(7.5,-1.5,{ice=101}),GATED)
  local p2=plant(w,36.5,1.5,{ice=0,['lithium-plate']=3})
  inserter(w,37.5,-1.5,p2,chest(37.5,-2.5,{ice=103}),GATED)
  local p3=plant(w,66.5,2.5,{['lithium-plate']=3})
  inserter(w,67.5,-0.5,p3,chest(67.5,-1.5,{}),WORKING)
  local p4=plant(w,96.5,2.5,{['lithium-plate']=3})
  inserter(w,97.5,-0.5,p4,chest(97.5,-1.5,{['lithium-plate']=40}),GATED)
  local p5=plant(w,126.5,2.5,{['lithium-plate']=3})
  inserter(w,127.5,-0.5,p5,chest(127.5,-1.5,{ice=50}),GATED)
  inserter(w,125.5,-0.5,p5,chest(125.5,-1.5,{ice=8}),WORKING)
  local p6=plant(w,156.5,2.5,{})
  inserter(w,157.5,-0.5,p6,chest(157.5,-1.5,{ice=30}),GATED)
  inserter(w,155.5,-0.5,p6,chest(155.5,-1.5,{}),WORKING)
  plant(w,186.5,2.5,{ice=6,['lithium-plate']=3},'working')
  local _,S,SH=modules(w)
  local force={name='player',logistic_networks={}}
  local r=SH.read({surface=w.surface,force=force},{})
  eq(r.lines[1],'stopped short of an ingredient, missing stock: cryogenic-science-pack short of ice (3 machines); cryogenic-science-pack short of lithium-plate (1 machine)')
  eq(r.lines[2],"stopped short of an ingredient, held back by its feeder's condition (its source holds the ingredient): cryogenic-science-pack short of ice (3 machines): "
    ..'cryogenic-plant (6.5,2.5): input stack-inserter (7.5,-0.5) off by its circuit condition cryogenic-science-pack >= 2000 (cryogenic-science-pack 2140 on its wires); '
    ..'its source requester-chest (7.5,-1.5) holds 101 ice | cryogenic-plant (36.5,1.5): input stack-inserter (37.5,-1.5) off by its circuit condition '
    ..'cryogenic-science-pack >= 2000 (cryogenic-science-pack 2140 on its wires); its source requester-chest (37.5,-2.5) holds 103 ice | 1 more')
  eq(r.lines[3],'requester chests lack nothing')
  eq(#r.held_back,2)
  local h=r.held_back[1]
  eq(h.machine,'cryogenic-plant'); eq(h.item,'ice'); eq(h.recipe,'cryogenic-science-pack'); eq(h.position.x,6.5)
  eq(h.inserter,'stack-inserter'); eq(h.inserter_position.x,7.5); eq(h.inserter_position.y,-0.5)
  eq(h.source,'requester-chest'); eq(h.source_position.y,-1.5); eq(h.source_holds,101)
  eq(r.held_back[2].source_holds,103)
  -- the machines' own statuses are what the game says: nothing written
  eq(p1.st,'item_ingredient_shortage'); eq(p1.status,7)
  -- one find a short machine with an item lacking (six), none for the working one
  eq(w.finds,6)
  -- held_feeders by itself: p5's running feeder has ice at its source, so not held; p6 holds ice only
  eq(S.held_feeders(p5,{'ice'}),nil)
  local h6=S.held_feeders(p6,{'ice','lithium-plate'})
  eq(h6.ice.count,30); eq(h6['lithium-plate'],nil)
  -- a running feeder with ice in its hand (its source empty now) runs it
  local p7=plant(w,216.5,2.5,{})
  inserter(w,217.5,-0.5,p7,chest(217.5,-1.5,{ice=12}),GATED)
  inserter(w,215.5,-0.5,p7,chest(215.5,-1.5,{}),WORKING,'ice')
  eq(S.held_feeders(p7,{'ice'}),nil)
  -- a logistic condition's words come from state_text the same way; an arm with no pickup target: the one at its
  -- pickup position
  local p8=plant(w,246.5,2.5,{})
  local box=chest(247.5,-1.5,{ice=7})
  local i8=inserter(w,247.5,-0.5,p8,nil,GATED)
  i8.pickup_position={x=247.5,y=-1.5}
  w.surface.find_entities_filtered=(function(old) return function(f) if f.position then return {box} end return old(f) end end)(w.surface.find_entities_filtered)
  local h8=S.held_feeders(p8,{'ice'})
  eq(h8.ice.count,7)
  has(S.held_line(h8.ice,'ice'),'its source requester-chest (247.5,-1.5) holds 7 ice')
  -- the wait's note
  eq(S.held_note(p1),"; held back by its feeder's condition (its source holds the item): input stack-inserter (7.5,-0.5) off by its circuit condition "
    ..'cryogenic-science-pack >= 2000 (cryogenic-science-pack 2140 on its wires); its source requester-chest (7.5,-1.5) holds 101 ice')
  eq(S.held_note(p3),nil)
  defines=nil
end
print('d26_batch244 shortages held back by a feeder\'s condition: ok')

-- Bounded: the feeders of the first 32 short machines read, the rest counted as missing stock and said; the words (a
-- circuit read each) for 6 machines at most, 2 a group.
do
  setup()
  local w=world()
  for k=1,40 do
    local p=plant(w,k*10+0.5,2.5,{['lithium-plate']=3})
    inserter(w,k*10+1.5,-0.5,p,chest(k*10+1.5,-1.5,{ice=5}),GATED)
  end
  local _,S,SH=modules(w)
  local words=0
  local SH2=dofile('mod/agent-harness_0.1.0/shortages.lua'){reuse=function(_,fn) return fn() end,status_name=function(e) return e.st end,
    held_feeders=S.held_feeders,held_line=function(h,item) words=words+1; return S.held_line(h,item) end}
  local r=SH2.read({surface=w.surface,force={name='player',logistic_networks={}}},{})
  eq(w.finds,32)
  eq(r.lines[1],'stopped short of an ingredient, missing stock: cryogenic-science-pack short of ice (8 machines)')
  has(r.lines[2],'held back by its feeder\'s condition (its source holds the ingredient): cryogenic-science-pack short of ice (32 machines): ')
  has(r.lines[2],' | 30 more')
  eq(r.lines[3],'feeders read for the first 32 machines short of an item; 8 more counted as missing stock without that read')
  eq(words,2); eq(#r.held_back,2)
  -- without held_feeders (an old wiring) the read is as before, missing stock only
  local SH3=dofile('mod/agent-harness_0.1.0/shortages.lua'){reuse=function(_,fn) return fn() end,status_name=function(e) return e.st end}
  r=SH3.read({surface=w.surface,force={name='player',logistic_networks={}}},{})
  eq(r.lines[1],'stopped short of an ingredient, missing stock: cryogenic-science-pack short of ice (40 machines)')
  lacks(r.lines[2],'held back')
  defines=nil
end
print('d26_batch244 shortages bounded: ok')

-- game_alerts' silo_short: a silo short of a part ingredient for 2 min whose feeder is held off says so after the parts.
do
  setup()
  defines.rocket_silo_status={rocket_ready=9}
  local st={}
  local held={}
  local P=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,status_name=function(e) return 'item_ingredient_shortage' end,
    held_feeders=function(e,items) return held[items[1]] and {[items[1]]=held[items[1]]} or nil end,
    held_line=function(h,item) return 'input bulk-inserter (3.5,-6.5) off by its circuit condition processing-unit >= 500 (processing-unit 800 on its wires); its source requester-chest (3.5,-7.5) holds 400 processing-unit' end}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',unit_number=7,position={x=0.5,y=0.5},status=7,rocket_parts=40,rocket_silo_status=0,
    prototype={rocket_parts_required=50},get_recipe=function() return {ingredients={{type='item',name='processing-unit',amount=10},{type='item',name='low-density-structure',amount=10}}} end,
    get_inventory=function() return {get_item_count=function(n) return n=='low-density-structure' and 20 or 2 end} end}
  defines.entity_status.item_ingredient_shortage=7
  P.silo_state(silo,{})
  game.tick=game.tick+7200
  local k,d=P.silo_state(silo,{})
  eq(k,'silo_short.processing-unit')
  eq(d,'rocket-silo (0.5,0.5): parts 40/50, no new part for 2 min; short of processing-unit (2 in it); silo {position, why: true} follows it')
  held['processing-unit']={arm={},source={},count=400}
  k,d=P.silo_state(silo,{})
  eq(k,'silo_short.processing-unit')
  eq(d,"rocket-silo (0.5,0.5): parts 40/50, no new part for 2 min; short of processing-unit (2 in it); held back by its feeder's condition (its source holds it): "
    ..'input bulk-inserter (3.5,-6.5) off by its circuit condition processing-unit >= 500 (processing-unit 800 on its wires); its source requester-chest (3.5,-7.5) holds 400 processing-unit; '
    ..'silo {position, why: true} follows it')
  defines=nil
end
print('d26_batch244 silo_short held back: ok')

-- starved (a wait's alert) gives the entities beside its lines, for the wait's note
do
  setup()
  local st={board={items={{kind='claim',status='claimed',owner='astra',id=5,title='cryo',area={left_top={x=0,y=0},right_bottom={x=20,y=20}}}}}}
  local m={valid=true,name='cryogenic-plant',type='assembling-machine',position={x=6.5,y=2.5},unit_number=30,status=7}
  local s={name='aquilo',find_entities_filtered=function() return {m} end}
  game.surfaces={aquilo=s}
  local P=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,who=function(p) return p.name end,
    status_name=function(e) return e.status==7 and 'item_ingredient_shortage' or 'working' end,claim_surface=function() return 'aquilo' end}
  local lines,ents=P.starved({name='astra',force='player'})
  eq(lines[30],'cryogenic-plant (6.5,2.5) in your claim "cryo" item ingredient shortage'); eq(ents[30],m)
  game.surfaces=nil
  defines=nil
end
print('d26_batch244 starved entities: ok')

-- factory_digest: the survey's item-short machines read again now (24 at most): those held back by their feeder's
-- condition counted and the first 2 a surface worded; one working now is not read as short.
do
  setup()
  local w=world()
  local p1=plant(w,6.5,2.5,{ice=2})
  inserter(w,7.5,-0.5,p1,chest(7.5,-1.5,{ice=101}),GATED)
  local p2=plant(w,36.5,1.5,{})
  inserter(w,37.5,-1.5,p2,chest(37.5,-2.5,{}),WORKING)
  local p3=plant(w,66.5,2.5,{},'working')
  local _,S=modules(w)
  local surfaces={[1]=w.surface}
  game.get_surface=function(i) return surfaces[i] end
  game.forces={player={name='player'}}
  local st={survey_cache={['player/1']={tick=900,digest={tick=900,machines={['cryogenic-plant']={type='assembling-machine',total=3,
    counts={item_ingredient_shortage=3},positions={item_ingredient_shortage={{x=6.5,y=2.5},{x=36.5,y=1.5},{x=66.5,y=2.5}}}}},fuel={},belts={ends=0}}}}}
  local D=dofile('mod/agent-harness_0.1.0/factory_digest.lua'){state=function() return st end,held_check=S.held_check,held_line=S.held_line,
    status_name=function(e) return e.st end}
  local out=D.operator.factory_digest{}
  local hb=out.surfaces[1].held_back
  eq(hb.read,2); eq(hb.held,1); eq(#hb.lines,1)
  eq(hb.lines[1],'cryogenic-plant (6.5,2.5) short of ice: input stack-inserter (7.5,-0.5) off by its circuit condition cryogenic-science-pack >= 2000 '
    ..'(cryogenic-science-pack 2140 on its wires); its source requester-chest (7.5,-1.5) holds 101 ice')
  -- the survey's counts stay as cached
  eq(out.surfaces[1].machines['cryogenic-plant'].counts.item_ingredient_shortage,3)
  game.get_surface=nil; game.forces=nil
  defines=nil
end
print('d26_batch244 factory_digest held_back: ok')

-- A wait on starved: a new starving machine in a claim whose feeder is held off by its condition wakes it with the
-- feeder's words after the line (supply.held_note).
do
  game={tick=100}
  local s={active={}}
  local function integer(v,d,lo,hi,name) if v==nil then v=d end; assert(type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi,name..' out of range'); return v end
  local starving,ents={},{}
  local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return s end,integer=integer,replace=function() end,advance=function() end,
    clock_mode=function() return 'realtime' end,alert_levels=function() return {} end,
    starved=function() local out={} for u,l in pairs(starving) do out[u]=l end return out,ents end,
    held_note=function(e) return e.note end}
  local p={index=1,character={valid=true,health=250}}
  starving[11]='assembling-machine-2 (1,1) in your claim "gears" item ingredient shortage'; ents[11]={}
  W.handlers.sleep(p,{seconds=300,condition={['until']='alert',kinds={'starved'}}})
  eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
  starving[12]='cryogenic-plant (6.5,2.5) in your claim "cryo" item ingredient shortage'
  ents[12]={note="; held back by its feeder's condition (its source holds the item): input stack-inserter (7.5,-0.5) off by its circuit condition cryogenic-science-pack >= 2000 (cryogenic-science-pack 2140 on its wires); its source requester-chest (7.5,-1.5) holds 101 ice"}
  game.tick=800
  local r=W.handlers.sleep_check(p,{peek=true})
  eq(r.woke,'alert'); eq(r.alert,starving[12]..ents[12].note)
  game=nil
end
print('d26_batch244 starved wait note: ok')
