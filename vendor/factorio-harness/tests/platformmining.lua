package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local s={}
defines={events={on_space_platform_pre_mined=1,on_space_platform_mined_entity=2}}
local function stack(name,quality,count,tag)
  local v={name=name,quality=quality,count=count or 0,valid_for_read=name~=nil,tag=tag,
    prototype={stack_size=name=='carbonic-asteroid-chunk' and 1 or 50}}
  v.clear=function() v.valid_for_read=false; v.count=0 end
  v.transfer_stack=function(from)
    local before=from.count
    v.name,v.quality,v.count,v.tag,v.valid_for_read=from.name,from.quality,math.min(before,from.prototype.stack_size),from.tag,true
    v.prototype=from.prototype
    if v.count==before then from.clear() else from.count=before-v.count end
    return v.count==before
  end
  return v
end
game={create_inventory=function(n)
  local inv={}; for i=1,n do inv[i]=stack() end
  inv.destroy=function() inv.destroyed=true end
  return inv
end}
local m=require('platformmining'){state=function() return s end}
local lanes={{stack('fusion-power-cell','rare',4,'keep')},{stack('fusion-power-cell','normal',2)}}
for _,l in ipairs(lanes) do l.valid=true end
local e={valid=true,type='transport-belt',name='transport-belt',unit_number=4,position={x=1,y=2},surface={name='platform-16'},
  get_max_inventory_index=function() return 0 end,
  get_max_transport_line_index=function() return 2 end,get_transport_line=function(i) return lanes[i] end}
