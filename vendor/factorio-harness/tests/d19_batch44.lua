-- d19 batch44. Run from the harness root: lua tests/d19_batch44.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A1 (where_is: 111 ms for one Nauvis call on the private copy): with the census's index and the ground watch's bins, a
-- call finds nothing on the surface; it counts the indexed holders now, takes belts and inserter hands from the pass, and
-- says what it read from where; with no index, the reads as before.
do
  game={tick=7200}
  defines={inventory={robot_cargo=9}}
  prototypes={item={['iron-plate']={get_spoil_ticks=function() return 0 end}}}
  local function holder(t,name,x,n) return {valid=true,type=t,name=name,position={x=x,y=0},get_item_count=function() return n end} end
  local chest,furnace=holder('container','iron-chest',10,500),holder('furnace','stone-furnace',20,40)
  local finds=0
  local surface={name='nauvis',index=1,find_entities_filtered=function(f) finds=finds+1; return {} end}
  local force={name='player',logistic_networks={}}
  local idx={holders={chest,furnace},belts={['iron-plate']=600},hands={['iron-plate']=7},as_of=3600}
  local S=dofile('mod/agent-harness_0.1.0/stores.lua'){agents=function() return {} end,
    where_index=function(f,s) eq(s,surface); return idx end,
    ground_index=function(f,s,item) return {count=3,stacks=1,cells={{position={x=5,y=5},count=3,stacks=1}},as_of=5400} end}
  local p={surface=surface,force=force,position={x=0,y=0},index=1}
  local r=S.where_is(p,{item='iron-plate'})
  eq(finds,0,'no find on the surface')
  eq(r.total,1150); eq(r.by_kind.chest,500); eq(r.by_kind.machine,40); eq(r.by_kind.belts,600); eq(r.by_kind.inserter_hands,7); eq(r.by_kind.on_ground,3)
  eq(r.places[1].entity,'iron-chest'); eq(r.places[2].entity,'stone-furnace')
  has(r.read_from,'chests, machines and the other places as the census found them (60s ago, tick 3600; places built since are not in it')
  eq(r.ground_read_from,'the stacks on the ground as the ground watch last binned them (30s ago, tick 5400)')
  -- no index (before a pass, or another force): found as before
  idx=nil
  surface.find_entities_filtered=function(f) finds=finds+1; if f.type and type(f.type)=='table' and f.type[1]=='assembling-machine' then return {chest,furnace} end return {} end
  r=S.where_is(p,{item='iron-plate'})
  assert(finds>0); eq(r.read_from,nil); eq(r.by_kind.chest,500)
  game,defines,prototypes=nil,nil,nil
end
print('d19_batch44 A1 where_is from the census index: ok')

-- A1: census.where_index gives the last pass's holders still valid, its belts and hands, as_of; nil for a surface the
-- pass listed no holder on, and for a force it does not read.
do
  local st={census={done={start=900,walked={[1]=true,[3]=true},by_type={[1]={n=4,container={{valid=true},{valid=false}},furnace={{valid=true}},['rocket-silo']={{valid=true,type='rocket-silo'}},radar={{valid=true}}},[3]={n=0}},
    belt_items={[1]={coal=5}},hand_items={}}}}
  local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return st end,walk={}}
  local w=C.where_index({name='player'},{index=1})
  eq(#w.holders,3,'container, furnace and silo: the radar holds nothing'); eq(w.belts.coal,5); eq(w.as_of,900)
  eq(C.where_index({name='player'},{index=2}),nil,'not walked')
  eq(C.where_index({name='player'},{index=3}),nil,'walked, no holder: read live')
  eq(C.where_index({name='enemy'},{index=1}),nil)
  -- A2: typed lists for the handlers
  eq(#C.typed({name='player'},{index=1},'rocket-silo'),1); eq(#C.typed({name='player'},{index=1},{'radar','furnace'}),2)
  eq(#C.typed({name='player'},{index=3},'rocket-silo'),0,'walked and none: an empty list')
  eq(C.typed({name='player'},{index=2},'rocket-silo'),nil)
end
print('d19_batch44 A1 census where_index: ok')

-- A1: the ground watch's bins read for one item, cells in chunks our force sees now
do
  local st={ground_watch={player={tick=5400,items={[1]={['iron-plate']={['0,0']={x=3,y=4,count=5,stacks=1},['9,9']={x=300,y=300,count=50,stacks=2}}}}}}}
  local G=dofile('mod/agent-harness_0.1.0/ground.lua'){state=function() return st end,walk={}}
  local force={name='player',is_chunk_visible=function(_,c) return c.x<5 end}
  local g=G.on_ground_index(force,{index=1},'iron-plate')
  eq(g.count,5,'the unseen chunk left out'); eq(#g.cells,1); eq(g.as_of,5400)
  eq(G.on_ground_index(force,{index=1},'coal').count,0)
  eq(G.on_ground_index({name='enemy'},{index=1},'coal'),nil)
end
print('d19_batch44 A1 ground index: ok')

-- A2: the loss log's slots by force and surface: built once from the log, kept as rows are written, a slot written over
-- passed over; rows_in newest first, the newest row a position wins
do
  game={tick=0}
  local st={}
  local L=dofile('mod/agent-harness_0.1.0/lostlog.lua'){state=function() return st end}
  local function die(surface,name,x)
    game.tick=game.tick+1
    L.died({force={name='player'},surface={name=surface},name=name,position={x=x,y=0},supports_direction=false},'test')
  end
  for i=1,10 do die('nauvis','pipe',i) end
  local r=L.rows_in('player','nauvis')
  eq(#r,10); eq(r[1].x,10,'newest first')
  -- the index is built now; the ring wraps: 6000 more on gleba write over the nauvis slots
  for i=1,6000 do die('gleba','stone-wall',i % 50) end
  eq(#L.rows_in('player','nauvis'),0,'written over')
  eq(#L.rows_in('player','gleba'),50,'one a position')
  die('nauvis','pipe',3); die('nauvis','pipe',3)
  r=L.rows_in('player','nauvis'); eq(#r,1); eq(r[1].t,game.tick)
  game=nil
end
print('d19_batch44 A2 loss log index: ok')
