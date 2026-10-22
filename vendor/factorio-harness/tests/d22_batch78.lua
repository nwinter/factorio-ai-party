package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or '')..': expected '..tostring(b)..', got '..tostring(a),2) end end

-- AN1 (#1809, Astra: Gleba had thousands of dropped items; inspect of an item-on-ground and scan's inventory and spoil
-- fields gave no stack): the stack as hovering it shows, and ground_items with the stalest freshness by item.
do
  local SPOIL={yumako=3600,['iron-plate']=0}
  local function stack(name,count,q,spoiled)
    local quality={name=q or 'normal'}
    return {valid=true,valid_for_read=true,name=name,count=count,quality=quality,spoil_percent=spoiled or 0,
      prototype={get_spoil_ticks=function(qq) assert(qq==quality); return SPOIL[name] end}}
  end
  local function ground(x,y,s) return {valid=true,type='item-entity',name='item-on-ground',position={x=x,y=y},stack=s} end
  local G=dofile('mod/agent-harness_0.1.0/groundstack.lua')
  local st=G.stack(ground(1,2,stack('yumako',3,'normal',0.385)))
  eq(st.name,'yumako'); eq(st.quality,'normal'); eq(st.count,3); eq(st.fresh,61)
  eq(G.text(st),'yumako*3'); eq(G.spoil_text(st),'yumako*3 61%'); eq(G.holds(st),'yumako*3, 61% fresh')
  st=G.stack(ground(1,2,stack('iron-plate',4,'uncommon')))
  eq(st.fresh,nil,'iron does not spoil'); eq(G.text(st),'iron-plate@uncommon*4'); eq(G.spoil_text(st),nil); eq(G.holds(st),'iron-plate@uncommon*4')
  eq(G.stack({valid=true,stack={valid_for_read=false}}),nil,'an empty stack'); eq(G.holds(nil),'empty')
  eq(G.stack({valid=true}),nil,'no stack at all')
  -- ground.lua's summary: by item, the stalest freshness of each that spoils
  local R=dofile('mod/agent-harness_0.1.0/ground.lua'){}
  local sum=R.summary({ground(0,0,stack('yumako',2,'normal',0.1)),ground(3,1,stack('yumako',5,'normal',0.5)),
    ground(1,1,stack('iron-plate',1))})
  eq(sum.stacks,3); eq(sum.items[1].name,'yumako'); eq(sum.items[1].count,7); eq(sum.items[1].fresh,50)
  eq(sum.items[2].name,'iron-plate'); eq(sum.items[2].fresh,nil)
end
print('d22_batch78 AN1 ground stacks: ok')

