#!/usr/bin/env python3
"""(mt309) Stage 2's prepared mid-game save: the r307 baseline with the same base, nest and second ore field at every
spawn (task-mt309 Stage 2; layout in report-mt309 section 6b).

  stage2_save.py plan [--json]         every spawn's geometry from the r307 layout (no server)
  stage2_save.py build                 apply it to the running imac2 server (the r307 baseline loaded, no agents)
  stage2_save.py check                 read back each spawn: base output, power, nest, field, research
  stage2_save.py measure               the Stage 2 measures per force (nest left, second-field drills, losses)
  stage2_save.py --map contact ...      (note-mt309-t) the same on the three-team contact map (layout below)
  stage2_save.py --map ct2 ...          (note-mt309-y) the contact map's design with the starts CT2_D apart
  stage2_save.py --map ct2-shortage ... the same, with each team's corridor fields short of one ore (SHORTAGE)
  stage2_save.py --map ct3 ...          (note-mt309-z7) two teams on ct2's map: each holds the only iron or the only copper

The contact map (note-mt309-t: Astra low, Opus high and Neon on one map where they can meet). mt_map.py's layout
(three starts CONTACT_D apart, each team's own patches toward the middle, the shared sites at each pair's midpoint
with their oil, no middle site) with this file's base at every spawn, but the nest and the second field split
between the team's two corridors: a half nest (two spawners, two worms) on the bearing to each neighbour, the iron
field behind the nest toward the next team (green, yellow, blue, round) and the copper field toward the other. Each
nest and field is the same gap from the base box on every bearing (the box is axis-aligned; Stage 2's nest was 90
tiles from green's base and 112-115 from the others'). The start's own iron, copper and oil (mt_map PRIMARY) are
removed as Stage 2 removed r307's: the base's ore runs short in about an hour, and oil lies at the shared sites.

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
LAYOUTS = {'stage2': ROOT/'docs/reports/mt307/data/map/layout.json', 'contact': ROOT/'docs/reports/mt309/data/contact/layout.json',
           'ct2': ROOT/'docs/reports/mt309/data/ct2/layout.json', 'ct2-shortage': ROOT/'docs/reports/mt309/data/ct2/layout.json',
           'ct3': ROOT/'docs/reports/mt309/data/ct3/layout.json'}
CONTACT_MAPS = ('contact', 'ct2', 'ct2-shortage', 'ct3')
MAP = 'stage2'          # main --map
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
# (note-mt309-t) the contact map. The nest's gap: from its centre to the nearest base building's centre (the built
# base, data/contact/base-footprint.json, the same at every spawn); its worms 9 tiles nearer (Stage 2's far spawns:
# nearest building 112-115 from the nearest enemy). The field lies CONTACT_FIELD_PAST beyond the nest (Stage 2: 120).
CONTACT_D = 900
CT2_D = 750         # (note-mt309-y) ct2: the nearest spacing at which a corridor field stays 10+ tiles from a shared site
CONTACT_NEST_GAP = 122
CONTACT_FIELD_PAST = 121
FOOTPRINT = ROOT/'docs/reports/mt309/data/contact/base-footprint.json'
CONTACT_FIELDS = {'next': ('iron-ore', 18, 1500000), 'prev': ('copper-ore', 16, 1200000)}   # Stage 2's amounts
CONTACT_SPAWNERS = (('biter-spawner', 0, -4), ('spitter-spawner', 0, 4))      # along the bearing, to its side
CONTACT_WORMS = (('small-worm-turret', -9, -6), ('medium-worm-turret', -9, 6))  # along < 0 faces the base
CONTACT_CLEAR_ORE = (220, ('iron-ore', 'copper-ore', 'crude-oil'))  # the start's own patches (shared sites: 390+)
# (note-mt309-y) a corridor's cleared ground ends this far short of the nearest shared-site patch on its line
CONTACT_SITE_GAP = 4
# (note-mt309-y) the shortage build: one corridor field per team changes ore and keeps its size and amount, so each
# team's own fields lack one ore that a neighbour's fields hold. Green and blue have two iron fields and no copper
# field; yellow has two copper fields and no iron field. (team, side): ore
SHORTAGE = {'ct2-shortage': {('green', 'prev'): 'iron-ore', ('yellow', 'next'): 'copper-ore', ('blue', 'prev'): 'iron-ore'}}
# and natural ore of the kind a team lacks goes within this many tiles of its spawn (shared sites, placed fields and
# the base's own ore cells stay)
SHORTAGE_CLEAR_R = 600
# (note-mt309-z7) ct3: green and blue on ct2's map (docs/reports/mt309/contact/ct3_layout.py), each team's ore its
# own and the other's missing. Each team's two corridors (half nest, field) lie CT3_SPREAD degrees either side of the
# bearing to the other team, as a ct2 team's two neighbours did, so the straight route between the starts passes
# about 80 tiles from every nest. Both fields, the base's ore cells and the kit's plates are the team's own ore.
CT3_ORE = {'green': 'copper-ore', 'blue': 'iron-ore'}
CT3_SPREAD = 30
PLATE = {'iron-ore': 'iron-plate', 'copper-ore': 'copper-plate'}


def teams():
    lay = json.loads(LAYOUTS[MAP].read_text())
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


def box_gap(spawn, x, y):
    """Distance from (x, y) to the base box round spawn (0 inside)."""
    ox, oy = math.floor(spawn[0]), math.floor(spawn[1])
    dx = max(ox + BASE_BOX[0] - x, 0, x - (ox + BASE_BOX[2]))
    dy = max(oy + BASE_BOX[1] - y, 0, y - (oy + BASE_BOX[3]))
    return math.hypot(dx, dy)


def building_gap(spawn, x, y):
    """Distance from (x, y) to the nearest base building's centre (FOOTPRINT; the box edge without it)."""
    if not FOOTPRINT.exists():
        return box_gap(spawn, x, y)
    ox, oy = math.floor(spawn[0]), math.floor(spawn[1])
    return min(math.hypot(x - ox - e[0], y - oy - e[1]) for e in json.loads(FOOTPRINT.read_text())['entities'])