local event={name=1,entity=e,platform={name='Asterion'},tick=17}
m.on_event(event)
assert(not lanes[1][1].valid_for_read and not lanes[2][1].valid_for_read)
local held=s.platform_mining.pending[4]
assert(held[1].tag=='keep' and held[1].quality=='rare')
local returned={{name='transport-belt',quality='normal',count=1}}
event.name=2; event.buffer={insert=function(v)
  returned[#returned+1]={name=v.name,quality=v.quality,count=v.count,tag=v.tag}; return v.count
end,get_contents=function()
  local rows,by={},{}
  for _,v in ipairs(returned) do
    local key=v.name..'@'..v.quality
    if not by[key] then by[key]={name=v.name,quality=v.quality,count=0}; rows[#rows+1]=by[key] end
    by[key].count=by[key].count+v.count
  end
  return rows
end}
m.on_event(event)
assert(held.destroyed and not s.platform_mining.pending[4])
assert(#returned==3 and returned[2].tag=='keep' and returned[2].count==4)
local lines=m.lines('fusion-power-cell','platform-16')
assert(#lines==1 and lines[1]:find('4 rare fusion%-power%-cell') and lines[1]:find('2 normal fusion%-power%-cell'))
assert(#m.lines('fusion-power-cell','nauvis')==0 and #m.lines('iron-plate')==0)
assert(#m.lines('transport-belt')==1)
lanes={{valid=true},{valid=true}}
event.name=1; m.on_event(event); assert(not s.platform_mining.pending[4])
event.name=2; m.on_event(event)
for i=1,40 do event.tick=i; m.on_event(event) end
assert(#s.platform_mining.returns==32 and #m.lines('transport-belt')==6)
e.type='assembling-machine'; event.name=1; m.on_event(event); assert(not s.platform_mining.pending[4])
print('platform mining: actual stacks, quality, metadata, empty belts, bounded receipts and filters passed')
-- Sparse inventories and native-returned modules are emptied before native mining,
-- so every actual stack has one owner. Empty slots need no preservation inventory.
for _,case in ipairs{
  {'fusion-reactor',1,'fusion-power-cell'}, {'reactor',6,'depleted-uranium-fuel-cell'},
  {'assembling-machine',2,'iron-plate'}, {'assembling-machine',3,'iron-gear-wheel'},
  {'assembling-machine',4,'speed-module'}, {'ammo-turret',1,'firearm-magazine'},
  {'container',1,'raw-fish'}, {'logistic-container',2,'iron-plate'},
  {'asteroid-collector',1,'carbonic-asteroid-chunk'}, {'beacon',1,'speed-module'},
  {'assembling-machine',7,'copper-plate'}, {'assembling-machine',8,'spoilage'},
} do
  for _,q in ipairs{'normal','uncommon','rare','epic','legendary'} do
    local source={stack(),stack(case[3],q,7,'exact metadata'),stack()}
    e.type=case[1]; e.name=case[1]
    e.get_max_inventory_index=function() return 8 end
    e.get_inventory=function(i) return i==case[2] and source or nil end
    event.name=1; m.on_event(event)
    assert(not source[2].valid_for_read)
    held=s.platform_mining.pending[4]
    assert(#held==math.ceil(7/source[2].prototype.stack_size) and held[1].tag=='exact metadata')
    returned={{name=e.name,quality='normal',count=1}}
    event.name=2; m.on_event(event)
    local count=0
    for i=2,#returned do
      count=count+returned[i].count
      assert(returned[i].quality==q and returned[i].tag=='exact metadata')
    end
    assert(count==7)
    assert(held.destroyed and not s.platform_mining.pending[4])
    assert(m.lines(case[3])[1]:find('7 '..q..' '..case[3],1,true))
  end
end
-- A physical belt stack can also exceed the item's inventory stack limit.
lanes={{valid=true,stack('carbonic-asteroid-chunk','epic',4,'stacked chunk')}}
e.type='transport-belt'; e.name='transport-belt'; e.get_max_inventory_index=function() return 0 end
e.get_max_transport_line_index=function() return 1 end
event.name=1; m.on_event(event)
assert(not lanes[1][1].valid_for_read and #s.platform_mining.pending[4]==4)
returned={{name=e.name,quality='normal',count=1}}
event.name=2; m.on_event(event)
assert(#returned==5 and m.lines('carbonic-asteroid-chunk')[1]:find('4 epic carbonic-asteroid-chunk',1,true))
-- Burner fuel and hand are independent owners, even when they carry the same item.
e.type='inserter'; e.name='burner-inserter'; e.held_stack=stack('coal','rare',1,'hand')
e.get_max_inventory_index=function() return 8 end
local fuel={stack('coal','rare',9,'fuel')}
e.get_inventory=function(i) return i==1 and fuel or nil end
event.name=1; m.on_event(event)
assert(not e.held_stack.valid_for_read and not fuel[1].valid_for_read)
held=s.platform_mining.pending[4]; assert(#held==2)
returned={{name=e.name,quality='normal',count=1}}
event.name=2; m.on_event(event)
assert(#returned==3 and returned[2].count+returned[3].count==10)
assert(returned[2].tag=='fuel' and returned[3].tag=='hand')
-- Non-platform events never move contents or record a return.
e.held_stack=stack('coal','legendary',1); event.platform=nil; event.name=1; m.on_event(event)
assert(e.held_stack.valid_for_read and not s.platform_mining.pending[4])
print('platform mining: all inventory kinds, all qualities, stack metadata and hands passed')
-- Old control.lua must refuse a live platform mark before changing any entity.
local ready=false
script={get_event_handler=function() return ready and function() end or nil end}
assert(not m.ready()); ready=true; assert(m.ready()); ready=false
local force={name='player',is_chunk_charted=function() return true end}
local marked=false
local belt={valid=true,minable=true,type='transport-belt',name='transport-belt',force=force,position={x=0.5,y=0.5},unit_number=7,
  to_be_deconstructed=function() return marked end,order_deconstruction=function() marked=true; return true end,
  cancel_deconstruction=function() marked=false end}
local surface={platform={force=force},find_entities_filtered=function() return {belt} end}
local player={surface=surface,force=force,position={x=0,y=0}}
local H=require('blueprints'){position=function(p) return p end,real=function(p) return p end,platform_mining=function() return m end}
m.preflight=function() return {safe=true,lines={}} end -- capacity/atomicity exercised by platformmining_preflight.lua
local args={positions={{x=0.5,y=0.5}},entity_names={'transport-belt'}}
local ok,err=pcall(H.deconstruct,player,args)
assert(not ok and tostring(err):find('server restart required',1,true) and not marked,tostring(err))
args.dry_run=true; assert(H.deconstruct(player,args).would_mark==1 and not marked)
args.dry_run=nil; ready=true; assert(H.deconstruct(player,args).changed==1 and marked)
ready=false; assert(H.cancel_deconstruction(player,args).changed==1 and not marked)
print('platform mining: missing-handler refusal, dry run and cancellation passed')
for _,kind in ipairs{'fusion-reactor','assembling-machine','ammo-turret','container','inserter'} do
  belt.type=kind; belt.name=kind; args.entity_names={kind}; ready=false
  local allowed,why=pcall(H.deconstruct,player,args)
  assert(not allowed and tostring(why):find('server restart required',1,true) and not marked)
end
print('platform mining: missing-handler refusal covers inventories and hands')
