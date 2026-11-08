package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={events={on_space_platform_pre_mined=1,on_space_platform_mined_entity=2},inventory={hub_main=1}}
script={get_event_handler=function() return function() end end}
local function quality(v) return type(v.quality)=='table' and v.quality.name or v.quality or 'normal' end
local function slot(v)
  local s={valid_for_read=false}
  s.set_stack=function(x) s.name=x.name; s.quality=quality(x); s.count=x.count; s.valid_for_read=true; s.tag=x.tag; return true end
  if v then s.set_stack(v) end
  return s
end
local function inventory(n)
  local inv={}
  for i=1,n do inv[i]=slot() end
  inv.supports_bar=function() return false end; inv.supports_filters=function() return false end
  inv.destroy=function() inv.destroyed=true end
  inv.insert=function(v)
    local left=v.count
    for _,s in ipairs(inv) do
      if s.valid_for_read and s.name==v.name and s.quality==quality(v) and s.tag==v.tag then
        local take=math.min(left,10-s.count); s.count=s.count+take; left=left-take
      end
    end
    for _,s in ipairs(inv) do
      if not s.valid_for_read and left>0 then local take=math.min(left,10); s.set_stack{name=v.name,quality=quality(v),count=take,tag=v.tag}; left=left-take end
    end
    return v.count-left
  end
  return inv
end
game={create_inventory=inventory}
local m=require('platformmining'){state=function() return {} end}
local hub=inventory(3)
local platform={hub={valid=true,get_inventory=function() return hub end}}
local force={name='player',is_chunk_charted=function() return true end}
local function entity(name,id,item)
  local inv=inventory(1); if item then inv[1].set_stack(item) end
  local e={valid=true,type='assembling-machine',name=name,unit_number=id,position={x=id,y=0},force=force,minable=true,
    prototype={mineable_properties={products={{name=name,amount=1,type='item'}}}},
    get_max_inventory_index=function() return 4 end,get_inventory=function(i) return i==2 and inv or nil end,
    get_max_transport_line_index=function() error('not connectable') end}
  e.to_be_deconstructed=function() return e.marked or false end
  e.order_deconstruction=function() e.marked=true; return true end
  e.cancel_deconstruction=function() e.marked=false end
  return e,inv
end
local a,ai=entity('machine-a',1,{name='iron-plate',quality='rare',count=4,tag='metadata'})
local b,bi=entity('machine-b',2,{name='iron-plate',quality='rare',count=4,tag='metadata'})
local result=m.preflight(platform,{a,b})
assert(result.safe and #result.entities==2 and #result.returns==3)
assert(result.lines[1]:find('4 rare iron-plate',1,true))
assert(ai[1].count==4 and bi[1].count==4 and not hub[1].valid_for_read)
hub=inventory(2)
assert(m.preflight(platform,{a}).safe and m.preflight(platform,{b}).safe)
result=m.preflight(platform,{a,b}); assert(not result.safe and #result.short>0)
hub=inventory(3); bi[1].tag='different metadata'; assert(not m.preflight(platform,{a,b}).safe); bi[1].tag='metadata'
local unknown=entity('linked-belt',3); unknown.type='linked-belt'
unknown.get_max_transport_line_index=function() return 1 end
local line={slot{name='coal',quality='epic',count=2},valid=true}
unknown.get_transport_line=function() return line end
result=m.preflight(platform,{unknown}); assert(not result.safe and result.reason:find('uncovered',1,true))
assert(result.lines[1]:find('2 epic coal',1,true))
local unread=entity('unknown-machine',4); unread.get_inventory=function() error('inventory unavailable') end
result=m.preflight(platform,{unread}); assert(not result.safe and result.entities[1].contents_unread)
assert(result.lines[1]:find('contents unread',1,true))
hub=inventory(2); for i=1,#hub do hub[i].set_stack{name='stone',count=10} end
local empty=entity('empty-machine',5)
local ghost=entity('entity-ghost',6); ghost.type='entity-ghost'
local ground_marked=false
local list={empty,ghost,a,b}
local surface={platform=platform,find_entities_filtered=function() return list end}
local p={surface=surface,force=force,position={x=0,y=0}}
local H=require('blueprints'){position=function(v) return v end,real=function(v) return v end,platform_mining=function() return m end,
  ground_mark=function() ground_marked=true end}
local args={area={left_top={x=0,y=-1},right_bottom={x=8,y=1}}}
local ok,err=pcall(H.deconstruct,p,args)
assert(not ok and tostring(err):find('nothing marked',1,true),tostring(err))
for _,e in ipairs(list) do assert(not e.marked) end
args.dry_run=true; result=H.deconstruct(p,args)
assert(not result.platform_returns.safe and #result.platform_return_lines==3)
assert(result.would_refuse and result.would_mark==0)
for _,e in ipairs(list) do assert(not e.marked) end
args.dry_run=nil; args.items_on_ground=true; args.entity_types={'assembling-machine'}
ok,err=pcall(H.deconstruct,p,args); assert(not ok and not ground_marked)
for _,e in ipairs(list) do assert(not e.marked) end
hub=inventory(8); args.items_on_ground=nil; args.entity_types=nil
assert(H.deconstruct(p,args).changed==4)
hub=inventory(1); hub[1].set_stack{name='stone',count=10}
assert(H.cancel_deconstruction(p,args).changed==4)
print('platform preflight: contents, quality, metadata, shared capacity, uncovered sources, unreadable inventory, atomic refusal, preview and cancellation passed')
