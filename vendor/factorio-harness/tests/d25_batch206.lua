-- Run from the harness root: lua tests/d25_batch206.lua
-- d25 batch206 QS (operator: the two costliest agent reads on world n): platform_defense, its asteroid watch read and
-- stock's elsewhere line read less, with the same replies (these checks pass on main too: what is read is unchanged). The hull's sides are kept while every foundation tile and
-- turret is as it was, and read again when one moved; a hull over a box much larger than its tiles is read as before;
-- the watch's pages keep their order (first seen, then unit) however its records come; a done watch's groups are kept
-- per filter; a chest's kind is read once a name; positions and rounds read as before.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function same(a,b,path)
  path=path or 'value'
  if type(a)~='table' or type(b)~='table' then assert(a==b,path..': '..tostring(a)..' ~= '..tostring(b)); return end
  for k,v in pairs(a) do same(v,b[k],path..'.'..tostring(k)) end
  for k in pairs(b) do assert(a[k]~=nil,path..'.'..tostring(k)..' only in the second') end
end

-- platform_defense's hull: sides as a brute force over the tiles gives them, kept and read again
do
  defines={inventory={turret_ammo=1}}
  game={tick=100}
  local finds=0
  local function turret(name,x,y,range,n)
    local t={valid=true,type='ammo-turret',name=name,position={x=x,y=y},bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}},
      prototype={attack_parameters={range=range,min_range=0}},ignore_unprioritised_targets=false,unit_number=500+x,n=n}
    t.get_inventory=function() return {get_contents=function() return t.n>0 and {{name='firearm-magazine',count=t.n}} or {} end} end
    t.get_priority_target=function() return nil end
    return t
  end
  local gun=turret('gun-turret',2.5,4.5,6,10)
  local far=turret('gun-turret',-49.5,-36,3,10)
  -- a 10x8 hull with a hole at (4,3) and a notch at (9,0)
  local set={}
  local function put(x,y) set[x..','..y]=true end
  for x=0,9 do for y=0,7 do put(x,y) end end
  set['4,3']=nil; set['9,0']=nil
  local function tiles()
    local out={}
    for k in pairs(set) do local x,y=k:match('^(-?%d+),(-?%d+)$'); out[#out+1]={position={x=tonumber(x),y=tonumber(y)}} end
    table.sort(out,function(a,b) if a.position.x~=b.position.x then return a.position.x<b.position.x end return a.position.y<b.position.y end)
    return out
  end
  local s={index=5,find_entities_filtered=function(f) if f.type=='asteroid-collector' or f.type=='inserter' then return {} end return {gun,far} end,
    find_tiles_filtered=function() finds=finds+1; return tiles() end}
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Lark',surface=s,force='f'} end,
    inventory_rounds=function(inv) local c=inv.get_contents()[1]; return c and {{name=c.name,quality='normal',count=c.count,rounds=c.count*10,magazine_size=10}} or {} end,
    rounds_text=function(rows) return rows[1] and rows[1].name..'*'..rows[1].count or nil end}
  -- a brute force: per side the edge tiles, and of them those no turret reaches, armed or not (every asteroid size alike
  -- here)
  local function brute()
    local out={}
    local sides={{0,-1,'north'},{1,0,'east'},{0,1,'south'},{-1,0,'west'}}
    for k in pairs(set) do
      local x,y=k:match('^(-?%d+),(-?%d+)$'); x,y=tonumber(x),tonumber(y)
      local reached=false
      for _,t in ipairs({gun,far}) do
        if math.sqrt((t.position.x-x-0.5)^2+(t.position.y-y-0.5)^2)<=t.prototype.attack_parameters.range then reached=true end
      end
      for _,d in ipairs(sides) do
        if not set[(x+d[1])..','..(y+d[2])] then
          local o=out[d[3]] or {edge=0,uncovered=0}; out[d[3]]=o
          o.edge=o.edge+1; if not reached then o.uncovered=o.uncovered+1 end
        end
      end
    end
    return out
  end
  local function check(r,what)
    local want=brute()
    local seen=0
    for _,row in ipairs(r.sides) do
      seen=seen+1
      eq(row.edge_tiles,want[row.side].edge,what..' '..row.side..' edge tiles')
      eq(row.uncovered,want[row.side].uncovered,what..' '..row.side..' uncovered')
    end
    eq(seen,4,what..' sides')
  end
  local r=D.read({},{platform='Lark'})
  check(r,'first read')
  local lines1=table.concat(r.lines,'\n')
  has(lines1,'2 turrets: 2 armed now')
  -- the same tiles and turrets: the kept sides, the same lines
  local r2=D.read({},{platform='Lark'})
  check(r2,'kept'); same(r2.sides,r.sides,'the kept rows'); eq(table.concat(r2.lines,'\n'),lines1)
  -- one tile moved, the count the same: read again
  set['0,7']=nil; put(10,3)
  check(D.read({},{platform='Lark'}),'a tile moved')
  -- a turret empty: the sides say what only it covered
  gun.n=0
  local r3=D.read({},{platform='Lark'})
  check(r3,'unarmed')
  local unarmed=0
  for _,row in ipairs(r3.sides) do unarmed=unarmed+(row.by_size.small.unarmed_only or 0) end
  assert(unarmed>0,'tiles covered only by the empty turret')
  gun.n=10
  -- a turret moved: read again
  gun.position={x=7.5,y=4.5}
  check(D.read({},{platform='Lark'}),'a turret moved')
  -- positions in lines as %g gives them
  has(table.concat(r3.lines,'\n'),'gun-turret (2.5,4.5)')
  -- a hull far larger than its tiles (two apart): the read by position, as before
  set={}; put(0,0); put(300,-200)
  local r4=D.read({},{platform='Lark'})
  for _,row in ipairs(r4.sides) do eq(row.edge_tiles,2,'two lone tiles: '..row.side) end
  -- a surface with no index (a mock): read each time
  s.index=nil
  check(D.read({},{platform='Lark'}),'no index')
  defines=nil; game=nil