def at_gap(spawn, ang, gap):
    """How far along bearing ang (radians) from spawn a point is `gap` tiles from the nearest base building."""
    lo, hi = 0.0, gap + 200.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if building_gap(spawn, spawn[0] + mid*math.cos(ang), spawn[1] + mid*math.sin(ang)) < gap: lo = mid
        else: hi = mid
    return (lo + hi) / 2


def site_edge(spawn, ang, half):
    """How far along bearing ang from spawn the nearest shared-site patch tile lies, among the patches within half
    (plus their radius) of the line; inf if none."""
    lay = json.loads(LAYOUTS[MAP].read_text()); best = math.inf
    for site in lay.get('place_sites', []):
        for q in site['patches']:
            dx, dy = site['x'] + q['dx'] - spawn[0], site['y'] + q['dy'] - spawn[1]; r = q.get('r', 3)
            u, v = dx*math.cos(ang) + dy*math.sin(ang), -dx*math.sin(ang) + dy*math.cos(ang)
            if u > 0 and abs(v) <= half + r:
                best = min(best, u - r)
    return best


def contact_plan():
    """(note-mt309-t) Each team's two corridors: toward the next team (iron) and the previous one (copper)."""
    ts = teams(); order = [n for n in TEAMS if n in ts]; out = {}; short = SHORTAGE.get(MAP, {})
    for i, name in enumerate(order):
        s = ts[name]['spawn']; nests, fields, spawners, worms, corridors, dist = [], [], [], [], [], {}
        two = len(order) == 2
        for side, other in (('next', order[(i + 1) % len(order)]), ('prev', order[(i - 1) % len(order)])):
            o = ts[other]['spawn']; ang = math.atan2(o[1] - s[1], o[0] - s[0])
            if two:     # (note-mt309-z7) one neighbour: the two corridors either side of its bearing
                ang += math.radians(CT3_SPREAD if side == 'next' else -CT3_SPREAD)
            deg = math.degrees(ang)
            pt = lambda a, v: (s[0] + a*math.cos(ang) - v*math.sin(ang), s[1] + a*math.sin(ang) + v*math.cos(ang))
            na = at_gap(s, ang, CONTACT_NEST_GAP); fa = na + CONTACT_FIELD_PAST
            nest = pt(na, 0); nests.append(nest)
            spawners += [(n, *pt(na + du, dv)) for n, du, dv in CONTACT_SPAWNERS]
            worms += [(n, *pt(na + du, dv)) for n, du, dv in CONTACT_WORMS]
            ore, r, amount = CONTACT_FIELDS[side]
            ore = short.get((name, side), ore)
            if MAP == 'ct3':
                ore = CT3_ORE[name]
            fields.append(dict(name=ore, r=r, amount=amount, at=pt(fa, 0), toward=other))
            # LUA_CORRIDOR's frame: u along the bearing given, the corridor at negative u; it stops short of a shared site
            end = min(fa + r + 30, site_edge(s, ang, 70) - CONTACT_SITE_GAP)
            corridors.append(dict(u1=-50, u2=-round(end), half=70, bearing=deg + 180, toward=other))
            dist[other + (' ' + side if two else '')] = dict(bearing=round(deg, 1), nest=round(na), field=round(fa), ore=ore, corridor_end=round(end),
                               nest_gap=round(building_gap(s, *nest)), field_gap=round(building_gap(s, *pt(fa, 0))))
        out[name] = dict(spawn=s, bearing=ts[name]['bearing'], nest=nests[0], nests=nests, spawners=spawners, worms=worms,
                         field=fields, corridors=corridors, corridor=corridors[0], distances=dist)
        if short or MAP == 'ct3':
            out[name]['lacks'] = sorted({v[0] for v in CONTACT_FIELDS.values()} - {f['name'] for f in fields})
    return out


