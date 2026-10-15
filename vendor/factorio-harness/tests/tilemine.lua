-- Run from repository root: lua tests/tilemine.lua
-- Tiles mined by hand (tilemine.lua; Sol, operator 15:30: landfill under an old pole at (194,58) kept a 3x3 planting
-- cell off the yumako farm): the checks, the mining time, the product and the tile put back, the timed action, the dry
-- run. LuaControl.mine_tile returns false for a character without a player on 2.0.77, so the harness mines itself.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function mask(...) local l={} for _,k in ipairs({...}) do l[k]=true end return {layers=l} end
prototypes={tile={
  ['wetland-yumako']={name='wetland-yumako',collision_mask=mask('floor','resource','water_tile'),mineable_properties={minable=false}},
  water={name='water',collision_mask=mask('item','player','resource','water_tile'),mineable_properties={minable=false}},
  ['grass-1']={name='grass-1',collision_mask=mask('ground_tile'),mineable_properties={minable=false}},
  landfill={name='landfill',collision_mask=mask('ground_tile'),mineable_properties={minable=true,mining_time=0.5,products={{type='item',name='landfill',amount=1}}}},
  concrete={name='concrete',collision_mask=mask('ground_tile'),mineable_properties={minable=true,mining_time=0.1,products={{type='item',name='concrete',amount=1}}}},
  ['stone-path']={name='stone-path',collision_mask=mask('ground_tile'),mineable_properties={minable=true,mining_time=0.1,products={{type='item',name='stone-brick',amount=1}}}}}}
