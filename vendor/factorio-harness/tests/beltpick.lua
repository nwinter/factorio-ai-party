-- Run with lua tests/beltpick.lua: items off belt lanes by hand (beltpick.lua; Grok, shift13 18:20: the iron for a
-- green circuit plant sat on a full belt at (90.5,-11.5) and pickup found "no items on the ground" three times). Read
-- on world n: the belt at (90.5,-11.5) carried coal*4 on lane 1 and iron-plate*4 on lane 2, its neighbours the same.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
prototypes={item={['iron-plate']={},coal={},bioflux={},['stone-brick']={}}}
game={tick=100}
local force={name='player'}
-- A lane: items in order, each {name, quality (userdata-like in the game: here a table), count, spoil}.
local function lane(list)
  local l={items=list}
  l.get_contents=function()
    local by,out={},{}
    for _,it in ipairs(l.items) do
      if not by[it.name] then by[it.name]={name=it.name,quality='normal',count=0}; out[#out+1]=by[it.name] end
      by[it.name].count=by[it.name].count+it.count
    end
    return out
  end
  l.get_detailed_contents=function()
    local out={}
    for i,it in ipairs(l.items) do
      out[i]={stack={valid_for_read=true,name=it.name,count=it.count,quality={name='normal'},spoil_percent=it.spoil},position=i,unique_id=i}
    end
    return out
  end
  l.remove_item=function(f)
    local left=f.count
    for i=#l.items,1,-1 do end
    local keep={}
    for _,it in ipairs(l.items) do
      if left>0 and it.name==f.name then
        local k=math.min(left,it.count); it.count=it.count-k; left=left-k
      end
      if it.count>0 then keep[#keep+1]=it end
    end
    l.items=keep
    return f.count-left
  end
  return l
end
local belts={}
local function belt(x,y,l1,l2)
  local e={valid=true,name='transport-belt',type='transport-belt',position={x=x,y=y},force=force,lines={lane(l1),lane(l2)}}
  e.get_max_transport_line_index=function() return 2 end
  e.get_transport_line=function(i) return e.lines[i] end
  belts[#belts+1]=e
  return e
end
local function iron(n,spoil) return {name='iron-plate',count=n,spoil=spoil} end
local function coal(n) return {name='coal',count=n} end
belt(90.5,-11.5,{coal(4)},{iron(4)})
belt(90.5,-10.5,{coal(4)},{iron(4)})
belt(90.5,-9.5,{coal(3)},{iron(4)})
belt(91.5,-9.5,{iron(2)},{{name='stone-brick',count=2},iron(3)})
belt(91.5,-13.5,{},{})
local surface={name='nauvis'}
surface.find_entities_filtered=function(f)
  assert(f.force==force and f.type,'our belts by type')
  local out={}
  for _,e in ipairs(belts) do
    local p=e.position
    local inside
    if f.area then inside=p.x>=f.area.left_top.x and p.x<=f.area.right_bottom.x and p.y>=f.area.left_top.y and p.y<=f.area.right_bottom.y
    else inside=(p.x-f.position.x)^2+(p.y-f.position.y)^2<=f.radius^2 end
    if inside then out[#out+1]=e end
  end
  return out
end
local held,space={},1000
local p={index=1,surface=surface,force=force,position={x=80,y=-11.5},character={valid=true,prototype={item_pickup_distance=1}}}
local inserted={}
p.insert=function(s)
  local n=math.min(s.count,space)
  space=space-n
  held[s.name]=(held[s.name] or 0)+n
  inserted[#inserted+1]={name=s.name,count=n,spoil=s.spoil_percent}
  return n
end
p.remove_item=function(s) held[s.name]=(held[s.name] or 0)-s.count; space=space+s.count; return s.count end
local action
local api
api={distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end,
  position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  assert_visible=function() end,
  start=function(_,a) action=a end,
  request_path=function() end,
  -- the walk: straight to the goal, a tile a tick, arriving within tolerance
  navigate=function(pp,nav)
    local d=api.distance(pp.position,nav.position)
    if d<=nav.tolerance then return 'arrived' end
    local k=math.min(1,d-nav.tolerance+0.01)/d
    pp.position={x=pp.position.x+(nav.position.x-pp.position.x)*k,y=pp.position.y+(nav.position.y-pp.position.y)*k}
  end,
  stop_walking=function() end}
local B=dofile('mod/agent-harness_0.1.0/beltpick.lua')(api)
local function run(limit) for _=1,limit or 2000 do game.tick=game.tick+1; local o=B.tick(p,action,game.tick); if o then return o end end end

-- Refused: no such item on the belts there (they carry coal...), no belt there, item missing.
fails(function() B.pickup(p,{belt=true,item='bioflux',position={x=90.5,y=-11.5},radius=3}) end,
  'no bioflux on our belts in (87.5,-14.5)-(93.5,-8.5): they carry iron-plate*17 coal*11 stone-brick*2')
fails(function() B.pickup(p,{belt=true,item='iron-plate',position={x=0,y=0},radius=3}) end,'no belt of ours there')
fails(function() B.pickup(p,{belt=true,position={x=90.5,y=-11.5}}) end,'belt pickup needs item (or items)')

-- Grok's spot: 10 iron plates off the belts at (90.5,-11.5), walking there from 10 tiles off; the coal stays.
local r=B.pickup(p,{belt=true,item='iron-plate',count=10,position={x=90.5,y=-11.5},radius=3})
eq(r.belt_tiles,4); eq(r.on_belts,17); eq(r.count,10); assert(r.rate:find('about one item a tick',1,true),r.rate)
eq(action.kind,'pickup'); eq(action.belt,true)
local out=run()
eq(out,'picked_up'); eq(action.taken,10); eq(held['iron-plate'],10); eq(held.coal,nil,'only what was asked')
assert(api.distance(p.position,{x=90.5,y=-11.5})<=2.5,'it walked to the belts')
eq(action.picked['iron-plate'],10)
local left=0
for _,e in ipairs(belts) do for _,l in ipairs(e.lines) do for _,it in ipairs(l.items) do if it.name=='iron-plate' then left=left+it.count end end end end
eq(left,7,'17 on the belts, 10 taken')
-- the pace: 6 items each 6 ticks once there
local t0=game.tick
B.pickup(p,{belt=true,item='iron-plate',count=6,position={x=90.5,y=-11.5},radius=3})
eq(run(),'picked_up'); assert(game.tick-t0<=7,'6 items in one pick: '..(game.tick-t0))
-- Spoilage kept: a spoiling item on the belt goes in with its spoil percent.
belts[1].lines[2].items={{name='bioflux',count=3,spoil=0.42}}
B.pickup(p,{belt=true,item='bioflux',count=3,position={x=90.5,y=-11.5},radius=3})
eq(run(),'picked_up'); eq(inserted[#inserted].name,'bioflux'); eq(inserted[#inserted].spoil,0.42)
-- None left: it waits 3 s for more to come along, then ends with what it took.
B.pickup(p,{belt=true,item='iron-plate',count=500,position={x=90.5,y=-11.5},radius=3})
eq(run(),'picked_up'); eq(action.taken,1,'the last plate, then nothing came for 3 s')
belts[2].lines[2].items={iron(2)}
B.pickup(p,{belt=true,item='iron-plate',count=50,position={x=90.5,y=-11.5},radius=3})
belts[2].lines[2].items={}   -- taken by an inserter before it got there
eq(run(),'nothing_on_belts')
-- A full inventory ends it.
belts[1].lines[2].items={iron(10)}
space=3
B.pickup(p,{belt=true,item='iron-plate',count=10,position={x=90.5,y=-11.5},radius=3})
eq(run(),'inventory_full'); eq(action.taken,3)
-- to (Luna, d15 09:20): a belt-to-chest move in one walk; the chest takes what was taken at the end.
do
  belts={}
  belt(90.5,-11.5,{coal(4)},{iron(4)})
  held,space={},1000
  p.position={x=80,y=-11.5}
  local chest={valid=true,name='wooden-chest',position={x=70.5,y=-11.5},got={}}
  p.can_reach_entity=function(e) return api.distance(p.position,e.position)<=8 end
  api.chest=function(_,pos) if pos.x==70.5 then return chest end end
  api.give=function(_,e,name,n) local k=math.min(n,held[name] or 0); held[name]=(held[name] or 0)-k; e.got[name]=(e.got[name] or 0)+k; return {transferred=k} end
  local r=B.pickup(p,{belt=true,item='iron-plate',count=4,position={x=90.5,y=-11.5},radius=3,to={x=70.5,y=-11.5}})
  assert(r.to:find('wooden-chest (70.5,-11.5)',1,true),r.to)
  eq(run(),'transferred'); eq(chest.got['iron-plate'],4); eq(action.delivered['iron-plate'],4); eq(held['iron-plate'],0)
  fails(function() B.pickup(p,{belt=true,item='coal',position={x=90.5,y=-11.5},radius=3,to={x=1,y=1}}) end,'to: no chest of ours at (1,1)')
end
-- (d22 batch104 BN1, Sol #1925: "reported 200 picked, but before/after scan still 120 scrap on same 15 belts") the end
-- says each belt before and after, what came in from upstream meanwhile, and where what was taken is now; a pass over
-- belts in reach that removes nothing three times running ends it.
do
  prototypes.item.scrap={}
  defines=defines or {inventory={character_trash=8}}
  belts={}
  local b1=belt(10.5,0.5,{{name='scrap',count=4}},{{name='scrap',count=4}})
  local b2=belt(10.5,1.5,{{name='scrap',count=4}},{{name='scrap',count=4}})
  -- the character: its main inventory is `held`; the game moves scrap over the request max (0) to the trash, and robots
  -- take part of it from there (simulated after the pickup)
  local trash={}
  p.character={valid=true,prototype={item_pickup_distance=1},
    get_main_inventory=function() return {get_item_count=function(n) return held[n] or 0 end} end,
    get_inventory=function() return {get_item_count=function(n) return trash[n] or 0 end} end}
  p.position={x=10.5,y=1}; space=1000; held.scrap=0
  B.pickup(p,{belt=true,item='scrap',count=40,area={left_top={x=10,y=0},right_bottom={x=11,y=2}},ticks=600})
  eq(action.area_before,16)
  -- upstream refills b1's lane 1 every pick (a belt that moves on as it is emptied)
  local upstream=0
  local out
  for _=1,600 do
    game.tick=game.tick+1
    if game.tick%6==0 and upstream<24 then b1.lines[1].items[#b1.lines[1].items+1]={name='scrap',count=2}; upstream=upstream+2 end
    out=B.tick(p,action,game.tick)
    if out then break end
  end
  eq(out,'picked_up'); eq(action.taken,40)
  -- the game moved 30 to the trash, robots took 20 of them
  held.scrap=held.scrap-30; trash.scrap=10
  local f=B.facts(p,action)
  eq(f.area_before,16); eq(f.came_in,f.area_after+40-16,'what came in: taken less the drop'); eq(f.kept,10); eq(f.in_trash,10); eq(f.gone_from_you,20)
  assert(f.line:find('40 taken off the belts; the area held 16 before and',1,true) and f.line:find('10 in your main inventory, 10 in your trash slots, 20 gone from you (moved to the trash over a request max and taken by robots, or used)',1,true),f.line)
  eq(#f.belts,2); assert(f.belts[1]:find('(10.5,0.5) 8 -> ',1,true) or f.belts[1]:find('(10.5,1.5) 8 -> ',1,true),f.belts[1])
  -- a belt that shows the items but gives none up: three passes, then nothing_removed
  local stuck=belt(20.5,0.5,{{name='scrap',count=4}},{})
  stuck.lines[1].remove_item=function() return 0 end
  p.position={x=20.5,y=1}; held.scrap=0
  B.pickup(p,{belt=true,item='scrap',count=10,area={left_top={x=20,y=0},right_bottom={x=21,y=1}}})
  eq(run(200),'nothing_removed'); eq(action.taken,0); eq(held.scrap,0,'what went in was taken back out')
  assert(action.why:find('3 passes over 1 belt in reach removed nothing',1,true),action.why)
  print('beltpick BN1 ok: before and after, what came in, where it went; nothing removed ends it')
end
print('beltpick ok')