-- AN2 (#1774, Astra: Asterion showed about 90 chunks while 24 collectors had collected nothing for 10 minutes): the
-- chunks in view, each collector's reach, and the collector_tally watch counting chunks taken from a reach.
do
  defines={inventory={asteroid_collector_output=1},entity_status={working=1,no_power=2},
    flow_precision_index={one_minute=1,ten_minutes=3}}
  prototypes={asteroid_chunk={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={},['parameter-0']={}},
    item={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={}}}
  local st={}
  local tick=1000
  game={tick=tick,surfaces={},forces={}}
  local produced={['metallic-asteroid-chunk']=10,['oxide-asteroid-chunk']=4}
  local force={name='player',get_item_production_statistics=function() return {
    get_flow_count=function(t) return t.precision_index==1 and 1 or 3 end,
    get_input_count=function(n) return produced[n] or 0 end} end}
  game.forces.player=force
  local chunks={}
  local function chunk(name,x,y,mx,my) chunks[#chunks+1]={name=name,position={x=x,y=y},movement={mx or 0,my or 0}}; return chunks[#chunks] end
  local function inside(c,a) return c.position.x>=a.left_top.x and c.position.x<=a.right_bottom.x and c.position.y>=a.left_top.y and c.position.y<=a.right_bottom.y end
  local proto={collection_box_offset=5}
  local function collector(x,y,dir)
    return {valid=true,name='asteroid-collector',position={x=x,y=y},direction=dir,prototype=proto,quality={name='normal'},status=1,filter_slot_count=0,
      get_inventory=function() return {get_contents=function() return {} end,get_item_count=function() return 0 end} end}
  end
  local east,west=collector(53.5,119.5,4),collector(-53.5,119.5,12)
  local surface={index=7,find_entities_filtered=function(f) assert(f.type=='asteroid-collector'); return {east,west} end,
    get_chunks=function() local done=false; return function() if done then return nil end done=true; return {area={left_top={x=-64,y=96},right_bottom={x=64,y=160}}} end end,
    count_tiles_filtered=function() return 1 end}
  game.surfaces[7]=surface
  local pl={valid=true,name='Asterion',surface=surface,force=force,
    find_asteroid_chunks_filtered=function(f) local out={} for _,c in ipairs(chunks) do if not f.area or inside(c,f.area) then out[#out+1]=c end end return out end}
  local states={}
  local C=dofile('mod/agent-harness_0.1.0/collectreach.lua'){state=function() return states end}
  local r=C.reach(east); eq(r.to.x,58.5); eq(r.to.y,119.5); eq(r.from.x,53.5); eq(r.radius,7.5)
  -- within 7.5 of the line from the centre to 5 in front: 12.4 in front in, 12.7 out, 7.4 beside the centre in
  assert(C.outside(r,{x=65.9,y=119.5})<0 and C.outside(r,{x=66.2,y=119.5})>0 and C.outside(r,{x=53.8,y=126.9})<0)
  r=C.reach(west); eq(r.to.x,-58.5); eq(math.floor(r.to.y*1000+0.5)/1000,119.5)
  chunk('metallic-asteroid-chunk',60,121,0,-1/60)  -- in the east reach
  chunk('oxide-asteroid-chunk',66.5,119.5)          -- 0.5 beyond it
  chunk('metallic-asteroid-chunk',0,300)            -- out of view
  local out=C.read(pl)
  eq(out.chunks_in_view,2); eq(out.in_reach,1); eq(out.outside_reach,1)
  eq(out.view.left_top.x,-96); eq(out.view.right_bottom.y,192)
  eq(out.collectors[1].in_reach,1); eq(out.collectors[1].direction,'east'); eq(out.collectors[1].nearest_outside.outside,0.5)
  eq(out.collectors[2].in_reach,0)
  eq(out.nearest[1].outside,0); eq(out.nearest[1].drift.y,-1)
  eq(#out.collected,2,'parameter chunks left out'); eq(out.collected[1].last_1m,1)
  assert(out.lines[1]:find('2 chunks in view',1,true) and out.lines[1]:find('1 in a collector\'s reach now',1,true),out.lines[1])
  -- the tally: the chunk in reach is taken (gone at the next read); the one drifting outside stays; production counts
  local p={index=3}
  eq(C.start(p,pl,60,'test'),nil)
  local job=states.collector_tally[3]
  eq(#job.prev,1)
  table.remove(chunks,1)
  produced['metallic-asteroid-chunk']=11
  game.tick=1010; C.tick(1010)
  local t=C.tally(p,pl)
  eq(t.taken_seen,1); eq(t.collectors[1].taken,1); eq(t.collectors[1].taken_by_type,'1 metallic-asteroid-chunk'); eq(t.collected,1)
  -- a chunk drifting through a reach is not taken
  chunk('oxide-asteroid-chunk',57,119.5,1/60,0)
  game.tick=1020; C.tick(1020)
  chunks[#chunks].position={x=57+10/60,y=119.5}
  game.tick=1030; C.tick(1030)
  eq(C.tally(p,pl).taken_seen,1,'a drifting chunk found where its drift put it')
  -- measures: the watch is running, then done and read
  local Mz=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return states end}
  local w=Mz.list(3,1030)[1]
  eq(w.kind,'collector_tally'); eq(w.state,'running'); eq(w.scope,'2 collectors on Asterion')
  game.tick=tick+3600; C.tick(game.tick)
  w=Mz.list(3,game.tick)[1]
  eq(w.state,'done'); assert(w.line:find('platform_supply {platform, collection: true} reads it',1,true),w.line)
  eq(C.tally(p,pl).done,true)
  eq(Mz.list(3,game.tick)[1].final_read,true)
  game=nil; defines=nil; prototypes=nil
end
print('d22_batch78 AN2 chunks, reach and collector_tally: ok')
