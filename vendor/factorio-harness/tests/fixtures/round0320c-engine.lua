-- Disposable Factorio 2.0.77 + Space Age fixture. Copy this and pathing.lua,
-- dryrun.lua and placewhy.lua into a private mod. Expose this returned function
-- through a remote interface from control.lua. Never run on the stream save.
local pathing=require('pathing'){paths=function() return {} end}
local why=require('placewhy'){}
local dry=require('dryrun'){placewhy=why,pathing=pathing,charted=function() return true end,own_platform=function() return false end}
return function()
  local s=game.surfaces['round0320c-fixture'] or game.create_surface('round0320c-fixture', {autoplace_settings={
    entity={treat_missing_as_default=false},decorative={treat_missing_as_default=false}}})
  s.request_to_generate_chunks({0,0},2);s.force_generate_chunk_requests()
  for _,e in pairs(s.find_entities()) do e.destroy() end
  local tiles={};for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name='grass-1',position={x,y}} end end;s.set_tiles(tiles)
  local f=game.forces.player
  for _,x in ipairs({-1.5,1.5}) do for y=0.5,8.5 do s.create_entity{name='stone-wall',position={x,y},force=f} end end
  for _,x in ipairs({-0.5,0.5}) do s.create_entity{name='stone-wall',position={x,8.5},force=f} end
  local c=s.create_entity{name='character',position={15,15},force=f}
  local p={surface=s,force=f,position=c.position,character=c,build_distance=10,
    get_main_inventory=function() return {get_item_count=function() return 100 end} end}
  local plan={kind='build',standing=false,entities={{index=1,name='accumulator',item='accumulator',position={x=0,y=0}}}}
  local timer=game.create_profiler();local out=dry.check(p,plan);timer.stop()
  assert(out.pockets and #out.pockets==1,helpers.table_to_json(out))
  assert(out.pockets[1].planned_boundary[1].name=='accumulator')
  rcon.print({'','first full build preview: ',timer})
  timer=game.create_profiler();for i=1,20 do assert(dry.check(p,plan).pockets) end;timer.stop()
  rcon.print({'','20 full build previews: ',timer})
  local ring={{0,0,1,28,'drill',1,base=true},{27,0,28,28,'drill',2,base=true},
    {1,0,27,1,'accumulator',3,base=true},{1,27,27,28,'accumulator',4,base=true}}
  timer=game.create_profiler();local pockets,checked=pathing.pockets(s,0.2,ring,{ignore=c,force=f});timer.stop()
  assert(checked.checked and checked.cells<=16641 and #pockets>0)
  rcon.print({'','maximum 32-tile window: ',timer})
  rcon.print(helpers.table_to_json({preview=out.pockets,check=out.pockets_checked,maximum=checked}))
end