end
print('d25_batch206 platform_defense hull kept and read again: ok')

-- the asteroid watch's pages: first seen, then unit, whatever order the records come in; a done watch's groups kept
do
  game={tick=1000}
  defines={inventory={turret_ammo=1}}
  local box={collision_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}}
  prototypes={entity={['medium-carbonic-asteroid']=box,['small-metallic-asteroid']=box}}
  local function foundation(x,y) return x>=0 and x<=19 and y>=0 and y<=39 end
  local surface={index=7,name='platform-7',platform={name='Probe6'}}
  function surface.get_chunks()
    local list={{area={left_top={x=0,y=0},right_bottom={x=32,y=32}}},{area={left_top={x=0,y=32},right_bottom={x=32,y=64}}}}
    local i=0
    return function() i=i+1; return list[i] end
  end
  function surface.count_tiles_filtered(f)
    local a=f.area
    local lt,rb=a.left_top or a[1],a.right_bottom or a[2]
    local x0,y0,x1,y1=lt.x or lt[1],lt.y or lt[2],rb.x or rb[1],rb.y or rb[2]
    for x=math.floor(x0),math.ceil(x1)-1 do for y=math.floor(y0),math.ceil(y1)-1 do if foundation(x,y) then return 1 end end end
    return 0
  end
  function surface.get_tile(x,y) return {name=foundation(x,y) and 'space-platform-foundation' or 'empty-space'} end
  game.get_surface=function(i) return i==7 and surface or nil end
  local st={}
  local api={state=function() return st end,on_platform=function() return {surface=surface,force={name='player'}} end}
  local asts={}
  local function asteroid(u,name,x,y) local e={valid=true,unit_number=u,name=name,type='asteroid',surface=surface,position={x=x,y=y}}; asts[u]=e; return e end
  local t1={valid=true,unit_number=900,name='gun-turret',type='ammo-turret',position={x=5,y=2},surface=surface,force={name='player'}}
  t1.get_inventory=function() return {get_item_count=function() return 10 end} end
  -- the find gives the asteroids highest unit first: records of one read come in that order
  surface.find_entities_filtered=function(f)
    if f.type=='asteroid' then local out={}; for _,e in pairs(asts) do if e.valid then out[#out+1]=e end end; table.sort(out,function(a,b) return a.unit_number>b.unit_number end); return out end
    return {t1}
  end
  local A=require('asteroidwatch'){state=api.state,on_platform=api.on_platform}
  A.handler({index=1},{platform='Probe6',asteroids=true,seconds=10})
  for u=40,31,-1 do asteroid(u,'medium-carbonic-asteroid',u*0.5,-30) end
  asteroid(3,'small-metallic-asteroid',1,-30)
  A.tick(1000)
  game.tick=1015
  for u=12,10,-1 do asteroid(u,'medium-carbonic-asteroid',u,-30) end
  A.tick(1015)
  game.tick=1030; A.tick(1030)
  local function units(r) local out={} for i,row in ipairs(r.trajectories) do out[i]=row.unit end return table.concat(out,',') end
  local want='31,32,33,34,35,36,37,38,39,40,10,11,12'
  local r=A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'medium-*'}})
  eq(units(r),want,'running: first seen, then unit')
  eq(units(A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'medium-*'},trajectory_limit=4,trajectory_page=3})),'39,40,10,11')
  -- a record first seen earlier coming after later ones (the full sort)
  local job=st.asteroid_watch[1]
  local early={n='medium-carbonic-asteroid',s0=900,p0={x=0,y=0},p={x=0,y=0},t=1030}
  job.asts[2]=early; job.nast=job.nast+1
  eq(units(A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'medium-*'}})),'2,'..want,'an earlier record after later ones')
  -- done: the groups kept per filter, the pages the same
  game.tick=1700; A.tick(1700)
  local d=A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'medium-*'}})
  eq(d.done,true); eq(units(d),'2,'..want)
  eq(units(A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'medium-*'},trajectory_limit=5,trajectory_page=2})),'35,36,37,38,39')
  local all=A.handler({index=1},{platform='Probe6',asteroids=true})
  eq(all.trajectory_page.total,15); eq(all.trajectories[1].unit,3,'the rarest name first')
  eq(A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'small-*'}}).trajectory_page.total,1)
  eq(units(A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'medium-*'}})),'2,'..want,'again after other filters')
  game=nil; defines=nil; prototypes=nil
