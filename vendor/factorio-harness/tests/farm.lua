-- Run from repository root: lua tests/farm.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={agricultural_tower_input=2,agricultural_tower_output=3,chest=1}}
game={tick=100000}
local YUMAKO={name='yumako-tree',type='plant',growth_ticks=18000,autoplace_specification={tile_restriction={'natural-yumako-soil','artificial-yumako-soil'}},
  mineable_properties={products={{name='yumako',amount=50}}}}
local JELLY={name='jellystem',type='plant',growth_ticks=18000,autoplace_specification={tile_restriction={'natural-jellynut-soil'}},
  mineable_properties={products={{name='jellynut',amount=50}}}}
prototypes={item={['yumako-seed']={plant_result=YUMAKO},['jellynut-seed']={plant_result=JELLY},yumako={},
  nutrients={fuel_value=2000000,fuel_category='nutrients'},coal={fuel_value=4000000,fuel_category='chemical'},['wood']={fuel_value=2000000,fuel_category='chemical'}},
  entity={['yumako-tree']=YUMAKO,jellystem=JELLY}}
local F=dofile('mod/agent-harness_0.1.0/farm.lua'){}
-- Seeds and soil come from the prototypes (can_place_entity ignores soil: a private 2.0.77 world).
eq(F.seeds()['yumako-seed'],'yumako-tree'); eq(F.seeds()['jellynut-seed'],'jellystem'); eq(F.seeds().yumako,nil)
eq(F.soil('yumako-tree')['natural-yumako-soil'],true); eq(F.soil('jellystem')['natural-yumako-soil'],nil)
-- A tower at (0.5,0.5), radius 1 cell of 3x3 tiles: 8 cells. Yumako soil west, jellynut soil east, lichen between.
local function tile(x) if x<0 then return 'natural-yumako-soil' elseif x>=2 then return 'natural-jellynut-soil' end return 'midland-cracked-lichen' end
local pole={valid=true,name='medium-electric-pole',type='electric-pole',position={x=-2.5,y=-2.5}}
local function inv(list)
  local i={}
  for k,v in ipairs(list) do i[k]=v end
  i.get_contents=function() local out={} for _,s in ipairs(list) do out[#out+1]={name=s.name,count=s.count} end return out end
  return i
end
local surface={name='gleba'}
surface.get_tile=function(x,y) return {name=tile(x)} end
surface.can_place_entity=function(a) return not (math.abs(a.position.x-pole.position.x)<1.5 and math.abs(a.position.y-pole.position.y)<1.5) end
surface.find_entities_filtered=function(f) if f.area[1][1]<=pole.position.x and f.area[2][1]>=pole.position.x and f.area[1][2]<=pole.position.y and f.area[2][2]>=pole.position.y then return {pole} end return {} end
local tower={valid=true,name='agricultural-tower',type='agricultural-tower',position={x=0.5,y=0.5},surface=surface,force={},
  prototype={growth_grid_tile_size=3,agricultural_tower_radius=1},status='waiting'}
tower.get_inventory=function(id) return id==2 and inv({{name='yumako-seed',count=5}}) or nil end
tower.get_output_inventory=function() return inv({{name='yumako',count=50}}) end
tower.owned_plants={
  {valid=true,name='yumako-tree',position={x=-2.4,y=0.6},tick_grown=game.tick+600,prototype=YUMAKO},
  {valid=true,name='jellystem',position={x=3.6,y=3.4},tick_grown=game.tick-10,prototype=JELLY}}
local t=F.tower(tower,{status_name=function() return 'waiting_for_plants_to_grow' end,flow=function(item) return item=='yumako' and 100 or 0 end})
eq(t.state,'waiting for plants to grow'); eq(t.seeds,'yumako-seed 5'); eq(t.output,'yumako 50')
eq(t.area,'8 cells of 3x3 tiles within 1 cells: (-4,-4)-(5,5)')
eq(t.cells,'1 growing (next grown in 10s); 1 grown; free with soil for: 2 jellynut-seed, 1 yumako-seed; blocked: 1 medium-electric-pole; no soil for any seed: 2 midland-cracked-lichen')
eq(t.plantable_now,1,'one free yumako cell for the yumako seeds it holds')
eq(t.planted_10min,2)
eq(t.plants[1],'jellystem (3.6,3.4) grown, waiting for harvest'); eq(t.plants[2],'yumako-tree (-2.4,0.6) grown in 10s')
eq(t.harvest_made_10min,'yumako 100 on gleba')
-- Each cell with soil and no plant, nearest first, where and why (Sol, 15:20: yumako cells stayed empty).
eq(#t.empty_cells,4)
eq(t.empty_cells[1],'(3.5,0.5) free, soil for jellynut-seed; the tower holds no jellynut-seed (it holds yumako-seed)')
eq(t.empty_cells[2],'(-2.5,-2.5) soil for yumako-seed, blocked by medium-electric-pole (-2.5,-2.5)')
eq(t.empty_cells[3],'(-2.5,3.5) free, soil for yumako-seed and the tower holds it: not planted yet (tower: waiting for plants to grow)')
eq(t.empty_cells[4],'(3.5,-2.5) free, soil for jellynut-seed; the tower holds no jellynut-seed (it holds yumako-seed)')
-- A cell whose centre is soil while tiles round it are not: the game refuses the plant with no entity there.
surface.get_tile=function(x,y) if y>2 and x>-2 and x<0 then return {name='midland-cracked-lichen'} end return {name=tile(x)} end
local place=surface.can_place_entity
surface.can_place_entity=function(a) if a.position.x==-2.5 and a.position.y==3.5 then return false end return place(a) end
t=F.tower(tower,{status_name=function() return 'working' end})
eq(t.empty_cells[3],'(-2.5,3.5) soil for yumako-seed at its centre, but 3 of the 9 tiles round it are not (3 midland-cracked-lichen): the game refuses the plant')
surface.get_tile=function(x,y) return {name=tile(x)} end; surface.can_place_entity=place
eq(F.STATE.item_ingredient_shortage,'no seeds in its input'); eq(F.STATE.no_spot_seedable_by_inputs,'no free cell with soil for its seeds')
eq(F.STATE.not_enough_space_in_output,'output full')
-- Fuel: a biochamber burns nutrients; chemical burners default to coal; asked fuel of another category is refused.
local bio={burner={fuel_categories={nutrients=true}}}
local furnace={burner={fuel_categories={chemical=true}}}
eq(F.default_fuel(bio,function(n) return n=='nutrients' and 5 or 0 end),'nutrients')
eq(F.default_fuel(furnace,function() return 0 end),'coal')
eq(F.default_fuel({},function() return 0 end),'coal')
eq(F.accepts_fuel(bio,'coal'),false); eq(F.accepts_fuel(bio,'nutrients'),true); eq(F.accepts_fuel(furnace,'wood'),true); eq(F.accepts_fuel({},'coal'),true)
-- Spoiling: stalest first, time left and how much has spoiled.
local function st(name,count,tick,pct) return {valid_for_read=true,name=name,count=count,spoil_tick=tick,spoil_percent=pct} end
local box={st('yumako',50,game.tick+3600,0.9),st('iron-plate',100,0,0),st('jellynut',20,game.tick+36000,0.1),{valid_for_read=false}}
local rows=F.spoiling(box,8)
eq(#rows,2); eq(rows[1],'yumako*50 spoils in 1m00s (90% spoiled)'); eq(rows[2],'jellynut*20 spoils in 10m00s (10% spoiled)')
print('farm: ok')