game={tick=100}
-- The world: tiles by "x,y" {name, hidden, double}; entities with boxes.
local tiles,ents={}, {}
local function lay(x,y,name,hidden,double) tiles[x..','..y]={name=name,hidden=hidden,double=double} end
local function tile_at(x,y) return tiles[x..','..y] or {name='grass-1'} end
local set_calls,hidden_calls={},{}
local surface={
  get_tile=function(x,y)
    local t=tile_at(x,y)
    return {valid=true,name=t.name,hidden_tile=t.hidden,double_hidden_tile=t.double,prototype=prototypes.tile[t.name],position={x=x,y=y}}
  end,
  find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(ents) do
      if e.valid then
        local b=e.bounding_box
        local a=f.area
        local hit=b.right_bottom.x>a[1][1] and b.left_top.x<a[2][1] and b.right_bottom.y>a[1][2] and b.left_top.y<a[2][2]
        if hit and (f.type==nil or f.type==e.type) then out[#out+1]=e end
      end
    end
    return out
  end,
  set_tiles=function(list) for _,t in ipairs(list) do local x,y=t.position[1],t.position[2]; local was=tile_at(x,y); set_calls[#set_calls+1]=t.name; tiles[x..','..y]={name=t.name,hidden=was.hidden} end end,
  set_hidden_tile=function(pos,name) hidden_calls[#hidden_calls+1]=tostring(name); local t=tiles[pos[1]..','..pos[2]]; if t then t.hidden=name end end,
  set_double_hidden_tile=function(pos,name) local t=tiles[pos[1]..','..pos[2]]; if t then t.double=name end end,
}
local function entity(name,type_,x,y,half)
  local e={valid=true,name=name,type=type_,position={x=x,y=y},
    bounding_box={left_top={x=x-half,y=y-half},right_bottom={x=x+half,y=y+half}}}
  e.destroy=function() e.valid=false end
  ents[#ents+1]=e
  return e
end
local held={}
local room=true
local inv={can_insert=function() return room end,insert=function(s) held[s.name]=(held[s.name] or 0)+s.count; return s.count end}
local p={surface=surface,position={x=195.1,y=54.6},reach_distance=10,force={manual_mining_speed_modifier=1},
  character={valid=true,prototype={mining_speed=0.5},character_mining_speed_modifier=0},
  get_main_inventory=function() return inv end,get_item_count=function(n) return held[n] or 0 end}
local navs={}
local T=dofile('mod/agent-harness_0.1.0/tilemine.lua'){
  position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  charted=function() return true end,
  request_path=function(_,nav) navs[#navs+1]=nav end,
  navigate=function(_,nav) if nav.arrive then return nav.arrive end end,
  stop_walking=function() end}

-- Sol's tile: landfill on wetland, the old pole on it.
lay(194,58,'landfill','wetland-yumako')
local pole=entity('small-electric-pole','electric-pole',194.5,58.5,0.15)
local info=T.check(p,194,58)
eq(info.why,'landfill at (194,58) has small-electric-pole (194.5,58.5) on it: mine it first'); eq(info.blocker.name,'small-electric-pole')
fails(function() T.handle(p,{tiles=true,position={x=194,y=58}}) end,'landfill at (194,58) has small-electric-pole (194.5,58.5) on it: mine it first')
-- The dry run says so and mines nothing.
local dry=T.handle(p,{tiles=true,position={x=194,y=58},dry_run=true})
eq(dry.dry_run,true); eq(dry.count,0); eq(dry.skipped[1].why,info.why); eq(#set_calls,0)
-- The pole gone: 0.5 s at mining speed 1 (0.5 x (1 + 1)), the landfill to the inventory, wetland back with nothing under it.
pole.valid=false
info=T.check(p,194,58)
eq(info.why,nil); eq(info.ticks,30); eq(info.hidden,'wetland-yumako'); eq(info.products[1].name,'landfill')
dry=T.handle(p,{tiles=true,position={x=194,y=58},dry_run=true})
eq(dry.count,1); eq(dry.tiles[1].tile,'landfill'); eq(dry.tiles[1].restores,'wetland-yumako'); eq(dry.tiles[1].seconds,0.5)
eq(dry.tiles[1].in_reach,true); eq(dry.items.landfill,1); eq(dry.note,'nothing was mined')
local reply,action=T.handle(p,{tiles=true,position={x=194.7,y=58.2}})
eq(reply.count,1); eq(action.kind,'mine'); eq(action.tiles,true); eq(action.held_before.landfill,0)
eq(T.tick(p,action),nil); eq(action.mining,130,'mining until tick 130')
game.tick=129; eq(T.tick(p,action),nil)
game.tick=130; eq(T.tick(p,action),'target_mined')
eq(tile_at(194,58).name,'wetland-yumako'); eq(tile_at(194,58).hidden,nil); eq(held.landfill,1); eq(set_calls[1],'wetland-yumako')
local last={}
T.last(action,last)
eq(last.mined,1); eq(last.tiles[1].tile,'landfill'); eq(last.tiles[1].restored,'wetland-yumako'); eq(last.items.landfill,1); eq(last.skipped,nil)
-- A natural tile is not minable; one with nothing laid under it neither.
fails(function() T.handle(p,{tiles=true,position={x=194,y=58}}) end,'wetland-yumako at (194,58) is not minable (a natural tile)')
lay(190,50,'landfill',nil)
eq(T.check(p,190,50).why,'landfill at (190,50) has no tile laid under it to put back')
-- Concrete over landfill over water: landfill goes back with water under it.
lay(196,55,'concrete','landfill','water')
reply,action=T.handle(p,{tiles=true,position={x=196,y=55}})
game.tick=200; T.tick(p,action); game.tick=action.mining; eq(T.tick(p,action),'target_mined')
eq(tile_at(196,55).name,'landfill'); eq(tile_at(196,55).hidden,'water'); eq(tile_at(196,55).double,nil); eq(held.concrete,1)
-- The character on landfill over water stands in the way (it cannot stand in water); on stone path over grass it does not.
local me=entity('character','character',196.5,55.5,0.2)
eq(T.check(p,196,55).why,'landfill at (196,55) has character (196.5,55.5) on it: mine it first')
lay(197,55,'stone-path','grass-1'); me.position={x=197.5,y=55.5}; me.bounding_box={left_top={x=197.3,y=55.3},right_bottom={x=197.7,y=55.7}}
eq(T.check(p,197,55).why,nil)
me.valid=false
-- An area: the laid tiles there (natural ones counted apart), name picks one kind, nearest first; a tile anything stands
-- on is skipped, named; a deconstruction mark on a mined tile is spent.
lay(192,59,'stone-path','grass-1'); lay(193,59,'stone-path','grass-1'); lay(194,59,'concrete','grass-1')
local chest=entity('wooden-chest','container',193.5,59.5,0.35)
local mark=entity('deconstructible-tile-proxy','deconstructible-tile-proxy',192.5,59.5,0.5)
dry=T.handle(p,{tiles=true,area={left_top={x=192,y=59},right_bottom={x=195,y=60}},name='stone-path',dry_run=true})
eq(dry.count,1); eq(dry.tiles[1].position.x,192); eq(dry.skipped[1].why,'stone-path at (193,59) has wooden-chest (193.5,59.5) on it: mine it first')
reply,action=T.handle(p,{tiles=true,area={left_top={x=192,y=59},right_bottom={x=195,y=60}}})
eq(reply.count,2); eq(#reply.skipped,1)
for _=1,20 do game.tick=game.tick+10; if T.tick(p,action) then break end end
eq(tile_at(192,59).name,'grass-1'); eq(tile_at(194,59).name,'grass-1'); eq(tile_at(193,59).name,'stone-path'); eq(mark.valid,false)
fails(function() T.handle(p,{tiles=true,area={left_top={x=0,y=0},right_bottom={x=40,y=1}}}) end,'area must be 1..32 tiles a side')
fails(function() T.handle(p,{tiles=true,area={left_top={x=160,y=40},right_bottom={x=170,y=45}}}) end,'no tile laid by a player in the area (50 natural tiles)')
-- Out of reach: refused without walk; with walk the action walks to each and mines it there.
lay(220,54,'landfill','wetland-yumako')
fails(function() T.handle(p,{tiles=true,position={x=220,y=54}}) end,'landfill at (220,54) is out of reach: 24.9 tiles from the character at (195.1,54.6) to its edge, reach 10 (walk: true walks into reach)')
reply,action=T.handle(p,{tiles=true,position={x=220,y=54},walk=true})
eq(reply.out_of_reach,1)
eq(T.tick(p,action),nil); eq(#navs,1); eq(navs[1].position.x,220.5); eq(navs[1].tolerance,8.5)
navs[1].arrive='arrived'; p.position={x=212,y=54.5}
eq(T.tick(p,action),nil); eq(action.nav,nil); eq(type(action.mining),'number')
game.tick=action.mining; eq(T.tick(p,action),'target_mined'); eq(tile_at(220,54).name,'wetland-yumako')
-- A walk that does not get there: skipped, said why.
lay(240,54,'landfill','wetland-yumako')
reply,action=T.handle(p,{tiles=true,position={x=240,y=54},walk=true})
T.tick(p,action); navs[#navs].arrive='unreachable'
eq(T.tick(p,action),'failed'); eq(action.skipped[1].why,'landfill at (240,54): not reached (unreachable)')
-- No room for the product: refused before; inventory_full if it filled meanwhile.
p.position={x=238,y=54.5}
room=false
fails(function() T.handle(p,{tiles=true,position={x=240,y=54}}) end,'no room for 1 landfill in your inventory')
room=true
reply,action=T.handle(p,{tiles=true,position={x=240,y=54}})
T.tick(p,action); room=false; game.tick=action.mining
eq(T.tick(p,action),'inventory_full'); eq(action.blocked_item,'landfill'); eq(tile_at(240,54).name,'landfill')
room=true
fails(function() T.handle(p,{tiles=true}) end,'tiles: true takes position, positions (1..64) or area')
fails(function() T.handle(p,{tiles=true,position={x=240,y=54},name='nope'}) end,'name is a tile name')
print('tilemine: ok')
