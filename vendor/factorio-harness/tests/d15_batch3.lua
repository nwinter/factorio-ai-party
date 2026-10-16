-- d15 batch3 (operator 18:30, shifts 18-19 requests). Run from the harness root: lua tests/d15_batch3.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A mock inventory: slots {name,count} or false.
local function inventory(list)
  local inv={}
  local mt={__len=function() return #list end,__index=function(_,k)
    if type(k)=='number' then local s=list[k]; return s and {valid_for_read=true,name=s[1],count=s[2]} or {valid_for_read=false} end
    if k=='count_empty_stacks' then return function() local n=0; for _,s in ipairs(list) do if not s then n=n+1 end end; return n end end
    if k=='can_insert' then return function() for _,s in ipairs(list) do if not s then return true end end; return false end end
    if k=='get_item_count' then return function(name) local n=0; for _,s in ipairs(list) do if s and s[1]==name then n=n+s[2] end end; return n end end
  end}
  return setmetatable(inv,mt)
end

-- 1 (Astra, Luna): a chest with every slot used, what fills it, and the machines whose output waits on it. ---------
do
  defines={inventory={chest=1},entity_status={}}
  local status={}
  local force={name='player'}
  local by_type={}
  local surface={find_entities_filtered=function(f)
    local out={}
    local types=type(f.type)=='table' and f.type or {f.type}
    for _,t in ipairs(types) do for _,e in ipairs(by_type[t] or {}) do out[#out+1]=e end end
    return out
  end}
  local function entity(t)
    t.valid=true; t.surface=surface; t.force=force
    local x,y=t.position.x,t.position.y
    t.bounding_box={left_top={x=x-0.5,y=y-0.5},right_bottom={x=x+0.5,y=y+0.5}}
    by_type[t.type]=by_type[t.type] or {}; table.insert(by_type[t.type],t)
    return t
  end
  local slots={}
  for i=1,48 do slots[i]=i<=40 and {'spoilage',100} or {'nutrients',30} end
  local full_inv=inventory(slots)
  local chest=entity{type='logistic-container',name='passive-provider-chest',unit_number=10,position={x=10.5,y=4.5},get_inventory=function() return full_inv end}
  local spare_inv=inventory({{'nutrients',5},false,false})
  local spare=entity{type='container',name='steel-chest',unit_number=11,position={x=14.5,y=4.5},get_inventory=function() return spare_inv end}
  local bio=entity{type='assembling-machine',name='biochamber',unit_number=20,position={x=7.5,y=4.5}}
  local ins=entity{type='inserter',name='inserter',unit_number=30,position={x=9.5,y=4.5},drop_target=chest,pickup_target=bio}
  local other=entity{type='inserter',name='inserter',unit_number=31,position={x=11.5,y=4.5},drop_target=spare,pickup_target=chest}
  status[bio]='full_output'; status[ins]='waiting_for_space_in_destination'; status[other]='working'
  local F=require('fullchest'){status_name=function(e) return status[e] end}
  local r=F.read(chest)
  eq(r.line,'passive-provider-chest (10.5,4.5): 48/48 slots used (spoilage 4000 in 40 slots, nutrients 240 in 8 slots); output waits on it: biochamber (7.5,4.5) full_output (1 inserter waiting)')
  eq(F.read(spare),nil,'a chest with a free slot is not full')
  eq(F.free_note(spare),', 2/3 slots free'); eq(F.free_note(chest),', 0/48 slots free')
  eq(F.of_machine(bio).line,r.line,'a full_output machine finds the chest its inserter waits on')
  local near=F.nearest_free(chest)
  eq(near[1],'steel-chest (14.5,4.5) 2/3 slots free, 4 tiles')
  spare_inv=inventory({{'nutrients',5}})
  eq(F.nearest_free(chest)[1],'no chest of ours within 32 tiles has a free slot')

  -- supply: full_chests from the makers' takers, free slots on the listed providers.
  prototypes={item={nutrients={}},fluid={}}
  local S=require('supply'){state=function() return {} end,integer=function(v,d) return v or d end,status_name=function(e) return status[e] end}
  local t={item='nutrients',chests={{n=240,e=chest,kind='passive-provider'}},takers={n=1,states={},into={},chests={[10]=chest}},request_of={}}
  local lines=S.full_chests(t)
  eq(lines[1],r.line); eq(#lines,1,'the same chest once')
  eq(S.top_chests(t)[1],'(10.5,4.5) passive-provider-chest 240, 0/48 slots free')

  -- open for you: a full_output machine in a fresh claim whose output waits on a full chest.
  game={tick=100000,surfaces={gleba={index=4,find_entity=function(name,pos) if name=='biochamber' and pos.x==7.5 then return bio end end}}}
  local st={board={items={{id=700,kind='claim',owner='luna',status='doing',title='bioflux',surface='gleba',area={left_top={x=0,y=0},right_bottom={x=40,y=40}}}}},
    survey_cache={['player/4']={positions={biochamber={full_output={{x=7.5,y=4.5}}}}}}}
  local O=require('open'){state=function() return st end,claim_surface=function(i) return i.surface end,claim_stale=function() return false end,fullchest=F}
  has(O.line('luna',force),'1 full chest in your claims that output waits on (passive-provider-chest (10.5,4.5) 48/48 slots used (spoilage 4000 in 40 slots, nutrients 240 in 8 slots))')
end
print('d15_batch3 1 full chests: ok')

-- 2 (Sol): what removing heat pipes does to heat: freezable entities losing their last warm heater, parts cut off. --
do
  local all={}
  local function proto(type,w,h,heating,buf) return {type=type,w=w,h=h,heating_energy=heating or 0,heat_buffer_prototype=buf and {specific_heat=1e6,max_temperature=1000,min_working_temperature=15,max_transfer=1e9} or nil} end
  local surface={planet={prototype={entities_require_heating=true}}}
  local n=0
  local function ent(name,pr,x,y,temp)
    n=n+1
    local e={valid=true,unit_number=n,name=name,type=pr.type,prototype=pr,position={x=x,y=y},direction=0,temperature=temp,heat_neighbours={}}
    all[#all+1]=e; return e
  end
  local function link(a,b) table.insert(a.heat_neighbours,b); table.insert(b.heat_neighbours,a) end
  surface.find_entities_filtered=function(f)
    local out={}
    local types=f.type and (type(f.type)=='table' and f.type or {f.type})
    for _,e in ipairs(all) do
      local ok=true
      if types then ok=false; for _,t in ipairs(types) do if t==e.type then ok=true end end end
      local a=f.area
      local w,h=(e.prototype.w or 1)/2,(e.prototype.h or 1)/2
      if ok and a and not (e.position.x+w>a[1][1] and e.position.x-w<a[2][1] and e.position.y+h>a[1][2] and e.position.y-h<a[2][2]) then ok=false end
      if ok then out[#out+1]=e end
    end
    return out
  end
  local H=require('heating'){footprint=function(pr,pos) return {left_top={x=pos.x-pr.w/2,y=pos.y-pr.h/2},right_bottom={x=pos.x+pr.w/2,y=pos.y+pr.h/2}} end}
  local tower=ent('heating-tower',proto('reactor',3,3,0,true),1.5,1.5,300)
  local pipe=proto('heat-pipe',1,1,0,true)
  local p1=ent('heat-pipe',pipe,3.5,1.5,280); local p2=ent('heat-pipe',pipe,4.5,1.5,270); local p3=ent('heat-pipe',pipe,5.5,1.5,260)
  link(tower,p1); link(p1,p2); link(p2,p3)
  local ug=ent('pipe-to-ground',proto('pipe-to-ground',1,1,50),5.5,2.5)
  local turbine=ent('steam-turbine',proto('generator',3,5,100),7.5,1.5)
  local loss=H.loss(surface,{name='player'},{p2})
  eq(loss.cut_off,'1 heat-network part cut off from every nuclear reactor and heating tower (1 heat-pipe; first at (5.5,1.5)); they keep their heat and cool')
  eq(loss.freeze_count,2)
  has(table.concat(loss.freeze,' | '),'pipe-to-ground (5.5,2.5): keeps only heaters cut off from every reactor and heating tower, which cool (heat-pipe (5.5,1.5) 260 C)')
  has(table.concat(loss.freeze,' | '),'steam-turbine (7.5,1.5): keeps only heaters cut off from every reactor and heating tower, which cool (heat-pipe (5.5,1.5) 260 C)')
  -- removing the end pipe: nothing cut; the turbine loses its last heater
  loss=H.loss(surface,{name='player'},{p3})
  eq(loss.cut_off,nil); eq(loss.freeze_count,1); has(table.concat(loss.freeze,' | '),'steam-turbine (7.5,1.5): loses its last heater at 30 C or more (heat-pipe (5.5,1.5) 260 C)')
  -- a pipe whose neighbours stay warm from another heater: nothing
  local p4=ent('heat-pipe',pipe,4.5,3.5,250); link(p4,tower)
  loss=H.loss(surface,{name='player'},{p2})
  eq(loss.freeze_count,1,'the underground keeps p4'); has(loss.freeze[1],'steam-turbine')
  -- no heating needed and nothing cut: none
  surface.planet.prototype.entities_require_heating=false
  eq(H.loss(surface,{name='player'},{p3}).none,'no entity loses its last heater at 30 C or more and no heat-network part is cut off')
  eq(H.loss(surface,{name='player'},{ug}),nil,'no heat part removed')
end
print('d15_batch3 2 heat: ok')

-- 3 (Grok): guns and ammo per slot; compatible ammo in another slot; moving ammo between ammo slots. ---------------
do
  defines={inventory={character_guns=1,character_ammo=2}}
  prototypes={item={pistol={type='gun',attack_parameters={ammo_categories={'bullet'}}},
    ['piercing-rounds-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}}}}
  local function slot(name,count)
    local s={}
    local function set(n,c) s.name,s.count,s.valid_for_read=n,c,n~=nil end
    set(name,count)
    s.swap_stack=function(o) local n,c=s.name,s.count; set(o.name,o.count); o._set(n,c); return true end
    s._set=set
    return s
  end
  local guns={slot('pistol',1),slot(),slot()}
  local ammo={slot(),slot('piercing-rounds-magazine',75),slot()}
  local p={get_inventory=function(i) return i==1 and guns or ammo end}
  local A=require('ammoslots')()
  local r=A.read(p)
  local g,am=A.lines(r)
  eq(g,'1 pistol, 2 empty, 3 empty'); eq(am,'1 empty, 2 piercing-rounds-magazine*75, 3 empty')
  eq(A.elsewhere(r,1),'piercing-rounds-magazine*75 in ammo slot 2 fits pistol (gun slot 1 fires only from ammo slot 1; ammo slot 2 is fired by gun slot 2: empty)')
  eq(A.idle_ammo(r)[1],'ammo slot 2 piercing-rounds-magazine*75: gun slot 2 is empty; it fits gun slot 1 pistol, which fires only from its own ammo slot')
  eq(A.fits('pistol','rocket'),false)
  local m=A.move(p,'piercing-rounds-magazine',1)
  eq(m.from,2); eq(m.to,1); eq(ammo[1].name,'piercing-rounds-magazine'); eq(ammo[1].count,75); eq(ammo[2].valid_for_read,false)
  eq(A.idle_ammo(A.read(p)),nil)
  -- Regression (hotfix 000fb4ac, Sol 18:54): in 2.0 a stack's quality is a LuaQualityPrototype, userdata, not a table.
  local function quality(name) local u=io.tmpfile(); debug.setmetatable(u,{__index={name=name}}); return u end
  ammo[2]=slot('piercing-rounds-magazine',10); ammo[2].quality=quality('uncommon'); ammo[1].quality=quality('normal')
  g,am=A.lines(A.read(p))
  eq(am,'1 piercing-rounds-magazine*75, 2 piercing-rounds-magazine@uncommon*10, 3 empty')
end
print('d15_batch3 3 ammo slots: ok')

-- 4 (Haiku, Luna): the route read before walking: worms on the way with their range, closed-in goals. ------------
do
  game={tick=100,forces={player={name='player'},enemy={name='enemy'}}}
  prototypes={entity={['big-worm-turret']={attack_parameters={range=38}},['biter-spawner']={result_units={}}}}
  local force=game.forces.player
  force.get_friend=function() return false end; force.get_cease_fire=function() return false end
  local worm={valid=true,name='big-worm-turret',type='turret',position={x=250,y=0},force=game.forces.enemy}
  local surface={name='nauvis',index=1,find_entities_filtered=function() return {worm} end}
  local st={}
  local A=require('avoid'){state=function() return st end,charted=function() return true end,leg=function() return false end}
  local closed_goal=false
  local P={half=function() return 0.2 end,area_text=function() return 'the area (10,10)-(20,20) has no gap' end,
    region=function(_,q) return {closed=closed_goal and q.x==500} end,
    dig=function() return {mine={{name='stone-wall',position={x=21.5,y=15.5}},{name='steel-chest',position={x=22.5,y=15.5}}}} end}
  local RC=require('routecheck'){avoid=A,pathing=P}
  local p={index=1,position={x=0,y=0},surface=surface,force=force,character={}}
  local out=RC.check(p,{{x=0,y=0},{x=500,y=0}},A.mode({distance=12}))
  has(out.enemies[1],'big-worm-turret (250,0) range 38: closest pass ')
  has(out.enemies[1],'inside it)')
  has(out.under_range[1],'big-worm-turret (250,0) range 38 is more than distance 12; the route passes ')
  has(out.route,'round worms and spawners')
  has(out.reachable,'not closed in at either end')
  -- the default margins keep the route out of its range
  out=RC.check(p,{{x=0,y=0},{x=500,y=0}},A.mode(nil))
  assert(not out.enemies[1]:find('inside it',1,true),out.enemies[1]); eq(out.under_range,nil)
  -- a live move_to with distance 12 names the worm too (on the straight line)
  has(RC.under_live(p,{{x=0,y=0},{x=500,y=0}},A.mode({distance=12}))[1],'passes 0 tiles from it')
  -- a closed goal: the entities to mine for a way in, the first met first
  closed_goal=true
  out=RC.check(p,{{x=0,y=0},{x=500,y=0}},A.mode(nil))
  eq(out.reachable,'no: closed in at the goal'); eq(out.mine_for_a_way_in[1],'steel-chest (23,16)')
  has(out.closed_in_goal,'the goal: the area')
  -- a goal in deep water: no spot to stand there, no dig (measured on a copy of world n: (350,900) read "closed in, about 0 tiles")
  P.region=function(_,q) return q.x==500 and {closed=true,stuck=true,tiles=0} or {} end
  P.dig=function() error('no dig for a goal with no spot to stand') end
  surface.get_tile=function() return {name='deepwater'} end
  out=RC.check(p,{{x=0,y=0},{x=500,y=0}},A.mode(nil))
  eq(out.reachable,'no: no spot to stand at the goal'); eq(out.closed_in_goal,'the goal: no spot the character stands on within a tile of (500,0) (the tile there: deepwater)')
  eq(out.mine_for_a_way_in,nil)
end
print('d15_batch3 4 route check: ok')

-- 5 (Sol): the inserters that take a machine's output and the chest they fill; the wait's reply says so. ---------
do
  prototypes={item={['lithium-plate']={}}}
  local force={name='player'}
  local chest={valid=true,unit_number=7,type='container',name='steel-chest',position={x=6.5,y=-3.5},get_item_count=function(n) return n=='lithium-plate' and 340 or 0 end}
  local plant
  local ins={valid=true,unit_number=8,name='fast-inserter',position={x=5.5,y=-3.5},drop_target=chest,use_filters=false}
  -- (a filter's name as a prototype, userdata in 2.0)
  local proto=io.tmpfile(); debug.setmetatable(proto,{__index={name='iron-plate'}})
  local blocked={valid=true,unit_number=9,name='inserter',position={x=3.5,y=-1.5},drop_target=chest,use_filters=true,inserter_filter_mode='whitelist',
    get_filter=function(i) return i==1 and {name=proto} or nil end}
  local surface={find_entities_filtered=function() return {ins,blocked} end}
  plant={valid=true,name='foundry',type='assembling-machine',position={x=3.5,y=-3.5},force=force,surface=surface,
    bounding_box={left_top={x=2,y=-5},right_bottom={x=5,y=-2}},get_recipe=function() return {name='molten-lithium'} end}
  ins.pickup_target=plant; blocked.pickup_target=plant
  local ST=require('stock'){integer=function(v,d) return v or d end}
  local tk=ST.output_takers(plant,'lithium-plate')
  eq(tk.line,'1 inserter takes lithium-plate from its output as it is made: fast-inserter (5.5,-3.5) into steel-chest (6.5,-3.5) (holds 340 lithium-plate)')
  eq(tk.chests[1].holds,340)
  -- the whitelist naming iron-plate by a userdata prototype lets iron-plate through
  has(ST.output_takers(plant,'iron-plate').line,'2 inserters take iron-plate')
  local _,out=ST.start_wait({position={x=0,y=0},force=force,can_reach_entity=function() return true end},{item='lithium-plate',count=100},plant,600)
  eq(out.taken_by_inserters,tk.line); eq(out.follow_chests,'follow: true takes from steel-chest (6.5,-3.5) instead')
end
print('d15_batch3 5 collect output takers: ok')
