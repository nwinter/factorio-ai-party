-- d26 batch249 (the batch227 review's R9 and R10). Run from the harness root: lua tests/d26_batch249.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function find_text(t,x,seen)
  if type(t)=='string' then return t:find(x,1,true)~=nil end
  if type(t)~='table' then return false end
  seen=seen or {}; if seen[t] then return false end; seen[t]=true
  for _,v in pairs(t) do if find_text(v,x,seen) then return true end end
  return false
end
local QUALITIES={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5},['quality-unknown']={level=0,hidden=true}}
-- As 2.0.77 counts (a copy, batch227: a chest of 600 uncommon iron-plate): a bare name is normal only, {name} every
-- quality, {name, quality} that one. stacks: {{name, quality, count}}.
local function counter(stacks)
  return function(q)
    local name,qual,any
    if type(q)=='table' then name,qual=q.name,q.quality; any=qual==nil else name,qual=q,'normal' end
    local n=0
    for _,s in ipairs(stacks) do if (name==nil or s[1]==name) and (any or s[2]==qual) then n=n+s[3] end end
    return n
  end
end

-- R10: qflow.held counts every quality and names them when any is above normal.
do
  prototypes={quality=QUALITIES}
  local Q=require('qflow'); Q.reset()
  local n,by=Q.held({get_item_count=counter({{'iron-plate','uncommon',600}})},'iron-plate')
  eq(n,600); eq(Q.label(by),'uncommon 600'); eq(Q.text(n,by),'600 (uncommon 600)')
  n,by=Q.held({get_item_count=counter({{'iron-plate','normal',5},{'iron-plate','rare',3}})},'iron-plate')
  eq(Q.text(n,by),'8 (normal 5, rare 3)')
  n,by=Q.held({get_item_count=counter({{'iron-plate','normal',5}})},'iron-plate')
  eq(n,5); eq(by,nil); eq(Q.text(n,by),'5')
  eq((Q.held({get_item_count=counter({})},'iron-plate')),0)
  local acc=Q.add(Q.add({},5,nil),3,{{quality='rare',n=3}})
  eq(Q.label(Q.by_of(acc)),'normal 5, rare 3'); eq(Q.by_of(Q.add({},4,nil)),nil)
  prototypes=nil; Q.reset()
end
print('d26_batch249 R10 qflow.held: ok')

