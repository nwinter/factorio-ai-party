-- Private Factorio 2.0.77 + Space Age test. Expose this function through a
-- disposable mod's remote interface. Never run on the stream save.
-- Real engine primitives used by build_direct; runtime_test.lua exercises
-- dispatch, item consumption and the build path construct calls.
return function()
  local s=game.surfaces['rampbuild-fixture'] or game.create_surface('rampbuild-fixture',{autoplace_settings={
    entity={treat_missing_as_default=false},decorative={treat_missing_as_default=false}}})
  local pos={x=-43,y=106}
  s.request_to_generate_chunks(pos,2);s.force_generate_chunk_requests()
  for _,e in pairs(s.find_entities()) do e.destroy() end
  local tiles={};for x=-70,-20 do for y=80,135 do tiles[#tiles+1]={name='grass-1',position={x,y}} end end;s.set_tiles(tiles)
  local timer=game.create_profiler()
  for _,dir in ipairs({0,4,8,12}) do
    local args={name='rail-ramp',position=pos,direction=dir,force=game.forces.player,build_check_type=defines.build_check_type.manual}
    assert(s.can_place_entity(args),'manual placement gate')
    local e=s.create_entity(args)
    assert(e and e.direction==dir);e.destroy()
    local ghost=s.create_entity{name='entity-ghost',inner_name='rail-ramp',position=pos,direction=dir,force=game.forces.player}
    local _,revived=ghost.revive{raise_revive=true}
    assert(not ghost.valid and revived and revived.direction==dir,'revive ramp')
    revived.destroy()
  end
  timer.stop();rcon.print({'','4 manual ramp checks/builds + 4 ghost revivals: ',timer})
  local blocker=s.create_entity{name='accumulator',position={-44,104},force=game.forces.player}
  assert(not s.can_place_entity{name='rail-ramp',position=pos,direction=8,force=game.forces.player,build_check_type=defines.build_check_type.manual})
  local ghost=s.create_entity{name='entity-ghost',inner_name='rail-ramp',position=pos,direction=8,force=game.forces.player}
  local _,revived=ghost.revive{raise_revive=true}
  assert(not revived and ghost.valid and blocker.valid,'blocked revival changes neither ghost nor obstacle')
  rcon.print('rampbuild engine: all 4 headings built and revived; manual gate and revival refuse the accumulator blocker')
end
