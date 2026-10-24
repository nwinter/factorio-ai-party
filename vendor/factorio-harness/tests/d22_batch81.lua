-- Run from the harness root: lua tests/d22_batch81.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path   -- (d24 batch152) modules require qflow
-- d22 batch81 AQ1 (Sol #1852): the collector tally credits a chunk only to a collector whose filters take it, does not
-- count a chunk whose drift takes it out of the reach, names the count inferred (gone_in_reach) and sets it beside the
-- platform's exact count from the production statistics.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
do
  defines={inventory={asteroid_collector_output=1},entity_status={working=1},flow_precision_index={one_minute=1,ten_minutes=3}}
  prototypes={asteroid_chunk={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={},['carbonic-asteroid-chunk']={}},
    item={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={},['carbonic-asteroid-chunk']={}}}
  game={tick=1000,surfaces={},forces={}}
  local produced={['oxide-asteroid-chunk']=0}
  local force={name='player',get_item_production_statistics=function() return {
    get_flow_count=function() return 0 end,get_input_count=function(n) return produced[n] or 0 end} end}
  game.forces.player=force
  local chunks={}
  local function chunk(name,x,y,mx,my) chunks[#chunks+1]={name=name,position={x=x,y=y},movement={mx or 0,my or 0}}; return chunks[#chunks] end
  local function inside(c,a) return c.position.x>=a.left_top.x and c.position.x<=a.right_bottom.x and c.position.y>=a.left_top.y and c.position.y<=a.right_bottom.y end
  -- Spindle's collector (5.5,-22.5) facing north, oxide only
  local col={valid=true,name='asteroid-collector',position={x=5.5,y=-22.5},direction=0,prototype={collection_box_offset=5},quality={name='normal'},status=1,
    filter_slot_count=3,get_filter=function(i) return i==1 and {name='oxide-asteroid-chunk'} or nil end,
    get_inventory=function() return {get_contents=function() return {} end} end}
  local surface={index=4,find_entities_filtered=function() return {col} end,
    get_chunks=function() local done=false; return function() if done then return nil end done=true; return {area={left_top={x=-32,y=-32},right_bottom={x=32,y=32}}} end end,
    count_tiles_filtered=function() return 1 end,
    -- the hull: y -23 and below it (the collector stands on its north edge)
    get_tile=function(x,y) return {valid=true,name=y>=-23 and 'space-platform-foundation' or 'empty-space'} end}
  game.surfaces[4]=surface
  local pl={valid=true,name='Spindle',surface=surface,force=force,
    find_asteroid_chunks_filtered=function(f) local out={} for _,c in ipairs(chunks) do if not f.area or inside(c,f.area) then out[#out+1]=c end end return out end}
  local states={}
  local C=dofile('mod/agent-harness_0.1.0/collectreach.lua'){state=function() return states end}
  -- in its reach: a metallic (its filter does not take it), an oxide at rest, an oxide drifting out at 0.1 tiles a tick
  chunk('metallic-asteroid-chunk',5.5,-26)
  chunk('oxide-asteroid-chunk',6,-27)
  chunk('oxide-asteroid-chunk',12.5,-27,0.1,0)
  -- an oxide 0.05 short of the hull's edge, drifting onto it
  chunk('oxide-asteroid-chunk',8,-23.05,0,1/60)
  -- outside: an oxide 1.5 tiles beyond the reach drifting away at 0.3 a tick (watched: 2 tiles and its drift), and one
  -- 6 beyond at rest (not watched)
  chunk('oxide-asteroid-chunk',14.5,-27,0.3,0)
  chunk('oxide-asteroid-chunk',19,-27)
  local r=C.read(pl)
  eq(r.collectors[1].in_reach,4); eq(r.collectors[1].in_reach_it_takes,3)
  has(r.collectors[1].line,'4 chunks in reach now (1 metallic-asteroid-chunk, 3 oxide-asteroid-chunk), 3 of them of a type its filters take (oxide-asteroid-chunk)')
  local p={index=2}
  C.start(p,pl,60)
  eq(#states.collector_tally[2].prev,4,'the metallic is not watched: its filters do not take it; nor the oxide 6 beyond')
  -- at the next read: the drifting oxide found 1 tile on, outside the reach (not counted); the rest gone: the metallic
  -- not credited, the one at the hull's edge struck the hull, the one drifting away gone away from every reach, the
  -- resting oxide counted; the platform collected 1 oxide
  chunks={}
  chunk('oxide-asteroid-chunk',13.5,-27,0.1,0)
  chunk('oxide-asteroid-chunk',19,-27)
  produced['oxide-asteroid-chunk']=1
  game.tick=1010; C.tick(1010)
  local t=C.tally(p,pl)
  eq(t.gone_in_reach_total,1); eq(t.collectors[1].gone_in_reach,1); eq(t.collectors[1].gone_in_reach_by_type,'1 oxide-asteroid-chunk')
  eq(t.collectors[1].filters[1],'oxide-asteroid-chunk'); eq(t.made,1); eq(t.caught,0); eq(t.inferred_minus_caught,1)
  eq(t.taken_seen,nil,'the old name is gone'); eq(t.collectors[1].taken,nil)
  eq(t.hit_hull,1); eq(t.gone_elsewhere,1)
  has(t.line,'; not counted: 1 gone on a hull tile (struck the hull), 1 gone away from every reach')
  has(t.line,'made 1 on the platform (production statistics, every chunk made there, the crushers\' returns among them: 1 oxide-asteroid-chunk), 1 more than caught; inferred: 1 gone at a collector\'s reach whose filters take them (1 more than the caught count')
  -- the platform collects 2 more metallic (another collector's, say) and nothing is seen: the difference by type
  produced['metallic-asteroid-chunk']=2
  chunks[1].position={x=14.5,y=-27}  -- where its drift puts it
  game.tick=1020; C.tick(1020)
  t=C.tally(p,pl)
  eq(t.made_minus_caught,3)
  has(t.line,'(1 more than the caught count; by type oxide-asteroid-chunk +1)')
  local m
  for _,x in ipairs(t.by_type) do if x.name=='metallic-asteroid-chunk' then m=x end end
  eq(m.inferred,0); eq(m.made,2); eq(m.caught,0); eq(m.made_minus_caught,2)
  has(t.note,'inferred, not a catch count')
  -- the filter set to metallic while the watch runs: read at each sample, a metallic in reach then gone is credited
  col.get_filter=function(i) return i==1 and {name='metallic-asteroid-chunk'} or nil end
  chunks={}
  chunk('metallic-asteroid-chunk',5.5,-26)
  game.tick=1030; C.tick(1030)
  chunks={}
  game.tick=1040; C.tick(1040)
  t=C.tally(p,pl)
  eq(t.collectors[1].filters[1],'metallic-asteroid-chunk'); eq(t.collectors[1].filters_changed,1)
  eq(t.collectors[1].gone_in_reach_by_type,'1 metallic-asteroid-chunk, 1 oxide-asteroid-chunk')
  game,defines,prototypes=nil,nil,nil
end
print('d22_batch81 AQ1 collector tally by filter, drift and the exact count: ok')