def keep_ore():
    """The ore circles a shortage clear leaves: every shared-site patch and every placed corridor field (ct3: the
    fields only, named by team and ore)."""
    if MAP == 'ct3':
        return [dict(at=f['at'], r=f['r'] + 2, what=f"{n} field {f['name']}") for n, t in contact_plan().items() for f in t['field']]
    lay = json.loads(LAYOUTS[MAP].read_text())
    out = [dict(at=(si['x'] + q['dx'], si['y'] + q['dy']), r=q.get('r', 3) + 2) for si in lay.get('place_sites', []) for q in si['patches']]
    return out + [dict(at=f['at'], r=f['r'] + 2) for t in contact_plan().values() for f in t['field']]


def plan():
    ents, ores = base_entities()
    out = {}
    if MAP in CONTACT_MAPS:
        return dict(teams=contact_plan(), base=dict(entities=ents, ores=ores, box=BASE_BOX, power=(POWER_X, POWER_Y), kit=KIT,
                                                    ore_per_tile=ORE_PER_TILE),
                    research=RESEARCH, evolution=EVOLUTION, clear_enemies=CLEAR_ENEMIES, nest_r=NEST_R,
                    clear_ore=list(CONTACT_CLEAR_ORE[1]), clear_ore_r=CONTACT_CLEAR_ORE[0], map='contact', name=MAP,
                    **(dict(shortage_clear_r=SHORTAGE_CLEAR_R, keep_ore=keep_ore()) if SHORTAGE.get(MAP) else {}),
                    **(dict(ct3=dict(keep_ore=keep_ore(), no_autoplace=sorted(PLATE), plates=PLATE)) if MAP == 'ct3' else {}))
    for name, t in teams().items():
        s, b = t['spawn'], t['bearing']
        field = [local(s, b, FIELD_U, dv) for *_, dv in FIELD]
        nest = local(s, b, NEST_U, 0)
        out[name] = dict(
            spawn=s, bearing=b, nest=nest, nests=[nest],
            spawners=[(n, *local(s, b, NEST_U + du, dv)) for n, du, dv in SPAWNERS],
            worms=[(n, *local(s, b, NEST_U + du, dv)) for n, du, dv in WORMS],
            field=[dict(name=n, r=r, amount=a, at=local(s, b, FIELD_U, dv)) for n, r, a, dv in FIELD],
            corridor=dict(u1=CORRIDOR[0], u2=CORRIDOR[1], half=CORRIDOR[2], bearing=b),
            distances=dict(nest=round(math.dist(s, nest)), field=round(math.dist(s, local(s, b, FIELD_U, 0))),
                           nest_to_field=FIELD_U and abs(FIELD_U - NEST_U)))
    return dict(teams=out, base=dict(entities=ents, ores=ores, box=BASE_BOX, power=(POWER_X, POWER_Y), kit=KIT,
                                     ore_per_tile=ORE_PER_TILE),
                research=RESEARCH, evolution=EVOLUTION, clear_enemies=CLEAR_ENEMIES, nest_r=NEST_R, clear_ore=CLEAR_ORE,
                clear_ore_r=CLEAR_ENEMIES, map='stage2')


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
  for _,e in pairs(s.find_entities_filtered{position={t.spawn[1],t.spawn[2]},radius=P.clear_ore_r,name=P.clear_ore}) do o=o+e.amount; ot=ot+1; e.destroy() end
  out[name]={enemies_removed=n,ore_removed=o,ore_tiles_removed=ot}
