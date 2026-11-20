#!/usr/bin/env python3
"""(mt309) Stage 2's prepared mid-game save: the r307 baseline with the same base, nest and second ore field at every
spawn (task-mt309 Stage 2; layout in report-mt309 section 6b).

  stage2_save.py plan [--json]         every spawn's geometry from the r307 layout (no server)
  stage2_save.py build                 apply it to the running imac2 server (the r307 baseline loaded, no agents)
  stage2_save.py check                 read back each spawn: base output, power, nest, field, research
  stage2_save.py measure               the Stage 2 measures per force (nest left, second-field drills, losses)

Geometry. The base is axis-aligned and the same offsets from every spawn (entities cannot turn by a team's 60 or
300 degree bearing). The nest and the second field go inward, toward the map centre, in each team's own frame
(u outward along its bearing, v to its side): that is the empty direction in every r307 start (its patches sit at
u 70 v +-45, u -14 v +-80 and oil at u 140), and the way to the rivals. Natural nests within CLEAR_ENEMIES of each
start are removed, and a corridor inward is cleared of trees, rocks, cliffs and water, so each team crosses the same
ground to the same nest. Evolution is fixed (growth and expansion off) so no team's kills or pollution change the
biters another team meets; pollution attacks stay on.

build needs the claim (run_state.claim) and the 2.1.24 pins; it never saves over saves/mt.zip (game.server_save
names its own file).
"""
import argparse
import json
import math
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'tools'), str(ROOT/'tools/stream'), str(ROOT/'tools/mt')]
LAYOUT = ROOT/'docs/reports/mt307/data/map/layout.json'
TEAMS = ('green', 'yellow', 'blue')

NEST_U = -150            # nest centre, tiles from the spawn along the team's bearing (negative: inward)
FIELD_U = -270           # second field centre
FIELD = (('iron-ore', 18, 1500000, -22), ('copper-ore', 16, 1200000, 22))   # name, radius, amount, v offset
SPAWNERS = (('biter-spawner', -4, -4), ('biter-spawner', -4, 4), ('biter-spawner', 4, -4), ('spitter-spawner', 4, 4))
WORMS = (('small-worm-turret', 9, -7), ('small-worm-turret', 9, 7), ('small-worm-turret', -10, 0),
         ('medium-worm-turret', 12, 0))     # u, v from the nest centre (u > 0 faces the base)
NEST_R = 12
EVOLUTION = 0.20
CLEAR_ENEMIES = 450
CORRIDOR = (-50, -320, 70)   # u from, u to, half width
BASE_BOX = (-36, -46, 36, 40)  # x1, y1, x2, y2 from the spawn tile: cleared, then built
RESEARCH = ('automation', 'automation-2', 'electronics', 'logistics', 'logistic-science-pack', 'steel-processing',
            'fast-inserter', 'electric-energy-distribution-1', 'optics', 'military', 'military-2', 'stone-wall',
            'gun-turret', 'heavy-armor', 'physical-projectile-damage-1', 'weapon-shooting-speed-1')
KIT = (('gun-turret', 10), ('firearm-magazine', 200), ('grenade', 20), ('stone-wall', 100), ('heavy-armor', 1),
       ('submachine-gun', 1), ('electric-mining-drill', 20), ('stone-furnace', 10), ('transport-belt', 200),
       ('inserter', 50), ('small-electric-pole', 50), ('iron-plate', 400), ('copper-plate', 200))
# The base's own ore (note-mt309-d): iron and copper run short within about an hour, coal never does. A cell's ore
# drill mines 20 tiles; its furnace takes 0.3125 ore/s, so 56 a tile (1,120 a cell) lasts 60 minutes as built and 37
# at the drill's full 0.5/s.
ORE_PER_TILE = {'iron-ore': 56, 'copper-ore': 56, 'coal': 20000}
CLEAR_ORE = ('iron-ore', 'copper-ore')   # removed within CLEAR_ENEMIES of each start (r307's start patches with them)


def teams():
    lay = json.loads(LAYOUT.read_text())
    out = {}
    for t in lay['teams']:
        if t['name'] in TEAMS:
            sx, sy = t['spawns']['nauvis']
            out[t['name']] = dict(spawn=(sx, sy), bearing=t['bearing_deg'])
    return out


