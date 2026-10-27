-- d27 batch268. Run from the harness root: lua tests/d27_batch268.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- DP (Astra #2561, shift86: 620 deconstruct calls, each a 0.2-tile area round one old pole, during power conversions
-- that keep topology and circuit anchors among hundreds of old poles): deconstruct {positions} marks the one entity at
-- each point through the same filters and refusals as an area, with a row a position (marked / missing / refused),
-- an optional expected unit_number (a stale one edits nothing there), the same rows in a dry run, and never an area.
do
  defines={input_action=setmetatable({},{__index=function(_,k) return k end})}
  game={tick=100}
  storage={agent_harness={}}
  local force={name='player'}
  force.is_chunk_charted=function(_,c) return c.x<4 end -- x >= 128 is uncharted
  local enemy={name='enemy'}
  local neutral={name='neutral'}
  local all,orders,cancels,finds={},0,0,{}
  local function ent(name,type_,x,y,unit,half,frc)
    local e={valid=true,name=name,type=type_,position={x=x,y=y},unit_number=unit,force=frc or force,minable=true,minable_flag=true,marked=false,h=half or 0.15}
    e.to_be_deconstructed=function() return e.marked end
    e.order_deconstruction=function() orders=orders+1; e.marked=true; return true end
    e.cancel_deconstruction=function() cancels=cancels+1; e.marked=false end
    all[#all+1]=e
    return e
  end
  local small=ent('small-electric-pole','electric-pole',10.5,10.5,101)
  local medium=ent('medium-electric-pole','electric-pole',12.5,10.5,102)
  local marked=ent('small-electric-pole','electric-pole',14.5,10.5,103); marked.marked=true
  local asm=ent('assembling-machine-2','assembling-machine',20.5,20.5,104,1.2)
  local theirs=ent('small-electric-pole','electric-pole',16.5,10.5,105,0.15,enemy)
  local rock=ent('big-rock','simple-entity',18.5,10.5,nil,0.8,neutral)
  -- a pole over iron ore, with an item on the ground at its centre: the ore and the item are not what the point names
  local ore=ent('iron-ore','resource',22.5,10.5,nil,0.5,neutral)
  local onore=ent('small-electric-pole','electric-pole',22.5,10.5,106)
  local item=ent('item-on-ground','item-entity',22.5,10.5,nil,0.14,neutral)
  -- two entities of ours whose boxes cover one point (a pole inside a wide entity's box)
  local wide=ent('straight-rail','straight-rail',30.5,30.5,107,1.0)
  local inrail=ent('small-electric-pole','electric-pole',30.5,30.5,108)
  local surface={name='nauvis'}
  surface.find_entities_filtered=function(f)
    finds[#finds+1]=f
    assert(f.position and not f.area,'positions look at points, never an area')
    local out={}
    for _,e in ipairs(all) do
      if e.valid and math.abs(f.position.x-e.position.x)<=e.h and math.abs(f.position.y-e.position.y)<=e.h then out[#out+1]=e end
    end
    return out
  end
  local p={index=1,force=force,surface=surface,position={x=0,y=0}}
  local H=dofile('mod/agent-harness_0.1.0/blueprints.lua'){
    position=function(v)
      if type(v)=='table' and v.x==nil and type(v[1])=='number' then v={x=v[1],y=v[2]} end
      assert(type(v)=='table' and type(v.x)=='number' and type(v.y)=='number','position requires x and y'); return {x=v.x,y=v.y} end,
    real=function(q) return q end}
  local function row(r,i) return r.positions[i] end

  -- the poles at their centres, a tile of the assembler's footprint, one stale unit_number, and nothing at a point
  local r=H.deconstruct(p,{positions={{x=10.5,y=10.5,unit_number=101},{x=12.5,y=10.5},{x=21.4,y=21.4,unit_number=104},
    {x=14.5,y=10.5},{x=10.5,y=10.5,unit_number=999},{x=40.5,y=40.5},{12.5,10.5}}})
  eq(r.changed,3,'the two poles and the assembler'); eq(orders,3)
  eq(small.marked,true); eq(medium.marked,true); eq(asm.marked,true)
  eq(#r.positions,7,'a row a position, in order')
  eq(row(r,1).status,'marked'); eq(row(r,1).entity,'small-electric-pole 101'); eq(row(r,1).at,'(10.5,10.5)')
  eq(row(r,2).status,'marked'); eq(row(r,2).entity,'medium-electric-pole 102','the entity\'s unit_number, given or not')
  eq(row(r,3).status,'marked','any point of its footprint'); eq(row(r,3).entity,'assembling-machine-2 104'); eq(row(r,3).at,'(21.4,21.4)')
  eq(row(r,4).status,'already_marked'); has(r.already_marked,'1 already marked')
  eq(row(r,5).status,'missing','a stale unit_number edits nothing'); eq(row(r,5).entity,nil)
  has(row(r,5).why,'unit_number 999 is not here (stale)'); eq(row(r,5).here,'small-electric-pole 101')
  eq(row(r,6).status,'missing'); eq(row(r,6).why,nil); eq(row(r,6).here,nil)
  eq(row(r,7).status,'marked'); eq(row(r,7).same_as,2,'the same pole as position 2, marked once')
  eq(r.by_status,'4 marked, 1 already_marked, 2 missing')
  has(r.marked_by_name,'1 small-electric-pole'); has(r.marked_by_name,'1 assembling-machine-2')
  eq(#finds,7,'one point find a position')

  -- filters: a pole the filters do not name is missing there, with what stands there
  orders=0; small.marked=false; medium.marked=false
  r=H.deconstruct(p,{positions={{x=10.5,y=10.5},{x=12.5,y=10.5}},entity_names={'medium-electric-pole'}})
  eq(r.changed,1); eq(small.marked,false); eq(medium.marked,true)
  eq(row(r,1).status,'missing'); eq(row(r,1).here,'small-electric-pole 101')
  eq(row(r,2).status,'marked')
  -- entity_types too
  medium.marked=false
  r=H.deconstruct(p,{positions={{x=10.5,y=10.5},{x=20.5,y=20.5}},entity_types={'electric-pole'}})
  eq(row(r,1).status,'marked'); eq(row(r,2).status,'missing'); eq(row(r,2).here,'assembling-machine-2 104')

  -- refusals as an area's: another force's pole; ore and an item on the ground are not the point's entity
  small.marked=false
  r=H.deconstruct(p,{positions={{x=16.5,y=10.5},{x=22.5,y=10.5},{x=18.5,y=10.5}}})
  eq(row(r,1).status,'refused'); has(row(r,1).why,'another force\'s (enemy)'); eq(theirs.marked,false)
  has(r.not_marked[1],'small-electric-pole 105 (16.5,10.5): another force\'s (enemy)')
  eq(row(r,2).status,'marked'); eq(row(r,2).entity,'small-electric-pole 106'); eq(onore.marked,true); eq(ore.marked,false); eq(item.marked,false)
  eq(row(r,3).status,'marked','a neutral rock, as an area marks it'); eq(row(r,3).entity,'big-rock'); eq(rock.marked,true)
  -- not minable now: refused with the game's reason
  small.minable=false
  r=H.deconstruct(p,{positions={{x=10.5,y=10.5}}})
  eq(row(r,1).status,'refused'); has(row(r,1).why,'not minable'); eq(small.marked,false)
  small.minable=true

  -- two entities the filters name at one point: refused, both named; unit_number or a filter picks one
  r=H.deconstruct(p,{positions={{x=30.5,y=30.5}}})
  eq(r.changed,0); eq(row(r,1).status,'refused'); has(row(r,1).why,'2 entities here the filters name (straight-rail 107, small-electric-pole 108)')
  eq(wide.marked,false); eq(inrail.marked,false)
  r=H.deconstruct(p,{positions={{x=30.5,y=30.5,unit_number=108}}})
  eq(row(r,1).status,'marked'); eq(inrail.marked,true); eq(wide.marked,false)
  inrail.marked=false
  r=H.deconstruct(p,{positions={{x=30.5,y=30.5}},entity_names={'small-electric-pole'}})
  eq(row(r,1).status,'marked'); eq(wide.marked,false)

  -- an uncharted chunk: refused there, the rest go on
  r=H.deconstruct(p,{positions={{x=130.5,y=10.5},{x=10.5,y=10.5}}})
  eq(row(r,1).status,'refused'); eq(row(r,1).why,'an uncharted chunk'); eq(row(r,2).status,'marked')

  -- dry run: the same rows, would_mark, nothing marked
  small.marked=false; medium.marked=false; orders=0
  r=H.deconstruct(p,{positions={{x=10.5,y=10.5},{x=12.5,y=10.5,unit_number=5},{x=14.5,y=10.5}},dry_run=true})
  eq(orders,0); eq(small.marked,false)
  eq(r.would_mark,1); eq(r.changed,nil)
  eq(row(r,1).status,'would_mark'); eq(row(r,2).status,'missing'); eq(row(r,3).status,'already_marked')
  eq(r.by_status,'1 would_mark, 1 already_marked, 1 missing')

  -- cancel (deconstruct cancel: true and cancel_deconstruction): cancelled, or not_marked
  r=H.deconstruct(p,{positions={{x=14.5,y=10.5},{x=10.5,y=10.5}},cancel=true})
  eq(r.cancelled,1); eq(marked.marked,false); eq(cancels,1)
  eq(row(r,1).status,'cancelled'); eq(row(r,2).status,'not_marked')
  medium.marked=true
  r=H.cancel_deconstruction(p,{positions={{x=12.5,y=10.5,unit_number=102}}})
  eq(row(r,1).status,'cancelled'); eq(medium.marked,false)

  -- the row's point as text: integers, halves, negatives and other fractions
  r=H.deconstruct(p,{positions={{x=-3,y=-0.5},{x=-12.5,y=7},{x=0.25,y=1e6-1}}})
  eq(row(r,1).at,'(-3,-0.5)'); eq(row(r,2).at,'(-12.5,7)'); eq(row(r,3).at,'(0.25,999999)')

  -- never an area: both, neither, tiles and items on the ground are refused; at most 64 points
  fails(function() H.deconstruct(p,{positions={{x=1,y=1}},area={left_top={x=0,y=0},right_bottom={x=2,y=2}}}) end,'deconstruct takes area or positions (one of them)')
  fails(function() H.deconstruct(p,{}) end,'deconstruct takes area or positions (one of them)')
  fails(function() H.deconstruct(p,{positions={{x=1,y=1}},tiles=true}) end,'positions take entities')
  fails(function() H.deconstruct(p,{positions={{x=1,y=1}},items_on_ground=true}) end,'positions take entities')
  fails(function() H.deconstruct(p,{positions={{x=1,y=1}},entity_types={'item-entity'}}) end,'positions take entities')
  local many={}
  for i=1,65 do many[i]={x=i,y=1} end
  fails(function() H.deconstruct(p,{positions=many}) end,'positions: 1..64')
  fails(function() H.deconstruct(p,{positions={}}) end,'positions: 1..64')
  fails(function() H.deconstruct(p,{positions={{x=1,y=1,unit_number='101'}}}) end,'positions[1].unit_number must be a number')
  eq(H.limits.DECON_POSITIONS,64); eq(H.limits.DECON_DRY,16)
  -- a dry run takes 16 points; marks and cancels 64
  local seventeen={}
  for i=1,17 do seventeen[i]={x=40.5+i,y=40.5} end
  fails(function() H.deconstruct(p,{positions=seventeen,dry_run=true}) end,'positions: a dry run takes 1..16 (marks and cancels 1..64)')
  eq(#H.deconstruct(p,{positions=seventeen}).positions,17)
  eq(#H.deconstruct(p,{positions=seventeen,cancel=true}).positions,17)
  game,defines,storage=nil,nil,nil
end
print('d27_batch268 DP deconstruct positions: ok')
