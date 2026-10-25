-- Run from the harness root: lua tests/d25_batch209.lua
-- d25 batch209 QV1 (Astra #2361: a legendary gun turret read range 18 in platform_defense while it killed asteroids 21-28
-- tiles out): a turret's range is its prototype's times its quality's range_multiplier. platform_defense's turret rows
-- give quality, range and base_range, and its collectors and hull use that range; planned ghosts the same; inspect's
-- turret reach (platdefense.reach); danger's turret coverage. Fails on main: range 18, no quality.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end
local QUALITY={normal={range_multiplier=1},uncommon={range_multiplier=1.1},rare={range_multiplier=1.2},legendary={range_multiplier=1.5}}

-- platform_defense: a legendary gun turret reaches a collector 22 tiles off, a normal one does not
do
  defines={inventory={turret_ammo=1}}
  game={tick=100}
  prototypes={quality=QUALITY}
  local function turret(name,x,y,range,q,unit)
    local t={valid=true,type='ammo-turret',name=name,position={x=x,y=y},bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}},
      prototype={attack_parameters={range=range,min_range=0}},ignore_unprioritised_targets=false,unit_number=unit,quality={name=q},direction=0}
    t.get_inventory=function() return {get_contents=function() return {{name='firearm-magazine',count=10}} end} end
    t.get_priority_target=function() return nil end
    return t
  end
  local leg=turret('gun-turret',0.5,0.5,18,'legendary',41968114)
  local plain=turret('gun-turret',100.5,0.5,18,'normal',41968115)
  local unc=turret('gun-turret',200.5,0.5,18,'uncommon',41968116)
  local function collector(x,y) return {valid=true,name='asteroid-collector',position={x=x,y=y},direction=0,prototype={}} end
  local cols={collector(0.5,-21.5),collector(100.5,-21.5),collector(200.5,-18.5)}
  local tiles={}
  for x=-30,230 do tiles[#tiles+1]={position={x=x,y=0}} end
  local s={index=9,find_entities_filtered=function(f)
      if f.type=='asteroid-collector' then return cols end
      if f.type=='inserter' then return {} end
      if f.type=='entity-ghost' then return {} end
      return {leg,plain,unc}
    end,
    find_tiles_filtered=function() return tiles end}
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Asterion',surface=s,force='f',index=3} end,
    inventory_rounds=function(inv) local c=inv.get_contents()[1]; return {{name=c.name,quality='normal',count=c.count,rounds=c.count*10,magazine_size=10}} end,
    rounds_text=function(rows) return rows[1].name..'*'..rows[1].count end}
  local r=D.read({},{platform='Asterion'})
  local rows={}
  for _,t in ipairs(r.turrets) do rows[t.position.x]=t end
  eq(rows[0.5].quality,'legendary','legendary row quality'); eq(rows[0.5].range,27,'legendary range'); eq(rows[0.5].base_range,18,'legendary base_range')
  eq(rows[100.5].quality,'normal','normal row quality'); eq(rows[100.5].range,18,'normal range'); eq(rows[100.5].base_range,18,'normal base_range')
  eq(rows[200.5].quality,'uncommon'); eq(rows[200.5].range,19.8,'uncommon range 18 x 1.1')
  eq(r.collectors[1].covered_by,1,'the legendary turret reaches 22 tiles')
  eq(r.collectors[2].covered_by,0,'the normal turret does not')
  eq(r.collectors[3].covered_by,1,'the uncommon turret reaches 19 tiles')
  local text=table.concat(r.lines,'\n')
  has(text,'asteroid-collector (0.5,-21.5), front (0.5,-21.5): 1 turret reach it')
  has(text,'legendary gun-turret (0.5,0.5) firearm-magazine*10')
  has(text,'NO turret reaches it (nearest gun-turret (100.5,0.5), 4 tiles past its range 18)')
  has(r.note,'times its quality\'s range_multiplier')
  -- the hull's edge tiles (the row y=0, x -30..230; tile centres x+0.5, 0.5) a turret reaches: x -27..27 (legendary,
  -- within 27 of (0.5,0.5)), 82..118 (normal, within 18), 181..219 (uncommon, within 19.8): 55 + 37 + 39 of 261
  local north
  for _,row in ipairs(r.sides) do if row.side=='north' then north=row end end
  eq(north.edge_tiles,261,'edge tiles')
  eq(north.uncovered,261-55-37-39,'north edge tiles no turret reaches')
  -- a turret's quality is read once per unit number
  local reads=0
  local mt={__index=function(_,k) if k=='name' then reads=reads+1; return 'legendary' end end}
  leg.quality=setmetatable({},mt)
  D.read({},{platform='Asterion'})
  eq(reads,0,'quality kept by unit number')
  -- planned: a rare railgun ghost's range 40 x 1.2
  local ghost={valid=true,type='entity-ghost',ghost_type='ammo-turret',ghost_name='railgun-turret',name='entity-ghost',position={x=50.5,y=0.5},direction=0,quality={name='rare'},
    ghost_prototype={attack_parameters={range=40,min_range=3.5,turn_range=0.2}},ignore_unprioritised_targets=false,get_priority_target=function() return nil end}
  local find=s.find_entities_filtered
  s.find_entities_filtered=function(f) if f.type=='entity-ghost' then return f.ghost_type=='asteroid-collector' and {} or {ghost} end return find(f) end
  storage={}
  local Dp=dofile('mod/agent-harness_0.1.0/platdefense.lua'){state=function() return storage end,platform=function() return {name='Asterion',surface=s,force='f',index=3} end,
    inventory_rounds=function(inv) local c=inv.get_contents()[1]; return {{name=c.name,quality='normal',count=c.count,rounds=c.count*10,magazine_size=10}} end,
    rounds_text=function(rows) return rows[1].name..'*'..rows[1].count end}
  local rp=Dp.read({},{platform='Asterion',planned=true})
  local g=rp.planned.ghosts[1]
  eq(g.quality,'rare'); eq(g.range,48,'rare railgun ghost range'); eq(g.base_range,40); eq(g.min_range,3.5,'minimum range the prototype\'s')
  has(table.concat(rp.lines,'\n'),'planned: rare railgun-turret ghost (50.5,0.5) aims within 72 degrees centred north, range 48, not within 3.5')
  -- inspect's reach: a built turret, a ghost, anything else
  local laser={type='electric-turret',name='laser-turret',quality={name='legendary'},prototype={attack_parameters={range=24,min_range=0}}}
  local lr=D.reach(laser)
  eq(lr.quality,'legendary'); eq(lr.range,36); eq(lr.base_range,24); eq(lr.min_range,0)
  local gr=D.reach(ghost)
  eq(gr.range,48); eq(gr.base_range,40); eq(gr.min_range,3.5)
  eq(D.reach({type='container',name='iron-chest',quality={name='legendary'},prototype={}}),nil,'a chest has no reach')
  eq(D.reach({type='ammo-turret',name='gun-turret',quality={name='normal'},prototype={attack_parameters={range=18,min_range=0}}}).range,18)
  defines=nil; game=nil; prototypes=nil; storage=nil
end
print('d25_batch209 platform_defense quality range: ok')

-- danger's turret coverage: a legendary rocket turret 50 tiles off covers, a normal one does not
do
  defines={inventory={turret_ammo=1}}
  prototypes={quality=QUALITY}
  local function rocket(x,q)
    return {valid=true,type='ammo-turret',name='rocket-turret',position={x=x,y=0},quality={name=q},prototype={attack_parameters={range=36,min_range=15}},
      get_inventory=function() return {is_empty=function() return false end} end}
  end
  local list={rocket(50,'legendary'),rocket(-50,'normal')}
  local radius
  local surface={find_entities_filtered=function(f) radius=f.radius; return list end}
  local Dg=dofile('mod/agent-harness_0.1.0/danger.lua'){state=function() return {} end,position=function(v) return {x=v.x,y=v.y} end}
  local c=Dg.coverage(surface,'f',{x=0,y=0})
  eq(c.ready,1,'the legendary rocket turret (range 54) covers 50 tiles off; the normal one (36) does not')
  assert(radius>=60,'the find reaches a legendary railgun\'s 60 tiles')
  has(c.line,'in range of 1 turret ready (1 rocket-turret)')
  prototypes=nil; defines=nil
end
print('d25_batch209 danger coverage quality range: ok')