def local(spawn, bearing, u, v):
    b = math.radians(bearing)
    return (spawn[0] + u*math.cos(b) - v*math.sin(b), spawn[1] + u*math.sin(b) + v*math.cos(b))


def cells():
    """The base's cells as (kind, x0, y0) from the spawn tile: iron and copper smelting, magazine (ammo) cells.

    A cell (columns x0-1..x0+4, rows y0-1..y0+8): an electric drill facing south on ore (x0..x0+2, y0..y0+2) drops
    into a stone furnace (x0+1..x0+2, y0+3..y0+4); a drill facing north on coal (y0+5..y0+7) drops coal into it from
    below; an inserter at (x0+3, y0+3) moves plates east into a chest at (x0+4, y0+3) (an ammo cell: into an
    assembler making firearm magazines, then an inserter into a chest); small poles at (x0+4, y0+1) and (x0+4, y0+6).
    """
    out = [('iron', -30 + 6*i, -40) for i in range(10)]
    out += [('copper', -30 + 6*i, -27) for i in range(6)]
    out += [('ammo', 8 + 10*i, -27) for i in range(2)]
    return out


def base_entities():
    """(name, x, y, direction, extra) from the spawn tile (x, y are entity centres), and ore rectangles."""
    ents, ores = [], []
    for kind, x0, y0 in cells():
        ore = 'copper-ore' if kind == 'copper' else 'iron-ore'
        ores.append((ore, x0 - 1, y0 - 1, x0 + 3, y0 + 2))
        ores.append(('coal', x0 - 1, y0 + 5, x0 + 3, y0 + 8))
        ents += [('electric-mining-drill', x0 + 1.5, y0 + 1.5, 'south', None),
                 ('stone-furnace', x0 + 2, y0 + 4, 'north', None),
                 ('electric-mining-drill', x0 + 1.5, y0 + 6.5, 'north', None),
                 ('inserter', x0 + 3.5, y0 + 3.5, 'east', None),
                 ('small-electric-pole', x0 + 4.5, y0 + 1.5, 'north', None),
                 ('small-electric-pole', x0 + 4.5, y0 + 6.5, 'north', None)]
        if kind == 'ammo':
            ents += [('assembling-machine-2', x0 + 5.5, y0 + 3.5, 'north', {'recipe': 'firearm-magazine'}),
                     ('inserter', x0 + 7.5, y0 + 3.5, 'east', None),
                     ('iron-chest', x0 + 8.5, y0 + 3.5, 'north', None),
                     ('small-electric-pole', x0 + 8.5, y0 + 1.5, 'north', None)]
        else:
            ents.append(('iron-chest', x0 + 4.5, y0 + 3.5, 'north', None))
    # links: iron row to copper row (gap rows -31..-29), copper row to the ammo cells, then a pole line down to the
    # power block (x 6.5, y -14.5 .. 15.5, every 6 tiles; the power block's own poles join it on the server)
    ents += [('small-electric-pole', -25.5, -29.5, 'north', None), ('small-electric-pole', 6.5, -25.5, 'north', None)]
    for y in range(-15, 16, 6):
        ents.append(('small-electric-pole', 6.5, y + 0.5, 'north', None))
    ents.append(('iron-chest', -2.5, -8.5, 'north', {'kit': True}))
    return ents, ores


POWER_X, POWER_Y = 0, 20     # the power block's origin (from the spawn tile): water rows POWER_Y+6 .. +13


def plan():
    ents, ores = base_entities()
    out = {}
    for name, t in teams().items():
        s, b = t['spawn'], t['bearing']
        field = [local(s, b, FIELD_U, dv) for *_, dv in FIELD]
        nest = local(s, b, NEST_U, 0)
        out[name] = dict(
            spawn=s, bearing=b, nest=nest,
            spawners=[(n, *local(s, b, NEST_U + du, dv)) for n, du, dv in SPAWNERS],
            worms=[(n, *local(s, b, NEST_U + du, dv)) for n, du, dv in WORMS],
            field=[dict(name=n, r=r, amount=a, at=local(s, b, FIELD_U, dv)) for n, r, a, dv in FIELD],
            corridor=dict(u1=CORRIDOR[0], u2=CORRIDOR[1], half=CORRIDOR[2], bearing=b),
            distances=dict(nest=round(math.dist(s, nest)), field=round(math.dist(s, local(s, b, FIELD_U, 0))),
                           nest_to_field=FIELD_U and abs(FIELD_U - NEST_U)))
    return dict(teams=out, base=dict(entities=ents, ores=ores, box=BASE_BOX, power=(POWER_X, POWER_Y), kit=KIT,
                                     ore_per_tile=ORE_PER_TILE),
                research=RESEARCH, evolution=EVOLUTION, clear_enemies=CLEAR_ENEMIES, nest_r=NEST_R, clear_ore=CLEAR_ORE)