end
rcon.print(helpers.table_to_json(out))
'''

LUA_SHORTAGE = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local out={}
local B=P.base.box
for name,t in pairs(P.teams) do
  local o,ot=0,0
  for _,e in pairs(s.find_entities_filtered{position={t.spawn[1],t.spawn[2]},radius=P.shortage_clear_r,name=t.lacks}) do
    local p=e.position; local keep=false
    for _,u in pairs(P.teams) do local ox,oy=math.floor(u.spawn[1]),math.floor(u.spawn[2])
      if p.x>=ox+B[1] and p.x<=ox+B[3] and p.y>=oy+B[2] and p.y<=oy+B[4] then keep=true end end
    for _,k in ipairs(P.keep_ore) do if (p.x-k.at[1])^2+(p.y-k.at[2])^2<=k.r*k.r then keep=true; break end end
    if not keep then o=o+e.amount; ot=ot+1; e.destroy() end
  end
  out[name]={lacks=t.lacks,ore_removed=o,ore_tiles_removed=ot}
end
rcon.print(helpers.table_to_json(out))
'''

# (note-mt309-z7) ct3. AUTOPLACE: iron and copper off in nauvis's map-gen settings (chunks made later have none).
# ORE: every iron and copper tile on nauvis by where it lies (a team's placed field or base box, else natural);
# remove destroys the natural ones. ITEMS: either ore or plate held by anything (a team's entity holding the ore it
# lacks, a wreck, a chest of no team, an item on the ground), plus the entities whose mining yields either; remove
# takes them out (never from the enemy force). FREEPLAY: the freeplay scenario's items for a new or respawned
# character, plates removed with remove.
LUA_CT3_AUTOPLACE = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local m=s.map_gen_settings; local out={before={},after={}}
for _,n in ipairs(P.ct3.no_autoplace) do local c=m.autoplace_controls[n]; out.before[n]=c and {c.frequency,c.size,c.richness} or 'none'
  if c then c.size=0 end end
