-- Private Factorio 2.0.77 + Space Age fixture. Copy this file and the harness
-- placewhy.lua, construction.lua and dryrun.lua into a temporary mod. Its
-- control.lua can expose require('raildry-engine') as a remote-interface method.
-- Run only on a disposable save: this creates and clears its own test surface.
-- Visibility is fixture-supplied; collision queries and placement are real.
local pw = require('placewhy'){}
  local construction = require('construction'){directions={}}
  local dry = require('dryrun'){placewhy=pw,charted=function() return true end,own_platform=function() return false end,
    ghost_placeable=function(p,proto,pos,dir) return construction.ghost_placeable(p.surface,p.force,proto,pos,dir) end}
return function()
  local s = game.surfaces['raildry-fixture'] or game.create_surface('raildry-fixture', {autoplace_settings={
    entity={treat_missing_as_default=false},decorative={treat_missing_as_default=false}}})
  local f, pos, proto = game.forces.player, {x=-43,y=106}, prototypes.entity['rail-ramp']
  s.request_to_generate_chunks(pos,2); s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities()) do e.destroy() end
  local tiles = {}
  for x=-80,0 do for y=60,150 do tiles[#tiles+1]={name='grass-1',position={x,y}} end end
  s.set_tiles(tiles)
  f.technologies['cliff-explosives'].researched=true
  local function check(dir, mode)
    return s.can_place_entity{name='rail-ramp',position=pos,direction=dir,force=f,
      build_check_type=mode or defines.build_check_type.manual_ghost,forced=mode == nil}
  end
  local cases = 0
  -- Every cliff orientation at the edge: includes a rotated cliff whose
  -- centre is five tiles from the ramp, and nearby non-colliding cliffs.
  for _, o in ipairs({'west-to-east','east-to-west','north-to-south','south-to-north','west-to-north',
    'north-to-west','south-to-west','west-to-south','none-to-west','west-to-none'}) do
    local e=s.create_entity{name='cliff-fulgora',position={-38,102.5},cliff_orientation=o}
    local entities=pw.ramp_collisions(s,f,proto,pos,8)
    assert((#entities>0) == not check(8,defines.build_check_type.manual),o)
    e.destroy();cases=cases+1
  end
  -- Axis changes and grid snapping match the engine, including fractional
  -- and negative requests. Physical blockers at the edge match the engine.
  for _, dir in ipairs({0,4,8,12}) do
    for _, delta in ipairs({{-1,-1},{0,0},{0.25,-0.25},{1,1}}) do
      local requested={x=pos.x+delta[1],y=pos.y+delta[2]}
      local snapped, facing=pw.ramp_position(requested,dir+3)
      local g=s.create_entity{name='entity-ghost',inner_name='rail-ramp',position=requested,direction=dir+3,force=f}
      assert(g.position.x==snapped.x and g.position.y==snapped.y and g.direction==facing,'ramp grid')
      local box=pw.box_at(proto.collision_box,snapped,facing)
      local actual=g.bounding_box
      assert(box.left_top.x==actual.left_top.x and box.left_top.y==actual.left_top.y
        and box.right_bottom.x==actual.right_bottom.x and box.right_bottom.y==actual.right_bottom.y,'ramp box')
      g.destroy();cases=cases+1
    end
  end
  local es={}
  for _, xy in ipairs({{-44,98},{-42,98},{-44,100},{-42,100},{-44,102}}) do
    es[#es+1]=s.create_entity{name='accumulator',position=xy,force=f}
  end
  es[#es+1]=s.create_entity{name='medium-electric-pole',position={-43.5,103.5},force=f}
  es[#es+1]=s.create_entity{name='cliff-fulgora',position={-38,102.5},cliff_orientation='west-to-north'}
  local p={surface=s,force=f,position={x=-60,y=120},get_item_count=function() return 0 end}
  local plan={kind='ghosts',standing=false,entities={{index=1,name='rail-ramp',position=pos,direction=8}}}
  local function verify(expected)
    local out=dry.check(p,plan)
    assert(out.entities[1].status==expected,helpers.table_to_json(out))
    assert(#out.entities[1].collisions==7,'every collision, including the fifth accumulator, pole and cliff')
    assert(construction.ghost_placeable(s,f,proto,pos,8)==(expected=='ok'),'real placement gate')
    return out
  end
  local cold=game.create_profiler()
  local blocked=verify('blocked')
  cold.stop();rcon.print({'','first ramp preview + placement gate: ',cold})
  for i=1,4 do es[i].order_deconstruction(f) end
  verify('blocked')
  for i=5,6 do es[i].order_deconstruction(f) end
  local marked=verify('ok')
  for i=1,6 do assert(es[i].valid and es[i].to_be_deconstructed(f),'marks are still present') end
  local timer=game.create_profiler()
  for i=1,20 do verify('ok') end
  timer.stop();rcon.print({'','20 warm ramp previews + placement gates: ',timer})
  local g=s.create_entity{name='entity-ghost',inner_name='rail-ramp',position=pos,direction=8,force=f}
  assert(g and g.valid,'actual ghost creation after the shared gate')
  g.destroy()
  for _,e in ipairs(es) do e.destroy() end
  assert(dry.check(p,plan).summary=='1 placeable (of 1)','empty footprint')
  rcon.print(helpers.table_to_json({cases=cases,blocked=blocked,marked=marked,actual_ghost_placed=true}))
end
