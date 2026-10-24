-- d24 batch143 PO1 (Sol #2133): Limestone's collector_tally called 7 metallic "collected" (its collectors take oxide
-- and carbonic; its reprocessing crusher returns metallic). The production statistics count every chunk made on the
-- platform, crushers' returns among them: made. What the collectors caught: each output's rise plus its inserters'
-- pickups, read under half an inserter's half turn. Run from the harness root: lua tests/d24_batch143.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end

defines={inventory={asteroid_collector_output=1},entity_status={working=1},flow_precision_index={one_minute=1,ten_minutes=3}}
prototypes={asteroid_chunk={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={},['carbonic-asteroid-chunk']={}},
  item={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={},['carbonic-asteroid-chunk']={}}}
game={tick=1000,surfaces={},forces={}}
-- what the platform made: chunks a crusher returned (metallic) among them
local produced={['oxide-asteroid-chunk']=100,['carbonic-asteroid-chunk']=50,['metallic-asteroid-chunk']=20}
local force={name='player',get_item_production_statistics=function() return {
  get_flow_count=function() return 0 end,get_input_count=function(n) return produced[n] or 0 end} end}
game.forces.player=force
-- Limestone's collector, oxide and carbonic, its output and the fast inserter taking from it (0.04 turns a tick)
local out={['oxide-asteroid-chunk']=2}
local function total() local n=0; for _,v in pairs(out) do n=n+v end; return n end
local inv={get_item_count=function(n) if n==nil then return total() end return out[n] or 0 end,get_contents=function() return {} end}
local col={valid=true,name='asteroid-collector',position={x=-6.5,y=-0.5},direction=12,prototype={collection_box_offset=5},quality={name='normal'},status=1,
  filter_slot_count=2,get_filter=function(i) return ({{name='oxide-asteroid-chunk'},{name='carbonic-asteroid-chunk'}})[i] end,
  get_inventory=function() return inv end}
local function inserter(unit,held)
  local hs={}
  setmetatable(hs,{__index=function(_,k) if k=='valid_for_read' then return held[1]~=nil elseif k=='name' then return held[1] elseif k=='count' then return held[1] and 1 or 0 end end})
  return {valid=true,unit_number=unit,name='fast-inserter',quality={name='normal'},pickup_target=col,held_stack=hs,
    prototype={get_inserter_rotation_speed=function() return 0.04 end}}
end
local hand1={'oxide-asteroid-chunk'}
local ins={inserter(301,hand1)}
local surface={index=9,find_entities_filtered=function(f) if f.type=='inserter' then return ins end return {col} end,
  get_chunks=function() local done=false; return function() if done then return nil end done=true; return {area={left_top={x=-32,y=-32},right_bottom={x=32,y=32}}} end end,
  count_tiles_filtered=function() return 1 end,get_tile=function() return {valid=true,name='empty-space'} end}
game.surfaces[9]=surface
local pl={valid=true,name='Limestone',surface=surface,force=force,find_asteroid_chunks_filtered=function() return {} end}
local states={}
local C=dofile('mod/agent-harness_0.1.0/collectreach.lua'){state=function() return states end}
local function run(to) for t=game.tick+1,to do game.tick=t; C.tick(t) end end

-- the read: the production statistics are what the platform made, crushers' returns among them
local r=C.read(pl)
eq(r.collected,nil,'not called collected')
eq(#r.made,3)
has(r.lines[2],'made on Limestone (production statistics: every chunk made on the platform, the crushers\' returns among them; what its collectors caught: seconds starts a collector_tally watch)')
has(r.note,'made: the platform\'s production statistics for chunks, every chunk made on the platform: its collectors\' catch and the crushers\' returns')

-- the watch: read every 6 ticks (half of the inserter's half turn, 12.5 ticks); the chunk held at the start is no catch
local p={index=7}
C.start(p,pl,60,'test')
eq(states.collector_tally[7].catch_every,6)
-- by 1006: the inserter dropped its chunk, one oxide arrived
hand1[1]=nil; out['oxide-asteroid-chunk']=3
run(1006)
eq(C.tally(p,pl).caught,1)
-- by 1012: it picked one up and one more arrived: the output stays at 3
hand1[1]='oxide-asteroid-chunk'
run(1012)
eq(C.tally(p,pl).caught,2,'the pickup counts')
-- by 1018: a carbonic arrived; the hand still holds its oxide (no new pickup)
out['carbonic-asteroid-chunk']=1
run(1018)
-- by 1024: a robot took 2 oxide from the output: not a catch, and not taken off it
out['oxide-asteroid-chunk']=1
run(1024)
-- the platform made 3 oxide, 1 carbonic, and 7 metallic its crusher returned
produced['oxide-asteroid-chunk']=103; produced['carbonic-asteroid-chunk']=51; produced['metallic-asteroid-chunk']=27
run(1030)
local t=C.tally(p,pl)
eq(t.collected,nil); eq(t.collected_by_type,nil); eq(t.inferred_minus_collected,nil)
eq(t.caught,3); eq(t.caught_by_type,'1 carbonic-asteroid-chunk, 2 oxide-asteroid-chunk'); eq(t.read_every,6)
eq(t.made,11); eq(t.made_minus_caught,8); eq(t.taken_otherwise,2)
eq(t.collectors[1].caught,3); eq(t.collectors[1].inserters,1); eq(t.collectors[1].taken_otherwise,2)
local m
for _,x in ipairs(t.by_type) do if x.name=='metallic-asteroid-chunk' then m=x end end
eq(m.made,7); eq(m.caught,0); eq(m.made_minus_caught,7)
has(t.line,'watching Limestone\'s 1 collectors for 0.5s of 60s: caught 3 (arrived in their outputs, read every 6 ticks: 1 carbonic-asteroid-chunk, 2 oxide-asteroid-chunk)')
has(t.line,'made 11 on the platform (production statistics, every chunk made there, the crushers\' returns among them: 7 metallic-asteroid-chunk, 3 oxide-asteroid-chunk, 1 carbonic-asteroid-chunk), 8 more than caught')
has(t.line,'2 taken from the outputs by other than their inserters (robots, a hand): not in caught')
lacks(t.line,'collected')
has(t.note,'gone_in_reach (inferred, not a catch count)')
-- an inserter built while it runs, holding a chunk when found (at the 600-tick feeder check): no catch
local hand2={'carbonic-asteroid-chunk'}
ins[2]=inserter(302,hand2)
run(1606)
eq(C.tally(p,pl).caught,3,'a new inserter\'s hand is no pickup')
eq(C.tally(p,pl).collectors[1].inserters,2)
-- one carbonic arrives (+1); then the new inserter picks it up: a chunk moved on, no new catch
hand2[1]=nil; out['carbonic-asteroid-chunk']=2
run(1612)
hand2[1]='carbonic-asteroid-chunk'; out['carbonic-asteroid-chunk']=1
run(1618)
eq(C.tally(p,pl).caught,4)
-- the watch's line in the bounded watches
local Mz=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return states end}
has(Mz.list(7,game.tick)[1].latest.line,'4 chunks caught; 0 gone inside a reach (inferred)')
game,defines,prototypes=nil,nil,nil
print('d24_batch143 PO1 made and caught: ok')