def overlaps(ents):
    """Pairs of base entities whose boxes overlap (tile footprints by name), for the plan's own test."""
    size = {'electric-mining-drill': (3, 3), 'stone-furnace': (2, 2), 'inserter': (1, 1), 'iron-chest': (1, 1),
            'small-electric-pole': (1, 1), 'assembling-machine-2': (3, 3)}
    boxes = []
    for n, x, y, d, _ in ents:
        w, h = size[n]
        boxes.append((n, x - w/2, y - h/2, x + w/2, y + h/2))
    bad = []
    for i, a in enumerate(boxes):
        for c in boxes[i+1:]:
            if a[1] < c[3] and c[1] < a[3] and a[2] < c[4] and c[2] < a[4]:
                bad.append((a, c))
    return bad


# ---- Lua (5.2, one line each; no -- comments) -------------------------------------------------------------------
LUA_PREP = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local out={}
game.map_settings.enemy_evolution.enabled=false; game.map_settings.enemy_expansion.enabled=false
game.forces.enemy.set_evolution_factor(P.evolution,s)
for name,t in pairs(P.teams) do
  s.request_to_generate_chunks({t.spawn[1],t.spawn[2]},math.ceil((P.clear_enemies+64)/32))
end
s.force_generate_chunk_requests()
for name,t in pairs(P.teams) do
  local n=0
  for _,e in pairs(s.find_entities_filtered{position={t.spawn[1],t.spawn[2]},radius=P.clear_enemies,force='enemy'}) do e.destroy(); n=n+1 end
  local o,ot=0,0
  for _,e in pairs(s.find_entities_filtered{position={t.spawn[1],t.spawn[2]},radius=P.clear_enemies,name=P.clear_ore}) do o=o+e.amount; ot=ot+1; e.destroy() end
  out[name]={enemies_removed=n,ore_removed=o,ore_tiles_removed=ot}
end
rcon.print(helpers.table_to_json(out))
'''

LUA_CORRIDOR = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local t=P.team; local c=t.corridor
local b=math.rad(c.bearing); local cb,sb=math.cos(b),math.sin(b)
local function uv(x,y) local dx,dy=x-t.spawn[1],y-t.spawn[2]; return dx*cb+dy*sb,-dx*sb+dy*cb end
local xs,ys={},{}
for _,u in ipairs{c.u1,c.u2} do for _,v in ipairs{-c.half,c.half} do
  xs[#xs+1]=t.spawn[1]+u*cb-v*sb; ys[#ys+1]=t.spawn[2]+u*sb+v*cb end end
local area={{math.floor(math.min(table.unpack(xs))),math.floor(math.min(table.unpack(ys)))},{math.ceil(math.max(table.unpack(xs))),math.ceil(math.max(table.unpack(ys)))}}
local inside=function(x,y) local u,v=uv(x,y); return u<=c.u1 and u>=c.u2 and math.abs(v)<=c.half end
local removed,tiles,res=0,{},0
for _,e in pairs(s.find_entities_filtered{area=area,type={'tree','simple-entity','cliff','fish','resource'}}) do
  if e.valid and inside(e.position.x,e.position.y) then if e.type=='resource' then res=res+1 end; e.destroy(); removed=removed+1 end end
for _,tl in pairs(s.find_tiles_filtered{area=area,collision_mask='water_tile'}) do
  local p=tl.position; if inside(p.x+0.5,p.y+0.5) then tiles[#tiles+1]={name='grass-1',position=p} end end
s.set_tiles(tiles,true,true,true,true)
s.destroy_decoratives{area=area}
rcon.print(helpers.table_to_json{removed=removed,resources=res,water_tiles=#tiles})
'''

