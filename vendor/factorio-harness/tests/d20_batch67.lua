-- d20 batch67 (operator d21 08:13). Run from the harness root: lua tests/d20_batch67.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end

-- AC1 (Astra #1609): platform names in free text, longest whole name first, names that are prefixes of others.
do
  local N=dofile('mod/agent-harness_0.1.0/namematch.lua')
  local cands={{name='Kestrel'},{name='Kestrel II'},{name='Kestrel IV'},{name='Kestrel IVa'},{name='Kestrel IVc'},
    {name='Limestone'},{name='Limestone-spare-unbuilt'},{name='Petrel'},{name='Petrel II'}}
  local function names(text)
    local t={}
    for k,m in ipairs(N.find(text,cands)) do t[k]=m.name end
    return table.concat(t,'|')
  end
  eq(names('Kestrel IVc refuel and Kestrel II ammo'),'Kestrel IVc|Kestrel II')
  eq(names('Kestrel to Aquilo'),'Kestrel')
  eq(names('Kestrel IV hub; Kestrel IVb hub'),'Kestrel IV|Kestrel','IVb is no name here: Kestrel stands before a space')
  eq(names('kestrel ii at Fulgora'),'Kestrel II','any case when the case differs')
  eq(names('Kestrels and KestrelII'),'','no whole name')
  eq(names('Limestone-spare-unbuilt, then Limestone'),'Limestone-spare-unbuilt|Limestone')
  eq(names('Petrel II/Petrel'),'Petrel II|Petrel')
  eq(names(nil),''); eq(names(''),'')
  -- one name in two cases: the case the game keeps first
  local two={{name='Wren',id=1},{name='wren',id=2}}
  eq(N.find('wren docks',two)[1].c.id,2); eq(N.find('Wren docks',two)[1].c.id,1); eq(N.find('WREN docks',two)[1].c.id,1)
  eq(#N.find('WREN docks',two),1,'one span, one name')
end
print('d20_batch67 AC1 name matcher: ok')

-- AC1: board_review {ownership}: a claim titled with a platform's whole name covers it ("Petrel II" is not "Petrel");
-- a claim's planet from its title is a whole planet name outside our platforms' names.
do
  game={tick=100000}
  local function plsurf(index,name) local s={name='platform-'..index,index=index}; s.platform={valid=true,index=index,name=name,surface=s}; return s end
  local p1,p2=plsurf(5,'Petrel'),plsurf(6,'Petrel II')
  local items={
    [5]={id=5,kind='claim',status='claimed',owner='astra',title='Petrel II ammo line',surface='nauvis',active_tick=99000},
    [6]={id=6,kind='claim',status='claimed',owner='sol',title='Petrel: rockets',surface='nauvis',active_tick=99000}}
  local st={board={items=items}}
  local force={platforms={p1.platform,p2.platform},logistic_networks={}}
  game.surfaces={}
  local C=dofile('mod/agent-harness_0.1.0/claims.lua'){state=function() return st end,crafters=function() return {} end,
    planets=function() return {'nauvis','gleba','fulgora'} end}
  local r=C.ownership({force=force},{})
  local by={}
  for _,s in ipairs(r.surfaces) do for _,row in ipairs(s.systems) do by[row.name or '']=row end end
  eq(by['Petrel'].claims,1); assert(by['Petrel'].line:find('#6 sol',1,true),by['Petrel'].line); assert(not by['Petrel'].line:find('#5',1,true),by['Petrel'].line)
  eq(by['Petrel II'].claims,1); assert(by['Petrel II'].line:find('#5 astra',1,true),by['Petrel II'].line)
  -- a claim from before claims had a surface: its title's planet
  game.forces={player={platforms={{valid=true,name='Gleba Express'},{valid=true,name='Fulgora Runner'}}}}
  local function surf(title) return C.surface_of({id=9,kind='claim',title=title,owner='luna'}) end
  eq(surf('Gleba Express refuel at Fulgora'),'fulgora','Gleba Express is a platform')
  eq(surf('Gleba landing power'),'gleba')
  eq(surf('Fulgora Runner hub at gleba, Gleba side'),'gleba','one planet named twice')
  eq(surf('Glebalike rows'),'nauvis','no whole planet name: the owner surface fallback')
  eq(surf('Gleba to Fulgora seeds'),'nauvis','two planets: the fallback')
  game=nil
end
print('d20_batch67 AC1 ownership and claim surfaces: ok')

-- AC2 (Astra #1647, tick 42417585): an underground entrance under an orphan inserter's drop point: the inserter (what it
-- holds, where it takes from), and belts and splitters running into the planned line; with item, other items conflict.
do
  prototypes={entity={['transport-belt']={type='transport-belt'},['underground-belt']={type='underground-belt'},splitter={type='splitter'},inserter={type='inserter'}},
    item={['iron-ore']={},coal={}},recipe={}}
  local function lanes(t) return {get_max_transport_line_index=function() return 2 end,get_transport_line=function(i) return {get_contents=function() return i==1 and t or {} end} end} end
  local function ent(e) e.valid=true; local m=e.methods or {}; e.methods=nil; for k,v in pairs(m) do e[k]=v end; return e end
  local chest=ent{name='wooden-chest',type='container',position={x=-82.5,y=49.5},
    methods={get_output_inventory=function() return {get_contents=function() return {{name='coal',count=50,quality='normal'},{name='firearm-magazine',count=20,quality='normal'}} end} end}}
  local ins=ent{name='inserter',type='inserter',unit_number=1,position={x=-82.5,y=48.5},drop_position={x=-82.3,y=47.7},pickup_position={x=-82.5,y=49.5},
    held_stack={valid_for_read=true,name='coal',count=1},pickup_target=chest,use_filters=false}
  local far=ent{name='inserter',type='inserter',unit_number=2,position={x=-80.5,y=48.5},drop_position={x=-80.5,y=47.5},held_stack={valid_for_read=false},use_filters=false}
  local side=ent{name='transport-belt',type='transport-belt',unit_number=3,position={x=-83.5,y=44.5},direction=4,methods=lanes({{name='iron-ore',count=4}})}
  local head=ent{name='transport-belt',type='transport-belt',unit_number=4,position={x=-82.5,y=43.5},direction=8,methods=lanes({{name='stone',count=2}})}
  local split=ent{name='splitter',type='splitter',unit_number=5,position={x=-83.5,y=41},direction=4,methods=lanes({{name='copper-ore',count=7}})}
  local found={ins,far,side,head,split}
  local surface={find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(found) do
      local okt=type(f.type)=='string' and e.type==f.type or type(f.type)=='table' and (function() for _,t in ipairs(f.type) do if t==e.type then return true end end end)()
      local a=f.area
      if okt and e.position.x>=a[1][1] and e.position.x<=a[2][1] and e.position.y>=a[1][2] and e.position.y<=a[2][2] then out[#out+1]=e end
    end
    return out
  end}
  -- the line runs north from (-82.5,47.5): an entrance there, its exit at (-82.5,45.5), belts on to (-82.5,40.5) then east
  local line={{name='underground-belt',position={x=-82.5,y=47.5},direction='north',type='input'},{name='underground-belt',position={x=-82.5,y=45.5},direction='north',type='output'},
    {name='transport-belt',position={x=-82.5,y=44.5},direction='north'},{name='transport-belt',position={x=-82.5,y=43.5},direction='north'},
    {name='transport-belt',position={x=-82.5,y=42.5},direction='north'},{name='transport-belt',position={x=-82.5,y=41.5},direction='north'},
    {name='transport-belt',position={x=-82.5,y=40.5},direction='north'},{name='transport-belt',position={x=-82.5,y=39.5},direction='north'}}
  local RF=dofile('mod/agent-harness_0.1.0/routefeeds.lua')()
  local f=RF.check(surface,'player',line,{item='iron-ore'})
  eq(#f.rows,3,'the inserter, the side belt, the splitter; the head-on belt and the inserter dropping off the line are not')
  local by={}; for _,r in ipairs(f.rows) do by[r.name]=r end
  local r=by.inserter
  eq(r.onto.type,'input'); eq(r.holds.name,'coal'); eq(r.from.name,'wooden-chest'); eq(r.conflict,true); eq(table.concat(r.others,','),'coal,firearm-magazine')
  eq(r.line,'inserter (-82.5,48.5) drops at (-82.3,47.7), on the planned underground-belt entrance (-82.5,47.5); holds coal 1; takes from wooden-chest (-82.5,49.5): coal 50, firearm-magazine 20; not iron-ore: coal, firearm-magazine')
  eq(by['transport-belt'].line,'transport-belt (-83.5,44.5) facing east runs into the planned transport-belt (-82.5,44.5) from its west side; carries iron-ore 4')
  eq(by['transport-belt'].conflict,nil,'it carries iron ore only')
  eq(by.splitter.how,'from its west side'); eq(by.splitter.conflict,true)
  eq(f.conflicts,2); eq(f.line,'3 entities of ours feed the planned tiles (1 inserter, 2 belts); 2 feed items other than iron-ore')
  -- without item: listed, no conflicts
  local g=RF.check(surface,'player',line,{})
  eq(g.conflicts,nil); eq(g.rows[1].conflict,nil)
  -- a whitelist that leaves out what the chest holds: nothing of it moves
  ins.use_filters=true; ins.filter_slot_count=1; ins.inserter_filter_mode='whitelist'; ins.get_filter=function() return {name='iron-ore'} end
  ins.held_stack={valid_for_read=false}
  local h=RF.check(surface,'player',line,{item='iron-ore'})
  for _,x in ipairs(h.rows) do if x.kind=='inserter' then eq(x.conflict,nil,'whitelist iron-ore'); assert(x.line:find('; whitelist iron-ore',1,true),x.line) end end
  -- the line's own entities on a re-run are not feeders (here the splitter), nor the belt the line extends
  local k=RF.check(surface,'player',line,{item='iron-ore',own={{position={x=-83.5,y=41}}}})
  eq(k.conflicts,0,"the whitelisted inserter and the side belt carry iron ore; the splitter is the line's own")
  eq(RF.check(surface,'player',{line[3],line[4]},{joins={x=-83.5,y=44.5}}),nil,'the side belt is the one the line extends')
  eq(RF.check(surface,'player',{{name='transport-belt',position={x=0.5,y=0.5},direction='north'}},{}),nil,'nothing near')
  prototypes=nil
end
print('d20_batch67 AC2 route feeders: ok')
