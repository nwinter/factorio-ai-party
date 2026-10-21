-- d20 batch53. Run from the harness root: lua tests/d20_batch53.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- L2 (Astra #1275): every global the runtime's modules read is one the game or Lua gives; a local moved into a do-block
-- (batch47) and still called from outside it read as a nil global (configure_check in a place_ghosts dry run).
do
  local ok=os.execute('luac -v >/dev/null 2>&1')
  if not ok then print('d20_batch53 L2 globals: skipped (no luac)') else
    local KNOWN={}
    for n in ('math ipairs string table type assert pairs game pcall tostring defines prototypes error require next tonumber rawget select '
      ..'rendering helpers storage setmetatable script log remote table_size collectgarbage load data BUNDLE_ID serpent print bit32'):gmatch('%S+') do KNOWN[n]=true end
    local dir='mod/agent-harness_0.1.0/'
    local list=io.popen('ls '..dir..'*.lua'):read('a')
    local bad={}
    for file in list:gmatch('%S+') do
      local out=io.popen('luac -p -l '..file..' 2>&1'):read('a')
      for name in out:gmatch('[GS]ETTABUP[^\n]-_ENV "([%w_]+)"') do
        if not KNOWN[name] then bad[#bad+1]=file:match('[^/]+$')..': '..name end
      end
    end
    eq(#bad,0,'globals read: '..table.concat(bad,', '))
    print('d20_batch53 L2 globals: ok')
  end
end

-- L1 (Astra #1223, Sol #1298): upgrade takes a target quality; without one each keeps its own (a bare name ordered
-- normal on 2.0.77); a locked quality is refused.
do
  prototypes={quality={normal={},uncommon={},rare={},epic={}},
    entity={['assembling-machine-2']={fast_replaceable_group='assembling-machine',collision_box={left_top={x=-1.4,y=-1.4},right_bottom={x=1.4,y=1.4}}},
      ['assembling-machine-3']={fast_replaceable_group='assembling-machine',collision_box={left_top={x=-1.4,y=-1.4},right_bottom={x=1.4,y=1.4}}}}}
  local orders={}
  local built={valid=true,type='assembling-machine',name='assembling-machine-2',quality={name='uncommon'},position={x=4.5,y=-9.5}}
  built.order_upgrade=function(o) orders[#orders+1]=o.target; return true end
  local ghost={valid=true,type='entity-ghost',ghost_name='assembling-machine-2',quality={name='normal'},position={x=-11.5,y=30.5}}
  ghost.order_upgrade=function(o) ghost.ghost_name=o.target.name; ghost.quality={name=o.target.quality}; return true end
  local list={built}
  local p={force={is_quality_unlocked=function(q) return q~='epic' end},surface={find_entities_filtered=function(f) if f.type=='entity-ghost' then return {ghost} end return list end}}
  local U=dofile('mod/agent-harness_0.1.0/upgrade.lua'){position=function(q) return q end,read_sight=function() end}
  local r=U.run(p,{position={x=4.5,y=-9.5},to='assembling-machine-3'})
  eq(orders[1].name,'assembling-machine-3'); eq(orders[1].quality,'uncommon','kept its own quality')
  has(r.line,'1 assembling-machine-3 (uncommon)')
  r=U.run(p,{position={x=4.5,y=-9.5},quality='rare'})
  eq(orders[2].name,'assembling-machine-2'); eq(orders[2].quality,'rare')
  -- the same name and quality: nothing to do
  r=U.run(p,{position={x=4.5,y=-9.5},quality='uncommon'})
  eq(#orders,2); eq(r.marked_for_upgrade,0)
  fails(function() U.run(p,{position={x=4.5,y=-9.5},quality='epic'}) end,'epic quality is not unlocked for our force')
  fails(function() U.run(p,{position={x=4.5,y=-9.5},quality='shiny'}) end,'quality must be a quality name')
  fails(function() U.run(p,{position={x=4.5,y=-9.5}}) end,'or give quality alone')
  -- a ghost changed in place: its quality read back
  list={ghost}
  r=U.run(p,{position={x=-11.5,y=30.5},to='assembling-machine-3',quality='rare'})
  eq(r.ghosts_upgraded,1); eq(ghost.ghost_name,'assembling-machine-3'); eq(ghost.quality.name,'rare')
  prototypes=nil
end
print('d20_batch53 L1 upgrade quality: ok')

-- L1: a place_ghosts entry takes quality (argshapes)
do
  local A=dofile('mod/agent-harness_0.1.0/argshapes.lua')()
  A.check('place_ghosts',{entities={{name='assembling-machine-2',position={x=1,y=2},quality='uncommon'}}})
  fails(function() A.check('place_ghosts',{entities={{name='assembling-machine-2',position={x=1,y=2},count=2}}}) end,'count is not a ghost entry field')
end
print('d20_batch53 L1 place_ghosts quality field: ok')

-- L3, L4 (Sol #1276, Astra #1035): sections and groups as 2.0.77 did them on the copy of world n.
do
  local groups={}
  local function filter(n,min) return {value={type='item',name=n,quality='normal'},min=min} end
  local function copy(t) local o={} for i,v in ipairs(t) do o[i]=v end return o end
  local force={}
  local function section(owner,index,filters)
    local s={is_manual=true,index=index,owner=owner,_filters=filters or {},_group=''}
    return setmetatable(s,{__index=function(t,k)
      if k=='filters' then return t._group~='' and groups[t._group].filters or t._filters end
      if k=='group' then return t._group end
    end,__newindex=function(t,k,v)
      if k=='group' then
        local old=t._group
        if old~='' then
          t._filters=copy(groups[old].filters)
          for i,m in ipairs(groups[old].members) do if m==t then table.remove(groups[old].members,i) break end end
        end
        if v~='' then
          if not groups[v] then groups[v]={filters=copy(t._filters),members={}} end
          table.insert(groups[v].members,t)
        end
        rawset(t,'_group',v)
      else rawset(t,k,v) end
    end})
  end
  force.get_logistic_group=function(n) return groups[n] end
  force.get_logistic_groups=function() local o={} for n in pairs(groups) do o[#o+1]=n end return o end
  force.delete_logistic_group=function(n) groups[n]=nil end
  local a={valid=true,name='requester-chest',type='logistic-container',position={x=4.5,y=-5.5},surface={name='nauvis'}}
  local b={valid=true,name='requester-chest',type='logistic-container',position={x=6.5,y=-5.5},surface={name='nauvis'}}
  local sa=section(a,1,{filter('iron-plate',10)})
  local sb=section(b,1,{filter('stone',3)})
  local G=dofile('mod/agent-harness_0.1.0/reqgroups.lua')()
  local r=G.set_group(force,sa,'stock')
  eq(r.made,true); has(r.line,'the group "stock" made from section 1\'s 1 request')
  r=G.set_group(force,sb,'stock')
  eq(r.made,nil); eq(r.dropped[1],'stone 3..inf'); has(r.line,'joined the group "stock" (1 other member)'); has(r.line,'its own stone 3..inf are gone')
  local o=G.others(force,sb)
  has(o.line,'the edit changes 1 other member too: requester-chest (4.5,-5.5) on nauvis section 1')
  local l=G.list(force)
  eq(l.groups[1].name,'stock'); eq(l.groups[1].members_count,2); eq(l.groups[1].requests[1],'iron-plate 10..inf')
  r=G.set_group(force,sb,false)
  has(r.line,'section 1 left the group "stock" and keeps its 1 request'); eq(sb.filters[1].value.name,'iron-plate')
  eq(G.others(force,sa),nil,'the only member: no other one')
  fails(function() G.set_group(force,sb,false) end,'is in no group')
  fails(function() G.set_group(force,sa,'stock') end,'in the group "stock" already')
  -- a dry run's undo: the group back, then a group it made dropped
  local snap=G.snapshot({sections_count=1,get_section=function() return sb end})
  sb.group='made-now'
  G.restore_group(force,sb,snap[1])
  G.drop_made(force,{['made-now']=true})
  eq(sb.group,''); eq(groups['made-now'],nil)
  has(G.removal(sa).line,'section 1 removed with its 1 request (it left the group "stock"; the group and its other members stay)')
end
print('d20_batch53 L3 L4 sections and groups: ok')

-- L5 (Sol #1331, viewer Foobator): a cargo wagon's slot filters and bar through train, read back.
do
  prototypes={item={['low-density-structure']={},coal={},['iron-plate']={}},quality={normal={},uncommon={}},entity={}}
  defines={inventory={cargo_wagon=1}}
  local slots,filters,bar={},{},41
  for i=1,40 do slots[i]={valid_for_read=false} end
  slots[1]={valid_for_read=true,name='coal',count=10,quality={name='normal'}}
  local inv=setmetatable({get_bar=function() return bar end,set_bar=function(n) bar=n or 41 end,
    get_filter=function(i) return filters[i] end,set_filter=function(i,f) filters[i]=f; return true end},
    {__index=function(_,i) return slots[i] end,__len=function() return 40 end})
  local loco={type='locomotive',name='locomotive'}
  local w={type='cargo-wagon',name='cargo-wagon',unit_number=7,position={x=-401,y=-400},get_inventory=function() return inv end}
  local train={carriages={loco,w}}
  local T=dofile('mod/agent-harness_0.1.0/trains.lua'){integer=function(v,d,lo,hi,name) assert(type(v)=='number' and v>=lo and v<=hi,name) return v end}
  fails(function() T.set_wagon_slots(train,w,{filters={['1']='iron-plate'}}) end,'slot 1 holds coal*10: a slot filter goes on an empty slot or one holding that item')
  eq(filters[1],nil,'nothing set on a refusal')
  local r=T.set_wagon_slots(train,loco,{wagon=2,filters={['1']='coal',['2']={name='low-density-structure',quality='uncommon'}},bar=30})
  eq(r.carriage,2); eq(r.set,2); eq(r.bar,30); eq(r.slot_filters[2],'2 low-density-structure@uncommon'); eq(bar,31)
  has(r.line,'(red-X limit: 30 usable)')
  r=T.set_wagon_slots(train,w,{filters={['2']=false},bar=false})
  eq(r.bar,'none'); eq(#r.slot_filters,1)
  fails(function() T.set_wagon_slots(train,loco,{}) end,'carriage 1 is a locomotive')
  fails(function() T.set_wagon_slots(train,w,{filters={['41']='coal'}}) end,'slot 41 is not one of 1..40')
  fails(function() T.set_wagon_slots(train,w,{limit=3}) end,'wagon_slots takes wagon, filters and bar')
  prototypes=nil; defines=nil
end
print('d20_batch53 L5 wagon slot filters and bar: ok')

-- L6 (Astra #1205): assembler_batch with the requester's trash unrequested on switches it off before the requests are
-- cleared and staged, and on after the output is released.
do
  defines={inventory={assembling_machine_input=2,assembling_machine_output=3}}
  local recipe={name='fusion-reactor',products={{type='item',name='fusion-reactor',amount=1}},ingredients={{type='item',name='tungsten-plate',amount=200}}}
  local m={valid=true,unit_number=1,name='assembling-machine-3',type='assembling-machine',position={x=22.5,y=-0.5},
    bounding_box={left_top={x=21,y=-2},right_bottom={x=24,y=1}},get_recipe=function() return recipe end,get_inventory=function() return nil end}
  local point={trash_not_requested=true}
  local req={valid=true,unit_number=2,name='requester-chest',position={x=22.5,y=-3.5},prototype={logistic_mode='requester'},
    get_item_count=function() return 0 end,get_requester_point=function() return point end}
  local input={valid=true,unit_number=3,type='inserter',position={x=22.5,y=-2.5},pickup_target=req,drop_target=m}
  local output={valid=true,unit_number=4,type='inserter',position={x=24.5,y=-0.5},pickup_target=m}
  m.surface={find_entities_filtered=function() return {input,output} end}
  local B=dofile('mod/agent-harness_0.1.0/batch.lua'){position=function(q) return q end,integer=function(v) return v end,
    entity=function() return m end,submit=function() end}
  local r=B.run({},{position={x=22.5,y=-0.5},count=1,dry_run=true})
  local labels={}
  for i,st in ipairs(r.steps) do labels[i]=st.label end
  eq(table.concat(labels,' / '),'hold output / input held / keep staged (trash unrequested off) / clear requester / stage / staged tungsten-plate / staged / input on / made / input off / release output / trash unrequested on again')
  eq(r.steps[3].args.trash_unrequested,false); eq(r.steps[12].args.trash_unrequested,true)
  eq(r.trash_unrequested,'on: switched off for the batch and on again after')
  has(r.plan[4],'requester (22.5,-3.5) has trash unrequested on')
  point.trash_not_requested=false
  r=B.run({},{position={x=22.5,y=-0.5},count=1,dry_run=true})
  eq(#r.steps,10); eq(r.trash_unrequested,'off')
  defines=nil
end
print('d20_batch53 L6 assembler_batch keeps the staged items: ok')

-- M2 (Sol #1297): supply {makers: "all"} (the census pass's makers) rates an egg breeder as inspect does: the egg a
-- craft returns gets no productivity (2.5 a craft at +50%, not 3); net per minute.
do
  defines={inventory={assembling_machine_input=2,assembling_machine_output=3,furnace_source=2,furnace_result=3},entity_status={}}
  local recipe={name='pentapod-egg',energy=15,ingredients={{type='item',name='pentapod-egg',amount=1},{type='item',name='nutrients',amount=30}},
    products={{type='item',name='pentapod-egg',amount=2,ignored_by_productivity=1}}}
  local inv={get_item_count=function() return 0 end}
  local b={valid=true,name='biochamber',type='assembling-machine',position={x=72.5,y=44.5},status='working',crafting_speed=2.6,productivity_bonus=0.5,
    bounding_box={left_top={x=71,y=43},right_bottom={x=74,y=46}},get_inventory=function() return inv end,get_recipe=function() return recipe end,
    prototype={},force={recipes={}},surface={find_entities_filtered=function() return {} end}}
  local M=dofile('mod/agent-harness_0.1.0/makersall.lua'){status_name=function(e) return e.status end}
  local r=M.row(b,recipe,'pentapod-egg')
  eq(r.per_min,26); eq(r.net_per_min,15.6); eq(r.ignored_by_productivity,1)
  has(r.line,'26 a minute (net 15.6: 10.4 a minute goes back in)')
  defines=nil
end
print('d20_batch53 M2 breeder rate as inspect: ok')

-- M4 (Astra #1200): a fire hit names what dealt it (the fire) and the game's cause, the turret whose stream lit the
-- first fire, with how far it stood against its range; nothing inferred.
do
  game={tick=600}
  local st={}
  local D=dofile('mod/agent-harness_0.1.0/damagelog.lua'){state=function() return st end,position=function(p) return p end,integer=function(v,d) return v or d end}
  local force={name='player',is_chunk_visible=function() return true end}
  local belt={valid=true,unit_number=9,name='transport-belt',force=force,surface={name='nauvis'},position={x=-116,y=509}}
  local flamer={valid=true,name='flamethrower-turret',force={name='player'},position={x=-119.5,y=423},direction=12,prototype={attack_parameters={range=30}}}
  local fire={valid=true,name='fire-flame',type='fire',position={x=-116.2,y=508.8}}
  D.on_damaged{entity=belt,cause=flamer,source=fire,damage_type={name='fire'},final_damage_amount=3,tick=600}
  local near={valid=true,unit_number=10,name='stone-wall',force=force,surface={name='nauvis'},position={x=-119.5,y=440}}
  local stream={valid=true,name='handheld-flamethrower-fire-stream',type='stream',position={x=-119.5,y=439}}
  D.on_damaged{entity=near,cause=flamer,source=stream,damage_type={name='fire'},final_damage_amount=5,tick=600}
  game.tick=660
  eq(D.of(belt)[1],'1s ago: 1 fire hit, 3 damage, from fire-flame at (-116.2,508.8), the game\'s cause: flamethrower-turret at (-119.5,423) facing west, 86 tiles from the hit (its range 30: the fire spread there from where its stream lit it)')
  eq(D.of(near)[1],'1s ago: 1 fire hit, 5 damage, from handheld-flamethrower-fire-stream at (-119.5,439), the game\'s cause: flamethrower-turret at (-119.5,423) facing west, 17 tiles from the hit (its range 30)')
end
print('d20_batch53 M4 damage source and cause: ok')

-- M1 (Sol #932): stretches standing only as ghosts are breaks, with materials and robot coverage.
do
  prototypes={entity={['transport-belt']={items_to_place_this={{name='transport-belt',count=1}}}}}
  local net={network_id=243,get_item_count=function() return 203 end,available_construction_robots=7}
  local surface={find_logistic_networks_by_construction_area=function(pos) return pos.x<0 and {net} or {} end}
  local G=dofile('mod/agent-harness_0.1.0/ghostbreaks.lua')()
  local seq={}
  for i=0,11 do seq[#seq+1]={position={x=-3.5+i,y=-28.5},ghost=(i>=3 and i<=5) or i==8,name='transport-belt'} end
  local rows,line=G.breaks(seq,surface,{})
  eq(#rows,2); eq(rows[1].tiles,3); eq(rows[1].materials['transport-belt'],3)
  eq(rows[1].robots,'1 of 3 in a construction area; network #243 holds 203 transport-belt, 7 construction robots idle')
  eq(rows[2].robots,'no roboport\'s construction area covers it: robots do not build it')
  has(line,'2 stretches of ghosts (4 tiles): a break until built: (-0.5,-28.5) to (1.5,-28.5): 3 ghost tiles carry nothing until built (3 transport-belt)')
  has(rows[2].line,'(4.5,-28.5): 1 ghost tile carries nothing until built (1 transport-belt)')
  eq(G.breaks({{ghost=false}},surface,{}),nil)
  prototypes=nil
end
print('d20_batch53 M1 ghost breaks: ok')

-- M3 (Sol #1304): uptime watches machines: status samples, shortages at the samples that read short, crafts finished.
do
  game={tick=1000}
  defines={inventory={assembling_machine_input=2,furnace_source=2}}
  local st={}
  local recipe={name='chemical-science-pack',ingredients={{type='item',name='advanced-circuit',amount=3},{type='item',name='engine-unit',amount=2}}}
  local held={['advanced-circuit']=1,['engine-unit']=4}
  local m={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=10.5,y=20.5},products_finished=100,status='working',
    get_recipe=function() return recipe end,get_inventory=function() return {get_item_count=function(n) return held[n] or 0 end} end}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() return m end,
    status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=12,productivity=0} end}
  local r=U.handler({index=1},{positions={{x=10.5,y=20.5}},seconds=10})
  eq(r.watching,true); eq(r.baseline[1],'assembling-machine-2 (10.5,20.5) chemical-science-pack: 100 completions so far (the game\'s count, productivity\'s included)')
  -- (d20 batch54 N2) the samples at a moving phase: 1067, 1134, 1201 short; from 1268 working; the last at 1600
  for t=1001,1600 do
    game.tick=t
    m.status=t<=1201 and 'item_ingredient_shortage' or 'working'
    m.products_finished=100+math.min(7,math.max(0,math.ceil((t-1201)/60)))
    U.tick(t)
  end
  local out=U.handler({index=1},{})
  eq(out.done,true); eq(out.samples,11)
  local row=out.machines[1]
  eq(row.crafts,7); eq(row.samples.working,8); eq(row.samples.item_ingredient_shortage,3)
  eq(row.short[1],'advanced-circuit short in 3 samples (least 1 of 3 a craft)')
  has(row.line,'7 crafts in 10s (42/min, 350% of its 12/min at full speed); working 73%, item ingredient shortage 27%')
  has(out.left_out,'a stop shorter than a second may not be seen')
  fails(function() U.handler({index=1},{positions={{x=1,y=1}},seconds=5}) end,'seconds: 10..3600')
  defines=nil
end
print('d20_batch53 M3 uptime: ok')