s.map_gen_settings=m; m=s.map_gen_settings
for _,n in ipairs(P.ct3.no_autoplace) do local c=m.autoplace_controls[n]; out.after[n]=c and {c.frequency,c.size,c.richness} or 'none' end
local n=0; for _ in s.get_chunks() do n=n+1 end; out.chunks=n
rcon.print(helpers.table_to_json(out))
'''

LUA_CT3_ORE = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local B=P.base.box; local out={kept={},removed={},removed_tiles=0,far=0}
for _,e in pairs(s.find_entities_filtered{name=P.ct3.no_autoplace}) do
  local p=e.position; local keep
  for n,t in pairs(P.teams) do local ox,oy=math.floor(t.spawn[1]),math.floor(t.spawn[2])
    if p.x>=ox+B[1] and p.x<=ox+B[3] and p.y>=oy+B[2] and p.y<=oy+B[4] then keep=n..' base '..e.name end end
  for _,k in ipairs(P.ct3.keep_ore) do if (p.x-k.at[1])^2+(p.y-k.at[2])^2<=k.r*k.r then keep=k.what..' '..e.name; break end end
  if keep then out.kept[keep]=(out.kept[keep] or 0)+e.amount else
    out.removed[e.name]=(out.removed[e.name] or 0)+e.amount; out.removed_tiles=out.removed_tiles+1
    local d=math.huge; for _,t in pairs(P.teams) do d=math.min(d,math.sqrt((p.x-t.spawn[1])^2+(p.y-t.spawn[2])^2)) end
    if d>out.far then out.far=math.floor(d) end
    if P.remove then e.destroy() end end
end
rcon.print(helpers.table_to_json(out))
'''

LUA_CT3_ITEMS = r'''
local P=helpers.json_to_table(%(spec)s); local s=game.surfaces.nauvis; local out={teams={},other={},ground={},minable={}}
local items={}; for o,pl in pairs(P.ct3.plates) do items[#items+1]=o; items[#items+1]=pl end
local function take(e,names,into)
  for i=1,e.get_max_inventory_index() do local inv=e.get_inventory(i)
    if inv then for _,n in ipairs(names) do local c=inv.get_item_count(n)
      if c>0 then into[n]=(into[n] or 0)+c; if P.remove then inv.remove{name=n,count=c} end end end end end
  if e.type=='inserter' and e.held_stack.valid_for_read then local h=e.held_stack
    for _,n in ipairs(names) do if h.name==n then into[n]=(into[n] or 0)+h.count; if P.remove then h.clear() end end end end
end
for n,t in pairs(P.teams) do local lacks={}
  for _,o in ipairs(t.lacks) do lacks[#lacks+1]=o; lacks[#lacks+1]=P.ct3.plates[o] end
  local got={}; for _,e in pairs(s.find_entities_filtered{force=n}) do take(e,lacks,got) end
  out.teams[n]={lacks=lacks,held=got} end
local teams={enemy=true}; for n in pairs(P.teams) do teams[n]=true end
for _,e in pairs(s.find_entities_filtered{type={'container','logistic-container','character-corpse','car','cargo-wagon','character'}}) do
  if not teams[e.force.name] then local got={}; take(e,items,got)
    if next(got) then out.other[#out.other+1]={name=e.name,force=e.force.name,position={math.floor(e.position.x),math.floor(e.position.y)},held=got} end end end
for _,e in pairs(s.find_entities_filtered{type='item-entity'}) do local st=e.stack
  for _,n in ipairs(items) do if st.valid_for_read and st.name==n then out.ground[n]=(out.ground[n] or 0)+st.count; if P.remove then e.destroy() end; break end end end
local yields={}
for name,pr in pairs(prototypes.entity) do local m=pr.mineable_properties
  if m and m.minable and m.products and pr.type~='resource' then for _,q in ipairs(m.products) do
    for _,n in ipairs(items) do if q.name==n then yields[#yields+1]=name end end end end end
for _,name in ipairs(yields) do out.minable[name]=s.count_entities_filtered{name=name} end
rcon.print(helpers.table_to_json(out))
'''

