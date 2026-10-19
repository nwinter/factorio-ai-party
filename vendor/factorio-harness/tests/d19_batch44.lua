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
  local st={census={done={start=900,holders={[1]={{valid=true},{valid=false},{valid=true}}},belt_items={[1]={coal=5}},hand_items={}}}}
  local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return st end,walk={}}
  local w=C.where_index({name='player'},{index=1})
  eq(#w.holders,2); eq(w.belts.coal,5); eq(w.as_of,900)
  eq(C.where_index({name='player'},{index=2}),nil)
  eq(C.where_index({name='enemy'},{index=1}),nil)
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