LUA_PLACE = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local t=P.team; local out={spawners=0,worms=0,field={}}
for _,f in ipairs(t.field) do
  for _,e in pairs(s.find_entities_filtered{position=f.at,radius=f.r+6,type={'resource','tree','simple-entity','cliff'}}) do e.destroy() end
  local pts={}
  for dx=-f.r,f.r do for dy=-f.r,f.r do if dx*dx+dy*dy<=f.r*f.r then pts[#pts+1]={math.floor(f.at[1])+dx+0.5,math.floor(f.at[2])+dy+0.5} end end end
  local each=math.floor(f.amount/#pts)
  for _,p in ipairs(pts) do s.create_entity{name=f.name,position=p,amount=each} end
  out.field[#out.field+1]={name=f.name,tiles=#pts,amount=each*#pts}
end
for _,e in pairs(s.find_entities_filtered{position=t.nest,radius=P.nest_r+8,type={'tree','simple-entity','cliff','resource'}}) do e.destroy() end
for _,w in ipairs(t.spawners) do if s.create_entity{name=w[1],position={w[2],w[3]},force='enemy'} then out.spawners=out.spawners+1 end end
for _,w in ipairs(t.worms) do if s.create_entity{name=w[1],position={w[2],w[3]},force='enemy'} then out.worms=out.worms+1 end end
local f=game.forces[P.name]; local done={}
local function res(n) local tech=f.technologies[n]; if not tech or done[n] then return end; done[n]=true
  for pn,_ in pairs(tech.prerequisites) do res(pn) end; tech.researched=true end
for _,n in ipairs(P.research) do res(n) end
out.researched=0; for _ in pairs(done) do out.researched=out.researched+1 end
local function chart(x,y,r) f.chart(s,{{x-r,y-r},{x+r,y+r}}) end
chart(t.nest[1],t.nest[2],P.nest_r+24)
for _,fl in ipairs(t.field) do chart(fl.at[1],fl.at[2],fl.r+24) end
rcon.print(helpers.table_to_json(out))
'''

LUA_BASE = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local B=P.base; local name=P.name
local ox,oy=math.floor(P.team.spawn[1]),math.floor(P.team.spawn[2])
local box={{ox+B.box[1],oy+B.box[2]},{ox+B.box[3],oy+B.box[4]}}
for _,e in pairs(s.find_entities_filtered{area=box,type={'tree','simple-entity','cliff','fish','resource','item-entity'}}) do if e.valid then e.destroy() end end
local tiles={}
for x=box[1][1],box[2][1]-1 do for y=box[1][2],box[2][2]-1 do tiles[#tiles+1]={name='grass-1',position={x,y}} end end
s.set_tiles(tiles,true,true,true,true); s.destroy_decoratives{area=box}
local nore=0
for _,r in ipairs(B.ores) do for x=r[2],r[4] do for y=r[3],r[5] do
  s.create_entity{name=r[1],position={ox+x+0.5,oy+y+0.5},amount=B.ore_per_tile[r[1]]}; nore=nore+1 end end end
local D=defines.direction; local made,failed=0,{}
local built={}
for _,e in ipairs(B.entities) do
  local ent=s.create_entity{name=e[1],position={ox+e[2],oy+e[3]},direction=D[e[4]],force=name,raise_built=true}
  if ent then made=made+1; built[#built+1]=ent
    if e[5] and e[5].recipe then ent.set_recipe(e[5].recipe) end
  else failed[#failed+1]=e[1]..'@'..e[2]..','..e[3] end
end
for _,ent in ipairs(built) do
  if ent.type=='inserter' and ent.drop_position.x<ent.position.x then ent.direction=D.west end
  if ent.type=='inserter' and ent.drop_position.x<ent.position.x then ent.direction=D.east end
end
for _,ent in ipairs(built) do if ent.type=='furnace' then ent.insert{name='coal',count=10} end end
rcon.print(helpers.table_to_json{ore_tiles=nore,made=made,failed=failed})
'''


LUA_POWER = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local name=P.name; local f=game.forces[name]
local ox,oy=math.floor(P.team.spawn[1])+P.base.power[1],math.floor(P.team.spawn[2])+P.base.power[2]
local D=defines.direction; local dirs={D.north,D.east,D.south,D.west}; local log={}
local water={}
for x=ox-6,ox+5 do for y=oy+6,oy+13 do water[#water+1]={name='water',position={x,y}} end end
s.set_tiles(water,true,true,true,true)
local pump
for dx=0,6 do for _,sx in ipairs{1,-1} do for _,d in ipairs(dirs) do
  local p={ox+sx*dx+0.5,oy+5.5}
  if not pump and s.can_place_entity{name='offshore-pump',position=p,direction=d,force=f} then pump=s.create_entity{name='offshore-pump',position=p,direction=d,force=f} end
end end end
if not pump then rcon.print(helpers.table_to_json{error='no pump spot'}) return end
local function connected(a,b)
  for i=1,#a.fluidbox do for _,c in pairs(a.fluidbox.get_connections(i)) do if c.owner==b then return true end end end
  return false
end
local function attach(a,bname,avoid)
  local best
  for dx=-6,6 do for dy=-6,6 do for _,d in ipairs(dirs) do
    if not best then
      local p={a.position.x+dx,a.position.y+dy}
      if s.can_place_entity{name=bname,position=p,direction=d,force=f} then
        local b=s.create_entity{name=bname,position=p,direction=d,force=f}
        if b and connected(a,b) and not (avoid and avoid(b)) then best=b elseif b then b.destroy() end
      end
    end
  end end end
  return best
end
local up=function(b) return b.position.y>oy+5 end
local b1=attach(pump,'boiler',up); local b2=b1 and attach(b1,'boiler',up)
local engines={}
for _,b in ipairs{b1,b2} do
  if b then
    local e1=attach(b,'steam-engine',up); local e2=e1 and attach(e1,'steam-engine',up)
    engines[#engines+1]=e1; engines[#engines+1]=e2
  end
end
local fed=0
for _,b in ipairs{b1,b2} do
  if b then
    b.insert{name='coal',count=20}
    local done=false
    for dx=-5,5 do for dy=-5,5 do for _,d in ipairs(dirs) do
      if not done then
        local p={b.position.x+dx+0.5,b.position.y+dy+0.5}
        if s.can_place_entity{name='electric-mining-drill',position=p,direction=d,force=f} then
          local m=s.create_entity{name='electric-mining-drill',position=p,direction=d,force=f}
          local q=m.drop_position; local bb=b.bounding_box
          if q.x>bb.left_top.x and q.x<bb.right_bottom.x and q.y>bb.left_top.y and q.y<bb.right_bottom.y then
            done=true; fed=fed+1
            for x=math.floor(m.position.x)-2,math.floor(m.position.x)+2 do for y=math.floor(m.position.y)-2,math.floor(m.position.y)+2 do
              if s.get_tile(x,y).collides_with('water_tile')==false and s.count_entities_filtered{position={x+0.5,y+0.5},type='resource'}==0 then
                s.create_entity{name='coal',position={x+0.5,y+0.5},amount=P.base.ore_per_tile.coal} end end end
          else m.destroy() end
        end
      end
    end end end
  end
end
local poles=0
local need={}
for _,e in ipairs(engines) do need[#need+1]=e end
for _,m in pairs(s.find_entities_filtered{area={{ox-12,oy-6},{ox+12,oy+6}},name='electric-mining-drill',force=f}) do need[#need+1]=m end
for _,e in ipairs(need) do
  if e and e.valid and #s.find_entities_filtered{type='electric-pole',position=e.position,radius=4.5,force=f}==0 then
    local p=s.find_non_colliding_position('small-electric-pole',e.position,4,0.5,true)
    if p then s.create_entity{name='small-electric-pole',position=p,force=f}; poles=poles+1 end
  end
end
local function chain(x1,y1,x2,y2)
  local n=math.ceil(math.sqrt((x2-x1)^2+(y2-y1)^2)/6)
  for i=1,n-1 do local p=s.find_non_colliding_position('small-electric-pole',{x1+(x2-x1)*i/n,y1+(y2-y1)*i/n},2,0.5,true)
    if p then s.create_entity{name='small-electric-pole',position=p,force=f}; poles=poles+1 end end
end
local top={ox+6.5,oy-4.5}
for _,pl in pairs(s.find_entities_filtered{area={{ox-12,oy-6},{ox+12,oy+14}},type='electric-pole',force=f}) do
  if #pl.neighbours.copper==0 then chain(pl.position.x,pl.position.y,top[1],top[2]) end end
rcon.print(helpers.table_to_json{pump={pump.position.x-ox,pump.position.y-oy,pump.direction},boilers=(b1 and 1 or 0)+(b2 and 1 or 0),engines=#engines,fed=fed,poles=poles})
'''

LUA_KIT = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local ox,oy=math.floor(P.team.spawn[1]),math.floor(P.team.spawn[2])
local c=s.find_entities_filtered{name='iron-chest',position={ox-2.5,oy-8.5},radius=0.5}[1]
local n=0; for _,k in ipairs(P.base.kit) do n=n+c.insert{name=k[1],count=k[2]} end
rcon.print(helpers.table_to_json{kit_items=n})
'''


LUA_CHECK = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local out={evolution=game.forces.enemy.get_evolution_factor(s),
 evolution_on=game.map_settings.enemy_evolution.enabled,expansion_on=game.map_settings.enemy_expansion.enabled,tick=game.tick}
for name,t in pairs(P.teams) do
  local ox,oy=math.floor(t.spawn[1]),math.floor(t.spawn[2]); local box={{ox-40,oy-50},{ox+40,oy+45}}
  local r={status={},chests={},enemies_450=s.count_entities_filtered{position=t.spawn,radius=P.clear_enemies,force='enemy'}}
  for _,e in pairs(s.find_entities_filtered{area=box,force=name}) do
    if e.status then local k=e.name..':'..tostring(e.status); r.status[k]=(r.status[k] or 0)+1 end
    if e.type=='container' then for _,it in pairs(e.get_inventory(defines.inventory.chest).get_contents()) do r.chests[it.name]=(r.chests[it.name] or 0)+it.count end end
  end
  local st={}; for k,v in pairs(defines.entity_status) do st[v]=k end
  local named={}; for k,v in pairs(r.status) do local n,c=k:match('^(.-):(%%d+)$'); named[n..':'..(st[tonumber(c)] or c)]=v end; r.status=named
  r.nest_spawners=s.count_entities_filtered{position=t.nest,radius=P.nest_r+6,type='unit-spawner',force='enemy'}
  r.nest_worms=s.count_entities_filtered{position=t.nest,radius=P.nest_r+6,type='turret',force='enemy'}
  r.field={}; for _,fl in ipairs(t.field) do r.field[fl.name]=s.count_entities_filtered{position=fl.at,radius=fl.r+1,name=fl.name} end
  local n=0; for _,tech in pairs(game.forces[name].technologies) do if tech.researched then n=n+1 end end; r.researched=n
  local fo=game.forces[name]; local cp=function(x,y) return fo.is_chunk_charted(s,{math.floor(x/32),math.floor(y/32)}) end
  r.charted={nest=cp(t.nest[1],t.nest[2]),field=cp(t.field[1].at[1],t.field[1].at[2]) and cp(t.field[2].at[1],t.field[2].at[2])}
  r.base_ore={}; for _,e in pairs(s.find_entities_filtered{area=box,type='resource'}) do r.base_ore[e.name]=(r.base_ore[e.name] or 0)+e.amount end
  local stray=0; for _,e in pairs(s.find_entities_filtered{position=t.spawn,radius=P.clear_enemies,name=P.clear_ore}) do
    local onf=false; for _,fl in ipairs(t.field) do if (e.position.x-fl.at[1])^2+(e.position.y-fl.at[2])^2<=(fl.r+2)^2 then onf=true end end
    if not onf and not (e.position.x>=box[1][1] and e.position.x<=box[2][1] and e.position.y>=box[1][2] and e.position.y<=box[2][2]) then stray=stray+1 end end
  r.iron_copper_tiles_outside=stray
  r.power_w=0; for _,e in pairs(s.find_entities_filtered{area=box,type='generator',force=name}) do r.power_w=r.power_w+e.energy_generated_last_tick*60 end
  out[name]=r
end
rcon.print(helpers.table_to_json(out))
'''

LUA_MEASURE = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local out={tick=game.tick}
for name,t in pairs(P.teams) do
  local f=game.forces[name]; local k=f.get_kill_count_statistics(s)
  local lost=0; for _,c in pairs(k.output_counts) do lost=lost+c end
  local kills=0; for _,c in pairs(k.input_counts) do kills=kills+c end
  local drills,outside=0,{}
  local ox,oy=math.floor(t.spawn[1]),math.floor(t.spawn[2]); local B=P.base.box
  for _,d in pairs(s.find_entities_filtered{type='mining-drill',force=name}) do
    if d.status==defines.entity_status.working then
      local p=d.position; local onfield=false
      for _,fl in ipairs(t.field) do if (p.x-fl.at[1])^2+(p.y-fl.at[2])^2<=(fl.r+2)^2 then onfield=true end end
      local inbase=p.x>=ox+B[1] and p.x<=ox+B[3] and p.y>=oy+B[2] and p.y<=oy+B[4]
      if onfield then drills=drills+1 elseif not inbase then
        local m=d.mining_target; local k=m and m.valid and m.name or '?'; outside[k]=(outside[k] or 0)+1 end
    end
  end
  out[name]={spawners=s.count_entities_filtered{position=t.nest,radius=P.nest_r+6,type='unit-spawner',force='enemy'},
    worms=s.count_entities_filtered{position=t.nest,radius=P.nest_r+6,type='turret',force='enemy'},
    field_drills_working=drills,outside_drills_working=outside,lost=lost,killed=kills,characters_lost=k.get_output_count and k.get_output_count('character') or nil}
end
rcon.print(helpers.table_to_json(out))
'''


def rcon():
    from pog import Rcon
    import run_state
    run_state.claim()
    pw = (Path.home()/'.config/pog/rcon-imac-mt.pw').read_text().strip()
    return Rcon(os.environ.get('IMAC_RCON_HOST') or 'imac.local', 27475, pw, timeout=600)


def run_lua(r, lua, spec):
    from harness import lua_string, one_line
    out = r.command('/silent-command ' + one_line(lua % {'spec': lua_string(json.dumps(spec))}))
    try:
        return json.loads(out)
    except ValueError:
        raise SystemExit(f'lua failed: {out[:2000]}')


def build():
    p = plan(); r = rcon(); res = {}
    res['prep'] = run_lua(r, LUA_PREP, p)
    for name, t in p['teams'].items():
        one = dict(team=t, name=name, base=p['base'], research=p['research'], nest_r=p['nest_r'])
        res[name] = dict(corridor=run_lua(r, LUA_CORRIDOR, one), place=run_lua(r, LUA_PLACE, one),
                         base=run_lua(r, LUA_BASE, one), power=run_lua(r, LUA_POWER, one), kit=run_lua(r, LUA_KIT, one))
    print(json.dumps(res, indent=1))
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    q = sub.add_parser('plan'); q.add_argument('--json', action='store_true')
    sub.add_parser('build'); sub.add_parser('check'); sub.add_parser('measure')
    q = sub.add_parser('save'); q.add_argument('name')
    a = ap.parse_args(argv)
    if a.cmd == 'plan':
        p = plan()
        if a.json:
            print(json.dumps(p, indent=1)); return
        for n, t in p['teams'].items():
            print(n, 'spawn', t['spawn'], 'bearing', t['bearing'], 'nest', tuple(round(c, 1) for c in t['nest']),
                  'field', [tuple(round(c, 1) for c in f['at']) for f in t['field']], t['distances'])
        print('base entities', len(p['base']['entities']), 'overlaps', len(overlaps(p['base']['entities'])))
    elif a.cmd == 'build':
        build()
    elif a.cmd in ('check', 'measure'):
        print(json.dumps(run_lua(rcon(), LUA_CHECK if a.cmd == 'check' else LUA_MEASURE, plan()), indent=1))
    elif a.cmd == 'save':
        # chart requests need ticks: run 10 s of game time, then save paused (the sprint's paused start unpauses)
        assert a.name.replace('-', '').isalnum() and a.name != 'mt'
        import time
        r = rcon(); t0 = int(r.command('/silent-command rcon.print(game.tick)'))
        r.command('/silent-command game.tick_paused=false')
        while int(r.command('/silent-command rcon.print(game.tick)')) < t0 + 600:
            time.sleep(1)
        r.command('/silent-command game.tick_paused=true')
        print(r.command(f"/silent-command game.server_save('{a.name}') rcon.print('saved {a.name} at tick ' .. game.tick)"))


if __name__ == '__main__':
    main()