end
print('d25_batch206 asteroid watch pages in order: ok')

-- elsewhere: a chest's kind by its name, read once; counts by kind as before
do
  game={tick=100}
  local reads=0
  local function chest(id,x,typ,mode,n,name)
    local proto=setmetatable({},{__index=function(_,k) if k=='logistic_mode' then reads=reads+1; return mode end end})
    return {valid=true,unit_number=id,name=name,type=typ,position={x=x,y=0},prototype=proto,get_item_count=function() return n end}
  end
  local chests={chest(1,10,'logistic-container','requester',5,'requester-chest'),chest(2,20,'logistic-container','requester',7,'requester-chest'),
    chest(3,30,'logistic-container','passive-provider',11,'passive-provider-chest'),chest(4,40,'container',nil,3,'iron-chest'),
    {valid=true,name='broken-chest',type='container',position={x=50,y=0},get_item_count=function() error('no') end}}
  local E=dofile('mod/agent-harness_0.1.0/elsewhere.lua'){chests=function() return chests end,crafters=function() return {} end}
  local line,total=E.line({name='player'},{index=3,name='gleba'},'iron-ore',nil,{x=0,y=0})
  eq(total,26)  -- a provider in no network counts as plain
  has(line,'plain chests 14 in 2'); has(line,'requester and buffer chests 12 in 2')
  assert(reads>=2)
  game=nil
end
print('d25_batch206 elsewhere kinds by name: ok')

-- census lists by force: by force_index where entities have it, else by force
do
  local p1,p2,p3={name='player',index=1},{name='enemy',index=2},{name='neutral'}
  local function e(fi,f) return {valid=true,force_index=fi,force=f} end
  local st={census={done={chests={[4]={e(1,p1),e(2,p2),e(1,p1),{valid=true,force=p2}}},crafters={[4]={e(2,p2),{valid=true,force=p1},e(3,p3)}}}}}
  local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return st end}
  eq(#C.chests_on(p1,{index=4}),2); eq(#C.chests_on(p2,{index=4}),2)
  eq(#C.crafters(p1,{index=4}),1); eq(#C.crafters(p3,{index=4}),1,'a force with no index: by force')
end
print('d25_batch206 census lists by force index: ok')

-- rounds as text: whole counts as before
do
  local V=dofile('mod/agent-harness_0.1.0/vehicles.lua'){}
  eq(V.rounds_text({{name='firearm-magazine',quality='normal',count=10,rounds=95,magazine_size=10},{name='rocket',quality='rare',count=4,rounds=4,magazine_size=1}}),
    'firearm-magazine*10 (95 rounds) rocket@rare*4')
  eq(V.rounds_text({{name='firearm-magazine',quality='normal',count=1,rounds=2.5,magazine_size=10}}),'firearm-magazine*1 (2.5 rounds)')
end
print('d25_batch206 rounds text: ok')
