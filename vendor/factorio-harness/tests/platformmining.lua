package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local s={}
defines={events={on_space_platform_pre_mined=1,on_space_platform_mined_entity=2}}
local function stack(name,quality,count,tag)
  local v={name=name,quality=quality,count=count or 0,valid_for_read=name~=nil,tag=tag}
  v.clear=function() v.valid_for_read=false; v.count=0 end
  v.transfer_stack=function(from)
    v.name,v.quality,v.count,v.tag,v.valid_for_read=from.name,from.quality,from.count,from.tag,true
    from.clear(); return true
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
  get_max_transport_line_index=function() return 2 end,get_transport_line=function(i) return lanes[i] end}
local event={name=1,entity=e,platform={name='Asterion'},tick=17}
m.on_event(event)
assert(not lanes[1][1].valid_for_read and not lanes[2][1].valid_for_read)
local held=s.platform_mining.pending[4]
assert(held[1].tag=='keep' and held[1].quality=='rare')
local returned={{name='transport-belt',quality='normal',count=1}}
event.name=2; event.buffer={insert=function(v)
  returned[#returned+1]={name=v.name,quality=v.quality,count=v.count,tag=v.tag}; return v.count
end,get_contents=function() return returned end}
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
local args={positions={{x=0.5,y=0.5}},entity_names={'transport-belt'}}
local ok,err=pcall(H.deconstruct,player,args)
assert(not ok and tostring(err):find('server restart required',1,true) and not marked,tostring(err))
args.dry_run=true; assert(H.deconstruct(player,args).would_mark==1 and not marked)
args.dry_run=nil; ready=true; assert(H.deconstruct(player,args).changed==1 and marked)
ready=false; assert(H.cancel_deconstruction(player,args).changed==1 and not marked)
print('platform mining: missing-handler refusal, dry run and cancellation passed')