-- R9: platform_plan {support: {positions}} takes what covers the tile at a position, as the engine finds by area (each
-- entity's box against it), not by radius (centres only): a footprint tile of a 3x3 assembler, and a tile corner of an
-- inserter's tile.
do
  prototypes={entity={}}
  local function box(x,y,h) return {left_top={x=x-h,y=y-h},right_bottom={x=x+h,y=y+h}} end
  local asm={valid=true,name='assembling-machine-3',type='assembling-machine',position={x=10.5,y=25.5},bounding_box=box(10.5,25.5,1.2),
    prototype={selectable_in_game=true}}
  local ins={valid=true,name='fast-inserter',type='inserter',position={x=-47.5,y=-37.5},bounding_box=box(-47.5,-37.5,0.15),
    prototype={selectable_in_game=true}}
  local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},bounding_box=box(0,0,2),prototype={selectable_in_game=true}}
  local ents={hub,asm,ins}
  local surface={
    find_tiles_filtered=function() return {} end,
    find_entities_filtered=function(f)
      if f.type then return {} end
      local out={}
      for _,e in ipairs(ents) do
        local b=e.bounding_box
        if f.area then
          if b.right_bottom.x>f.area[1][1] and b.left_top.x<f.area[2][1] and b.right_bottom.y>f.area[1][2] and b.left_top.y<f.area[2][2] then out[#out+1]=e end
        elseif f.position then
          if ((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5<=(f.radius or 0) then out[#out+1]=e end
        else out[#out+1]=e end
      end
      return out
    end}
  local pl={name='Asterion',surface=surface,force='us',hub=hub}
  local PP=require('platplan'){platform=function() return pl end,position=function(v) return v end}
  PP.SLICE=math.huge
  local r=PP.read({},{platform='Asterion',support={positions={{x=11.5,y=25.5}}}})
  eq(r.chosen,1); eq(r.support.footprints>=1,true)
  r=PP.read({},{platform='Asterion',support={positions={{x=-47,y=-38}}}})
  eq(r.chosen,1)
  local ok,err=pcall(PP.read,{},{platform='Asterion',support={positions={{x=50.5,y=50.5}}}})
  assert(not ok,'nothing there'); has(err,'nothing of ours at (50.5,50.5) (a position takes what of ours covers that tile, or touches that tile corner)')
  prototypes=nil
end
print('d26_batch249 R9 support positions by the tile: ok')

-- R10: where_is counts every quality (the bare name counted normal only: 600 uncommon plates read 0) and names them.
do
  game={tick=7200}
  defines={inventory={robot_cargo=9}}
  prototypes={item={['iron-plate']={get_spoil_ticks=function() return 0 end}},quality=QUALITIES}
  require('qflow').reset()
  local function holder(t,name,x,stacks) return {valid=true,type=t,name=name,position={x=x,y=0},get_item_count=counter(stacks)} end
  local chest=holder('container','storage-chest',-37.5,{{'iron-plate','uncommon',600}})
  local box=holder('container','iron-chest',10,{{'iron-plate','normal',50}})
  local surface={name='fulgora',index=3,find_entities_filtered=function() return {} end}
  local idx={holders={chest,box},belts={},hands={},as_of=3600}
  local S=dofile('mod/agent-harness_0.1.0/stores.lua'){agents=function() return {} end,where_index=function() return idx end,
    ground_index=function() return {count=0,stacks=0,cells={}} end}
  local r=S.where_is({surface=surface,force={name='player',logistic_networks={}},position={x=0,y=0},index=1},{item='iron-plate'})
  eq(r.total,650); eq(r.by_kind.chest,650)
  local q
  for _,pl in ipairs(r.places) do if pl.entity=='storage-chest' then q=pl end end
  eq(q.count,600); eq(q.qualities,'uncommon 600')
  has(r.qualities,'normal 50, uncommon 600 in the places (counts are of every quality')
  game,defines,prototypes=nil,nil,nil; require('qflow').reset()
end
print('d26_batch249 R10 where_is at every quality: ok')

-- R10: platform_plan ready: an entity ghost waits for its own quality's item; tile ghosts' foundation is counted at every
-- quality (a tile has none).
do
  prototypes={entity={},quality=QUALITIES}
  defines={inventory={hub_main=1}}
  local function box(x,y,h) return {left_top={x=x-h,y=y-h},right_bottom={x=x+h,y=y+h}} end
  local turret={valid=true,type='entity-ghost',ghost_name='gun-turret',ghost_type='ammo-turret',position={x=3,y=3},bounding_box=box(3,3,1),
    quality={name='rare'},unit_number=71,ghost_prototype={items_to_place_this={{name='gun-turret',count=1}}}}
  local tile={valid=true,type='tile-ghost',ghost_name='space-platform-foundation',position={x=2.5,y=2.5},unit_number=72,
    ghost_prototype={items_to_place_this={{name='space-platform-foundation',count=1}}}}
  local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},bounding_box=box(0,0,2)}
  local inv={get_item_count=counter({{'gun-turret','normal',5},{'gun-turret','rare',1},{'space-platform-foundation','uncommon',40}})}
  hub.get_inventory=function() return inv end
  local surface={get_tile=function() return {name='space-platform-foundation'} end,find_tiles_filtered=function() return {} end,
    find_entities_filtered=function(f)
      if f.type=='tile-ghost' then return {tile} end
      if f.type=='entity-ghost' then return {turret} end
      if f.position then
        local out={}
        for _,e in ipairs({turret,tile}) do if math.abs(e.position.x-f.position.x)<=(f.radius or 0.6) and math.abs(e.position.y-f.position.y)<=(f.radius or 0.6) then out[#out+1]=e end end
        return out
      end
      return {}
    end}
  local pl={name='Asterion',surface=surface,force='us',hub=hub}
  local PP=require('platplan'){platform=function() return pl end,position=function(v) return v end}
  PP.SLICE=math.huge
  local r=PP.read({},{platform='Asterion',ready={positions={{x=3,y=3}},tiles={left_top={x=2,y=2},right_bottom={x=3,y=3}}}})
  local by={}
  for _,row in ipairs(r.ready.items) do by[row.item]=row end
  eq(by['gun-turret@rare'].hub,1,'the rare turret ghost counts rare turrets'); eq(by['gun-turret'],nil)
  eq(by['space-platform-foundation'].hub,40,'foundation of every quality')
  prototypes,defines=nil,nil
end
print('d26_batch249 R10 platform_plan ready by quality: ok')

-- R10: a platform's defense ghosts waiting on foundation: the hub's foundation at every quality (named), and a turret
-- ghost's own quality's item.
do
  prototypes={quality=QUALITIES,entity={['gun-turret']={items_to_place_this={{name='gun-turret',count=1}}}}}
  require('qflow').reset()
  defines={space_platform_state={},rocket_silo_status={}}
  local SP=dofile('mod/agent-harness_0.1.0/space.lua')({})
  local g={valid=true,ghost_name='gun-turret',ghost_type='ammo-turret',position={x=1,y=1},quality={name='rare'},
    bounding_box={left_top={x=0,y=0},right_bottom={x=2,y=2}}}
  local pl={surface={get_tile=function(x,y) return {name=(x==0 and y==0) and 'empty-space' or 'space-platform-foundation'} end}}
  local inv={get_item_count=counter({{'space-platform-foundation','rare',30},{'gun-turret','normal',4}})}
  local line=SP.defense_waits(pl,{g},{},inv)
  has(line,'the hub holds 30 (rare 30) space-platform-foundation: the least to bring no more foundation')
  has(line,', 1 gun-turret@rare (hub has 0)')
  prototypes,defines=nil,nil; require('qflow').reset()
end
print('d26_batch249 R10 defense waits by quality: ok')

-- R10: reservations: a requester's request is read against what it holds of that request's quality.
do
  prototypes={item={['iron-plate']={}}}
  game={tick=60,get_surface=function() return nil end}
  defines={inventory={chest=1}}
  local R=dofile('mod/agent-harness_0.1.0/reservations.lua')({})
  local inv={get_item_count=counter({{'iron-plate','rare',4},{'iron-plate','normal',100}}),count_empty_stacks=function() return 3 end,
    get_insertable_count=function() return 100 end}
  local chest={valid=true,type='logistic-container',name='requester-chest',position={x=5.5,y=5.5},unit_number=9,get_inventory=function() return inv end}
  local pt={owner=chest,filters={{name='iron-plate',quality='rare',count=10}},targeted_items_deliver={}}
  local ln={valid=true,network_id=4,requester_points={pt},provider_points={},storage_points={},logistic_robots={}}
  local p={surface={name='nauvis'},force={logistic_networks={nauvis={ln}}}}
  local r=R.read(p,{network=4})
  assert(find_text(r,'iron-plate@rare asks 10, holds 4, 0 on the way'),'the rare request against rare held')
  game,defines,prototypes=nil,nil,nil
end
print('d26_batch249 R10 reservations by the request\'s quality: ok')