LUA_CT3_FREEPLAY = r'''
local P=helpers.json_to_table(%(spec)s); local out={freeplay=remote.interfaces.freeplay and true or false}
if out.freeplay then
  for _,k in ipairs{'created','respawn','ship','debris'} do local get=remote.interfaces.freeplay['get_'..k..'_items']
    if get then local list=remote.call('freeplay','get_'..k..'_items'); out[k]=list
      local hit=false; for o,pl in pairs(P.ct3.plates) do if list[o] or list[pl] then hit=true; list[o]=nil; list[pl]=nil end end
      if hit and P.remove and remote.interfaces.freeplay['set_'..k..'_items'] then remote.call('freeplay','set_'..k..'_items',list); out[k..'_now']=remote.call('freeplay','get_'..k..'_items') end
    end end
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
for dx=0,6 do for _,sx in ipairs{1,-1} do for _,d in ipairs{D.south,D.east,D.west,D.north} do
  local p={ox+sx*dx+0.5,oy+5.5}
  if not pump and s.can_place_entity{name='offshore-pump',position=p,direction=d,force=f} then
    local q=s.create_entity{name='offshore-pump',position=p,direction=d,force=f}
    local c=q and q.get_fluid_box_pipe_connections(1)[1]
    if c and not s.get_tile(c.target_position.x,c.target_position.y).name:find('water') then pump=q elseif q then q.destroy() end
  end
end end end
if not pump then rcon.print(helpers.table_to_json{error='no pump spot'}) return end
local function on(a,i,b)
  for _,c in ipairs(a.get_fluid_box_neighbours(i) or {}) do if c.entity==b then return true end end
  return false
end
local function connected(a,b,ia,ib) return on(a,ia,b) and on(b,ib,a) end
local function wet_engine(b)
  if b.name~='steam-engine' then return false end
  for _,c in ipairs(b.get_fluid_box_neighbours(1) or {}) do if c.entity.name=='boiler' and on(c.entity,1,b) then return true end end
  return false
end
local function attach(a,bname,avoid,ia,ib)
  local best
  for dx=-6,6 do for dy=-6,6 do for _,d in ipairs(dirs) do
    if not best then
      local p={a.position.x+dx,a.position.y+dy}
      if s.can_place_entity{name=bname,position=p,direction=d,force=f} then
        local b=s.create_entity{name=bname,position=p,direction=d,force=f}
        if b and connected(a,b,ia,ib) and not wet_engine(b) and not (avoid and avoid(b)) then best=b elseif b then b.destroy() end
      end
    end
  end end end
  return best
end
local up=function(b) return b.position.y>oy+5 end
local b1=attach(pump,'boiler',up,1,1); local b2=b1 and attach(b1,'boiler',up,1,1)
local engines={}
for _,b in ipairs{b1,b2} do
  if b then
    local e1=attach(b,'steam-engine',up,2,1); local e2=e1 and attach(e1,'steam-engine',up,1,1)
    engines[#engines+1]=e1; engines[#engines+1]=e2
  end
end
local fed,drops=0,{}
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
            local mp,md=m.position,m.direction; m.destroy()
            m=s.create_entity{name='electric-mining-drill',position=mp,direction=md,force=f}
            drops[#drops+1]=m.drop_target and m.drop_target.name or 'none'
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
  if pl.get_wire_connector(defines.wire_connector_id.pole_copper,true).connection_count==0 then chain(pl.position.x,pl.position.y,top[1],top[2]) end end
rcon.print(helpers.table_to_json{pump={pump.position.x-ox,pump.position.y-oy,pump.direction},boilers=(b1 and 1 or 0)+(b2 and 1 or 0),engines=#engines,fed=fed,drops=drops,poles=poles})
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
  r.nest_spawners=0; r.nest_worms=0; r.nests={}
  for _,nst in ipairs(t.nests) do local sp=s.count_entities_filtered{position=nst,radius=P.nest_r+6,type='unit-spawner',force='enemy'}
    local wm=s.count_entities_filtered{position=nst,radius=P.nest_r+6,type='turret',force='enemy'}
    local near=s.find_entities_filtered{position=nst,radius=200,force=name}; local gap=nil
    for _,e in ipairs(near) do local d=math.sqrt((e.position.x-nst[1])^2+(e.position.y-nst[2])^2); if not gap or d<gap then gap=d end end
    r.nest_spawners=r.nest_spawners+sp; r.nest_worms=r.nest_worms+wm; r.nests[#r.nests+1]={spawners=sp,worms=wm,nearest_building=gap and math.floor(gap+0.5)} end
  r.field={}; for _,fl in ipairs(t.field) do r.field[fl.name]=(r.field[fl.name] or 0)+s.count_entities_filtered{position=fl.at,radius=fl.r+1,name=fl.name} end
  local n=0; for _,tech in pairs(game.forces[name].technologies) do if tech.researched then n=n+1 end end; r.researched=n
  local fo=game.forces[name]; local cp=function(x,y) return fo.is_chunk_charted(s,{math.floor(x/32),math.floor(y/32)}) end
  local cn=true; for _,nst in ipairs(t.nests) do cn=cn and cp(nst[1],nst[2]) end
  local cf=true; for _,fl in ipairs(t.field) do cf=cf and cp(fl.at[1],fl.at[2]) end
  r.charted={nest=cn,field=cf}
  r.base_ore={}; for _,e in pairs(s.find_entities_filtered{area=box,type='resource'}) do r.base_ore[e.name]=(r.base_ore[e.name] or 0)+e.amount end
  local stray=0; for _,e in pairs(s.find_entities_filtered{position=t.spawn,radius=P.clear_ore_r,name=P.clear_ore}) do
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
  local sp,wm,nests=0,0,{}
  for _,nst in ipairs(t.nests) do local a=s.count_entities_filtered{position=nst,radius=P.nest_r+6,type='unit-spawner',force='enemy'}
    local b=s.count_entities_filtered{position=nst,radius=P.nest_r+6,type='turret',force='enemy'}; sp=sp+a; wm=wm+b; nests[#nests+1]={a,b} end
  out[name]={spawners=sp,worms=wm,nests=nests,
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


def team_base(p, name):
    """The base as built for a team: ct3's ore cells and kit plates are the team's own ore (note-mt309-z7)."""
    if MAP != 'ct3':
        return p['base']
    own = CT3_ORE[name]; b = dict(p['base'])
    b['ores'] = [(own if o[0] in PLATE else o[0], *o[1:]) for o in b['ores']]
    kit = {}
    for item, n in b['kit']:
        item = PLATE[own] if item in PLATE.values() else item
        kit[item] = kit.get(item, 0) + n
    b['kit'] = list(kit.items())
    return b


def build():
    p = plan(); r = rcon(); res = {}
    if p.get('ct3'):    # before the first chunk the build makes: no iron or copper in any chunk made from now on
        res['autoplace'] = run_lua(r, LUA_CT3_AUTOPLACE, p)
        res['freeplay'] = run_lua(r, LUA_CT3_FREEPLAY, dict(p, remove=True))
    res['prep'] = run_lua(r, LUA_PREP, p)
    for name, t in p['teams'].items():
        one = dict(team=t, name=name, base=team_base(p, name), research=p['research'], nest_r=p['nest_r'])
        if p['map'] == 'contact':      # each corridor: cleared, then its half nest and its field placed and charted
            res[name] = dict(corridor=[], place=[])
            for k, c in enumerate(t['corridors']):
                sub = dict(t, corridor=c, nest=t['nests'][k], spawners=t['spawners'][2*k:2*k + 2], worms=t['worms'][2*k:2*k + 2],
                           field=[t['field'][k]])
                res[name]['corridor'].append(run_lua(r, LUA_CORRIDOR, dict(one, team=sub)))
                res[name]['place'].append(run_lua(r, LUA_PLACE, dict(one, team=sub)))
        else:
            res[name] = dict(corridor=run_lua(r, LUA_CORRIDOR, one), place=run_lua(r, LUA_PLACE, one))
        res[name].update(base=run_lua(r, LUA_BASE, one), power=run_lua(r, LUA_POWER, one), kit=run_lua(r, LUA_KIT, one))
    if p.get('shortage_clear_r'):     # after every field is placed: natural ore of each team's missing kind near it
        res['shortage'] = run_lua(r, LUA_SHORTAGE, p)
    if p.get('ct3'):    # natural iron and copper on the whole surface, then the missing ore and plates anywhere
        res['ct3_ore'] = run_lua(r, LUA_CT3_ORE, dict(p, remove=True))
        res['ct3_items'] = run_lua(r, LUA_CT3_ITEMS, dict(p, remove=True))
    print(json.dumps(res, indent=1))
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--map', choices=sorted(LAYOUTS), default='stage2')
    sub = ap.add_subparsers(dest='cmd', required=True)
    q = sub.add_parser('plan'); q.add_argument('--json', action='store_true')
    sub.add_parser('build'); sub.add_parser('check'); sub.add_parser('measure')
    q = sub.add_parser('save'); q.add_argument('name')
    a = ap.parse_args(argv)
    global MAP
    MAP = a.map
    if a.cmd == 'plan':
        p = plan()
        if a.json:
            print(json.dumps(p, indent=1)); return
        for n, t in p['teams'].items():
            print(n, 'spawn', t['spawn'], 'bearing', t['bearing'], 'nests', [tuple(round(c, 1) for c in x) for x in t['nests']],
                  'field', [tuple(round(c, 1) for c in f['at']) for f in t['field']], t['distances'])
        print('base entities', len(p['base']['entities']), 'overlaps', len(overlaps(p['base']['entities'])))
    elif a.cmd == 'build':
        build()
    elif a.cmd in ('check', 'measure'):
        r = rcon(); p = plan(); out = run_lua(r, LUA_CHECK if a.cmd == 'check' else LUA_MEASURE, p)
        if p.get('ct3') and a.cmd == 'check':     # (note-mt309-z7) read only: where iron and copper lie, who holds what
            out['ct3'] = dict(ore=run_lua(r, LUA_CT3_ORE, p), items=run_lua(r, LUA_CT3_ITEMS, p),
                              freeplay=run_lua(r, LUA_CT3_FREEPLAY, p),
                              autoplace=run_lua(r, 'local m=game.surfaces.nauvis.map_gen_settings.autoplace_controls; local o={} for _,n in ipairs{"iron-ore","copper-ore"} do o[n]=m[n] and m[n].size end rcon.print(helpers.table_to_json(o))', p))
        if MAP in CONTACT_MAPS and a.cmd == 'measure':
            # (note-mt309-t) the harness's first contacts (chart, shot) and losses by killer, from its own storage
            # (note-mt309-u) and Post raids (the market's spill records), shipments made, and a harness fault
            got = r.command('/silent-command __agent-harness__ local h=storage.agent_harness local m=h.mt or {} '
                            'local mk=m.market or {} local sp=0 for k in pairs(mk.spills or {}) do if type(k)=="string" then sp=sp+1 end end '
                            'local tx=0 for _,p in pairs(mk.pairs or {}) do tx=tx+#(p.transactions or {}) end '
                            'rcon.print(helpers.table_to_json({first=m.first or {},losses=m.losses or {},post_spills=sp,'
                            'transactions=tx,runtime_fault=h.runtime_fault and tostring(h.runtime_fault) or nil}))')
            try:
                out.update(json.loads(got))
            except ValueError:
                out['contacts_error'] = got[:300]
        print(json.dumps(out, indent=1))
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
